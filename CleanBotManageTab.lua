-- ============================================================
-- CleanBotManageTab.lua  —  Manage tab: add / remove bots
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
            NS.CB_Print("Account name cannot be empty.")
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
            NS.CB_Print("Security key cannot be empty.")
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
        NS.CB_Print("Linking account '" .. accountName .. "'...")
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        StaticPopupDialogs["CLEANBOT_LINK_ACCOUNT_KEY"].OnAccept(dialog, dialog.data)
        dialog:Hide()
    end,
}

NS.CleanBot_BuildManageContent = function()
    local COL1_X = NS.PAD
    local COL2_X = NS.PAD + 130

    local function makeBtn(label, xOffset, yOffset, onClick)
        local safeName = label:gsub("%s+", "")
        local btn = NS.CB_CreateButton(NS.managePanel, "CleanBotManage" .. safeName .. "Btn",
                                       label, 120, 24, onClick)
        btn:SetPoint("TOPLEFT", NS.managePanel, "TOPLEFT", xOffset, yOffset)
        return btn
    end

    -- Returns the target's name if it's a valid, existing player; prints an error and returns nil otherwise.
    local function requireValidPlayerTarget()
        if not UnitExists("target") or not UnitIsPlayer("target") then
            NS.CB_Print("No valid player target selected.")
            return nil
        end
        return UnitName("target")
    end

    -- Column 1: party invite/uninvite
    makeBtn("Invite Target", COL1_X, -NS.PAD, function()
        local target = requireValidPlayerTarget()
        if not target then return end
        if UnitIsUnit("target", "player") or UnitInParty("target") then
            NS.CB_Print("Target is already in your party.")
            return
        end
        local isKnownBot = CleanBot_PartyBots[strlower(target)] ~= nil
        if not isKnownBot and not NS.ASSUME_ALL_PARTY_ARE_BOTS then
            NS.CB_Print("Cannot verify '" .. target ..
                  "' is a bot. Enable 'Assume all party members are bots' in Settings.")
            return
        end
        InviteUnit(target)
    end)

    makeBtn("Uninvite Target", COL1_X, -(NS.PAD + 30), function()
        local target = requireValidPlayerTarget()
        if not target then return end
        if not UnitInParty("target") then
            NS.CB_Print("Target is not in your party.")
            return
        end
        if not NS.CleanBot_IsBot("target") then
            NS.CB_Print("Target does not appear to be a bot.")
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
            NS.CB_Print("No bots found in party to remove.")
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
    local favLabel = NS.managePanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    favLabel:SetPoint("TOPLEFT", NS.managePanel, "TOPLEFT", NS.PAD, -(NS.PAD + 120))
    favLabel:SetText("Favorites")

    -- Builds a dropdown populated from provider() (an array of display names).
    -- Selection is cleared on every open, then onSelect(name) fires (with nil on
    -- open, or the chosen name). emptyText shows when the list is empty.
    local function makeListDropdown(frameName, anchorBtn, provider, emptyText, onSelect)
        local dd = NS.CB_CreateDropdown(NS.managePanel, frameName, 150)
        dd:SetPoint("LEFT", anchorBtn, "RIGHT", -10, 0)
        UIDropDownMenu_Initialize(dd, function(self)
            UIDropDownMenu_SetText(dd, "")
            onSelect(nil)
            local items = provider()
            if not items or #items == 0 then
                local info        = UIDropDownMenu_CreateInfo()
                info.text         = emptyText
                info.notCheckable = 1
                UIDropDownMenu_AddButton(info)
                return
            end
            for _, name in ipairs(items) do
                local info  = UIDropDownMenu_CreateInfo()
                info.text   = name
                info.value  = name
                info.func   = function()
                    UIDropDownMenu_SetText(self, name)
                    onSelect(name)
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        return dd
    end

    -- Favorite bot display names (capitalised), drawn from saved vars.
    local function favoritesList()
        local favs = CleanBot_SavedVars and CleanBot_SavedVars.favoriteBots
        local list = {}
        if favs then
            for key in pairs(favs) do
                list[#list + 1] = key:sub(1, 1):upper() .. key:sub(2)
            end
        end
        return list
    end

    local inviteAllBtn = NS.CB_CreateButton(NS.managePanel, "CleanBotInviteAllFavoritesBtn", "Invite All", 80, 24, function()
        local list = favoritesList()
        if #list == 0 then
            NS.CB_Print("No favorites saved.")
            return
        end
        for _, name in ipairs(list) do
            SendChatMessage(".playerbots bot add " .. name, "SAY")
        end
    end)
    inviteAllBtn:SetPoint("TOPLEFT", favLabel, "BOTTOMLEFT", 0, -8)

    local selectedFavName = nil
    local addFavBtn = NS.CB_CreateButton(NS.managePanel, "CleanBotAddFavoriteBtn", "Invite", 60, 24, function()
        if not selectedFavName then
            NS.CB_Print("No favorite selected.")
            return
        end
        SendChatMessage(".playerbots bot add " .. selectedFavName, "SAY")
    end)
    addFavBtn:SetPoint("TOPLEFT", inviteAllBtn, "BOTTOMLEFT", 0, -8)
    local favDD = makeListDropdown("CleanBotFavoritesDD", addFavBtn, favoritesList,
        "No favorites saved", function(name) selectedFavName = name end)

    local selectedDelName = nil
    local delFavBtn = NS.CB_CreateButton(NS.managePanel, "CleanBotDeleteFavoriteBtn", "Delete", 60, 24)
    delFavBtn:SetPoint("TOPLEFT", addFavBtn, "BOTTOMLEFT", 0, -8)
    local delFavDD = makeListDropdown("CleanBotFavoritesDelDD", delFavBtn, favoritesList,
        "No favorites saved", function(name) selectedDelName = name end)
    delFavBtn:SetScript("OnClick", function()
        if not selectedDelName then
            NS.CB_Print("No favorite selected.")
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
    local altLabel = NS.managePanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    altLabel:SetPoint("TOPLEFT", delFavBtn, "BOTTOMLEFT", 0, -20)
    altLabel:SetText("Altbots")

    -- Linked accounts, as stored (already an array of display names).
    local function linkedAccountsList() return NS.linkedAccounts end

    -- Link Account (top of section)
    local linkAltBtn = NS.CB_CreateButton(NS.managePanel, "CleanBotLinkAltBtn", "Link Account", 100, 24, function()
        StaticPopup_Show("CLEANBOT_LINK_ACCOUNT_NAME")
    end)
    linkAltBtn:SetPoint("TOPLEFT", altLabel, "BOTTOMLEFT", 0, -8)

    -- Invite All
    local inviteAllAltBtn = NS.CB_CreateButton(NS.managePanel, "CleanBotInviteAllAltBtn", "Invite All", 100, 24, function()
        local accounts = NS.linkedAccounts
        if not accounts or #accounts == 0 then
            NS.CB_Print("No linked accounts found.")
            return
        end
        for _, name in ipairs(accounts) do
            SendChatMessage(".playerbots bot addaccount " .. name, "SAY")
        end
    end)
    inviteAllAltBtn:SetPoint("TOPLEFT", linkAltBtn, "BOTTOMLEFT", 0, -8)

    -- Invite Account + dropdown + Refresh List
    local selectedAltAccount = nil
    local addAltBtn = NS.CB_CreateButton(NS.managePanel, "CleanBotAddAltBtn", "Invite Account", 100, 24, function()
        if not selectedAltAccount then
            NS.CB_Print("No account selected.")
            return
        end
        SendChatMessage(".playerbots bot addaccount " .. selectedAltAccount, "SAY")
    end)
    addAltBtn:SetPoint("TOPLEFT", inviteAllAltBtn, "BOTTOMLEFT", 0, -8)

    local altDD = makeListDropdown("CleanBotAltAccountDD", addAltBtn, linkedAccountsList,
        "No accounts found", function(name) selectedAltAccount = name end)

    local refreshAltBtn = NS.CB_CreateButton(NS.managePanel, "CleanBotRefreshAltBtn", "Refresh List", 100, 24, function()
        NS.CleanBot_FetchLinkedAccounts()
    end)
    refreshAltBtn:SetPoint("LEFT", altDD, "RIGHT", -10, 0)

    -- Unlink Account + dropdown
    local selectedUnlinkAccount = nil
    local unlinkAltBtn = NS.CB_CreateButton(NS.managePanel, "CleanBotUnlinkAltBtn", "Unlink Account", 100, 24)
    unlinkAltBtn:SetPoint("TOPLEFT", addAltBtn, "BOTTOMLEFT", 0, -8)

    local unlinkDD = makeListDropdown("CleanBotUnlinkAccountDD", unlinkAltBtn, linkedAccountsList,
        "No accounts found", function(name) selectedUnlinkAccount = name end)

    unlinkAltBtn:SetScript("OnClick", function()
        if not selectedUnlinkAccount then
            NS.CB_Print("No account selected.")
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
