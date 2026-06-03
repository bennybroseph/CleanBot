-- ============================================================
-- CleanBotSettingsTab.lua  —  Settings tab content
-- ============================================================
local NS = CleanBotNS

NS.CleanBot_BuildSettingsContent = function()
    -- Pending values — hold uncommitted user input until Apply is pressed.
    local pendingScale        = 100
    local pendingTransparency = 100
    local pendingAccentR, pendingAccentG, pendingAccentB = 1, 1, 1

    local panel      = NS.settingsPanel
    local pad        = NS.PAD
    local labelGap   = NS.LABEL_GAP
    local sectionGap = NS.SECTION_GAP

    -- ── Scale ──────────────────────────────────────────────────
    local scaleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    scaleLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", pad, -pad)
    scaleLabel:SetText("Scale")

    local scaleSlider = NS.CB_CreateSlider(panel, "CleanBotScaleSlider", 50, 150, 100, "50%", "150%")
    scaleSlider:SetWidth(180)
    scaleSlider:SetPoint("TOPLEFT", scaleLabel, "BOTTOMLEFT", 0, -labelGap)
    scaleSlider:SetScript("OnValueChanged", function(self, val)
        pendingScale = math.floor(val + 0.5)
        self.textLabel:SetText(pendingScale .. "%")
    end)
    scaleSlider.textLabel:SetText("100%")

    -- ── Transparency ───────────────────────────────────────────
    local transLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    transLabel:SetPoint("TOPLEFT", scaleSlider, "BOTTOMLEFT", 0, -sectionGap)
    transLabel:SetText("Transparency")

    local transSlider = NS.CB_CreateSlider(panel, "CleanBotTransSlider", 0, 100, 100, "0%", "100%")
    transSlider:SetWidth(180)
    transSlider:SetPoint("TOPLEFT", transLabel, "BOTTOMLEFT", 0, -labelGap)
    transSlider:SetScript("OnValueChanged", function(self, val)
        pendingTransparency = math.floor(val + 0.5)
        self.textLabel:SetText(pendingTransparency .. "%")
    end)
    transSlider.textLabel:SetText("100%")

    -- ── Accent Color ───────────────────────────────────────────
    local accentLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    accentLabel:SetPoint("TOPLEFT", transSlider, "BOTTOMLEFT", 0, -sectionGap)
    accentLabel:SetText("Accent Color")

    local colorSwatch = NS.CB_CreateColorSwatch(panel, "CleanBotAccentSwatch", 1, 1, 1,
        function(r, g, b)
            pendingAccentR, pendingAccentG, pendingAccentB = r, g, b
        end)
    colorSwatch:SetPoint("TOPLEFT", accentLabel, "BOTTOMLEFT", 0, -labelGap)

    -- ── Apply ──────────────────────────────────────────────────
    local applyBtn = NS.CB_CreateButton(panel, "CleanBotApplySettings", "Apply", 80, 22, function()
        -- TODO: apply pendingScale, pendingTransparency, pendingAccentR/G/B
    end)
    applyBtn:SetPoint("TOPLEFT", colorSwatch, "BOTTOMLEFT", 0, -sectionGap)
end
