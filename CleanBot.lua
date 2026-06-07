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
NS.FRAME_WIDTH       = 850
NS.FRAME_HEIGHT      = 560
NS.TAB_WIDTH         = 88
NS.TAB_HEIGHT        = 24
NS.TITLE_H           = 28
NS.PAD               = 6
NS.COLUMN_GAP        = 4   -- horizontal space between side-by-side column pairs
NS.TOP_BAR_H         = NS.TAB_HEIGHT + 8
NS.BOT_BAR_H         = NS.TAB_HEIGHT + 8
-- Per-frame padding — space between a frame's border and the content inside it (CSS padding).
-- frame:   outermost window (CleanBotFrame)
-- panel:   main panels and column containers (managePanel, partyPanel, ctrl, left/right columns)
-- section: strategy section frames (the bordered checkbox groups in the party tab)
NS.PADDING_DEFAULTS = {
    frame   = { top = 32, bottom = 16, left = 16, right = 16 },
    panel   = { top = 6,  bottom = 6,  left = 6,  right = 6  },
    section = { top = 4,  bottom = 4,  left = 4,  right = 4  },
}
-- Working copy — mutated at login from SavedVars, and by the Settings Apply button.
NS.PADDING = {}
for k, v in pairs(NS.PADDING_DEFAULTS) do
    NS.PADDING[k] = { top = v.top, bottom = v.bottom, left = v.left, right = v.right }
end
-- Per-element margins — each widget declares the space it needs above and below.
-- Gap between two elements = above.marginBottom + below.marginTop (additive, like CSS margins).
NS.MARGIN_DEFAULTS = {
    -- Widget types — space a widget reserves around itself within a flow.
    header   = { top = 10, bottom = 4, left = 0, right = 0 },
    label    = { top = 6,  bottom = 2, left = 0, right = 0 },
    button   = { top = 2,  bottom = 2, left = 0, right = 0 },
    tab      = { top = 2,  bottom = 2, left = 0, right = 4 },
    slider   = { top = 2,  bottom = 4, left = 4, right = 4 },
    dropdown = { top = 2,  bottom = 2, left = -12, right = 0 },
    checkbox = { top = 2,  bottom = 2, left = 0, right = 0 },
    swatch   = { top = 2,  bottom = 2, left = 0, right = 0 },
    editBox  = { top = 2,  bottom = 2, left = 0, right = 0 },
    -- Frame types — extra breathing room a child frame adds on top of its
    -- parent's padding when placed via CB_CreateInnerFrame.
    panel    = { top = 0, bottom = 0, left = 0, right = 0 },
    section  = { top = 0, bottom = 0, left = 0, right = 0 },
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
NS.partyPanel      = nil
NS.botTabBar       = nil
NS.partyContent    = nil
NS.partyEmptyLabel = nil
NS.managePanel      = nil
NS.manageScrollFrame = nil
NS.manageScrollChild = nil
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
-- NS.CleanBot_BuildPartyTab / NS.CleanBot_BuildManageTab /
-- NS.CleanBot_BuildSettingsTab /
-- NS.CleanBot_RefreshTabs are all defined in the files that load after this one.
-- They are only ever called at event time (never at load time), so the forward
-- references are fine.
-- ============================================================
function CleanBot_BuildFrames()
    -- Static frame size — never shrinks/grows based on party state
    CleanBotFrame:SetWidth(NS.FRAME_WIDTH)
    CleanBotFrame:SetHeight(NS.FRAME_HEIGHT)

    -- Stamp padding fields so child anchors can read CleanBotFrame.paddingXxx
    -- directly rather than going through the raw NS.PADDING.frame globals.
    -- CleanBotFrame is XML-defined so CB_CreatePanel never runs on it.
    local framePad = NS.PADDING.frame
    CleanBotFrame.paddingTop    = framePad.top
    CleanBotFrame.paddingBottom = framePad.bottom
    CleanBotFrame.paddingLeft   = framePad.left
    CleanBotFrame.paddingRight  = framePad.right

    -- ── Top tab bar ────────────────────────────────────────────
    NS.topTabBar = CreateFrame("Frame", "CleanBotTopTabBar", CleanBotFrame)
    NS.topTabBar:SetPoint("TOPLEFT",  CleanBotFrame, "TOPLEFT",  0, -NS.TITLE_H)
    NS.topTabBar:SetPoint("TOPRIGHT", CleanBotFrame, "TOPRIGHT", 0, -NS.TITLE_H)
    NS.topTabBar:SetHeight(NS.TOP_BAR_H)

    local tabLabels = { "Manage", "Party", "Settings" }
    local prevTopTab = nil
    for i, label in ipairs(tabLabels) do
        local idx = i
        local tab = NS.CB_CreateTab(NS.topTabBar, "CleanBotTopTab" .. i, label,
                                    function() NS.CleanBot_SelectTopTab(idx) end)
        tab:SetWidth(NS.TAB_WIDTH)
        if prevTopTab then
            NS.CB_AnchorAhead(tab, prevTopTab)
        else
            tab:SetPoint("LEFT", NS.topTabBar, "LEFT", CleanBotFrame.paddingLeft + (tab.marginLeft or 0), 0)
        end
        prevTopTab  = tab
        NS.topTabs[i] = tab
    end

    -- ── Content frame ──────────────────────────────────────────
    NS.contentFrame = CreateFrame("Frame", "CleanBotContentFrame", CleanBotFrame)
    NS.contentFrame:SetPoint("TOPLEFT",     CleanBotFrame, "TOPLEFT",      CleanBotFrame.paddingLeft,   -(NS.TITLE_H + NS.TOP_BAR_H))
    NS.contentFrame:SetPoint("BOTTOMRIGHT", CleanBotFrame, "BOTTOMRIGHT", -CleanBotFrame.paddingRight,    CleanBotFrame.paddingBottom)
    NS.CB_ApplyFrameSkin(NS.contentFrame, 1)

    -- ── Party panel ────────────────────────────────────────────
    -- Defined in Party/CleanBotParty.lua (loads after this file).
    NS.CleanBot_BuildPartyTab()

    -- ── Manage panel ───────────────────────────────────────────
    -- Defined in CleanBotManageTab.lua (loads after this file).
    NS.CleanBot_BuildManageTab()

    -- ── Settings panel ─────────────────────────────────────────
    -- Defined in CleanBotSettingsTab.lua (loads after this file).
    NS.CleanBot_BuildSettingsTab()

    if NS.ElvUI_S then
        CleanBotFrame:StripTextures()
        NS.ElvUI_S:HandleCloseButton(CleanBotFrameCloseButton)
    end
    NS.CB_ApplyFrameSkin(CleanBotFrame, 0)
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
        local defaultAccentColor  = NS.ElvUI_S and { r = 0.0, g = 0.0, b = 0.0, a = 1 } or { r = 1.0, g = 1.0, b = 1.0, a = 1 }
        local defaultTransparency = NS.ElvUI_S and 75 or 90
        NS.THEME_DEFAULTS.accentColor   = defaultAccentColor
        NS.THEME_DEFAULTS.transparency  = defaultTransparency
        NS.transparency                 = defaultTransparency

        -- Initialise saved variables, preserving any existing data
        if type(CleanBot_SavedVars) ~= "table" then CleanBot_SavedVars = {} end
        if type(CleanBot_SavedVars.collapsedSections)   ~= "table" then CleanBot_SavedVars.collapsedSections   = {} end
        if type(CleanBot_SavedVars.presets)             ~= "table" then CleanBot_SavedVars.presets             = {} end

        -- Seed the protected "Favorites" preset, migrating the old favoriteBots set
        -- (format: { [lowercaseName] = true }) into the preset array format on first run.
        if type(CleanBot_SavedVars.presets["Favorites"]) ~= "table" then
            local migrated = {}
            if type(CleanBot_SavedVars.favoriteBots) == "table" then
                for key in pairs(CleanBot_SavedVars.favoriteBots) do
                    migrated[#migrated + 1] = key:sub(1, 1):upper() .. key:sub(2)
                end
                table.sort(migrated)
            end
            CleanBot_SavedVars.presets["Favorites"] = migrated
        end
        CleanBot_SavedVars.favoriteBots = nil  -- drop old storage key after migration

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
        -- Accent colour is baked in during CB_ApplyFrameSkin calls inside
        -- CleanBot_BuildFrames, which read NS.accentColor at build time.
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

print("CleanBot loaded! Type /cleanbot to open.")
