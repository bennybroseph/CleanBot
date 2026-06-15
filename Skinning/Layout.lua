-- ============================================================
-- Skinning\Layout.lua  —  margin/padding flow anchoring helpers
--                         and the horizontal-rule separator.
--
-- The CSS-like spacing model: padding is a frame's inner inset,
-- margin is the space a widget reserves around itself. These
-- helpers turn stamped margin/padding fields into SetPoint offsets
-- so call sites never hardcode raw point offsets.
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- Live-layout record/replay registry
--
-- Every widget positioned by the flow/wall helpers records HOW it was placed, so a margin/padding
-- change can re-apply the spacing without rebuilding the UI. A widget may hold several records under
-- different "slots": one "flow" slot (CB_AnchorBelow/Ahead, which owns the widget's TOP/LEFT points)
-- and one slot per wall corner (CB_AnchorWall, additive points like a RIGHT edge for width). Records
-- are de-duped by (widget, slot) so a runtime re-anchor updates in place, and kept in first-seen
-- order so replay re-anchors references before dependents.
-- ============================================================
local recordList = {}       -- ordered array of records { w, kind, slot, ref?/parent?/corner? }
local recordMap  = {}       -- widget -> { [slot] = record }
local replaying  = false    -- true while replaying: suppresses re-recording from the helpers
NS.CB_layoutRecords = recordList

local function record(widget, slot, data)
    if replaying then return end
    local byWidget = recordMap[widget]
    if not byWidget then byWidget = {}; recordMap[widget] = byWidget end
    local rec = byWidget[slot]
    if rec then
        rec.ref, rec.parent, rec.corner, rec.fn = data.ref, data.parent, data.corner, data.fn
    else
        data.w, data.slot = widget, slot
        byWidget[slot] = data
        recordList[#recordList + 1] = data
    end
end

-- Widgets/frames whose margin/padding fields were stamped (copied) from NS.MARGIN/NS.PADDING at
-- creation, so CB_RestampAll can refresh them when those tables change. Populated by the factories.
NS.CB_stampables = NS.CB_stampables or {}

--- Registers a stamped widget (idempotent) so CB_RestampAll refreshes it.
---@param widget table  A widget carrying _marginType, or a frame carrying _paddingRole.
NS.CB_RegisterStampable = function(widget)
    if widget and not widget._inStampables then
        widget._inStampables = true
        NS.CB_stampables[#NS.CB_stampables + 1] = widget
    end
end

-- ============================================================
-- Layout helper — anchors widget directly below above (vertical flow).
-- Gap (Y axis) = above.marginBottom + widget.marginTop.
-- X position is CSS-style: parent.paddingLeft + widget.marginLeft,
-- applied relative to the parent frame's left edge so each widget
-- in the chain positions itself independently (not inherited from above).
-- ============================================================
--- Anchors widget directly below another widget in a vertical flow chain.
---@param widget table  The widget to position (reads its marginTop/marginLeft).
---@param above  table  The widget above it (reads its marginBottom).
NS.CB_AnchorBelow = function(widget, above)
    local gap    = (above.marginBottom or 0) + (widget.marginTop or 0)
    local parent = widget:GetParent()
    local xLeft  = (parent and parent.paddingLeft or 0) + (widget.marginLeft or 0)
    -- On replay we UPDATE the existing points instead of clearing, so extra inline anchors a caller
    -- added after this (e.g. a RIGHT wall anchor for width) survive the re-flow.
    if not replaying then widget:ClearAllPoints() end
    widget:SetPoint("TOP",  above,  "BOTTOM", 0,    -gap)
    widget:SetPoint("LEFT", parent, "LEFT",   xLeft,  0)
    record(widget, "flow", { kind = "below", ref = above })
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
--- Anchors widget directly to the right of another widget in a horizontal flow row.
---@param widget table  The widget to position (reads its marginLeft).
---@param before table  The widget to its left (reads its marginRight).
NS.CB_AnchorAhead = function(widget, before)
    local gap = (before.marginRight or 0) + (widget.marginLeft or 0)
    if not replaying then widget:ClearAllPoints() end  -- see CB_AnchorBelow: preserve extra inline points on replay
    widget:SetPoint("TOPLEFT", before, "TOPRIGHT", gap, 0)
    record(widget, "flow", { kind = "ahead", ref = before })
end

-- ============================================================
-- Layout helper — anchors one of a widget's corners/edges to the matching corner/edge of its parent,
-- inset by the parent's padding + the widget's margin on that side (the CSS "wall" math documented in
-- CLAUDE.md). Additive (no ClearAllPoints): call once per corner — e.g. TOPLEFT + BOTTOMRIGHT to fill,
-- or a single RIGHT to set a width edge — and the points coexist. Recorded so padding goes live.
-- ============================================================
--- Anchors widget's `corner` to the parent's same corner, inset by padding+margin.
---@param widget table   The widget to position (reads its margin on the inset sides).
---@param parent table   The frame whose wall to anchor against (reads its padding).
---@param corner string  TOPLEFT|TOPRIGHT|BOTTOMLEFT|BOTTOMRIGHT|LEFT|RIGHT|TOP|BOTTOM.
NS.CB_AnchorWall = function(widget, parent, corner)
    local pl = (parent.paddingLeft   or 0) + (widget.marginLeft   or 0)
    local pr = (parent.paddingRight  or 0) + (widget.marginRight  or 0)
    local pt = (parent.paddingTop    or 0) + (widget.marginTop    or 0)
    local pb = (parent.paddingBottom or 0) + (widget.marginBottom or 0)
    local x, y = 0, 0
    if     corner == "TOPLEFT"     then x, y =  pl, -pt
    elseif corner == "TOPRIGHT"    then x, y = -pr, -pt
    elseif corner == "BOTTOMLEFT"  then x, y =  pl,  pb
    elseif corner == "BOTTOMRIGHT" then x, y = -pr,  pb
    elseif corner == "LEFT"        then x, y =  pl,  0
    elseif corner == "RIGHT"       then x, y = -pr,  0
    elseif corner == "TOP"         then x, y =  0,  -pt
    elseif corner == "BOTTOM"      then x, y =  0,   pb
    end
    widget:SetPoint(corner, parent, corner, x, y)
    record(widget, "wall:" .. corner, { kind = "wall", parent = parent, corner = corner })
end

-- ============================================================
-- Closure-recorded anchor — for inline / structural-constant-mixed / multi-point placements that the
-- flow (CB_AnchorBelow/Ahead) and corner (CB_AnchorWall) helpers can't express. `fn` does the raw
-- widget:SetPoint calls (reading live padding/margin/constants); it is run now and re-run on every
-- replay so the placement tracks padding changes. CONTRACT: the closure OWNS all of its widget's
-- points (no coexisting flow/wall record on the same widget) — so it may ClearAllPoints freely.
-- ============================================================
--- Records and applies a closure that fully positions `widget`; re-run on layout change.
---@param widget table  The widget the closure positions (sole owner of its points).
---@param fn     fun()  Performs the SetPoint(s); reads live padding/margin/constants.
NS.CB_Anchor = function(widget, fn)
    fn()
    record(widget, "closure", { kind = "closure", fn = fn })
end

-- Horizontal rule. ElvUI: 1px line using E.media.blank tinted with the border
-- color. Fallback: the UI-TooltipDivider-Transparent tiled texture at 8px.
-- Width is NOT set — callers size it after anchoring with CB_AnchorBelow.
--- Creates a 1px horizontal separator frame with margins stamped.
---@param parent table  Parent frame to create the separator inside.
---@return table        The created Frame (caller must SetWidth after anchoring).
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

-- ============================================================
-- Live re-layout (LAYOUT_CHANGED)
-- ============================================================

-- Re-applies stamped margins/padding from the live NS.MARGIN/NS.PADDING tables. The factories COPY
-- these values at creation, so a settings change must re-stamp before the anchors are replayed.
NS.CB_RestampAll = function()
    for _, w in ipairs(NS.CB_stampables) do
        local m = w._marginType and NS.MARGIN[w._marginType]
        if m then
            w.marginTop, w.marginBottom, w.marginLeft, w.marginRight = m.top, m.bottom, m.left, m.right
        end
        -- Optional per-widget top override (the titled slider uses the label top margin).
        local mt = w._marginTopType and NS.MARGIN[w._marginTopType]
        if mt then w.marginTop = mt.top end
        local p = w._paddingRole and NS.PADDING[w._paddingRole]
        if p then
            w.paddingTop, w.paddingBottom, w.paddingLeft, w.paddingRight = p.top, p.bottom, p.left, p.right
        end
    end
end

-- Replays every recorded anchor in first-seen order, re-establishing the flow with the freshly
-- re-stamped margins/padding. Guarded so the helpers don't re-record while replaying.
NS.CB_ReplayAnchors = function()
    replaying = true
    for _, r in ipairs(recordList) do
        if     r.kind == "below"   then NS.CB_AnchorBelow(r.w, r.ref)
        elseif r.kind == "ahead"   then NS.CB_AnchorAhead(r.w, r.ref)
        elseif r.kind == "wall"    then NS.CB_AnchorWall(r.w, r.parent, r.corner)
        elseif r.kind == "closure" then r.fn()
        end
    end
    replaying = false
end

-- Relayout callbacks — size/extent recompute that must run AFTER positions settle (section heights,
-- collapsible backgrounds, scroll regions, separators, window width). Registered once at build.
NS.CB_relayouts = NS.CB_relayouts or {}

--- Registers a callback to run on every layout change, after re-stamp + anchor replay.
---@param fn fun()  Recompute that reads live NS.MARGIN/NS.PADDING (and may read post-replay geometry).
NS.CB_RegisterRelayout = function(fn)
    NS.CB_relayouts[#NS.CB_relayouts + 1] = fn
end

--- Runs every registered relayout callback in registration order.
NS.CB_RunRelayouts = function()
    for _, fn in ipairs(NS.CB_relayouts) do fn() end
end

-- Deferred relayout callbacks — for recomputes that read GetBottom/GetTop of freshly-anchored frames
-- (e.g. collapsible background heights), which are only valid one frame after the layout resolves.
NS.CB_deferredRelayouts = NS.CB_deferredRelayouts or {}

--- Registers a callback to run one frame after a layout change (post-draw geometry available).
---@param fn fun()
NS.CB_RegisterDeferredRelayout = function(fn)
    NS.CB_deferredRelayouts[#NS.CB_deferredRelayouts + 1] = fn
end

--- Runs every deferred relayout callback (invoked via CB_After(0) from the LAYOUT_CHANGED handler).
NS.CB_RunDeferredRelayouts = function()
    for _, fn in ipairs(NS.CB_deferredRelayouts) do fn() end
end

-- Live layout on any margin/padding change. Order matters: re-stamp the margin/padding fields first,
-- then replay anchors (which read those fields), then size recomputes (which read post-anchor
-- geometry). GetBottom/GetTop-dependent recomputes that need a drawn frame run one frame later.
NS.CB_On(NS.EV.LAYOUT_CHANGED, function()
    NS.CB_RestampAll()
    NS.CB_ReplayAnchors()
    NS.CB_RunRelayouts()
    NS.CB_After(0, NS.CB_RunDeferredRelayouts)
end)
