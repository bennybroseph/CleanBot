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

-- Registry of frames skinned by CB_ApplyFrameSkin.
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

-- Panel factory — creates a bordered child frame, applies CB_ApplyFrameSkin for
-- nestLevel, and stamps paddingTop/Bottom/Left/Right from paddingRole so child
-- helpers such as CB_CreateScrollFrame can read parent.paddingXxx directly.
-- Returns the new frame. Caller is responsible for SetPoint / SetAllPoints.
NS.CB_CreatePanel = function(parent, name, nestLevel, paddingRole)
    local frame = CreateFrame("Frame", name, parent)
    NS.CB_ApplyFrameSkin(frame, nestLevel or 1)
    local pad = NS.PADDING[paddingRole] or NS.PADDING.panel
    frame.paddingTop    = pad.top
    frame.paddingBottom = pad.bottom
    frame.paddingLeft   = pad.left
    frame.paddingRight  = pad.right
    return frame
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
-- Must be called AFTER CB_ApplyFrameSkin (i.e. after any StripTextures call).
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
-- ElvUI: centred label using GameFontNormalLarge.
NS.CB_ApplyInventoryTitleBar = function(frame, botName, class)
    if NS.ElvUI_S then
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
-- Unlike CB_ApplyFrameSkin, this does NOT register for accent-colour or
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

-- Single entry point for skinning any structural frame.
--
-- nestLevel controls which backdrop and fill brightness to use:
--   0        — outermost window (CleanBotFrame, inventory windows).
--              Non-ElvUI: ornate OUTER_BACKDROP; ElvUI: SetTemplate("Default").
--   1, 2, … — inner panels. Both paths use PANEL_BACKDROP / SetTemplate("Default");
--              brightness scales per level so nested frames read as progressively
--              inset (ElvUI gets darker inward, Blizzard gets lighter inward).
--
-- ElvUI:     level 0 → 0.10 brightness, each additional level subtracts 0.05 → max 0
-- Non-ElvUI: level 0 → 0.00 brightness, each level adds 0.05
--   SetBackdropColor is a vertex-colour multiply; small steps look near-black so
--   0.05 per level keeps contrast visible across at least four nesting levels.
--
-- Registers every frame in CB_skinnedFrames so CB_RefreshAccentColor and
-- CB_RefreshTransparency can re-apply shading without re-calling this function.
NS.CB_ApplyFrameSkin = function(frame, nestLevel)
    local level = nestLevel or 1

    if level == 0 then
        -- Outermost window: accent colour has no tint by default (a=0 on Blizzard).
        local ac         = NS.accentColor or { r = 0.0, g = 0.0, b = 0.0, a = 0 }
        local alpha      = (NS.transparency or 100) / 100
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
    else
        -- Inner panel: depth is 0-based for the brightness formula (level 1 = shallowest).
        local ac         = NS.accentColor or { r = 0.3, g = 0.3, b = 0.3, a = 1 }
        local alpha      = (NS.transparency or 100) / 100
        local depth      = level - 1
        local brightness = NS.ElvUI_S and math.max(0, 0.10 - depth * 0.02) or (depth * 0.05)
        if NS.ElvUI_S then
            frame:StripTextures()
            frame:SetTemplate("Default")
        else
            frame:SetBackdrop(NS.PANEL_BACKDROP)
        end
        frame:SetBackdropColor(brightness, brightness, brightness, CB_LevelAlpha(alpha, depth))
        frame:SetBackdropBorderColor(ac.r, ac.g, ac.b, ac.a or 1)
        NS.CB_skinnedFrames[frame] = { skin = "panel", brightness = brightness, level = depth }
    end
end

-- Internal skin for scrollable list containers (CB_CreateSelectList only).
-- Uses SetTemplate("Transparent") on ElvUI so the list reads as a recessed input
-- area rather than a standard panel. Not registered for transparency refresh —
-- the fixed dark alpha is intentional regardless of the theme setting.
local function CB_ApplyInnerSkin(frame)
    local ac = NS.accentColor or { r = 0.3, g = 0.3, b = 0.3, a = 1 }
    if NS.ElvUI_S then
        frame:StripTextures()
        frame:SetTemplate("Transparent")
    else
        frame:SetBackdrop(NS.PANEL_BACKDROP)
        frame:SetBackdropColor(0, 0, 0, 0.4)
    end
    frame:SetBackdropBorderColor(ac.r, ac.g, ac.b, ac.a or 1)
end

-- ============================================================
-- Layout helper — anchors widget directly below above (vertical flow).
-- Gap (Y axis) = above.marginBottom + widget.marginTop.
-- X position is CSS-style: parent.paddingLeft + widget.marginLeft,
-- applied relative to the parent frame's left edge so each widget
-- in the chain positions itself independently (not inherited from above).
-- ============================================================
NS.CB_AnchorBelow = function(widget, above)
    local gap    = (above.marginBottom or 0) + (widget.marginTop or 0)
    local parent = widget:GetParent()
    local xLeft  = (parent and parent.paddingLeft or 0) + (widget.marginLeft or 0)
    widget:ClearAllPoints()
    widget:SetPoint("TOP",  above,  "BOTTOM", 0,    -gap)
    widget:SetPoint("LEFT", parent, "LEFT",   xLeft,  0)
end

-- ============================================================
-- Layout helper — anchors widget directly ahead (to the right) of
-- before (horizontal flow).
-- Gap (X axis) = before.marginRight + widget.marginLeft.
-- Y position is inherited from before's top edge so the widget stays
-- on the same implicit row regardless of where that row sits in a
-- vertical chain. (CSS-style parent-relative Y is intentionally not
-- used here — it would snap mid-chain rows to the parent's top edge.)
-- ============================================================
NS.CB_AnchorAhead = function(widget, before)
    local gap = (before.marginRight or 0) + (widget.marginLeft or 0)
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT", before, "TOPRIGHT", gap, 0)
end

-- ============================================================
-- Quest text factories
--
-- Each factory creates a FontString styled for its role and stamps
-- uniform margins so CB_AnchorBelow produces consistent spacing
-- without any hardcoded offsets at the call site.
--
-- Skin priority: ElvUI (E.media.normFont) → WoW named font objects.
-- Color and size are set explicitly so the result is the same
-- regardless of which FontObject the named font currently inherits.
-- ============================================================

--- Creates a quest title FontString.
--- ElvUI: E.media.normFont at 20px, #ffcc1a.
--- Default: QuestTitleFont face at 22px, black with a #7d590d drop shadow.
--- @param parent table  Parent frame to create the FontString inside.
--- @return table        The created FontString with margins stamped.
NS.CB_CreateQuestHeader = function(parent)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    local E  = NS.ElvUI_E
    if E and E.media and E.media.normFont then
        fs:SetFont(E.media.normFont, 22)
        fs:SetTextColor(1, 0.8, 0.102)        -- #ffcc1a
    else
        local ref  = _G["QuestTitleFont"]
        local path = ref and ref:GetFont()
        fs:SetFont(path or "Fonts\\MORPHEUS.TTF", 22)
        fs:SetTextColor(0, 0, 0)              -- black
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0.490, 0.349, 0.051)  -- #7d590d
    end
    fs:SetJustifyH("LEFT")
    fs.marginTop    = 8
    fs.marginBottom = 8
    fs.marginLeft   = 0
    fs.marginRight  = 0
    return fs
end

--- Creates a quest body text FontString (description or objectives text).
--- ElvUI: E.media.normFont at 14px, white.
--- Default: QuestFont face at its native size, brown #2e1f0f.
--- @param parent table  Parent frame to create the FontString inside.
--- @return table        The created FontString with margins stamped.
NS.CB_CreateQuestParagraph = function(parent)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    local E  = NS.ElvUI_E
    if E and E.media and E.media.normFont then
        fs:SetFont(E.media.normFont, 14)
        fs:SetTextColor(1, 1, 1)              -- white
    else
        local ref        = _G["QuestFont"]
        local path, size = ref and ref:GetFont()
        fs:SetFont(path or "Fonts\\FRIZQT__.TTF", size or 12)
        fs:SetTextColor(0.180, 0.122, 0.059)  -- #2e1f0f
    end
    fs:SetJustifyH("LEFT")
    fs.marginTop    = 0
    fs.marginBottom = 8
    fs.marginLeft   = 0
    fs.marginRight  = 0
    return fs
end

--- Creates a leaderboard objective entry FontString.
--- ElvUI: E.media.normFont at 14px; #ffcc1a when complete, #999999 when incomplete.
--- Default: GameFontHighlight face at its native size; #333333 when complete, #2e1f0f when incomplete.
--- @param parent   table    Parent frame to create the FontString inside.
--- @param finished boolean  Whether this objective has been completed.
--- @return table            The created FontString with margins stamped.
NS.CB_CreateObjectiveText = function(parent, finished)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    local E  = NS.ElvUI_E
    if E and E.media and E.media.normFont then
        fs:SetFont(E.media.normFont, 14)
        if finished then
            fs:SetTextColor(1, 0.8, 0.102)    -- #ffcc1a
        else
            fs:SetTextColor(0.6, 0.6, 0.6)    -- #999999
        end
    else
        local ref        = _G["GameFontHighlight"]
        local path, size = ref and ref:GetFont()
        fs:SetFont(path or "Fonts\\FRIZQT__.TTF", size or 12)
        if finished then
            fs:SetTextColor(0.2, 0.2, 0.2)        -- #333333 greyed out
        else
            fs:SetTextColor(0.180, 0.122, 0.059)  -- #2e1f0f same as paragraph
        end
    end
    fs:SetJustifyH("LEFT")
    fs.marginTop    = 0
    fs.marginBottom = 1
    fs.marginLeft   = 0
    fs.marginRight  = 0
    return fs
end

-- ============================================================
-- Frame factory — creates a child frame nested inside parent,
-- inset by parent's padding (chosen by paddingRole) plus the
-- child's own margin (chosen by marginType, from NS.MARGIN).
--
-- paddingRole: "frame" | "panel" | "section"  — selects NS.PADDING[paddingRole]
-- marginType:  "panel" | "section" | nil       — selects NS.MARGIN[marginType];
--              nil means no extra margin (pure padding placement).
-- widthPct / heightPct: fraction of the parent's interior to fill (default 1.0).
-- nestLevel:   passed to CB_ApplyFrameSkin to control fill brightness relative
--              to parent (1 = one level in from the outermost frame).
--
-- Full fill (both 1.0): dual anchors so the layout engine handles resizing.
-- Partial fill: TOPLEFT anchor + OnSizeChanged to recompute size dynamically.
--
-- The child's margin values are stamped onto it so CB_AnchorBelow / CB_AnchorAhead
-- can treat it the same as any other widget in a flow chain.
-- ============================================================
NS.CB_CreateInnerFrame = function(parent, name, paddingRole, marginType, widthPct, heightPct, nestLevel)
    local child = CreateFrame("Frame", name, parent)

    local pad = NS.PADDING[paddingRole] or NS.PADDING.panel
    local mar = (marginType and NS.MARGIN[marginType]) or {}

    local mTop    = mar.top    or 0
    local mBottom = mar.bottom or 0
    local mLeft   = mar.left   or 0
    local mRight  = mar.right  or 0

    child.marginTop    = mTop
    child.marginBottom = mBottom
    child.marginLeft   = mLeft
    child.marginRight  = mRight

    local wPct = widthPct  or 1
    local hPct = heightPct or 1

    if wPct == 1 and hPct == 1 then
        child:SetPoint("TOPLEFT", parent, "TOPLEFT",
             pad.left   + mLeft,
            -(pad.top   + mTop))
        child:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT",
            -(pad.right  + mRight),
              pad.bottom + mBottom)
    else
        child:SetPoint("TOPLEFT", parent, "TOPLEFT",
             pad.left + mLeft,
            -(pad.top + mTop))

        local function resize(w, h)
            local availW = w - pad.left - pad.right - mLeft - mRight
            local availH = h - pad.top  - pad.bottom - mTop - mBottom
            child:SetSize(math.max(availW * wPct, 1), math.max(availH * hPct, 1))
        end

        parent:HookScript("OnSizeChanged", function(self, w, h) resize(w, h) end)

        local w, h = parent:GetWidth(), parent:GetHeight()
        if w > 0 and h > 0 then resize(w, h) end
    end

    NS.CB_ApplyFrameSkin(child, nestLevel or 1)

    return child
end

-- ============================================================
-- Scroll frame factory — creates a scroll frame inset from parent by
-- parent's stamped padding, wires up the scroll child, mouse wheel, and
-- ElvUI scroll bar skinning. The scroll bar is accessed via the standard
-- UIPanelScrollFrameTemplate naming convention: name .. "ScrollBar".
--
-- Both the scroll frame and scroll child have paddingTop/Bottom/Left/Right = 0
-- stamped onto them — they are borderless containers with no visual inset.
-- Content inside the scroll child uses only its own margins; there is no
-- border to escape from.
--
-- Returns scrollFrame, scrollChild.
-- ============================================================
NS.CB_CreateScrollFrame = function(parent, name)
    local pTop    = parent.paddingTop    or 0
    local pBottom = parent.paddingBottom or 0
    local pLeft   = parent.paddingLeft   or 0
    local pRight  = parent.paddingRight  or 0

    local sf = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     parent, "TOPLEFT",      pLeft,          -pTop)
    sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -(pRight + 20),   pBottom)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local max = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * 20)))
    end)

    sf.paddingTop    = 0 ; sf.paddingBottom = 0
    sf.paddingLeft   = 0 ; sf.paddingRight  = 0

    local sc = CreateFrame("Frame", name .. "Child", sf)
    sc:SetHeight(1)
    sf:SetScrollChild(sc)
    sf:SetScript("OnSizeChanged", function(self, w, _)
        sc:SetWidth(w)
    end)

    sc.paddingTop    = 0 ; sc.paddingBottom = 0
    sc.paddingLeft   = 0 ; sc.paddingRight  = 0

    local scrollBar = _G[name .. "ScrollBar"]
    if scrollBar and NS.ElvUI_S then
        NS.ElvUI_S:HandleScrollBar(scrollBar)
    end

    return sf, sc
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

-- Creates a standalone collapse/expand button using the native Blizzard +/−
-- circle textures. ElvUI is applied via HandleCollapseExpandButton when present.
-- isCollapsed drives the initial texture state (+ vs −).
-- Size defaults to 16×16 to match the quest list header row height.
--- @param parent     table    Parent frame.
--- @param isCollapsed boolean Initial collapsed state.
--- @return table              The created Button.
NS.CB_CreateCollapseButton = function(parent, isCollapsed)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(16, 16)

    local MINUS_UP = "Interface\\Buttons\\UI-MinusButton-Up"
    local MINUS_DN = "Interface\\Buttons\\UI-MinusButton-Down"
    local PLUS_UP  = "Interface\\Buttons\\UI-PlusButton-Up"
    local PLUS_DN  = "Interface\\Buttons\\UI-PlusButton-Down"
    local PLUS_HL  = "Interface\\Buttons\\UI-PlusButton-Hilight"

    if isCollapsed then
        btn:SetNormalTexture(PLUS_UP)
        btn:SetPushedTexture(PLUS_DN)
    else
        btn:SetNormalTexture(MINUS_UP)
        btn:SetPushedTexture(MINUS_DN)
    end
    btn:SetHighlightTexture(PLUS_HL, "ADD")

    if NS.ElvUI_S then
        NS.ElvUI_S:HandleCollapseExpandButton(btn, isCollapsed and "+" or "-")
    end

    return btn
end

--- Creates a quest reward item button backed by LargeItemButtonTemplate (147×41).
--- The template provides $parentIconTexture (39×39 BACKGROUND), $parentNameFrame
--- (parchment backing texture), $parentName (GameFontHighlight FontString), and
--- $parentCount (NumberFontNormal FontString) — all accessed by CB_PopulateRewardSlot
--- via _G[name.."IconTexture/Name/Count"].
---
--- ElvUI: strips the parchment art, applies SetTemplate("Default"), re-layers the
---   icon to ARTWORK so it renders above the backdrop, re-anchors $parentName.
--- Default: template art is used as-is; the parchment NameFrame background matches
---   the Blizzard quest log reward style with no extra skinning needed.
---
--- @param parent table   Parent frame.
--- @param name   string  Globally unique frame name (required by $parent substitution).
--- @return table         The created Button with margins stamped.
NS.CB_CreateQuestRewardItem = function(parent, name)
    local btn = CreateFrame("Button", name, parent, "LargeItemButtonTemplate")

    local bName   = btn:GetName()
    local iconTex = bName and _G[bName .. "IconTexture"]

    if NS.ElvUI_S then
        local nameFS = bName and _G[bName .. "Name"]

        btn:StripTextures()
        btn:SetTemplate("Default")
        btn:SetBackdropBorderColor(1, 1, 1, 1)
        btn:StyleButton()

        if iconTex then
            -- Move to ARTWORK so it renders above the BACKGROUND backdrop fill.
            iconTex:SetDrawLayer("ARTWORK")
            iconTex:ClearAllPoints()
            iconTex:SetPoint("TOPLEFT",    btn, "TOPLEFT",    2, -2)
            iconTex:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 2,  2)
            iconTex:SetWidth(btn:GetHeight() - 4)
            NS.CB_ApplyElvCoords(iconTex)
            iconTex:Show()
        end

        if nameFS and iconTex then
            -- Re-anchor away from the (now-hidden) parchment NameFrame texture.
            nameFS:ClearAllPoints()
            nameFS:SetPoint("LEFT",   iconTex, "RIGHT",  4,  0)
            nameFS:SetPoint("RIGHT",  btn,     "RIGHT", -4,  0)
            nameFS:SetPoint("TOP",    btn,     "TOP",    0, -2)
            nameFS:SetPoint("BOTTOM", btn,     "BOTTOM", 0,  2)
        end
    end

    -- Vanilla only: quality border scoped to the icon, not the full button.
    -- ElvUI uses SetBackdropBorderColor on the button itself via CB_SetQualityBorder.
    if not NS.ElvUI_S and iconTex then
        local qf = CreateFrame("Frame", nil, btn)
        qf:SetAllPoints(iconTex)
        qf:SetFrameLevel(btn:GetFrameLevel() + 2)
        qf:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 8,
            insets   = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        qf:SetBackdropBorderColor(0, 0, 0, 0)
        btn.qualityFrame = qf
    end

    btn:SetScript("OnEnter", function(self)
        if self.itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.itemLink)
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    btn.marginTop    = 4
    btn.marginBottom = 4
    btn.marginLeft   = 0
    btn.marginRight  = 4
    return btn
end

-- Creates a collapsible section for the Manage tab.
--
-- The toggle button and title label are children of parent (scroll child, MEDIUM
-- strata). The visual bg frame is also a child of parent but forced to BACKGROUND
-- strata so it renders behind everything else.
--
-- IMPORTANT: In WoW 3.3.5a child frames INHERIT their parent's strata. section.bg
-- defaults to MEDIUM (no explicit SetFrameStrata call), so content widgets parented
-- to it are also MEDIUM and remain mouse-interactive. Do NOT call SetFrameStrata on bg.
--
-- section.frame starts as the toggle button. Call section:Finalize(lastWidget)
-- once all content widgets are added; this sets section.frame to lastWidget so
-- the next section can chain its CB_AnchorBelow off the correct anchor point.
--
-- Content widgets are children of bg and hide/show automatically with it — no
-- manual contentWidgets registration needed.
--
-- Collapsed state is persisted in CleanBot_SavedVars.collapsedSections[key].
-- parent must have paddingRight stamped (via CB_CreatePanel) so Apply() can compute
-- the section background's right edge without guessing the parent's role.
NS.CB_CreateSection = function(parent, key, title, nestLevel)
    local section = {}

    -- Toggle button using the native Blizzard gold +/- circle textures — the same
    -- art used by the Reputation, Skills, TradeSkill, and Trainer panels since vanilla.
    local toggleBtn = CreateFrame("Button", "CleanBotSection_" .. key .. "_Toggle", parent)
    toggleBtn:SetSize(14, 14)

    local MINUS_UP = "Interface\\Buttons\\UI-MinusButton-Up"
    local MINUS_DN = "Interface\\Buttons\\UI-MinusButton-Down"
    local PLUS_UP  = "Interface\\Buttons\\UI-PlusButton-Up"
    local PLUS_DN  = "Interface\\Buttons\\UI-PlusButton-Down"
    local PLUS_HL  = "Interface\\Buttons\\UI-PlusButton-Hilight"

    toggleBtn:SetNormalTexture(MINUS_UP)
    toggleBtn:SetPushedTexture(MINUS_DN)
    toggleBtn:SetHighlightTexture(PLUS_HL, "ADD")

    -- ElvUI hooks SetNormalTexture internally to swap in its own Plus/Minus textures,
    -- so our SetText override (which calls SetNormalTexture) still drives the state.
    if NS.ElvUI_S then NS.ElvUI_S:HandleCollapseExpandButton(toggleBtn, "-") end

    -- Swap between + (collapsed) and − (expanded) by swapping normal/pushed textures.
    toggleBtn.SetText = function(self, text)
        if text == "+" then
            self:SetNormalTexture(PLUS_UP) ; self:SetPushedTexture(PLUS_DN)
        else
            self:SetNormalTexture(MINUS_UP) ; self:SetPushedTexture(MINUS_DN)
        end
    end

    -- Title label: FontString on parent, to the right of the toggle button.
    local titleLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleLabel:SetText(title)
    titleLabel:SetPoint("LEFT", toggleBtn, "RIGHT", 4, 0)

    -- Load saved collapse state.
    local saved = CleanBot_SavedVars and CleanBot_SavedVars.collapsedSections
    section.collapsed  = saved and saved[key] == true or false
    section.key        = key
    section.toggleBtn  = toggleBtn   -- always the section header; never hidden
    section.lastWidget = nil         -- set by Finalize; deepest content widget
    section.frame      = toggleBtn   -- updated to lastWidget in Finalize
    section.onToggle   = nil         -- optional callback fired after each toggle

    -- Returns the bottommost currently-visible widget for this section.
    -- Collapsed → header toggle button only; expanded → last content widget.
    -- Falls back to toggleBtn if Finalize has not been called yet.
    section.GetAnchor = function(self)
        return self.collapsed and self.toggleBtn or (self.lastWidget or self.toggleBtn)
    end

    -- Shared width calculation used by both Apply and the OnSizeChanged hook.
    local function calcBgWidth()
        local mar        = NS.MARGIN.section
        local rightInset = (parent.paddingRight or 0) + mar.right
        local pw         = parent:GetWidth()
        return math.max(pw > 0 and (pw - (parent.paddingLeft or 0) - (toggleBtn.marginLeft or 0) - rightInset) or 200, 1)
    end

    section.Apply = function(self)
        -- Content widgets are children of bg and hide/show automatically with it.
        if self.collapsed then
            self.bg:Hide()
        else
            local mar    = NS.MARGIN.section
            local topGap = (toggleBtn.marginBottom or 0) + mar.top
            -- Anchor TOPLEFT to toggleBtn BOTTOMLEFT so bg tracks the toggle when
            -- reflow moves it. toggleBtn is already at panel.left from the panel wall,
            -- so only the section margin delta is needed as an X offset — not leftX
            -- (which would double-count the panel padding).
            self.bg:ClearAllPoints()
            self.bg:SetPoint("TOPLEFT", toggleBtn, "BOTTOMLEFT",
                mar.left - (toggleBtn.marginLeft or 0), -topGap)
            self.bg:SetWidth(calcBgWidth())
            self.bg:SetHeight(2000)  -- corrected by UpdateBackground after first render
            self.bg:Show()
        end
        toggleBtn:SetText(self.collapsed and "+" or "-")
    end

    -- Re-sync bg width whenever the parent (scroll child) changes size — e.g. when
    -- the frame collapses or expands on tab switch. Only updates width; height is
    -- managed separately by UpdateBackground to avoid resetting the 2000px placeholder.
    parent:HookScript("OnSizeChanged", function()
        if not section.collapsed and section.bg:IsShown() then
            section.bg:SetWidth(calcBgWidth())
        end
    end)

    section.Toggle = function(self)
        self.collapsed = not self.collapsed
        if CleanBot_SavedVars then
            if not CleanBot_SavedVars.collapsedSections then
                CleanBot_SavedVars.collapsedSections = {}
            end
            CleanBot_SavedVars.collapsedSections[self.key] = self.collapsed or nil
        end
        self:Apply()
        -- Fire after Apply so GetAnchor already reflects the new state.
        if self.onToggle then self.onToggle() end
    end

    -- Call once all content widgets have been added and registered.
    -- lastWidget: the bottommost content widget in the section.
    -- Sets section.frame / section.lastWidget so GetAnchor and the next
    -- section's anchor both resolve correctly.
    section.Finalize = function(self, lastWidget)
        self.lastWidget = lastWidget
        self.frame      = lastWidget
        self:Apply()
    end

    toggleBtn:SetScript("OnClick", function() section:Toggle() end)

    -- Match label margins so CB_AnchorBelow spacing is consistent with the
    -- old plain-label style that sections replace.
    toggleBtn.marginTop    = NS.MARGIN.label.top
    toggleBtn.marginBottom = NS.MARGIN.label.bottom
    toggleBtn.marginLeft   = NS.MARGIN.label.left
    toggleBtn.marginRight  = NS.MARGIN.label.right

    -- Visual background frame. Stays at MEDIUM strata (default) so that child
    -- content widgets inherit MEDIUM and remain mouse-interactive. WoW 3.3.5a
    -- renders same-strata same-level frames in creation order, so subsequent
    -- sections' toggle buttons (created later) always render on top of this bg
    -- even during the height=2000 expansion phase.
    -- Hidden until Apply() shows it on first expand.
    local bg = NS.CB_CreatePanel(parent, "CleanBotSection_" .. key .. "_BG", nestLevel or 3, "section")
    bg:Hide()
    section.bg = bg

    -- Corrects the bg height to exactly wrap the section's content area.
    -- Apply() already positions and shows bg (anchored to toggleBtn BOTTOMLEFT)
    -- with a generous temporary height. This trims it to fit once layout resolves.
    -- lastWidget:GetBottom() is valid here because bg is positioned and its
    -- children (content widgets) therefore have real screen coordinates.
    section.UpdateBackground = function(self)
        if self.collapsed or not self.lastWidget then
            self.bg:Hide()
            return
        end
        local bgTop  = self.bg:GetTop()
        local lastBt = self.lastWidget:GetBottom()
        if not (bgTop and lastBt) then return end
        local botGap = (self.lastWidget.marginBottom or 0) + (self.bg.paddingBottom or 0)
        self.bg:SetHeight(math.max(bgTop - lastBt + botGap, 4))
    end

    return section
end

-- A bordered, scrollable list of selectable string rows.
--
-- Returns a container frame with the following API:
--   container:SetItems({"string", ...}) — populates rows; clears any previous selection.
--   container:GetSelected()             — returns the value of the currently selected row,
--                                         or nil if nothing is selected.
--
-- onSelect(value) is called whenever the user clicks a row.
-- width / height size the visible container; rows scroll inside it.
-- ElvUI skins the inner scroll bar when present.
NS.CB_CreateSelectList = function(parent, name, width, height, onSelect)
    local ROW_H = 20

    -- Outer bordered container. CB_ApplyInnerSkin gives it the panel-inset look
    -- without registering it for theme-refresh (the list colour is fixed art).
    local container = CreateFrame("Frame", name, parent)
    -- width is the content area; add 20px (2px left inset + 18px scrollbar) for the container.
    container:SetSize(width + 20, height)
    CB_ApplyInnerSkin(container)

    -- ScrollFrame inset 2px from the container walls; 20px right gap keeps the
    -- scrollbar (18px) plus a 2px mirror of the left inset inside the container border.
    local sf = CreateFrame("ScrollFrame", name .. "SF", container,
        "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     container, "TOPLEFT",      2,  -2)
    sf:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -20,  2)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local max = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * ROW_H)))
    end)
    -- Re-anchor the scrollbar explicitly so it sits inside the container's right
    -- zone rather than floating to the right of the scroll frame (template default).
    local scrollBar = _G[name .. "SFScrollBar"]
    if scrollBar then
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOPLEFT",    container, "TOPRIGHT",    -20, -20)
        scrollBar:SetPoint("BOTTOMLEFT", container, "BOTTOMRIGHT", -20,  20)
        if NS.ElvUI_S then NS.ElvUI_S:HandleScrollBar(scrollBar) end
    end

    local content = CreateFrame("Frame", name .. "Content", sf)
    content:SetHeight(1)
    sf:SetScrollChild(content)
    sf:SetScript("OnSizeChanged", function(self, w, _)
        content:SetWidth(w)
    end)

    -- Shared state captured by row closures. Reassigning `rows` inside SetItems
    -- is safe — all closures share the same upvalue reference, so a new call to
    -- SetItems immediately makes old OnClick handlers operate on the new table.
    -- Old rows are hidden anyway and will not receive clicks.
    local rows          = {}
    local selectedIndex = nil

    container.SetItems = function(self, items)
        for _, r in ipairs(rows) do r:Hide() end
        rows          = {}
        selectedIndex = nil

        for i, text in ipairs(items) do
            local row = CreateFrame("Button", nil, content)
            row:SetHeight(ROW_H)
            row:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, -(i - 1) * ROW_H)
            row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -(i - 1) * ROW_H)

            local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetPoint("LEFT", row, "LEFT", 4, 0)
            lbl:SetText(text)
            row.label = lbl

            -- Highlight texture shown at reduced alpha when the row is selected.
            local hl = row:CreateTexture(nil, "BACKGROUND")
            hl:SetAllPoints()
            hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            hl:SetBlendMode("ADD")
            hl:SetAlpha(0)
            row.hl = hl

            row.index = i
            row.value = text

            row:SetScript("OnClick", function(self)
                selectedIndex = self.index
                for _, other in ipairs(rows) do
                    other.hl:SetAlpha(other.index == selectedIndex and 0.4 or 0)
                end
                if onSelect then onSelect(self.value) end
            end)

            rows[i] = row
        end

        content:SetHeight(math.max(#items * ROW_H, 1))
    end

    container.GetSelected = function(self)
        return selectedIndex and rows[selectedIndex] and rows[selectedIndex].value
    end

    container.marginTop    = NS.MARGIN.button.top
    container.marginBottom = NS.MARGIN.button.bottom
    container.marginLeft   = NS.MARGIN.button.left
    container.marginRight  = NS.MARGIN.button.right

    return container
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
    if NS.ElvUI_S then
        NS.ElvUI_S:HandleDropDownBox(dd, width)

        -- Reparent the button and text to dd.backdrop, mirroring ElvUI's own Ace3
        -- dropdown skin. HandleDropDownBox leaves the button as a child of dd, where
        -- it is obscured inside a ScrollFrame. Moving it to dd.backdrop (which sits
        -- at the same frame level as dd) resolves the rendering order issue.
        local backdrop = dd.backdrop
        if backdrop then
            local btn  = _G[name .. "Button"]
            local text = _G[name .. "Text"]

            -- HandleDropDownBox anchors backdrop BOTTOMRIGHT to the button, which
            -- creates a circular dependency when we then try to anchor the button to
            -- the backdrop. Re-anchor backdrop to dd directly first to break the cycle.
            backdrop:ClearAllPoints()
            backdrop:SetPoint("TOPLEFT",     dd, "TOPLEFT",     20,  0)
            backdrop:SetPoint("BOTTOMRIGHT", dd, "BOTTOMRIGHT", -8,  8)

            if btn then
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT",     backdrop, "TOPRIGHT",    -22, -2)
                btn:SetPoint("BOTTOMRIGHT", backdrop, "BOTTOMRIGHT",  -2,  2)
                btn:SetParent(backdrop)
                -- After reparenting, self:GetParent() is the unnamed backdrop frame,
                -- breaking UIDropDownMenu's name-based lookup. Reference dd directly.
                btn:SetScript("OnClick", function()
                    ToggleDropDownMenu(1, nil, dd)
                end)
            end

            if text then
                text:ClearAllPoints()
                text:SetJustifyH("RIGHT")
                text:SetPoint("RIGHT", btn,      "LEFT",  -3, 0)
                text:SetPoint("LEFT",  backdrop, "LEFT",   2, 0)
                text:SetParent(backdrop)
            end
        end
    end
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

    tab.marginTop    = NS.MARGIN.tab.top
    tab.marginBottom = NS.MARGIN.tab.bottom
    tab.marginLeft   = NS.MARGIN.tab.left
    tab.marginRight  = NS.MARGIN.tab.right
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

    -- Snapshot original colors for Enable/Disable — must be read after HandleSliderFrame
    -- so ElvUI's thumb replacement is already in place.
    local thumbTex                    = s:GetThumbTexture()
    local thumbR, thumbG, thumbB      = thumbTex:GetVertexColor()
    local labelR, labelG, labelB      = label and label:GetTextColor()
    local lowR,   lowG,   lowB        = lowLabel  and lowLabel:GetTextColor()
    local highR,  highG,  highB       = highLabel and highLabel:GetTextColor()
    local boxR,   boxG,   boxB        = box:GetTextColor()
    local GREY                        = 0.5

    wrapper.Disable = function(self)
        if label    then label:SetTextColor(GREY, GREY, GREY) end
        if lowLabel  then lowLabel:SetTextColor(GREY, GREY, GREY) end
        if highLabel then highLabel:SetTextColor(GREY, GREY, GREY) end
        box:SetTextColor(GREY, GREY, GREY)
        thumbTex:SetVertexColor(GREY, GREY, GREY)
        s:EnableMouse(false)
        box:EnableMouse(false)
    end

    wrapper.Enable = function(self)
        if label    then label:SetTextColor(labelR, labelG, labelB) end
        if lowLabel  then lowLabel:SetTextColor(lowR, lowG, lowB) end
        if highLabel then highLabel:SetTextColor(highR, highG, highB) end
        box:SetTextColor(boxR, boxG, boxB)
        thumbTex:SetVertexColor(thumbR, thumbG, thumbB)
        s:EnableMouse(true)
        box:EnableMouse(true)
    end

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

-- Applies an ElvUI-style square skin to an equipment slot button.
--
-- Applies an ElvUI-style square skin to an equipment slot button.
--
-- StripTextures nulls btn.bg and btn.icon. SetTemplate applies the dark
-- backdrop + border directly on btn (avoids backdrop child frame level issues).
-- Both the slot art (btn.bg) and item icon (btn.icon) are restored with
-- E.TexCoords cropping, which trims the rounded edges off the circular paperdoll
-- slot textures and makes them read as square. btn.bg sits in BACKGROUND below
-- the ARTWORK icon, so when equipped the icon renders on top of the slot art.
-- RefreshEquipSlots hides btn.bg when an item is equipped and shows it when empty.
-- No-op when ElvUI is not installed.
-- Applies ElvUI's standard icon crop to a texture. Trims the rounded edges that
-- are baked into WoW's icon and paperdoll slot textures, giving them a square look.
-- No-op when ElvUI is not installed.
-- Returns the clean API item link for a raw item link (which may contain color
-- codes and extra fields). Strips to the item ID and re-fetches from the client
-- cache via GetItemInfo. Falls back to the raw link if the cache misses.
-- Use this before sending any item link over whisper or a bot command.
NS.CB_CleanItemLink = function(rawLink)
    local itemId = strmatch(rawLink, "item:(%d+)")
    local _, apiLink = GetItemInfo(tonumber(itemId) or 0)
    return apiLink or rawLink
end

NS.CB_ApplyElvCoords = function(texture)
    if not NS.ElvUI_E then return end
    texture:SetTexCoord(unpack(NS.ElvUI_E.TexCoords))
end

-- Applies an ElvUI-style square skin to an inventory cell button.
-- Mirrors CB_SkinEquipSlot but for plain Button frames — no ItemButtonTemplate
-- chrome means no StripTextures needed. SetTemplate provides the dark backdrop
-- and border; StyleButton adds hover/push highlight textures; both the icon and
-- the bag-slot background texture receive the E.TexCoords crop.
-- No-op when ElvUI is not installed.
NS.CB_SkinInventoryCell = function(cell)
    if not NS.ElvUI_S then return end
    cell:StripTextures()
    cell:SetTemplate("Default")
    cell:StyleButton()
    if cell.icon then
        NS.CB_ApplyElvCoords(cell.icon)
        cell.icon:SetInside()
    end
    if cell.bg then
        NS.CB_ApplyElvCoords(cell.bg)
        cell.bg:SetAllPoints()
    end
end

NS.CB_SkinEquipSlot = function(btn)
    if not NS.ElvUI_S then return end
    btn:StripTextures()
    btn:SetTemplate("Default")
    btn:StyleButton()
    if btn.icon then
        NS.CB_ApplyElvCoords(btn.icon)
        btn.icon:SetInside()
    end
    -- btn.bg is created AFTER this function returns (in CB_CreateEquipSlots) so
    -- that it is always the last BACKGROUND texture on the button and renders
    -- above the dark fill that SetTemplate just stamped on.
end

-- Returns the r, g, b color for a given item quality level (0–6).
-- Wraps GetItemQualityColor with a white fallback so callers never receive nil.
NS.CB_GetQualityColor = function(quality)
    local r, g, b = GetItemQualityColor(quality or 1)
    return r or 1, g or 1, b or 1
end

-- Colors the border of an item button to match the item's quality.
--
-- ElvUI path: SetTemplate already applied a backdrop border — SetBackdropBorderColor
--   tints it with the quality colour.
-- Blizz path: btn.normTex is the ItemButtonTemplate NormalTexture (UI-Quickslot2),
--   a mostly-transparent overlay with visible rounded edges. SetVertexColor tints
--   those edges to the quality colour; Show() makes it visible if it was hidden
--   (equip slots hide normTex on empty slots; inventory cells keep it visible).
-- Creates a rounded quality-colour border on an item button for the Blizz UI
-- path using a child frame with Interface\Tooltips\UI-Tooltip-Border as the
-- edgeFile. The child frame renders above the parent's texture layers so the
-- border is visible over the icon. Border is hidden (alpha 0) until equipped.
-- Equip slots use this; inventory cells fall back to normTex which is always
-- visible and serves as both the slot indicator and quality tint.
-- No-op on ElvUI — SetTemplate's iborder/oborder child frames handle this.
NS.CB_ApplyQualityBackdrop = function(btn)
    if NS.ElvUI_S then return end
    local f = CreateFrame("Frame", nil, btn)
    f:SetAllPoints()
    f:SetFrameLevel(btn:GetFrameLevel() + 2)
    f:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropBorderColor(0, 0, 0, 0)
    btn.qualityFrame = f
end

-- Colors the border of an item button to match the item's quality.
-- ElvUI: SetBackdropBorderColor (targets SetTemplate's iborder/oborder frames).
-- Blizz with qualityFrame (equip slots): SetBackdropBorderColor on the child frame.
-- Blizz with normTex only (inventory cells): vertex-colours normTex (already visible).
NS.CB_SetQualityBorder = function(btn, quality)
    local r, g, b = GetItemQualityColor(quality or 1)
    if NS.ElvUI_S then
        btn:SetBackdropBorderColor(r, g, b, 1)
    elseif btn.qualityFrame then
        btn.qualityFrame:SetBackdropBorderColor(r, g, b, 1)
    elseif btn.normTex then
        btn.normTex:SetVertexColor(r, g, b)
    end
end

-- Resets the border of an item button to its uncoloured state.
-- ElvUI: restores db.general.bordercolor.
-- Blizz with qualityFrame: hides the border (alpha 0) on empty slots.
-- Blizz with normTex only: resets to white (no tint; normTex stays visible).
NS.CB_ClearQualityBorder = function(btn)
    if NS.ElvUI_S then
        local E  = NS.ElvUI_E
        local bc = (E and E.db and E.db.general and E.db.general.bordercolor) or {}
        btn:SetBackdropBorderColor(bc.r or 0.3, bc.g or 0.3, bc.b or 0.3, 1)
    elseif btn.qualityFrame then
        btn.qualityFrame:SetBackdropBorderColor(0, 0, 0, 0)
    elseif btn.normTex then
        btn.normTex:SetVertexColor(1, 1, 1)
    end
end
