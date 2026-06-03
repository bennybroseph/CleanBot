-- ============================================================
-- CleanBotSettingsTab.lua  —  Settings tab content
-- ============================================================
local NS = CleanBotNS

NS.CleanBot_BuildSettingsContent = function()
    local panel    = NS.settingsPanel
    local PAD      = NS.PAD
    local SLIDER_W = 200

    -- Space reserved at the bottom of the panel for the always-visible action buttons.
    local BTN_ROW_H = PAD + 22 + PAD

    -- ── ScrollFrame ────────────────────────────────────────────
    -- Fills the panel above the button row. The scroll child holds all settings
    -- content; the 20px right inset leaves room for the scrollbar.
    local sf = CreateFrame("ScrollFrame", "CleanBotSettingsScroll", panel, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     panel, "TOPLEFT",     0,   0)
    sf:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -20, BTN_ROW_H)

    local child = CreateFrame("Frame", "CleanBotSettingsScrollChild", sf)
    child:SetWidth(NS.FRAME_WIDTH - 28)  -- frame width - content insets (8) - scrollbar area (20)
    child:SetHeight(100)
    sf:SetScrollChild(child)

    -- Manually pin the scrollbar flush against the panel's inner border.
    -- 2px inset on all sides clears the backdrop edge (insets=3, edgeSize=12)
    -- and keeps it within the visible content area.
    local scrollBar = CleanBotSettingsScrollScrollBar
    scrollBar:ClearAllPoints()
    scrollBar:SetPoint("TOPRIGHT",    panel, "TOPRIGHT",    0, -19)
    scrollBar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, BTN_ROW_H + 19)
    if NS.ElvUI_S then NS.ElvUI_S:HandleScrollBar(scrollBar) end

    -- ── Pending values ─────────────────────────────────────────
    -- Hold uncommitted user input until Accept is pressed.
    local pendingScale        = 100
    local pendingTransparency = 100
    local pendingAccentR, pendingAccentG, pendingAccentB = 1, 1, 1

    -- Copy of NS.MARGIN (already loaded from SavedVars at login).
    local pendingMargins = {}
    for k, v in pairs(NS.MARGIN) do
        pendingMargins[k] = { top = v.top, bottom = v.bottom }
    end

    -- ── Scale ──────────────────────────────────────────────────
    local scaleSlider = NS.CB_CreateSlider(child, "CleanBotScaleSlider", "Scale",
        50, 150, 100, "50%", "150%", function(v) pendingScale = v end)
    scaleSlider:SetWidth(SLIDER_W)
    scaleSlider:SetPoint("TOPLEFT", child, "TOPLEFT", PAD, -PAD)

    -- ── Transparency ───────────────────────────────────────────
    local transSlider = NS.CB_CreateSlider(child, "CleanBotTransSlider", "Transparency",
        0, 100, 100, "0%", "100%", function(v) pendingTransparency = v end)
    transSlider:SetWidth(SLIDER_W)
    NS.CB_AnchorBelow(transSlider, scaleSlider)

    -- ── Accent Color ───────────────────────────────────────────
    local accentLabel = NS.CB_CreateLabel(child, "Accent Color")
    NS.CB_AnchorBelow(accentLabel, transSlider)

    local colorSwatch = NS.CB_CreateColorSwatch(child, "CleanBotAccentSwatch", 1, 1, 1,
        function(r, g, b)
            pendingAccentR, pendingAccentG, pendingAccentB = r, g, b
        end)
    NS.CB_AnchorBelow(colorSwatch, accentLabel)

    -- ── Margins ────────────────────────────────────────────────
    -- Live-tuning panel for NS.MARGIN values. Each row shows the type name on
    -- the left with a Top and Bot slider side by side. Values are committed on
    -- Accept and require a UI reload for existing widget positions to reflect them.
    local marginsLabel = NS.CB_CreateLabel(child, "Margins")
    NS.CB_AnchorBelow(marginsLabel, colorSwatch)

    local COL_TYPE_W = 80
    local COL_GAP    = 10

    local MARGIN_TYPES = {
        { key = "label",    display = "Label"    },
        { key = "button",   display = "Button"   },
        { key = "slider",   display = "Slider"   },
        { key = "dropdown", display = "Dropdown" },
        { key = "checkbox", display = "Checkbox" },
        { key = "swatch",   display = "Swatch"   },
        { key = "editBox",  display = "Edit Box" },
    }

    local marginSliderRefs = {}

    local prevRow = marginsLabel
    for _, mtype in ipairs(MARGIN_TYPES) do
        local key = mtype.key

        -- Invisible anchor frame sized to the titled slider height (54px) so the
        -- vertical chain correctly clears the full title+slider+editbox stack.
        local rowAnchor = CreateFrame("Frame", nil, child)
        rowAnchor:SetSize(1, 54)
        rowAnchor.marginTop    = NS.MARGIN.label.top
        rowAnchor.marginBottom = NS.MARGIN.slider.bottom
        NS.CB_AnchorBelow(rowAnchor, prevRow)

        -- Type name aligns with the "Top"/"Bot" title labels inside each slider.
        local nameLabel = child:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameLabel:SetText(mtype.display)
        nameLabel:SetPoint("TOPLEFT", rowAnchor, "TOPLEFT", PAD, 0)
        nameLabel:SetWidth(COL_TYPE_W)
        nameLabel:SetJustifyH("LEFT")

        local topSlider = NS.CB_CreateSlider(child, "CleanBotMargin_" .. key .. "_Top",
            "Top", -12, 12, NS.MARGIN[key].top, "-12", "12",
            function(v) pendingMargins[key].top = v end)
        topSlider:SetWidth(SLIDER_W)
        topSlider:SetPoint("TOPLEFT", rowAnchor, "TOPLEFT", PAD + COL_TYPE_W + COL_GAP, 0)

        local botSlider = NS.CB_CreateSlider(child, "CleanBotMargin_" .. key .. "_Bot",
            "Bot", -12, 12, NS.MARGIN[key].bottom, "-12", "12",
            function(v) pendingMargins[key].bottom = v end)
        botSlider:SetWidth(SLIDER_W)
        botSlider:SetPoint("TOPLEFT", rowAnchor, "TOPLEFT",
                           PAD + COL_TYPE_W + COL_GAP + SLIDER_W + COL_GAP, 0)

        marginSliderRefs[key] = { top = topSlider, bot = botSlider }
        prevRow = rowAnchor
    end

    -- ── Sync helper ────────────────────────────────────────────
    -- Pushes all pending values into the UI widgets. Each SetValue fires the
    -- slider's internal OnValueChanged which updates the editbox and onChange.
    local function syncPendingToUI()
        scaleSlider:SetValue(pendingScale)
        transSlider:SetValue(pendingTransparency)
        colorSwatch:setColor(pendingAccentR, pendingAccentG, pendingAccentB)
        for key, refs in pairs(marginSliderRefs) do
            refs.top:SetValue(pendingMargins[key].top)
            refs.bot:SetValue(pendingMargins[key].bottom)
        end
    end

    -- ── Action buttons (fixed, outside the scroll frame) ───────
    -- Defaults is pinned to the far left; Accept and Cancel are pinned to the
    -- far right with Cancel outermost.
    local defaultsBtn = NS.CB_CreateButton(panel, "CleanBotDefaultsSettings", "Defaults", 80, 22, function()
        pendingScale        = 100
        pendingTransparency = 100
        pendingAccentR, pendingAccentG, pendingAccentB = 1, 1, 1
        for k, defaults in pairs(NS.MARGIN_DEFAULTS) do
            pendingMargins[k].top    = defaults.top
            pendingMargins[k].bottom = defaults.bottom
        end
        syncPendingToUI()
    end)
    defaultsBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD, PAD)

    local cancelBtn = NS.CB_CreateButton(panel, "CleanBotCancelSettings", "Cancel", 80, 22, function()
        -- Restore pending values from what was last saved (fall back to defaults).
        -- TODO: restore pendingScale/pendingTransparency/accent from SavedVars when those are saved.
        pendingScale        = 100
        pendingTransparency = 100
        pendingAccentR, pendingAccentG, pendingAccentB = 1, 1, 1
        local saved = CleanBot_SavedVars and CleanBot_SavedVars.margins
        for k, defaults in pairs(NS.MARGIN_DEFAULTS) do
            local s = saved and saved[k]
            if type(s) == "table" then
                pendingMargins[k].top    = type(s.top)    == "number" and s.top    or defaults.top
                pendingMargins[k].bottom = type(s.bottom) == "number" and s.bottom or defaults.bottom
            else
                pendingMargins[k].top    = defaults.top
                pendingMargins[k].bottom = defaults.bottom
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
            CleanBot_SavedVars.margins[k] = { top = v.top, bottom = v.bottom }
        end
        NS.CB_Print("Margin values saved. Reload the UI to see layout changes.")
    end)
    applyBtn:SetPoint("RIGHT", cancelBtn, "LEFT", -8, 0)
end
