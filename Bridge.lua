-- ============================================================
-- Bridge.lua  —  MBOT bridge / playerbot protocol layer.
--
-- Owns the handshake, debounced sync, no-bridge whisper discovery,
-- linked-account fetch, inventory fetch, quest fetch, the event
-- handler that parses ROSTER~ / DETAIL~ / STATE~ / INV_* / QUESTS_*
-- addon messages plus the co?/nc? whisper replies, and the item-link
-- cleaning helper used before sending links over bot commands.
-- ============================================================
local NS = CleanBotNS

-- URL-decode a percent-encoded string (e.g. quest names from the bridge).
-- Converts %XX hex sequences to their ASCII characters.
---@param s string  Percent-encoded string.
---@return string   The decoded string.
local function CB_UrlDecode(s)
    return (s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

-- Returns the clean API item link for a raw item link (which may carry colour
-- codes and extra enchant/gem fields that confuse the server-side parser).
-- Strips to the item ID and re-fetches a canonical link from the client cache via
-- GetItemInfo, falling back to the raw link on a cache miss.
-- Use this before sending any item link over a bot command (give/equip/etc.).
---@param rawLink string  The raw item link (may carry extra fields).
---@return string         The canonical client-cache link, or rawLink on a cache miss.
NS.CB_CleanItemLink = function(rawLink)
    local itemId = strmatch(rawLink, "item:(%d+)")
    local _, apiLink = GetItemInfo(tonumber(itemId) or 0)
    return apiLink or rawLink
end

-- ============================================================
-- Bot discovery / roster helpers
-- These support bot identification and class resolution during the
-- handshake and STATE~ packet handling below, so they live alongside the
-- discovery state and probing logic. Called at event time, so they may
-- reference helpers defined in earlier-loading files (CB_GroupInfo).
-- ============================================================

-- Tests whether a unit token belongs to a tracked playerbot.
---@param unit string  Unit token to test (e.g. "party1").
---@return boolean      Whether the unit is a tracked playerbot.
NS.CleanBot_IsBot = function(unit)
    local name = UnitName(unit)
    if not name then return false end
    if CleanBot_PartyBots[strlower(name)] then return true end
    return false
end

-- Returns the group unit id ("partyN" or "raidN") whose name matches, or nil.
-- Walks the raid roster when in a raid, the party roster otherwise.
---@param name string  Character name to locate in the party/raid.
---@return string|nil   The matching unit token (e.g. "party2" / "raid5"), or nil.
NS.CB_FindPartyUnit = function(name)
    local prefix, n = NS.CB_GroupInfo()
    for i = 1, n do
        local unit = prefix .. i
        if UnitName(unit) == name then return unit end
    end
    return nil
end

-- Resolves a bot's class token from the live party roster (authoritative),
-- falling back to the supplied value (or WARRIOR) when the unit isn't found.
---@param name     string  Character name to resolve the class for.
---@param fallback string? Class token to return when resolution fails.
---@return string|nil       The resolved class token, or fallback.
NS.CB_ResolveClass = function(name, fallback)
    local unit = NS.CB_FindPartyUnit(name)
    if unit then
        local _, class = UnitClass(unit)
        if class then return class end
    end
    return fallback or "WARRIOR"
end

-- ============================================================
-- Bridge / handshake state
-- ============================================================
NS.lastRawStates = nil
NS.lastHelloAck  = nil
NS.bridgeReady   = false

-- Bridge availability: "unknown" until detection resolves, then "present"
-- (HELLO_ACK received) or "absent" (detection timed out). Drives whether
-- strategy reads use GET~STATES (bridge) or co?/nc? whispers (no bridge).
NS.bridgeState   = "unknown"
NS.probed        = {}   -- name-key -> true: party member already probed for bot-hood
NS.awaitingProbe = {}   -- name-key -> true: probe co? sent, awaiting a "Strategies:" reply

-- Debug overrides — both are nil/false by default and are toggled via /cbdebug.
-- nil = auto (follow real handshake); "present" or "absent" = forced override.
NS.debugBridgeOverride = nil   ---@type string|nil
-- When true, CB_SendBotCommand prints commands to chat instead of sending them.
NS.debugSimulate       = false ---@type boolean
-- When true, strategy toggles log any optimistic-vs-actual mismatch after the
-- authoritative state comes back (see CB_SendStrategyToggle / CB_VerifyStrategyExpect).
NS.debugVerify         = false ---@type boolean

-- No-bridge login gating: on a fresh login (not a /reload) bots may not be
-- online yet, so we block CB_ProbePartyForBots until bridge detection
-- resolves. "Hello!" whispers from bots are buffered here and flushed once
-- the bridge is declared absent.
NS.loginPhaseActive = false  -- true only on fresh login, cleared when detection resolves
NS.pendingHello     = {}     -- name-key -> display-name: buffered "Hello!" senders

-- ============================================================
-- Linked accounts  (populated by .playerbots account linkedAccounts)
-- ============================================================
NS.linkedAccounts            = {}
NS.awaitingLinkedAccounts    = false  -- true = waiting for "Linked accounts:" header
NS.collectingLinkedAccounts  = false  -- true = reading "- NAME" lines

NS.CleanBot_FetchLinkedAccounts = function()
    NS.linkedAccounts           = {}
    NS.awaitingLinkedAccounts   = true
    NS.collectingLinkedAccounts = false
    SendChatMessage(".playerbots account linkedAccounts", "SAY")
end

-- ============================================================
-- Debounced bridge sync + UI refresh
-- ============================================================
NS.syncPending = false

-- No-bridge discovery: whisper "co ?" to each group member (party or raid)
-- exactly once. Only members that reply with a "Strategies: " line are treated
-- as bots (handled in the CHAT_MSG_WHISPER branch). Humans never respond, so
-- they are probed a single time and then ignored.
-- Skipped during loginPhaseActive — bots may not be online yet on fresh
-- login; the "Hello!" path gates probing until each bot announces itself.
local function CB_ProbePartyForBots()
    if NS.loginPhaseActive then return end

    -- Forget probe records for members who have left, so a rejoin re-probes.
    local present = {}
    NS.CB_ForEachGroupMember(function(unit, nm)
        if nm then present[strlower(nm)] = true end
    end)
    for k in pairs(NS.probed) do
        if not present[k] then NS.probed[k] = nil; NS.awaitingProbe[k] = nil end
    end

    NS.CB_ForEachGroupMember(function(unit, nm)
        if nm and UnitIsPlayer(unit) then
            local key = strlower(nm)
            if not CleanBot_PartyBots[key] and not NS.probed[key] then
                NS.probed[key]        = true
                NS.awaitingProbe[key] = true
                NS.CB_SendBotCommand(nm, "co ?")
            end
        end
    end)
end

-- ============================================================
-- Self-bot management
-- ============================================================
-- mod-playerbots can register the player's own character as a bot. The authoritative
-- live signal is the server's "Enable/Disable player botAI" system message (parsed in
-- the CHAT_MSG_SYSTEM handler), which fires however the toggle happens — addon, login
-- auto-enable, or a manually typed `.playerbot bot self`. CB_SetSelfBotActive applies
-- that live state on the addon side; it never sends the toggle command itself (that is
-- a pure server toggle, sent only once on a fresh login — see PLAYER_ENTERING_WORLD).
--
-- NS.selfBotActive  = live state (driven by the messages; persisted only for reload).
-- NS.manageSelf     = auto-enable-on-login preference (Settings checkbox / first-time popup).

--- Applies the player's live self-bot state on the addon side (no command is sent).
--- active=true seeds the player as a known bot, reads real strategies, and surfaces them
--- in the lists; active=false drops them. Persists the state for /reload recovery.
---@param active boolean  Whether the player is currently a self-bot.
NS.CB_SetSelfBotActive = function(active)
    active = active and true or false
    NS.selfBotActive = active
    if CleanBot_SavedVars then CleanBot_SavedVars.selfBotActive = active end

    local name = UnitName("player")
    local key  = name and strlower(name)

    if active and key then
        -- Seed a known-bot entry (same shape as the ROSTER~ handler) so the player counts
        -- as a bot regardless of bridge state. Class comes from the client (always known).
        if not CleanBot_PartyBots[key] then
            local _, class = UnitClass("player")
            class = class or "WARRIOR"
            CleanBot_PartyBots[key] = {
                name      = name,
                class     = class,
                combat    = NS.CB_DefaultCombat(),
                nonCombat = NS.CB_DefaultNonCombat(),
                classData = NS.CB_DefaultClassData(class),
            }
        end

        -- Now that we're a live self-bot, resolve the bridge if it hasn't yet (the gate
        -- keys off NS.selfBotActive, so a self-whisper handshake can run solo).
        if NS.bridgeState == "unknown" and NS.CB_StartBridgeDetection then
            NS.CB_StartBridgeDetection()
        end

        -- Read the player's actual strategies. A bare "co ?" (awaitingCo, NOT coVerifyOnly)
        -- stores the combat reply then chains "nc ?" — a full read, same as the probe path.
        -- Always whispers (queries are never bridged), and self-whisper works here.
        local entry = CleanBot_PartyBots[key]
        if entry then
            entry.awaitingCo = true
            NS.CB_SendBotCommand(name, "co ?")
        end
    elseif key then
        CleanBot_PartyBots[key] = nil
    end

    if CleanBotFrame:IsShown() and NS.CleanBot_RefreshTabs then
        NS.CleanBot_RefreshTabs()
    end
end

-- ============================================================
-- Bridge allowlists — mirror of MultiBotBridge.cpp IsAllowed*()
-- Source: https://github.com/Wishmaster117/mod-multibot-bridge/blob/main/src/MultiBotBridge.cpp
-- Keep in sync with the server when the bridge is updated.
-- ============================================================

-- RUN~COMBAT — IsAllowedCombatCommand()
local BRIDGE_COMBAT_CMDS = {
    ["CO +FOCUS"]           = true,
    ["CO -FOCUS"]           = true,
    ["CO +DPS ASSIST"]      = true,
    ["CO -DPS ASSIST"]      = true,
    ["CO +AOE"]             = true,
    ["CO -AOE"]             = true,
    ["CO +DPS AOE"]         = true,
    ["CO -DPS AOE"]         = true,
    ["CO +TANK ASSIST"]     = true,
    ["CO -TANK ASSIST"]     = true,
    ["CO +AVOID AOE"]       = true,
    ["CO -AVOID AOE"]       = true,
    ["CO +SAVE MANA"]       = true,
    ["CO -SAVE MANA"]       = true,
    ["CO +THREAT"]          = true,
    ["CO -THREAT"]          = true,
    ["CO +BEHIND"]          = true,
    ["CO -BEHIND"]          = true,
    ["CO +WAIT FOR ATTACK"] = true,
    ["CO -WAIT FOR ATTACK"] = true,
    -- "wait for attack time N" (N = 0–60) handled via pattern below
}

-- RUN~LOOT — IsAllowedLootCommand()  (case-sensitive after trim)
local BRIDGE_LOOT_CMDS = {
    ["nc +loot"] = true,
    ["nc -loot"] = true,
    ["ll all"]   = true,
    ["ll normal"] = true,
    ["ll gray"]  = true,
    ["ll quest"] = true,
    ["ll skill"] = true,
}

-- RUN~RTI — IsAllowedRTIIcon()
local BRIDGE_RTI_ICONS = {
    ["STAR"]     = true,
    ["CIRCLE"]   = true,
    ["DIAMOND"]  = true,
    ["TRIANGLE"] = true,
    ["MOON"]     = true,
    ["SQUARE"]   = true,
    ["CROSS"]    = true,
    ["SKULL"]    = true,
}

---@param command string  The bot command being routed.
---@return string|nil      The bridge opcode ("COMBAT"/"POSITION"/"LOOT"/"RTI") or nil to whisper.
local function CB_GetBridgeOpcode(command)
    -- COMBAT: static set
    if BRIDGE_COMBAT_CMDS[strupper(command)] then return "COMBAT" end

    -- COMBAT: "wait for attack time N" — no "co" prefix, N must be 0–60
    local n = strmatch(command, "^[Ww][Aa][Ii][Tt]%s+[Ff][Oo][Rr]%s+[Aa][Tt][Tt][Aa][Cc][Kk]%s+[Tt][Ii][Mm][Ee]%s+(%d+)$")
    if n and tonumber(n) <= 60 then return "COMBAT" end

    -- POSITION: "disperse disable" or "disperse set N" (0 < N ≤ 100)
    local lower = strlower(command)
    if lower == "disperse disable" then return "POSITION" end
    local dval = strmatch(lower, "^disperse set%s+(.+)$")
    if dval then
        local v = tonumber(dval)
        if v and v > 0 and v <= 100 then return "POSITION" end
    end

    -- LOOT: static set (case-sensitive)
    if BRIDGE_LOOT_CMDS[command] then return "LOOT" end

    -- RTI: "attack/pull rti target", "rti <icon>", "rti cc <icon>"
    local upper = strupper(command)
    if upper == "ATTACK RTI TARGET" or upper == "PULL RTI TARGET" then return "RTI" end
    local rtiIcon = strmatch(upper, "^RTI%s+(%S+)$")
    if rtiIcon and BRIDGE_RTI_ICONS[rtiIcon] then return "RTI" end
    local rtiCCIcon = strmatch(upper, "^RTI%s+CC%s+(%S+)$")
    if rtiCCIcon and BRIDGE_RTI_ICONS[rtiCCIcon] then return "RTI" end

    return nil
end

-- Returns the effective bridge state, respecting NS.debugBridgeOverride.
-- Use this instead of reading NS.bridgeState directly inside CB_SendBotCommand
-- so that /cbdebug bridge on/off can exercise both code paths without a real bridge.
local function CB_EffectiveBridgeState()
    return NS.debugBridgeOverride or NS.bridgeState
end

-- Sends a bridge addon packet on the correct channel:
--   • In a raid  → "RAID"   ("PARTY" does not reach raid members)
--   • In a party → "PARTY"
--   • Solo + self-management on → "WHISPER" to self. The server bridge replies directly
--     to the sender (player->SendDirectMessage in MultiBotBridge.cpp) and its chat hook
--     fires on the whisper overload regardless of recipient, so a self-whisper completes
--     the handshake and carries all GET~/RUN~ traffic with no group present.
--   • Solo without self-management → no bots to talk to, so this no-ops.
local function CB_SendBridge(msg)
    if GetNumRaidMembers() > 0 then
        SendAddonMessage("MBOT", msg, "RAID")
    elseif GetNumPartyMembers() > 0 then
        SendAddonMessage("MBOT", msg, "PARTY")
    elseif NS.selfBotActive then
        SendAddonMessage("MBOT", msg, "WHISPER", UnitName("player"))
    end
end

-- Sends a command to a bot. Routes through the bridge (silent, no whisper
-- spam) when the bridge is present and the command is allowlisted; falls back
-- to a whisper for everything else or when bridge is absent. Safe to use for
-- all commands including queries — unlisted commands always whisper, so
-- replies still arrive normally via CHAT_MSG_WHISPER.
--
-- When NS.debugSimulate is true the command is printed to chat instead of
-- sent, and when NS.debugBridgeOverride is set it overrides the real bridge
-- state — both are toggled via /cbdebug.
---@param botName string  Target bot's name (whisper recipient / bridge BOT field).
---@param command string  The command text to run.
NS.CB_SendBotCommand = function(botName, command)
    if NS.debugSimulate then
        NS.CB_Print("|cff888888[simulate]|r → " .. botName .. ": " .. command)
        return
    end
    if CB_EffectiveBridgeState() == "present" then
        local opcode = CB_GetBridgeOpcode(command)
        if opcode then
            CB_SendBridge("RUN~" .. opcode .. "~BOT~" .. botName .. "~~" .. command)
            return
        end
    end
    SendChatMessage(command, "WHISPER", nil, botName)
end

NS.CB_RequestSync = function()
    if NS.syncPending then return end
    NS.syncPending = true
    NS.CB_After(0.5, function()
        NS.syncPending = false
        if CB_EffectiveBridgeState() == "present" then
            CB_SendBridge("GET~ROSTER")
            CB_SendBridge("GET~DETAILS")
            CB_SendBridge("GET~STATES")
        elseif CB_EffectiveBridgeState() == "absent" then
            CB_ProbePartyForBots()
        end
        if CleanBotFrame:IsShown() then
            NS.CleanBot_RefreshTabs()
        end
    end)
end

--- Convenience wrapper: kicks off a debounced roster/details/states sync.
NS.CB_RequestRosterThenRefresh = function()
    NS.CB_RequestSync()
end

-- Lightweight, debounced strategy-state re-sync (bridge path). Unlike
-- CB_RequestSync it sends ONLY GET~STATES — no ROSTER/DETAILS and no RefreshTabs —
-- so it reconciles strategy flags (via the STATE~ handler → CB_StoreCombat/
-- CB_StoreNonCombat → CB_UpdateTabData) without tab/inspect churn. Used to verify a
-- strategy toggle silently after sending it over the bridge.
NS.statesPending = false
NS.CB_RequestStates = function()
    if NS.statesPending then return end
    NS.statesPending = true
    NS.CB_After(0.4, function()
        NS.statesPending = false
        if CB_EffectiveBridgeState() == "present" then
            CB_SendBridge("GET~STATES")
        end
    end)
end

-- Sends a combat/non-combat strategy toggle, then arranges an authoritative
-- re-read so the optimistic UI converges to the bot's real state (self-healing).
-- Path-aware to avoid reintroducing bridge whisper spam:
--   bridge present → send the toggle as usual (allowlisted singles stay silent),
--                    then a silent debounced GET~STATES (CB_RequestStates).
--   no bridge      → send the atomic combined form "<prefix> <toggle>,?" so the
--                    bot's "Strategies:" reply (still via CHAT_MSG_WHISPER) reflects
--                    the post-set state; arm awaitingCo/awaitingNc to consume it.
-- expectMap = { [field] = bool } of the toggled strategies; recorded for the
-- /cbdebug verify mismatch check (only when NS.debugVerify is on).
---@param slot      table   The bound slot (resolves the live bot via slot.key/.name).
---@param prefix    string  "co" or "nc".
---@param toggleStr string  Toggle body, e.g. "+focus", "-aoe", "+arms,-fury,-prot".
---@param expectMap table?  field→expected-bool map for the debug mismatch check.
NS.CB_SendStrategyToggle = function(slot, prefix, toggleStr, expectMap)
    local entry = CleanBot_PartyBots[slot.key]

    if entry and NS.debugVerify and expectMap then
        local section = (prefix == "co") and "combat" or "nonCombat"
        entry.stratExpect = entry.stratExpect or {}
        local acc = entry.stratExpect[section] or {}
        for f, v in pairs(expectMap) do acc[f] = v end   -- merge so rapid toggles all check
        entry.stratExpect[section] = acc
    end

    if CB_EffectiveBridgeState() == "present" then
        NS.CB_SendBotCommand(slot.name, prefix .. " " .. toggleStr)
        NS.CB_RequestStates()
    else
        NS.CB_SendBotCommand(slot.name, prefix .. " " .. toggleStr .. ",?")
        if entry then
            if prefix == "co" then
                entry.awaitingCo   = true
                entry.coVerifyOnly = true   -- parse the combat reply but don't chain "nc ?"
            else
                entry.awaitingNc = true
            end
        end
    end
end

-- Finalizes a whisper-path quest collection: swaps the staged quests into the
-- live list and re-renders if the bot's quest frame is open. Shared by the
-- summary-line terminator and the silence-timeout fallback below.
---@param key   string  Bot name-key.
---@param entry table   The bot roster entry being finalized.
local function CB_FinalizeQuestCollection(key, entry)
    entry.awaitingQuests = false
    entry.questTimeout   = 0
    entry.quests         = entry.questStaging or {}
    entry.questStaging   = nil
    local f = NS.botQuestFrames and NS.botQuestFrames[key]
    if f and f:IsShown() and NS.CB_RenderQuests then NS.CB_RenderQuests(key) end
end

-- ============================================================
-- Premade talent-spec list cache  (per class, in-memory)
-- "talents spec list" replies one line per premade: "1. arms pve (51-0-20)"
-- where the name is the exact "talents spec <name>" argument (== dropdown cmd)
-- and (t1-t2-t3) is the per-tree point spread. CB_SyncTalentSpec matches the
-- inspected bot's tree totals against these spreads to identify its premade.
-- ============================================================
NS.premadeSpecs         = {}   -- [class] = { { name = "arms pve", t = {51,0,20} }, ... }
NS.premadeSpecsFetching = {}   -- [class] = true while a list fetch is in flight

-- Whispers "talents spec list" to one bot of the class and arms collection.
-- One fetch per class per session; the reply lines are collected in the
-- CHAT_MSG_WHISPER handler and finalized on 2s silence in invTickFrame.
---@param key   string  Bot name-key of the bot to query.
---@param entry table   The bot roster entry (provides name/class).
NS.CB_FetchSpecList = function(key, entry)
    if not entry or not entry.class then return end
    if NS.premadeSpecs[entry.class] or NS.premadeSpecsFetching[entry.class] then return end
    NS.premadeSpecsFetching[entry.class] = true
    entry.awaitingSpecList = true
    entry.specListTimeout  = 0
    entry.specListStaging  = {}
    NS.CB_SendBotCommand(entry.name, "talents spec list")
end

-- Publishes a collected spec list to the per-class cache and re-runs the
-- pending talent sync that requested it.
---@param key   string  Bot name-key.
---@param entry table   The bot roster entry being finalized.
local function CB_FinalizeSpecList(key, entry)
    entry.awaitingSpecList = false
    entry.specListTimeout  = 0
    if entry.class then
        NS.premadeSpecsFetching[entry.class] = nil
        -- Publish even an empty list so a server with no premades doesn't refetch
        -- on every inspect; the sync just falls back to tree-name display.
        NS.premadeSpecs[entry.class] = entry.specListStaging or {}
    end
    entry.specListStaging = nil
    if NS.CB_SyncTalentSpec then NS.CB_SyncTalentSpec(key) end
end

-- How long a whisper collection waits in SILENCE before declaring itself done.
-- The clock resets on every line received, so this must cover (a) the bot's
-- time-to-first-reply after our query and (b) the max gap between burst lines —
-- NOT the total reply length. Bots reply fast on a healthy server; favour snappy
-- UX when things run smoothly over graceful degradation under lag.
-- Tune with /cbtiming (measures both first-reply latency and inter-line gaps).
-- 0.5 chosen from /cbtiming measurements on a healthy server (2026-06).
NS.WHISPER_SILENCE = 0.5

-- Tick inventory, money, quest, and spec-list timeouts for the whisper path
-- (silence = collection done)
local invTickFrame = CreateFrame("Frame")
invTickFrame:SetScript("OnUpdate", function(self, dt)
    for key, entry in pairs(CleanBot_PartyBots) do
        if entry.awaitingSpecList then
            entry.specListTimeout = (entry.specListTimeout or 0) + dt
            if entry.specListTimeout >= NS.WHISPER_SILENCE then
                CB_FinalizeSpecList(key, entry)
            end
        end

        if entry.awaitingQuests then
            entry.questTimeout = (entry.questTimeout or 0) + dt
            if entry.questTimeout >= NS.WHISPER_SILENCE then
                CB_FinalizeQuestCollection(key, entry)
            end
        end

        if entry.awaitingInventory then
            entry.invTimeout = (entry.invTimeout or 0) + dt
            if entry.invTimeout >= NS.WHISPER_SILENCE then
                entry.awaitingInventory = false
                entry.invTimeout        = 0

                -- Whisper path only (marked by invStaging): atomically swap the
                -- freshly-staged items in (replacing the preserved stale set) so
                -- a refresh updates cleanly, then fetch money/bag separately so
                -- its reply arrives on its own and isn't swallowed here.
                -- On the bridge path invStaging is nil and INV_END has normally
                -- already rendered; this branch is just a safety-net flag clear.
                if entry.invStaging then
                    if entry.inventory then
                        entry.inventory.items = entry.invStaging or {}
                    end
                    entry.invStaging     = nil
                    -- Inventory just changed (e.g. Sell Trash) — force past the TTL so the
                    -- bag/money totals reflect the new state (in-flight dedup still applies).
                    NS.CB_FetchStats(entry, true)
                end

                local f = NS.botInventoryFrames and NS.botInventoryFrames[key]
                if f and f:IsShown() then
                    NS.CB_RenderInventory(key)
                elseif f and NS.CB_SetInventoryLoading then
                    NS.CB_SetInventoryLoading(f, false)
                end
            end
        end

        if entry.awaitingMoney then
            entry.moneyTimeout = (entry.moneyTimeout or 0) + dt
            if entry.moneyTimeout >= NS.WHISPER_SILENCE then
                entry.awaitingMoney  = false
                entry.moneyTimeout   = 0
            end
        end
    end
end)

---@param key     string  Bot name-key (lowercased lookup key).
---@param botName string  Bot's display name (whisper/bridge target).
NS.CB_FetchInventory = function(key, botName)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    -- Preserve existing inventory while the fresh fetch is in flight so the
    -- frame can display stale-but-correct data instead of going blank.
    entry.inventory = entry.inventory or { items = {} }

    -- In-flight flag drives the loading overlay; set on BOTH paths so the
    -- indicator is path-agnostic. Cleared in CB_RenderInventory when data lands
    -- (or by the silence-timeout tick below as a safety net).
    entry.awaitingInventory = true
    entry.invTimeout        = 0

    -- Overlay policy: always for a first (empty) load, but for a refresh of an
    -- already-rendered grid only on the whisper path — bridge refreshes are
    -- near-instant, so a "Refreshing..." flash there is distracting noise.
    -- CB_RenderInventory consults this flag when reflecting the in-flight state.
    local invF = NS.botInventoryFrames and NS.botInventoryFrames[key]
    entry.invOverlay = (not (invF and invF.rendered))
        or CB_EffectiveBridgeState() ~= "present"
    if invF and invF:IsShown() and entry.invOverlay and NS.CB_SetInventoryLoading then
        NS.CB_SetInventoryLoading(invF, true)
    end

    if CB_EffectiveBridgeState() == "present" then
        CB_SendBridge("GET~INVENTORY~" .. botName .. "~inv")
    else
        -- invStaging is the whisper-path marker: its presence tells the tick
        -- below to run the whisper finalize (swap + stats fetch) rather than
        -- just clearing the flag.
        -- Collect fresh item replies into a staging table rather than appending
        -- to entry.inventory.items directly. The live items are preserved for
        -- the stale-display-during-flight render and only replaced (atomically)
        -- once collection completes, so a refresh updates instead of duplicating.
        entry.invStaging        = {}
        NS.CB_SendBotCommand(botName, "items")
    end
end

-- How long a fetched "stats" reply is considered fresh. Re-selecting a bot within this
-- window reuses the cached money/XP/durability instead of re-whispering; older revisits
-- refetch so the values stay reasonably current.
NS.STATS_TTL = 30  -- seconds

-- Fetches a bot's "stats" reply (money, bag totals, durability, XP). The reply is
-- parsed in the awaitingMoney branch of CHAT_MSG_WHISPER (below). "stats" is a query,
-- so it always whispers (never allowlisted) and the reply returns via CHAT_MSG_WHISPER
-- regardless of CB_EffectiveBridgeState() — no override gating needed. This is the
-- single source of truth for the "stats" whisper: the inventory-finalize tick and the
-- on-demand XP-bar fetch both route through here.
--
-- Two guards keep this from spamming a bot (mirrors CB_FetchSpecList's guard pattern):
--   • in-flight dedup — never stack a second "stats" while one is awaiting a reply. This
--     collapses the post-login RefreshTabs→SelectBot burst that previously hammered the
--     first bot once per frame.
--   • TTL freshness — skip the refetch when the cached reply is younger than STATS_TTL,
--     so re-selecting a recently-viewed bot reuses the cache. Pass force=true to bypass
--     the TTL (e.g. after an inventory change that may have altered bag/money); the
--     in-flight dedup still applies.
---@param entry table   The CleanBot_PartyBots entry to refresh.
---@param force boolean? Bypass the TTL freshness check (still respects in-flight dedup).
NS.CB_FetchStats = function(entry, force)
    if not entry or not entry.name then return end
    if entry.awaitingMoney then return end
    if not force and entry.statsAt and (GetTime() - entry.statsAt) < NS.STATS_TTL then
        return
    end
    entry.awaitingMoney = true
    entry.moneyTimeout  = 0
    SendChatMessage("stats", "WHISPER", nil, entry.name)
end

---@param key     string  Bot name-key (lowercased lookup key).
---@param botName string  Bot's display name (whisper/bridge target).
NS.CB_RequestInventory = function(key, botName)
    NS.CB_FetchInventory(key, botName)
    NS.CB_ToggleInventory(key, botName)
end

-- Fetches the quest log for a bot. Bridge path sends a structured GET~QUESTS
-- request; the QUESTS_BEGIN/ITEM/END packets are handled below in the
-- CHAT_MSG_ADDON block. Whisper fallback sends "quests" and parses the reply
-- lines in the CHAT_MSG_WHISPER handler into the same { {id, status} } shape.
-- The live entry.quests is intentionally NOT cleared here: the bridge path
-- resets it on QUESTS_BEGIN, and the whisper path swaps fresh data in on
-- finalize (CB_FinalizeQuestCollection) — so the last render survives on screen
-- until the new list is ready.
---@param key     string  Bot name-key (lowercased lookup key).
---@param botName string  Bot's display name (whisper/bridge target).
NS.CB_FetchQuests = function(key, botName)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    if CB_EffectiveBridgeState() == "present" then
        CB_SendBridge("GET~QUESTS~ALL~" .. botName .. "~quests")
    else
        -- Whisper path: collect the "quests" reply lines into staging, keyed by
        -- section header (Incompleted/Completed). Swapped in on the summary line
        -- or after 3s of silence (invTickFrame).
        entry.awaitingQuests = true
        entry.questTimeout   = 0
        entry.questStatus    = "I"   -- current section; flipped by reply headers
        entry.questStaging   = {}
        -- "quests all" (not bare "quests", which only prints the summary) makes the
        -- bot stream the per-quest lines + section headers we parse — mirrors the
        -- bridge's GET~QUESTS~ALL mode.
        NS.CB_SendBotCommand(botName, "quests all")
    end
end

-- ============================================================
-- Bridge handshake
-- ============================================================
local function CB_BridgeRequest()
    NS.CB_RequestSync()
end

local function CB_SendHello()
    -- CB_SendBridge picks the channel (group broadcast, or self-whisper when solo +
    -- selfBotActive), and no-ops when there is nothing to detect against.
    if NS.CB_InGroup() or NS.selfBotActive then
        CB_SendBridge("HELLO~1")
    end
end

-- Sends HELLO and, if no HELLO_ACK arrives within the timeout, declares the
-- bridge absent and switches to no-bridge (whisper) discovery. Only runs while
-- the bridge state is still unknown.
local function CB_StartBridgeDetection()
    if NS.bridgeState ~= "unknown" then return end
    if NS.bridgeDetecting then return end           -- a detection timer is already running
    -- Need either a group to detect against, or an active self-bot (which talks to the
    -- bridge over a self-whisper). Solo with no self-bot has nothing to detect.
    if not NS.CB_InGroup() and not NS.selfBotActive then return end
    NS.bridgeDetecting = true
    CB_SendHello()

    NS.CB_After(3, function()
        NS.bridgeDetecting  = false
        NS.loginPhaseActive = false   -- login gate lifted regardless of outcome
        if NS.bridgeState == "unknown" then
            NS.bridgeState = "absent"
            -- Keep the Debug tab's "Auto (<state>)" label current.
            if NS.CB_RefreshDebugTab then NS.CB_RefreshDebugTab() end

            -- Flush bots that said "Hello!" during detection (fresh login path).
            -- CB_ProbePartyForBots is now unblocked for mid-session joins.
            for key, displayName in pairs(NS.pendingHello) do
                if not CleanBot_PartyBots[key] and not NS.probed[key] then
                    NS.probed[key]        = true
                    NS.awaitingProbe[key] = true
                    NS.CB_SendBotCommand(displayName, "co ?")
                end
            end
            NS.pendingHello = {}

            NS.CB_RequestSync()
        end
    end)
end

-- Exposed so the self-bot toggle can kick off detection the moment it's enabled
-- (the function is idempotent — guards on state / in-progress / nothing-to-detect).
NS.CB_StartBridgeDetection = CB_StartBridgeDetection

-- ============================================================
-- Bridge: listen for MBOT messages and party changes
-- ============================================================
local bridgeFrame = CreateFrame("Frame")
bridgeFrame:RegisterEvent("CHAT_MSG_ADDON")
bridgeFrame:RegisterEvent("CHAT_MSG_WHISPER")
bridgeFrame:RegisterEvent("CHAT_MSG_SYSTEM")
bridgeFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
bridgeFrame:RegisterEvent("RAID_ROSTER_UPDATE")
bridgeFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
bridgeFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
bridgeFrame:RegisterEvent("INSPECT_TALENT_READY")
bridgeFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
bridgeFrame:RegisterEvent("PLAYER_LOGOUT")
bridgeFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_WHISPER" then
        local msg, sender = ...
        local key   = strlower(sender)
        local entry = CleanBot_PartyBots[key]

        -- "Hello!" detection: a bot has just come online (no-bridge, fresh-login path).
        -- We verify the sender is actually in our group to avoid acting on a real player.
        -- "Hello!" is not a Strategies reply, so we return early after handling it.
        if msg == "Hello!" and CB_EffectiveBridgeState() ~= "present" then
            local inParty = false
            NS.CB_ForEachGroupMember(function(unit, nm)
                if nm == sender then inParty = true end
            end)
            if inParty then
                if NS.loginPhaseActive then
                    -- Detection still running: buffer for processing when it resolves.
                    NS.pendingHello[key] = sender
                elseif not CleanBot_PartyBots[key] then
                    -- A bot whispers "Hello!" once it has finished loading into the
                    -- world. Re-probe even if we already probed it: the initial
                    -- discovery probe is often whispered before the bot has spawned,
                    -- so it never replies (leaving probed=true, awaiting=true, but no
                    -- cache entry — exactly what /cbdebug showed). "Hello!" is the
                    -- bot's readiness signal and only bots send it, so re-probing
                    -- here never spams real players.
                    NS.probed[key]        = true
                    NS.awaitingProbe[key] = true
                    NS.CB_SendBotCommand(sender, "co ?")
                end
            end
            return
        end

        -- Spec-list collection: reply lines from "talents spec list", one premade
        -- per line, e.g. "1. arms pve (51-0-20)". Only actual spec lines are consumed
        -- (and reset the silence timeout); any other line falls through to the branches
        -- below. This matters because a "stats" fetch on the same select interleaves its
        -- reply ("… 92/150% XP") with the spec stream — if we returned on every line we
        -- would swallow that stats reply and the XP bar would never populate.
        -- Finalized by the silence tick in invTickFrame (CB_FinalizeSpecList).
        if entry and entry.awaitingSpecList then
            local name, t1, t2, t3 = msg:match("^%s*%d+%.%s+(.-)%s+%((%d+)%-(%d+)%-(%d+)%)%s*$")
            if name then
                entry.specListTimeout = 0
                if entry.specListStaging then
                    entry.specListStaging[#entry.specListStaging + 1] = {
                        name = name,
                        t    = { tonumber(t1), tonumber(t2), tonumber(t3) },
                    }
                end
                return
            end
        end

        -- Inventory collection (whisper path): grab any item link, ignore everything
        -- else. Gated on invStaging (the whisper-only marker) rather than
        -- awaitingInventory, so a bridge-path fetch — which also sets
        -- awaitingInventory but never sends "items" — doesn't swallow unrelated whispers.
        if entry and entry.invStaging then
            if strfind(msg, "|Hitem:", 1, true) then
                local item = NS.CB_ParseItemLine and NS.CB_ParseItemLine(msg)
                if item then
                    local staging = entry.invStaging
                    if staging then staging[#staging + 1] = item end
                end
            end
            entry.invTimeout = 0   -- reset timeout on every whisper from this bot
            return
        end

        -- Money/stats capture (whisper path): reply from "stats" whisper.
        -- The real reply is laced with WoW colour/hyperlink escape codes, e.g.
        --   "2g 34s 56c, |h|cff20ff2012/16|h|cffffffff Bag, |cff...87% (5g 24s)|cffffffff Dur, |cff...45/67%|cffffffff XP"
        -- so we strip the |c / |h / |r escapes first, then parse the cleaned text.
        -- The bag count is FREE/TOTAL (not used/total); convert to used to match
        -- the bridge's INV_SUMMARY semantics (which reports used/total).
        -- Each money denomination is optional (e.g. a broke bot omits gold).
        -- Identify the stats reply by its CONTENT SIGNATURE — it always carries the
        -- "Bag" and "Dur" fields — rather than trusting the awaitingMoney flag alone.
        -- This is essential because other replies (e.g. talent spec-list lines) can
        -- interleave with the stats reply while awaitingMoney is still set; keying off
        -- the flag would mis-parse such a line and clear awaitingMoney prematurely.
        -- Signature matching also rescues a reply that arrives after the 0.5s
        -- WHISPER_SILENCE window has already cleared awaitingMoney (cold bot / slow
        -- round-trip) — otherwise the XP bar would never populate until a warm refetch.
        if entry and strfind(msg, "Bag", 1, true) and strfind(msg, "Dur", 1, true) then
            local clean = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|h", ""):gsub("|r", "")
            local xpCur, xpMax = clean:match("(%d+)/(%d+)%%%s*XP")
            if clean:match("%d+/%d+%s*Bag") then
                entry.moneyTimeout  = 0
                entry.awaitingMoney = false
                entry.statsAt       = GetTime()   -- mark fresh for the CB_FetchStats TTL

                local gold   = tonumber(clean:match("(%d+)g")) or 0
                local silver = tonumber(clean:match("(%d+)s")) or 0
                local copper = tonumber(clean:match("(%d+)c")) or 0
                entry.money  = { gold = gold, silver = silver, copper = copper }

                -- Bag totals are not available from the "items" whisper, but stats gives them.
                local bagFree, bagTotal = clean:match("(%d+)/(%d+)%s*Bag")
                if bagFree and entry.inventory then
                    bagFree  = tonumber(bagFree)
                    bagTotal = tonumber(bagTotal)
                    entry.inventory.bagTotal = bagTotal
                    entry.inventory.bagUsed  = bagTotal - bagFree
                end

                -- Durability and XP are whisper-only — store for future display.
                -- Dur is "N% (repair cost) Dur"; XP is "cur/rest% XP".
                local durPct     = tonumber(clean:match("(%d+)%%%s*%(.-%)%s*Dur"))
                entry.durability = durPct
                entry.xpPercent  = xpCur and (tonumber(xpCur) .. "/" .. tonumber(xpMax)) or nil

                local f = NS.botInventoryFrames and NS.botInventoryFrames[strlower(sender)]
                if f and f:IsShown() then NS.CB_RenderInventory(strlower(sender)) end

                -- XP just landed — repaint the paperdoll XP bar if this bot is live.
                if NS.CB_RefreshXPBarForKey then NS.CB_RefreshXPBarForKey(strlower(sender)) end
                return
            end
        end

        -- Quest list collection (whisper path): reply to the "quests" command.
        -- The bot streams section headers (Incompleted/Completed) then one quest
        -- hyperlink per line, ending with a "--- Summary --- / Total:" line.
        -- Status comes from the active section; the quest ID from the |Hquest:ID:
        -- link. Collected into questStaging, swapped into entry.quests on finalize.
        if entry and entry.awaitingQuests then
            entry.questTimeout = 0
            -- Quest lines carry a |Hquest:ID: link — match that FIRST so a quest
            -- whose title contains "Complete"/"Incomplete" isn't mistaken for a
            -- section header. Headers (no link) only set the current status.
            local id = tonumber(msg:match("|Hquest:(%d+):"))
            if id then
                entry.questStaging[#entry.questStaging + 1] = { id = id, status = entry.questStatus }
            elseif msg:find("Summary", 1, true) or msg:match("^%s*Total:") then
                CB_FinalizeQuestCollection(key, entry)
            elseif msg:find("Incomplet", 1, true) then
                entry.questStatus = "I"
            elseif msg:find("Complet", 1, true) then
                entry.questStatus = "C"
            end
            return
        end

        if strsub(msg, 1, 12) ~= "Strategies: " then return end

        if entry then
            -- Known bot: response to a co?/nc? read (no-bridge mode, or a manual re-read).
            if entry.awaitingCo then
                entry.awaitingCo = false
                entry.class = NS.CB_ResolveClass(sender, entry.class)
                NS.CB_StoreCombat(entry, msg)
                if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key) end
                if entry.coVerifyOnly then
                    -- Combined "co +x,?" verify: consume only the combat reply.
                    entry.coVerifyOnly = nil
                else
                    entry.awaitingNc = true
                    NS.CB_SendBotCommand(entry.name, "nc ?")
                end
            elseif entry.awaitingNc then
                entry.awaitingNc = false
                NS.CB_StoreNonCombat(entry, msg)
                if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key) end
            end

        elseif NS.awaitingProbe[key] then
            -- No-bridge discovery: a probed party member replied, so it IS a bot.
            NS.awaitingProbe[key] = nil
            local class = NS.CB_ResolveClass(sender, "WARRIOR")
            entry = {
                name       = sender,
                class      = class,
                combat     = NS.CB_DefaultCombat(),
                nonCombat  = NS.CB_DefaultNonCombat(),
                classData  = NS.CB_DefaultClassData(class),
                awaitingNc = true,
            }
            CleanBot_PartyBots[key] = entry
            NS.CB_StoreCombat(entry, msg)
            NS.CB_SendBotCommand(sender, "nc ?")
            if CleanBotFrame:IsShown() then NS.CleanBot_RefreshTabs() end
        end
        return

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg = ...
        if prefix ~= "MBOT" then return end

        if msg and strsub(msg, 1, 10) == "HELLO_ACK~" then
            -- HELLO_ACK drives the *real* state machine and is processed even when
            -- the override forces "absent", so /cbdebug bridge reset can restore the
            -- true state. CB_BridgeRequest below re-syncs via the effective path.
            NS.lastHelloAck = msg
            if not NS.bridgeReady then
                NS.bridgeReady      = true
                NS.bridgeState      = "present"
                NS.bridgeDetecting  = false
                NS.loginPhaseActive = false  -- bridge handles discovery; no Hello! gating needed
                NS.pendingHello     = {}
                -- Keep the Debug tab's "Auto (<state>)" label current.
                if NS.CB_RefreshDebugTab then NS.CB_RefreshDebugTab() end
                CB_BridgeRequest()
                NS.CleanBot_FetchLinkedAccounts()
            end

        elseif CB_EffectiveBridgeState() ~= "present" then
            -- Override forces the no-bridge path: ignore all inbound bridge data
            -- packets (ROSTER~/DETAIL~/STATE~/INV_*/QUESTS_*) so the cache is only
            -- ever populated via the whisper discovery path. Without this guard a
            -- real bridge would keep pushing strategy/inventory data and the
            -- "absent" simulation would be incomplete.
            return

        elseif msg and strsub(msg, 1, 7) == "ROSTER~" then
            local name = strmatch(msg, "^ROSTER~([^,]+),")
            if name then
                local key = strlower(name)
                if not CleanBot_PartyBots[key] then
                    CleanBot_PartyBots[key] = {
                        name      = name,
                        class     = "WARRIOR",
                        combat    = NS.CB_DefaultCombat(),
                        nonCombat = NS.CB_DefaultNonCombat(),
                        classData = NS.CB_DefaultClassData("WARRIOR"),
                    }
                end
            end

        elseif msg and strsub(msg, 1, 7) == "DETAIL~" then
            local name, className = strmatch(msg, "^DETAIL~([^~]+)~[^~]+~[^~]+~([^~]+)~")
            if name and className then
                local classKey = strupper(className)
                classKey = gsub(classKey, "%s+", "")
                local key      = strlower(name)
                local existing = CleanBot_PartyBots[key]
                -- Bridge mode: strategy data arrives via GET~STATES (STATE~ packets),
                -- so DETAIL~ only establishes identity/class. Preserve any strategy
                -- data already parsed from an earlier STATE~ packet.
                CleanBot_PartyBots[key] = {
                    name      = name,
                    class     = classKey,
                    combat    = (existing and existing.combat)    or NS.CB_DefaultCombat(),
                    nonCombat = (existing and existing.nonCombat) or NS.CB_DefaultNonCombat(),
                    classData = (existing and existing.classData) or NS.CB_DefaultClassData(classKey),
                    inventory = existing and existing.inventory,
                    money     = existing and existing.money,
                }
            end
            if CleanBotFrame:IsShown() then
                NS.CleanBot_RefreshTabs()
            end

        elseif msg and strsub(msg, 1, 6) == "STATE~" then
            -- Bridge strategy snapshot for one bot: STATE~Name~combat~nonCombat
            -- (combat / nonCombat are comma-separated strategy lists.)
            NS.lastRawStates = msg
            local rest             = strsub(msg, 7)
            local name, r2         = NS.CB_SplitOnce(rest, "~")
            local combatStr, ncStr = NS.CB_SplitOnce(r2,   "~")
            name = name:match("^%s*(.-)%s*$")
            if name and name ~= "" then
                local key   = strlower(name)
                local entry = CleanBot_PartyBots[key]
                if not entry then
                    -- STATE~ arrived before ROSTER~/DETAIL~; create a minimal entry.
                    local class = NS.CB_ResolveClass(name, "WARRIOR")
                    entry = {
                        name      = name,
                        class     = class,
                        combat    = NS.CB_DefaultCombat(),
                        nonCombat = NS.CB_DefaultNonCombat(),
                        classData = NS.CB_DefaultClassData(class),
                    }
                    CleanBot_PartyBots[key] = entry
                else
                    entry.class = NS.CB_ResolveClass(name, entry.class)
                end
                NS.CB_StoreCombat(entry, combatStr)
                NS.CB_StoreNonCombat(entry, ncStr)
                if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key) end
            end

        elseif msg and strsub(msg, 1, 10) == "INV_BEGIN~" then
            local rest = strsub(msg, 11)
            local name = NS.CB_SplitOnce(rest, "~")
            local key  = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry then
                entry.inventory = { items = {} }
            end

        elseif msg and strsub(msg, 1, 12) == "INV_SUMMARY~" then
            local rest              = strsub(msg, 13)
            local name, r2          = NS.CB_SplitOnce(rest, "~")
            local _, r3             = NS.CB_SplitOnce(r2,   "~")  -- skip token
            local gold, r4          = NS.CB_SplitOnce(r3,   "~")
            local silver, r5        = NS.CB_SplitOnce(r4,   "~")
            local copper, r6        = NS.CB_SplitOnce(r5,   "~")
            local bagUsed, bagTotal = NS.CB_SplitOnce(r6,   "~")
            local key   = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry then
                -- Money is a bot attribute, not an inventory item — stored separately
                -- so it can be displayed and accessed independently of the bag grid.
                entry.money = {
                    gold   = tonumber(gold)   or 0,
                    silver = tonumber(silver) or 0,
                    copper = tonumber(copper) or 0,
                }
                if entry.inventory then
                    entry.inventory.bagUsed  = tonumber(bagUsed)  or 0
                    entry.inventory.bagTotal = tonumber(bagTotal) or 0
                end
            end

        elseif msg and strsub(msg, 1, 9) == "INV_ITEM~" then
            local rest      = strsub(msg, 10)
            local name, r2  = NS.CB_SplitOnce(rest, "~")
            local _, encoded = NS.CB_SplitOnce(r2,  "~")   -- skip token
            local key   = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry and entry.inventory then
                local item = NS.CB_ParseItemLine and NS.CB_ParseItemLine(encoded)
                if item then
                    local items = entry.inventory.items
                    items[#items + 1] = item
                end
            end

        elseif msg and strsub(msg, 1, 8) == "INV_END~" then
            local rest = strsub(msg, 9)
            local name = NS.CB_SplitOnce(rest, "~")
            local key  = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry then entry.awaitingInventory = false end   -- bridge data landed
            local f    = NS.botInventoryFrames and NS.botInventoryFrames[key]
            if f and f:IsShown() then
                NS.CB_RenderInventory(key)
            elseif f and NS.CB_SetInventoryLoading then
                NS.CB_SetInventoryLoading(f, false)
            end

        -- ── Quest log packets ────────────────────────────────────────────
        -- Request: GET~QUESTS~ALL~botName~quests
        -- Packets: QUESTS_BEGIN~name~token~mode
        --          QUESTS_ITEM~name~token~mode~status~questID~questName
        --          QUESTS_END~name~token~mode
        -- status = "C" (complete) or "I" (incomplete). questName is URL-encoded.
        elseif msg and strsub(msg, 1, 13) == "QUESTS_BEGIN~" then
            local rest  = strsub(msg, 14)
            local name  = NS.CB_SplitOnce(rest, "~")
            local key   = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry then
                entry.quests = {}
            end

        elseif msg and strsub(msg, 1, 12) == "QUESTS_ITEM~" then
            local rest              = strsub(msg, 13)
            local name,   r2        = NS.CB_SplitOnce(rest, "~")
            local _,      r3        = NS.CB_SplitOnce(r2,   "~")  -- skip token
            local _,      r4        = NS.CB_SplitOnce(r3,   "~")  -- skip mode
            local status, r5        = NS.CB_SplitOnce(r4,   "~")
            local questID = NS.CB_SplitOnce(r5, "~")
            local key   = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry and entry.quests then
                entry.quests[#entry.quests + 1] = {
                    id     = tonumber(questID),
                    status = status,
                }
            end

        elseif msg and strsub(msg, 1, 11) == "QUESTS_END~" then
            local rest = strsub(msg, 12)
            local name = NS.CB_SplitOnce(rest, "~")
            local key  = strlower(name)
            local f    = NS.botQuestFrames and NS.botQuestFrames[key]
            if f and f:IsShown() then
                if NS.CB_RenderQuests then NS.CB_RenderQuests(key) end
            end
        end

    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        -- Self-bot live state: the server prints "Enable/Disable player botAI" on every
        -- toggle (addon, login auto-enable, or a manually typed command). This is the
        -- authoritative source of truth — drive tracking off it rather than assuming.
        local lower = msg and strlower(msg)
        if lower and lower:find("player botai", 1, true) then
            if lower:find("enable", 1, true) then
                -- First-ever detection: offer to set the auto-enable preference (once).
                if CleanBot_SavedVars and not CleanBot_SavedVars.selfBotPromptShown then
                    CleanBot_SavedVars.selfBotPromptShown = true
                    if not NS.manageSelf then StaticPopup_Show("CLEANBOT_SELFBOT_AUTO") end
                end
                NS.CB_SetSelfBotActive(true)
            elseif lower:find("disable", 1, true) then
                NS.CB_SetSelfBotActive(false)
            end
            return
        end

        -- Workaround: ".playerbots bot add/addaccount/login <name>" fails with
        -- "<cmd>: <Name> - player already logged in" when the character is already online —
        -- the server won't pull an online character into the group. Fall back to a normal
        -- party invite. The per-name system line carries the name, so this one handler covers
        -- every bot-add path (Invite by Name / Preset / Login Target / Invite Account, or a
        -- hand-typed command). Match the raw msg to keep the name's casing.
        if msg then
            local onlineName = msg:match("(%S+)%s*%-%s*[Pp]layer already logged in")
            if onlineName then
                InviteUnit(onlineName)
                NS.CB_Print(onlineName .. " was already online \226\128\148 sent a party invite instead.")
                return
            end
        end

        if NS.awaitingLinkedAccounts and msg and strlower(msg):find("linked accounts") then
            -- Header line received — start collecting account entries
            NS.awaitingLinkedAccounts   = false
            NS.collectingLinkedAccounts = true
            NS.linkedAccounts           = {}
        elseif NS.collectingLinkedAccounts then
            local name = msg and msg:match("^%-%s*(%S+)")
            if name then
                NS.linkedAccounts[#NS.linkedAccounts + 1] = name
            else
                -- Non-matching line signals end of the list
                NS.collectingLinkedAccounts = false
            end
        end

    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        -- Either group-roster event drives detection/sync: party APIs read 0 while
        -- in a raid, so RAID_ROSTER_UPDATE is required to detect bots in a raid.
        if NS.bridgeState == "unknown" then
            CB_StartBridgeDetection()
        else
            NS.CB_RequestSync()
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        if NS.individualPanel and NS.individualPanel:IsShown() and NS.CleanBot_RefreshTabs then
            NS.CleanBot_RefreshTabs()
        end

    elseif event == "UNIT_INVENTORY_CHANGED" then
        -- Re-inspect ONLY the currently-viewed bot. Bots re-gear themselves
        -- constantly (looting, auto-equip), so reacting for every bound bot
        -- burns the ~6/10s NotifyInspect throttle and evicts the viewed bot's
        -- single-unit inspect cache — non-viewed bots get fresh data anyway
        -- when selected (SelectBot inspects on every selection).
        local unit = ...
        if unit and NS.tabList and NS.CB_QueueEquipRefresh then
            for _, info in ipairs(NS.tabList) do
                if info.unit == unit and info.key == NS.selectedBotKey then
                    NS.CB_QueueEquipRefresh({{ key = info.key, unit = unit }})
                    break
                end
            end
        end

    elseif event == "INSPECT_TALENT_READY" then
        -- 3.3.5a's inspect-data-ready event (there is no "INSPECT_READY"). Carries
        -- only `success`, not a unit id — Equip.lua maps it to the serialised
        -- in-flight inspect. Equipment is readable immediately once this fires.
        if NS.CB_OnInspectReady then
            NS.CB_OnInspectReady()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- One-shot: reset bridge state at the first world entry (login),
        -- then stop listening so later zone/instance loads don't wipe the cache.
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")

        -- Determine whether this is a fresh login or a /reload.
        -- PLAYER_LOGOUT does not fire on /reload, so sessionActive remaining true
        -- means the last session ended via reload rather than a proper logout.
        local isReload = CleanBot_SavedVars and CleanBot_SavedVars.sessionActive == true
        CleanBot_SavedVars.sessionActive = true

        NS.loginPhaseActive = not isReload  -- gate bot probing on fresh login only
        NS.pendingHello     = {}
        NS.bridgeReady      = false
        NS.bridgeState      = "unknown"
        NS.bridgeDetecting  = false
        -- Keep the Debug tab's "Auto (<state>)" label current.
        if NS.CB_RefreshDebugTab then NS.CB_RefreshDebugTab() end
        NS.probed           = {}
        NS.awaitingProbe    = {}
        CleanBot_PartyBots  = {}

        -- Self-bot live state across the world entry:
        --   Fresh login — the character always spawns with self-bot OFF, so force it off
        --     (overriding any stale persisted value); auto-enable below re-toggles it.
        --   Reload — server state is preserved and no message re-fires, so keep the
        --     persisted NS.selfBotActive (restored at PLAYER_LOGIN) and re-apply it below.
        if not isReload then
            NS.selfBotActive = false
            if CleanBot_SavedVars then CleanBot_SavedVars.selfBotActive = false end
        end

        CB_StartBridgeDetection()
        -- The party/raid roster may not be query-able yet at login, so the call
        -- above can no-op (GetNum*Members == 0) and the roster event may have
        -- already fired during the loading screen. Retry a few times so being
        -- already in a group — especially a raid — is reliably detected.
        -- CB_StartBridgeDetection is idempotent (guards on state / in-progress /
        -- in-group), so extra calls are harmless once detection has begun.
        NS.CB_After(1, CB_StartBridgeDetection)
        NS.CB_After(3, CB_StartBridgeDetection)
        NS.CB_After(6, CB_StartBridgeDetection)

        -- Self-bot enable/restore (delayed so the player is in-world and detection has had
        -- a chance to start). `.playerbot bot self` is a pure toggle and the character
        -- spawns OFF, so it is sent ONLY on a fresh login — never on reload (which would
        -- turn it off). The "Enable player botAI" reply drives CB_SetSelfBotActive.
        if not isReload then
            if NS.manageSelf then
                NS.CB_After(2, function() SendChatMessage(".playerbot bot self", "SAY") end)
            end
        elseif NS.selfBotActive then
            -- Reload while active: re-seed the wiped cache without re-toggling the server.
            NS.CB_After(2, function() NS.CB_SetSelfBotActive(true) end)
        end

    elseif event == "PLAYER_LOGOUT" then
        -- Clear the flag so the next session is treated as a fresh login.
        if CleanBot_SavedVars then
            CleanBot_SavedVars.sessionActive = false
        end
    end
end)
