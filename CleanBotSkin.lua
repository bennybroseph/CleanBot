-- ============================================================
-- CleanBotSkin.lua  —  ElvUI integration, fallback backdrop,
--                      skinning helpers, and widget factories.
--
-- This file centralises everything ElvUI-related: the module
-- handles, detection, the plain-backdrop fallback, the panel/inner
-- skin helpers, and the CreateFrame factories that bake in the
-- "create widget → apply ElvUI skin" boilerplate used everywhere.
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- ElvUI handles (populated by NS.CB_InitElvUI at PLAYER_LOGIN)
-- ============================================================
NS.ElvUI_E = nil
NS.ElvUI_S = nil

-- Detect ElvUI and grab its Skins module. Called once at login,
-- when ElvUI is guaranteed to be loaded.
NS.CB_InitElvUI = function()
    if IsAddOnLoaded("ElvUI") then
        NS.ElvUI_E = unpack(ElvUI)
        if NS.ElvUI_E then NS.ElvUI_S = NS.ElvUI_E:GetModule("Skins") end
    end
end

-- ============================================================
-- Fallback backdrop (used when ElvUI is absent)
-- ============================================================
NS.PLAIN_BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- ============================================================
-- Skinning helpers
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
-- Widget factories — create a widget and apply the ElvUI skin in
-- one call. Callers still position the widget (SetPoint) and set
-- any extra state (font objects, tooltips, etc.) themselves.
-- ============================================================

-- UIPanelButtonTemplate button. w/h, text and onClick are optional.
NS.CB_CreateButton = function(parent, name, text, w, h, onClick)
    local btn = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    if w and h then btn:SetSize(w, h) end
    if text then btn:SetText(text) end
    if onClick then btn:SetScript("OnClick", onClick) end
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(btn) end
    return btn
end

-- UIDropDownMenuTemplate dropdown. When width is given the dropdown
-- is sized and the ElvUI skin is sized to match.
NS.CB_CreateDropdown = function(parent, name, width)
    local dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    if width then UIDropDownMenu_SetWidth(dd, width) end
    if NS.ElvUI_S then NS.ElvUI_S:HandleDropDownBox(dd, width) end
    return dd
end

-- UICheckButtonTemplate check button.
NS.CB_CreateCheckBox = function(parent, name)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    if NS.ElvUI_S then NS.ElvUI_S:HandleCheckBox(cb) end
    return cb
end

-- InputBoxTemplate edit box. w/h are optional.
NS.CB_CreateEditBox = function(parent, name, w, h)
    local box = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
    if w and h then box:SetSize(w, h) end
    if NS.ElvUI_S then NS.ElvUI_S:HandleEditBox(box) end
    return box
end

-- OptionsSliderTemplate slider.
-- name is required — the template creates named children (<name>Text, <name>Low, <name>High)
-- which are stored on the returned slider as .textLabel, .lowLabel, .highLabel.
-- lowText/highText label the ends; defaultVal seeds the initial position and display.
-- Caller sets OnValueChanged after creation; the initial SetValue fires before that.
NS.CB_CreateSlider = function(parent, name, minVal, maxVal, defaultVal, lowText, highText)
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetMinMaxValues(minVal, maxVal)
    s:SetValueStep(1)
    s.textLabel = _G[name .. "Text"]
    s.lowLabel  = _G[name .. "Low"]
    s.highLabel = _G[name .. "High"]
    if s.lowLabel  then s.lowLabel:SetText(lowText  or tostring(minVal)) end
    if s.highLabel then s.highLabel:SetText(highText or tostring(maxVal)) end
    s:SetValue(defaultVal or minVal)
    if NS.ElvUI_S then NS.ElvUI_S:HandleSliderFrame(s) end
    return s
end

-- Small colored swatch button that opens the WoW ColorPickerFrame.
-- initR/G/B seed the starting color (defaults to white). onChange(r, g, b) fires
-- on both confirm and cancel so the caller always sees the current value.
-- The returned button has a .swatch texture that reflects the active color.
NS.CB_CreateColorSwatch = function(parent, name, initR, initG, initB, onChange)
    local r, g, b = initR or 1, initG or 1, initB or 1

    local btn = CreateFrame("Button", name, parent)
    btn:SetSize(20, 20)

    local swatch = btn:CreateTexture(nil, "BACKGROUND")
    swatch:SetAllPoints()
    swatch:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    swatch:SetVertexColor(r, g, b)
    btn.swatch = swatch

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    btn:SetScript("OnClick", function()
        local prevR, prevG, prevB = r, g, b
        ColorPickerFrame.func = function()
            r, g, b = ColorPickerFrame:GetColorRGB()
            swatch:SetVertexColor(r, g, b)
            if onChange then onChange(r, g, b) end
        end
        ColorPickerFrame.cancelFunc = function()
            r, g, b = prevR, prevG, prevB
            swatch:SetVertexColor(r, g, b)
            if onChange then onChange(r, g, b) end
        end
        ColorPickerFrame:SetColorRGB(r, g, b)
        ShowUIPanel(ColorPickerFrame)
    end)

    return btn
end
