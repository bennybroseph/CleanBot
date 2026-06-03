-- ============================================================
-- CleanBotSettingsTab.lua  —  Settings tab content
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

-- Green overlay on widget bounds; yellow overlays for margins.
-- Overlay frames are parented to 'parent' above its children.
local function applyDebugOverlay(parent, widget)
    local mTop    = widget.marginTop    or 0
    local mBottom = widget.marginBottom or 0
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
end

local sampleContent  = nil
local sampleGenCount = 0

-- Tears down the previous widget set and rebuilds inside 'body'.
local function buildSampleContent(body)
    if sampleContent then sampleContent:Hide() end
    overlayFrames  = {}
    sampleGenCount = sampleGenCount + 1
    local gen     = sampleGenCount
    local PAD     = NS.PAD

    local content = CreateFrame("Frame", nil, body)
    content:SetPoint("TOPLEFT",     body, "TOPLEFT",     PAD, -PAD)
    content:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -PAD, PAD)
    sampleContent = content

    local header = NS.CB_CreateHeader(content, "Lorem Ipsum")
    header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    applyDebugOverlay(content, header)

    local lbl = NS.CB_CreateLabel(content, "Lorem Ipsum")
    NS.CB_AnchorBelow(lbl, header)
    applyDebugOverlay(content, lbl)

    local btn = NS.CB_CreateButton(content, nil, "Lorem Ipsum", 120, 22)
    NS.CB_AnchorBelow(btn, lbl)
    applyDebugOverlay(content, btn)

    local chk = NS.CB_CreateCheckBox(content, nil)
    NS.CB_AnchorBelow(chk, btn)
    applyDebugOverlay(content, chk)
    local chkLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    chkLbl:SetText("Lorem Ipsum")
    chkLbl:SetPoint("LEFT", chk, "RIGHT", 2, 0)
    chkLbl.marginTop    = 0
    chkLbl.marginBottom = 0
    applyDebugOverlay(content, chkLbl)

    local eb = NS.CB_CreateEditBox(content, nil, 180, 20)
    NS.CB_AnchorBelow(eb, chk)
    eb:SetText("Lorem Ipsum")
    eb:SetAutoFocus(false)
    applyDebugOverlay(content, eb)

    local dd = NS.CB_CreateDropdown(content, "CleanBotSampleDropdown" .. gen, 150)
    NS.CB_AnchorBelow(dd, eb)
    UIDropDownMenu_Initialize(dd, function()
        local info = UIDropDownMenu_CreateInfo()
        info.text  = "Lorem Ipsum"
        info.value = 1
        info.func  = function() UIDropDownMenu_SetSelectedValue(dd, 1) end
        UIDropDownMenu_AddButton(info)
    end)
    UIDropDownMenu_SetText(dd, "Lorem Ipsum")
    applyDebugOverlay(content, dd)

    local sl = NS.CB_CreateSlider(content, "CleanBotSampleSlider" .. gen,
        "Lorem Ipsum", 0, 100, 50, "0", "100", nil)
    sl:SetWidth(200)
    NS.CB_AnchorBelow(sl, dd)
    applyDebugOverlay(content, sl)

    local sw = NS.CB_CreateColorSwatch(content, nil, "Lorem Ipsum", 1, 0.5, 0)
    NS.CB_AnchorBelow(sw, sl)
    applyDebugOverlay(content, sw)
end

-- Opens the singleton Sample Layout window, creating it on first call.
local sampleLayoutFrame = nil

local function showSampleLayout()
    local PAD       = NS.PAD
    local BTN_ROW_H = PAD + 22 + PAD
    local TITLE_H   = NS.TOP_BAR_H

    if not sampleLayoutFrame then
        local f = CreateFrame("Frame", "CleanBotSampleLayoutFrame", UIParent)
        f:SetSize(380, 520)
        f:SetPoint("TOPLEFT", CleanBotFrame, "TOPRIGHT", 4, 0)
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        NS.CB_ApplyPanelSkin(f)

        local titleLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        titleLbl:SetText("Sample Layout")
        titleLbl:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD)

        local closeBtn = CreateFrame("Button", "CleanBotSampleLayoutClose", f, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
        closeBtn:SetScript("OnClick", function() f:Hide() end)
        if NS.ElvUI_S then NS.ElvUI_S:HandleCloseButton(closeBtn) end

        local body = CreateFrame("Frame", nil, f)
        body:SetPoint("TOPLEFT",     f, "TOPLEFT",     0, -TITLE_H)
        body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0,  BTN_ROW_H)
        f._body = body

        local overlayCB = NS.CB_CreateCheckBox(f, "CleanBotSampleLayoutOverlayCB")
        overlayCB:SetChecked(overlayVisible)
        overlayCB:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, PAD)
        local overlayCBLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        overlayCBLbl:SetText("Show Overlays")
        overlayCBLbl:SetPoint("LEFT", overlayCB, "RIGHT", 2, 0)
        overlayCB:SetScript("OnClick", function(self)
            local checked = self:GetChecked() and true or false
            self:SetChecked(checked)
            overlayVisible = checked
            for _, overlay in ipairs(overlayFrames) do
                if checked then overlay:Show() else overlay:Hide() end
            end
        end)

        sampleLayoutFrame = f
    end

    sampleLayoutFrame:ClearAllPoints()
    sampleLayoutFrame:SetPoint("TOPLEFT", CleanBotFrame, "TOPRIGHT", 4, 0)
    buildSampleContent(sampleLayoutFrame._body)
    sampleLayoutFrame:Show()
end

-- ============================================================
-- Settings tab
-- ============================================================

NS.CleanBot_BuildSettingsContent = function()
    local panel    = NS.settingsPanel
    local PAD      = NS.PAD
    local SLIDER_W = 200

    local BTN_ROW_H = PAD + 22 + PAD
    local SUB_TAB_H = NS.TOP_BAR_H

    -- ── Pending values ─────────────────────────────────────────
    local pendingScale        = 100
    local pendingTransparency = 100
    local pendingAccentR, pendingAccentG, pendingAccentB = 1, 1, 1

    local pendingMargins = {}
    for k, v in pairs(NS.MARGIN) do
        pendingMargins[k] = { top = v.top, bottom = v.bottom, left = v.left, right = v.right }
    end

    -- ── Sub-tab bar ────────────────────────────────────────────
    local subTabBar = CreateFrame("Frame", "CleanBotSettingsSubTabBar", panel)
    subTabBar:SetPoint("TOPLEFT",  panel, "TOPLEFT",  0, 0)
    subTabBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    subTabBar:SetHeight(SUB_TAB_H)

    -- ── Content panels ─────────────────────────────────────────
    local themePanel = CreateFrame("Frame", "CleanBotThemePanel", panel)
    themePanel:SetPoint("TOPLEFT",     panel, "TOPLEFT",     0, -SUB_TAB_H)
    themePanel:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0,  BTN_ROW_H)

    local layoutPanel = CreateFrame("Frame", "CleanBotLayoutPanel", panel)
    layoutPanel:SetPoint("TOPLEFT",     panel, "TOPLEFT",     0, -SUB_TAB_H)
    layoutPanel:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0,  BTN_ROW_H)
    layoutPanel:Hide()

    -- ── Sub-tab switching ──────────────────────────────────────
    local subTabs      = {}
    local activeSubTab = 0

    local function selectSubTab(index)
        if activeSubTab == index then return end
        activeSubTab = index
        for i, tab in ipairs(subTabs) do
            if i == index then
                tab:SetNormalFontObject(GameFontHighlightSmall)
                tab:SetButtonState("PUSHED", true)
            else
                tab:SetNormalFontObject(GameFontNormalSmall)
                tab:SetButtonState("NORMAL")
            end
        end
        if index == 1 then
            themePanel:Show()
            layoutPanel:Hide()
        else
            themePanel:Hide()
            layoutPanel:Show()
        end
    end

    local themeTab = NS.CB_CreateButton(subTabBar, "CleanBotSettingsThemeTab", "Theme",
        NS.TAB_WIDTH, NS.TAB_HEIGHT, function() selectSubTab(1) end)
    themeTab:SetPoint("LEFT", subTabBar, "LEFT", PAD, 0)
    themeTab:SetNormalFontObject(GameFontNormalSmall)
    subTabs[1] = themeTab

    local layoutTab = NS.CB_CreateButton(subTabBar, "CleanBotSettingsLayoutTab", "Layout",
        NS.TAB_WIDTH, NS.TAB_HEIGHT, function() selectSubTab(2) end)
    layoutTab:SetPoint("LEFT", themeTab, "RIGHT", 2, 0)
    layoutTab:SetNormalFontObject(GameFontNormalSmall)
    subTabs[2] = layoutTab

    -- ── Theme tab: ScrollFrame ─────────────────────────────────
    local themeSF = CreateFrame("ScrollFrame", "CleanBotThemeScroll", themePanel, "UIPanelScrollFrameTemplate")
    themeSF:SetPoint("TOPLEFT",     themePanel, "TOPLEFT",     0,   0)
    themeSF:SetPoint("BOTTOMRIGHT", themePanel, "BOTTOMRIGHT", -20, 0)

    local themeChild = CreateFrame("Frame", "CleanBotThemeScrollChild", themeSF)
    themeChild:SetWidth(NS.FRAME_WIDTH - 28)
    themeChild:SetHeight(300)
    themeSF:SetScrollChild(themeChild)

    themeSF:EnableMouseWheel(true)
    themeSF:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local max     = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, current - delta * 20)))
    end)

    local themeScrollBar = CleanBotThemeScrollScrollBar
    themeScrollBar:ClearAllPoints()
    themeScrollBar:SetPoint("TOPRIGHT",    themePanel, "TOPRIGHT",    0, -19)
    themeScrollBar:SetPoint("BOTTOMRIGHT", themePanel, "BOTTOMRIGHT", 0,  19)
    if NS.ElvUI_S then NS.ElvUI_S:HandleScrollBar(themeScrollBar) end

    -- ── Scale ──────────────────────────────────────────────────
    local scaleSlider = NS.CB_CreateSlider(themeChild, "CleanBotScaleSlider", "Scale",
        50, 150, 100, "50%", "150%", function(v) pendingScale = v end)
    scaleSlider:SetWidth(SLIDER_W)
    scaleSlider:SetPoint("TOPLEFT", themeChild, "TOPLEFT", PAD, -PAD)

    -- ── Transparency ───────────────────────────────────────────
    local transSlider = NS.CB_CreateSlider(themeChild, "CleanBotTransSlider", "Transparency",
        0, 100, 100, "0%", "100%", function(v) pendingTransparency = v end)
    transSlider:SetWidth(SLIDER_W)
    NS.CB_AnchorBelow(transSlider, scaleSlider)

    -- ── Accent Color ───────────────────────────────────────────
    local colorSwatch = NS.CB_CreateColorSwatch(themeChild, "CleanBotAccentSwatch", "Accent Color", 1, 1, 1,
        function(r, g, b)
            pendingAccentR, pendingAccentG, pendingAccentB = r, g, b
        end)
    NS.CB_AnchorBelow(colorSwatch, transSlider)

    -- ── Layout tab: ScrollFrame ────────────────────────────────
    local layoutSF = CreateFrame("ScrollFrame", "CleanBotLayoutScroll", layoutPanel, "UIPanelScrollFrameTemplate")
    layoutSF:SetPoint("TOPLEFT",     layoutPanel, "TOPLEFT",     0,   0)
    layoutSF:SetPoint("BOTTOMRIGHT", layoutPanel, "BOTTOMRIGHT", -20, 0)

    local layoutChild = CreateFrame("Frame", "CleanBotLayoutScrollChild", layoutSF)
    layoutChild:SetWidth(NS.FRAME_WIDTH - 28)
    layoutChild:SetHeight(900)
    layoutSF:SetScrollChild(layoutChild)

    layoutSF:EnableMouseWheel(true)
    layoutSF:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local max     = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, current - delta * 20)))
    end)

    local layoutScrollBar = CleanBotLayoutScrollScrollBar
    layoutScrollBar:ClearAllPoints()
    layoutScrollBar:SetPoint("TOPRIGHT",    layoutPanel, "TOPRIGHT",    0, -19)
    layoutScrollBar:SetPoint("BOTTOMRIGHT", layoutPanel, "BOTTOMRIGHT", 0,  19)
    if NS.ElvUI_S then NS.ElvUI_S:HandleScrollBar(layoutScrollBar) end

    -- ── Margins ────────────────────────────────────────────────
    local marginsHeader = NS.CB_CreateHeader(layoutChild, "Margins")
    marginsHeader:SetPoint("TOPLEFT", layoutChild, "TOPLEFT", PAD, -PAD)

    -- ── Show Sample Layout ─────────────────────────────────────
    local sampleBtn = NS.CB_CreateButton(layoutChild, "CleanBotShowSampleLayout",
        "Show Sample Layout", 140, 22, showSampleLayout)
    NS.CB_AnchorBelow(sampleBtn, marginsHeader)

    local COL_TYPE_W = 80
    local COL_GAP    = 10

    local MARGIN_TYPES = {
        { key = "header",   display = "Header"   },
        { key = "label",    display = "Label"    },
        { key = "button",   display = "Button"   },
        { key = "slider",   display = "Slider"   },
        { key = "dropdown", display = "Dropdown" },
        { key = "checkbox", display = "Checkbox" },
        { key = "swatch",   display = "Swatch"   },
        { key = "editBox",  display = "Edit Box" },
    }

    local marginSliderRefs = {}

    local prevRow = sampleBtn
    for _, mtype in ipairs(MARGIN_TYPES) do
        local key = mtype.key

        -- Top/Bot sub-row — carries the type name label on the left.
        local rowA = CreateFrame("Frame", nil, layoutChild)
        rowA:SetSize(1, 54)
        rowA.marginTop    = NS.MARGIN.label.top
        rowA.marginBottom = 0
        NS.CB_AnchorBelow(rowA, prevRow)

        local nameLabel = layoutChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameLabel:SetText(mtype.display)
        nameLabel:SetPoint("TOPLEFT", rowA, "TOPLEFT", PAD, 0)
        nameLabel:SetWidth(COL_TYPE_W)
        nameLabel:SetJustifyH("LEFT")

        local topSlider = NS.CB_CreateSlider(layoutChild, "CleanBotMargin_" .. key .. "_Top",
            "Top", -12, 12, NS.MARGIN[key].top, "-12", "12",
            function(v) pendingMargins[key].top = v end)
        topSlider:SetWidth(SLIDER_W)
        topSlider:SetPoint("TOPLEFT", rowA, "TOPLEFT", PAD + COL_TYPE_W + COL_GAP, 0)

        local botSlider = NS.CB_CreateSlider(layoutChild, "CleanBotMargin_" .. key .. "_Bot",
            "Bot", -12, 12, NS.MARGIN[key].bottom, "-12", "12",
            function(v) pendingMargins[key].bottom = v end)
        botSlider:SetWidth(SLIDER_W)
        botSlider:SetPoint("TOPLEFT", rowA, "TOPLEFT", PAD + COL_TYPE_W + COL_GAP + SLIDER_W + COL_GAP, 0)

        -- Left/Right sub-row — flush below Top/Bot, no extra gap between them.
        local rowB = CreateFrame("Frame", nil, layoutChild)
        rowB:SetSize(1, 54)
        rowB.marginTop    = 0
        rowB.marginBottom = NS.MARGIN.slider.bottom
        NS.CB_AnchorBelow(rowB, rowA)

        local leftSlider = NS.CB_CreateSlider(layoutChild, "CleanBotMargin_" .. key .. "_Left",
            "Left", -12, 12, NS.MARGIN[key].left, "-12", "12",
            function(v) pendingMargins[key].left = v end)
        leftSlider:SetWidth(SLIDER_W)
        leftSlider:SetPoint("TOPLEFT", rowB, "TOPLEFT", PAD + COL_TYPE_W + COL_GAP, 0)

        local rightSlider = NS.CB_CreateSlider(layoutChild, "CleanBotMargin_" .. key .. "_Right",
            "Right", -12, 12, NS.MARGIN[key].right, "-12", "12",
            function(v) pendingMargins[key].right = v end)
        rightSlider:SetWidth(SLIDER_W)
        rightSlider:SetPoint("TOPLEFT", rowB, "TOPLEFT", PAD + COL_TYPE_W + COL_GAP + SLIDER_W + COL_GAP, 0)

        marginSliderRefs[key] = { top = topSlider, bot = botSlider, left = leftSlider, right = rightSlider }
        prevRow = rowB
    end

    -- ── Sync helper ────────────────────────────────────────────
    local function syncPendingToUI()
        scaleSlider:SetValue(pendingScale)
        transSlider:SetValue(pendingTransparency)
        colorSwatch:setColor(pendingAccentR, pendingAccentG, pendingAccentB)
        for key, refs in pairs(marginSliderRefs) do
            refs.top:SetValue(pendingMargins[key].top)
            refs.bot:SetValue(pendingMargins[key].bottom)
            refs.left:SetValue(pendingMargins[key].left)
            refs.right:SetValue(pendingMargins[key].right)
        end
    end

    -- ── Action buttons ─────────────────────────────────────────
    local defaultsBtn = NS.CB_CreateButton(panel, "CleanBotDefaultsSettings", "Defaults", 80, 22, function()
        pendingScale        = 100
        pendingTransparency = 100
        pendingAccentR, pendingAccentG, pendingAccentB = 1, 1, 1
        for k, defaults in pairs(NS.MARGIN_DEFAULTS) do
            pendingMargins[k].top    = defaults.top
            pendingMargins[k].bottom = defaults.bottom
            pendingMargins[k].left   = defaults.left
            pendingMargins[k].right  = defaults.right
        end
        syncPendingToUI()
    end)
    defaultsBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD, PAD)

    local cancelBtn = NS.CB_CreateButton(panel, "CleanBotCancelSettings", "Cancel", 80, 22, function()
        pendingScale        = 100
        pendingTransparency = 100
        pendingAccentR, pendingAccentG, pendingAccentB = 1, 1, 1
        local saved = CleanBot_SavedVars and CleanBot_SavedVars.margins
        for k, defaults in pairs(NS.MARGIN_DEFAULTS) do
            local s = saved and saved[k]
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
        syncPendingToUI()
    end)
    cancelBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, PAD)

    local applyBtn = NS.CB_CreateButton(panel, "CleanBotApplySettings", "Apply", 80, 22, function()
        -- TODO: apply pendingScale to frame scale
        -- TODO: apply pendingTransparency to frame alpha
        -- TODO: apply pendingAccentR/G/B as accent color
        if type(CleanBot_SavedVars.margins) ~= "table" then CleanBot_SavedVars.margins = {} end
        for k, v in pairs(pendingMargins) do
            NS.MARGIN[k].top    = v.top
            NS.MARGIN[k].bottom = v.bottom
            NS.MARGIN[k].left   = v.left
            NS.MARGIN[k].right  = v.right
            CleanBot_SavedVars.margins[k] = { top = v.top, bottom = v.bottom, left = v.left, right = v.right }
        end
        if sampleLayoutFrame and sampleLayoutFrame:IsShown() then
            buildSampleContent(sampleLayoutFrame._body)
        end
        NS.CB_Print("Margin values saved. Reload the UI to see layout changes.")
    end)
    applyBtn:SetPoint("RIGHT", cancelBtn, "LEFT", -8, 0)

    selectSubTab(1)
end
