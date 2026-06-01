-- ============================================================
-- CleanBotMinimap.lua  —  Minimap button
-- ============================================================
local NS = CleanBotNS

local RADIUS = 80  -- distance from minimap center to button center
local angle  = 220 -- degrees

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

local function UpdatePosition()
    local rad = math.rad(angle)
    btn:SetPoint("CENTER", Minimap, "CENTER",
        RADIUS * math.cos(rad),
        RADIUS * math.sin(rad))
end
UpdatePosition()

btn:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
        CleanBotNS.CleanBot_Toggle()
    end
end)

btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("CleanBot", 1, 1, 1)
    GameTooltip:AddLine("Click to open Bot Manager", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end)
btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
