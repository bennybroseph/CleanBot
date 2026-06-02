-- ============================================================
-- CleanBot.lua  —  core: namespace init, ElvUI, layout constants,
--                  frame shell, top-tab management, sync, bridge, init
-- ============================================================

CleanBotNS = {}
local NS = CleanBotNS

-- ============================================================
-- ElvUI handles + fallback backdrop
-- ============================================================
NS.ElvUI_E = nil
NS.ElvUI_S = nil

NS.PLAIN_BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- ============================================================
-- Debug: KnownBots popup window (created lazily, reused)
-- ============================================================
local debugKnownBotsFrame = nil
NS.lastRawStates = nil
NS.lastHelloAck  = nil
NS.bridgeReady   = false

-- Bridge availability: "unknown" until detection resolves, then "present"
-- (HELLO_ACK received) or "absent" (detection timed out). Drives whether
-- strategy reads use GET~STATES (bridge) or co?/nc? whispers (no bridge).
NS.bridgeState   = "unknown"
NS.probed        = {}   -- name-key -> true: party member already probed for bot-hood
NS.awaitingProbe = {}   -- name-key -> true: probe co? sent, awaiting a "Strategies:" reply

local function CB_FormatKnownBots()
    local lines = {
        "=== Handshake ===",
        "bridgeReady: " .. tostring(NS.bridgeReady),
        "Last HELLO_ACK: " .. (NS.lastHelloAck or "(none received yet)"),
        "",
        "=== Last raw STATES payload ===",
        NS.lastRawStates or "(none received yet)",
        "",
        "=== Parsed KnownBots ===",
        "",
    }
    local count = 0
    for key, bot in pairs(CleanBot_PartyBots) do
        count = count + 1
        lines[#lines + 1] = string.format("[%d]  %s  (%s)", count, bot.name or key, bot.class or "?")
        if bot.combat then
            local active, inactive, unknown = {}, {}, {}
            for field, val in pairs(bot.combat) do
                if val == true then
                    active[#active + 1] = field
                elseif val == false then
                    inactive[#inactive + 1] = field
                else
                    unknown[#unknown + 1] = field
                end
            end
            table.sort(active); table.sort(inactive); table.sort(unknown)
            if #active   > 0 then lines[#lines + 1] = "  |cff00ff00ON |r  " .. table.concat(active,   "  ") end
            if #inactive > 0 then lines[#lines + 1] = "  |cffff4444OFF|r  " .. table.concat(inactive, "  ") end
            if #unknown  > 0 then lines[#lines + 1] = "  |cffaaaaaa?  |r  " .. table.concat(unknown,  "  ") end
        else
            lines[#lines + 1] = "  (no combat data)"
        end
        lines[#lines + 1] = ""
    end
    if count == 0 then return "(CleanBot_PartyBots is empty)" end
    return table.concat(lines, "\n")
end

function CleanBot_ShowDebugKnownBots()
    local screenH = UIParent:GetHeight()
    local winW    = 520
    local winH    = math.floor(screenH / 2)
    local titleH  = 24
    local footerH = 32
    local padH    = 8

    if not debugKnownBotsFrame then
        local f = CreateFrame("Frame", "CleanBotDebugKnownBots", UIParent)
        f:SetSize(winW, winH)
        f:SetPoint("CENTER")
        f:SetMovable(true)
        f:SetToplevel(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")

        if NS.ElvUI_S then
            f:SetTemplate("Default")
        else
            f:SetBackdrop(NS.PLAIN_BACKDROP)
            f:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
            f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        end

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", f, "TOP", 0, -8)
        title:SetText("CleanBot — KnownBots")

        local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        closeBtn:SetSize(80, 22)
        closeBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 6)
        closeBtn:SetText("Close")
        closeBtn:SetScript("OnClick", function() f:Hide() end)
        if NS.ElvUI_S then NS.ElvUI_S:HandleButton(closeBtn) end

        local sf = CreateFrame("ScrollFrame", "CleanBotDebugScroll", f,
                               "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT",     f, "TOPLEFT",     8,  -(titleH + padH))
        sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, footerH + padH)

        local child = CreateFrame("Frame", nil, sf)
        child:SetWidth(sf:GetWidth() or (winW - 36))
        sf:SetScrollChild(child)

        local txt = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        txt:SetPoint("TOPLEFT", child, "TOPLEFT", 4, -4)
        txt:SetWidth((sf:GetWidth() or (winW - 36)) - 8)
        txt:SetJustifyH("LEFT")
        txt:SetNonSpaceWrap(false)

        f.scrollFrame = sf
        f.scrollChild = child
        f.textObj     = txt
        debugKnownBotsFrame = f
    end

    local f   = debugKnownBotsFrame
    local txt = f.textObj
    txt:SetText(CB_FormatKnownBots())
    f.scrollChild:SetHeight(math.max(txt:GetStringHeight() + 8, 1))
    f:SetHeight(winH)
    f:Show()
    f.scrollFrame:SetVerticalScroll(0)
end

-- ============================================================
-- Config + bot detection cache
-- ============================================================
NS.ASSUME_ALL_PARTY_ARE_BOTS = false

CleanBot_PartyBots = {}  -- global so Commands.lua and XML scripts can reach it

-- ============================================================
-- Layout constants
-- ============================================================
NS.FRAME_WIDTH       = 680
NS.FRAME_HEIGHT      = 560
NS.TAB_HEIGHT        = 24
NS.TAB_WIDTH         = 88
NS.TITLE_H           = 28
NS.FOOTER_H          = 36
NS.TOP_BAR_H         = NS.TAB_HEIGHT + 8
NS.BOT_BAR_H         = NS.TAB_HEIGHT + 8
NS.PAD               = 6
-- Vertical space reserved below the model for the weapon-slot row.
-- The model height = contentH - EQUIP_WEAPON_PAD, weapon slots sit in that gap.
NS.EQUIP_WEAPON_PAD  = 60

-- ============================================================
-- ElvUI skinning helpers
-- ============================================================
NS.CB_ApplyPanelSkin = function(frame)
    if NS.ElvUI_S then
        frame:StripTextures()
        frame:SetTemplate("Default")
    else
        frame:SetBackdrop(NS.PLAIN_BACKDROP)
        frame:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
        frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    end
end

NS.CB_ApplyInnerSkin = function(frame)
    if NS.ElvUI_S then
        frame:StripTextures()
        frame:SetTemplate("Transparent")
    else
        frame:SetBackdrop(NS.PLAIN_BACKDROP)
        frame:SetBackdropColor(0, 0, 0, 0.4)
        frame:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.8)
    end
end

-- ============================================================
-- Persistent sub-frame references (assigned in CleanBot_BuildFrames)
-- ============================================================
NS.topTabBar     = nil
NS.contentFrame  = nil
NS.partyPanel    = nil
NS.botTabBar     = nil
NS.partyContent  = nil
NS.targetPanel   = nil
NS.settingsPanel = nil

-- ============================================================
-- Top-level tab management  (Manage = 1, Party = 2, Settings = 3)
-- ============================================================
NS.activeTopTabIndex = 0
NS.topTabs           = {}

NS.CleanBot_SelectTopTab = function(index)
    if NS.activeTopTabIndex == index then return end
    NS.activeTopTabIndex = index

    for i, tab in ipairs(NS.topTabs) do
        if i == index then
            tab:SetNormalFontObject(GameFontHighlightSmall)
            tab:SetButtonState("PUSHED", true)
        else
            tab:SetNormalFontObject(GameFontNormalSmall)
            tab:SetButtonState("NORMAL")
        end
    end

    if NS.targetPanel   then if index == 1 then NS.targetPanel:Show()   else NS.targetPanel:Hide()   end end
    if NS.partyPanel    then if index == 2 then NS.partyPanel:Show()    else NS.partyPanel:Hide()    end end
    if NS.settingsPanel then if index == 3 then NS.settingsPanel:Show() else NS.settingsPanel:Hide() end end

    if index == 2 then
        for i, info in ipairs(NS.tabList or {}) do
            if info.model then
                if i == NS.selectedTabIndex then info.model:Show() else info.model:Hide() end
            end
        end
    else
        for _, info in ipairs(NS.tabList or {}) do
            if info.model then info.model:Hide() end
        end
    end
end

-- ============================================================
-- Frame construction (called once at PLAYER_LOGIN)
-- NS.CleanBot_BuildTargetContent / NS.CleanBot_BuildSettingsContent /
-- NS.CleanBot_RefreshTabs are all defined in the files that load after this one.
-- They are only ever called at event time (never at load time), so the forward
-- references are fine.
-- ============================================================
NS.tabCounter = 0

function CleanBot_BuildFrames()
    -- Static frame size — never shrinks/grows based on party state
    CleanBotFrame:SetWidth(NS.FRAME_WIDTH)
    CleanBotFrame:SetHeight(NS.FRAME_HEIGHT)

    -- ── Top tab bar ────────────────────────────────────────────
    NS.topTabBar = CreateFrame("Frame", "CleanBotTopTabBar", CleanBotFrame)
    NS.topTabBar:SetPoint("TOPLEFT",  CleanBotFrame, "TOPLEFT",  0, -NS.TITLE_H)
    NS.topTabBar:SetPoint("TOPRIGHT", CleanBotFrame, "TOPRIGHT", 0, -NS.TITLE_H)
    NS.topTabBar:SetHeight(NS.TOP_BAR_H)

    local tabLabels = { "Manage", "Party", "Settings" }
    for i, label in ipairs(tabLabels) do
        local tab = CreateFrame("Button", "CleanBotTopTab" .. i,
                                NS.topTabBar, "UIPanelButtonTemplate")
        tab:SetSize(NS.TAB_WIDTH, NS.TAB_HEIGHT)
        tab:SetPoint("LEFT", NS.topTabBar, "LEFT", NS.PAD + (i - 1) * (NS.TAB_WIDTH + 2), 0)
        tab:SetText(label)
        tab:SetNormalFontObject(GameFontNormalSmall)
        local idx = i
        tab:SetScript("OnClick", function() NS.CleanBot_SelectTopTab(idx) end)
        if NS.ElvUI_S then NS.ElvUI_S:HandleButton(tab) end
        NS.topTabs[i] = tab
    end

    -- ── Content frame ──────────────────────────────────────────
    NS.contentFrame = CreateFrame("Frame", "CleanBotContentFrame", CleanBotFrame)
    NS.contentFrame:SetPoint("TOPLEFT",     CleanBotFrame, "TOPLEFT",     4, -(NS.TITLE_H + NS.TOP_BAR_H))
    NS.contentFrame:SetPoint("BOTTOMRIGHT", CleanBotFrame, "BOTTOMRIGHT", -4, NS.FOOTER_H)
    NS.CB_ApplyInnerSkin(NS.contentFrame)

    -- ── Party panel ────────────────────────────────────────────
    NS.partyPanel = CreateFrame("Frame", "CleanBotPartyPanel", NS.contentFrame)
    NS.partyPanel:SetAllPoints(NS.contentFrame)

    NS.botTabBar = CreateFrame("Frame", "CleanBotBotTabBar", NS.partyPanel)
    NS.botTabBar:SetPoint("TOPLEFT",  NS.partyPanel, "TOPLEFT",  0, 0)
    NS.botTabBar:SetPoint("TOPRIGHT", NS.partyPanel, "TOPRIGHT", 0, 0)
    NS.botTabBar:SetHeight(NS.BOT_BAR_H)

    -- Hide the XML-defined text (it's a child of CleanBotFrame and leaks across tabs).
    -- We use a dedicated label parented to partyPanel instead.
    CleanBotFrameText:SetText("")
    CleanBotFrameText:Hide()

    NS.partyEmptyLabel = NS.partyPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    NS.partyEmptyLabel:SetPoint("TOP", NS.partyPanel, "TOP", 0, -(NS.BOT_BAR_H + 20))
    NS.partyEmptyLabel:SetText("")

    NS.partyContent = CreateFrame("Frame", "CleanBotPartyContent", NS.partyPanel)
    NS.partyContent:SetPoint("TOPLEFT",     NS.partyPanel, "TOPLEFT",     0, -NS.BOT_BAR_H)
    NS.partyContent:SetPoint("BOTTOMRIGHT", NS.partyPanel, "BOTTOMRIGHT", 0, 0)

    -- ── Target panel ───────────────────────────────────────────
    NS.targetPanel = CreateFrame("Frame", "CleanBotTargetPanel", NS.contentFrame)
    NS.targetPanel:SetAllPoints(NS.contentFrame)
    NS.targetPanel:Hide()
    NS.CleanBot_BuildTargetContent()

    -- ── Settings panel ─────────────────────────────────────────
    NS.settingsPanel = CreateFrame("Frame", "CleanBotSettingsPanel", NS.contentFrame)
    NS.settingsPanel:SetAllPoints(NS.contentFrame)
    NS.settingsPanel:Hide()
    NS.CleanBot_BuildSettingsContent()

    if NS.ElvUI_S then
        CleanBotFrame:StripTextures()
        NS.ElvUI_S:HandleButton(CleanBotFrameCloseButton)
    end
    NS.CB_ApplyPanelSkin(CleanBotFrame)

    NS.CleanBot_SelectTopTab(1)

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
    local ticker  = CreateFrame("Frame")
    local elapsed = 0
    ticker:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= 0.5 then
            NS.syncPending = false
            ticker:SetScript("OnUpdate", nil)
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

    local ticker  = CreateFrame("Frame")
    local elapsed = 0
    ticker:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= 3 then
            ticker:SetScript("OnUpdate", nil)
            NS.bridgeDetecting = false
            if NS.bridgeState == "unknown" then
                NS.bridgeState = "absent"
                NS.CB_RequestSync()
            end
        end
    end)
end

-- ============================================================
-- Initialise at login (ElvUI is ready by PLAYER_LOGIN)
-- ============================================================
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        if IsAddOnLoaded("ElvUI") then
            NS.ElvUI_E = unpack(ElvUI)
            if NS.ElvUI_E then NS.ElvUI_S = NS.ElvUI_E:GetModule("Skins") end
        end

        -- Initialise saved variables, preserving any existing data
        if type(CleanBot_SavedVars) ~= "table" then CleanBot_SavedVars = {} end
        if type(CleanBot_SavedVars.favoriteBots) ~= "table" then CleanBot_SavedVars.favoriteBots = {} end

        CleanBot_BuildFrames()
        self:UnregisterEvent("PLAYER_LOGIN")

    elseif event == "PLAYER_ENTERING_WORLD" then
        NS.bridgeReady     = false
        NS.bridgeState     = "unknown"
        NS.bridgeDetecting = false
        NS.probed          = {}
        NS.awaitingProbe   = {}
        CleanBot_PartyBots = {}
        CB_StartBridgeDetection()
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
end)

print("CleanBot loaded! Type /cleanbot to open.")

-- ============================================================
-- Bridge: listen for MBOT messages and party changes
-- ============================================================
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
    end
end)
