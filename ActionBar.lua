-- ============================================================
-- ActionBar.lua  —  small standalone action bar
--
-- A tiny, movable bar of bot-command buttons that lives outside the main window.
-- v1: Summon + a Passive toggle, both mirroring the Manage tab's party/raid
-- (broadcast) behavior. Shown/hidden via the minimap right-click or a Settings
-- checkbox (persisted). Edit mode (shift-right-click the minimap, or a Settings
-- checkbox; SESSION-only) disables the buttons and lets the bar be dragged so it
-- snaps/anchors to nearby visible frames.
--
-- Both commands are plain chat commands, so these are ordinary insecure buttons —
-- no SecureActionButton/taint concerns; everything works in combat. The bar is
-- BUILT at PLAYER_LOGIN (not file load) so ElvUI detection + theming have run.
-- ============================================================
local NS = CleanBotNS

local BTN   = 32   -- button size
local PAD   = 6    -- bar inner padding
local GAP   = 4    -- gap between buttons
local SNAP_DIST    = 20  -- px: how close an edge must be to a frame to ACQUIRE a snap
local SNAP_RELEASE = 40  -- px: how far past the snap the bar must move to RELEASE it (hysteresis)
local SNAP_GAP     = 2   -- px gap left when snapped flush to a frame's edge

-- State (assigned by the build; setters guard on `bar` so they're safe pre-build).
local bar, overlay, passiveBtn, snapHighlight

-- Effective on-screen opacity: the product of the frame's own alpha and all its ancestors'. A frame
-- can be IsVisible() (shown, in a shown parent chain) yet faded to nothing — ElvUI does this to its
-- action bars on mouseover-fade — so we treat near-zero effective alpha as "not really shown".
local function CB_EffectiveAlpha(f)
    local a = 1
    while f and f.GetAlpha do
        a = a * (f:GetAlpha() or 1)
        if a <= 0.05 then return a end
        f = f:GetParent()
    end
    return a
end

-- Calls fn(frame, name) for each snap-candidate: a named, visible (shown AND not faded out),
-- reasonably-sized frame. Two sources: direct children of UIParent / ElvUIParent, plus oUF's spawned
-- unit frames (ElvUF_Player, target, party/raid, …). The latter are reparented under their movers —
-- grandchildren of UIParent — so a child scan misses them; oUF tracks them all in ElvUF.objects.
-- Named so the chosen anchor survives a reload (re-found via _G[name]); size-bounded to skip
-- full-screen containers; the bar and its own highlight are excluded.
local function CB_ForEachSnapCandidate(fn)
    local maxW, maxH = UIParent:GetWidth() * 0.9, UIParent:GetHeight() * 0.9
    local seen = {}
    local function tryFrame(f)
        if not f or seen[f] then return end
        local name = f.GetName and f:GetName()
        -- Skip tooltips: they're transient, and GameTooltip is anchored to the bar while its edit
        -- tooltip shows (SetOwner), so snapping TO it would be a dependency cycle.
        if not (name and f ~= bar and f ~= snapHighlight and not name:find("Tooltip")) then return end
        if not (f.IsVisible and f:IsVisible() and f.GetLeft and f:GetLeft()) then return end
        if CB_EffectiveAlpha(f) <= 0.05 then return end
        local w, h = f:GetWidth(), f:GetHeight()
        if not (w and h and w >= 16 and h >= 16 and w <= maxW and h <= maxH) then return end
        seen[f] = true
        fn(f, name)
    end

    local roots = { UIParent }
    if _G.ElvUIParent then roots[#roots + 1] = _G.ElvUIParent end
    for _, root in ipairs(roots) do
        for _, f in ipairs({ root:GetChildren() }) do tryFrame(f) end
    end
    -- oUF unit frames (ElvUI's instance is ElvUF; bare oUF as a fallback). seen[] dedups any that are
    -- also direct children so they aren't considered twice.
    local function addOUF(ouf)
        if type(ouf) == "table" and type(ouf.objects) == "table" then
            for _, f in ipairs(ouf.objects) do tryFrame(f) end
        end
    end
    addOUF(_G.ElvUF)
    addOUF(_G.oUF)
end
NS.actionBarShown    = false   -- persisted in CleanBot_SavedVars.actionBarShown
NS.actionBarEditMode = false   -- session-only

-- Reflects group passive state: the icon is saturated (full color) when any bot is passive,
-- desaturated (grayed) otherwise. Registered as a command refresher so it tracks the Manage
-- tab's checkbox and co? replies.
local function refreshPassiveBtn()
    if not passiveBtn then return end
    passiveBtn.icon:SetDesaturated(not NS.CB_GetGroupPassive())
end

local function applyVisibility()
    if not bar then return end
    if NS.actionBarShown or NS.actionBarEditMode then bar:Show() else bar:Hide() end
end

-- ── Live drag with edge snapping (edit mode) ─────────────────────────────────
-- The bar follows the cursor; when one of its edges comes within SNAP_DIST of a candidate frame's
-- edge, that SINGLE axis locks flush to the frame (the nearest edge wins) while the other axis keeps
-- following the cursor — so the bar slides along the frame's edge. On release it anchors to whatever
-- frame it ended up snapped to (so it follows that frame), else to UIParent. Position is preserved.
local dragGrabX, dragGrabY  -- cursor offset from the bar's bottom-left, captured on mouse-down
local dragSnap              -- current snap { frame, edge, axis, value, dist } (nil = free)
local dragging              -- true while a drag is in progress (guards double mouse-up)

-- Each snap edge-key maps to the side of the candidate frame it touches — used to draw the blue edge
-- strip. Both the flush ("left↔left") and the abutting ("bar left ↔ frame right") snaps share a side.
local EDGE_SIDE = {
    xLeft  = "LEFT",   xAbutLeft  = "LEFT",
    xRight = "RIGHT",  xAbutRight = "RIGHT",
    yBottom = "BOTTOM", yAbutBelow = "BOTTOM",
    yTop    = "TOP",    yAbutAbove = "TOP",
}

-- Best single-axis snap for a proposed bottom-left, within `maxDist`: { axis, edge, value, dist, frame },
-- or nil. When `onlyFrame`/`onlyEdge` are set, only that exact candidate edge is considered (sticky
-- release check) so a held snap stays on the same edge instead of jumping sides near a corner.
local function CB_BestSnap(newLeft, newBottom, maxDist, onlyFrame, onlyEdge)
    local w, h = bar:GetWidth(), bar:GetHeight()
    local bl, br, bb, bt = newLeft, newLeft + w, newBottom, newBottom + h
    local best
    CB_ForEachSnapCandidate(function(f, name)
        if onlyFrame and name ~= onlyFrame then return end
        local cl, cr, ct, cb = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
        -- X-axis (vertical-edge) snaps require the bar to be vertically near the frame; Y the reverse.
        local vNear = bb <= ct + maxDist and bt >= cb - maxDist
        local hNear = bl <= cr + maxDist and br >= cl - maxDist
        -- True extent overlap on the PERPENDICULAR axis marks the edge the bar is sliding along: an
        -- x-edge whose vertical ranges overlap, or a y-edge whose horizontal ranges overlap. Preferred
        -- over a merely-nearer edge so dragging in from the side of a short, wide frame catches its
        -- left/right edge instead of its nearby top/bottom.
        local vOverlap = bb < ct and bt > cb
        local hOverlap = bl < cr and br > cl
        local function consider(axis, edge, value, dist, near, overlap)
            if onlyEdge and edge ~= onlyEdge then return end
            if not (near and dist <= maxDist) then return end
            if not best
               or (overlap and not best.overlap)
               or (overlap == best.overlap and dist < best.dist) then
                best = { axis = axis, edge = edge, value = value, dist = dist, frame = name, overlap = overlap }
            end
        end
        consider("x", "xLeft",      cl,                math.abs(bl - cl), vNear, vOverlap)  -- left ↔ left
        consider("x", "xRight",     cr - w,            math.abs(br - cr), vNear, vOverlap)  -- right ↔ right
        consider("x", "xAbutRight", cr + SNAP_GAP,     math.abs(bl - cr), vNear, vOverlap)  -- abut right of frame
        consider("x", "xAbutLeft",  cl - w - SNAP_GAP, math.abs(br - cl), vNear, vOverlap)  -- abut left of frame
        consider("y", "yBottom",    cb,                math.abs(bb - cb), hNear, hOverlap)  -- bottom ↔ bottom
        consider("y", "yTop",       ct - h,            math.abs(bt - ct), hNear, hOverlap)  -- top ↔ top
        consider("y", "yAbutAbove", ct + SNAP_GAP,     math.abs(bb - ct), hNear, hOverlap)  -- abut above frame
        consider("y", "yAbutBelow", cb - h - SNAP_GAP, math.abs(bt - cb), hNear, hOverlap)  -- abut below frame
    end)
    return best
end

-- Highlights the frame the bar is snapped to: a green wash over the whole frame, a brighter blue strip
-- on the exact edge being snapped to, and the frame's name centered on it. Passing nil hides it all.
local EDGE_THICK = 3
local function CB_UpdateSnapHighlight(snap)
    if not snapHighlight then return end
    local f = snap and _G[snap.frame]
    if not (f and f.GetLeft and f:GetLeft()) then snapHighlight:Hide() return end
    snapHighlight:ClearAllPoints()
    snapHighlight:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    snapHighlight:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    snapHighlight.label:SetText(snap.frame)

    local edge, side = snapHighlight.edge, EDGE_SIDE[snap.edge]
    edge:ClearAllPoints()
    if side == "LEFT" then
        edge:SetPoint("TOPLEFT"); edge:SetPoint("BOTTOMLEFT"); edge:SetWidth(EDGE_THICK)
    elseif side == "RIGHT" then
        edge:SetPoint("TOPRIGHT"); edge:SetPoint("BOTTOMRIGHT"); edge:SetWidth(EDGE_THICK)
    elseif side == "TOP" then
        edge:SetPoint("TOPLEFT"); edge:SetPoint("TOPRIGHT"); edge:SetHeight(EDGE_THICK)
    else -- BOTTOM
        edge:SetPoint("BOTTOMLEFT"); edge:SetPoint("BOTTOMRIGHT"); edge:SetHeight(EDGE_THICK)
    end
    snapHighlight:Show()
end

-- Per-frame drag tick: follow the cursor, then lock the one nearest snapping edge.
-- Hysteresis: while snapped, keep the SAME frame AND edge until the bar drifts past SNAP_RELEASE from
-- it; only then is a fresh snap acquired within the tighter SNAP_DIST. This stops the bar from
-- flickering between frames (or between the two edges of a corner) that sit close together.
local function CB_DragUpdate()
    local scale = bar:GetEffectiveScale()
    if not scale or scale == 0 then return end
    local cx, cy = GetCursorPosition()
    local newLeft   = cx / scale - dragGrabX
    local newBottom = cy / scale - dragGrabY
    local snap
    if dragSnap then
        snap = CB_BestSnap(newLeft, newBottom, SNAP_RELEASE, dragSnap.frame, dragSnap.edge)
    end
    if not snap then
        snap = CB_BestSnap(newLeft, newBottom, SNAP_DIST)
    end
    dragSnap = snap
    if snap then
        if snap.axis == "x" then newLeft = snap.value else newBottom = snap.value end
    end
    bar:ClearAllPoints()
    bar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", newLeft, newBottom)
    CB_UpdateSnapHighlight(snap)
end

-- Mouse-up: anchor to the snapped frame (so the bar follows it) or UIParent, keeping the on-screen
-- position, then persist. (Called by the shared capture frame.)
local function CB_FinishDrag()
    if not dragging then return end
    dragging = false
    NS.CB_EndCapture()
    CB_UpdateSnapHighlight(nil)
    local bl, bb = bar:GetLeft(), bar:GetBottom()
    local relTo, x, y = "UIParent", bl, bb
    local snapFrame = dragSnap and dragSnap.frame
    local f = snapFrame and _G[snapFrame]
    if f and f:GetLeft() then
        relTo, x, y = snapFrame, bl - f:GetLeft(), bb - f:GetBottom()
    end
    bar:ClearAllPoints()
    bar:SetPoint("BOTTOMLEFT", _G[relTo] or UIParent, "BOTTOMLEFT", x, y)
    if CleanBot_SavedVars then
        CleanBot_SavedVars.actionBarAnchor = { relTo = relTo, point = "BOTTOMLEFT", relPoint = "BOTTOMLEFT", x = x, y = y }
    end
end

-- Begins dragging immediately on mouse-down (we're in edit mode, so that's fine), via the shared
-- capture frame which tracks the cursor + mouse-up anywhere on screen.
local function CB_BeginDrag()
    local scale = bar:GetEffectiveScale()
    if not scale or scale == 0 then return end
    GameTooltip:Hide()   -- drop the edit-tooltip's SetOwner anchor so re-anchoring can't cycle
    local cx, cy = GetCursorPosition()
    dragGrabX = cx / scale - bar:GetLeft()
    dragGrabY = cy / scale - bar:GetBottom()
    dragSnap = nil
    dragging = true
    -- The capture frame catches the mouse-up when the cursor has moved off the overlay; the
    -- overlay's own OnMouseUp catches it when released in place (WoW delivers the button-up to
    -- the frame that owned the button-down). CB_FinishDrag is guarded so only the first wins.
    NS.CB_BeginCapture(CB_DragUpdate, CB_FinishDrag)
end

-- ── State setters (shared by the minimap and Settings, like the debug setters) ──
--- Shows/hides the action bar and persists the choice.
---@param on boolean
NS.CB_SetActionBarShown = function(on)
    NS.actionBarShown = on and true or false
    if CleanBot_SavedVars then CleanBot_SavedVars.actionBarShown = NS.actionBarShown end
    applyVisibility()
    if NS.CB_RefreshActionBarChecks then NS.CB_RefreshActionBarChecks() end
end
NS.CB_ToggleActionBar = function() NS.CB_SetActionBarShown(not NS.actionBarShown) end

--- Toggles edit mode (session only): edit forces the bar visible, swaps the overlay on (which
--- covers + disables the buttons), and is the drag handle; off restores the saved shown state.
---@param on boolean
NS.CB_SetActionBarEditMode = function(on)
    NS.actionBarEditMode = on and true or false
    if overlay then
        if NS.actionBarEditMode then overlay:Show() else overlay:Hide() end
    end
    applyVisibility()
    if NS.CB_RefreshActionBarChecks then NS.CB_RefreshActionBarChecks() end
end
NS.CB_ToggleActionBarEditMode = function() NS.CB_SetActionBarEditMode(not NS.actionBarEditMode) end

-- ── Build (once, at PLAYER_LOGIN) ────────────────────────────────────────────
local function CB_BuildActionBar()
    bar = CreateFrame("Frame", "CleanBotActionBarFrame", UIParent)
    bar:SetFrameStrata("MEDIUM")
    bar:SetSize(PAD + BTN + GAP + BTN + PAD, PAD + BTN + PAD)
    bar:SetClampedToScreen(true)
    bar:Hide()
    NS.CB_ApplyFrameSkin(bar, 2)

    -- Summon: bring the party/raid's bots to the player.
    local summonBtn = NS.CB_CreateIconButton(bar, "CleanBotActionSummonBtn",
        "Interface\\Icons\\Spell_Arcane_TeleportStormwind", BTN,
        function() NS.CB_SendGroupCommand("summon") end)
    summonBtn:SetPoint("TOPLEFT", bar, "TOPLEFT", PAD, -PAD)
    NS.CB_SetTooltip(summonBtn, "Summon", "Summon your party/raid bots to you.")

    -- Passive: toggle every bot's passive state (OR-read + blanket flip — same as the
    -- Manage tab's Passive checkbox). Lit when any bot is passive.
    passiveBtn = NS.CB_CreateIconButton(bar, "CleanBotActionPassiveBtn",
        "Interface\\Icons\\Spell_Nature_Sleep", BTN,
        function()
            NS.CB_SetGroupPassive(not NS.CB_GetGroupPassive())
            NS.CB_RefreshCommands()
        end)
    passiveBtn:SetPoint("TOPLEFT", bar, "TOPLEFT", PAD + BTN + GAP, -PAD)
    NS.CB_SetTooltip(passiveBtn, "Passive", "Toggle all bots passive — stand down and do nothing in combat.")
    NS.commandRefreshers[#NS.commandRefreshers + 1] = refreshPassiveBtn

    -- Edit overlay: covers the bar above the buttons, mouse-enabled only in edit mode, so it
    -- both blocks button clicks ("disables normal interaction") and is the drag handle.
    overlay = CreateFrame("Frame", nil, bar)
    overlay:SetAllPoints(bar)
    overlay:SetFrameLevel(bar:GetFrameLevel() + 10)
    overlay:EnableMouse(true)
    overlay:Hide()

    local tint = overlay:CreateTexture(nil, "OVERLAY")
    tint:SetAllPoints(overlay)
    tint:SetTexture(0.1, 0.6, 1.0, 0.25)   -- translucent blue "edit" wash

    local editLabel = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    editLabel:SetPoint("CENTER", overlay, "CENTER", 0, 0)
    editLabel:SetText("CleanBot")

    NS.CB_SetTooltip(overlay, "Action Bar — Edit Mode",
        "Click and drag to move. Drag near a frame (minimap, the CleanBot window, a unit frame, …) to snap to its edge.", "ANCHOR_TOP")

    -- Drag starts on mouse-down (immediate) — fine since this only fires in edit mode.
    overlay:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then CB_BeginDrag() end
    end)
    overlay:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then CB_FinishDrag() end
    end)

    -- Snap highlight: a green wash laid over whatever frame the bar is currently snapped to during a
    -- drag, so the anchor target is obvious. High strata so it shows above the candidate frame.
    snapHighlight = CreateFrame("Frame", "CleanBotSnapHighlightFrame", UIParent)
    snapHighlight:SetFrameStrata("FULLSCREEN_DIALOG")
    snapHighlight:Hide()
    local hlTint = snapHighlight:CreateTexture(nil, "ARTWORK")
    hlTint:SetAllPoints(snapHighlight)
    hlTint:SetTexture(0.1, 1.0, 0.1, 0.25)   -- translucent green "snapped here" wash
    local hlEdge = snapHighlight:CreateTexture(nil, "OVERLAY")
    hlEdge:SetTexture(0.2, 0.6, 1.0, 0.9)    -- bright blue strip on the snapped edge
    snapHighlight.edge = hlEdge
    local hlLabel = snapHighlight:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hlLabel:SetPoint("CENTER", snapHighlight, "CENTER", 0, 0)
    snapHighlight.label = hlLabel

    -- ── Restore position + shown state (edit mode always starts off). ──
    local a = CleanBot_SavedVars and CleanBot_SavedVars.actionBarAnchor
    bar:ClearAllPoints()
    if type(a) == "table" and a.point then
        bar:SetPoint(a.point, _G[a.relTo] or UIParent, a.relPoint, a.x or 0, a.y or 0)
    else
        bar:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -220)  -- sensible default
    end
    NS.actionBarShown = CleanBot_SavedVars and CleanBot_SavedVars.actionBarShown == true
    applyVisibility()
    refreshPassiveBtn()
    if NS.CB_RefreshActionBarChecks then NS.CB_RefreshActionBarChecks() end
end

-- Build on PLAYER_ENTERING_WORLD (once): by then ElvUI's frames + skin module are fully initialized
-- and saved anchor targets (e.g. ElvUF_Player) exist — so the icons crop and the bar restores onto
-- its anchored frame correctly. PLAYER_LOGIN is too early for both (other addons' frames may not be
-- up yet). CleanBot's own frames (CB_BuildFrames) are built by login, so they're ready here too.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    CB_BuildActionBar()
end)
