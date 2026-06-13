-- ============================================================
-- Strategies.lua  —  the combat / non-combat strategy model:
--   definitions, derived lookup tables, default-state builders,
--   whisper-reply parsers, and per-bot storage helpers.
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- Combat strategy definitions  (single source of truth)
--
-- Format mirrors NS.CLASS_STRATEGIES:
--   { header, group, column, [type], strategies = { {cmd, field, name, desc} } }
--
-- column = "left" | "right"  — which panel column the group renders in.
-- type   = "roleDropdown"    — exclusive dropdown whose selection shows one
--   of the subGroups:  { field, header, strategies }
--
-- Derived flat tables (NS.ROLE_STRATEGIES, NS.TANK_STRATEGIES, …) are built
-- automatically below for any callers that still need them.
-- ============================================================

-- The five movement strategies (MovementStrategyContext, supportsSiblings=true →
-- mutually exclusive: adding one drops the rest). Shared by TWO exclusive dropdowns —
-- one in the combat list, one in the non-combat list — because the lists are
-- independent engines: a fresh bot has "follow" in its NON-COMBAT defaults only
-- (AiFactory::AddDefaultNonCombatStrategies), while the combat engine also acts on
-- movement (e.g. PlayerbotAI::ChangeEngineOnCombat snapshots a combat "stay" position),
-- so the two genuinely differ. Each dropdown reads/writes its own state via the normal
-- exclusive-dropdown path; a nil selection ("Free Roam") clears all five.
NS.MOVEMENT_STRATEGIES = {
    { cmd = "follow",         field = "mFollow",   name = "Follow",         desc = "Follow the master at the configured distance" },
    { cmd = "stay",           field = "mStay",     name = "Stay",           desc = "Hold current position; return to it if moved" },
    { cmd = "guard",          field = "mGuard",    name = "Guard",          desc = "Guard this spot — engage what approaches, then return" },
    { cmd = "runaway",        field = "mRunaway",  name = "Run Away",       desc = "Keep distance from enemies" },
    { cmd = "flee from adds", field = "mFleeAdds", name = "Flee from Adds", desc = "Retreat specifically from add packs" },
}

NS.STRATEGIES = {
    {
        header     = "Role",
        group      = "role",
        column     = "left",
        type       = "roleDropdown",
        strategies = {
            -- cmdByClass: classes that implement the role under a different token.
            -- Druid/DK have no literal "tank" rotation token — they tank via their
            -- form/spec strategy (bear / blood). Druid heals via "resto", not "heal".
            { cmd = "tank",       field = "isTank",   name = "Tank",   desc = "Use threat-generating abilities",
              cmdByClass = { DRUID = "bear", DEATHKNIGHT = "blood" } },
            -- dps assist / dps aoe are mutually-exclusive target-acquisition siblings
            -- (AssistStrategyContext, supportsSiblings): single-target focus vs anchoring
            -- on the highest-HP attacker for AoE cleave. Both are universal (no gating).
            { cmd = "dps assist", field = "isDPS",    name = "DPS (Single)", desc = "Assist the group on one efficient kill target at a time" },
            { cmd = "dps aoe",    field = "isDPSAoe", name = "DPS (AoE)",    desc = "Anchor on the toughest attacker so the AoE rotation cleaves the pack" },
            { cmd = "heal",       field = "isHealer", name = "Healer", desc = "Focus on party healing",
              cmdByClass = { DRUID = "resto", SHAMAN = "resto" } },
        },
        subGroups = {
            { field = "isTank",   header = "Tank",    strategies = {
                { cmd = "tank assist", field = "peelAggro",      name = "Peel Aggro",       desc = "Tank pulls mobs off other party members" },
                { cmd = "pull",        field = "pull",           name = "Pull",             desc = "Tank pulls mobs using a ranged skill" },
                { cmd = "pull back",   field = "pullBack",       name = "Pull Back",        desc = "Pull mob then return to starting position" },
                { cmd = "tank face",   field = "faceTargetAway", name = "Face Target Away", desc = "Ensure target does not face ranged players" },
            }},
            -- Shared by both DPS roles (single + aoe). The "Rotation" dropdown bundles the
            -- mutually-exclusive damage modes: AoE Rotation (class cleave — distinct from the
            -- DPS (AoE) role's target picking) vs Focus Fire (single-target only), or "Standard"
            -- (neither). They hard-conflict engine-side (focus vetoes AoE), hence one exclusive
            -- selector. Avoid Aggro stays an independent checkbox below it.
            { field = "isDPS", roles = { "isDPS", "isDPSAoe" }, header = "DPS", strategies = {
                { type = "dropdown", group = "dpsRotation", header = "Rotation", noneLabel = "Standard",
                  strategies = {
                      { cmd = "aoe",   field = "aoeTarget", name = "AoE Rotation",
                        desc = "Use the class AoE rotation — cleave / multi-target spells" },
                      { cmd = "focus", field = "focusFire",  name = "Focus Fire",
                        desc = "Concentrate on the priority target — no AoE or debuff spells, just single-target damage (healing is unaffected)" },
                  } },
                { cmd = "threat", field = "avoidAggro", name = "Avoid Aggro",  desc = "DPS actively avoids grabbing threat" },
            }},
            { field = "isHealer", header = "Healing", strategies = {
                { cmd = "save mana",  field = "saveMana",  name = "Save Mana",  desc = "Healers prioritize high-efficiency spells" },
                { cmd = "healer dps", field = "healerDps", name = "Healer DPS", desc = "Healers cast damage spells when mana allows" },
            }},
        },
    },
    {
        header = "Combat Control",
        group  = "combat",
        column = "left",
        strategies = {
            { cmd = "potions",   field = "usePotions",      name = "Use Potions",           desc = "Use healing and mana potions in combat", default = true },
            { cmd = "boost",     field = "useCooldowns",    name = "Use Cooldowns",         desc = "Use major cooldowns", default = true },
            { cmd = "racials",   field = "useRacials",      name = "Use Racials",           desc = "Use racial abilities in combat", default = true },
            { cmd = "cc",        field = "useCC",           name = "Crowd Control",         desc = "Use crowd-control abilities on Raid Target Icon (RTI) Moon" },
            { cmd = "passive",   field = "passive",         name = "Passive",               desc = "Stand down — do nothing in combat" },
        },
    },
    {
        -- In-combat movement. Default is empty ("Free Roam") — combat positioning
        -- (close/ranged/kite) drives movement unless you pin a mode here (e.g. a ranged
        -- bot set to Stay holds its combat-entry spot). Parsed from co? into entry.combat.
        header     = "Combat Movement",
        group      = "movement",
        column     = "right",
        type       = "dropdown",
        noneLabel  = "Free Roam",
        strategies = NS.MOVEMENT_STRATEGIES,
    },
    {
        -- Engagement range: close (melee) vs ranged (caster) genuinely conflict, so they're
        -- an exclusive dropdown. "Default" clears both (the spec re-applies one on reset).
        -- Normally spec-driven, so it shows the bot's reported mode until you pin one.
        header     = "Positioning Mode",
        group      = "posMode",
        column     = "right",
        type       = "dropdown",
        noneLabel  = "Default",
        strategies = {
            { cmd = "close",  field = "posClose",  name = "Close (Melee)",
              desc = "Close to melee range of the target." },
            { cmd = "ranged", field = "posRanged", name = "Ranged (Caster)",
              desc = "Hold caster distance — back away when a target gets too close to cast." },
        },
    },
    {
        header = "Positioning",
        group  = "position",
        column = "right",
        strategies = {
            { cmd = "kite",      field = "kite",             name = "Kite",               desc = "Run from enemies while you hold their aggro" },
            { cmd = "avoid aoe", field = "avoidAoe",         name = "Avoid AoE",          desc = "Automatically avoid harmful AoE spells" },
            { cmd = "behind",    field = "stayBehindTarget", name = "Stay Behind Target", desc = "Move to target's back when not behind" },
        },
    },
    {
        header = "Timing Controls",
        group  = "timing",
        column = "right",
        strategies = {
            { cmd = "cast time", field = "castTime", name = "Smart Cast Time",
              desc = "Skips casts too slow to land before the target dies — favors faster spells on dying mobs.",
              default = true },
            { cmd = "wait for attack",      field = "waitAttack",    name = "Enable Wait to Attack", desc = "Wait a set time before attacking or healing" },
            { cmd = "wait for attack time", field = "waitAttackTime", name = "Delay",
              type = "timerSlider", min = 1, max = 10, dependsOn = "waitAttack",
              desc = "Seconds to wait before attacking or healing" },
        },
    },
    {
        header = "Other",
        group  = "other",
        column = "right",
        strategies = {
            { cmd = "mark rti",        field = "markTargets", name = "Mark Targets",   desc = "Automatically mark unmarked combat attackers" },
            { cmd = "grind",      field = "grindMobs",  name = "Grind Mobs", desc = "Attack any visible target" },
            { cmd = "aggressive", field = "aggressive", name = "Aggressive", desc = "Auto-attack any nearby hostile, even without a target" },
        },
    },
}

-- ============================================================
-- Per-class registration of the gap-prone generic/role tokens.
-- Verified against each src/Ai/Class/<Class>/<Class>AiObjectContext.cpp strategy
-- factory (see docs/playerbot-strategies.md). A token absent from this table is
-- registered by every class (generic StrategyContext) and is always shown. A class
-- that implements a concept under a different token is covered by the strategy's
-- cmdByClass override instead (e.g. druid "heal" → "resto"), not listed here.
-- Sets keyed by class token for O(1) lookup.
-- ============================================================
NS.STRATEGY_CLASS_SUPPORT = {
    ["tank"]       = { WARRIOR=true, PALADIN=true, WARLOCK=true, DRUID=true, DEATHKNIGHT=true },
    ["heal"]       = { PALADIN=true, PRIEST=true, SHAMAN=true },
    ["pull"]       = { WARRIOR=true, PALADIN=true, ROGUE=true, PRIEST=true, MAGE=true, WARLOCK=true, DRUID=true, DEATHKNIGHT=true },
    ["aoe"]        = { WARRIOR=true, HUNTER=true, ROGUE=true, PRIEST=true, SHAMAN=true, MAGE=true, WARLOCK=true, DRUID=true },
    ["healer dps"] = { PALADIN=true, PRIEST=true, SHAMAN=true, DRUID=true },
    ["cc"]         = { PALADIN=true, HUNTER=true, ROGUE=true, PRIEST=true, MAGE=true, WARLOCK=true, DRUID=true },
    ["boost"]      = { PALADIN=true, ROGUE=true, PRIEST=true, SHAMAN=true, MAGE=true, WARLOCK=true, DRUID=true },
}

-- Effective send/parse token for a strategy on a given class: the cmdByClass
-- override when one exists for that class, else the base cmd.
---@param s     table    Strategy definition { cmd, field, [cmdByClass] }.
---@param class string?  Class token (e.g. "DRUID"); nil → base cmd.
---@return string        The token to send / expect in the reply.
NS.CB_EffStrategyCmd = function(s, class)
    return (class and s.cmdByClass and s.cmdByClass[class]) or s.cmd
end

-- Whether a strategy entry should be shown for a class. Shown when: the class has a
-- cmdByClass override (we know which token works), OR the token has no coverage gaps
-- (absent from STRATEGY_CLASS_SUPPORT), OR the class is in the token's support set.
---@param s     table    Strategy definition.
---@param class string?  Class token; nil → always shown.
---@return boolean
NS.CB_StrategyShown = function(s, class)
    if not class then return true end
    if s.cmdByClass and s.cmdByClass[class] then return true end
    local sup = NS.STRATEGY_CLASS_SUPPORT[s.cmd]
    if not sup then return true end
    return sup[class] == true
end

-- Iterates the leaf strategies of a list, descending one level into inline
-- exclusive-dropdown bundles (`type="dropdown"`, whose own `strategies` are the
-- real toggles). Lets the token map / default builders treat a bundle's options
-- as ordinary strategies. `fn(leaf)`.
---@param list table  A strategies array (may contain dropdown bundles).
---@param fn   fun(s:table)
local function CB_EachLeafStrategy(list, fn)
    for _, s in ipairs(list) do
        if s.type == "dropdown" then
            for _, n in ipairs(s.strategies) do fn(n) end
        else
            fn(s)
        end
    end
end

NS.STRATEGY_MAP        = {}
NS.ROLE_STRATEGIES     = {}
NS.TANK_STRATEGIES     = {}
NS.DPS_STRATEGIES      = {}
NS.HEAL_STRATEGIES     = {}
NS.COMBAT_STRATEGIES   = {}
NS.POSITION_STRATEGIES = {}
NS.TIMING_STRATEGIES   = {}
do
    local groupToTable = {
        role     = NS.ROLE_STRATEGIES,
        combat   = NS.COMBAT_STRATEGIES,
        position = NS.POSITION_STRATEGIES,
        timing   = NS.TIMING_STRATEGIES,
    }
    local subFieldToTable = {
        isTank   = NS.TANK_STRATEGIES,
        isDPS    = NS.DPS_STRATEGIES,
        isHealer = NS.HEAL_STRATEGIES,
    }
    -- Map a strategy's base cmd AND every per-class override token to its field, so
    -- the co? reply parser recognizes whichever token a class actually reports
    -- (e.g. a druid healer reports "resto", a DK tank reports "blood").
    local function mapTokens(s)
        NS.STRATEGY_MAP[s.cmd] = s.field
        if s.cmdByClass then
            for _, alt in pairs(s.cmdByClass) do NS.STRATEGY_MAP[alt] = s.field end
        end
    end
    for _, grp in ipairs(NS.STRATEGIES) do
        for _, s in ipairs(grp.strategies) do
            mapTokens(s)
            local t = groupToTable[grp.group]
            if t then t[#t + 1] = s end
        end
        if grp.subGroups then
            for _, sg in ipairs(grp.subGroups) do
                local t = subFieldToTable[sg.field]
                CB_EachLeafStrategy(sg.strategies, function(s)
                    mapTokens(s)
                    if t then t[#t + 1] = s end
                end)
            end
        end
    end
end

-- ============================================================
-- Non-combat strategy definitions
--
-- Same grouped format as NS.STRATEGIES and NS.CLASS_STRATEGIES.
-- NS.NC_GENERAL_STRATEGIES is derived below; the UI uses it directly.
-- ============================================================
NS.NC_STRATEGIES = {
    {
        header = "General",
        group  = "general",
        column = "left",
        strategies = {
            { cmd = "food", field = "useFood",   name = "Eat & Drink", desc = "Automatically eat and drink when low on health or mana", default = true },
            { cmd = "pvp",  field = "enablePVP", name = "Enable PvP",  desc = "Enable PvP mode — bot will flag for PvP and engage enemy players", default = true },
        },
    },
    {
        -- Out-of-combat movement. A fresh bot defaults to Follow here
        -- (AiFactory::AddDefaultNonCombatStrategies). Parsed from nc? into entry.nonCombat.
        header       = "Movement",
        group        = "movement",
        column       = "left",
        type         = "dropdown",
        noneLabel    = "Free Roam",
        defaultField = "mFollow",
        strategies   = NS.MOVEMENT_STRATEGIES,
    },
    {
        header = "Loot & Gather",
        group  = "lootGather",
        column = "right",
        strategies = {
            { cmd = "loot",   field = "autoLoot",   name = "Auto Loot",   desc = "Automatically loot nearby corpses after combat", default = true },
            { cmd = "gather", field = "autoGather", name = "Auto Gather", desc = "Automatically gather nearby nodes after combat", default = true },
        },
    },
}

NS.NC_STRATEGY_MAP      = {}
NS.NC_GENERAL_STRATEGIES = {}
do
    local groupToTable = {
        general      = NS.NC_GENERAL_STRATEGIES,
    }
    for _, grp in ipairs(NS.NC_STRATEGIES) do
        for _, s in ipairs(grp.strategies) do
            NS.NC_STRATEGY_MAP[s.cmd] = s.field
            local t = groupToTable[grp.group]
            if t then t[#t + 1] = s end
        end
    end
end

-- ============================================================
-- Default state constructors
--
-- Seeds mirror the server's UNCONDITIONAL defaults (AiFactory.cpp) so a freshly
-- discovered bot shows correct toggle state before its first co?/nc? query lands:
--   - a strategy entry with `default = true` seeds on,
--   - a group's `defaultField` seeds that exclusive-dropdown field on.
-- Only spec/config-independent defaults are mirrored (follow/food/loot/gather/pvp/boost);
-- spec- or config-gated ones (avoid aoe, save mana, tank face, role, class buffs) are left
-- off and corrected by the authoritative reply. These are transient initial values only.
-- ============================================================
---@return table  A fresh combat-strategy state table with server-aligned defaults.
NS.CB_DefaultCombat = function()
    local t = {}
    for _, grp in ipairs(NS.STRATEGIES) do
        for _, s in ipairs(grp.strategies) do t[s.field] = s.default or nil end
        if grp.defaultField then t[grp.defaultField] = true end
        if grp.subGroups then
            for _, sg in ipairs(grp.subGroups) do
                CB_EachLeafStrategy(sg.strategies, function(s) t[s.field] = s.default or nil end)
            end
        end
    end
    return t
end

---@return table  A fresh non-combat-strategy state table with server-aligned defaults.
NS.CB_DefaultNonCombat = function()
    local t = {}
    for _, grp in ipairs(NS.NC_STRATEGIES) do
        for _, s in ipairs(grp.strategies) do t[s.field] = s.default or nil end
        if grp.defaultField then t[grp.defaultField] = true end
    end
    return t
end

-- Parse a comma-separated strategy reply into a { field = bool } table.
-- `map` is token(cmd) -> field. Every field present in `map` is seeded
-- false, then any token found in the message (after an optional "Label: "
-- prefix) flips its field true.
---@param msg string  Whisper reply text to scan for strategy tokens.
---@param map table   Token→field lookup; matched fields are set true/false in the result.
local function CB_ParseTokens(msg, map)
    local result = {}
    for _, field in pairs(map) do result[field] = false end
    if not msg or msg == "" then return result end
    local colon = strfind(msg, ":", 1, true)
    local list  = colon and strsub(msg, colon + 1) or msg
    for token in gmatch(list, "[^,]+") do
        token = token:match("^%s*(.-)%s*$")
        local field = map[token]
        if field then result[field] = true end
    end
    return result
end

-- Parse a bot whisper response to "co ?".
---@param msg string  The bot's "co ?" reply text.
---@return table       Combat-strategy state parsed from the reply.
NS.CB_ParseCombatStr = function(msg)
    return CB_ParseTokens(msg, NS.STRATEGY_MAP)
end

-- Parse a bot whisper response to "nc ?".
---@param msg string  The bot's "nc ?" reply text.
---@return table       Non-combat-strategy state parsed from the reply.
NS.CB_ParseNonCombatStr = function(msg)
    return CB_ParseTokens(msg, NS.NC_STRATEGY_MAP)
end

-- ============================================================
-- Class-specific data helpers
-- (NS.CLASS_STRATEGIES is defined in ClassData.lua, which loads after
--  this file. These helpers are only called at event time, so the forward
--  reference resolves before first use.)
-- ============================================================

-- Returns a fresh classData table for a given class.
---@param class string  Class token (e.g. "WARRIOR").
---@return table         Default class-strategy state for that class.
NS.CB_DefaultClassData = function(class)
    local result = { combat = {}, nonCombat = {} }
    local cs = NS.CLASS_STRATEGIES and NS.CLASS_STRATEGIES[class]
    if not cs then return result end
    if cs.combat then
        for _, group in ipairs(cs.combat) do
            for _, s in ipairs(group.strategies) do
                result.combat[s.field] = nil
            end
        end
    end
    if cs.nonCombat then
        for _, group in ipairs(cs.nonCombat) do
            for _, s in ipairs(group.strategies) do
                result.nonCombat[s.field] = nil
            end
        end
    end
    return result
end

-- Parse a co? or nc? response for class-specific strategy tokens.
-- section: "combat" or "nonCombat"
-- Returns { field = bool } for every strategy in that section.
---@param msg     string  The bot's class-strategy reply text.
---@param class   string  Class token (e.g. "WARRIOR").
---@param section string  Which class section the reply belongs to.
---@return table          Class-strategy state parsed from the reply.
NS.CB_ParseClassStr = function(msg, class, section)
    local cs = NS.CLASS_STRATEGIES and NS.CLASS_STRATEGIES[class]
    if not cs or not cs[section] then return {} end

    local map = {}
    for _, group in ipairs(cs[section]) do
        -- Skip whisper groups (talent-spec premades): their cmds are "talents spec"
        -- names that never appear in co?/nc? replies, so including them here would
        -- seed their fields false on every reconcile — stomping the talent dropdown.
        -- Those fields are owned by CB_SyncTalentSpec (inspect-derived) and user clicks.
        if not group.whisper then
            for _, s in ipairs(group.strategies) do
                map[s.cmd] = s.field
            end
        end
    end
    return CB_ParseTokens(msg, map)
end

-- ============================================================
-- Strategy storage helpers (shared by bridge GET~STATES and
-- the no-bridge co?/nc? whisper read paths)
-- ============================================================

-- Dev mismatch check: after an authoritative re-read reconciles the bot's real
-- state, compare the expectations recorded by CB_SendStrategyToggle (the optimistic
-- UI guess) against what actually parsed, and print any divergence. Only runs when
-- /cbdebug verify is on; pops entry.stratExpect[section] either way so it doesn't
-- carry over. Each field may live in the general (entry[section]) or class-specific
-- (entry.classData[section]) table, so check both.
---@param entry   table   The reconciled bot roster entry.
---@param section string  "combat" or "nonCombat".
local function CB_VerifyStrategyExpect(entry, section)
    local expect = entry.stratExpect and entry.stratExpect[section]
    if not expect then return end
    entry.stratExpect[section] = nil
    if not NS.debugVerify then return end

    local general  = entry[section]
    local classSec = entry.classData and entry.classData[section]
    for field, want in pairs(expect) do
        local got = general and general[field]
        if got == nil and classSec then got = classSec[field] end
        if got ~= want then
            NS.CB_Print(string.format("|cffff4444[verify]|r %s  %s.%s: expected %s, got %s",
                entry.name or "?", section, field, tostring(want), tostring(got)))
        end
    end
end

-- Parses a combat strategy string into entry.combat + entry.classData.combat.
---@param entry     table   The bot roster entry to store parsed flags on.
---@param combatStr string  The bot's "co ?" reply text.
NS.CB_StoreCombat = function(entry, combatStr)
    if not entry then return end
    entry.combat = NS.CB_ParseCombatStr(combatStr)
    if not entry.classData then entry.classData = NS.CB_DefaultClassData(entry.class) end
    entry.classData.combat = NS.CB_ParseClassStr(combatStr, entry.class, "combat")
    CB_VerifyStrategyExpect(entry, "combat")
end

-- Parses a non-combat strategy string into entry.nonCombat + entry.classData.nonCombat.
---@param entry table   The bot roster entry to store parsed flags on.
---@param ncStr string  The bot's "nc ?" reply text.
NS.CB_StoreNonCombat = function(entry, ncStr)
    if not entry then return end
    entry.nonCombat = NS.CB_ParseNonCombatStr(ncStr)
    if not entry.classData then entry.classData = NS.CB_DefaultClassData(entry.class) end
    entry.classData.nonCombat = NS.CB_ParseClassStr(ncStr, entry.class, "nonCombat")
    CB_VerifyStrategyExpect(entry, "nonCombat")
end
