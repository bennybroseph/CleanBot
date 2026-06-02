-- ============================================================
-- CleanBot.lua  —  core: namespace, shared utilities, layout
--                  constants, frame shell, top-tab management,
--                  and login init.
--
-- ElvUI/skinning lives in CleanBotSkin.lua, the bridge/protocol
-- layer in CleanBotBridge.lua, and the debug popup in
-- CleanBotDebug.lua.
-- ============================================================

CleanBotNS = {}
local NS = CleanBotNS

-- ============================================================
-- Shared utilities
-- ============================================================

-- Chat output with the standard CleanBot tag.
NS.CB_Print = function(msg)
    print("|cffffcc00CleanBot|r: " .. msg)
end

-- One-shot timer: run fn() once, `delay` seconds from now.
-- Backed by a single shared ticker so repeated calls don't each
-- leak a throwaway frame. Due callbacks run after the scan finishes,
-- so a callback may safely schedule further timers.
local timerFrame = CreateFrame("Frame")
local timers     = {}
timerFrame:SetScript("OnUpdate", function(self, dt)
    local due
    for t in pairs(timers) do
        t.elapsed = t.elapsed + dt
        if t.elapsed >= t.delay then
            due = due or {}
            due[#due + 1] = t
        end
    end
    if due then
        for _, t in ipairs(due) do
            timers[t] = nil
            t.fn()
        end
    end
end)

NS.CB_After = function(delay, fn)
    timers[{ elapsed = 0, delay = delay, fn = fn }] = true
end

-- Shared full-screen mouse-capture frame. Only one drag can be active at a
-- time (model rotation or an inventory item drag), so a single reusable frame
-- absorbs mouse events for the duration. The caller supplies the OnUpdate and
-- an onStop(button) handler; CB_EndCapture tears them down and hides the frame.
NS.CB_BeginCapture = function(onUpdate, onStop)
    local cap = NS.dragCapture
    if not cap then
        cap = CreateFrame("Frame", "CleanBotDragCapture", UIParent)
        cap:SetAllPoints(UIParent)
        cap:SetFrameStrata("FULLSCREEN_DIALOG")
        cap:EnableMouse(true)
        cap:Hide()
        NS.dragCapture = cap
    end
    cap:SetScript("OnUpdate", onUpdate)
    cap:SetScript("OnMouseUp", onStop and function(self, button) onStop(button) end or nil)
    cap:Show()
    return cap
end

NS.CB_EndCapture = function()
    local cap = NS.dragCapture
    if cap then
        cap:SetScript("OnUpdate", nil)
        cap:SetScript("OnMouseUp", nil)
        cap:Hide()
    end
end

-- ============================================================
-- Config + bot detection cache
-- ============================================================
NS.ASSUME_ALL_PARTY_ARE_BOTS = false

CleanBot_PartyBots = {}  -- global so other modules and XML scripts can reach it

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
-- Persistent sub-frame references (assigned in CleanBot_BuildFrames)
-- ============================================================
NS.topTabBar     = nil
NS.contentFrame  = nil
NS.partyPanel    = nil
NS.botTabBar     = nil
NS.partyContent  = nil
NS.managePanel   = nil
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

    if NS.managePanel   then if index == 1 then NS.managePanel:Show()   else NS.managePanel:Hide()   end end
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
-- NS.CleanBot_BuildManageContent / NS.CleanBot_BuildSettingsContent /
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
        local idx = i
        local tab = NS.CB_CreateButton(NS.topTabBar, "CleanBotTopTab" .. i, label,
                                       NS.TAB_WIDTH, NS.TAB_HEIGHT,
                                       function() NS.CleanBot_SelectTopTab(idx) end)
        tab:SetPoint("LEFT", NS.topTabBar, "LEFT", NS.PAD + (i - 1) * (NS.TAB_WIDTH + 2), 0)
        tab:SetNormalFontObject(GameFontNormalSmall)
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

    -- ── Manage panel ───────────────────────────────────────────
    NS.managePanel = CreateFrame("Frame", "CleanBotManagePanel", NS.contentFrame)
    NS.managePanel:SetAllPoints(NS.contentFrame)
    NS.managePanel:Hide()
    NS.CleanBot_BuildManageContent()

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
-- Initialise at login (ElvUI is ready by PLAYER_LOGIN)
-- ============================================================
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        NS.CB_InitElvUI()

        -- Initialise saved variables, preserving any existing data
        if type(CleanBot_SavedVars) ~= "table" then CleanBot_SavedVars = {} end
        if type(CleanBot_SavedVars.favoriteBots) ~= "table" then CleanBot_SavedVars.favoriteBots = {} end

        CleanBot_BuildFrames()
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

print("CleanBot loaded! Type /cleanbot to open.")
