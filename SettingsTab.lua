-- ============================================================
-- SettingsTab.lua  —  Settings tab panel construction and content
--
-- Two nested sub-tabs inside the Settings panel:
--   • Theme   — scale, transparency, accent colour
--   • Layout  — margin tuning and the Sample Layout launcher
--
-- The Sample Layout window is a standalone singleton floating
-- frame that shows one of every widget type with debug overlays.
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- Sample Layout window
-- ============================================================

local overlayFrames  = {}
local overlayVisible = true

-- Visualises the margin space around a widget. Green = positive margin, red = negative.
-- These frames intentionally bypass the CB_AnchorBelow / CB_AnchorAhead helpers and the
-- margin/padding model entirely — using those helpers would be circular, since the gaps
-- they produce are derived from the very margin values being visualised here. Raw SetPoint
-- against specific reference frames is the only correct approach.
---@param parent table  Frame the debug overlay is anchored to.
---@param widget table  The widget being annotated with its debug overlay.
local function applyDebugOverlay(parent, widget)
    local mTop    = widget.marginTop    or 0
    local mBottom = widget.marginBottom or 0
    local mLeft   = widget.marginLeft   or 0
    local mRight  = widget.marginRight  or 0
    local level   = parent:GetFrameLevel() + 20

    local function makeOverlay(r, g, b)
        local f = CreateFrame("Frame", nil, parent)
        f:SetFrameLevel(level)
        local tex = f:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
        tex:SetVertexColor(r, g, b, 0.2)
        overlayFrames[#overlayFrames + 1] = f
        if not overlayVisible then f:Hide() end
        return f
    end

    -- Top/bottom: show this widget's contribution to the gap above/below it.
    -- Height = the margin value; anchored flush to the widget's top or bottom edge.
    if mTop ~= 0 then
        local top = mTop > 0 and makeOverlay(0, 1, 0) or makeOverlay(1, 0, 0)
        top:SetPoint("BOTTOMLEFT",  widget, "TOPLEFT",  0, 0)
        top:SetPoint("BOTTOMRIGHT", widget, "TOPRIGHT", 0, 0)
        top:SetHeight(math.abs(mTop))
    end

    if mBottom ~= 0 then
        local bot = mBottom > 0 and makeOverlay(0, 1, 0) or makeOverlay(1, 0, 0)
        bot:SetPoint("TOPLEFT",  widget, "BOTTOMLEFT",  0, 0)
        bot:SetPoint("TOPRIGHT", widget, "BOTTOMRIGHT", 0, 0)
        bot:SetHeight(math.abs(mBottom))
    end

    -- Left: CSS-style — spans between the parent's content left edge (parent.paddingLeft)
    -- and the widget's left edge. For positive marginLeft the widget sits to the right of
    -- the content edge; for negative it encroaches into the padding, so the span reverses.
    if mLeft ~= 0 then
        local left = mLeft > 0 and makeOverlay(0, 1, 0) or makeOverlay(1, 0, 0)
        if mLeft > 0 then
            left:SetPoint("TOPRIGHT",    widget, "TOPLEFT",    0, 0)
            left:SetPoint("BOTTOMRIGHT", widget, "BOTTOMLEFT", 0, 0)
            left:SetPoint("LEFT",        parent, "LEFT",       (parent.paddingLeft or 0), 0)
        else
            left:SetPoint("TOPLEFT",    widget, "TOPLEFT",    0, 0)
            left:SetPoint("BOTTOMLEFT", widget, "BOTTOMLEFT", 0, 0)
            left:SetPoint("RIGHT",      parent, "LEFT",       (parent.paddingLeft or 0), 0)
        end
    end

    -- Right: marginRight has no parent-wall reference in vertical flow (it is only the
    -- right half of the gap in CB_AnchorAhead). Show reserved space to the right of the
    -- widget by the margin amount — the most accurate representation in both flow contexts.
    if mRight ~= 0 then
        local right = mRight > 0 and makeOverlay(0, 1, 0) or makeOverlay(1, 0, 0)
        right:SetPoint("TOPLEFT",    widget, "TOPRIGHT",    0, 0)
        right:SetPoint("BOTTOMLEFT", widget, "BOTTOMRIGHT", 0, 0)
        right:SetWidth(math.abs(mRight))
    end
end

-- Visualises the padding insets of a frame. Blue overlays mark each of the 4 padding strips.
-- Same intentional raw-SetPoint bypass as applyDebugOverlay — these exist to show
-- the padding space, not participate in it.
---@param frame table  Frame to draw the padding-visualisation overlay on.
local function applyPaddingOverlay(frame)
    local pTop    = frame.paddingTop    or 0
    local pBottom = frame.paddingBottom or 0
    local pLeft   = frame.paddingLeft   or 0
    local pRight  = frame.paddingRight  or 0
    local level   = frame:GetFrameLevel() + 10

    local function makePad()
        local f = CreateFrame("Frame", nil, frame)
        f:SetFrameLevel(level)
        local tex = f:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
        tex:SetVertexColor(0, 0.5, 1, 0.25)
        overlayFrames[#overlayFrames + 1] = f
        if not overlayVisible then f:Hide() end
        return f
    end

    if pTop ~= 0 then
        local top = makePad()
        top:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, 0)
        top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        top:SetHeight(pTop)
    end

    if pBottom ~= 0 then
        local bot = makePad()
        bot:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  0, 0)
        bot:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        bot:SetHeight(pBottom)
    end

    if pLeft ~= 0 then
        local left = makePad()
        left:SetPoint("TOPLEFT",    frame, "TOPLEFT",    0, 0)
        left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        left:SetWidth(pLeft)
    end

    if pRight ~= 0 then
        local right = makePad()
        right:SetPoint("TOPRIGHT",    frame, "TOPRIGHT",    0, 0)
        right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        right:SetWidth(pRight)
    end
end

local sampleSection  = nil
local sampleGenCount = 0

-- Tears down the previous section and rebuilds inside 'panel'.
-- The section demonstrates section padding; widgets inside it demonstrate margins.
---@param panel table  The sample-layout panel to populate with demo widgets.
local function buildSampleContent(panel)
    if sampleSection then sampleSection:Hide() end
    for _, f in ipairs(overlayFrames) do f:Hide() end
    overlayFrames  = {}
    sampleGenCount = sampleGenCount + 1
    local gen = sampleGenCount

    applyPaddingOverlay(panel)

    -- Section sits inside the panel, inset by panel padding.
    -- Leaves room at the bottom for the persistent "Show Overlays" checkbox row.
    -- Row height = section bottom padding + checkbox margins + checkbox height + panel bottom padding.
    local OVERLAY_ROW_H = NS.PADDING.section.bottom + NS.MARGIN.checkbox.bottom + panel._overlayCB:GetHeight() + NS.MARGIN.checkbox.top + (panel.paddingBottom or 0)
    local section = NS.CB_CreatePanel(panel, nil, 4, "section")
    section:SetPoint("TOPLEFT",     panel, "TOPLEFT",      (panel.paddingLeft  or 0), -(panel.paddingTop   or 0))
    section:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -(panel.paddingRight or 0),   OVERLAY_ROW_H)
    sampleSection = section
    applyPaddingOverlay(section)

    -- First widget: section padding + the widget's own marginTop are both applied
    -- explicitly so the header's top margin is visible when tuning in Settings.
    local header = NS.CB_CreateHeader(section, "Lorem Ipsum")
    header:SetPoint("TOPLEFT", section, "TOPLEFT",
        (section.paddingLeft or 0) + (header.marginLeft or 0),
        -((section.paddingTop or 0) + (header.marginTop or 0)))
    applyDebugOverlay(section, header)

    local lbl = NS.CB_CreateLabel(section, "Lorem Ipsum")
    NS.CB_AnchorBelow(lbl, header)
    applyDebugOverlay(section, lbl)

    local btn = NS.CB_CreateButton(section, nil, "Lorem Ipsum", 120, 22)
    NS.CB_AnchorBelow(btn, lbl)
    applyDebugOverlay(section, btn)

    local chk = NS.CB_CreateCheckBox(section, nil)
    NS.CB_AnchorBelow(chk, btn)
    applyDebugOverlay(section, chk)
    local chkLbl = NS.CB_CreateLabel(section, "Lorem Ipsum")
    chkLbl:SetPoint("LEFT", chk, "RIGHT", 2, 0)
    chkLbl.marginTop    = 0
    chkLbl.marginBottom = 0
    applyDebugOverlay(section, chkLbl)

    local eb = NS.CB_CreateEditBox(section, nil, 180, 20)
    NS.CB_AnchorBelow(eb, chk)
    eb:SetText("Lorem Ipsum")
    eb:SetAutoFocus(false)
    applyDebugOverlay(section, eb)

    local dd = NS.CB_CreateDropdown(section, "CleanBotSampleDropdown" .. gen, 150)
    NS.CB_AnchorBelow(dd, eb)
    UIDropDownMenu_Initialize(dd, function()
        local info = UIDropDownMenu_CreateInfo()
        info.text  = "Lorem Ipsum"
        info.value = 1
        info.func  = function() UIDropDownMenu_SetSelectedValue(dd, 1) end
        UIDropDownMenu_AddButton(info)
    end)
    UIDropDownMenu_SetText(dd, "Lorem Ipsum")
    applyDebugOverlay(section, dd)

    local sl = NS.CB_CreateSlider(section, "CleanBotSampleSlider" .. gen,
        "Lorem Ipsum", 0, 100, 50, "0", "100", nil)
    sl:SetWidth(200)
    NS.CB_AnchorBelow(sl, dd)
    applyDebugOverlay(section, sl)

    local sw = NS.CB_CreateColorSwatch(section, nil, "Lorem Ipsum", 1, 0.5, 0)
    NS.CB_AnchorBelow(sw, sl)
    applyDebugOverlay(section, sw)
end

-- Opens the singleton Sample Layout window, creating it on first call.
local sampleLayoutFrame = nil

--- Opens (creating once) the sample-layout preview window used to tune spacing.
local function showSampleLayout()
    if sampleLayoutFrame and sampleLayoutFrame:IsShown() then
        sampleLayoutFrame:Hide()
        return
    end

    if not sampleLayoutFrame then
        local f = CreateFrame("Frame", "CleanBotSampleLayoutFrame", UIParent)
        NS.CB_RegisterRootFrame(f)
        f:SetSize(380, NS.FRAME_HEIGHT)
        f:SetPoint("TOPLEFT", CleanBotFrame, "TOPRIGHT", 4, 0)
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        if NS.ElvUI_S then f:StripTextures() end
        NS.CB_ApplyFrameSkin(f, 0)
        NS.CB_ApplyTitleBar(f, "Sample Layout")

        -- Stamp padding fields — f is a raw CreateFrame so CB_CreatePanel never runs on it.
        local framePad = NS.PADDING.frame
        f.paddingTop    = framePad.top
        f.paddingBottom = framePad.bottom
        f.paddingLeft   = framePad.left
        f.paddingRight  = framePad.right

        local closeBtn = CreateFrame("Button", "CleanBotSampleLayoutClose", f, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
        closeBtn:SetScript("OnClick", function() f:Hide() end)
        if NS.ElvUI_S then NS.ElvUI_S:HandleCloseButton(closeBtn) end

        -- Panel — level 2, mirrors managePanel/individualPanel inside CleanBotFrame.
        local panel = NS.CB_CreatePanel(f, "CleanBotSamplePanel", 2, "panel")
        panel:SetPoint("TOPLEFT",     f, "TOPLEFT",      f.paddingLeft,   -NS.TITLE_H)
        panel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -f.paddingRight,   f.paddingBottom)
        f._panel = panel

        -- "Show Overlays" checkbox lives on the panel outside the rebuilt section.
        -- Stored on the panel so buildSampleContent can query its height for OVERLAY_ROW_H.
        local overlayCB = NS.CB_CreateCheckBox(panel, "CleanBotSampleLayoutOverlayCB")
        panel._overlayCB = overlayCB
        overlayCB:SetChecked(overlayVisible)
        overlayCB:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT",
            (panel.paddingLeft   or 0) + (overlayCB.marginLeft   or 0),
            (panel.paddingBottom or 0) + (overlayCB.marginBottom or 0))
        local overlayCBLbl = NS.CB_CreateLabel(panel, "Show Overlays")
        overlayCBLbl:SetPoint("LEFT", overlayCB, "RIGHT", 2, 0)
        overlayCB:SetScript("OnClick", function(self)
            local checked = self:GetChecked() and true or false
            self:SetChecked(checked)
            overlayVisible = checked
            for _, overlay in ipairs(overlayFrames) do
                if checked then overlay:Show() else overlay:Hide() end
            end
        end)

        CleanBotFrame:HookScript("OnHide", function()
            if sampleLayoutFrame then sampleLayoutFrame:Hide() end
        end)

        sampleLayoutFrame = f
    end

    sampleLayoutFrame:ClearAllPoints()
    sampleLayoutFrame:SetPoint("TOPLEFT", CleanBotFrame, "TOPRIGHT", 4, 0)
    buildSampleContent(sampleLayoutFrame._panel)
    sampleLayoutFrame:Show()
end

-- ============================================================
-- Settings tab
-- ============================================================

--- Builds the Settings tab: the nested sub-tabs and all their option widgets.
NS.CleanBot_BuildSettingsTab = function()
    NS.settingsPanel = NS.CB_CreatePanel(NS.contentFrame, "CleanBotSettingsPanel", 2, "panel")
    NS.settingsPanel:SetAllPoints(NS.contentFrame)
    NS.settingsPanel:Hide()

    local panel    = NS.settingsPanel
    local SLIDER_W = 130

    local SUB_TAB_H = NS.TOP_BAR_H
    -- Forward declarations — both are defined later but called only at interaction time.
    local syncPendingToUI
    local syncApplyBtn

    -- ── Pending values ─────────────────────────────────────────
    local pendingScale        = NS.scale
    local pendingTransparency = NS.transparency
    local pendingAccentR      = NS.accentColor.r
    local pendingAccentG      = NS.accentColor.g
    local pendingAccentB      = NS.accentColor.b
    local pendingAccentA      = NS.accentColor.a

    local pendingMargins = {}
    for k, v in pairs(NS.MARGIN) do
        pendingMargins[k] = { top = v.top, bottom = v.bottom, left = v.left, right = v.right }
    end

    local pendingPadding = {}
    for k, v in pairs(NS.PADDING) do
        pendingPadding[k] = { top = v.top, bottom = v.bottom, left = v.left, right = v.right }
    end

    -- ── Action buttons ─────────────────────────────────────────
    -- Created first so BTN_ROW_H can query the actual rendered height.
    local defaultsBtn = NS.CB_CreateButton(panel, "CleanBotDefaultsSettings", "Defaults", 80, 22, function()
        pendingScale        = NS.THEME_DEFAULTS.scale
        pendingTransparency = NS.THEME_DEFAULTS.transparency
        pendingAccentR      = NS.THEME_DEFAULTS.accentColor.r
        pendingAccentG      = NS.THEME_DEFAULTS.accentColor.g
        pendingAccentB      = NS.THEME_DEFAULTS.accentColor.b
        pendingAccentA      = NS.THEME_DEFAULTS.accentColor.a
        for k, defaults in pairs(NS.MARGIN_DEFAULTS) do
            pendingMargins[k].top    = defaults.top
            pendingMargins[k].bottom = defaults.bottom
            pendingMargins[k].left   = defaults.left
            pendingMargins[k].right  = defaults.right
        end
        for k, defaults in pairs(NS.PADDING_DEFAULTS) do
            pendingPadding[k].top    = defaults.top
            pendingPadding[k].bottom = defaults.bottom
            pendingPadding[k].left   = defaults.left
            pendingPadding[k].right  = defaults.right
        end
        syncPendingToUI()
    end)
    defaultsBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT",
        (panel.paddingLeft   or 0) + (defaultsBtn.marginLeft   or 0),
        (panel.paddingBottom or 0) + (defaultsBtn.marginBottom or 0))

    local cancelBtn = NS.CB_CreateButton(panel, "CleanBotCancelSettings", "Cancel", 80, 22, function()
        pendingScale        = NS.scale
        pendingTransparency = NS.transparency
        pendingAccentR      = NS.accentColor.r
        pendingAccentG      = NS.accentColor.g
        pendingAccentB      = NS.accentColor.b
        pendingAccentA      = NS.accentColor.a
        local savedMargins  = CleanBot_SavedVars and CleanBot_SavedVars.margins
        for k, defaults in pairs(NS.MARGIN_DEFAULTS) do
            local s = savedMargins and savedMargins[k]
            if type(s) == "table" then
                pendingMargins[k].top    = type(s.top)    == "number" and s.top    or defaults.top
                pendingMargins[k].bottom = type(s.bottom) == "number" and s.bottom or defaults.bottom
                pendingMargins[k].left   = type(s.left)   == "number" and s.left   or defaults.left
                pendingMargins[k].right  = type(s.right)  == "number" and s.right  or defaults.right
            else
                pendingMargins[k].top    = defaults.top
                pendingMargins[k].bottom = defaults.bottom
                pendingMargins[k].left   = defaults.left
                pendingMargins[k].right  = defaults.right
            end
        end
        local savedPadding = CleanBot_SavedVars and CleanBot_SavedVars.padding
        for k, defaults in pairs(NS.PADDING_DEFAULTS) do
            local s = savedPadding and savedPadding[k]
            if type(s) == "table" then
                pendingPadding[k].top    = type(s.top)    == "number" and s.top    or defaults.top
                pendingPadding[k].bottom = type(s.bottom) == "number" and s.bottom or defaults.bottom
                pendingPadding[k].left   = type(s.left)   == "number" and s.left   or defaults.left
                pendingPadding[k].right  = type(s.right)  == "number" and s.right  or defaults.right
            else
                pendingPadding[k].top    = defaults.top
                pendingPadding[k].bottom = defaults.bottom
                pendingPadding[k].left   = defaults.left
                pendingPadding[k].right  = defaults.right
            end
        end
        syncPendingToUI()
    end)
    cancelBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT",
        -((panel.paddingRight  or 0) + (cancelBtn.marginRight  or 0)),
        (panel.paddingBottom   or 0) + (cancelBtn.marginBottom or 0))

    local applyBtn
    applyBtn = NS.CB_CreateButton(panel, "CleanBotApplySettings", "Apply", 80, 22, function()
        -- Scale
        NS.scale = pendingScale
        NS.CB_RefreshScale(NS.scale)
        CleanBot_SavedVars.scale = NS.scale

        -- Transparency (backdrop alpha only — does not cascade to children)
        NS.transparency = pendingTransparency
        NS.CB_RefreshTransparency(NS.transparency)
        CleanBot_SavedVars.transparency = NS.transparency

        -- Accent Color (border colour on all skinned frames, ElvUI and non-ElvUI)
        NS.accentColor.r = pendingAccentR
        NS.accentColor.g = pendingAccentG
        NS.accentColor.b = pendingAccentB
        NS.accentColor.a = pendingAccentA
        NS.CB_RefreshAccentColor(pendingAccentR, pendingAccentG, pendingAccentB, pendingAccentA)
        CleanBot_SavedVars.accentColor = { r = pendingAccentR, g = pendingAccentG, b = pendingAccentB, a = pendingAccentA }

        -- Margins
        if type(CleanBot_SavedVars.margins) ~= "table" then CleanBot_SavedVars.margins = {} end
        for k, v in pairs(pendingMargins) do
            NS.MARGIN[k].top    = v.top
            NS.MARGIN[k].bottom = v.bottom
            NS.MARGIN[k].left   = v.left
            NS.MARGIN[k].right  = v.right
            CleanBot_SavedVars.margins[k] = { top = v.top, bottom = v.bottom, left = v.left, right = v.right }
        end

        -- Padding
        if type(CleanBot_SavedVars.padding) ~= "table" then CleanBot_SavedVars.padding = {} end
        for k, v in pairs(pendingPadding) do
            NS.PADDING[k].top    = v.top
            NS.PADDING[k].bottom = v.bottom
            NS.PADDING[k].left   = v.left
            NS.PADDING[k].right  = v.right
            CleanBot_SavedVars.padding[k] = { top = v.top, bottom = v.bottom, left = v.left, right = v.right }
        end

        if sampleLayoutFrame and sampleLayoutFrame:IsShown() then
            buildSampleContent(sampleLayoutFrame._panel)
        end
        applyBtn:Disable()
        NS.CB_Print("Settings saved. Reload the UI to apply layout changes.")
    end)
    applyBtn:SetPoint("RIGHT", cancelBtn, "LEFT",
        -((applyBtn.marginRight or 0) + (cancelBtn.marginLeft or 0)), 0)
    applyBtn:Disable()

    local BTN_ROW_H = (panel.paddingBottom or 0) + NS.MARGIN.button.bottom + defaultsBtn:GetHeight() + NS.MARGIN.button.top + (panel.paddingBottom or 0)

    -- ── Sub-tab bar ────────────────────────────────────────────
    local subTabBar = CreateFrame("Frame", "CleanBotSettingsSubTabBar", panel)
    subTabBar:SetPoint("TOPLEFT",  panel, "TOPLEFT",  0, 0)
    subTabBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    subTabBar:SetHeight(SUB_TAB_H)

    -- ── Content panels ─────────────────────────────────────────
    local themePanel = NS.CB_CreatePanel(panel, "CleanBotThemePanel", 3, "panel")
    themePanel:SetPoint("TOPLEFT",     panel, "TOPLEFT",     0, -SUB_TAB_H)
    themePanel:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0,  BTN_ROW_H)

    local layoutPanel = NS.CB_CreatePanel(panel, "CleanBotLayoutPanel", 3, "panel")
    layoutPanel:SetPoint("TOPLEFT",     panel, "TOPLEFT",     0, -SUB_TAB_H)
    layoutPanel:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0,  BTN_ROW_H)
    layoutPanel:Hide()

    local otherPanel = NS.CB_CreatePanel(panel, "CleanBotOtherPanel", 3, "panel")
    otherPanel:SetPoint("TOPLEFT",     panel, "TOPLEFT",     0, -SUB_TAB_H)
    otherPanel:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0,  BTN_ROW_H)
    otherPanel:Hide()

    -- ── Sub-tab switching ──────────────────────────────────────
    local subTabs      = {}
    local activeSubTab = 0

    local function selectSubTab(index)
        if activeSubTab == index then return end
        activeSubTab = index
        for i, tab in ipairs(subTabs) do
            tab:SetActive(i == index)
        end
        themePanel:Hide()
        layoutPanel:Hide()
        otherPanel:Hide()
        if index == 1 then
            themePanel:Show()
        elseif index == 2 then
            layoutPanel:Show()
        else
            otherPanel:Show()
        end
    end

    local themeTab = NS.CB_CreateTab(subTabBar, "CleanBotSettingsThemeTab", "Theme",
        function() selectSubTab(1) end)
    themeTab:SetWidth(NS.TAB_WIDTH)
    themeTab:SetPoint("LEFT", subTabBar, "LEFT", (panel.paddingLeft or 0) + (themeTab.marginLeft or 0), 0)
    subTabs[1] = themeTab

    local layoutTab = NS.CB_CreateTab(subTabBar, "CleanBotSettingsLayoutTab", "Layout",
        function() selectSubTab(2) end)
    layoutTab:SetWidth(NS.TAB_WIDTH)
    NS.CB_AnchorAhead(layoutTab, themeTab)
    subTabs[2] = layoutTab

    local otherTab = NS.CB_CreateTab(subTabBar, "CleanBotSettingsOtherTab", "Other",
        function() selectSubTab(3) end)
    otherTab:SetWidth(NS.TAB_WIDTH)
    NS.CB_AnchorAhead(otherTab, layoutTab)
    subTabs[3] = otherTab

    -- ── Theme tab: ScrollFrame ─────────────────────────────────
    local themeSF, themeChild = NS.CB_CreateScrollFrame(themePanel, "CleanBotThemeScroll")
    themeChild:SetHeight(300)

    -- ── Scale ──────────────────────────────────────────────────
    local scaleSlider = NS.CB_CreateSlider(themeChild, "CleanBotScaleSlider", "Scale",
        50, 150, pendingScale, "50%", "150%", function(v) pendingScale = v; if syncApplyBtn then syncApplyBtn() end end)
    scaleSlider:SetWidth(SLIDER_W)
    scaleSlider:SetPoint("TOPLEFT", themeChild, "TOPLEFT",
        (themeChild.paddingLeft or 0) + (scaleSlider.marginLeft or 0),
       -((themeChild.paddingTop or 0) + (scaleSlider.marginTop  or 0)))

    -- ── Transparency ───────────────────────────────────────────
    local transSlider = NS.CB_CreateSlider(themeChild, "CleanBotTransSlider", "Transparency",
        0, 100, pendingTransparency, "0%", "100%", function(v) pendingTransparency = v; if syncApplyBtn then syncApplyBtn() end end)
    transSlider:SetWidth(SLIDER_W)
    NS.CB_AnchorBelow(transSlider, scaleSlider)

    -- ── Accent Color ───────────────────────────────────────────
    local colorSwatch = NS.CB_CreateColorSwatch(themeChild, "CleanBotAccentSwatch", "Accent Color",
        NS.accentColor.r, NS.accentColor.g, NS.accentColor.b,
        function(r, g, b, a)
            pendingAccentR, pendingAccentG, pendingAccentB, pendingAccentA = r, g, b, a
            if syncApplyBtn then syncApplyBtn() end
        end,
        true, NS.accentColor.a)
    NS.CB_AnchorBelow(colorSwatch, transSlider)

    -- ── Layout tab: ScrollFrame ────────────────────────────────
    local layoutSF, layoutChild = NS.CB_CreateScrollFrame(layoutPanel, "CleanBotLayoutScroll")
    layoutChild:SetHeight(1200)

    -- ── Show Sample Layout ─────────────────────────────────────
    local sampleBtn = NS.CB_CreateButton(layoutChild, "CleanBotShowSampleLayout",
        "Show Sample Layout", 140, 22, showSampleLayout)
    sampleBtn:SetPoint("TOPLEFT", layoutChild, "TOPLEFT",
        (layoutChild.paddingLeft or 0) + (sampleBtn.marginLeft or 0),
       -((layoutChild.paddingTop or 0) + (sampleBtn.marginTop  or 0)))

    local COL_TYPE_W = 80
    local COL_GAP    = 10

    local MARGIN_TYPES = {
        { key = "panel",    display = "Panel"    },
        { key = "section",  display = "Section"  },
        { key = "tab",      display = "Tab"      },
        { key = "header",   display = "Header"   },
        { key = "label",    display = "Label"    },
        { key = "button",   display = "Button"   },
        { key = "slider",   display = "Slider"   },
        { key = "dropdown", display = "Dropdown" },
        { key = "checkbox", display = "Checkbox" },
        { key = "swatch",   display = "Swatch"   },
        { key = "editBox",  display = "Edit Box" },
    }

    local PADDING_TYPES = {
        { key = "frame",   display = "Frame"   },
        { key = "panel",   display = "Panel"   },
        { key = "section", display = "Section" },
    }

    local marginSliderRefs  = {}
    local paddingSliderRefs = {}

    -- Scroll child is a borderless void — full width, no content padding.
    -- Subtract the panel padding on both sides (scroll frame inset) plus 20px scroll bar.
    local SEP_W = NS.EXPANDED_WIDTH - (panel.paddingLeft or 0) - (panel.paddingRight or 0) - 20

    -- ── Padding ────────────────────────────────────────────────
    local paddingHeader = NS.CB_CreateHeader(layoutChild, "Padding")
    NS.CB_AnchorBelow(paddingHeader, sampleBtn)

    local paddingSep = NS.CB_CreateSeparator(layoutChild)
    NS.CB_AnchorBelow(paddingSep, paddingHeader)
    paddingSep:SetWidth(SEP_W)

    -- Scroll child is a borderless void — content starts at its left edge (no padding offset).
    local COL_BASE = layoutChild.paddingLeft or 0

    local prevRow = paddingSep
    for i, ptype in ipairs(PADDING_TYPES) do
        local key = ptype.key

        local rowA = CreateFrame("Frame", nil, layoutChild)
        rowA:SetSize(1, 54)
        rowA.marginTop    = NS.MARGIN.label.top
        rowA.marginBottom = 0
        NS.CB_AnchorBelow(rowA, prevRow)

        local nameLabel = NS.CB_CreateLabel(layoutChild, ptype.display)
        nameLabel:SetPoint("TOPLEFT", rowA, "TOPLEFT", COL_BASE, 0)
        nameLabel:SetWidth(COL_TYPE_W)
        nameLabel:SetJustifyH("LEFT")

        local P_MIN, P_MAX = 0, 40
        local topSlider = NS.CB_CreateSlider(layoutChild, "CleanBotPadding_" .. key .. "_Top",
            "Top", P_MIN, P_MAX, NS.PADDING[key].top, tostring(P_MIN), tostring(P_MAX),
            function(v) pendingPadding[key].top = v; if syncApplyBtn then syncApplyBtn() end end)
        topSlider:SetWidth(SLIDER_W)
        topSlider:SetPoint("TOPLEFT", rowA, "TOPLEFT", COL_BASE + COL_TYPE_W + COL_GAP, 0)

        local botSlider = NS.CB_CreateSlider(layoutChild, "CleanBotPadding_" .. key .. "_Bot",
            "Bot", P_MIN, P_MAX, NS.PADDING[key].bottom, tostring(P_MIN), tostring(P_MAX),
            function(v) pendingPadding[key].bottom = v; if syncApplyBtn then syncApplyBtn() end end)
        botSlider:SetWidth(SLIDER_W)
        botSlider:SetPoint("TOPLEFT", rowA, "TOPLEFT", COL_BASE + COL_TYPE_W + COL_GAP + SLIDER_W + COL_GAP, 0)

        local rowB = CreateFrame("Frame", nil, layoutChild)
        rowB:SetSize(1, 54)
        rowB.marginTop    = 0
        rowB.marginBottom = NS.MARGIN.slider.bottom
        NS.CB_AnchorBelow(rowB, rowA)

        local leftSlider = NS.CB_CreateSlider(layoutChild, "CleanBotPadding_" .. key .. "_Left",
            "Left", P_MIN, P_MAX, NS.PADDING[key].left, tostring(P_MIN), tostring(P_MAX),
            function(v) pendingPadding[key].left = v; if syncApplyBtn then syncApplyBtn() end end)
        leftSlider:SetWidth(SLIDER_W)
        leftSlider:SetPoint("TOPLEFT", rowB, "TOPLEFT", COL_BASE + COL_TYPE_W + COL_GAP, 0)

        local rightSlider = NS.CB_CreateSlider(layoutChild, "CleanBotPadding_" .. key .. "_Right",
            "Right", P_MIN, P_MAX, NS.PADDING[key].right, tostring(P_MIN), tostring(P_MAX),
            function(v) pendingPadding[key].right = v; if syncApplyBtn then syncApplyBtn() end end)
        rightSlider:SetWidth(SLIDER_W)
        rightSlider:SetPoint("TOPLEFT", rowB, "TOPLEFT", COL_BASE + COL_TYPE_W + COL_GAP + SLIDER_W + COL_GAP, 0)

        paddingSliderRefs[key] = { top = topSlider, bot = botSlider, left = leftSlider, right = rightSlider }
        prevRow = rowB
        if i < #PADDING_TYPES then
            local sep = NS.CB_CreateSeparator(layoutChild)
            NS.CB_AnchorBelow(sep, rowB)
            sep:SetWidth(SEP_W)
            prevRow = sep
        end
    end

    -- ── Margins ────────────────────────────────────────────────
    local marginsHeader = NS.CB_CreateHeader(layoutChild, "Margins")
    marginsHeader.marginTop = NS.MARGIN.header.top + 8
    NS.CB_AnchorBelow(marginsHeader, prevRow)

    local marginsSep = NS.CB_CreateSeparator(layoutChild)
    NS.CB_AnchorBelow(marginsSep, marginsHeader)
    marginsSep:SetWidth(SEP_W)

    prevRow = marginsSep
    for i, mtype in ipairs(MARGIN_TYPES) do
        local key = mtype.key

        -- Top/Bot sub-row — carries the type name label on the left.
        local rowA = CreateFrame("Frame", nil, layoutChild)
        rowA:SetSize(1, 54)
        rowA.marginTop    = NS.MARGIN.label.top
        rowA.marginBottom = 0
        NS.CB_AnchorBelow(rowA, prevRow)

        local nameLabel = NS.CB_CreateLabel(layoutChild, mtype.display)
        nameLabel:SetPoint("TOPLEFT", rowA, "TOPLEFT", COL_BASE, 0)
        nameLabel:SetWidth(COL_TYPE_W)
        nameLabel:SetJustifyH("LEFT")

        local M_RANGE = 20
        local topSlider = NS.CB_CreateSlider(layoutChild, "CleanBotMargin_" .. key .. "_Top",
            "Top", -M_RANGE, M_RANGE, NS.MARGIN[key].top, "-" .. M_RANGE, tostring(M_RANGE),
            function(v) pendingMargins[key].top = v; if syncApplyBtn then syncApplyBtn() end end)
        topSlider:SetWidth(SLIDER_W)
        topSlider:SetPoint("TOPLEFT", rowA, "TOPLEFT", COL_BASE + COL_TYPE_W + COL_GAP, 0)

        local botSlider = NS.CB_CreateSlider(layoutChild, "CleanBotMargin_" .. key .. "_Bot",
            "Bot", -M_RANGE, M_RANGE, NS.MARGIN[key].bottom, "-" .. M_RANGE, tostring(M_RANGE),
            function(v) pendingMargins[key].bottom = v; if syncApplyBtn then syncApplyBtn() end end)
        botSlider:SetWidth(SLIDER_W)
        botSlider:SetPoint("TOPLEFT", rowA, "TOPLEFT", COL_BASE + COL_TYPE_W + COL_GAP + SLIDER_W + COL_GAP, 0)

        -- Left/Right sub-row — flush below Top/Bot, no extra gap between them.
        local rowB = CreateFrame("Frame", nil, layoutChild)
        rowB:SetSize(1, 54)
        rowB.marginTop    = 0
        rowB.marginBottom = NS.MARGIN.slider.bottom
        NS.CB_AnchorBelow(rowB, rowA)

        local leftSlider = NS.CB_CreateSlider(layoutChild, "CleanBotMargin_" .. key .. "_Left",
            "Left", -M_RANGE, M_RANGE, NS.MARGIN[key].left, "-" .. M_RANGE, tostring(M_RANGE),
            function(v) pendingMargins[key].left = v; if syncApplyBtn then syncApplyBtn() end end)
        leftSlider:SetWidth(SLIDER_W)
        leftSlider:SetPoint("TOPLEFT", rowB, "TOPLEFT", COL_BASE + COL_TYPE_W + COL_GAP, 0)

        local rightSlider = NS.CB_CreateSlider(layoutChild, "CleanBotMargin_" .. key .. "_Right",
            "Right", -M_RANGE, M_RANGE, NS.MARGIN[key].right, "-" .. M_RANGE, tostring(M_RANGE),
            function(v) pendingMargins[key].right = v; if syncApplyBtn then syncApplyBtn() end end)
        rightSlider:SetWidth(SLIDER_W)
        rightSlider:SetPoint("TOPLEFT", rowB, "TOPLEFT", COL_BASE + COL_TYPE_W + COL_GAP + SLIDER_W + COL_GAP, 0)

        marginSliderRefs[key] = { top = topSlider, bot = botSlider, left = leftSlider, right = rightSlider }
        prevRow = rowB
        if i < #MARGIN_TYPES then
            local sep = NS.CB_CreateSeparator(layoutChild)
            NS.CB_AnchorBelow(sep, rowB)
            sep:SetWidth(SEP_W)
            prevRow = sep
        end
    end

    -- ── Other tab: Bot Emotes ──────────────────────────────────
    local botEmotesHeader = NS.CB_CreateHeader(otherPanel, "Behaviour")
    botEmotesHeader:SetPoint("TOPLEFT", otherPanel, "TOPLEFT",
        (otherPanel.paddingLeft or 0) + (botEmotesHeader.marginLeft or 0),
        -((otherPanel.paddingTop or 0) + (botEmotesHeader.marginTop  or 0)))

    local botEmotesCB = NS.CB_CreateCheckBox(otherPanel, "CleanBotBotEmotesCB")
    botEmotesCB:SetChecked(NS.botEmotes)
    NS.CB_AnchorBelow(botEmotesCB, botEmotesHeader)

    -- A small invisible frame over the label text catches mouse events for the tooltip.
    local botEmotesCBLbl = NS.CB_CreateLabel(otherPanel, "Enable Bot Emotes")
    botEmotesCBLbl:SetPoint("LEFT", botEmotesCB, "RIGHT", 2, 0)

    local botEmotesCBLblHit = CreateFrame("Frame", nil, otherPanel)
    botEmotesCBLblHit:SetPoint("LEFT",  botEmotesCBLbl, "LEFT",  0,  0)
    botEmotesCBLblHit:SetPoint("RIGHT", botEmotesCBLbl, "RIGHT", 0,  0)
    botEmotesCBLblHit:SetHeight(20)
    botEmotesCBLblHit:EnableMouse(true)

    -- Tooltip on hover over the checkbox or its label.
    local EMOTE_TOOLTIP = "When enabled, switching to a bot's tab in the Individual panel sends an \"emote wave\" command, making them wave at you."
    local function showEmoteTooltip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
        GameTooltip:SetText(EMOTE_TOOLTIP, nil, nil, nil, nil, true)
        GameTooltip:Show()
    end
    botEmotesCB:SetScript("OnEnter",       function(self) showEmoteTooltip(self) end)
    botEmotesCB:SetScript("OnLeave",       function()     GameTooltip:Hide()     end)
    botEmotesCBLblHit:SetScript("OnEnter", function(self) showEmoteTooltip(self) end)
    botEmotesCBLblHit:SetScript("OnLeave", function()     GameTooltip:Hide()     end)

    botEmotesCB:SetScript("OnClick", function(self)
        local checked = self:GetChecked() and true or false
        self:SetChecked(checked)
        NS.botEmotes = checked
        CleanBot_SavedVars.botEmotes = checked
    end)

    -- ── Sync helper ────────────────────────────────────────────
    syncPendingToUI = function()
        scaleSlider:SetValue(pendingScale)
        transSlider:SetValue(pendingTransparency)
        colorSwatch:setColor(pendingAccentR, pendingAccentG, pendingAccentB, pendingAccentA)
        for key, refs in pairs(marginSliderRefs) do
            refs.top:SetValue(pendingMargins[key].top)
            refs.bot:SetValue(pendingMargins[key].bottom)
            refs.left:SetValue(pendingMargins[key].left)
            refs.right:SetValue(pendingMargins[key].right)
        end
        for key, refs in pairs(paddingSliderRefs) do
            refs.top:SetValue(pendingPadding[key].top)
            refs.bot:SetValue(pendingPadding[key].bottom)
            refs.left:SetValue(pendingPadding[key].left)
            refs.right:SetValue(pendingPadding[key].right)
        end
        syncApplyBtn()
    end

    syncApplyBtn = function()
        local dirty = pendingScale ~= NS.scale
            or pendingTransparency ~= NS.transparency
            or pendingAccentR ~= NS.accentColor.r
            or pendingAccentG ~= NS.accentColor.g
            or pendingAccentB ~= NS.accentColor.b
            or pendingAccentA ~= NS.accentColor.a
        if not dirty then
            for k, v in pairs(pendingMargins) do
                local m = NS.MARGIN[k]
                if m and (v.top ~= m.top or v.bottom ~= m.bottom or v.left ~= m.left or v.right ~= m.right) then
                    dirty = true
                    break
                end
            end
        end
        if not dirty then
            for k, v in pairs(pendingPadding) do
                local p = NS.PADDING[k]
                if p and (v.top ~= p.top or v.bottom ~= p.bottom or v.left ~= p.left or v.right ~= p.right) then
                    dirty = true
                    break
                end
            end
        end
        if dirty then applyBtn:Enable() else applyBtn:Disable() end
    end

    selectSubTab(1)
end
