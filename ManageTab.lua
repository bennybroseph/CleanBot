-- ============================================================
-- ManageTab.lua  —  Manage tab: panel construction,
--                           scroll frame, and bot management UI.
-- ============================================================
local NS = CleanBotNS

-- ── Shared popup helpers ──────────────────────────────────────────────────────
---@param self table  The popup frame to position on screen.
local function CB_PositionPopup(self)
    self:ClearAllPoints()
    self:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
end

-- Registers a StaticPopupDialog with a single edit box, OK/Cancel buttons, and
-- a centered position. onAccept(dialog, data) is called on OK or Enter.
-- Only the prompt text and accept logic vary between popups — everything else
-- is shared boilerplate handled here.
-- Registers a StaticPopupDialog with Yes/No buttons and a centered position.
-- No edit box — purely a confirmation step.
-- onAccept(dialog, data) is called when the user clicks Yes.
-- Pass context to the dialog via StaticPopup_Show(key, nil, nil, data) and
-- read it back as the second argument in onAccept.
---@param key      string  Unique popup key (StaticPopupDialogs entry name).
---@param text      string  Confirmation prompt text.
---@param onAccept  fun()   Called when the user confirms.
---@param onCancel fun(self:table, data:any, reason:string)?  Called when the user clicks No.
NS.CB_RegisterConfirmPopup = function(key, text, onAccept, onCancel)
    StaticPopupDialogs[key] = {
        text         = text,
        button1      = "Yes",
        button2      = "No",
        timeout      = 0,
        whileDead    = true,
        hideOnEscape = true,
        -- Escape must NOT run onCancel. In 3.3.5a StaticPopup_EscapePressed calls
        -- OnCancel(frame, data, "clicked"), which is indistinguishable from a real No
        -- click — so an onCancel that performs an action (e.g. linking with no key) would
        -- fire on Escape. noCancelOnEscape makes Escape hide-only (a clean abort).
        noCancelOnEscape = true,
        OnShow       = CB_PositionPopup,
        OnAccept     = onAccept,
        OnCancel     = onCancel,
    }
end

---@param key      string             Unique popup key (StaticPopupDialogs entry name).
---@param text      string             Prompt text shown above the edit box.
---@param onAccept  fun(value:string)  Called with the entered text on confirm.
NS.CB_RegisterEditPopup = function(key, text, onAccept)
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
-- Local alias for this file's own popup registrations; exported on NS so other
-- tabs (GroupTab) can reuse the same edit-popup boilerplate.
local CB_RegisterEditPopup = NS.CB_RegisterEditPopup

-- ── Reusable "copy this text" popup ──────────────────────────────────────────
-- Default Blizzard StaticPopup styling with a wide, pre-selected edit box so the text
-- copies with a single Ctrl+C, plus an optional caption/body. Made draggable without
-- restyling; re-centers on each open (StaticPopups don't persist a dragged position).
-- hasWideEditBox gives the 420px dialog + wide box — the widening is applied in
-- StaticPopup_Resize (which runs AFTER OnShow), so the flag, not a manual SetWidth, must
-- do it. The caption width is bumped in OnShow before Resize recomputes the height.
StaticPopupDialogs["CLEANBOT_COPY"] = {
    text           = "%s",
    button1        = "Close",
    -- hasWideEditBox only takes effect when hasEditBox is also set: the framework gates the
    -- whole edit-box show block on hasEditBox, then picks the wide box inside it.
    hasEditBox     = 1,
    hasWideEditBox = 1,
    timeout        = 0,
    whileDead      = true,
    hideOnEscape   = true,
    EditBoxOnEnterPressed  = function(self) self:GetParent():Hide() end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    OnShow = function(self, data)
        CB_PositionPopup(self)
        -- Make it draggable. Cleared in OnHide because StaticPopup frames are pooled and
        -- would otherwise stay draggable when reused by other dialogs.
        self:SetMovable(true)
        self:RegisterForDrag("LeftButton")
        self:SetScript("OnDragStart", self.StartMoving)
        self:SetScript("OnDragStop",  self.StopMovingOrSizing)
        -- Widen the caption past the template's 290px so it wraps less awkwardly.
        local text = _G[self:GetName() .. "Text"]
        if text then text:SetWidth(380) end
        local eb = _G[self:GetName() .. "WideEditBox"]
        if eb then
            -- Read-only: the wide edit box (unlike the narrow one) does NOT route
            -- OnTextChanged through StaticPopup's per-dialog hook, so set a revert handler
            -- directly here and restore the original in OnHide (pooled frame, shared with
            -- Blizzard autocomplete dialogs). Reverting keeps focus/selection/Ctrl+C; only
            -- edits are undone. The re-SetText fires this again but GetText == text, so it stops.
            eb.cbCopyText = data
            eb.cbOrigOTC  = eb:GetScript("OnTextChanged")
            eb:SetScript("OnTextChanged", function(box)
                if box.cbCopyText and box:GetText() ~= box.cbCopyText then
                    box:SetText(box.cbCopyText)
                    box:HighlightText()
                end
            end)
            -- Fill + select the copy text (Ctrl+C copies it all even if it scrolls).
            eb:SetText(data or "")
            eb:SetFocus()
            eb:HighlightText()
            -- The wide box is CENTER-anchored by default, which a multi-line caption
            -- overlaps. Center it between the caption and the button instead. Deferred a
            -- frame because StaticPopup_Resize finalizes the caption height and button
            -- position right AFTER OnShow; anchored to the dialog so it tracks dragging.
            if NS.CB_After then
                NS.CB_After(0, function()
                    if not self:IsShown() then return end
                    local btn1 = _G[self:GetName() .. "Button1"]
                    local tb, bt, db = text and text:GetBottom(), btn1 and btn1:GetTop(), self:GetBottom()
                    if tb and bt and db then
                        eb:ClearAllPoints()
                        eb:SetPoint("CENTER", self, "BOTTOM", 0, (tb + bt) / 2 - db)
                    end
                end)
            end
        end
    end,
    OnHide = function(self)
        self:SetScript("OnDragStart", nil)
        self:SetScript("OnDragStop",  nil)
        self:SetMovable(false)
        self:RegisterForDrag()
        -- Restore the template's default edit-box anchor + OnTextChanged handler
        -- (frames are pooled/reused by other dialogs, incl. autocomplete ones).
        local eb = _G[self:GetName() .. "WideEditBox"]
        if eb then
            eb:SetScript("OnTextChanged", eb.cbOrigOTC)
            eb.cbOrigOTC  = nil
            eb.cbCopyText = nil
            eb:ClearAllPoints()
            eb:SetPoint("CENTER")
        end
    end,
}

-- Shows the reusable copy popup with `copyText` pre-selected in the edit box.
---@param opts table  { copyText:string (required), title:string?, body:string? }
NS.CB_ShowCopyPopup = function(opts)
    if not opts or not opts.copyText then return end
    local display = opts.title or ""
    if opts.body and opts.body ~= "" then
        display = (display ~= "" and (display .. "\n\n") or "") .. opts.body
    end
    StaticPopup_Show("CLEANBOT_COPY", display, nil, opts.copyText)
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

-- Sends the account-link command and records the account in the in-memory linked list.
-- mod-playerbots requires a security key — the target account must have run
-- `.playerbots account setKey <key>` and the same key must be supplied here — so there is
-- no keyless link path (see CB_RegisterConfirmPopup "CLEANBOT_LINK_ACCOUNT_HASKEY" below).
---@param accountName string  The account to link.
---@param key string         The security key set on that account.
local function CB_FinishAccountLink(accountName, key)
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
end

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
        StaticPopup_Show("CLEANBOT_LINK_ACCOUNT_HASKEY", nil, nil, name)
    end)

-- ── Popup: link account — step 2, did the account set a security key? ─────────
-- mod-playerbots only links accounts that have a security key, and the key is set on the
-- account itself (`.playerbots account setKey <key>`, which targets the logged-in account).
-- Yes → ask for the key (step 3). No → guidance: the alt must set a key first (we can't do
-- it from here). Escape aborts (noCancelOnEscape); the reason guard ignores non-click cancels.
NS.CB_RegisterConfirmPopup("CLEANBOT_LINK_ACCOUNT_HASKEY",
    "Did you set a security key for the account?",
    function(self, data)
        StaticPopup_Show("CLEANBOT_LINK_ACCOUNT_KEY", data, nil, data)
    end,
    function(self, data, reason)
        -- No → the alt has no key yet. It must set one while logged into that account
        -- (setKey targets the logged-in account), so show the command in a copyable box.
        if reason == "clicked" then
            NS.CB_ShowCopyPopup({
                title    = "Security key required",
                body     = "Account |cffffd200" .. tostring(data) .. "|r needs a security key before it can be linked.\n"
                        .. "Copy the following command (Ctrl + C), log into the account, "
                        .. "paste the command into the chat (Ctrl + V), then come back here and use the key you entered.",
                copyText = ".playerbots account setKey <key>",
            })
        end
    end)

-- ── Popup: link account — step 3, security key ───────────────────────────────
CB_RegisterEditPopup("CLEANBOT_LINK_ACCOUNT_KEY",
    "Enter the security key for account |cffffd200%s|r:",
    function(self, data)
        local key = self.editBox and self.editBox:GetText()
        key = key and key:match("^%s*(.-)%s*$")
        if not key or key == "" then
            NS.CB_Print("Security key cannot be empty.")
            return
        end
        CB_FinishAccountLink(data, key)
    end)

--- Builds the Manage tab panel: scroll frame, sections, and bot management controls.
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

    local function linkedAccountsList() return NS.linkedAccounts end

    -- ── Invite by Name ────────────────────────────────────
    local inviteByNameBtn = NS.CB_CreateButton(panel, "CleanBotInviteByNameBtn",
        "Invite by Name", 120, 24, function()
            local popup = StaticPopup_Show("CLEANBOT_INVITE_BY_NAME")
            if popup then
                popup:SetWidth(420)
                popup.text:SetWidth(380)
            end
        end)
    NS.CB_AnchorWall(inviteByNameBtn, panel, "TOPLEFT")

    -- ── Target section ────────────────────────────────────
    local targetSection = NS.CB_CreateSection(panel, "target", "Target", 3)

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

    local uninviteAllBtn = NS.CB_CreateButton(targetSection.bg, "CleanBotManageUninviteAllBtn",
        "Uninvite All", 120, 24, function()
            local removed = 0
            NS.CB_ForEachGroupMember(function(unit, name)
                if name and UnitExists(unit) and NS.CleanBot_IsBot(unit) then
                    UninviteUnit(name)
                    removed = removed + 1
                end
            end)
            if removed == 0 then
                NS.CB_Print("No bots found in party or raid to remove.")
            end
        end)
    NS.CB_AnchorBelow(uninviteAllBtn, uninviteTargetBtn)

    local loginTargetBtn = NS.CB_CreateButton(targetSection.bg, "CleanBotManageLoginTargetBtn",
        "Login Target", 120, 24, function()
            local target = requireValidPlayerTarget()
            if not target then return end
            SendChatMessage(".playerbots bot add " .. target, "SAY")
        end)
    NS.CB_AnchorAhead(loginTargetBtn, inviteTargetBtn)

    local logoutTargetBtn = NS.CB_CreateButton(targetSection.bg, "CleanBotManageLogoutTargetBtn",
        "Logout Target", 120, 24, function()
            local target = requireValidPlayerTarget()
            if not target then return end
            SendChatMessage(".playerbots bot remove " .. target, "SAY")
        end)
    NS.CB_AnchorAhead(logoutTargetBtn, uninviteTargetBtn)

    local logoutAllBtn = NS.CB_CreateButton(targetSection.bg, "CleanBotManageLogoutAllBtn",
        "Logout All", 120, 24, function()
            SendChatMessage(".playerbots bot remove *", "SAY")
        end)
    NS.CB_AnchorAhead(logoutAllBtn, uninviteAllBtn)

    targetSection:Finalize(uninviteAllBtn)  -- deepest col-1 widget; col-2 is same depth

    -- ── Party/Raid section ────────────────────────────────
    -- Shared command set (Summon/Maintenance/Eat-Drink/Revive/Release + Formation),
    -- also used by the Individual/Group "Commands" inner tab. Manage broadcasts to
    -- the whole party/raid (no single selection here).
    local partyRaidSection = NS.CB_CreateSection(panel, "partyRaid", "Party/Raid", 3)
    local partyRaidDeepest = NS.CB_BuildPartyRaidCommands(partyRaidSection.bg, "Manage",
        function(cmd) NS.CB_SendGroupCommand(cmd) end,
        function() return "your party/raid bots'" end,
        nil, nil,  -- formation stays action-only (broadcast, no aggregate display)
        NS.CB_GetGroupPassive,   -- passive: OR over the group — checked when ANY bot is passive
        function(on)             -- blanket flip the cache (the command set sends co +/-passive itself)
            NS.CB_ForEachGroupMember(function(_, name)
                local e = name and CleanBot_PartyBots[strlower(name)]
                if e then e.combat = e.combat or {}; e.combat.passive = on end
            end)
        end,
        function() return NS.desiredBots end)   -- gear commands refetch any roster bot with a live model
    partyRaidSection:Finalize(partyRaidDeepest)

    -- ── Favorites/Presets section ─────────────────────────
    -- SavedVars shape:
    --   CleanBot_SavedVars.presets = {
    --       ["Favorites"] = { "BotName1", ... },   ← protected; seeded on init
    --       ["PresetName"] = { "BotName1", ... },
    --   }
    -- "Favorites" is the protected preset populated by the Individual tab star buttons.
    -- It cannot be renamed or removed. Left list: preset names. Right list: bots in
    -- the selected preset. Col-2 buttons anchor independently below presetList2 so
    -- both columns stay vertically aligned regardless of button label width differences.

    local FAVORITES_KEY = "Favorites"  -- protected preset name; guards reference this

    local presetsSection = NS.CB_CreateSection(panel, "presets", "Favorites/Presets", 3)

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

    local inviteBotBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotPresetInviteBotBtn",
        "Invite Bot", 110, 24)
    inviteBotBtn.marginLeft = NS.COLUMN_GAP
    NS.CB_AnchorAhead(inviteBotBtn, invitePresetBtn)

    -- ── Row 2: Selectable lists ───────────────────────────
    local presetList1 = NS.CB_CreateSelectList(presetsSection.bg, "CleanBotPresetList1", 155, 104,
        function(name)
            selectedPresetName = name
            local entries = (CleanBot_SavedVars.presets or {})[name] or {}
            presetList2:SetItems(entries)
        end)
    NS.CB_AnchorBelow(presetList1, invitePresetBtn)

    presetList2 = NS.CB_CreateSelectList(presetsSection.bg, "CleanBotPresetList2", 155, 104)
    presetList2.marginLeft = NS.COLUMN_GAP
    NS.CB_AnchorAhead(presetList2, presetList1)

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

    local renamePresetBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotRenamePresetBtn",
        "Rename Preset", 110, 24)
    NS.CB_AnchorBelow(renamePresetBtn, addPresetBtn)

    local removePresetBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotRemovePresetBtn",
        "Remove Preset", 110, 24)
    NS.CB_AnchorBelow(removePresetBtn, renamePresetBtn)

    -- ── Col-2 buttons (aligned under presetList2's left edge) ─────────────────
    -- CB_AnchorBelow pins X to the parent's left wall (single-column flow), so the
    -- right column can't use it — it is anchored explicitly to presetList2 and then
    -- chained BOTTOMLEFT→TOPLEFT (X inherited from the button above), using the same
    -- gap formula (above.marginBottom + widget.marginTop) so spacing matches col-1.
    local addBotBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotPresetAddBotBtn",
        "Add Bot", 110, 24)
    addBotBtn:SetPoint("TOPLEFT", presetList2, "BOTTOMLEFT",
        0, -((presetList2.marginBottom or 0) + (addBotBtn.marginTop or 0)))

    local renameBotBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotPresetRenameBotBtn",
        "Rename Bot", 110, 24)
    renameBotBtn:SetPoint("TOPLEFT", addBotBtn, "BOTTOMLEFT",
        0, -((addBotBtn.marginBottom or 0) + (renameBotBtn.marginTop or 0)))

    local removeBotBtn = NS.CB_CreateButton(presetsSection.bg, "CleanBotPresetRemoveBotBtn",
        "Remove Bot", 110, 24)
    removeBotBtn:SetPoint("TOPLEFT", renameBotBtn, "BOTTOMLEFT",
        0, -((renameBotBtn.marginBottom or 0) + (removeBotBtn.marginTop or 0)))

    presetsSection:Finalize(removePresetBtn)  -- col-1 deepest; both cols same row count

    -- ── Helpers ───────────────────────────────────────────

    -- Rebuilds the left list from saved vars. "Favorites" is pinned at the top;
    -- all other presets are sorted alphabetically below it.
    -- Clears selection and the right list since the active preset is no longer reliable.
    local function refreshPresetList()
        local presets = CleanBot_SavedVars and CleanBot_SavedVars.presets or {}
        local names = {}
        for k in pairs(presets) do
            if k ~= FAVORITES_KEY then names[#names + 1] = k end
        end
        table.sort(names)
        -- Pin Favorites at position 1 if it exists.
        if presets[FAVORITES_KEY] then
            table.insert(names, 1, FAVORITES_KEY)
        end
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
            if name == FAVORITES_KEY then
                NS.CB_Print("'" .. FAVORITES_KEY .. "' is a protected preset and cannot be created manually.")
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
            -- Belt-and-suspenders guard: the button handler checks first.
            if oldName == FAVORITES_KEY then
                NS.CB_Print("'" .. FAVORITES_KEY .. "' is a protected preset and cannot be renamed.")
                return
            end
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
            -- Belt-and-suspenders guard: the button handler checks first.
            if data == FAVORITES_KEY then
                NS.CB_Print("'" .. FAVORITES_KEY .. "' is a protected preset and cannot be removed.")
                return
            end
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
            -- If adding to Favorites, refresh the star on any matching Individual tab slot.
            if selectedPresetName == FAVORITES_KEY then
                local key = strlower(botName)
                if NS.botStarUpdaters and NS.botStarUpdaters[key] then
                    NS.botStarUpdaters[key]()
                end
            end
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
            -- If renaming within Favorites, refresh stars for both old and new key.
            if selectedPresetName == FAVORITES_KEY then
                local oldKey = strlower(oldName)
                local newKey = strlower(newName)
                if NS.botStarUpdaters then
                    if NS.botStarUpdaters[oldKey] then NS.botStarUpdaters[oldKey]() end
                    if NS.botStarUpdaters[newKey] then NS.botStarUpdaters[newKey]() end
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
            -- If removing from Favorites, update the star on any matching Individual tab slot.
            if selectedPresetName == FAVORITES_KEY then
                local key = strlower(data)
                if NS.botStarUpdaters and NS.botStarUpdaters[key] then
                    NS.botStarUpdaters[key]()
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
        if selected == FAVORITES_KEY then
            NS.CB_Print("'" .. FAVORITES_KEY .. "' is a protected preset and cannot be renamed.")
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
        if selected == FAVORITES_KEY then
            NS.CB_Print("'" .. FAVORITES_KEY .. "' is a protected preset and cannot be removed.")
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

    -- ── Altbots section ───────────────────────────────────
    local altbotsSection = NS.CB_CreateSection(panel, "altbots", "Altbots", 3)

    local linkAltBtn = NS.CB_CreateButton(altbotsSection.bg, "CleanBotLinkAltBtn",
        "Link Account", 100, 24, function()
            StaticPopup_Show("CLEANBOT_LINK_ACCOUNT_NAME")
        end)
    linkAltBtn:SetPoint("TOPLEFT", altbotsSection.bg, "TOPLEFT",
        NS.PADDING.section.left  + (linkAltBtn.marginLeft or 0),
      -(NS.PADDING.section.top   + (linkAltBtn.marginTop  or 0)))

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

    local altDD = makeListDropdown(altbotsSection.bg, "CleanBotAltAccountDD", addAltBtn, linkedAccountsList,
        "No accounts found", function(name) selectedAltAccount = name end)

    local refreshAltBtn = NS.CB_CreateButton(altbotsSection.bg, "CleanBotRefreshAltBtn",
        "Refresh", 60, 24, function()
            NS.CleanBot_FetchLinkedAccounts()
        end)
    NS.CB_AnchorAhead(refreshAltBtn, altDD)

    local selectedUnlinkAccount = nil
    local unlinkAltBtn = NS.CB_CreateButton(altbotsSection.bg, "CleanBotUnlinkAltBtn", "Unlink Account", 100, 24)
    NS.CB_AnchorBelow(unlinkAltBtn, addAltBtn)

    local unlinkDD = makeListDropdown(altbotsSection.bg, "CleanBotUnlinkAccountDD", unlinkAltBtn, linkedAccountsList,
        "No accounts found", function(name) selectedUnlinkAccount = name end)

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

    -- ── Content height ────────────────────────────────────────────────────────
    local function updateContentHeight()
        local scrollTop  = NS.manageScrollChild:GetTop()
        local lastAnchor = altbotsSection:GetAnchor()
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
            presetsSection:UpdateBackground()
            altbotsSection:UpdateBackground()
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
        anchorToggle(presetsSection.toggleBtn,   partyRaidSection:GetAnchor())
        anchorToggle(altbotsSection.toggleBtn,   presetsSection:GetAnchor())
        scheduleUpdate()
    end

    targetSection.onToggle    = reflow
    partyRaidSection.onToggle = reflow
    presetsSection.onToggle   = reflow
    altbotsSection.onToggle   = reflow

    reflow()
    scheduleUpdate()  -- initial deferred pass: backgrounds + height after first render

    -- Live: re-anchor the section toggles + recompute backgrounds/scroll height on a layout change
    -- (reflow reads live panel padding + margins; scheduleUpdate defers the GetBottom-dependent work).
    NS.CB_RegisterRelayout(reflow)
end
