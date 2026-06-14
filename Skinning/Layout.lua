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
--- Anchors widget directly to the right of another widget in a horizontal flow row.
---@param widget table  The widget to position (reads its marginLeft).
---@param before table  The widget to its left (reads its marginRight).
NS.CB_AnchorAhead = function(widget, before)
    local gap = (before.marginRight or 0) + (widget.marginLeft or 0)
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT", before, "TOPRIGHT", gap, 0)
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
