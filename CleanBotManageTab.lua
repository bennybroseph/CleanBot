-- ============================================================
-- CleanBotManageTab.lua  —  Manage tab: panel construction,
--                           scroll frame, and bot management UI.
-- ============================================================
local NS = CleanBotNS

-- ── Shared popup helpers ──────────────────────────────────────────────────────
local function CB_PositionPopup(self)
    self:ClearAllPoints()
    self:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
end

-- Registers a StaticPopupDialog with a single edit box, OK/Cancel buttons, and
-- a centred position. onAccept(dialog, data) is called on OK or Enter.
-- Only the prompt text and accept logic vary between popups — everything else
-- is shared boilerplate handled here.
-- Registers a StaticPopupDialog with Yes/No buttons and a centred position.
-- No edit box — purely a confirmation step.
-- onAccept(dialog, data) is called when the user clicks Yes.
-- Pass context to the dialog via StaticPopup_Show(key, nil, nil, data) and
-- read it back as the second argument in onAccept.
NS.CB_RegisterConfirmPopup = function(key, text, onAccept)
    StaticPopupDialogs[key] = {
        text         = text,
        button1      = "Yes",
        button2      = "No",
        timeout      = 0,
        whileDead    = true,
        hideOnEscape = true,
        OnShow       = CB_PositionPopup,
        OnAccept     = onAccept,
    }
end

local function CB_RegisterEditPopup(key, text, onAccept)
    StaticPopupDialogs[key] = {
        text         = text,
        button1      = "OK",
        button2      = "Cancel",
        hasEditBox   = 1,
        timeout      = 0,
        whileDead    = true,
        hideOnEscape = true,
        OnShow       = CB_PositionPopup,
        OnAccept     = onAccept,
        EditBoxOnEnterPressed = function(self)
            local dialog = self:GetParent()
            onAccept(dialog, dialog.data)
            dialog:Hide()
        end,
    }
end

-- ── Popup: invite one or more bots by character name ─────────────────────────
CB_RegisterEditPopup("CLEANBOT_INVITE_BY_NAME",
    "Enter the character name(s) below separated by a comma:",
    function(self)
        local input = self.editBox and self.editBox:GetText()
        input = input and input:match("^%s*(.-)%s*$")
        if not input or input == "" then
            NS.CB_Print("Please enter at least one character name.")
            return
        end
        -- Clean each entry: title-case every word, strip spaces.
        -- e.g. "john doe,  jane smith" → "JohnDoe,JaneSmith"
        local names = {}
        for entry in input:gmatch("[^,]+") do
            entry = entry:match("^%s*(.-)%s*$")
            entry = entry:gsub("(%a)([%a]*)", function(first, rest)
                return first:upper() .. rest:lower()
            end):gsub("%s+", "")
            if entry ~= "" then names[#names + 1] = entry end
        end
        if #names == 0 then
            NS.CB_Print("Please enter at least one character name.")
            return
        end
        SendChatMessage(".playerbots bot add " .. table.concat(names, ","), "SAY")
    end)

-- ── Popup: link account — step 1, account name ───────────────────────────────
CB_RegisterEditPopup("CLEANBOT_LINK_ACCOUNT_NAME",
    "Enter the name of the account to link:",
    function(self)
        local name = self.editBox and self.editBox:GetText()
        name = name and strupper(name:match("^%s*(.-)%s*$"))
        if not name or name == "" then
            NS.CB_Print("Account name cannot be empty.")
            return
        end
        StaticPopup_Show("CLEANBOT_LINK_ACCOUNT_KEY", name, nil, name)
    end)

-- ── Popup: link account — step 2, security key ───────────────────────────────
CB_RegisterEditPopup("CLEANBOT_LINK_ACCOUNT_KEY",
    "Enter the security key for account |cffffd200%s|r:",
    function(self, data)
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
    end)

NS.CleanBot_BuildManageTab = function()
    -- ── Panel, scroll frame, and scroll child ─────────────────────────────────
    NS.managePanel = NS.CB_CreatePanel(NS.contentFrame, "CleanBotManagePanel", 2, "panel")
    NS.managePanel:SetAllPoints(NS.contentFrame)
    NS.managePanel:Hide()

    -- Intermediate container isolates the scroll frame from iborder/oborder child
    -- frames stamped by ElvUI's SetTemplate on managePanel.
    local manageScrollContainer = CreateFrame("Frame", "CleanBotManageScrollContainer",
        NS.managePanel)
    manageScrollContainer:SetAllPoints(NS.managePanel)
    -- Padding mirrors managePanel so CB_CreateScrollFrame can inset correctly.
    manageScrollContainer.paddingTop    = NS.managePanel.paddingTop
    manageScrollContainer.paddingBottom = NS.managePanel.paddingBottom
    manageScrollContainer.paddingLeft   = NS.managePanel.paddingLeft
    manageScrollContainer.paddingRight  = NS.managePanel.paddingRight

    NS.manageScrollFrame, NS.manageScrollChild = NS.CB_CreateScrollFrame(
        manageScrollContainer, "CleanBotManageScrollFrame")
    NS.manageScrollChild:SetHeight(600)

    -- ── Content ───────────────────────────────────────────────────────────────
    -- All manage-tab widgets parent to the scroll child, not the panel frame itself.
    -- Using a local alias keeps call sites concise and avoids panel confusion.
    local panel = NS.manageScrollChild

    local function requireValidPlayerTarget()
        if not UnitExists("target") or not UnitIsPlayer("target") then
            NS.CB_Print("No valid player target selected.")
            return nil
        end
        return UnitName("target")
    end

    -- Builds a dropdown populated from provider() placed to the right of anchorBtn.
    local function makeListDropdown(parent, frameName, anchorBtn, provider, emptyText, onSelect)
        local dd = NS.CB_CreateDropdown(parent, frameName, 150)
        NS.CB_AnchorAhead(dd, anchorBtn)
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

    local function linkedAccountsList() return NS.linkedAccounts end

    -- ── Invite by Name ────────────────────────────────────────
    local inviteByNameBtn = NS.CB_CreateButton(panel, "CleanBotInviteByNameBtn",
        "Invite by Name", 120, 24, function()
            local popup = StaticPopup_Show("CLEANBOT_INVITE_BY_NAME")
            if popup then
                popup:SetWidth(420)
                popup.text:SetWidth(380)
            end
        end)
    inviteByNameBtn:SetPoint("TOPLEFT", panel, "TOPLEFT",
        (panel.paddingLeft or 0) + (inviteByNameBtn.marginLeft or 0),
      -((panel.paddingTop  or 0) + (inviteByNameBtn.marginTop  or 0)))

    -- ── Target section ────────────────────────────────────────
    local targetSection = NS.CB_CreateSection(panel, "target", "Target", 3)
    local tw = targetSection.contentWidgets  -- shorthand for tracking

    local inviteTargetBtn = NS.CB_CreateButton(targetSection.bg, "CleanBotManageInviteTargetBtn",
        "Invite Target", 120, 24, function()
            local target = requireValidPlayerTarget()
            if not target then return end
            if UnitIsUnit("target", "player") or UnitInParty("target") then
                NS.CB_Print("Target is already in your party.")
                return
            end
            InviteUnit(target)
        end)
    inviteTargetBtn:SetPoint("TOPLEFT", targetSection.bg, "TOPLEFT",
        NS.PADDING.section.left  + (inviteTargetBtn.marginLeft or 0),
      -(NS.PADDING.section.top   + (inviteTargetBtn.marginTop  or 0)))
    tw[#tw + 1] = inviteTargetBtn

    local uninviteTargetBtn = NS.CB_CreateButton(targetSection.bg, "CleanBotManageUninviteTargetBtn",
        "Uninvite Target", 120, 24, function()
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
    NS.CB_AnchorBelow(uninviteTargetBtn, inviteTargetBtn)
    tw[#tw + 1] = uninviteTargetBtn

    local uninviteAllBtn = NS.CB_CreateButton(targetSection.bg, "CleanBotManageUninviteAllBtn",
        "Uninvite All", 120, 24, function()
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
    NS.CB_AnchorBelow(uninviteAllBtn, uninviteTargetBtn)
    tw[#tw + 1] = uninviteAllBtn

    local loginTargetBtn = NS.CB_CreateButton(targetSection.bg, "CleanBotManageLoginTargetBtn",
        "Login Target", 120, 24, function()
            local target = requireValidPlayerTarget()
            if not target then return end
            SendChatMessage(".playerbots bot add " .. target, "SAY")
        end)
    loginTargetBtn.marginLeft = NS.COLUMN_GAP
    NS.CB_AnchorAhead(loginTargetBtn, inviteTargetBtn)
    tw[#tw + 1] = loginTargetBtn

    local logoutTargetBtn = NS.CB_CreateButton(targetSection.bg, "CleanBotManageLogoutTargetBtn",
        "Logout Target", 120, 24, function()
            local target = requireValidPlayerTarget()
            if not target then return end
            SendChatMessage(".playerbots bot remove " .. target, "SAY")
        end)
    NS.CB_AnchorBelow(logoutTargetBtn, loginTargetBtn)
    tw[#tw + 1] = logoutTargetBtn

    local logoutAllBtn = NS.CB_CreateButton(targetSection.bg, "CleanBotManageLogoutAllBtn",
        "Logout All", 120, 24, function()
            SendChatMessage(".playerbots bot remove *", "SAY")
        end)
    NS.CB_AnchorBelow(logoutAllBtn, logoutTargetBtn)
    tw[#tw + 1] = logoutAllBtn

    targetSection:Finalize(uninviteAllBtn)  -- deepest col-1 widget; col-2 is same depth

    -- ── Party/Raid section ────────────────────────────────────
    local function CB_SendGroupCommand(cmd)
        if GetNumRaidMembers() > 0 then
            SendChatMessage(cmd, "RAID")
        elseif GetNumPartyMembers() > 0 then
            SendChatMessage(cmd, "PARTY")
        else
            NS.CB_Print("You are not in a party or raid.")
        end
    end

    local partyRaidSection = NS.CB_CreateSection(panel, "partyRaid", "Party/Raid", 3)
    local pw = partyRaidSection.contentWidgets

    local summonBtn = NS.CB_CreateButton(partyRaidSection.bg, "CleanBotManageSummonBtn",
        "Summon", 120, 24, function() CB_SendGroupCommand("summon") end)
    summonBtn:SetPoint("TOPLEFT", partyRaidSection.bg, "TOPLEFT",
        NS.PADDING.section.left  + (summonBtn.marginLeft or 0),
      -(NS.PADDING.section.top   + (summonBtn.marginTop  or 0)))
    pw[#pw + 1] = summonBtn

    local maintenanceBtn = NS.CB_CreateButton(partyRaidSection.bg, "CleanBotManageMaintenanceBtn",
        "Maintenance", 120, 24, function() CB_SendGroupCommand("maintenance") end)
    NS.CB_AnchorBelow(maintenanceBtn, summonBtn)
    pw[#pw + 1] = maintenanceBtn

    local eatDrinkBtn = NS.CB_CreateButton(partyRaidSection.bg, "CleanBotManageEatDrinkBtn",
        "Eat/Drink", 120, 24, function() CB_SendGroupCommand("drink") end)
    NS.CB_AnchorBelow(eatDrinkBtn, maintenanceBtn)
    pw[#pw + 1] = eatDrinkBtn

    local reviveBtn = NS.CB_CreateButton(partyRaidSection.bg, "CleanBotManageReviveBtn",
        "Revive", 120, 24, function() CB_SendGroupCommand("revive") end)
    reviveBtn.marginLeft = NS.COLUMN_GAP
    NS.CB_AnchorAhead(reviveBtn, summonBtn)
    pw[#pw + 1] = reviveBtn

    local releaseBtn = NS.CB_CreateButton(partyRaidSection.bg, "CleanBotManageReleaseBtn",
        "Release", 120, 24, function() CB_SendGroupCommand("release") end)
    NS.CB_AnchorBelow(releaseBtn, reviveBtn)
    pw[#pw + 1] = releaseBtn

    partyRaidSection:Finalize(eatDrinkBtn)  -- col-1 is deeper

    -- ── Favorites section ─────────────────────────────────────
    local favoritesSection = NS.CB_CreateSection(panel, "favorites", "Favorites", 3)
    local fw = favoritesSection.contentWidgets

    local inviteAllBtn = NS.CB_CreateButton(favoritesSection.bg, "CleanBotInviteAllFavoritesBtn",
        "Invite All", 80, 24, function()
            local list = favoritesList()
            if #list == 0 then
                NS.CB_Print("No favorites saved.")
                return
            end
            for _, name in ipairs(list) do
                SendChatMessage(".playerbots bot add " .. name, "SAY")
            end
        end)
    inviteAllBtn:SetPoint("TOPLEFT", favoritesSection.bg, "TOPLEFT",
        NS.PADDING.section.left  + (inviteAllBtn.marginLeft or 0),
      -(NS.PADDING.section.top   + (inviteAllBtn.marginTop  or 0)))
    fw[#fw + 1] = inviteAllBtn

    local selectedFavName = nil
    local addFavBtn = NS.CB_CreateButton(favoritesSection.bg, "CleanBotAddFavoriteBtn",
        "Invite", 60, 24, function()
            if not selectedFavName then
                NS.CB_Print("No favorite selected.")
                return
            end
            SendChatMessage(".playerbots bot add " .. selectedFavName, "SAY")
        end)
    NS.CB_AnchorBelow(addFavBtn, inviteAllBtn)
    fw[#fw + 1] = addFavBtn
    local favDD = makeListDropdown(favoritesSection.bg, "CleanBotFavoritesDD", addFavBtn, favoritesList,
        "No favorites saved", function(name) selectedFavName = name end)
    fw[#fw + 1] = favDD

    local selectedDelName = nil
    local delFavBtn = NS.CB_CreateButton(favoritesSection.bg, "CleanBotDeleteFavoriteBtn", "Remove", 60, 24)
    NS.CB_AnchorBelow(delFavBtn, addFavBtn)
    fw[#fw + 1] = delFavBtn
    local delFavDD = makeListDropdown(favoritesSection.bg, "CleanBotFavoritesDelDD", delFavBtn, favoritesList,
        "No favorites saved", function(name) selectedDelName = name end)
    fw[#fw + 1] = delFavDD
    NS.CB_RegisterConfirmPopup("CLEANBOT_REMOVE_FAVORITE",
        "Are you sure you want to remove '%s' from your favorites?",
        function(self, data)
            local key = strlower(data)
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

    delFavBtn:SetScript("OnClick", function()
        if not selectedDelName then
            NS.CB_Print("No favorite selected.")
            return
        end
        local popup = StaticPopup_Show("CLEANBOT_REMOVE_FAVORITE",
            selectedDelName, nil, selectedDelName)
        if popup then
            popup:SetWidth(420)
            popup.text:SetWidth(380)
        end
    end)

    favoritesSection:Finalize(delFavBtn)

    -- ── Altbots section ───────────────────────────────────────
    local altbotsSection = NS.CB_CreateSection(panel, "altbots", "Altbots", 3)
    local aw = altbotsSection.contentWidgets

    local linkAltBtn = NS.CB_CreateButton(altbotsSection.bg, "CleanBotLinkAltBtn",
        "Link Account", 100, 24, function()
            StaticPopup_Show("CLEANBOT_LINK_ACCOUNT_NAME")
        end)
    linkAltBtn:SetPoint("TOPLEFT", altbotsSection.bg, "TOPLEFT",
        NS.PADDING.section.left  + (linkAltBtn.marginLeft or 0),
      -(NS.PADDING.section.top   + (linkAltBtn.marginTop  or 0)))
    aw[#aw + 1] = linkAltBtn

    local inviteAllAltBtn = NS.CB_CreateButton(altbotsSection.bg, "CleanBotInviteAllAltBtn",
        "Invite All", 100, 24, function()
            local accounts = NS.linkedAccounts
            if not accounts or #accounts == 0 then
                NS.CB_Print("No linked accounts found.")
                return
            end
            for _, name in ipairs(accounts) do
                SendChatMessage(".playerbots bot addaccount " .. name, "SAY")
            end
        end)
    NS.CB_AnchorBelow(inviteAllAltBtn, linkAltBtn)
    aw[#aw + 1] = inviteAllAltBtn

    local selectedAltAccount = nil
    local addAltBtn = NS.CB_CreateButton(altbotsSection.bg, "CleanBotAddAltBtn",
        "Invite Account", 100, 24, function()
            if not selectedAltAccount then
                NS.CB_Print("No account selected.")
                return
            end
            SendChatMessage(".playerbots bot addaccount " .. selectedAltAccount, "SAY")
        end)
    NS.CB_AnchorBelow(addAltBtn, inviteAllAltBtn)
    aw[#aw + 1] = addAltBtn

    local altDD = makeListDropdown(altbotsSection.bg, "CleanBotAltAccountDD", addAltBtn, linkedAccountsList,
        "No accounts found", function(name) selectedAltAccount = name end)
    aw[#aw + 1] = altDD

    local refreshAltBtn = NS.CB_CreateButton(altbotsSection.bg, "CleanBotRefreshAltBtn",
        "Refresh", 60, 24, function()
            NS.CleanBot_FetchLinkedAccounts()
        end)
    NS.CB_AnchorAhead(refreshAltBtn, altDD)
    aw[#aw + 1] = refreshAltBtn

    local selectedUnlinkAccount = nil
    local unlinkAltBtn = NS.CB_CreateButton(altbotsSection.bg, "CleanBotUnlinkAltBtn", "Unlink Account", 100, 24)
    NS.CB_AnchorBelow(unlinkAltBtn, addAltBtn)
    aw[#aw + 1] = unlinkAltBtn

    local unlinkDD = makeListDropdown(altbotsSection.bg, "CleanBotUnlinkAccountDD", unlinkAltBtn, linkedAccountsList,
        "No accounts found", function(name) selectedUnlinkAccount = name end)
    aw[#aw + 1] = unlinkDD

    NS.CB_RegisterConfirmPopup("CLEANBOT_UNLINK_ACCOUNT",
        "Are you sure you want to unlink the '%s' account?",
        function(self, data)
            SendChatMessage(".playerbots account unlink " .. data, "SAY")
            for i, v in ipairs(NS.linkedAccounts) do
                if strlower(v) == strlower(data) then
                    table.remove(NS.linkedAccounts, i)
                    break
                end
            end
            UIDropDownMenu_SetText(unlinkDD, "")
            UIDropDownMenu_SetText(altDD, "")
            selectedUnlinkAccount = nil
            selectedAltAccount    = nil
        end)

    unlinkAltBtn:SetScript("OnClick", function()
        if not selectedUnlinkAccount then
            NS.CB_Print("No account selected.")
            return
        end
        local popup = StaticPopup_Show("CLEANBOT_UNLINK_ACCOUNT",
            selectedUnlinkAccount, nil, selectedUnlinkAccount)
        if popup then
            popup:SetWidth(420)
            popup.text:SetWidth(380)
        end
    end)

    altbotsSection:Finalize(unlinkAltBtn)

    -- ── Presets section ───────────────────────────────────────
    -- SavedVars shape:
    --   CleanBot_SavedVars.presets = {
    --       ["PresetName"] = { "BotName1", "BotName2", ... },
    --   }
    -- Left list: preset names. Right list: bots in the selected preset.
    -- Col-2 buttons anchor independently below presetList2 so both columns
    -- stay vertically aligned regardless of button label width differences.

    local presetsSection = NS.CB_CreateSection(panel, "presets", "Presets", 3)
    local prw = presetsSection.contentWidgets

    -- Title-cases a single name and strips spaces.
    -- e.g. "john doe" → "JohnDoe"  (matches the bot add command convention)
    local function titleCaseName(str)
        return str:gsub("(%a)([%a]*)", function(first, rest)
            return first:upper() .. rest:lower()
        end):gsub("%s+", "")
    end

    local selectedPresetName = nil
    local presetList2  -- forward-declared; assigned before any onSelect fires

    -- ── Row 1: Invite buttons ─────────────────────────────
    local invitePresetBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotInvitePresetBtn",
        "Invite Preset", 110, 24)
    invitePresetBtn:SetPoint("TOPLEFT", presetsSection.bg, "TOPLEFT",
        NS.PADDING.section.left  + (invitePresetBtn.marginLeft or 0),
      -(NS.PADDING.section.top   + (invitePresetBtn.marginTop  or 0)))
    prw[#prw + 1] = invitePresetBtn

    local inviteBotBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotPresetInviteBotBtn",
        "Invite Bot", 110, 24)
    inviteBotBtn.marginLeft = NS.COLUMN_GAP
    NS.CB_AnchorAhead(inviteBotBtn, invitePresetBtn)
    prw[#prw + 1] = inviteBotBtn

    -- ── Row 2: Selectable lists ───────────────────────────
    local presetList1 = NS.CB_CreateSelectList(presetsSection.bg, "CleanBotPresetList1", 160, 104,
        function(name)
            selectedPresetName = name
            local entries = (CleanBot_SavedVars.presets or {})[name] or {}
            presetList2:SetItems(entries)
        end)
    NS.CB_AnchorBelow(presetList1, invitePresetBtn)
    prw[#prw + 1] = presetList1

    presetList2 = NS.CB_CreateSelectList(presetsSection.bg, "CleanBotPresetList2", 160, 104)
    presetList2.marginLeft = NS.COLUMN_GAP
    NS.CB_AnchorAhead(presetList2, presetList1)
    prw[#prw + 1] = presetList2

    -- Re-anchor Invite Bot so its left edge aligns with presetList2 rather than
    -- sitting offset from invitePresetBtn. Pin BOTTOMLEFT → presetList2 TOPLEFT
    -- with the combined facing margins as the gap (mirror of CB_AnchorBelow).
    inviteBotBtn:ClearAllPoints()
    inviteBotBtn:SetPoint("BOTTOMLEFT", presetList2, "TOPLEFT",
        0, (presetList2.marginTop or 0) + (inviteBotBtn.marginBottom or 0))

    -- ── Col-1 buttons (below presetList1) ─────────────────
    local addPresetBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotAddPresetBtn",
        "Add Preset", 110, 24)
    NS.CB_AnchorBelow(addPresetBtn, presetList1)
    prw[#prw + 1] = addPresetBtn

    local renamePresetBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotRenamePresetBtn",
        "Rename Preset", 110, 24)
    NS.CB_AnchorBelow(renamePresetBtn, addPresetBtn)
    prw[#prw + 1] = renamePresetBtn

    local removePresetBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotRemovePresetBtn",
        "Remove Preset", 110, 24)
    NS.CB_AnchorBelow(removePresetBtn, renamePresetBtn)
    prw[#prw + 1] = removePresetBtn

    -- ── Col-2 buttons (independently anchored below presetList2) ──────────────
    local addBotBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotPresetAddBotBtn",
        "Add Bot", 110, 24)
    NS.CB_AnchorBelow(addBotBtn, presetList2)
    prw[#prw + 1] = addBotBtn

    local renameBotBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotPresetRenameBotBtn",
        "Rename Bot", 110, 24)
    NS.CB_AnchorBelow(renameBotBtn, addBotBtn)
    prw[#prw + 1] = renameBotBtn

    local removeBotBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotPresetRemoveBotBtn",
        "Remove Bot", 110, 24)
    NS.CB_AnchorBelow(removeBotBtn, renameBotBtn)
    prw[#prw + 1] = removeBotBtn

    presetsSection:Finalize(removePresetBtn)  -- col-1 deepest; both cols same row count

    -- ── Helpers ───────────────────────────────────────────

    -- Rebuilds the left list from saved vars, sorted alphabetically.
    -- Clears selection and the right list since the active preset is no longer reliable.
    local function refreshPresetList()
        local presets = CleanBot_SavedVars and CleanBot_SavedVars.presets or {}
        local names = {}
        for k in pairs(presets) do names[#names + 1] = k end
        table.sort(names)
        presetList1:SetItems(names)
        presetList2:SetItems({})
        selectedPresetName = nil
    end

    -- Re-populates the right list from the currently selected preset's entries.
    local function refreshPresetEntries()
        if not selectedPresetName then return end
        local entries = (CleanBot_SavedVars.presets or {})[selectedPresetName] or {}
        presetList2:SetItems(entries)
    end

    -- ── Popups ────────────────────────────────────────────

    CB_RegisterEditPopup("CLEANBOT_ADD_PRESET",
        "Enter a name for the new preset:",
        function(self)
            local name = self.editBox and self.editBox:GetText()
            name = name and name:match("^%s*(.-)%s*$")
            if not name or name == "" then
                NS.CB_Print("Please enter a preset name.")
                return
            end
            if not CleanBot_SavedVars.presets then CleanBot_SavedVars.presets = {} end
            if CleanBot_SavedVars.presets[name] then
                NS.CB_Print("A preset named '" .. name .. "' already exists.")
                return
            end
            CleanBot_SavedVars.presets[name] = {}
            refreshPresetList()
        end)

    CB_RegisterEditPopup("CLEANBOT_RENAME_PRESET",
        "Enter a new name for the '%s' preset:",
        function(self, data)
            local newName = self.editBox and self.editBox:GetText()
            newName = newName and newName:match("^%s*(.-)%s*$")
            if not newName or newName == "" then
                NS.CB_Print("Please enter a preset name.")
                return
            end
            local oldName = data
            if not oldName or not CleanBot_SavedVars.presets then return end
            if CleanBot_SavedVars.presets[newName] then
                NS.CB_Print("A preset named '" .. newName .. "' already exists.")
                return
            end
            CleanBot_SavedVars.presets[newName] = CleanBot_SavedVars.presets[oldName]
            CleanBot_SavedVars.presets[oldName] = nil
            refreshPresetList()
        end)

    NS.CB_RegisterConfirmPopup("CLEANBOT_REMOVE_PRESET",
        "Are you sure you want to remove the '%s' preset?",
        function(self, data)
            if data and CleanBot_SavedVars.presets then
                CleanBot_SavedVars.presets[data] = nil
            end
            refreshPresetList()
        end)

    CB_RegisterEditPopup("CLEANBOT_ADD_BOT_TO_PRESET",
        "Enter a bot name to add to the '%s' preset:",
        function(self)
            local botName = self.editBox and self.editBox:GetText()
            botName = botName and botName:match("^%s*(.-)%s*$")
            if not botName or botName == "" then
                NS.CB_Print("Please enter a bot name.")
                return
            end
            if not selectedPresetName then return end
            local preset = CleanBot_SavedVars.presets
                and CleanBot_SavedVars.presets[selectedPresetName]
            if not preset then return end
            for _, v in ipairs(preset) do
                if strlower(v) == strlower(botName) then
                    NS.CB_Print("'" .. botName .. "' is already in this preset.")
                    return
                end
            end
            preset[#preset + 1] = botName
            refreshPresetEntries()
        end)

    CB_RegisterEditPopup("CLEANBOT_RENAME_BOT_IN_PRESET",
        "Enter a new name for '%s':",
        function(self, data)
            local newName = self.editBox and self.editBox:GetText()
            newName = newName and newName:match("^%s*(.-)%s*$")
            if not newName or newName == "" then
                NS.CB_Print("Please enter a bot name.")
                return
            end
            local oldName = data
            if not oldName or not selectedPresetName then return end
            local preset = CleanBot_SavedVars.presets
                and CleanBot_SavedVars.presets[selectedPresetName]
            if not preset then return end
            for _, v in ipairs(preset) do
                if strlower(v) == strlower(newName) then
                    NS.CB_Print("'" .. newName .. "' is already in this preset.")
                    return
                end
            end
            for i, v in ipairs(preset) do
                if v == oldName then
                    preset[i] = newName
                    break
                end
            end
            refreshPresetEntries()
        end)

    NS.CB_RegisterConfirmPopup("CLEANBOT_REMOVE_BOT_FROM_PRESET",
        "Are you sure you want to remove '%s' from the '%s' preset?",
        function(self, data)
            if not selectedPresetName then return end
            local preset = CleanBot_SavedVars.presets
                and CleanBot_SavedVars.presets[selectedPresetName]
            if not preset then return end
            for i, v in ipairs(preset) do
                if v == data then
                    table.remove(preset, i)
                    break
                end
            end
            refreshPresetEntries()
        end)

    -- ── Button handlers ───────────────────────────────────

    invitePresetBtn:SetScript("OnClick", function()
        if not selectedPresetName then
            NS.CB_Print("No preset selected.")
            return
        end
        local preset = CleanBot_SavedVars.presets
            and CleanBot_SavedVars.presets[selectedPresetName]
        if not preset or #preset == 0 then
            NS.CB_Print("This preset has no bots.")
            return
        end
        local names = {}
        for _, v in ipairs(preset) do
            names[#names + 1] = titleCaseName(v)
        end
        SendChatMessage(".playerbots bot add " .. table.concat(names, ","), "SAY")
    end)

    inviteBotBtn:SetScript("OnClick", function()
        local selected = presetList2:GetSelected()
        if not selected then
            NS.CB_Print("No bot selected.")
            return
        end
        SendChatMessage(".playerbots bot add " .. titleCaseName(selected), "SAY")
    end)

    addPresetBtn:SetScript("OnClick", function()
        StaticPopup_Show("CLEANBOT_ADD_PRESET")
    end)

    renamePresetBtn:SetScript("OnClick", function()
        local selected = presetList1:GetSelected()
        if not selected then
            NS.CB_Print("No preset selected.")
            return
        end
        StaticPopup_Show("CLEANBOT_RENAME_PRESET", selected, nil, selected)
    end)

    removePresetBtn:SetScript("OnClick", function()
        local selected = presetList1:GetSelected()
        if not selected then
            NS.CB_Print("No preset selected.")
            return
        end
        local popup = StaticPopup_Show("CLEANBOT_REMOVE_PRESET", selected, nil, selected)
        if popup then
            popup:SetWidth(420)
            popup.text:SetWidth(380)
        end
    end)

    addBotBtn:SetScript("OnClick", function()
        if not selectedPresetName then
            NS.CB_Print("No preset selected.")
            return
        end
        StaticPopup_Show("CLEANBOT_ADD_BOT_TO_PRESET", selectedPresetName)
    end)

    renameBotBtn:SetScript("OnClick", function()
        if not selectedPresetName then
            NS.CB_Print("No preset selected.")
            return
        end
        local selected = presetList2:GetSelected()
        if not selected then
            NS.CB_Print("No bot selected.")
            return
        end
        StaticPopup_Show("CLEANBOT_RENAME_BOT_IN_PRESET", selected, nil, selected)
    end)

    removeBotBtn:SetScript("OnClick", function()
        if not selectedPresetName then
            NS.CB_Print("No preset selected.")
            return
        end
        local selected = presetList2:GetSelected()
        if not selected then
            NS.CB_Print("No bot selected.")
            return
        end
        local popup = StaticPopup_Show("CLEANBOT_REMOVE_BOT_FROM_PRESET",
            selected, selectedPresetName, selected)
        if popup then
            popup:SetWidth(420)
            popup.text:SetWidth(380)
        end
    end)

    refreshPresetList()  -- populate from saved vars on load

    -- ── Content height ────────────────────────────────────────────────────────
    local function updateContentHeight()
        local scrollTop  = NS.manageScrollChild:GetTop()
        local lastAnchor = presetsSection:GetAnchor()
        local lastBottom = lastAnchor and lastAnchor:GetBottom()
        if not (scrollTop and lastBottom) then return end
        local contentH = scrollTop - lastBottom
            + (lastAnchor.marginBottom or 0) + (panel.paddingBottom or 0)
        local frameH = NS.manageScrollFrame:GetHeight() or 0
        NS.manageScrollChild:SetHeight(math.max(contentH, frameH))
    end

    -- Schedules a one-shot OnUpdate that updates section backgrounds and scroll
    -- height once anchors and layout have resolved (GetTop/GetBottom need one
    -- rendered frame before they return valid values).
    local function scheduleUpdate()
        NS.manageScrollChild:SetScript("OnUpdate", function(self)
            self:SetScript("OnUpdate", nil)
            targetSection:UpdateBackground()
            partyRaidSection:UpdateBackground()
            favoritesSection:UpdateBackground()
            altbotsSection:UpdateBackground()
            presetsSection:UpdateBackground()
            updateContentHeight()
        end)
    end

    -- ── Reflow: re-anchor section headers after any collapse/expand ───────────
    -- Hidden widgets still occupy their anchor positions in WoW, leaving a gap
    -- when a section collapses. Reflow fixes this by re-setting each section
    -- header's TOPLEFT to the last *visible* widget of the section above it.
    -- Called once at the end to correct any saved collapsed state, then wired
    -- into each section's onToggle so it fires on every expand/collapse.
    -- Section toggle buttons chain Y from the previous visible widget but must
    -- always align X with the panel left wall — not inherit X from content
    -- widgets inside a section bg (which are inset by NS.PADDING.section.left).
    -- Two-anchor approach: LEFT pins X to panel; TOP pins Y to the above widget.
    local function anchorToggle(toggleBtn, above)
        local gap = (above.marginBottom or 0) + (toggleBtn.marginTop or 0)
        toggleBtn:ClearAllPoints()
        toggleBtn:SetPoint("LEFT", panel, "LEFT",
            (panel.paddingLeft or 0) + (toggleBtn.marginLeft or 0), 0)
        toggleBtn:SetPoint("TOP", above, "BOTTOM", 0, -gap)
    end

    local function reflow()
        anchorToggle(targetSection.toggleBtn,    inviteByNameBtn)
        anchorToggle(partyRaidSection.toggleBtn, targetSection:GetAnchor())
        anchorToggle(favoritesSection.toggleBtn, partyRaidSection:GetAnchor())
        anchorToggle(altbotsSection.toggleBtn,   favoritesSection:GetAnchor())
        anchorToggle(presetsSection.toggleBtn,   altbotsSection:GetAnchor())
        scheduleUpdate()
    end

    targetSection.onToggle    = reflow
    partyRaidSection.onToggle = reflow
    favoritesSection.onToggle = reflow
    altbotsSection.onToggle   = reflow
    presetsSection.onToggle   = reflow

    reflow()
    scheduleUpdate()  -- initial deferred pass: backgrounds + height after first render
end
