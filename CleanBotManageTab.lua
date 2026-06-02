-- ============================================================
-- CleanBotTargetTab.lua  —  Manage tab: add / remove bots
-- ============================================================
local NS = CleanBotNS

-- ── Link Account popup (two-step: account name → security key) ───────────────
local function CB_PositionPopup(self)
    self:ClearAllPoints()
    self:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
end

StaticPopupDialogs["CLEANBOT_LINK_ACCOUNT_NAME"] = {
    text         = "Enter the name of the account to link:",
    button1      = "OK",
    button2      = "Cancel",
    hasEditBox   = 1,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    OnShow   = CB_PositionPopup,
    OnAccept = function(self)
        local name = self.editBox and self.editBox:GetText()
        name = name and strupper(name:match("^%s*(.-)%s*$"))  -- trim + uppercase
        if not name or name == "" then
            print("|cffffcc00CleanBot|r: Account name cannot be empty.")
            return
        end
        StaticPopup_Show("CLEANBOT_LINK_ACCOUNT_KEY", name, nil, name)
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        StaticPopupDialogs["CLEANBOT_LINK_ACCOUNT_NAME"].OnAccept(dialog)
        dialog:Hide()
    end,
}

StaticPopupDialogs["CLEANBOT_LINK_ACCOUNT_KEY"] = {
    text         = "Enter the security key for account |cffffd200%s|r:",
    button1      = "OK",
    button2      = "Cancel",
    hasEditBox   = 1,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    OnShow   = CB_PositionPopup,
    OnAccept = function(self, data)
        local key = self.editBox and self.editBox:GetText()
        key = key and key:match("^%s*(.-)%s*$")
        if not key or key == "" then
            print("|cffffcc00CleanBot|r: Security key cannot be empty.")
            return
        end
        local accountName = data
        SendChatMessage(".playerbots account link " .. accountName .. " " .. key, "SAY")
        -- Add to the in-memory linked accounts list if not already present
        local found = false
        for _, v in ipairs(NS.linkedAccounts) do
            if strlower(v) == strlower(accountName) then found = true; break end
        end
        if not found then
            NS.linkedAccounts[#NS.linkedAccounts + 1] = accountName
        end
        print("|cffffcc00CleanBot|r: Linking account '" .. accountName .. "'...")
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        StaticPopupDialogs["CLEANBOT_LINK_ACCOUNT_KEY"].OnAccept(dialog, dialog.data)
        dialog:Hide()
    end,
}

NS.CleanBot_BuildTargetContent = function()
    local COL1_X = NS.PAD
    local COL2_X = NS.PAD + 130

    local function makeBtn(label, xOffset, yOffset, onClick)
        local safeName = label:gsub("%s+", "")
        local btn = CreateFrame("Button", "CleanBotTarget" .. safeName .. "Btn",
                                NS.targetPanel, "UIPanelButtonTemplate")
        btn:SetSize(120, 24)
        btn:SetPoint("TOPLEFT", NS.targetPanel, "TOPLEFT", xOffset, yOffset)
        btn:SetText(label)
        btn:SetScript("OnClick", onClick)
        if NS.ElvUI_S then NS.ElvUI_S:HandleButton(btn) end
        return btn
    end

    -- Returns the target's name if it's a valid, existing player; prints an error and returns nil otherwise.
    local function requireValidPlayerTarget()
        if not UnitExists("target") or not UnitIsPlayer("target") then
            print("|cffffcc00CleanBot|r: No valid player target selected.")
            return nil
        end
        return UnitName("target")
    end

    -- Column 1: party invite/uninvite
    makeBtn("Invite Target", COL1_X, -NS.PAD, function()
        local target = requireValidPlayerTarget()
        if not target then return end
        if UnitIsUnit("target", "player") or UnitInParty("target") then
            print("|cffffcc00CleanBot|r: Target is already in your party.")
            return
        end
        local isKnownBot = CleanBot_PartyBots[strlower(target)] ~= nil
        if not isKnownBot and not NS.ASSUME_ALL_PARTY_ARE_BOTS then
            print("|cffffcc00CleanBot|r: Cannot verify '" .. target ..
                  "' is a bot. Enable 'Assume all party members are bots' in Settings.")
            return
        end
        InviteUnit(target)
    end)

    makeBtn("Uninvite Target", COL1_X, -(NS.PAD + 30), function()
        local target = requireValidPlayerTarget()
        if not target then return end
        if not UnitInParty("target") then
            print("|cffffcc00CleanBot|r: Target is not in your party.")
            return
        end
        if not NS.CleanBot_IsBot("target") then
            print("|cffffcc00CleanBot|r: Target does not appear to be a bot.")
            return
        end
        UninviteUnit(target)
    end)

    makeBtn("Uninvite All", COL1_X, -(NS.PAD + 70), function()
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

    -- Column 2: bot login/logout
    makeBtn("Login Target", COL2_X, -NS.PAD, function()
        local target = requireValidPlayerTarget()
        if not target then return end
        SendChatMessage(".playerbots bot add " .. target, "SAY")
    end)

    makeBtn("Logout Target", COL2_X, -(NS.PAD + 30), function()
        local target = requireValidPlayerTarget()
        if not target then return end
        SendChatMessage(".playerbots bot remove " .. target, "SAY")
    end)

    makeBtn("Logout All", COL2_X, -(NS.PAD + 70), function()
        SendChatMessage(".playerbots bot remove *", "SAY")
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

    local inviteAllBtn = CreateFrame("Button", "CleanBotInviteAllFavoritesBtn", NS.targetPanel, "UIPanelButtonTemplate")
    inviteAllBtn:SetSize(80, 24)
    inviteAllBtn:SetPoint("TOPLEFT", favLabel, "BOTTOMLEFT", 0, -8)
    inviteAllBtn:SetText("Invite All")
    inviteAllBtn:SetScript("OnClick", function()
        local favs = CleanBot_SavedVars and CleanBot_SavedVars.favoriteBots
        if not favs then
            print("|cffffcc00CleanBot|r: No favorites saved.")
            return
        end
        local count = 0
        for key in pairs(favs) do
            local name = key:sub(1, 1):upper() .. key:sub(2)
            SendChatMessage(".playerbots bot add " .. name, "SAY")
            count = count + 1
        end
        if count == 0 then
            print("|cffffcc00CleanBot|r: No favorites saved.")
        end
    end)
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(inviteAllBtn) end

    local selectedFavName = nil
    local addFavBtn = CreateFrame("Button", "CleanBotAddFavoriteBtn", NS.targetPanel, "UIPanelButtonTemplate")
    addFavBtn:SetSize(60, 24)
    addFavBtn:SetPoint("TOPLEFT", inviteAllBtn, "BOTTOMLEFT", 0, -8)
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

    -- ── Altbots section ───────────────────────────────────────
    local altLabel = NS.targetPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    altLabel:SetPoint("TOPLEFT", delFavBtn, "BOTTOMLEFT", 0, -20)
    altLabel:SetText("Altbots")

    -- Shared helper: dropdown populated from NS.linkedAccounts.
    -- onSelect(name) called on selection; selection cleared on re-open.
    local function makeAltDropdown(frameName, anchorBtn, onSelect)
        local dd = CreateFrame("Frame", frameName, NS.targetPanel, "UIDropDownMenuTemplate")
        dd:SetPoint("LEFT", anchorBtn, "RIGHT", -10, 0)
        UIDropDownMenu_SetWidth(dd, 150)
        if NS.ElvUI_S then NS.ElvUI_S:HandleDropDownBox(dd, 150) end
        UIDropDownMenu_Initialize(dd, function(self)
            UIDropDownMenu_SetText(dd, "")
            onSelect(nil)
            local accounts = NS.linkedAccounts
            if not accounts or #accounts == 0 then
                local info        = UIDropDownMenu_CreateInfo()
                info.text         = "No accounts found"
                info.notCheckable = 1
                UIDropDownMenu_AddButton(info)
                return
            end
            for _, name in ipairs(accounts) do
                local info = UIDropDownMenu_CreateInfo()
                info.text  = name
                info.value = name
                info.func  = function()
                    UIDropDownMenu_SetText(self, name)
                    onSelect(name)
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        return dd
    end

    -- Link Account (top of section)
    local linkAltBtn = CreateFrame("Button", "CleanBotLinkAltBtn", NS.targetPanel, "UIPanelButtonTemplate")
    linkAltBtn:SetSize(100, 24)
    linkAltBtn:SetPoint("TOPLEFT", altLabel, "BOTTOMLEFT", 0, -8)
    linkAltBtn:SetText("Link Account")
    linkAltBtn:SetScript("OnClick", function()
        StaticPopup_Show("CLEANBOT_LINK_ACCOUNT_NAME")
    end)
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(linkAltBtn) end

    -- Invite All
    local inviteAllAltBtn = CreateFrame("Button", "CleanBotInviteAllAltBtn", NS.targetPanel, "UIPanelButtonTemplate")
    inviteAllAltBtn:SetSize(100, 24)
    inviteAllAltBtn:SetPoint("TOPLEFT", linkAltBtn, "BOTTOMLEFT", 0, -8)
    inviteAllAltBtn:SetText("Invite All")
    inviteAllAltBtn:SetScript("OnClick", function()
        local accounts = NS.linkedAccounts
        if not accounts or #accounts == 0 then
            print("|cffffcc00CleanBot|r: No linked accounts found.")
            return
        end
        for _, name in ipairs(accounts) do
            SendChatMessage(".playerbots bot addaccount " .. name, "SAY")
        end
    end)
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(inviteAllAltBtn) end

    -- Invite Account + dropdown + Refresh List
    local selectedAltAccount = nil
    local addAltBtn = CreateFrame("Button", "CleanBotAddAltBtn", NS.targetPanel, "UIPanelButtonTemplate")
    addAltBtn:SetSize(100, 24)
    addAltBtn:SetPoint("TOPLEFT", inviteAllAltBtn, "BOTTOMLEFT", 0, -8)
    addAltBtn:SetText("Invite Account")
    addAltBtn:SetScript("OnClick", function()
        if not selectedAltAccount then
            print("|cffffcc00CleanBot|r: No account selected.")
            return
        end
        SendChatMessage(".playerbots bot addaccount " .. selectedAltAccount, "SAY")
    end)
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(addAltBtn) end

    local altDD = makeAltDropdown("CleanBotAltAccountDD", addAltBtn,
        function(name) selectedAltAccount = name end)

    local refreshAltBtn = CreateFrame("Button", "CleanBotRefreshAltBtn", NS.targetPanel, "UIPanelButtonTemplate")
    refreshAltBtn:SetSize(100, 24)
    refreshAltBtn:SetPoint("LEFT", altDD, "RIGHT", -10, 0)
    refreshAltBtn:SetText("Refresh List")
    refreshAltBtn:SetScript("OnClick", function()
        NS.CleanBot_FetchLinkedAccounts()
    end)
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(refreshAltBtn) end

    -- Unlink Account + dropdown
    local selectedUnlinkAccount = nil
    local unlinkAltBtn = CreateFrame("Button", "CleanBotUnlinkAltBtn", NS.targetPanel, "UIPanelButtonTemplate")
    unlinkAltBtn:SetSize(100, 24)
    unlinkAltBtn:SetPoint("TOPLEFT", addAltBtn, "BOTTOMLEFT", 0, -8)
    unlinkAltBtn:SetText("Unlink Account")
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(unlinkAltBtn) end

    local unlinkDD = makeAltDropdown("CleanBotUnlinkAccountDD", unlinkAltBtn,
        function(name) selectedUnlinkAccount = name end)

    unlinkAltBtn:SetScript("OnClick", function()
        if not selectedUnlinkAccount then
            print("|cffffcc00CleanBot|r: No account selected.")
            return
        end
        SendChatMessage(".playerbots account unlink " .. selectedUnlinkAccount, "SAY")
        -- Remove from in-memory list
        for i, v in ipairs(NS.linkedAccounts) do
            if strlower(v) == strlower(selectedUnlinkAccount) then
                table.remove(NS.linkedAccounts, i)
                break
            end
        end
        UIDropDownMenu_SetText(unlinkDD, "")
        UIDropDownMenu_SetText(altDD, "")
        selectedUnlinkAccount = nil
        selectedAltAccount    = nil
    end)
end
