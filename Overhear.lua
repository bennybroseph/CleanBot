-- ============================================================
-- Overhear.lua  —  keep tracked state in sync with the player's OWN chat commands
--
-- CleanBot only learns about bot state from its own UI actions and the replies it
-- requests. But the player can also command bots by typing directly in chat —
-- broadcasting "co +passive" to party/raid, or whispering "e <item>" to one bot.
-- This listener overhears the PLAYER'S OWN command-shaped messages and folds them
-- into the cached state (firing the same events the UI reacts to), so the display
-- stays correct without the user touching CleanBot.
--
-- Scope (locked): the player's own messages only. Strategy/display commands
-- (co/nc, formation, ll) are merged into the bot entry; inventory/bank/equipment
-- commands (e/u/ue/give/s/b/t/nt, bank <link>, outfit … equip) mark the bot's
-- inventory dirty so an open window re-fetches. Everything else is ignored.
--
-- All parsing helpers are pure (no WoW API) and exposed on NS for unit testing.
-- ============================================================
local NS = CleanBotNS

local strlower, strmatch, gmatch = string.lower, string.match, string.gmatch

-- ── Pure helpers (unit-tested in spec/overhear_spec.lua) ─────────────────────

-- Strips a realm suffix ("Name-Realm" → "Name") so a cross-realm sender compares
-- to UnitName("player") (which is realm-less on the player's own realm).
local function nameOnly(s) return s and (strmatch(s, "^([^-]+)") or s) or nil end

--- True when a chat sender is the player (realm-insensitive, case-insensitive).
---@param sender string?  The CHAT_MSG_* sender (arg2).
---@param me     string?  UnitName("player").
---@return boolean
NS.CB_IsSelfSender = function(sender, me)
    if not sender or not me then return false end
    return strlower(nameOnly(sender)) == strlower(nameOnly(me))
end

local DELTA_OP = { ["+"] = "on", ["-"] = "off", ["~"] = "toggle" }

--- Parses a co/nc operator body into per-token ops. Returns ONLY the mentioned
--- tokens (a delta — never a full replacement), plus a reset flag. Operators:
--- `+`add, `-`remove, `~`toggle, `!`reset-all-for-state, `?`query (ignored — e.g.
--- the ",?" we append on the no-bridge read path). Bare/unknown tokens are ignored.
---@param rest string?  The text after "co "/"nc ", e.g. "+passive,-aoe,~focus" or "!".
---@return table   ops    Map token → "on"|"off"|"toggle" for each mentioned token.
---@return boolean reset  True if a "!" (reset-all) operator was present.
NS.CB_ParseStrategyDelta = function(rest)
    local ops, reset = {}, false
    if not rest then return ops, reset end
    for token in gmatch(rest, "[^,]+") do
        token = token:gsub("^%s*(.-)%s*$", "%1")
        local first = token:sub(1, 1)
        if first == "!" then
            reset = true
        elseif DELTA_OP[first] then
            local name = token:sub(2):gsub("^%s*(.-)%s*$", "%1")
            if name ~= "" then ops[name] = DELTA_OP[first] end
        end
        -- "?" and bare/unknown tokens fall through (ignored) — we never guess a value.
    end
    return ops, reset
end

-- Short item-action verbs (InventoryAction / vendor / trade triggers). Each takes an
-- item argument, so a bare verb is treated as chatter and ignored.
local INVENTORY_VERBS = {
    e = true, u = true, ue = true, give = true,  -- InventoryAction (equip/use/unequip/give)
    s = true, b = true,                          -- vendor sell/buy
    t = true, nt = true,                         -- trade (traded / non-traded slot)
}

--- Classifies a chat line as a bot command we care about. Pure — does no validation
--- of strategy/formation/loot values (the appliers do that).
---@param msg string?  The raw chat message.
---@return string? kind  "combat" | "noncombat" | "formation" | "loot" | "inventory", or nil.
---@return string? verb  The leading command word (lowercased).
---@return string? rest  The remainder after the verb.
NS.CB_ClassifyChatCommand = function(msg)
    if not msg then return nil end
    local trimmed = msg:gsub("^%s*(.-)%s*$", "%1")
    if trimmed == "" then return nil end
    -- Bare movement one-shot (whole message is the command, e.g. "follow", "stay", "flee from adds").
    -- Checked before the verb split so multi-word "flee from adds" matches; "follow me" does NOT.
    local low = strlower(trimmed)
    if NS.CB_MovementField(low) then return "movement", low, "" end
    local verb, rest = strmatch(trimmed, "^(%S+)%s*(.*)$")
    verb = verb and strlower(verb)
    if verb == "co"        then return "combat",    verb, rest end
    if verb == "nc"        then return "noncombat", verb, rest end
    if verb == "formation" then return "formation", verb, rest end
    if verb == "ll"        then return "loot",      verb, rest end
    -- "reset botAI" (ResetAiAction) wipes the bot's AI to defaults — combat, non-combat, movement,
    -- formation, and loot all revert — so we mirror a full reset to defaults into the cached state.
    if verb == "reset" and strlower(rest) == "botai" then return "reset", verb, rest end
    if verb == "bank" then
        -- Bare "bank" lists the bank (a query handled by the reply parser); "bank <link>"
        -- / "bank -<link>" deposit/withdraw and change its contents.
        if rest == "" then return nil end
        return "inventory", verb, rest
    end
    if verb == "outfit" then
        -- Only equip/replace change equipped gear; build/list/snapshot forms don't.
        local r = strlower(rest)
        if r:find("equip", 1, true) or r:find("replace", 1, true) then return "inventory", verb, rest end
        return nil
    end
    if INVENTORY_VERBS[verb] and rest ~= "" then return "inventory", verb, rest end
    return nil
end

-- Validation sets, built lazily from the live tables (Overhear loads before
-- CommandControls/Strategies in the TOC, so we can't snapshot them at file load).
local formationSet, lootSet, movementSet
local function ensureSets()
    if formationSet then return end
    formationSet, lootSet, movementSet = {}, {}, {}
    for _, f in ipairs(NS.FORMATIONS or {}) do formationSet[f.token] = true end
    for _, grp in ipairs(NS.NC_STRATEGIES or {}) do
        if grp.options then for _, o in ipairs(grp.options) do lootSet[o.value] = true end end
    end
    -- token (chat one-shot, e.g. "follow", "flee from adds") → strategy field (e.g. "mFollow").
    for _, m in ipairs(NS.MOVEMENT_STRATEGIES or {}) do movementSet[m.cmd] = m.field end
end

--- Maps a bare movement one-shot command to its strategy field, or nil if not one.
--- (e.g. "follow" → "mFollow"). Note "flee" is a transient action with no persistent
--- field, so it is intentionally absent — only the exclusive movement strategies map.
---@param token string?
---@return string?  The movement field, or nil.
NS.CB_MovementField = function(token)
    ensureSets()
    return token and movementSet[token] or nil
end

--- True if `token` is a valid `formation <token>` value.
---@param token string?
---@return boolean
NS.CB_IsFormationToken = function(token)
    ensureSets()
    return token ~= nil and formationSet[token] == true
end

--- True if `value` is a valid `ll <value>` loot-quality value.
---@param value string?
---@return boolean
NS.CB_IsLootValue = function(value)
    ensureSets()
    return value ~= nil and lootSet[value] == true
end

-- ── @-qualifier targeting (mirrors mod-playerbots src/Bot/Cmd/ChatFilter.cpp) ─
-- A command may lead with one or more "@..." qualifiers that AND together to restrict which bots
-- react (e.g. "@tank co +passive", "@melee @warrior s gray"). We mirror the families CleanBot can
-- evaluate from cached state + live unit info: role, class, melee/ranged, level, subgroup. Families
-- needing server-only state (@<spec>, @aura/@noaura, @aggroby, @star..@skull RTI) — and ANY
-- unrecognized "@token" — cause the whole command to be skipped (not overheard), so we never
-- mis-apply; the next authoritative sync reconciles.

local QUAL_ROLE        = { tank = true, heal = true, dps = true, rangeddps = true, meleedps = true }
local QUAL_MELEERANGED = { melee = true, ranged = true }
local QUAL_CLASS       = {
    dk = "DEATHKNIGHT", druid = "DRUID", hunter = "HUNTER", mage = "MAGE", paladin = "PALADIN",
    priest = "PRIEST", rogue = "ROGUE", shaman = "SHAMAN", warlock = "WARLOCK", warrior = "WARRIOR",
}
local MELEE_CLASS  = { WARRIOR = true, PALADIN = true, ROGUE = true, DEATHKNIGHT = true }
local RANGED_CLASS = { HUNTER = true, PRIEST = true, MAGE = true, WARLOCK = true }

-- Mirror of ChatFilter.cpp's CombatTypeChatFilter class+role rule. Returns true=ranged,
-- false=melee, nil=unknown (class not yet cached).
local function isEntryRanged(entry)
    local c = entry and entry.class
    if not c then return nil end
    if RANGED_CLASS[c] then return true end
    if MELEE_CLASS[c]  then return false end
    local cd = entry.combat
    if c == "DRUID"  then return not (cd and cd.isTank) end        -- tank druid = melee, else ranged
    if c == "SHAMAN" then return (cd and cd.isHealer) == true end  -- heal shaman = ranged, else melee
    return nil
end

-- Parses a "@group" body like "1,3-4" into a set { [1]=true, [3]=true, [4]=true }, or nil if malformed.
local function parseGroupSet(spec)
    if not spec or spec == "" then return nil end
    local set = {}
    for token in gmatch(spec, "[^,]+") do
        local a, b = strmatch(token, "^(%d+)%-(%d+)$")
        if a then
            a, b = tonumber(a), tonumber(b)
            if a > b then a, b = b, a end
            for i = a, b do set[i] = true end
        elseif strmatch(token, "^%d+$") then
            set[tonumber(token)] = true
        else
            return nil  -- malformed → treat the whole qualifier as unrecognized
        end
    end
    return set
end

-- Classifies one "@token" into a descriptor table, or nil if unrecognized/unsupported.
local function classifyQualifier(tok)
    local body = strlower(tok:sub(2))  -- drop the leading "@"
    if QUAL_ROLE[body]        then return { kind = "role",  role = body } end
    if QUAL_MELEERANGED[body] then return { kind = "mr",    want = body } end
    if QUAL_CLASS[body]       then return { kind = "class", class = QUAL_CLASS[body] } end
    if body:sub(1, 5) == "group" then
        local set = parseGroupSet(body:sub(6))
        if set then return { kind = "group", set = set } end
        return nil
    end
    local lf, lt = strmatch(body, "^(%d+)%-(%d+)$")
    if lf then return { kind = "level", from = tonumber(lf), to = tonumber(lt) } end
    local lv = strmatch(body, "^(%d+)$")
    if lv then return { kind = "level", from = tonumber(lv), to = tonumber(lv) } end
    return nil  -- @<spec>, @aura, @aggroby, @star.., or unknown → caller skips the command
end

--- Strips leading "@..." qualifiers from a message into descriptors. Qualifiers chain (AND).
--- The remainder string is kept intact (item-link spaces preserved).
---@param msg string?
---@return table?   descriptors  List of descriptors, or nil when ok is false.
---@return string?  remainder    The command text after the qualifiers.
---@return boolean  ok           False if a leading qualifier was unrecognized → skip the command.
NS.CB_ParseQualifiers = function(msg)
    local descriptors = {}
    if not msg then return descriptors, msg, true end
    local rest = msg:gsub("^%s+", "")
    while rest:sub(1, 1) == "@" do
        local tok, after = strmatch(rest, "^(@%S+)%s*(.*)$")
        if not tok then break end
        local desc = classifyQualifier(tok)
        if not desc then return nil, msg, false end
        descriptors[#descriptors + 1] = desc
        rest = after
    end
    return descriptors, rest, true
end

--- True if a bot entry satisfies ALL qualifier descriptors. `level`/`subgroup` are resolved by the
--- caller from the unit so this helper stays pure; an unresolvable value fails its predicate (safe).
---@param descriptors table   From CB_ParseQualifiers.
---@param entry       table?  CleanBot_PartyBots[key].
---@param level       number? UnitLevel(unit).
---@param subgroup    number? The bot's raid subgroup (party = 1).
---@return boolean
NS.CB_EntryMatchesQualifiers = function(descriptors, entry, level, subgroup)
    if not entry then return false end
    local cd = entry.combat
    local isTank, isHeal = cd and cd.isTank, cd and cd.isHealer
    for _, d in ipairs(descriptors) do
        if d.kind == "role" then
            local ok
            if     d.role == "tank"      then ok = isTank == true
            elseif d.role == "heal"      then ok = isHeal == true
            elseif d.role == "dps"       then ok = not isTank and not isHeal
            elseif d.role == "rangeddps" then ok = isEntryRanged(entry) == true  and not isTank and not isHeal
            elseif d.role == "meleedps"  then ok = isEntryRanged(entry) == false and not isTank and not isHeal
            end
            if not ok then return false end
        elseif d.kind == "mr" then
            local ranged = isEntryRanged(entry)
            if ranged == nil then return false end
            if d.want == "ranged" and not ranged then return false end
            if d.want == "melee"  and ranged     then return false end
        elseif d.kind == "class" then
            if entry.class ~= d.class then return false end
        elseif d.kind == "level" then
            if not level or level < d.from or level > d.to then return false end
        elseif d.kind == "group" then
            if not subgroup or not d.set[subgroup] then return false end
        end
    end
    return true
end

-- ── Appliers (mutate the cached entry, then announce via CB_UpdateTabData) ────

-- Folds a co/nc delta into one bot's cached state. Resolves tokens via the same
-- maps the reply parser uses (so role aliases like "bear"/"resto" land on the right
-- field). "!" resets the section to the seeded defaults (best-effort: the server-side
-- reset is unused by our UI and the next sync reconciles exact state).
---@param key  string  Bot name-key.
---@param kind string  "combat" or "noncombat".
---@param rest string  The operator body after the verb.
local function applyStateDelta(key, kind, rest)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end
    local section = (kind == "combat") and "combat" or "nonCombat"
    local map     = (kind == "combat") and NS.STRATEGY_MAP or NS.NC_STRATEGY_MAP
    local ops, reset = NS.CB_ParseStrategyDelta(rest)
    local touched = false
    if reset then
        entry[section] = (section == "combat") and NS.CB_DefaultCombat() or NS.CB_DefaultNonCombat()
        touched = true
    end
    for token, op in pairs(ops) do
        local field = map and map[token]
        if field then
            entry[section] = entry[section] or {}
            if op == "on" then
                entry[section][field] = true
            elseif op == "off" then
                entry[section][field] = false
            else
                entry[section][field] = not entry[section][field]  -- toggle
            end
            touched = true
        end
    end
    if touched and NS.CB_UpdateTabData then NS.CB_UpdateTabData(key, { [section] = true }) end
end

-- Sets one bot's cached formation from an overheard "formation <token>".
local function applyFormation(key, rest)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end
    local token = strmatch(strlower(rest or ""), "^(%a+)")
    if NS.CB_IsFormationToken(token) then
        entry.formation = token
        if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key, { formation = true }) end
    end
end

-- Sets one bot's cached movement mode from an overheard bare one-shot ("follow"/"stay"/"runaway"/…).
-- The one-shot applies to the bot's ACTIVE engine, so we approximate the context with the player's
-- combat state (matching the action bar's display rule). Movement is exclusive — the chosen field is
-- set and the rest cleared.
local function applyMovement(key, token)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end
    local field = NS.CB_MovementField(token)
    if not field then return end
    local section = UnitAffectingCombat("player") and "combat" or "nonCombat"
    entry[section] = entry[section] or {}
    for _, m in ipairs(NS.MOVEMENT_STRATEGIES or {}) do entry[section][m.field] = (m.field == field) end
    if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key, { [section] = true }) end
end

-- Sets one bot's cached loot-quality from an overheard "ll <value>".
local function applyLoot(key, rest)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end
    local value = strmatch(strlower(rest or ""), "^(%a+)")
    if NS.CB_IsLootValue(value) then
        entry.lootStrategy = value
        if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key, { loot = true }) end
    end
end

-- Resets one bot's cached strategy state to defaults, mirroring "reset botAI" (ResetStrategies).
-- combat/non-combat use the seeded defaults; formation + loot use the server's documented defaults
-- ("chaos" / "normal"). Optimistic like the rest of Overhear — a later authoritative reply reconciles.
local function applyReset(key)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end
    entry.combat       = NS.CB_DefaultCombat()
    entry.nonCombat    = NS.CB_DefaultNonCombat()
    entry.formation    = "chaos"    -- NS.FORMATIONS default (CommandControls.lua)
    entry.lootStrategy = "normal"   -- ll default (LootStrategyValue base; see Strategies.lua)
    if NS.CB_UpdateTabData then
        NS.CB_UpdateTabData(key, { combat = true, nonCombat = true, formation = true, loot = true })
    end
end

-- Routes a classified command to the right applier for one managed bot.
local function dispatch(key, kind, verb, rest)
    if kind == "combat" or kind == "noncombat" then
        applyStateDelta(key, kind, rest)
    elseif kind == "movement" then
        applyMovement(key, verb)
    elseif kind == "formation" then
        applyFormation(key, rest)
    elseif kind == "loot" then
        applyLoot(key, rest)
    elseif kind == "reset" then
        applyReset(key)
    elseif kind == "inventory" then
        if CleanBot_PartyBots[key] then NS.CB_Emit(NS.EV.BOT_INVENTORY_DIRTY, key) end
    end
end
-- Exposed as a test seam (drive the appliers with a staged entry); the listener uses the local.
NS.CB_DispatchOverheard = dispatch

-- Runs fn(key, unit) for each managed group member (the player is skipped, matching the
-- broadcast semantics of CB_SendGroupCommand). The unit lets callers resolve UnitLevel / subgroup.
local function forEachManagedMember(fn)
    if not NS.CB_ForEachGroupMember then return end
    NS.CB_ForEachGroupMember(function(unit, name)
        local key = name and strlower(name)
        if key and CleanBot_PartyBots[key] then fn(key, unit) end
    end)
end

-- Resolves a unit's raid subgroup (party members are all subgroup 1).
local function unitSubgroup(unit)
    local idx = unit and tonumber(strmatch(unit, "^raid(%d+)$"))
    if idx then
        local _, _, sg = GetRaidRosterInfo(idx)
        return sg
    end
    return 1
end

-- Applies a classified command to one bot if it passes the qualifier predicate.
local function dispatchIfMatched(key, unit, descriptors, kind, verb, rest)
    if NS.CB_EntryMatchesQualifiers(descriptors, CleanBot_PartyBots[key], UnitLevel(unit), unitSubgroup(unit)) then
        dispatch(key, kind, verb, rest)
    end
end

-- ── Listener ─────────────────────────────────────────────────────────────────
local frame = CreateFrame("Frame", "CleanBotOverhearFrame")
frame:RegisterEvent("CHAT_MSG_PARTY")
frame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
frame:RegisterEvent("CHAT_MSG_RAID")
frame:RegisterEvent("CHAT_MSG_RAID_LEADER")
frame:RegisterEvent("CHAT_MSG_SAY")
frame:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
frame:SetScript("OnEvent", function(_, event, msg, sender)
    local descriptors, remainder, ok = NS.CB_ParseQualifiers(msg)
    if not ok then return end  -- leading @qualifier we can't evaluate → skip (avoid desync)
    local kind, verb, rest = NS.CB_ClassifyChatCommand(remainder)
    if not kind then return end
    if event == "CHAT_MSG_WHISPER_INFORM" then
        -- Our own outgoing whisper: `sender` is the RECIPIENT bot — the single target. The server
        -- still applies @-filters on a whisper, so honor the qualifier against that one bot.
        local rkey = sender and strlower(sender)
        if not rkey or not CleanBot_PartyBots[rkey] then return end
        forEachManagedMember(function(key, unit)
            if key == rkey then dispatchIfMatched(key, unit, descriptors, kind, verb, rest) end
        end)
    elseif NS.CB_IsSelfSender(sender, UnitName("player")) then
        -- Our own party/raid/say broadcast: applies to every managed member that matches.
        forEachManagedMember(function(key, unit)
            dispatchIfMatched(key, unit, descriptors, kind, verb, rest)
        end)
    end
end)
