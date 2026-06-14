-- ============================================================
-- Minimap.lua  —  Minimap button
-- ============================================================
local NS = CleanBotNS

local btn = CreateFrame("Button", "CleanBotMinimapButton", Minimap)
btn:SetSize(31, 31)
btn:SetFrameStrata("MEDIUM")
btn:SetFrameLevel(8)

btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local icon = btn:CreateTexture(nil, "BACKGROUND")
icon:SetTexture("Interface\\Icons\\INV_Misc_Wrench_01")
icon:SetSize(20, 20)
icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 7, -5)

local border = btn:CreateTexture(nil, "OVERLAY")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetSize(53, 53)
border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

-- ── Movable positioning (ported from LibDBIcon-1.0) ──────────────────────────
-- The button rides the minimap rim at a saved ANGLE. Per minimap shape, each of the
-- four quadrants is rounded (true) or squared (false): rounded → place on the circle
-- (r=80); squared → project onto the square edge and clamp to ±80. This handles round,
-- square, corner, side and tricorner minimaps via the GetMinimapShape() global (provided
-- by square-minimap addons; defaults to ROUND).
local DEFAULT_ANGLE = 220
local currentAngle  = DEFAULT_ANGLE   -- degrees; persisted in CleanBot_SavedVars.minimapAngle

local minimapShapes = {
    ["ROUND"]                 = { true,  true,  true,  true  },
    ["SQUARE"]                = { false, false, false, false },
    ["CORNER-TOPLEFT"]        = { true,  false, false, false },
    ["CORNER-TOPRIGHT"]       = { false, false, true,  false },
    ["CORNER-BOTTOMLEFT"]     = { false, true,  false, false },
    ["CORNER-BOTTOMRIGHT"]    = { false, false, false, true  },
    ["SIDE-LEFT"]             = { true,  true,  false, false },
    ["SIDE-RIGHT"]            = { false, false, true,  true  },
    ["SIDE-TOP"]              = { true,  false, true,  false },
    ["SIDE-BOTTOM"]           = { false, true,  false, true  },
    ["TRICORNER-TOPLEFT"]     = { true,  true,  true,  false },
    ["TRICORNER-TOPRIGHT"]    = { true,  false, true,  true  },
    ["TRICORNER-BOTTOMLEFT"]  = { true,  true,  false, true  },
    ["TRICORNER-BOTTOMRIGHT"] = { false, true,  true,  true  },
}

-- Overhang past the minimap edge (LibDBIcon's lib.radius default). On the default 140px
-- minimap this makes the round radius 70 + 10 = 80, matching the old fixed value; on a
-- resized minimap it scales so the button still hugs the rim.
local RIM_OVERHANG = 10

--- Repositions the button on the minimap rim for currentAngle, honoring minimap shape
--- AND the live minimap size (radius derived from Minimap:GetWidth()/GetHeight()).
local function UpdatePosition()
    local a = math.rad(currentAngle)
    local x, y, q = math.cos(a), math.sin(a), 1
    if x < 0 then q = q + 1 end
    if y > 0 then q = q + 2 end
    local quad = minimapShapes[(GetMinimapShape and GetMinimapShape()) or "ROUND"]
              or minimapShapes["ROUND"]
    local w = (Minimap:GetWidth()  / 2) + RIM_OVERHANG
    local h = (Minimap:GetHeight() / 2) + RIM_OVERHANG
    if quad[q] then
        x, y = x * w, y * h
    else
        local diagW = math.sqrt(2 * w * w) - 10
        local diagH = math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(x * diagW, w))
        y = math.max(-h, math.min(y * diagH, h))
    end
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end
UpdatePosition()

-- ── Left-click drag to move ──────────────────────────────────────────────────
-- While dragging, track the cursor's angle from the minimap center, persist it, reposition.
-- A plain left click (press + release, no drag) still fires OnClick → toggles the window.
local function OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale  = Minimap:GetEffectiveScale()
    if not (mx and px and scale and scale ~= 0) then return end
    px, py = px / scale, py / scale
    currentAngle = math.deg(math.atan2(py - my, px - mx)) % 360
    if CleanBot_SavedVars then CleanBot_SavedVars.minimapAngle = currentAngle end
    UpdatePosition()
end

btn:RegisterForDrag("LeftButton")
btn:SetScript("OnDragStart", function(self)
    self:LockHighlight()
    GameTooltip:Hide()
    self:SetScript("OnUpdate", OnDragUpdate)
end)
btn:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    self:UnlockHighlight()
end)

-- Right button is registered so future right-click actions can hook in here.
btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
btn:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
        CleanBotNS.CleanBot_Toggle()
    end
end)

NS.CB_AttachTooltip(btn, function(tt)
    tt:AddLine("CleanBot", 1, 1, 1)
    tt:AddLine("Click to Open CleanBot", 0.8, 0.8, 0.8)
    tt:AddLine("Drag to Move", 0.8, 0.8, 0.8)

    -- Bridge status line — always shows the real handshake state (not the debug override).
    local state = NS.bridgeState or "unknown"
    local r, g, b
    if state == "present" then
        r, g, b = 0.2, 1.0, 0.2
    elseif state == "absent" then
        r, g, b = 1.0, 0.3, 0.3
    else
        r, g, b = 1.0, 0.8, 0.2
    end
    tt:AddLine("MultiBot Bridge Status: " .. state, r, g, b)

    -- Debug lines — only shown when an override or simulate mode is active.
    if NS.debugBridgeOverride then
        tt:AddLine("|cff888888Debug: Bridge override \226\134\146 " .. NS.debugBridgeOverride .. "|r")
    end
    if NS.debugSimulate then
        tt:AddLine("|cff888888Simulate mode: ON|r")
    end
    if NS.debugVerify then
        tt:AddLine("|cff888888Strategy verify logging: ON|r")
    end
end, "ANCHOR_LEFT")

-- Restore the saved drag position at login. Minimap.lua loads after CleanBot.lua, so its
-- PLAYER_LOGIN handler fires after CleanBot_SavedVars is initialized; by login any
-- square-minimap addon that provides GetMinimapShape has also loaded, so the reposition
-- lands on the correct rim.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    if CleanBot_SavedVars and type(CleanBot_SavedVars.minimapAngle) == "number" then
        currentAngle = CleanBot_SavedVars.minimapAngle
    end
    UpdatePosition()
end)
