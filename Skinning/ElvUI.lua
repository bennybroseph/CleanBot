-- ============================================================
-- Skinning\ElvUI.lua  —  ElvUI integration, fallback backdrops,
--                        and structural frame/panel skinning.
--
-- Centralises everything ElvUI-related: the module handles and
-- detection, the plain-backdrop fallback, the theme refresh
-- functions (accent / transparency / scale), and the panel /
-- inner / container / scroll skin helpers.
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- ElvUI handles (populated by NS.CB_InitElvUI at PLAYER_LOGIN)
-- ============================================================
NS.ElvUI_E = nil
NS.ElvUI_S = nil

-- Detect ElvUI and grab its Skins module. Called once at login,
-- when ElvUI is guaranteed to be loaded.
--- Populates NS.ElvUI_E / NS.ElvUI_S when ElvUI is installed.
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
--- Registers a top-level window for scale refresh and applies the current scale.
---@param frame table  The top-level frame (UIParent child) to register.
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

--- Computes the per-nesting-level alpha for the non-ElvUI fallback.
---@param baseAlpha number  The base alpha (0–1) before falloff.
---@param level     number  Nesting depth (0 = outermost).
---@return number           baseAlpha when ElvUI is active, else exponentially reduced.
local function CB_LevelAlpha(baseAlpha, level)
    if NS.ElvUI_S then return baseAlpha end
    local factor = 1
    for _ = 1, level do factor = factor * TRANSPARENCY_FALLOFF end
    return baseAlpha * factor
end

-- Re-applies accent colour to every registered skinned frame.
-- a defaults to 1 (fully opaque) when omitted.
--- Re-applies the accent border colour to every registered skinned frame.
---@param r number  Red 0–1.
---@param g number  Green 0–1.
---@param b number  Blue 0–1.
---@param a number? Alpha 0–1 (defaults to 1).
NS.CB_RefreshAccentColor = function(r, g, b, a)
    local alpha = a or 1
    for frame, _ in pairs(NS.CB_skinnedFrames) do
        frame:SetBackdropBorderColor(r, g, b, alpha)
    end
end

-- Re-applies background transparency to every registered panel frame.
-- t is 0–100; 100 = fully opaque, 0 = fully transparent.
-- Non-ElvUI frames additionally apply per-level exponential falloff.
--- Re-applies background transparency to every registered panel frame.
---@param t number  Opacity 0–100 (100 = fully opaque).
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
--- Creates a bordered, skinned child panel with padding fields stamped from its role.
---@param parent      table   Parent frame.
---@param name        string? Optional global frame name.
---@param nestLevel   number? Nesting depth for CB_ApplyFrameSkin (default 1).
---@param paddingRole string? Padding role key into NS.PADDING (default "panel").
---@return table              The created Frame with paddingTop/Bottom/Left/Right stamped.
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
--- Re-applies scale to every registered root frame.
---@param s number  Scale percentage 0–100+ (100 = 1.0).
NS.CB_RefreshScale = function(s)
    local scale = (s or 100) / 100
    for frame, _ in pairs(NS.CB_rootFrames) do
        frame:SetScale(scale)
    end
end

-- Applies the title bar ornament and creates the title FontString for an outer frame.
-- Must be called AFTER CB_ApplyFrameSkin (i.e. after any StripTextures call).
--
-- Non-ElvUI: adds the Blizzard dialog header ornament (256×64 OVERLAY texture,
--   elevated 12px so it overlaps the border) and a compact GameFontNormal label
--   nudged to sit in the ornament's visual band.
-- ElvUI: skips the ornament (SetTemplate handles the chrome) and uses the larger
--   GameFontNormalLarge centred in the title area, matching ElvUI frame conventions.
---@param frame     table   The outer frame to add the title bar to.
---@param titleText string? Title string to display (e.g. "CleanBot").
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
-- CONTAINER_TITLE_OFFSET controls how far below the top edge the label sits.
local CONTAINER_TITLE_OFFSET = 2
--- Places a centred title label for a ContainerFrame-style window.
---@param frame table   The container-style frame.
---@param text  string? Title string to display.
NS.CB_ApplyContainerTitleLabel = function(frame, text)
    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetText(text or "")
    lbl:SetPoint("CENTER", frame, "TOP", 0, -(NS.TITLE_H / 2) - CONTAINER_TITLE_OFFSET)
    lbl:SetJustifyH("CENTER")
end

-- Applies the inventory window title bar label.
-- Blizz: plain centred label via CB_ApplyContainerTitleLabel.
-- ElvUI: centred label using GameFontNormalLarge.
---@param frame   table   The inventory frame.
---@param botName string  Bot's display name (label reads "<botName>'s Inventory").
---@param class   string? Bot class (unused for the label; kept for signature parity).
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

-- Assembles the Blizzard ContainerFrame-style backdrop for the inventory frame from
-- sliced pieces of UI-BackpackBackground. Call once when the frame is created.
-- Unlike CB_ApplyFrameSkin, this does NOT register for accent-colour or transparency
-- refresh — the ContainerFrame look is fixed art, not theme-driven. Edges and fill
-- are added in CB_UpdateContainerTiles once the frame is sized by CB_RenderInventory.
--
-- Border measurements derived from ContainerFrame1 (192×240, texture 256×256,
-- scale X=192/256=0.75, scale Y=240/256=0.9375):
--   Left  : 23px screen → ~31px texture  → U  = 31/256  ≈ 0.12109
--   Right : 12px screen →  16px texture  → U  = 240/256 = 0.93750 (start of right border)
--   Top   : 51px screen → ~54px texture  → V  = 54/256  ≈ 0.21094
--   Bottom: 32px screen → ~34px texture  → V  = 222/256 ≈ 0.86719 (start of bottom border)
---@param frame table  The inventory frame to skin (stores _skinParams + tile pools on it).
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
---@param frame table   The inventory frame previously passed to CB_ApplyContainerFrameSkin.
---@param rows  number  Number of item rows to fill.
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
---@param frame     table   The structural frame to skin.
---@param nestLevel number? Nesting depth (0 = outermost window, default 1).
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
-- Promoted to NS so CB_CreateSelectList (Skinning\Widgets.lua) can reach it.
---@param frame table  The list container frame to skin.
NS.CB_ApplyInnerSkin = function(frame)
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

-- Frame factory — creates a child frame nested inside parent, inset by parent's
-- padding (chosen by paddingRole) plus the child's own margin (chosen by marginType).
--
-- paddingRole: "frame" | "panel" | "section"  — selects NS.PADDING[paddingRole]
-- marginType:  "panel" | "section" | nil       — selects NS.MARGIN[marginType];
--              nil means no extra margin (pure padding placement).
-- widthPct / heightPct: fraction of the parent's interior to fill (default 1.0).
--   Full fill (both 1.0): dual anchors so the layout engine handles resizing.
--   Partial fill: TOPLEFT anchor + OnSizeChanged to recompute size dynamically.
-- nestLevel:   passed to CB_ApplyFrameSkin to control fill brightness relative to parent.
--
-- The child's margin values are stamped onto it so CB_AnchorBelow / CB_AnchorAhead
-- can treat it the same as any other widget in a flow chain.
---@param parent      table   Parent frame.
---@param name        string? Optional global frame name.
---@param paddingRole string? Padding role key into NS.PADDING (default "panel").
---@param marginType  string? Margin type key into NS.MARGIN, or nil for none.
---@param widthPct    number? Fraction of parent interior width to fill (default 1).
---@param heightPct   number? Fraction of parent interior height to fill (default 1).
---@param nestLevel   number? Nesting depth for CB_ApplyFrameSkin (default 1).
---@return table              The created Frame with margins stamped.
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

-- Scroll frame factory — creates a scroll frame inset from parent by parent's
-- stamped padding, wires up the scroll child, mouse wheel, and ElvUI scroll bar
-- skinning. The scroll bar is accessed via the standard UIPanelScrollFrameTemplate
-- naming convention: name .. "ScrollBar".
--
-- Both the scroll frame and scroll child have paddingTop/Bottom/Left/Right = 0
-- stamped onto them — they are borderless containers with no visual inset.
-- Content inside the scroll child uses only its own margins; there is no
-- border to escape from.
---@param parent table   Parent frame (reads its paddingTop/Bottom/Left/Right).
---@param name   string  Global name; the scroll bar is looked up as name.."ScrollBar".
---@return table         scrollFrame  The created ScrollFrame.
---@return table         scrollChild  The scroll child Frame.
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
