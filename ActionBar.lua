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
local SNAP_DIST = 20  -- px: how close an edge must be to a frame to snap
local SNAP_GAP  = 2   -- px gap left when snapped flush to a frame's edge

-- State (assigned by the build; setters guard on `bar` so they're safe pre-build).
local bar, overlay, passiveBtn

-- Calls fn(frame, name) for each snap-candidate: a named, visible, reasonably-sized direct child
-- of UIParent or ElvUIParent (ElvUI reparents its unit frames — e.g. ElvUF_Player — there, which
-- is why a fixed list missed them). Named so the chosen anchor survives a reload (re-found via
-- _G[name]); size-bounded to skip full-screen containers; the bar itself is excluded.
local function CB_ForEachSnapCandidate(fn)
    local roots = { UIParent }
    if _G.ElvUIParent then roots[#roots + 1] = _G.ElvUIParent end
    local maxW, maxH = UIParent:GetWidth() * 0.9, UIParent:GetHeight() * 0.9
    for _, root in ipairs(roots) do
        for _, f in ipairs({ root:GetChildren() }) do
            local name = f.GetName and f:GetName()
            -- Skip tooltips: they're transient, and GameTooltip is anchored to the bar while its
            -- edit tooltip shows (SetOwner), so snapping TO it would be a dependency cycle.
            if name and f ~= bar and not name:find("Tooltip")
               and f.IsVisible and f:IsVisible() and f.GetLeft and f:GetLeft() then
                local w, h = f:GetWidth(), f:GetHeight()
                if w and h and w >= 16 and h >= 16 and w <= maxW and h <= maxH then
                    fn(f, name)
                end
            end
        end
    end
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
local dragSnapFrame         -- name of the frame the bar is currently snapped to (nil = free)
local dragging              -- true while a drag is in progress (guards double mouse-up)

-- Best single-axis snap for a proposed bottom-left: { axis = "x"|"y", value, dist, frame }, or nil.
local function CB_BestSnap(newLeft, newBottom)
    local w, h = bar:GetWidth(), bar:GetHeight()
    local bl, br, bb, bt = newLeft, newLeft + w, newBottom, newBottom + h
    local best
    CB_ForEachSnapCandidate(function(f, name)
        local cl, cr, ct, cb = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
        -- X-axis (vertical-edge) snaps require the bar to be vertically near the frame; Y the reverse.
        local vNear = bb <= ct + SNAP_DIST and bt >= cb - SNAP_DIST
        local hNear = bl <= cr + SNAP_DIST and br >= cl - SNAP_DIST
        local function consider(axis, value, dist, near)
            if near and dist <= SNAP_DIST and (not best or dist < best.dist) then
                best = { axis = axis, value = value, dist = dist, frame = name }
            end
        end
        consider("x", cl,                math.abs(bl - cl), vNear)  -- left ↔ left
        consider("x", cr - w,            math.abs(br - cr), vNear)  -- right ↔ right
        consider("x", cr + SNAP_GAP,     math.abs(bl - cr), vNear)  -- abut right of frame
        consider("x", cl - w - SNAP_GAP, math.abs(br - cl), vNear)  -- abut left of frame
        consider("y", cb,                math.abs(bb - cb), hNear)  -- bottom ↔ bottom
        consider("y", ct - h,            math.abs(bt - ct), hNear)  -- top ↔ top
        consider("y", ct + SNAP_GAP,     math.abs(bb - ct), hNear)  -- abut above frame
        consider("y", cb - h - SNAP_GAP, math.abs(bt - cb), hNear)  -- abut below frame
    end)
    return best
end

-- Per-frame drag tick: follow the cursor, then lock the one nearest snapping axis.
local function CB_DragUpdate()
    local scale = bar:GetEffectiveScale()
    if not scale or scale == 0 then return end
    local cx, cy = GetCursorPosition()
    local newLeft   = cx / scale - dragGrabX
    local newBottom = cy / scale - dragGrabY
    local snap = CB_BestSnap(newLeft, newBottom)
    dragSnapFrame = snap and snap.frame or nil
    if snap then
        if snap.axis == "x" then newLeft = snap.value else newBottom = snap.value end
    end
    bar:ClearAllPoints()
    bar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", newLeft, newBottom)
end

-- Mouse-up: anchor to the snapped frame (so the bar follows it) or UIParent, keeping the on-screen
-- position, then persist. (Called by the shared capture frame.)
local function CB_FinishDrag()
    if not dragging then return end
    dragging = false
    NS.CB_EndCapture()
    local bl, bb = bar:GetLeft(), bar:GetBottom()
    local relTo, x, y = "UIParent", bl, bb
    local f = dragSnapFrame and _G[dragSnapFrame]
    if f and f:GetLeft() then
        relTo, x, y = dragSnapFrame, bl - f:GetLeft(), bb - f:GetBottom()
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
    dragSnapFrame = nil
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
