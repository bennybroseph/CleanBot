-- ============================================================
-- CleanBotBridge.lua  —  MBOT bridge / playerbot protocol layer.
--
-- Owns the handshake, debounced sync, no-bridge whisper discovery,
-- linked-account fetch, inventory fetch, and the event handler that
-- parses ROSTER~ / DETAIL~ / STATE~ / INV_* addon messages plus the
-- co?/nc? whisper replies.
-- ============================================================
local NS = CleanBotNS

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
local function CB_ProbePartyForBots()
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
                SendChatMessage("co ?", "WHISPER", nil, nm)
            end
        end
    end
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

-- Tick inventory timeouts for the whisper path (3s silence = done)
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
            end
        end
    end
end)

NS.CB_FetchInventory = function(key, botName)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    entry.inventory = { items = {} }

    if NS.bridgeState == "present" then
        SendAddonMessage("MBOT", "GET~INVENTORY~" .. botName .. "~inv", "PARTY")
    else
        entry.awaitingInventory = true
        entry.invTimeout        = 0
        SendChatMessage("items", "WHISPER", nil, botName)
    end
end

NS.CB_RequestInventory = function(key, botName)
    NS.CB_FetchInventory(key, botName)
    NS.CB_ShowInventory(key, botName)
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
        NS.bridgeDetecting = false
        if NS.bridgeState == "unknown" then
            NS.bridgeState = "absent"
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
bridgeFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_WHISPER" then
        local msg, sender = ...
        local key   = strlower(sender)
        local entry = CleanBot_PartyBots[key]

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

        if strsub(msg, 1, 12) ~= "Strategies: " then return end

        if entry then
            -- Known bot: response to a co?/nc? read (no-bridge mode, or a manual re-read).
            if entry.awaitingCo then
                entry.awaitingCo = false
                entry.class = NS.CB_ResolveClass(sender, entry.class)
                NS.CB_StoreCombat(entry, msg)
                if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key) end
                entry.awaitingNc = true
                SendChatMessage("nc ?", "WHISPER", nil, entry.name)
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
            SendChatMessage("nc ?", "WHISPER", nil, sender)
            if CleanBotFrame:IsShown() then NS.CleanBot_RefreshTabs() end
        end
        return

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg = ...
        if prefix ~= "MBOT" then return end

        if msg and strsub(msg, 1, 10) == "HELLO_ACK~" then
            NS.lastHelloAck = msg
            if not NS.bridgeReady then
                NS.bridgeReady     = true
                NS.bridgeState     = "present"
                NS.bridgeDetecting = false
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
            local rest                  = strsub(msg, 13)
            local name, r2              = NS.CB_SplitOnce(rest, "~")
            local _, r3                 = NS.CB_SplitOnce(r2,   "~")  -- skip token
            local gold, r4              = NS.CB_SplitOnce(r3,   "~")  -- skip gold
            local silver, r5            = NS.CB_SplitOnce(r4,   "~")  -- skip silver
            local copper, r6            = NS.CB_SplitOnce(r5,   "~")  -- skip copper
            local bagUsed, bagTotal     = NS.CB_SplitOnce(r6,   "~")
            local key   = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry and entry.inventory then
                entry.inventory.bagUsed  = tonumber(bagUsed)  or 0
                entry.inventory.bagTotal = tonumber(bagTotal) or 0
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
        NS.bridgeReady     = false
        NS.bridgeState     = "unknown"
        NS.bridgeDetecting = false
        NS.probed          = {}
        NS.awaitingProbe   = {}
        CleanBot_PartyBots = {}
        CB_StartBridgeDetection()
    end
end)
