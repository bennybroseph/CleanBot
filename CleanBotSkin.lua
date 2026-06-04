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

-- Registry of all top-level CleanBot windows (UIParent children).
-- Each frame registered here receives SetScale on theme apply.
-- Call NS.CB_RegisterRootFrame(f) immediately after creating any
-- top-level CleanBot window.
NS.CB_rootFrames = {}
-- Registers a top-level CleanBot window and immediately applies the current
-- scale so lazily-created frames (inventory, sample layout) get the right
-- value even when they open after the scale was last changed.
NS.CB_RegisterRootFrame = function(frame)
    NS.CB_rootFrames[frame] = true
    frame:SetScale((NS.scale or 100) / 100)
end

-- Registry of frames skinned by CB_ApplyPanelSkin / CB_ApplyInnerSkin.
-- Stores the skin type ("panel" | "inner") so transparency refresh
-- knows which base alpha to use. Both ElvUI and non-ElvUI frames are
-- registered so that accent colour and transparency always apply.
NS.CB_skinnedFrames = {}

-- Re-applies accent colour to every registered skinned frame.
NS.CB_RefreshAccentColor = function(r, g, b)
    for frame, _ in pairs(NS.CB_skinnedFrames) do
        frame:SetBackdropBorderColor(r, g, b, 1)
    end
end

-- Re-applies background transparency to every registered panel frame.
-- t is 0–100; 100 = fully opaque, 0 = fully transparent.
-- Inner frames keep their fixed 0.4 alpha and are not affected.
-- Each panel frame's stored brightness is used so nesting shades are preserved.
NS.CB_RefreshTransparency = function(t)
    local alpha = (t or 100) / 100
    for frame, info in pairs(NS.CB_skinnedFrames) do
        if info.skin == "panel" then
            local b = info.brightness
            frame:SetBackdropColor(b, b, b, alpha)
        end
    end
end

-- Re-applies scale to every registered root frame.
NS.CB_RefreshScale = function(s)
    local scale = (s or 100) / 100
    for frame, _ in pairs(NS.CB_rootFrames) do
        frame:SetScale(scale)
    end
end

-- nestLevel controls fill darkness: 0 = lightest (outermost), 1 = one step darker, etc.
-- Brightness formula: max(0, 0.10 - nestLevel * 0.05)
--   Level 0 → 0.10,  Level 1 → 0.05,  Level 2 → 0.0
NS.CB_ApplyPanelSkin = function(frame, nestLevel)
    local ac         = NS.accentColor or { r = 0.3, g = 0.3, b = 0.3 }
    local alpha      = (NS.transparency or 100) / 100
    local brightness = math.max(0, 0.10 - (nestLevel or 0) * 0.05)
    if NS.ElvUI_S then
        frame:StripTextures()
        frame:SetTemplate("Default")
    else
        frame:SetBackdrop(NS.PLAIN_BACKDROP)
    end
    frame:SetBackdropColor(brightness, brightness, brightness, alpha)
    frame:SetBackdropBorderColor(ac.r, ac.g, ac.b, 1)
    NS.CB_skinnedFrames[frame] = { skin = "panel", brightness = brightness }
end

NS.CB_ApplyInnerSkin = function(frame)
    local ac = NS.accentColor or { r = 0.3, g = 0.3, b = 0.3 }
    if NS.ElvUI_S then
        frame:StripTextures()
        frame:SetTemplate("Transparent")
    else
        frame:SetBackdrop(NS.PLAIN_BACKDROP)
        frame:SetBackdropColor(0, 0, 0, 0.4)  -- fixed; transparency setting only affects panel frames
    end
    frame:SetBackdropBorderColor(ac.r, ac.g, ac.b, 1)
    NS.CB_skinnedFrames[frame] = { skin = "inner" }
end

-- ============================================================
-- Layout helper — anchors widget directly below above using their
-- combined margins as the gap (above.marginBottom + widget.marginTop).
-- xOffset shifts the horizontal anchor (defaults to 0).
-- ============================================================
NS.CB_AnchorBelow = function(widget, above, xOffset)
    local gap    = (above.marginBottom or 0) + (widget.marginTop or 0)
    local xShift = (xOffset or 0) + (widget.marginLeft or 0) - (above.marginLeft or 0)
    widget:SetPoint("TOPLEFT", above, "BOTTOMLEFT", xShift, -gap)
end

-- ============================================================
-- Widget factories — create a widget, apply the ElvUI skin, and
-- stamp NS.MARGIN values onto the returned frame so CB_AnchorBelow
-- can compute gaps automatically.
-- ============================================================

-- Horizontal rule. ElvUI: 1px line using E.media.blank tinted with the border
-- colour. Fallback: the UI-TooltipDivider-Transparent tiled texture at 8px.
-- Width is NOT set — callers size it after anchoring with CB_AnchorBelow.
NS.CB_CreateSeparator = function(parent)
    local f = CreateFrame("Frame", nil, parent)
    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()

    if NS.ElvUI_E and NS.ElvUI_E.media and NS.ElvUI_E.media.blank then
        local bc = (NS.ElvUI_E.db and NS.ElvUI_E.db.general and NS.ElvUI_E.db.general.bordercolor) or {}
        tex:SetTexture(NS.ElvUI_E.media.blank)
        tex:SetVertexColor(bc.r or 0.3, bc.g or 0.3, bc.b or 0.3, 1)
        f:SetHeight(1)
    else
        tex:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
        tex:SetVertexColor(0.3, 0.3, 0.3, 0.8)
        f:SetHeight(1)
    end

    f.marginTop    = 6
    f.marginBottom = 4
    f.marginLeft   = 0
    f.marginRight  = 0
    return f
end

-- FontString label. fontObj defaults to "GameFontNormal".
NS.CB_CreateLabel = function(parent, text, fontObj)
    local lbl = parent:CreateFontString(nil, "OVERLAY", fontObj or "GameFontNormal")
    if text then lbl:SetText(text) end
    lbl.marginTop    = NS.MARGIN.label.top
    lbl.marginBottom = NS.MARGIN.label.bottom
    lbl.marginLeft   = NS.MARGIN.label.left
    lbl.marginRight  = NS.MARGIN.label.right
    return lbl
end

-- FontString section header. Larger than a label (GameFontNormalLarge) with
-- wider top/bottom margins so it reads as a visual section break.
-- fontObj can override the font object if desired.
NS.CB_CreateHeader = function(parent, text, fontObj)
    local hdr = parent:CreateFontString(nil, "OVERLAY", fontObj or "GameFontNormalLarge")
    if text then hdr:SetText(text) end
    hdr.marginTop    = NS.MARGIN.header.top
    hdr.marginBottom = NS.MARGIN.header.bottom
    hdr.marginLeft   = NS.MARGIN.header.left
    hdr.marginRight  = NS.MARGIN.header.right
    return hdr
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
    btn.marginLeft   = NS.MARGIN.button.left
    btn.marginRight  = NS.MARGIN.button.right
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
    dd.marginLeft   = NS.MARGIN.dropdown.left
    dd.marginRight  = NS.MARGIN.dropdown.right
    return dd
end

-- UICheckButtonTemplate check button.
NS.CB_CreateCheckBox = function(parent, name)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    if NS.ElvUI_S then NS.ElvUI_S:HandleCheckBox(cb) end
    cb.marginTop    = NS.MARGIN.checkbox.top
    cb.marginBottom = NS.MARGIN.checkbox.bottom
    cb.marginLeft   = NS.MARGIN.checkbox.left
    cb.marginRight  = NS.MARGIN.checkbox.right
    return cb
end

-- Applies an ElvUI-matching skin to an EditBox using SetBackdrop directly,
-- bypassing HandleEditBox / SetTemplate. HandleEditBox creates iborder/oborder
-- child frames via SetTemplate; inside a ScrollFrame those children land at a
-- frame level that obscures the EditBox's own text layer, making text invisible
-- and blocking cursor interaction. SetBackdrop on the EditBox itself avoids that.
-- Falls back to a no-op when ElvUI is absent (InputBoxTemplate provides its own look).
NS.CB_SkinEditBoxSafe = function(box)
    if not NS.ElvUI_S then return end
    local E   = NS.ElvUI_E
    -- Use ElvUI's own blank texture when available so the fill is pure white and
    -- can be tinted accurately; fall back to a reliable Blizzard solid texture.
    local tex = (E and E.media and E.media.blank) or "Interface\\ChatFrame\\ChatFrameBackground"
    local bc  = (E and E.db and E.db.general and E.db.general.bordercolor) or {}
    -- Hide only Texture regions to remove InputBoxTemplate's default art.
    -- GetRegions() returns Textures and FontStrings but never child Frames, so this
    -- is safe for input handling. We filter to Texture only so the EditBox's text
    -- FontString stays visible. StripTextures is avoided entirely — ElvUI's version
    -- also iterates child frames and hides something InputBoxTemplate needs for focus.
    for _, region in pairs({box:GetRegions()}) do
        if region:GetObjectType() == "Texture" then
            region:Hide()
        end
    end
    box:SetBackdrop({
        bgFile   = tex,
        edgeFile = tex,
        tile     = false,
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    box:SetBackdropColor(0.06, 0.06, 0.06, 1)
    box:SetBackdropBorderColor(bc.r or 0.3, bc.g or 0.3, bc.b or 0.3, 1)
end

-- InputBoxTemplate edit box. w/h are optional.
NS.CB_CreateEditBox = function(parent, name, w, h)
    local box = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
    if w and h then box:SetSize(w, h) end
    NS.CB_SkinEditBoxSafe(box)
    box.marginTop    = NS.MARGIN.editBox.top
    box.marginBottom = NS.MARGIN.editBox.bottom
    box.marginLeft   = NS.MARGIN.editBox.left
    box.marginRight  = NS.MARGIN.editBox.right
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
    -- Created directly (not via CB_CreateEditBox) so we can apply CB_SkinEditBoxSafe
    -- instead of HandleEditBox — see CB_SkinEditBoxSafe for the full explanation.
    local box = CreateFrame("EditBox", name .. "EditBox", wrapper, "InputBoxTemplate")
    box:SetSize(70, 18)
    NS.CB_SkinEditBoxSafe(box)
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
    wrapper.marginLeft   = NS.MARGIN.slider.left
    wrapper.marginRight  = NS.MARGIN.slider.right
    return wrapper
end

-- Clears keyboard focus from any focused EditBox (e.g. a slider EditBox) when
-- the user clicks in the 3D world or on the CleanBot frame's own background.
-- Without this, EditBoxes hold focus indefinitely until Escape is pressed.
local function CB_ClearKeyboardFocus()
    local focused = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    if focused then focused:ClearFocus() end
end
WorldFrame:HookScript("OnMouseDown",    CB_ClearKeyboardFocus)
CleanBotFrame:HookScript("OnMouseDown", CB_ClearKeyboardFocus)

-- Wrapper containing a 20×20 colored swatch button on the left and an optional
-- text label to its right, aligned to the same vertical centre.
-- Clicking the swatch opens the WoW ColorPickerFrame; onChange(r, g, b) fires
-- on both confirm and cancel. initR/G/B seed the starting color (default white).
-- The wrapper exposes :setColor(r, g, b) and a .swatch texture reference.
NS.CB_CreateColorSwatch = function(parent, name, text, initR, initG, initB, onChange)
    local r, g, b = initR or 1, initG or 1, initB or 1

    local wrapper = CreateFrame("Frame", nil, parent)
    wrapper:SetSize(160, 20)

    local btn = CreateFrame("Button", name, wrapper)
    btn:SetSize(20, 20)
    btn:SetPoint("LEFT", wrapper, "LEFT", 0, 0)

    local swatch = btn:CreateTexture(nil, "BACKGROUND")
    swatch:SetAllPoints()
    swatch:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    swatch:SetVertexColor(r, g, b)
    btn.swatch = swatch

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    if text then
        local lbl = wrapper:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetText(text)
        -- "LEFT" is the middle-left anchor point, so this centres the label
        -- vertically with the swatch button without extra math.
        lbl:SetPoint("LEFT", btn, "RIGHT", 4, 0)
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

    wrapper.swatch   = swatch
    wrapper.setColor = function(self, nr, ng, nb)
        r, g, b = nr, ng, nb
        swatch:SetVertexColor(r, g, b)
    end

    wrapper.marginTop    = NS.MARGIN.swatch.top
    wrapper.marginBottom = NS.MARGIN.swatch.bottom
    wrapper.marginLeft   = NS.MARGIN.swatch.left
    wrapper.marginRight  = NS.MARGIN.swatch.right
    return wrapper
end
