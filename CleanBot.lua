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
            if NS.bridgeReady then
                SendAddonMessage("MBOT", "GET~ROSTER",  "PARTY")
                SendAddonMessage("MBOT", "GET~DETAILS", "PARTY")
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
        NS.bridgeReady = false
        CleanBot_PartyBots = {}
        CB_SendHello()
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
        if entry and strsub(msg, 1, 12) == "Strategies: " then
            if entry.awaitingCo then
                entry.awaitingCo = false
                entry.combat     = NS.CB_ParseCombatStr(msg)

                -- Parse class-specific combat flags from the same co? response.
                if not entry.classData then entry.classData = NS.CB_DefaultClassData(entry.class) end
                entry.classData.combat = NS.CB_ParseClassStr(msg, entry.class, "combat")

                if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key) end

                entry.awaitingNc = true
                SendChatMessage("nc ?", "WHISPER", nil, entry.name)

            elseif entry.awaitingNc then
                entry.awaitingNc = false
                entry.nonCombat  = NS.CB_ParseNonCombatStr(msg)

                -- Parse class-specific non-combat flags from the same nc? response.
                if not entry.classData then entry.classData = NS.CB_DefaultClassData(entry.class) end
                entry.classData.nonCombat = NS.CB_ParseClassStr(msg, entry.class, "nonCombat")

                if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key) end
            end
        end
        return

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg = ...
        if prefix ~= "MBOT" then return end

        if msg and strsub(msg, 1, 10) == "HELLO_ACK~" then
            NS.lastHelloAck = msg
            if not NS.bridgeReady then
                NS.bridgeReady = true
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
                local key            = strlower(name)
                local existing       = CleanBot_PartyBots[key]
                local alreadyQueried = existing and existing.queried
                -- Preserve all in-flight state so a duplicate DETAIL~ (e.g. from a second
                -- GET~DETAILS fired while awaiting a co ?/nc ? response) doesn't silently
                -- drop the awaiting flags.
                CleanBot_PartyBots[key] = {
                    name       = name,
                    class      = classKey,
                    combat     = (existing and existing.combat)    or NS.CB_DefaultCombat(),
                    nonCombat  = (existing and existing.nonCombat) or NS.CB_DefaultNonCombat(),
                    classData  = (existing and existing.classData) or NS.CB_DefaultClassData(classKey),
                    queried    = alreadyQueried,
                    awaitingCo = existing and existing.awaitingCo,
                    awaitingNc = existing and existing.awaitingNc,
                }
                if not alreadyQueried then
                    CleanBot_PartyBots[key].queried    = true
                    CleanBot_PartyBots[key].awaitingCo = true
                    CleanBot_PartyBots[key].awaitingNc = false
                    SendChatMessage("co ?", "WHISPER", nil, name)
                end
            end
            if CleanBotFrame:IsShown() then
                NS.CleanBot_RefreshTabs()
            end

        elseif msg and strsub(msg, 1, 7) == "STATES~" then
            local payload = strsub(msg, 8)
            NS.lastRawStates = payload
            for entry in gmatch(payload .. ";", "([^;]*);") do
                if entry ~= "" then
                    local name, rest   = NS.CB_SplitOnce(entry, "~")
                    local combatStr, _ = NS.CB_SplitOnce(rest,  "~")
                    name = name:match("^%s*(.-)%s*$")
                    if name and name ~= "" then
                        local key = strlower(name)
                        if CleanBot_PartyBots[key] then
                            CleanBot_PartyBots[key].combat = NS.CB_ParseCombatStr(combatStr)
                        end
                    end
                end
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
        if not NS.bridgeReady then
            CB_SendHello()
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
