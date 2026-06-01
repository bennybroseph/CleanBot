-- ============================================================
-- CleanBotTargetTab.lua  —  Manage tab: add / remove bots
-- ============================================================
local NS = CleanBotNS

NS.CleanBot_BuildTargetContent = function()
    local function makeBtn(label, yOffset, onClick)
        local safeName = label:gsub("%s+", "")
        local btn = CreateFrame("Button", "CleanBotTarget" .. safeName .. "Btn",
                                NS.targetPanel, "UIPanelButtonTemplate")
        btn:SetSize(120, 24)
        btn:SetPoint("TOPLEFT", NS.targetPanel, "TOPLEFT", NS.PAD, yOffset)
        btn:SetText(label)
        btn:SetScript("OnClick", onClick)
        if NS.ElvUI_S then NS.ElvUI_S:HandleButton(btn) end
        return btn
    end

    makeBtn("Add Target", -NS.PAD, function()
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

    makeBtn("Remove Target", -(NS.PAD + 30), function()
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

    -- ── Favorites section ─────────────────────────────────────
    local favLabel = NS.targetPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    favLabel:SetPoint("TOPLEFT", NS.targetPanel, "TOPLEFT", NS.PAD, -(NS.PAD + 120))
    favLabel:SetText("Favorites")

    -- Builds a favorites dropdown and wires up its selection callback.
    -- onSelect(displayName) is called when an entry is chosen.
    local function makeFavDropdown(frameName, anchorBtn, onSelect)
        local dd = CreateFrame("Frame", frameName, NS.targetPanel, "UIDropDownMenuTemplate")
        dd:SetPoint("LEFT", anchorBtn, "RIGHT", -10, 0)
        UIDropDownMenu_SetWidth(dd, 150)
        if NS.ElvUI_S then NS.ElvUI_S:HandleDropDownBox(dd, 150) end
        UIDropDownMenu_Initialize(dd, function(self)
            UIDropDownMenu_SetText(dd, "")
            onSelect(nil)
            local favs = CleanBot_SavedVars and CleanBot_SavedVars.favoriteBots
            if not favs then return end
            local any = false
            for key in pairs(favs) do
                local displayName = key:sub(1, 1):upper() .. key:sub(2)
                local info        = UIDropDownMenu_CreateInfo()
                info.text         = displayName
                info.value        = displayName
                info.func         = function()
                    UIDropDownMenu_SetText(self, displayName)
                    onSelect(displayName)
                end
                UIDropDownMenu_AddButton(info)
                any = true
            end
            if not any then
                local info        = UIDropDownMenu_CreateInfo()
                info.text         = "No favorites saved"
                info.notCheckable = 1
                UIDropDownMenu_AddButton(info)
            end
        end)
        return dd
    end

    local selectedFavName = nil
    local addFavBtn = CreateFrame("Button", "CleanBotAddFavoriteBtn", NS.targetPanel, "UIPanelButtonTemplate")
    addFavBtn:SetSize(60, 24)
    addFavBtn:SetPoint("TOPLEFT", favLabel, "BOTTOMLEFT", 0, -8)
    addFavBtn:SetText("Invite")
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(addFavBtn) end
    local favDD = makeFavDropdown("CleanBotFavoritesDD", addFavBtn, function(name) selectedFavName = name end)
    addFavBtn:SetScript("OnClick", function()
        if not selectedFavName then
            print("|cffffcc00CleanBot|r: No favorite selected.")
            return
        end
        SendChatMessage(".playerbots bot add " .. selectedFavName, "SAY")
    end)

    local selectedDelName = nil
    local delFavBtn = CreateFrame("Button", "CleanBotDeleteFavoriteBtn", NS.targetPanel, "UIPanelButtonTemplate")
    delFavBtn:SetSize(60, 24)
    delFavBtn:SetPoint("TOPLEFT", addFavBtn, "BOTTOMLEFT", 0, -8)
    delFavBtn:SetText("Delete")
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(delFavBtn) end
    local delFavDD = makeFavDropdown("CleanBotFavoritesDelDD", delFavBtn, function(name) selectedDelName = name end)
    delFavBtn:SetScript("OnClick", function()
        if not selectedDelName then
            print("|cffffcc00CleanBot|r: No favorite selected.")
            return
        end
        local key = strlower(selectedDelName)
        if CleanBot_SavedVars and CleanBot_SavedVars.favoriteBots then
            CleanBot_SavedVars.favoriteBots[key] = nil
        end
        if NS.botStarUpdaters and NS.botStarUpdaters[key] then
            NS.botStarUpdaters[key]()
        end
        UIDropDownMenu_SetText(delFavDD, "")
        UIDropDownMenu_SetText(favDD, "")
        selectedDelName = nil
        selectedFavName = nil
    end)
end
