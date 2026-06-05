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
CleanBot_PartyBots = {}  -- global so other modules and XML scripts can reach it

-- ============================================================
-- Layout constants
-- ============================================================
NS.FRAME_WIDTH       = 680
NS.FRAME_HEIGHT      = 560
NS.TAB_WIDTH         = 88
NS.TAB_HEIGHT        = 24
NS.TITLE_H           = 28
NS.PAD               = 6
NS.FOOTER_H          = NS.PAD  -- close button at top-right X; only a border margin needed
NS.TOP_BAR_H         = NS.TAB_HEIGHT + 8
NS.BOT_BAR_H         = NS.TAB_HEIGHT + 8
-- Per-frame padding — space between a frame's border and the content inside it (CSS padding).
-- panel:   main panels and column containers (managePanel, partyPanel, ctrl, left/right columns)
-- section: strategy section frames (the bordered checkbox groups in the party tab)
NS.PADDING_DEFAULTS = {
    frame   = { top = 4, bottom = 4, left = 16, right = 16 },
    panel   = { top = 6, bottom = 6, left = 6,  right = 6 },
    section = { top = 4, bottom = 4, left = 4,  right = 4 },
}
-- Working copy — mutated at login from SavedVars, and by the Settings Apply button.
NS.PADDING = {}
for k, v in pairs(NS.PADDING_DEFAULTS) do
    NS.PADDING[k] = { top = v.top, bottom = v.bottom, left = v.left, right = v.right }
end
-- Per-element margins — each widget declares the space it needs above and below.
-- Gap between two elements = above.marginBottom + below.marginTop (additive, like CSS margins).
NS.MARGIN_DEFAULTS = {
    header   = { top = 10, bottom = 4, left = 0, right = 0 },
    label    = { top = 6,  bottom = 2, left = 0, right = 0 },
    button   = { top = 2,  bottom = 2, left = 0, right = 0 },
    slider   = { top = 2,  bottom = 4, left = 4, right = 4 },
    dropdown = { top = 2,  bottom = 2, left = 0, right = 0 },
    checkbox = { top = 1,  bottom = 1, left = 4, right = 0 },
    swatch   = { top = 2,  bottom = 2, left = 0, right = 0 },
    editBox  = { top = 2,  bottom = 2, left = 0, right = 0 },
}
-- Canonical defaults for theme settings — read by the Defaults button.
-- accentColor.a is set to the skin-appropriate value at PLAYER_LOGIN (after ElvUI detection):
--   0 (fully transparent) for plain Blizzard UI — no visible border tint by default.
--   1 (fully opaque)      for ElvUI             — matches ElvUI's solid border style.
NS.THEME_DEFAULTS = {
    scale        = 100,
    transparency = 90,
    accentColor  = { r = 0.0, g = 0.0, b = 0.0, a = 0 },
}

-- Feature flags and theme values — mutated at login from SavedVars, and by the Settings Apply button.
NS.botEmotes    = true
NS.scale        = NS.THEME_DEFAULTS.scale
NS.transparency = NS.THEME_DEFAULTS.transparency
NS.accentColor  = { r = NS.THEME_DEFAULTS.accentColor.r, g = NS.THEME_DEFAULTS.accentColor.g, b = NS.THEME_DEFAULTS.accentColor.b, a = NS.THEME_DEFAULTS.accentColor.a }

-- Working copy — mutated at login from SavedVars, and by the Settings Apply button.
NS.MARGIN = {}
for k, v in pairs(NS.MARGIN_DEFAULTS) do
    NS.MARGIN[k] = { top = v.top, bottom = v.bottom, left = v.left, right = v.right }
end
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
NS.managePanel     = nil
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
        tab:SetActive(i == index)
    end

    if NS.managePanel     then if index == 1 then NS.managePanel:Show()     else NS.managePanel:Hide()     end end
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
        local tab = NS.CB_CreateTab(NS.topTabBar, "CleanBotTopTab" .. i, label,
                                    function() NS.CleanBot_SelectTopTab(idx) end)
        tab:SetWidth(NS.TAB_WIDTH)
        tab:SetPoint("LEFT", NS.topTabBar, "LEFT", NS.PAD + (i - 1) * (NS.TAB_WIDTH + 2), 0)
        NS.topTabs[i] = tab
    end

    -- ── Content frame ──────────────────────────────────────────
    NS.contentFrame = CreateFrame("Frame", "CleanBotContentFrame", CleanBotFrame)
    NS.contentFrame:SetPoint("TOPLEFT",     CleanBotFrame, "TOPLEFT",      NS.PADDING.frame.left, -(NS.TITLE_H + NS.TOP_BAR_H))
    NS.contentFrame:SetPoint("BOTTOMRIGHT", CleanBotFrame, "BOTTOMRIGHT", -NS.PADDING.frame.right, NS.FOOTER_H)
    NS.CB_ApplyPanelSkin(NS.contentFrame, 0)

    -- ── Party panel ────────────────────────────────────────────
    NS.partyPanel = CreateFrame("Frame", "CleanBotPartyPanel", NS.contentFrame)
    NS.partyPanel:SetAllPoints(NS.contentFrame)
    NS.CB_ApplyPanelSkin(NS.partyPanel, 1)

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
    NS.CB_ApplyPanelSkin(NS.managePanel, 1)
    NS.managePanel:Hide()
    NS.CleanBot_BuildManageContent()

    -- ── Settings panel ─────────────────────────────────────────
    NS.settingsPanel = CreateFrame("Frame", "CleanBotSettingsPanel", NS.contentFrame)
    NS.settingsPanel:SetAllPoints(NS.contentFrame)
    NS.CB_ApplyPanelSkin(NS.settingsPanel, 1)
    NS.settingsPanel:Hide()
    NS.CleanBot_BuildSettingsContent()

    if NS.ElvUI_S then
        CleanBotFrame:StripTextures()
        NS.ElvUI_S:HandleCloseButton(CleanBotFrameCloseButton)
    end
    NS.CB_ApplyOuterFrameSkin(CleanBotFrame)
    -- Hide the XML-defined ARTWORK FontString — CB_ApplyTitleBar creates its own
    -- OVERLAY replacement so it renders above the ornament texture.
    CleanBotFrameTitle:Hide()
    NS.CB_ApplyTitleBar(CleanBotFrame, "CleanBot")

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

        -- Set the skin-appropriate default accent alpha now that ElvUI detection has run.
        -- This must happen before SavedVars are applied so that the Defaults button in
        -- Settings shows the correct value, and so that NS.accentColor starts at the
        -- right value when no saved data exists yet.
        local defaultAccentColor = NS.ElvUI_S and { r = 0.0, g = 0.0, b = 0.0, a = 1 } or { r = 1.0, g = 1.0, b = 1.0, a = 1 }
        NS.THEME_DEFAULTS.accentColor   = defaultAccentColor

        -- Initialise saved variables, preserving any existing data
        if type(CleanBot_SavedVars) ~= "table" then CleanBot_SavedVars = {} end
        if type(CleanBot_SavedVars.favoriteBots) ~= "table" then CleanBot_SavedVars.favoriteBots = {} end

        -- Restore feature flags.
        if type(CleanBot_SavedVars.botEmotes) == "boolean" then
            NS.botEmotes = CleanBot_SavedVars.botEmotes
        end

        -- Restore theme values.
        if type(CleanBot_SavedVars.scale) == "number" then
            NS.scale = CleanBot_SavedVars.scale
        end
        if type(CleanBot_SavedVars.transparency) == "number" then
            NS.transparency = CleanBot_SavedVars.transparency
        end
        if type(CleanBot_SavedVars.accentColor) == "table" then
            local ac = CleanBot_SavedVars.accentColor
            if type(ac.r) == "number" then NS.accentColor.r = ac.r end
            if type(ac.g) == "number" then NS.accentColor.g = ac.g end
            if type(ac.b) == "number" then NS.accentColor.b = ac.b end
            if type(ac.a) == "number" then NS.accentColor.a = ac.a end
        end

        -- Restore saved margin values, filling in any missing keys with defaults.
        if type(CleanBot_SavedVars.margins) ~= "table" then CleanBot_SavedVars.margins = {} end
        for k, defaults in pairs(NS.MARGIN) do
            local saved = CleanBot_SavedVars.margins[k]
            if type(saved) == "table" then
                if type(saved.top)    == "number" then NS.MARGIN[k].top    = saved.top    end
                if type(saved.bottom) == "number" then NS.MARGIN[k].bottom = saved.bottom end
                if type(saved.left)   == "number" then NS.MARGIN[k].left   = saved.left   end
                if type(saved.right)  == "number" then NS.MARGIN[k].right  = saved.right  end
            end
        end

        -- Restore saved padding values, filling in any missing keys with defaults.
        if type(CleanBot_SavedVars.padding) ~= "table" then CleanBot_SavedVars.padding = {} end
        for k, defaults in pairs(NS.PADDING) do
            local saved = CleanBot_SavedVars.padding[k]
            if type(saved) == "table" then
                if type(saved.top)    == "number" then NS.PADDING[k].top    = saved.top    end
                if type(saved.bottom) == "number" then NS.PADDING[k].bottom = saved.bottom end
                if type(saved.left)   == "number" then NS.PADDING[k].left   = saved.left   end
                if type(saved.right)  == "number" then NS.PADDING[k].right  = saved.right  end
            end
        end

        NS.CB_RegisterRootFrame(CleanBotFrame)
        CleanBot_BuildFrames()
        NS.CB_RefreshScale(NS.scale)
        NS.CB_RefreshTransparency(NS.transparency)
        -- Accent colour is baked in during CB_ApplyPanelSkin/InnerSkin calls inside
        -- CleanBot_BuildFrames, which read NS.accentColor at build time.
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

print("CleanBot loaded! Type /cleanbot to open.")
