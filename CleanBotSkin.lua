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
-- Layout helper — anchors widget directly below above using their
-- combined margins as the gap (above.marginBottom + widget.marginTop).
-- xOffset shifts the horizontal anchor (defaults to 0).
-- ============================================================
NS.CB_AnchorBelow = function(widget, above, xOffset)
    local gap = (above.marginBottom or 0) + (widget.marginTop or 0)
    widget:SetPoint("TOPLEFT", above, "BOTTOMLEFT", xOffset or 0, -gap)
end

-- ============================================================
-- Widget factories — create a widget, apply the ElvUI skin, and
-- stamp NS.MARGIN values onto the returned frame so CB_AnchorBelow
-- can compute gaps automatically.
-- ============================================================

-- FontString label. fontObj defaults to "GameFontNormal".
NS.CB_CreateLabel = function(parent, text, fontObj)
    local lbl = parent:CreateFontString(nil, "OVERLAY", fontObj or "GameFontNormal")
    if text then lbl:SetText(text) end
    lbl.marginTop    = NS.MARGIN.label.top
    lbl.marginBottom = NS.MARGIN.label.bottom
    return lbl
end

-- UIPanelButtonTemplate button. w/h, text and onClick are optional.
NS.CB_CreateButton = function(parent, name, text, w, h, onClick)
    local btn = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    if w and h then btn:SetSize(w, h) end
    if text then btn:SetText(text) end
    if onClick then btn:SetScript("OnClick", onClick) end
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(btn) end
    btn.marginTop    = NS.MARGIN.button.top
    btn.marginBottom = NS.MARGIN.button.bottom
    return btn
end

-- UIDropDownMenuTemplate dropdown. When width is given the dropdown
-- is sized and the ElvUI skin is sized to match.
NS.CB_CreateDropdown = function(parent, name, width)
    local dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    if width then UIDropDownMenu_SetWidth(dd, width) end
    if NS.ElvUI_S then NS.ElvUI_S:HandleDropDownBox(dd, width) end
    dd.marginTop    = NS.MARGIN.dropdown.top
    dd.marginBottom = NS.MARGIN.dropdown.bottom
    return dd
end

-- UICheckButtonTemplate check button.
NS.CB_CreateCheckBox = function(parent, name)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    if NS.ElvUI_S then NS.ElvUI_S:HandleCheckBox(cb) end
    cb.marginTop    = NS.MARGIN.checkbox.top
    cb.marginBottom = NS.MARGIN.checkbox.bottom
    return cb
end

-- InputBoxTemplate edit box. w/h are optional.
NS.CB_CreateEditBox = function(parent, name, w, h)
    local box = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
    if w and h then box:SetSize(w, h) end
    if NS.ElvUI_S then NS.ElvUI_S:HandleEditBox(box) end
    box.marginTop    = NS.MARGIN.editBox.top
    box.marginBottom = NS.MARGIN.editBox.bottom
    return box
end

-- OptionsSliderTemplate slider paired with an optional title label and a centered EditBox.
-- Returns a wrapper frame; callers use wrapper:SetWidth() to size it.
-- The slider and EditBox are kept in sync: dragging updates the EditBox, and typing
-- (confirmed with Enter or focus loss) updates the slider.
-- onChange(v) fires whenever the committed integer value changes from either input path.
--
-- title:          optional label rendered above the slider bar (GameFontNormal / gold).
-- softMin/softMax define the slider's draggable range.
-- hardMin/hardMax define the EditBox's allowed input range (default = softMin/softMax).
--   Typing outside [softMin,softMax] pins the thumb to the boundary while onChange
--   still receives the full typed value.
--
-- Wrapper exposes :SetValue(v) / :GetValue() proxies plus sub-element refs:
--   .label, .slider, .editBox, .lowLabel, .highLabel, .textLabel (hidden built-in).
-- marginTop uses label.top when a title is present, slider.top otherwise.
NS.CB_CreateSlider = function(parent, name, title, softMin, softMax, defaultVal, lowText, highText, onChange, hardMin, hardMax)
    hardMin = hardMin or softMin
    hardMax = hardMax or softMax

    local wrapper = CreateFrame("Frame", nil, parent)

    -- Optional title label spanning the full widget width.
    local label = nil
    if title then
        label = wrapper:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetText(title)
        label:SetPoint("TOPLEFT",  wrapper, "TOPLEFT",  0, 0)
        label:SetPoint("TOPRIGHT", wrapper, "TOPRIGHT", 0, 0)
        label:SetJustifyH("CENTER")
        label:SetHeight(15)
    end

    -- Inner slider fills wrapper horizontally; anchored below label when present.
    local s = CreateFrame("Slider", name, wrapper, "OptionsSliderTemplate")
    s:SetHeight(17)
    if label then
        s:SetPoint("TOPLEFT",  label, "BOTTOMLEFT",  0, -2)
        s:SetPoint("TOPRIGHT", label, "BOTTOMRIGHT", 0, -2)
    else
        s:SetPoint("TOPLEFT",  wrapper, "TOPLEFT",  0, 0)
        s:SetPoint("TOPRIGHT", wrapper, "TOPRIGHT", 0, 0)
    end
    s:SetMinMaxValues(softMin, softMax)
    s:SetValueStep(1)

    local textLabel = _G[name .. "Text"]
    local lowLabel  = _G[name .. "Low"]
    local highLabel = _G[name .. "High"]
    if textLabel then textLabel:Hide() end
    if lowLabel  then lowLabel:SetText(lowText  or tostring(softMin)) end
    if highLabel then highLabel:SetText(highText or tostring(softMax)) end

    -- EditBox sits centred between the low/high labels, directly below the slider bar.
    local box = NS.CB_CreateEditBox(wrapper, name .. "EditBox", 70, 18)
    box:SetPoint("TOP", s, "BOTTOM", 0, -2)
    box:SetAutoFocus(false)
    box:SetJustifyH("CENTER")

    -- Guard against re-entrancy when applyBoxValue moves the slider thumb.
    local updating = false

    -- Sync: slider → editbox → onChange.
    -- Skipped when applyBoxValue is already driving the update to avoid double-firing.
    s:SetScript("OnValueChanged", function(self, val)
        if updating then return end
        local v = math.floor(val + 0.5)
        box:SetText(tostring(v))
        if onChange then onChange(v) end
    end)

    -- Sync: editbox → slider.
    -- Hard range clamps the data value; soft range clamps the slider thumb position.
    -- Invalid text reverts to the current slider value without firing onChange.
    local function applyBoxValue()
        local v = tonumber(box:GetText())
        if v then
            v = math.max(hardMin, math.min(hardMax, math.floor(v + 0.5)))
            box:SetText(tostring(v))
            local thumbPos = math.max(softMin, math.min(softMax, v))
            updating = true
            s:SetValue(thumbPos)
            updating = false
            if onChange then onChange(v) end
        else
            box:SetText(tostring(math.floor(s:GetValue() + 0.5)))
        end
    end
    box:SetScript("OnEnterPressed", function(self) applyBoxValue(); self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self)
        box:SetText(tostring(math.floor(s:GetValue() + 0.5)))
        self:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", applyBoxValue)

    s:SetValue(defaultVal or softMin)
    if NS.ElvUI_S then NS.ElvUI_S:HandleSliderFrame(s) end

    -- Proxy SetValue/GetValue so callers treat the wrapper like a slider.
    wrapper.SetValue = function(self, v) s:SetValue(v) end
    wrapper.GetValue = function(self) return s:GetValue() end

    wrapper.label     = label
    wrapper.slider    = s
    wrapper.editBox   = box
    wrapper.lowLabel  = lowLabel
    wrapper.highLabel = highLabel
    wrapper.textLabel = textLabel  -- hidden; kept for reference

    -- Height: title (15px label + 2px gap) when present, + slider (17px) + gap (2px) + editbox (18px).
    local titleH = title and 17 or 0
    wrapper:SetHeight(titleH + 37)
    wrapper.marginTop    = title and NS.MARGIN.label.top or NS.MARGIN.slider.top
    wrapper.marginBottom = NS.MARGIN.slider.bottom
    return wrapper
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

    -- Updates the displayed color and the internal upvalues so the color picker
    -- opens with the correct starting color the next time OnClick fires.
    btn.setColor = function(self, nr, ng, nb)
        r, g, b = nr, ng, nb
        swatch:SetVertexColor(r, g, b)
    end

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

    btn.marginTop    = NS.MARGIN.swatch.top
    btn.marginBottom = NS.MARGIN.swatch.bottom
    return btn
end
