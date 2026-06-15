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
local bar, overlay, passiveBtn, snapHighlight, configFrame
local barButtons = {}   -- the bar's buttons in flow order; laid out by CB_LayoutBar per grow direction
local followBtn, runawayBtn, stayBtn   -- movement flyout buttons (saturation tracks the group's value)
local pendingRunawayRevert             -- key → { name, prev } captured on Runaway; restored on combat end

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
        if not (name and f ~= bar and f ~= snapHighlight and f ~= configFrame and not name:find("Tooltip")) then return end
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
NS.actionBarSnap     = true    -- persisted in CleanBot_SavedVars.actionBarSnap; gates edge snapping

-- Reflects group passive state: the icon is saturated (full color) when any bot is passive,
-- desaturated (grayed) otherwise. Registered as a command refresher so it tracks the Manage
-- tab's checkbox and co? replies.
local function refreshPassiveBtn()
    if not passiveBtn then return end
    passiveBtn.icon:SetDesaturated(not NS.CB_GetGroupPassive())
end

-- ── Movement flyout (Follow / Runaway / Stay) ────────────────────────────────
-- The affected/displayed movement context follows the PLAYER's combat state: in combat → entry.combat,
-- else entry.nonCombat. A button is lit when its movement is the active value for that context (the
-- "any member" rule, like Passive). Runaway sets the "runaway" strategy in the COMBAT context, with
-- the previous combat movement restored automatically when combat ends.
local function playerCombatSection()
    return UnitAffectingCombat("player") and "combat" or "nonCombat"
end

local function refreshMoveBtns()
    if not followBtn then return end
    local section = playerCombatSection()
    followBtn.icon:SetDesaturated(not NS.CB_GroupMovementActive(section, "mFollow"))
    runawayBtn.icon:SetDesaturated(not NS.CB_GroupMovementActive(section, "mRunaway"))
    stayBtn.icon:SetDesaturated(not NS.CB_GroupMovementActive(section, "mStay"))
end

-- An explicit Follow/Stay choice supersedes a pending Runaway revert.
local function cancelRunawayRevert() pendingRunawayRevert = nil end

-- Follow / Stay: set the group's movement for the player-combat-state context.
local function setMovement(field)
    cancelRunawayRevert()
    NS.CB_SetGroupMovement(playerCombatSection(), field)
    NS.CB_RefreshCommands()
end

-- Runaway: set the group's COMBAT movement to Run Away, remembering each member's previous combat
-- movement (only on the first press, so repeats don't overwrite the original) for restore on combat end.
local function runawayMovement()
    pendingRunawayRevert = pendingRunawayRevert or {}
    if NS.CB_ForEachGroupMember then
        NS.CB_ForEachGroupMember(function(_, name)
            local key = name and strlower(name)
            local e = key and CleanBot_PartyBots[key]
            if e and pendingRunawayRevert[key] == nil then
                local cur = false  -- false = "Free Roam" (no movement strategy set)
                if e.combat then
                    for _, m in ipairs(NS.MOVEMENT_STRATEGIES or {}) do
                        if e.combat[m.field] then cur = m.field; break end
                    end
                end
                pendingRunawayRevert[key] = { name = name, prev = cur }
            end
        end)
    end
    NS.CB_SetGroupMovement("combat", "mRunaway")
    NS.CB_RefreshCommands()
end

-- On combat end: restore each remembered bot's previous combat movement (per-member — they may differ).
local function revertRunaway()
    if not pendingRunawayRevert then return end
    for key, info in pairs(pendingRunawayRevert) do
        local e = CleanBot_PartyBots[key]
        if e then
            local field = info.prev or nil   -- false → nil (Free Roam, clears all five)
            e.combat = e.combat or {}
            for _, m in ipairs(NS.MOVEMENT_STRATEGIES or {}) do e.combat[m.field] = (m.field == field) end
            NS.CB_SendBotCommand(info.name, "co " .. NS.CB_MovementToggleString(field))
        end
    end
    pendingRunawayRevert = nil
    NS.CB_RefreshCommands()
end


local function applyVisibility()
    if not bar then return end
    if NS.actionBarShown or NS.actionBarEditMode then bar:Show() else bar:Hide() end
end

-- ── Anchor model (position + grow-from corner) ───────────────────────────────
-- The bar is anchored BY one of its four corners (`growFrom`) to the SAME-named corner of `relTo`,
-- offset by (x, y). Pinning a corner means that corner stays put if the bar's size changes (e.g. more
-- buttons) — the bar grows away from it. x/y are screen-axis offsets: +x right, +y up, at any corner.
local CORNERS = { "BOTTOMLEFT", "BOTTOMRIGHT", "TOPLEFT", "TOPRIGHT" }
local CORNER_LABEL = {
    BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
    TOPLEFT = "Top Left", TOPRIGHT = "Top Right",
}
-- Grow direction: the axis/way the bar's buttons flow out from the anchored corner.
local GROW_DIRS = { "UP", "DOWN", "LEFT", "RIGHT" }
local DIR_LABEL = { UP = "Up", DOWN = "Down", LEFT = "Left", RIGHT = "Right" }

-- Default: top-right of the screen (20px in, 220px down), pinned by its top-right corner; buttons flow
-- to the right.
local anchor = { relTo = "UIParent", growFrom = "TOPRIGHT", x = -20, y = -220, growDir = "RIGHT" }

-- Overlap area of two screen rects (0 if disjoint). Shared by the flyout + config placement logic.
local function CB_RectOverlap(al, ab, ar, at, bl, bb, br, bt)
    local ix = math.max(0, math.min(ar, br) - math.max(al, bl))
    local iy = math.max(0, math.min(at, bt) - math.max(ab, bb))
    return ix * iy
end

-- Config-frame helpers (defined with the build, used during drag). Forward-declared.
local CB_PositionConfig, CB_RefreshConfig

-- Screen coords of `corner` ("TOPLEFT"…) of a frame: x picks the right edge for *RIGHT, else left; y
-- picks the top edge for TOP*, else bottom.
local function CB_FrameCorner(f, corner)
    local l, b, w, h = f:GetLeft(), f:GetBottom(), f:GetWidth(), f:GetHeight()
    if not (l and b and w and h) then return nil end
    return l + (corner:find("RIGHT") and w or 0), b + (corner:find("TOP") and h or 0)
end

-- Re-pins the bar from the current `anchor`. Safe before build (guards on bar).
local function CB_ApplyAnchor()
    if not bar then return end
    bar:ClearAllPoints()
    bar:SetPoint(anchor.growFrom, _G[anchor.relTo] or UIParent, anchor.growFrom, anchor.x, anchor.y)
end

local function CB_SaveAnchor()
    if CleanBot_SavedVars then
        CleanBot_SavedVars.actionBarAnchor = {
            relTo = anchor.relTo, growFrom = anchor.growFrom,
            x = anchor.x, y = anchor.y, growDir = anchor.growDir,
        }
    end
end

-- Lays out the bar's buttons (in flow order) for the current grow direction and sizes the bar to fit.
-- Horizontal directions make a wide bar; vertical ones a tall bar. The anchored corner stays pinned
-- across the resize because the bar is anchored BY that corner (see CB_ApplyAnchor).
local function CB_LayoutBar()
    if not bar or #barButtons == 0 then return end
    local dir   = anchor.growDir or "RIGHT"
    local n     = #barButtons
    local horiz = (dir == "RIGHT" or dir == "LEFT")
    local along = n * BTN + (n - 1) * GAP
    bar:SetSize(
        horiz and (PAD + along + PAD) or (PAD + BTN + PAD),
        horiz and (PAD + BTN + PAD)   or (PAD + along + PAD))
    for i, b in ipairs(barButtons) do
        local off = (i - 1) * (BTN + GAP)
        b:ClearAllPoints()
        if dir == "RIGHT" then
            b:SetPoint("TOPLEFT",     bar, "TOPLEFT",      PAD + off, -PAD)
        elseif dir == "LEFT" then
            b:SetPoint("TOPRIGHT",    bar, "TOPRIGHT",   -(PAD + off), -PAD)
        elseif dir == "DOWN" then
            b:SetPoint("TOPLEFT",     bar, "TOPLEFT",      PAD, -(PAD + off))
        else -- UP
            b:SetPoint("BOTTOMLEFT",  bar, "BOTTOMLEFT",   PAD,   PAD + off)
        end
    end
end

-- Recomputes anchor.x/y so the bar keeps its CURRENT screen position under the current relTo+growFrom.
-- Used after a drag (relTo just changed) and after a grow-from change (so the bar doesn't jump).
local function CB_RecomputeOffsets()
    local bx, by = CB_FrameCorner(bar, anchor.growFrom)
    local fx, fy = CB_FrameCorner(_G[anchor.relTo] or UIParent, anchor.growFrom)
    if bx and fx then anchor.x, anchor.y = bx - fx, by - fy end
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
    if NS.actionBarSnap then
        if dragSnap then
            snap = CB_BestSnap(newLeft, newBottom, SNAP_RELEASE, dragSnap.frame, dragSnap.edge)
        end
        if not snap then
            snap = CB_BestSnap(newLeft, newBottom, SNAP_DIST)
        end
    end
    dragSnap = snap
    if snap then
        if snap.axis == "x" then newLeft = snap.value else newBottom = snap.value end
    end
    bar:ClearAllPoints()
    bar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", newLeft, newBottom)
    CB_UpdateSnapHighlight(snap)
    -- Keep the anchor state (and the config readout) live mid-drag without persisting: provisional
    -- relTo is whatever we're snapped to, else UIParent. CB_FinishDrag re-derives + saves on release.
    anchor.relTo = (snap and snap.frame) or "UIParent"
    CB_RecomputeOffsets()
    if CB_PositionConfig then CB_PositionConfig() end
    if CB_RefreshConfig then CB_RefreshConfig() end
end

-- Mouse-up: anchor to the snapped frame (so the bar follows it) or UIParent, keeping the on-screen
-- position, then persist. (Called by the shared capture frame.)
local function CB_FinishDrag()
    if not dragging then return end
    dragging = false
    NS.CB_EndCapture()
    CB_UpdateSnapHighlight(nil)
    local snapFrame = dragSnap and dragSnap.frame
    local f = snapFrame and _G[snapFrame]
    anchor.relTo = (f and f:GetLeft()) and snapFrame or "UIParent"
    CB_RecomputeOffsets()   -- offsets at growFrom for the final on-screen position
    CB_ApplyAnchor()
    CB_SaveAnchor()
    if CB_PositionConfig then CB_PositionConfig() end
    if CB_RefreshConfig then CB_RefreshConfig() end
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
    if configFrame then
        if NS.actionBarEditMode then
            CB_PositionConfig()
            CB_RefreshConfig()
            configFrame:Show()
        else
            configFrame:Hide()
        end
    end
    if NS.CB_RefreshActionBarChecks then NS.CB_RefreshActionBarChecks() end
end
NS.CB_ToggleActionBarEditMode = function() NS.CB_SetActionBarEditMode(not NS.actionBarEditMode) end

-- ── Flyout button (expands to reveal more buttons) ───────────────────────────
-- Hint appended to every flyout button's tooltip (after a blank line) so the right-click behavior is
-- discoverable. Kept as a constant so it's edited in one place.
local FLYOUT_HINT = "|cFF80CCFFRight-Click to toggle this flyout|r"   -- light blue

-- A bar button whose left-click runs its own action and which reveals a stack of extra buttons —
-- on hover (auto-closes when the pointer leaves) or pinned open by right-click. The stack expands
-- AWAY from the frame the bar is anchored to (so it never grows back over it); when the bar is free
-- (anchored to UIParent) it defaults downward. Add children with btn:AddFlyout(icon, onClick, …).
local function CB_CreateFlyoutButton(parent, name, iconTex, onClick, title, desc)
    local btn = NS.CB_CreateIconButton(parent, name, iconTex, BTN, nil)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    if title then
        NS.CB_SetTooltip(btn, title, desc and (desc .. "\n\n" .. FLYOUT_HINT) or FLYOUT_HINT)
    end

    -- Child container. Parented to the button so it inherits MEDIUM strata (children stay interactive);
    -- raised a few levels so it draws above the bar. Anchored contiguous with the button (no gap
    -- between their hit rects) so moving the pointer into it never crosses a dead zone.
    local flyout = CreateFrame("Frame", name .. "Flyout", btn)
    flyout:SetFrameLevel(btn:GetFrameLevel() + 5)
    flyout:Hide()
    btn.flyout, btn.children = flyout, {}

    -- Screen rect the flyout would occupy growing `dir` from the button, for `n` children.
    local function flyoutRect(dir, n)
        local bl, bb = btn:GetLeft(), btn:GetBottom()
        if not bl then return end
        local bw, bh, len = btn:GetWidth(), btn:GetHeight(), n * (BTN + GAP)
        if dir == "DOWN"  then return bl, bb - len, bl + bw, bb end
        if dir == "UP"    then return bl, bb + bh, bl + bw, bb + bh + len end
        if dir == "RIGHT" then return bl + bw, bb, bl + bw + len, bb + bh end
        return bl - len, bb, bl, bb + bh   -- LEFT
    end

    -- Direction the stack grows: PERPENDICULAR to the bar's flow (so it never grows along the bar over
    -- the other buttons), then the side of that axis that best avoids overlapping the bar — most
    -- important — and the anchored frame, while staying on-screen. Ties keep the first option.
    local function flyoutDir()
        local n    = #btn.children
        local opts = (anchor.growDir == "UP" or anchor.growDir == "DOWN")
                     and { "RIGHT", "LEFT" } or { "DOWN", "UP" }
        local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
        local rf = anchor.relTo ~= "UIParent" and _G[anchor.relTo]
        local rl, rb, rr, rt
        if rf and rf.GetLeft and rf:GetLeft() then rl, rb, rr, rt = rf:GetLeft(), rf:GetBottom(), rf:GetRight(), rf:GetTop() end
        local barL, barB, barR, barT
        if bar and bar:GetLeft() then barL, barB, barR, barT = bar:GetLeft(), bar:GetBottom(), bar:GetRight(), bar:GetTop() end

        local best, bestScore
        for _, dir in ipairs(opts) do
            local l, b, r, t = flyoutRect(dir, n)
            if l then
                local score = -1000 * (math.max(0, -l) + math.max(0, r - sw) + math.max(0, -b) + math.max(0, t - sh))
                if barL then score = score - 100 * CB_RectOverlap(l, b, r, t, barL, barB, barR, barT) end
                if rl   then score = score -       CB_RectOverlap(l, b, r, t, rl, rb, rr, rt) end
                if not bestScore or score > bestScore then bestScore, best = score, dir end
            end
        end
        return best or opts[1]
    end

    -- (Re)anchors the flyout and its children for the given direction and sizes it to fit. The near
    -- edge is flush with the button; children are inset by GAP, so the flyout's leading strip bridges
    -- the visible gap for hover detection.
    local function layout(dir)
        local n = #btn.children
        if n == 0 then return end
        local vertical = (dir == "UP" or dir == "DOWN")
        flyout:ClearAllPoints()
        flyout:SetSize(vertical and BTN or n * (BTN + GAP), vertical and n * (BTN + GAP) or BTN)
        local fp = (dir == "DOWN" and "TOP") or (dir == "UP" and "BOTTOM")
                or (dir == "RIGHT" and "LEFT") or "RIGHT"
        local bp = (dir == "DOWN" and "BOTTOM") or (dir == "UP" and "TOP")
                or (dir == "RIGHT" and "RIGHT") or "LEFT"
        flyout:SetPoint(fp, btn, bp, 0, 0)
        for i, child in ipairs(btn.children) do
            child:ClearAllPoints()
            local ref = (i == 1) and flyout or btn.children[i - 1]
            if dir == "DOWN" then
                child:SetPoint("TOP", ref, i == 1 and "TOP" or "BOTTOM", 0, -GAP)
            elseif dir == "UP" then
                child:SetPoint("BOTTOM", ref, i == 1 and "BOTTOM" or "TOP", 0, GAP)
            elseif dir == "RIGHT" then
                child:SetPoint("LEFT", ref, i == 1 and "LEFT" or "RIGHT", GAP, 0)
            else -- LEFT
                child:SetPoint("RIGHT", ref, i == 1 and "RIGHT" or "LEFT", -GAP, 0)
            end
        end
    end

    local function open()
        layout(flyoutDir())
        flyout:Show()
    end

    -- Hover opens; close when the pointer is over neither the button nor the open flyout (and it isn't
    -- pinned). Polled via OnUpdate (runs only while shown) so no OnLeave can be missed mid-traverse.
    local function pointerInside() return btn:IsMouseOver() or flyout:IsMouseOver() end
    flyout:SetScript("OnUpdate", function(self, elapsed)
        self._t = (self._t or 0) + elapsed
        if self._t < 0.1 then return end
        self._t = 0
        if not self.pinned and not pointerInside() then self:Hide() end
    end)
    btn:HookScript("OnEnter", open)

    btn:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then       -- toggle pinned-open (survives the pointer leaving)
            flyout.pinned = not flyout.pinned
            if flyout.pinned then open() else flyout:Hide() end
        elseif onClick then
            onClick()
        end
    end)

    -- Adds a child button; positioning happens in layout() at open time (direction can change). Selecting
    -- a child also closes the flyout unless it's pinned.
    function btn:AddFlyout(childIcon, childOnClick, childTitle, childDesc)
        local idx   = #self.children + 1
        local child = NS.CB_CreateIconButton(flyout, name .. "Fly" .. idx, childIcon, BTN, function()
            if childOnClick then childOnClick() end
            if not flyout.pinned then flyout:Hide() end
        end)
        if childTitle then NS.CB_SetTooltip(child, childTitle, childDesc) end
        self.children[idx] = child
        return child
    end

    return btn
end

-- ── Config frame (edit mode) ─────────────────────────────────────────────────
-- A small panel shown beside the bar in edit mode: an "Anchor From" corner dropdown, a "Grow
-- Direction" dropdown, x/y position editboxes, four 1px nudge buttons, a snapping toggle and Done.
-- Excluded from snap candidates so the bar can't anchor to it.
local function CB_BuildConfig()
    configFrame = CreateFrame("Frame", "CleanBotActionBarConfigFrame", UIParent)
    configFrame:SetFrameStrata("DIALOG")
    configFrame:SetSize(180, 250)
    configFrame:EnableMouse(true)   -- swallow clicks so they don't fall through to the world
    NS.CB_ApplyFrameSkin(configFrame, 2)
    configFrame:Hide()
    local PADC = 10
    local CONTENT_W = 180 - 2 * PADC   -- inner width the full-span rows fill

    -- Re-pins the bar from the live anchor, persists, and re-flows the config + readout. Shared by
    -- the dropdowns, editboxes, and nudge buttons.
    local function applyAndSave()
        CB_ApplyAnchor()
        CB_SaveAnchor()
        CB_PositionConfig()
        CB_RefreshConfig()
    end

    -- "Anchor From" label + corner dropdown (the pinned corner; left-aligned at PADC).
    local anchorLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    anchorLabel:SetText("Anchor From")
    anchorLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", PADC, -PADC)

    local growDD = NS.CB_CreateDropdown(configFrame, "CleanBotActionBarGrowDD", 150)
    -- The template carries a ~16px left inset; pull left so the visible box lines up with PADC.
    growDD:SetPoint("TOPLEFT", anchorLabel, "BOTTOMLEFT", -16, -2)
    UIDropDownMenu_Initialize(growDD, function()
        for _, corner in ipairs(CORNERS) do
            local info        = UIDropDownMenu_CreateInfo()
            info.text         = CORNER_LABEL[corner]
            info.value        = corner
            info.notCheckable = 1
            info.func         = function()
                anchor.growFrom = corner
                CB_RecomputeOffsets()   -- keep the bar where it is; only the pinned corner changes
                applyAndSave()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    configFrame.growDD = growDD

    -- "Grow Direction" label + dropdown (the way the bar's buttons flow).
    local dirLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dirLabel:SetText("Grow Direction")
    dirLabel:SetPoint("TOPLEFT", anchorLabel, "BOTTOMLEFT", 0, -40)

    local dirDD = NS.CB_CreateDropdown(configFrame, "CleanBotActionBarDirDD", 150)
    dirDD:SetPoint("TOPLEFT", dirLabel, "BOTTOMLEFT", -16, -2)
    UIDropDownMenu_Initialize(dirDD, function()
        for _, d in ipairs(GROW_DIRS) do
            local info        = UIDropDownMenu_CreateInfo()
            info.text         = DIR_LABEL[d]
            info.value        = d
            info.notCheckable = 1
            info.func         = function()
                anchor.growDir = d
                CB_LayoutBar()          -- reflow the buttons + resize; pinned corner stays put
                applyAndSave()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    configFrame.dirDD = dirDD

    -- x / y position editboxes in a full-width holder; each box stretches to fill its half of the row.
    local xyRow = CreateFrame("Frame", nil, configFrame)
    xyRow:SetSize(CONTENT_W, 18)
    xyRow:SetPoint("TOPLEFT", dirLabel, "BOTTOMLEFT", 0, -40)

    local xLabel = xyRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    xLabel:SetText("x:")
    xLabel:SetPoint("LEFT", xyRow, "LEFT", 0, 0)

    local yLabel = xyRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    yLabel:SetText("y:")
    yLabel:SetPoint("LEFT", xyRow, "CENTER", 4, 0)

    -- Both boxes anchored on both sides so they grow: xBox fills xLabel→midpoint, yBox fills yLabel→right.
    local xBox = NS.CB_CreateEditBox(xyRow, "CleanBotActionBarXBox")
    xBox:SetHeight(18)
    xBox:SetAutoFocus(false)
    xBox:SetPoint("LEFT",  xLabel, "RIGHT", 4, 0)
    xBox:SetPoint("RIGHT", yLabel, "LEFT", -8, 0)
    configFrame.xBox = xBox

    local yBox = NS.CB_CreateEditBox(xyRow, "CleanBotActionBarYBox")
    yBox:SetHeight(18)
    yBox:SetAutoFocus(false)
    yBox:SetPoint("LEFT",  yLabel, "RIGHT", 4, 0)
    yBox:SetPoint("RIGHT", xyRow, "RIGHT", 0, 0)
    configFrame.yBox = yBox

    -- Commit a typed value (Enter or focus loss): valid number → store + re-pin; invalid → revert.
    local function commit(box, axis)
        local v = tonumber(box:GetText())
        if v then anchor[axis] = math.floor(v + 0.5); applyAndSave()
        else CB_RefreshConfig() end
        box:ClearFocus()
    end
    xBox:SetScript("OnEnterPressed",   function(self) commit(self, "x") end)
    yBox:SetScript("OnEnterPressed",   function(self) commit(self, "y") end)
    xBox:SetScript("OnEditFocusLost",  function(self) commit(self, "x") end)
    yBox:SetScript("OnEditFocusLost",  function(self) commit(self, "y") end)
    xBox:SetScript("OnEscapePressed",  function(self) CB_RefreshConfig(); self:ClearFocus() end)
    yBox:SetScript("OnEscapePressed",  function(self) CB_RefreshConfig(); self:ClearFocus() end)

    -- Four 1px nudge buttons: ⟨ ^ v ⟩ → left, up, down, right (screen-axis, regardless of growFrom).
    local function nudge(dx, dy)
        anchor.x = anchor.x + dx
        anchor.y = anchor.y + dy
        applyAndSave()
    end
    local BW, BH = 28, 22
    local dirs = {
        { "<", -1,  0 }, { "^",  0,  1 }, { "v",  0, -1 }, { ">",  1,  0 },
    }
    -- Spread the fixed-width buttons evenly across the full content width (gap fills the slack).
    local BGAP = (CONTENT_W - #dirs * BW) / (#dirs - 1)
    local btnRow = CreateFrame("Frame", nil, configFrame)
    btnRow:SetSize(CONTENT_W, BH)
    btnRow:SetPoint("TOPLEFT", xyRow, "BOTTOMLEFT", 0, -8)
    local prev
    for i, d in ipairs(dirs) do
        local btn = NS.CB_CreateButton(btnRow, "CleanBotActionBarNudge" .. i, d[1], BW, BH,
            function() nudge(d[2], d[3]) end)
        if i == 1 then
            btn:SetPoint("LEFT", btnRow, "LEFT", 0, 0)
        else
            btn:SetPoint("LEFT", prev, "RIGHT", BGAP, 0)
        end
        prev = btn
    end

    -- Done button (bottom center): leaves edit mode.
    local doneBtn = NS.CB_CreateButton(configFrame, "CleanBotActionBarDoneBtn", "Done", 80, 22,
        function() NS.CB_SetActionBarEditMode(false) end)
    doneBtn:SetPoint("BOTTOM", configFrame, "BOTTOM", 0, PADC)

    -- Snapping toggle (left-aligned, above Done): persists CleanBot_SavedVars.actionBarSnap.
    local snapCB = NS.CB_CreateLabeledCheckBox(configFrame, "CleanBotActionBarSnapCB", "Snapping",
        "Snap the bar to nearby frame edges while dragging.")
    snapCB:SetSize(20, 20)
    snapCB:SetPoint("BOTTOMLEFT", configFrame, "BOTTOMLEFT", PADC, PADC + 22 + 10)
    snapCB:SetScript("OnClick", function(self)
        NS.actionBarSnap = self:GetChecked() and true or false
        if CleanBot_SavedVars then CleanBot_SavedVars.actionBarSnap = NS.actionBarSnap end
    end)
    configFrame.snapCB = snapCB

    -- Pins the config beside the bar. Vertical adjacency (below/above) and horizontal alignment
    -- (extend right / centered / extend left) are each preferred from where the bar sits relative to a
    -- centered deadzone, so the panel is pushed away from whichever screen edges the bar is near. The
    -- vertical default is ABOVE (only a bar near the top pushes it below); bar at top-left → below +
    -- extending right, etc. But the preference can be overridden: every
    -- candidate placement is scored so the panel stays on-screen AND avoids covering the frame the bar
    -- is anchored to (which sits right beside the bar when snapped). On-screen wins first, then
    -- not-overlapping the anchor frame, then the deadzone preference.
    local GAPC, DZ = 6, 0.32

    -- Screen rect the config would occupy for a given (vert, horiz) placement.
    local function rectFor(vert, horiz, bl, bb, br, bt, cw, ch)
        local l = (horiz == "LEFT" and bl) or (horiz == "RIGHT" and br - cw) or ((bl + br) / 2 - cw / 2)
        local b = (vert == "BELOW") and (bb - GAPC - ch) or (bt + GAPC)
        return l, b, l + cw, b + ch
    end
    -- Total length of edges hanging off-screen (linear; 0 when fully on-screen).
    local function offScreen(l, b, r, t, sw, sh)
        return math.max(0, -l) + math.max(0, r - sw) + math.max(0, -b) + math.max(0, t - sh)
    end
    local overlap = CB_RectOverlap

    CB_PositionConfig = function()
        if not (configFrame and bar) then return end
        local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
        local bl, bb, br, bt = bar:GetLeft(), bar:GetBottom(), bar:GetRight(), bar:GetTop()
        if not bl then return end
        local cw, ch = configFrame:GetWidth(), configFrame:GetHeight()
        local dx = (bl + br) / 2 - sw / 2
        local dy = (bb + bt) / 2 - sh / 2

        local prefVert  = (dy > DZ * sh) and "BELOW" or "ABOVE"
        local prefHoriz = (dx < -DZ * sw) and "LEFT" or (dx > DZ * sw) and "RIGHT" or ""

        -- Anchor-frame rect to avoid (skip when anchored to UIParent or unresolved).
        local rf = anchor.relTo ~= "UIParent" and _G[anchor.relTo]
        local rl, rb, rr, rt
        if rf and rf.GetLeft and rf:GetLeft() then
            rl, rb, rr, rt = rf:GetLeft(), rf:GetBottom(), rf:GetRight(), rf:GetTop()
        end

        local best, bestScore
        for _, vert in ipairs({ "BELOW", "ABOVE" }) do
            for _, horiz in ipairs({ "", "LEFT", "RIGHT" }) do
                local l, b, r, t = rectFor(vert, horiz, bl, bb, br, bt, cw, ch)
                local score = -1000 * offScreen(l, b, r, t, sw, sh)
                if rl then score = score - overlap(l, b, r, t, rl, rb, rr, rt) end
                if vert  == prefVert  then score = score + 50 end
                if horiz == prefHoriz then score = score + 25 end
                if not bestScore or score > bestScore then
                    bestScore, best = score, { vert = vert, horiz = horiz }
                end
            end
        end

        local cPoint = (best.vert == "BELOW" and "TOP" or "BOTTOM") .. best.horiz
        local bPoint = (best.vert == "BELOW" and "BOTTOM" or "TOP") .. best.horiz
        local yoff   = (best.vert == "BELOW") and -GAPC or GAPC
        configFrame:ClearAllPoints()
        configFrame:SetPoint(cPoint, bar, bPoint, 0, yoff)
    end

    -- Syncs the dropdown text and editboxes from the live anchor (no focused box is clobbered).
    CB_RefreshConfig = function()
        if not configFrame then return end
        UIDropDownMenu_SetText(growDD, CORNER_LABEL[anchor.growFrom] or anchor.growFrom)
        UIDropDownMenu_SetText(dirDD, DIR_LABEL[anchor.growDir] or anchor.growDir)
        if not xBox:HasFocus() then xBox:SetText(tostring(math.floor((anchor.x or 0) + 0.5))) end
        if not yBox:HasFocus() then yBox:SetText(tostring(math.floor((anchor.y or 0) + 0.5))) end
        snapCB:SetChecked(NS.actionBarSnap)
    end
end

-- ── Build (once, at PLAYER_LOGIN) ────────────────────────────────────────────
local function CB_BuildActionBar()
    bar = CreateFrame("Frame", "CleanBotActionBarFrame", UIParent)
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:Hide()
    NS.CB_ApplyFrameSkin(bar, 2)

    -- Summon: bring the party/raid's bots to the player.
    local summonBtn = NS.CB_CreateIconButton(bar, "CleanBotActionSummonBtn",
        "Interface\\Icons\\Spell_Arcane_TeleportStormwind", BTN,
        function() NS.CB_SendGroupCommand("summon") end)
    NS.CB_SetTooltip(summonBtn, "Summon", "Summon your party/raid bots to you.")

    -- Attack (flyout): left-click orders the WHOLE group onto your target; the flyout sends the same
    -- order scoped to a single role/combat-type via the leading @-qualifier (read by the bots
    -- server-side). Icons live in the addon's icons/ folder.
    local ATK = "Interface\\AddOns\\CleanBot\\icons\\attack"
    local attackBtn = CB_CreateFlyoutButton(bar, "CleanBotActionAttackBtn", ATK,
        function() NS.CB_SendGroupCommand("do attack my target") end,
        "Attack", "Order all your bots to attack your target.")
    local attackTargets = {
        { icon = "_tank",   qual = "@tank",   title = "Attack — Tanks",   desc = "Order your tank bots to attack your target." },
        { icon = "_healer", qual = "@heal",   title = "Attack — Healers", desc = "Order your healer bots to attack your target." },
        { icon = "_dps",    qual = "@dps",    title = "Attack — DPS",     desc = "Order your DPS bots to attack your target." },
        { icon = "_melee",  qual = "@melee",  title = "Attack — Melee",   desc = "Order your melee bots to attack your target." },
        { icon = "_ranged", qual = "@ranged", title = "Attack — Ranged",  desc = "Order your ranged bots to attack your target." },
    }
    for _, t in ipairs(attackTargets) do
        attackBtn:AddFlyout(ATK .. t.icon,
            function() NS.CB_SendGroupCommand(t.qual .. " do attack my target") end,
            t.title, t.desc)
    end

    -- Pull: tell the group's tank bots to pull YOUR current target (server-side: tank-only, needs the
    -- pull strategy, which tank specs run by default). One-shot, like Attack.
    local pullBtn = NS.CB_CreateIconButton(bar, "CleanBotActionPullBtn",
        "Interface\\Icons\\Ability_Hunter_Misdirection", BTN,
        function() NS.CB_SendGroupCommand("pull my target") end)
    NS.CB_SetTooltip(pullBtn, "Pull",
        "Order your tank bots to pull your current target. (Select a mob first.)")

    -- Passive: toggle every bot's passive state (OR-read + blanket flip — same as the
    -- Manage tab's Passive checkbox). Lit when any bot is passive.
    passiveBtn = NS.CB_CreateIconButton(bar, "CleanBotActionPassiveBtn",
        "Interface\\Icons\\Spell_Nature_Sleep", BTN,
        function()
            NS.CB_SetGroupPassive(not NS.CB_GetGroupPassive())
            NS.CB_RefreshCommands()
        end)
    NS.CB_SetTooltip(passiveBtn, "Passive", "Toggle all bots passive — stand down and do nothing in combat.")
    NS.commandRefreshers[#NS.commandRefreshers + 1] = refreshPassiveBtn

    -- Release (flyout → Revive): death-state control, broadcast to the group. Left-click releases
    -- spirit; hover or right-click reveals Revive (run back / revive from corpse).
    local releaseBtn = CB_CreateFlyoutButton(bar, "CleanBotActionReleaseBtn",
        "Interface\\Icons\\Spell_Holy_GuardianSpirit",
        function() NS.CB_SendGroupCommand("release") end,
        "Release", "Release your bots' spirits when they die.")
    releaseBtn:AddFlyout("Interface\\Icons\\Spell_Holy_Resurrection",
        function() NS.CB_SendGroupCommand("revive") end,
        "Revive", "Revive your bots from their corpses.")

    -- Movement (flyout): Follow (main) reveals Runaway + Stay. Each lights when it's the group's
    -- movement value for the current combat context. Blizzard icons (no custom art for these yet).
    followBtn = CB_CreateFlyoutButton(bar, "CleanBotActionFollowBtn",
        "Interface\\Icons\\Ability_Hunter_BeastSoothe",
        function() setMovement("mFollow") end,
        "Follow", "Order your bots to follow you.")
    stayBtn = followBtn:AddFlyout("Interface\\Icons\\Spell_Nature_TimeStop",
        function() setMovement("mStay") end,
        "Stay", "Order your bots to hold position.")
    runawayBtn = followBtn:AddFlyout("Interface\\Icons\\Ability_Rogue_Sprint", runawayMovement,
        "Runaway", "Order your bots to keep their distance from enemies. Reverts to their previous combat movement when combat ends.")
    NS.commandRefreshers[#NS.commandRefreshers + 1] = refreshMoveBtns

    -- Combat transitions re-flow the displayed context (combat vs non-combat), and combat END triggers
    -- the pending Runaway revert.
    local moveCombatFrame = CreateFrame("Frame", "CleanBotActionMoveCombatFrame")
    moveCombatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    moveCombatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    moveCombatFrame:SetScript("OnEvent", function(_, ev)
        if ev == "PLAYER_REGEN_ENABLED" then revertRunaway() end
        refreshMoveBtns()
    end)

    -- Lay out the buttons in flow order per the grow direction (also sizes the bar).
    barButtons = { summonBtn, attackBtn, pullBtn, passiveBtn, followBtn, releaseBtn }
    CB_LayoutBar()

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

    CB_BuildConfig()

    -- ── Restore position + shown state (edit mode always starts off). ──
    -- Seed the anchor model from SavedVars. Pre-grow-from saves stored point/relPoint = BOTTOMLEFT, so
    -- their x/y are valid BOTTOMLEFT offsets and the default growFrom = BOTTOMLEFT reproduces them.
    local a = CleanBot_SavedVars and CleanBot_SavedVars.actionBarAnchor
    if type(a) == "table" then
        anchor.relTo    = a.relTo or "UIParent"
        anchor.growFrom = (a.growFrom and CORNER_LABEL[a.growFrom] and a.growFrom) or a.point or "BOTTOMLEFT"
        anchor.x        = a.x or 0
        anchor.y        = a.y or 0
        anchor.growDir  = (a.growDir and DIR_LABEL[a.growDir] and a.growDir) or "RIGHT"
    end
    CB_LayoutBar()   -- reflow buttons for the restored direction before pinning the corner
    CB_ApplyAnchor()
    -- Snapping defaults ON; only an explicit saved false disables it.
    NS.actionBarSnap = not (CleanBot_SavedVars and CleanBot_SavedVars.actionBarSnap == false)
    CB_RefreshConfig()
    NS.actionBarShown = CleanBot_SavedVars and CleanBot_SavedVars.actionBarShown == true
    applyVisibility()
    refreshPassiveBtn()
    refreshMoveBtns()
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
