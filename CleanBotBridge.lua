-- ============================================================
-- CleanBotBridge.lua  —  MBOT bridge / playerbot protocol layer.
--
-- Owns the handshake, debounced sync, no-bridge whisper discovery,
-- linked-account fetch, inventory fetch, quest fetch, and the event
-- handler that parses ROSTER~ / DETAIL~ / STATE~ / INV_* / QUESTS_*
-- addon messages plus the co?/nc? whisper replies.
-- ============================================================
local NS = CleanBotNS

-- URL-decode a percent-encoded string (e.g. quest names from the bridge).
-- Converts %XX hex sequences to their ASCII characters.
local function CB_UrlDecode(s)
    return (s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
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

-- No-bridge discovery: whisper "co ?" to each party member exactly once.
-- Only members that reply with a "Strategies: " line are treated as bots
-- (handled in the CHAT_MSG_WHISPER branch). Humans never respond, so they
-- are probed a single time and then ignored.
-- Skipped during loginPhaseActive — bots may not be online yet on fresh
-- login; the "Hello!" path gates probing until each bot announces itself.
local function CB_ProbePartyForBots()
    if NS.loginPhaseActive then return end
    local n = GetNumPartyMembers()

    -- Forget probe records for members who have left, so a rejoin re-probes.
    local present = {}
    for i = 1, n do
        local nm = UnitName("party" .. i)
        if nm then present[strlower(nm)] = true end
    end
    for k in pairs(NS.probed) do
        if not present[k] then NS.probed[k] = nil; NS.awaitingProbe[k] = nil end
    end

    for i = 1, n do
        local unit = "party" .. i
        local nm   = UnitName(unit)
        if nm and UnitIsPlayer(unit) then
            local key = strlower(nm)
            if not CleanBot_PartyBots[key] and not NS.probed[key] then
                NS.probed[key]        = true
                NS.awaitingProbe[key] = true
                NS.CB_SendBotCommand(nm, "co ?")
            end
        end
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

-- Sends a command to a bot. Routes through the bridge (silent, no whisper
-- spam) when the bridge is present and the command is allowlisted; falls back
-- to a whisper for everything else or when bridge is absent. Safe to use for
-- all commands including queries — unlisted commands always whisper, so
-- replies still arrive normally via CHAT_MSG_WHISPER.
NS.CB_SendBotCommand = function(botName, command)
    if NS.bridgeState == "present" then
        local opcode = CB_GetBridgeOpcode(command)
        if opcode then
            SendAddonMessage("MBOT", "RUN~" .. opcode .. "~BOT~" .. botName .. "~~" .. command, "PARTY")
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
        if NS.bridgeState == "present" then
            SendAddonMessage("MBOT", "GET~ROSTER",  "PARTY")
            SendAddonMessage("MBOT", "GET~DETAILS", "PARTY")
            SendAddonMessage("MBOT", "GET~STATES",  "PARTY")
        elseif NS.bridgeState == "absent" then
            CB_ProbePartyForBots()
        end
        if CleanBotFrame:IsShown() then
            NS.CleanBot_RefreshTabs()
        end
    end)
end

function CleanBot_RequestRosterThenRefresh()
    NS.CB_RequestSync()
end

-- Tick inventory and money timeouts for the whisper path (3s silence = done)
local invTickFrame = CreateFrame("Frame")
invTickFrame:SetScript("OnUpdate", function(self, dt)
    for key, entry in pairs(CleanBot_PartyBots) do
        if entry.awaitingInventory then
            entry.invTimeout = (entry.invTimeout or 0) + dt
            if entry.invTimeout >= 3 then
                entry.awaitingInventory = false
                entry.invTimeout        = 0
                local f = NS.botInventoryFrames and NS.botInventoryFrames[key]
                if f and f:IsShown() then NS.CB_RenderInventory(key) end

                -- Inventory done — now ask for money separately so the reply
                -- arrives on its own and is not swallowed by awaitingInventory.
                entry.awaitingMoney  = true
                entry.moneyTimeout   = 0
                SendChatMessage("stats", "WHISPER", nil, entry.name)
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

NS.CB_FetchInventory = function(key, botName)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    -- Preserve existing inventory while the fresh fetch is in flight so the
    -- frame can display stale-but-correct data instead of going blank.
    entry.inventory = entry.inventory or { items = {} }

    if NS.bridgeState == "present" then
        SendAddonMessage("MBOT", "GET~INVENTORY~" .. botName .. "~inv", "PARTY")
    else
        entry.awaitingInventory = true
        entry.invTimeout        = 0
        NS.CB_SendBotCommand(botName, "items")
    end
end

NS.CB_RequestInventory = function(key, botName)
    NS.CB_FetchInventory(key, botName)
    NS.CB_ToggleInventory(key, botName)
end

-- Fetches the quest log for a bot. Bridge path sends a structured GET~QUESTS
-- request; the QUESTS_BEGIN/ITEM/END packets are handled below in the
-- CHAT_MSG_ADDON block. Whisper fallback sends "quests" — structured parsing
-- of the whisper reply is not yet implemented.
NS.CB_FetchQuests = function(key, botName)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end
    entry.quests = {}

    if NS.bridgeState == "present" then
        SendAddonMessage("MBOT", "GET~QUESTS~ALL~" .. botName .. "~quests", "PARTY")
    else
        -- Whisper fallback — reply parsing not yet implemented.
        NS.CB_SendBotCommand(botName, "quests")
    end
end

-- ============================================================
-- Bridge handshake
-- ============================================================
local function CB_BridgeRequest()
    NS.CB_RequestSync()
end

local function CB_SendHello()
    if GetNumPartyMembers() > 0 then
        SendAddonMessage("MBOT", "HELLO~1", "PARTY")
    end
end

-- Sends HELLO and, if no HELLO_ACK arrives within the timeout, declares the
-- bridge absent and switches to no-bridge (whisper) discovery. Only runs while
-- the bridge state is still unknown.
local function CB_StartBridgeDetection()
    if NS.bridgeState ~= "unknown" then return end
    if NS.bridgeDetecting then return end           -- a detection timer is already running
    if GetNumPartyMembers() == 0 then return end    -- nothing to detect against yet
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
        -- We verify the sender is actually in our party to avoid acting on a real player.
        -- "Hello!" is not a Strategies reply, so we return early after handling it.
        if msg == "Hello!" and NS.bridgeState ~= "present" then
            local inParty = false
            for i = 1, GetNumPartyMembers() do
                if UnitName("party" .. i) == sender then inParty = true; break end
            end
            if inParty then
                if NS.loginPhaseActive then
                    -- Detection still running: buffer for processing when it resolves.
                    NS.pendingHello[key] = sender
                elseif NS.bridgeState == "absent" then
                    -- Detection already resolved to absent: probe immediately.
                    if not CleanBot_PartyBots[key] and not NS.probed[key] then
                        NS.probed[key]        = true
                        NS.awaitingProbe[key] = true
                        NS.CB_SendBotCommand(sender, "co ?")
                    end
                end
            end
            return
        end

        -- Inventory collection (whisper path): grab any item link, ignore everything else
        if entry and entry.awaitingInventory then
            if strfind(msg, "|Hitem:", 1, true) then
                local item = NS.CB_ParseItemLine and NS.CB_ParseItemLine(msg)
                if item then
                    local items = entry.inventory and entry.inventory.items
                    if items then items[#items + 1] = item end
                end
            end
            entry.invTimeout = 0   -- reset timeout on every whisper from this bot
            return
        end

        -- Money/stats capture (whisper path): reply from "stats" whisper.
        -- Format: "Ng Ns Nc, used/total Bag, X% (Y) Dur, cur/max% XP"
        -- Each money denomination is optional (e.g. a broke bot omits gold).
        if entry and entry.awaitingMoney then
            entry.moneyTimeout  = 0
            entry.awaitingMoney = false

            local gold   = tonumber(msg:match("(%d+)g")) or 0
            local silver = tonumber(msg:match("(%d+)s")) or 0
            local copper = tonumber(msg:match("(%d+)c")) or 0
            entry.money  = { gold = gold, silver = silver, copper = copper }

            -- Bag totals are not available from the "items" whisper, but stats gives them.
            local bagUsed, bagTotal = msg:match("(%d+)/(%d+)%s+Bag")
            if bagUsed and entry.inventory then
                entry.inventory.bagUsed  = tonumber(bagUsed)
                entry.inventory.bagTotal = tonumber(bagTotal)
            end

            -- Durability and XP are whisper-only — store for future display.
            local durPct            = tonumber(msg:match("(%d+)%%%s+%(%d+%)%s+Dur"))
            local xpCur, xpMax     = msg:match("(%d+)/(%d+)%%%s+XP")
            entry.durability        = durPct
            entry.xpPercent         = xpCur and (tonumber(xpCur) .. "/" .. tonumber(xpMax)) or nil

            local f = NS.botInventoryFrames and NS.botInventoryFrames[strlower(sender)]
            if f and f:IsShown() then NS.CB_RenderInventory(strlower(sender)) end
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
            local f    = NS.botInventoryFrames and NS.botInventoryFrames[key]
            if f and f:IsShown() then
                NS.CB_RenderInventory(key)
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
            local questID, questName = NS.CB_SplitOnce(r5,  "~")
            local key   = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry and entry.quests then
                entry.quests[#entry.quests + 1] = {
                    id     = tonumber(questID),
                    name   = CB_UrlDecode(questName or ""),
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

    elseif event == "PARTY_MEMBERS_CHANGED" then
        if NS.bridgeState == "unknown" then
            CB_StartBridgeDetection()
        else
            NS.CB_RequestSync()
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        if NS.partyPanel and NS.partyPanel:IsShown() and NS.CleanBot_RefreshTabs then
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

    elseif event == "PLAYER_LOGOUT" then
        -- Clear the flag so the next session is treated as a fresh login.
        if CleanBot_SavedVars then
            CleanBot_SavedVars.sessionActive = false
        end
    end
end)
