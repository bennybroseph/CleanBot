-- ============================================================
-- CleanBotMinimap.lua  —  Minimap button
-- ============================================================
local NS = CleanBotNS

local RADIUS = 80  -- distance from minimap center to button center
local angle  = 220 -- degrees; clockwise from the right

local btn = CreateFrame("Button", "CleanBotMinimapButton", Minimap)
btn:SetSize(32, 32)
btn:SetFrameStrata("MEDIUM")
btn:SetFrameLevel(8)
btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoneButton-Highlight")

local border = btn:CreateTexture(nil, "OVERLAY")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetSize(53, 53)
border:SetPoint("CENTER", 0, 0)

local icon = btn:CreateTexture(nil, "ARTWORK")
icon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
icon:SetSize(20, 20)
icon:SetPoint("CENTER", 0, 0)

local function UpdatePosition()
    local rad = math.rad(angle)
    btn:SetPoint("CENTER", Minimap, "CENTER",
        RADIUS * math.cos(rad),
        RADIUS * math.sin(rad))
end
UpdatePosition()

btn:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
        if CleanBotFrame:IsShown() then
            CleanBotFrame:Hide()
        else
            CleanBotFrame:Show()
        end
    end
end)

btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("CleanBot", 1, 1, 1)
    GameTooltip:AddLine("Click to open Bot Manager", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end)
btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
