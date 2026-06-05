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
-- Fallback backdrops (used when ElvUI is absent)
-- ============================================================

-- Thin tooltip-style border — used for inner panels and secondary windows.
NS.PLAIN_BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Panel backdrop using a pure-white bgFile so that SetBackdropColor(r,g,b,a) maps
-- directly to the displayed colour. UI-DialogBox-Background is dark (~20% brightness),
-- which means vertex-colour multiplication makes every brightness value look near-black.
-- WHITE8X8 has full (1,1,1) pixel values so brightness = displayed colour exactly.
NS.PANEL_BACKDROP = {
    bgFile   = "Interface\\BUTTONS\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Ornate WoW dialog border — used only for the main CleanBotFrame so it
-- reads as a proper WoW window rather than a generic panel.
NS.OUTER_BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
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

-- Registry of frames skinned by CB_ApplyPanelSkin / CB_ApplyOuterFrameSkin.
-- Each entry stores { skin, brightness, level } so refresh functions can
-- recompute both brightness and per-level alpha without re-calling the skin function.
NS.CB_skinnedFrames = {}

-- Non-ElvUI only: each nesting level multiplies the base alpha by this factor,
-- making deeper frames progressively more transparent to compensate for layering.
-- Applied exponentially: effective_alpha = base_alpha * TRANSPARENCY_FALLOFF ^ level
local TRANSPARENCY_FALLOFF = 0.85

local function CB_LevelAlpha(baseAlpha, level)
    if NS.ElvUI_S then return baseAlpha end
    local factor = 1
    for _ = 1, level do factor = factor * TRANSPARENCY_FALLOFF end
    return baseAlpha * factor
end

-- Re-applies accent colour to every registered skinned frame.
-- a defaults to 1 (fully opaque) when omitted.
NS.CB_RefreshAccentColor = function(r, g, b, a)
    local alpha = a or 1
    for frame, _ in pairs(NS.CB_skinnedFrames) do
        frame:SetBackdropBorderColor(r, g, b, alpha)
    end
end

-- Re-applies background transparency to every registered panel frame.
-- t is 0–100; 100 = fully opaque, 0 = fully transparent.
-- Non-ElvUI frames additionally apply per-level exponential falloff.
NS.CB_RefreshTransparency = function(t)
    local baseAlpha = (t or 100) / 100
    for frame, info in pairs(NS.CB_skinnedFrames) do
        if info.skin == "panel" then
            frame:SetBackdropColor(info.brightness, info.brightness, info.brightness,
                CB_LevelAlpha(baseAlpha, info.level))
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

-- Adds the classic Blizzard dialog header ornament behind the frame title.
-- Non-ElvUI only — ElvUI's SetTemplate already provides its own title treatment.
-- Must be called AFTER CB_ApplyOuterFrameSkin (i.e. after any StripTextures call).
-- The 256×64 header texture is centred at the top of the frame and elevated by 12px
-- so it overlaps the border, matching the standard Blizzard dialog layout.
-- Applies the title bar ornament and creates the title FontString for an outer frame.
-- titleText is the string to display (e.g. "CleanBot", "Sample Layout").
--
-- Non-ElvUI: adds the Blizzard dialog header ornament (OVERLAY texture) and a
--   compact GameFontNormal label nudged to sit in the ornament's visual band.
-- ElvUI: skips the ornament (SetTemplate handles the chrome) and uses the larger
--   GameFontNormalLarge centred in the title area, matching ElvUI frame conventions.
NS.CB_ApplyTitleBar = function(frame, titleText)
    if NS.ElvUI_S then
        local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        lbl:SetText(titleText or "")
        lbl:SetPoint("CENTER", frame, "TOP", 0, -(NS.TITLE_H / 2))
        lbl:SetJustifyH("CENTER")
        return
    end
    -- Ornament texture in OVERLAY — FontStrings render above Textures within the
    -- same draw layer, so the label below will appear on top of the ornament.
    local tex = frame:CreateTexture(nil, "OVERLAY")
    tex:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    tex:SetWidth(256)
    tex:SetHeight(64)
    tex:SetPoint("CENTER", frame, "TOP", 0, -(NS.TITLE_H / 2))
    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetText(titleText or "")
    lbl:SetPoint("CENTER", frame, "TOP", 0, -2)
    lbl:SetJustifyH("CENTER")
end

-- Places a centred title label for a ContainerFrame-style window (Blizz path only).
-- Reusable for any frame built with CB_ApplyContainerFrameSkin.
-- CONTAINER_TITLE_Y controls how far below the top edge the label sits.
local CONTAINER_TITLE_OFFSET = 2
NS.CB_ApplyContainerTitleLabel = function(frame, text)
    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetText(text or "")
    lbl:SetPoint("CENTER", frame, "TOP", 0, -(NS.TITLE_H / 2) - CONTAINER_TITLE_OFFSET)
    lbl:SetJustifyH("CENTER")
end

-- Applies the inventory window title bar label.
-- Blizz: plain centred label via CB_ApplyContainerTitleLabel.
-- ElvUI: class-coloured badge with bag icon and centred label.
NS.CB_ApplyInventoryTitleBar = function(frame, botName, class)
    if NS.ElvUI_S then
        local BADGE_SIZE = 50
        local BADGE_X    = 34
        local BADGE_Y    = 4
        local ICON_INSET = 5
        local cc = (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class])
                or { r = 0.5, g = 0.5, b = 0.5 }

        local badge = CreateFrame("Frame", nil, frame)
        badge:SetSize(BADGE_SIZE, BADGE_SIZE)
        badge:SetPoint("CENTER", frame, "TOPLEFT", BADGE_X, BADGE_Y)
        badge:SetTemplate("Default")
        badge:SetBackdropColor(cc.r * 0.4, cc.g * 0.4, cc.b * 0.4, 1)

        local icon = badge:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT",     badge, "TOPLEFT",      ICON_INSET, -ICON_INSET)
        icon:SetPoint("BOTTOMRIGHT", badge, "BOTTOMRIGHT", -ICON_INSET,  ICON_INSET)
        icon:SetTexture("Interface\\ContainerFrame\\UI-BackpackBackground")
        icon:SetTexCoord(0.27734375, 0.43359375, 0.01953125, 0.17578125)

        local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        lbl:SetText(botName .. "'s Inventory")
        lbl:SetPoint("CENTER", frame, "TOP", 0, -(NS.TITLE_H / 2))
        lbl:SetJustifyH("CENTER")
        return
    end

    NS.CB_ApplyContainerTitleLabel(frame, botName .. "'s Inventory")
end

-- Applies the Blizzard ContainerFrame-style backdrop to a frame.
-- Uses UI-BackpackBackground as the tiling background and the ornate dialog
-- border, matching the visual style of WoW's own bag frames.
-- Unlike CB_ApplyOuterFrameSkin, this does NOT register for accent-colour or
-- transparency refresh — the ContainerFrame look is fixed art, not theme-driven.
-- Assembles the ContainerFrame-style visual for the inventory frame from
-- sliced pieces of UI-BackpackBackground. Call once when the frame is created.
-- Edges and fill are added in CB_UpdateInventoryBackground once the frame
-- is sized by CB_RenderInventory.
--
-- Border measurements derived from ContainerFrame1 (192×240, texture 256×256,
-- scale X=192/256=0.75, scale Y=240/256=0.9375):
--   Left  : 23px screen → ~31px texture  → U  = 31/256  ≈ 0.12109
--   Right : 12px screen →  16px texture  → U  = 240/256 = 0.93750 (start of right border)
--   Top   : 51px screen → ~54px texture  → V  = 54/256  ≈ 0.21094
--   Bottom: 32px screen → ~34px texture  → V  = 222/256 ≈ 0.86719 (start of bottom border)
NS.CB_ApplyContainerFrameSkin = function(frame)
    local TEX    = "Interface\\ContainerFrame\\UI-BackpackBackground"
    local TILE_W = 40   -- one item cell: CELL_SIZE(37) + CELL_PAD(3)
    local TILE_H = 40
    local COLS   = 10

    local BL_X1, BL_X2 = 65,  122
    local BR_X1, BR_X2 = 204, 256

    local FILL_X1, FILL_X2 = 122, 162  -- x crop for center and top/bottom edge fill tiles; tune as needed
    local FILL_Y1, FILL_Y2 = 92,  132  -- y crop for center and side fill tiles; tune as needed

    -- Corners and edges are static (BORDER layer so they always render above dynamic fill tiles).
    local function makeCorner(anchor, x1, y1, x2, y2)
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetSize(x2 - x1, y2 - y1)
        t:SetPoint(anchor, frame, anchor, 0, 0)
        t:SetTexture(TEX)
        t:SetTexCoord(x1/256, x2/256, y1/256, y2/256)
        return x2 - x1, y2 - y1
    end

    local function makeEdge(anchor, x1, y1, x2, y2, startX)
        local tileH = y2 - y1
        for i = 0, COLS - 3 do
            local t = frame:CreateTexture(nil, "BORDER")
            t:SetSize(TILE_W, tileH)
            t:SetPoint(anchor, frame, anchor, startX + i * TILE_W, 0)
            t:SetTexture(TEX)
            t:SetTexCoord(x1/256, x2/256, y1/256, y2/256)
        end
    end

    local tlW, tlH = makeCorner("TOPLEFT",      BL_X1,   0, BL_X2,  49)
    local blW      = makeCorner("BOTTOMLEFT",   BL_X1, 213, BL_X2, 240)
    makeCorner("TOPRIGHT",    BR_X1,   0, BR_X2,  49)
    makeCorner("BOTTOMRIGHT", BR_X1, 213, BR_X2, 240)

    makeEdge("TOPLEFT",    FILL_X1,   0, FILL_X2,  49, tlW)
    makeEdge("BOTTOMLEFT", FILL_X1, 213, FILL_X2, 240, blW)

    -- Store params needed by CB_UpdateContainerTiles.
    frame._skinParams = {
        tex    = TEX,
        tileW  = TILE_W, tileH  = TILE_H,
        centerCols = COLS - 2,
        tlW    = tlW,   tlH    = tlH,
        lx1    = BL_X1, lx2    = BL_X2,
        rx1    = BR_X1, rx2    = BR_X2,
        fx1    = FILL_X1, fx2  = FILL_X2,
        fy1    = FILL_Y1, fy2  = FILL_Y2,
    }
    frame._sideLeftPool  = {}
    frame._sideRightPool = {}
    frame._centerPool    = {}
end

-- Updates the dynamic side and center fill tiles to match the current row count.
-- Call from CB_RenderInventory after the row count is known.
NS.CB_UpdateContainerTiles = function(frame, rows)
    local p = frame._skinParams
    if not p then return end

    local function ensureAndUpdate(pool, needed, createFn, updateFn)
        while #pool < needed do
            pool[#pool + 1] = createFn()
        end
        for i, t in ipairs(pool) do
            if i <= needed then updateFn(t, i) ; t:Show()
            else t:Hide() end
        end
    end

    local lW = p.lx2 - p.lx1
    local rW = p.rx2 - p.rx1

    ensureAndUpdate(frame._sideLeftPool, rows,
        function()
            local t = frame:CreateTexture(nil, "BACKGROUND")
            t:SetTexture(p.tex)
            t:SetTexCoord(p.lx1/256, p.lx2/256, p.fy1/256, p.fy2/256)
            return t
        end,
        function(t, i)
            t:SetSize(lW, p.tileH)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(p.tlH + (i - 1) * p.tileH))
        end)

    ensureAndUpdate(frame._sideRightPool, rows,
        function()
            local t = frame:CreateTexture(nil, "BACKGROUND")
            t:SetTexture(p.tex)
            t:SetTexCoord(p.rx1/256, p.rx2/256, p.fy1/256, p.fy2/256)
            return t
        end,
        function(t, i)
            t:SetSize(rW, p.tileH)
            t:ClearAllPoints()
            t:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -(p.tlH + (i - 1) * p.tileH))
        end)

    local centerNeeded = rows * p.centerCols
    ensureAndUpdate(frame._centerPool, centerNeeded,
        function()
            local t = frame:CreateTexture(nil, "BACKGROUND")
            t:SetTexture(p.tex)
            t:SetTexCoord(p.fx1/256, p.fx2/256, p.fy1/256, p.fy2/256)
            return t
        end,
        function(t, i)
            local col = (i - 1) % p.centerCols
            local row = math.floor((i - 1) / p.centerCols)
            t:SetSize(p.tileW, p.tileH)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", frame, "TOPLEFT",
                p.tlW + col * p.tileW,
                -(p.tlH + row * p.tileH))
        end)
end

-- Variant of CB_ApplyPanelSkin used exclusively for the main CleanBotFrame.
-- Non-ElvUI path uses the thick ornate WoW dialog border (NS.OUTER_BACKDROP)
-- instead of the thin tooltip border so the window reads as a native WoW dialog.
-- ElvUI path is identical to CB_ApplyPanelSkin (SetTemplate replaces all art anyway).
NS.CB_ApplyOuterFrameSkin = function(frame)
    local ac         = NS.accentColor or { r = 0.0, g = 0.0, b = 0.0, a = 0 }
    local alpha      = (NS.transparency or 100) / 100
    -- ElvUI: outermost is lightest (0.10); non-ElvUI: outermost is darkest (0.0) and
    -- inner frames get progressively brighter, reversing the nesting direction.
    local brightness = NS.ElvUI_S and 0.10 or 0.0
    if NS.ElvUI_S then
        frame:StripTextures()
        frame:SetTemplate("Default")
    else
        frame:SetBackdrop(NS.OUTER_BACKDROP)
    end
    frame:SetBackdropColor(brightness, brightness, brightness, CB_LevelAlpha(alpha, 0))
    frame:SetBackdropBorderColor(ac.r, ac.g, ac.b, ac.a or 1)
    NS.CB_skinnedFrames[frame] = { skin = "panel", brightness = brightness, level = 0 }
end

-- nestLevel controls fill brightness relative to the outermost frame.
-- ElvUI:     level 0 = 0.10 (lightest), gets darker inward  — max(0, 0.10 - level * 0.05)
-- Non-ElvUI: level 0 = 0.00 (darkest),  gets lighter inward — level * 0.15
--   A large step is needed because SetBackdropColor is a vertex-colour multiply against
--   the UI-DialogBox-Background texture, which is already dark. Small steps (0.05) result
--   in visually indistinguishable near-black values at every level.
-- Both paths store brightness in CB_skinnedFrames so CB_RefreshTransparency preserves shading.
NS.CB_ApplyPanelSkin = function(frame, nestLevel)
    local ac         = NS.accentColor or { r = 0.3, g = 0.3, b = 0.3, a = 1 }
    local alpha      = (NS.transparency or 100) / 100
    local level      = nestLevel or 0
    local brightness = NS.ElvUI_S and math.max(0, 0.10 - level * 0.05) or (level * 0.05)
    if NS.ElvUI_S then
        frame:StripTextures()
        frame:SetTemplate("Default")
    else
        frame:SetBackdrop(NS.PANEL_BACKDROP)
    end
    frame:SetBackdropColor(brightness, brightness, brightness, CB_LevelAlpha(alpha, level))
    frame:SetBackdropBorderColor(ac.r, ac.g, ac.b, ac.a or 1)
    NS.CB_skinnedFrames[frame] = { skin = "panel", brightness = brightness, level = level }
end

NS.CB_ApplyInnerSkin = function(frame)
    local ac = NS.accentColor or { r = 0.3, g = 0.3, b = 0.3, a = 1 }
    if NS.ElvUI_S then
        frame:StripTextures()
        frame:SetTemplate("Transparent")
    else
        frame:SetBackdrop(NS.PANEL_BACKDROP)
        frame:SetBackdropColor(0, 0, 0, 0.4)  -- fixed; transparency setting only affects panel frames
    end
    frame:SetBackdropBorderColor(ac.r, ac.g, ac.b, ac.a or 1)
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

-- Tab button built on UIPanelButtonTemplate.
-- PanelTabButtonTemplate does not exist in WoW 3.3.5a, so we use the standard
-- button template and layer the active/inactive visual state on top.
-- Exposes tab:SetActive(bool) so call sites do not need to manage font objects
-- or button states directly.
-- ElvUI is applied via HandleButton when available.
NS.CB_CreateTab = function(parent, name, text, onClick)
    local tab = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    tab:SetSize(NS.TAB_WIDTH, NS.TAB_HEIGHT)
    if text    then tab:SetText(text)                   end
    if onClick then tab:SetScript("OnClick", onClick)   end
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(tab)     end

    -- Unified active/inactive toggle.
    tab.SetActive = function(self, active)
        if active then
            self:SetNormalFontObject(GameFontHighlightSmall)
            self:SetButtonState("PUSHED", true)
        else
            self:SetNormalFontObject(GameFontNormalSmall)
            self:SetButtonState("NORMAL", false)
        end
    end

    tab:SetActive(false)  -- start inactive
    return tab
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
-- Clicking the swatch opens the WoW ColorPickerFrame.
--
-- showAlpha (optional bool): when true, the picker shows an opacity slider and
--   onChange(r, g, b, a) fires with all four channels.
--   When false/nil, onChange(r, g, b) fires as before (backward compatible).
-- initA (optional number 0–1): starting alpha when showAlpha is true. Defaults to 1.
--
-- The wrapper exposes :setColor(r, g, b [, a]) and a .swatch texture reference.
-- WoW's ColorPickerFrame uses an inverted opacity convention: opacity 0 = fully opaque,
-- opacity 1 = fully transparent. We convert: opacity = 1 - a on the way in/out.
NS.CB_CreateColorSwatch = function(parent, name, text, initR, initG, initB, onChange, showAlpha, initA)
    local r, g, b = initR or 1, initG or 1, initB or 1
    local a       = (showAlpha and initA) or 1

    local wrapper = CreateFrame("Frame", nil, parent)
    wrapper:SetSize(160, 20)

    local btn = CreateFrame("Button", name, wrapper)
    btn:SetSize(20, 20)
    btn:SetPoint("LEFT", wrapper, "LEFT", 0, 0)

    local swatch = btn:CreateTexture(nil, "BACKGROUND")
    swatch:SetAllPoints()
    swatch:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    swatch:SetVertexColor(r, g, b, a)
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
        local prevR, prevG, prevB, prevA = r, g, b, a

        -- Fires when the user moves the RGB sliders.
        -- Intentionally does NOT read OpacitySliderFrame — SetColorRGB triggers this
        -- callback immediately (before ShowUIPanel initialises the opacity slider),
        -- so reading the slider here would clobber alpha with a stale value.
        local function applyRGB()
            r, g, b = ColorPickerFrame:GetColorRGB()
            swatch:SetVertexColor(r, g, b, a)
            if onChange then
                if showAlpha then onChange(r, g, b, a) else onChange(r, g, b) end
            end
        end

        -- Fires only when the user moves the opacity slider.
        -- WoW opacity convention: 0 = fully opaque, 1 = fully transparent (inverted).
        local function applyOpacity()
            a = 1 - OpacitySliderFrame:GetValue()
            swatch:SetVertexColor(r, g, b, a)
            if onChange then onChange(r, g, b, a) end
        end

        ColorPickerFrame.func       = applyRGB
        ColorPickerFrame.cancelFunc = function()
            r, g, b, a = prevR, prevG, prevB, prevA
            swatch:SetVertexColor(r, g, b, a)
            if onChange then
                if showAlpha then onChange(r, g, b, a) else onChange(r, g, b) end
            end
        end

        ColorPickerFrame:SetColorRGB(r, g, b)

        if showAlpha then
            ColorPickerFrame.hasOpacity  = true
            ColorPickerFrame.opacity     = 1 - a  -- convert alpha → WoW opacity
            ColorPickerFrame.opacityFunc = applyOpacity
        else
            ColorPickerFrame.hasOpacity  = false
            ColorPickerFrame.opacityFunc = nil
        end

        ShowUIPanel(ColorPickerFrame)
    end)

    wrapper.swatch   = swatch
    wrapper.setColor = function(self, nr, ng, nb, na)
        r, g, b = nr, ng, nb
        if showAlpha and na ~= nil then a = na end
        swatch:SetVertexColor(r, g, b, a)
    end

    wrapper.marginTop    = NS.MARGIN.swatch.top
    wrapper.marginBottom = NS.MARGIN.swatch.bottom
    wrapper.marginLeft   = NS.MARGIN.swatch.left
    wrapper.marginRight  = NS.MARGIN.swatch.right
    return wrapper
end
