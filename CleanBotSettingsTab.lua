-- ============================================================
-- CleanBotSettingsTab.lua  —  Settings tab content
-- ============================================================
local NS = CleanBotNS

NS.CleanBot_BuildSettingsContent = function()
    local cb = NS.CB_CreateCheckBox(NS.settingsPanel, "CleanBotAssumeBotsCheck")
    cb:SetPoint("TOPLEFT", NS.settingsPanel, "TOPLEFT", NS.PAD, -NS.PAD)
    cb:SetChecked(NS.ASSUME_ALL_PARTY_ARE_BOTS)
    cb:SetScript("OnClick", function(self)
        NS.ASSUME_ALL_PARTY_ARE_BOTS = self:GetChecked() and true or false
    end)

    local label = NS.settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText("Treat All Players as Bots")

    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Treat All Players as Bots", 1, 1, 1)
        GameTooltip:AddLine(
            "Treat every party member as a bot regardless of whether the " ..
            "MultiBot bridge has confirmed them. Enable this when the bridge " ..
            "module is not installed on the server or is otherwise malfunctioning.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
