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

-- Addon-message distribution channel for the player's current group. Bridge
-- packets must go to "RAID" when in a raid — "PARTY" does not reach raid members.
local function CB_GroupChannel()
    return GetNumRaidMembers() > 0 and "RAID" or "PARTY"
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
            SendAddonMessage("MBOT", "RUN~" .. opcode .. "~BOT~" .. botName .. "~~" .. command, CB_GroupChannel())
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
            local ch = CB_GroupChannel()
            SendAddonMessage("MBOT", "GET~ROSTER",  ch)
            SendAddonMessage("MBOT", "GET~DETAILS", ch)
            SendAddonMessage("MBOT", "GET~STATES",  ch)
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

-- Tick inventory, money, and quest timeouts for the whisper path (3s silence = done)
local invTickFrame = CreateFrame("Frame")
invTickFrame:SetScript("OnUpdate", function(self, dt)
    for key, entry in pairs(CleanBot_PartyBots) do
        if entry.awaitingQuests then
            entry.questTimeout = (entry.questTimeout or 0) + dt
            if entry.questTimeout >= 3 then
                CB_FinalizeQuestCollection(key, entry)
            end
        end

        if entry.awaitingInventory then
            entry.invTimeout = (entry.invTimeout or 0) + dt
            if entry.invTimeout >= 3 then
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
                    entry.awaitingMoney  = true
                    entry.moneyTimeout   = 0
                    SendChatMessage("stats", "WHISPER", nil, entry.name)
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
            if entry.moneyTimeout >= 3 then
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
    local invF = NS.botInventoryFrames and NS.botInventoryFrames[key]
    if invF and invF:IsShown() and NS.CB_SetInventoryLoading then
        NS.CB_SetInventoryLoading(invF, true)
    end

    if CB_EffectiveBridgeState() == "present" then
        SendAddonMessage("MBOT", "GET~INVENTORY~" .. botName .. "~inv", CB_GroupChannel())
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
        SendAddonMessage("MBOT", "GET~QUESTS~ALL~" .. botName .. "~quests", CB_GroupChannel())
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
    if NS.CB_InGroup() then
        SendAddonMessage("MBOT", "HELLO~1", CB_GroupChannel())
    end
end

-- Sends HELLO and, if no HELLO_ACK arrives within the timeout, declares the
-- bridge absent and switches to no-bridge (whisper) discovery. Only runs while
-- the bridge state is still unknown.
local function CB_StartBridgeDetection()
    if NS.bridgeState ~= "unknown" then return end
    if NS.bridgeDetecting then return end           -- a detection timer is already running
    if not NS.CB_InGroup() then return end          -- nothing to detect against yet
    NS.bridgeDetecting = true
    CB_SendHello()

    NS.CB_After(3, function()
        NS.bridgeDetecting  = false
        NS.loginPhaseActive = false   -- login gate lifted regardless of outcome
        if NS.bridgeState == "unknown" then
            NS.bridgeState = "absent"

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
bridgeFrame:RegisterEvent("INSPECT_READY")
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
        if entry and entry.awaitingMoney then
            entry.moneyTimeout  = 0
            entry.awaitingMoney = false

            local clean = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|h", ""):gsub("|r", "")

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
            local durPct        = tonumber(clean:match("(%d+)%%%s*%(.-%)%s*Dur"))
            local xpCur, xpMax  = clean:match("(%d+)/(%d+)%%%s*XP")
            entry.durability    = durPct
            entry.xpPercent     = xpCur and (tonumber(xpCur) .. "/" .. tonumber(xpMax)) or nil

            local f = NS.botInventoryFrames and NS.botInventoryFrames[strlower(sender)]
            if f and f:IsShown() then NS.CB_RenderInventory(strlower(sender)) end
            return
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
                entry.awaitingNc = true
                NS.CB_SendBotCommand(entry.name, "nc ?")
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
        local unit = ...
        if unit and NS.tabList and NS.CB_QueueEquipRefresh then
            for _, info in ipairs(NS.tabList) do
                if info.unit == unit then
                    NS.CB_QueueEquipRefresh({{ key = info.key, unit = unit }})
                    break
                end
            end
        end

    elseif event == "INSPECT_READY" then
        -- Fired when NotifyInspect data arrives; GUID identifies which unit.
        local guid = ...
        if NS.CB_OnInspectReady then
            NS.CB_OnInspectReady(guid)
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
        NS.probed           = {}
        NS.awaitingProbe    = {}
        CleanBot_PartyBots  = {}
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

    elseif event == "PLAYER_LOGOUT" then
        -- Clear the flag so the next session is treated as a fresh login.
        if CleanBot_SavedVars then
            CleanBot_SavedVars.sessionActive = false
        end
    end
end)
