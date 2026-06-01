-- ============================================================
-- CleanBotTargetTab.lua  —  Target tab: add / remove bots
-- ============================================================
local NS = CleanBotNS

NS.CleanBot_BuildTargetContent = function()
    local function makeBtn(label, yOffset, onClick)
        local btn = CreateFrame("Button", "CleanBotTarget" .. label .. "Btn",
                                NS.targetPanel, "UIPanelButtonTemplate")
        btn:SetSize(120, 24)
        btn:SetPoint("TOPLEFT", NS.targetPanel, "TOPLEFT", NS.PAD, yOffset)
        btn:SetText(label)
        btn:SetScript("OnClick", onClick)
        if NS.ElvUI_S then NS.ElvUI_S:HandleButton(btn) end
        return btn
    end

    makeBtn("Add", -NS.PAD, function()
        if not UnitExists("target") or not UnitIsPlayer("target") then
            print("|cffffcc00CleanBot|r: No valid player target selected.")
            return
        end
        if UnitIsUnit("target", "player") or UnitInParty("target") then
            print("|cffffcc00CleanBot|r: Target is already in your party.")
            return
        end
        local target = UnitName("target")
        local isKnownBot = target and CleanBot_KnownBots[strlower(target)] ~= nil
        if not isKnownBot and not NS.ASSUME_ALL_PARTY_ARE_BOTS then
            print("|cffffcc00CleanBot|r: Cannot verify '" .. (target or "?") ..
                  "' is a bot. Enable 'Assume all party members are bots' in Settings.")
            return
        end
        InviteUnit(target)
    end)

    makeBtn("Remove", -(NS.PAD + 30), function()
        if not UnitExists("target") or not UnitIsPlayer("target") then
            print("|cffffcc00CleanBot|r: No valid player target selected.")
            return
        end
        if not UnitInParty("target") then
            print("|cffffcc00CleanBot|r: Target is not in your party.")
            return
        end
        if not NS.CleanBot_IsBot("target") then
            print("|cffffcc00CleanBot|r: Target does not appear to be a bot.")
            return
        end
        UninviteUnit(UnitName("target"))
    end)

    makeBtn("Remove All", -(NS.PAD + 70), function()
        local numMembers = GetNumPartyMembers and GetNumPartyMembers() or 0
        local removed = 0
        for i = 1, numMembers do
            local unit = "party" .. i
            if UnitExists(unit) and NS.CleanBot_IsBot(unit) then
                UninviteUnit(UnitName(unit))
                removed = removed + 1
            end
        end
        if removed == 0 then
            print("|cffffcc00CleanBot|r: No bots found in party to remove.")
        end
    end)
end
