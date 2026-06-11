-- ============================================================
-- GroupTab.lua  —  Group tab: manage strategy state for whole
--                  groups of bots at once.
--
-- Left list: groups — one auto-derived "class group" per unique class among
-- the bots in the party/raid, plus user-created custom groups persisted in
-- CleanBot_SavedVars.botGroups. Right list: the selected group's members.
-- Selecting a group shows a mirror of the Individual tab's strategy sub-tabs
-- (Combat / Non-Combat / one class tab per class present) whose values
-- aggregate across all members and whose writes fan out to every member that
-- supports the command (see the group-slot support block in Individual.lua).
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- Group slots and registries
--
-- One mutable generic slot renders NS.STRATEGIES / NS.NC_STRATEGIES once at
-- build time (class = nil → every strategy shows); selecting a group only
-- swaps its `members` and re-aggregates. Class tabs get per-class slots and
-- are built lazily on the first group that contains that class.
-- ============================================================

-- Builds an empty group-slot table (see CB_SlotEntry/CB_SlotTargets in
-- Individual.lua for how the build engine consumes it).
---@param key   string   Synthetic slot key (never a roster key).
---@param class string?  Class token for a class-tab slot; nil for the generic slot.
---@return table          The group slot.
local function CB_NewGroupSlot(key, class)
    return {
        key           = key,
        name          = "(group)",   -- never a send target; members are
        isGroup       = true,
        class         = class,
        members       = {},          -- {key,name,class} of LIVE members (class-filtered for class slots)
        partialFields = {},          -- field→true: some-but-not-all members support it
        noneActive    = {},          -- groupId→true: a member has nothing active in that noneLabel set
        aggEntry      = { combat = {}, nonCombat = {}, classData = { combat = {}, nonCombat = {} } },
    }
end

NS.groupSlot        = CB_NewGroupSlot("__GROUP__", nil)
NS.groupClassSlots  = {}   -- [class] = per-class group slot (lazy)
NS.groupFrames      = {}   -- registry: the shared Combat + Non-Combat content
NS.groupClassFrames = {}   -- [class] = registry for that class's group tab content

-- Returns (creating on first use) the per-class group slot.
---@param class string  Class token.
---@return table         The class group slot.
local function CB_GroupClassSlot(class)
    local cs = NS.groupClassSlots[class]
    if not cs then
        cs = CB_NewGroupSlot("__GROUP_" .. class .. "__", class)
        NS.groupClassSlots[class] = cs
    end
    return cs
end

-- ── UI state (assigned in CleanBot_BuildGroupTab) ─────────────────────────────
local selectedGroupValue = nil   ---@type string?  "class:WARRIOR" | "custom:Name"; survives refreshes
local groupList, memberList      -- the two select lists
local listsRegion                -- container for buttons + both lists (hidden in the empty state)
local groupStratPanel            -- right-hand mirrored strategy panel
local groupEmptyLabel            -- "No bots found..." (mirrors the Individual tab)
local groupCtrl, groupContainer  -- ctrl panel + content container (class tabs build into it)
local innerTabBar                -- inner tab bar (Combat / Non-Combat / class tabs)
local innerTabBtns = {}          -- [1] = Combat, [2] = Non-Combat
local classTabBtns   = {}        -- [class] = lazily created class tab button
local classContents  = {}        -- [class] = lazily built class content frame
local combatContent, nonCombatContent
local activeInnerKey = 1         ---@type number|string  1 | 2 | class token

-- ============================================================
-- Data helpers
-- ============================================================

-- Live roster bots keyed by name-key.
---@return table<string, table>  key → NS.desiredBots entry.
local function CB_LiveByKey()
    local map = {}
    for _, d in ipairs(NS.desiredBots or {}) do map[d.key] = d end
    return map
end

-- The selected group's custom name, or nil for class groups / no selection.
---@return string?  The custom group name.
local function CB_SelectedCustomGroupName()
    return selectedGroupValue and selectedGroupValue:match("^custom:(.+)$") or nil
end

-- Items for the groups list: class groups first (order of first appearance in
-- the roster, class-colored + icon), then custom groups sorted by name. A
-- custom group greys when ANY stored member is missing from the party/raid.
---@return table  Array of select-list item tables.
local function CB_GroupItems()
    local items = {}
    local seen  = {}
    for _, d in ipairs(NS.desiredBots or {}) do
        if not seen[d.class] then
            seen[d.class] = true
            items[#items + 1] = {
                text  = (NS.CLASS_DISPLAY and NS.CLASS_DISPLAY[d.class]) or d.class,
                value = "class:" .. d.class,
                class = d.class,
            }
        end
    end

    local groups = CleanBot_SavedVars and CleanBot_SavedVars.botGroups or {}
    local names  = {}
    for name in pairs(groups) do names[#names + 1] = name end
    table.sort(names)

    local live = CB_LiveByKey()
    for _, name in ipairs(names) do
        local missing = false
        for _, botName in ipairs(groups[name]) do
            if not live[strlower(botName)] then missing = true break end
        end
        items[#items + 1] = { text = name, value = "custom:" .. name, grey = missing }
    end
    return items
end

-- Resolves a group value into its LIVE members (send/aggregate targets) and
-- the member-list items. A stored custom-group member missing from the
-- roster renders grey but stays selectable so it can be removed.
---@param value string  "class:CLASS" or "custom:Name".
---@return table members  Array of {key,name,class}.
---@return table items    Select-list item tables for the member list.
local function CB_ResolveMembers(value)
    local members, items = {}, {}
    local kind, rest = value:match("^(%a+):(.+)$")
    if kind == "class" then
        for _, d in ipairs(NS.desiredBots or {}) do
            if d.class == rest then
                members[#members + 1] = { key = d.key, name = d.name, class = d.class }
                items[#items + 1]     = { text = d.name, value = d.key, class = d.class }
            end
        end
    elseif kind == "custom" then
        local stored = (CleanBot_SavedVars and CleanBot_SavedVars.botGroups or {})[rest] or {}
        local live   = CB_LiveByKey()
        for _, botName in ipairs(stored) do
            local d = live[strlower(botName)]
            if d then
                members[#members + 1] = { key = d.key, name = d.name, class = d.class }
                items[#items + 1]     = { text = d.name, value = botName, class = d.class }
            else
                items[#items + 1]     = { text = botName, value = botName, grey = true }
            end
        end
    end
    return members, items
end

-- ============================================================
-- Aggregation — definition-driven over the same strategy tables the build
-- engine renders, so new strategies aggregate with zero extra wiring.
-- ============================================================

-- Aggregates one strategy list over the slot's members: all supporting
-- members agree → that value; they disagree → NS.MIXED; nobody supports it →
-- nil. Also records the partial-support flag for the " (*)" suffixes.
---@param slot            table  The group slot being aggregated.
---@param list            table  Strategy definitions.
---@param getMemberSource fun(entry:table?):table?  Extracts a member's state table.
---@param aggTable        table  The aggregate table to write into (mutated in place).
local function CB_AggregateStrategyList(slot, list, getMemberSource, aggTable)
    local total = #slot.members
    for _, s in ipairs(list) do
        local result = nil
        local count  = 0
        for _, m in ipairs(slot.members) do
            if NS.CB_StrategyShown(s, m.class) then
                count = count + 1
                local src = getMemberSource(CleanBot_PartyBots[m.key])
                local v
                if s.type == "timerSlider" then
                    v = src and src[s.field] or nil
                else
                    -- Boolean-normalize: a member with no data yet reads false.
                    v = (src and src[s.field] == true) and true or false
                end
                if count == 1 then
                    result = v
                elseif result ~= v then
                    result = NS.MIXED
                end
            end
        end
        aggTable[s.field] = result
        slot.partialFields[s.field] = (count > 0 and count < total) and true or nil
    end
end

-- Aggregates every group in a definition table into aggTable, including
-- roleDropdown sub-groups and the per-group noneLabel state. Whisper (talent
-- spec) groups are skipped: their state is inspect-driven, and skipping keeps
-- the user's optimistic spec pick alive across aggregate rebuilds.
---@param slot            table   The group slot being aggregated.
---@param groups          table   Strategy group definitions (e.g. NS.STRATEGIES).
---@param prefix          string  "co" or "nc" — namespaces the noneActive keys
---                               (the combat and non-combat Movement groups share group="movement").
---@param getMemberSource fun(entry:table?):table?  Extracts a member's state table.
---@param aggTable        table   The aggregate table to write into (mutated in place).
local function CB_AggregateGroups(slot, groups, prefix, getMemberSource, aggTable)
    for _, grp in ipairs(groups) do
        if not grp.whisper then
            CB_AggregateStrategyList(slot, grp.strategies, getMemberSource, aggTable)
            if grp.subGroups then
                for _, sg in ipairs(grp.subGroups) do
                    CB_AggregateStrategyList(slot, sg.strategies, getMemberSource, aggTable)
                end
            end
            if grp.noneLabel then
                -- A member with nothing active in this exclusive set sits at
                -- "none" — the noneLabel then joins the dropdown display list.
                -- Key must match the registry's: cmd-prefixed group/header.
                local groupId = prefix .. ":" .. (grp.group or grp.header)
                local anyNone = false
                for _, m in ipairs(slot.members) do
                    local src = getMemberSource(CleanBot_PartyBots[m.key])
                    local hasActive = false
                    for _, s in ipairs(grp.strategies) do
                        if NS.CB_StrategyShown(s, m.class) and src and src[s.field] == true then
                            hasActive = true
                            break
                        end
                    end
                    if not hasActive then anyNone = true break end
                end
                slot.noneActive[groupId] = anyNone or nil
            end
        end
    end
end

-- Rebuilds a group slot's aggregate entry from its current members. The
-- generic slot aggregates the generic combat/non-combat strategies; a class
-- slot aggregates that class's ClassData strategies.
---@param slot table  The group slot to refresh.
NS.CB_RefreshGroupAggregate = function(slot)
    if slot.class then
        local cs = NS.CLASS_STRATEGIES and NS.CLASS_STRATEGIES[slot.class]
        if cs and cs.combat then
            CB_AggregateGroups(slot, cs.combat, "co",
                function(e) return e and e.classData and e.classData.combat end,
                slot.aggEntry.classData.combat)
        end
        if cs and cs.nonCombat then
            CB_AggregateGroups(slot, cs.nonCombat, "nc",
                function(e) return e and e.classData and e.classData.nonCombat end,
                slot.aggEntry.classData.nonCombat)
        end
    else
        CB_AggregateGroups(slot, NS.STRATEGIES, "co",
            function(e) return e and e.combat end,    slot.aggEntry.combat)
        CB_AggregateGroups(slot, NS.NC_STRATEGIES, "nc",
            function(e) return e and e.nonCombat end, slot.aggEntry.nonCombat)
    end
end

-- ============================================================
-- Sync — pushes the aggregates into the built controls via the shared
-- NS.CB_SyncRegistry (which renders NS.MIXED and the suffix maps).
-- ============================================================

-- Syncs the generic registry plus every class registry whose slot currently
-- has members in the selected group.
local function CB_SyncGroupViews()
    NS.CB_SyncRegistry(NS.groupFrames, NS.groupSlot.aggEntry, {
        partial    = NS.groupSlot.partialFields,
        noneActive = NS.groupSlot.noneActive,
    })
    for class, reg in pairs(NS.groupClassFrames) do
        local cs = NS.groupClassSlots[class]
        if cs and #cs.members > 0 then
            NS.CB_SyncRegistry(reg, cs.aggEntry, {
                partial    = cs.partialFields,
                noneActive = cs.noneActive,
            })
        end
    end
end

-- ============================================================
-- Inner tab bar — fixed Combat / Non-Combat tabs plus one lazily-built tab
-- per class present in the selected group.
-- ============================================================

-- Shows the content frame matching tabKey (1 = Combat, 2 = Non-Combat, class
-- token = that class tab) and toggles the tab button active states.
---@param tabKey number|string  Inner tab key.
local function CB_SelectGroupInnerTab(tabKey)
    activeInnerKey = tabKey
    innerTabBtns[1]:SetActive(tabKey == 1)
    innerTabBtns[2]:SetActive(tabKey == 2)
    for class, btn in pairs(classTabBtns) do btn:SetActive(tabKey == class) end

    if tabKey == 1 then combatContent:Show()    else combatContent:Hide()    end
    if tabKey == 2 then nonCombatContent:Show() else nonCombatContent:Hide() end
    for class, frame in pairs(classContents) do
        if tabKey == class then frame:Show() else frame:Hide() end
    end
end

-- Builds (once) the tab button + class content for a class, rendering the
-- same ClassData strategies the Individual tab shows — against the per-class
-- group slot, so writes fan out to that class's members only.
---@param class string  Class token.
local function CB_EnsureGroupClassTab(class)
    if classTabBtns[class] then return end

    local display = (NS.CLASS_DISPLAY and NS.CLASS_DISPLAY[class]) or class
    classTabBtns[class] = NS.CB_CreateTab(innerTabBar, "CleanBotGroupInnerTab_" .. class,
                                          display, function() CB_SelectGroupInnerTab(class) end)

    local frame = CreateFrame("Frame", nil, groupContainer)
    frame:SetPoint("TOPLEFT",     groupContainer, "TOPLEFT",     0, -NS.BOT_BAR_H)
    -- Reserve the legend-footer height (GROUP_LEGEND_H = NS.BOT_BAR_H) so class
    -- strategies don't overlap the "*"/"?" legend at the panel bottom.
    frame:SetPoint("BOTTOMRIGHT", groupContainer, "BOTTOMRIGHT", 0, NS.BOT_BAR_H)
    frame:Hide()
    frame.paddingLeft   = groupCtrl.paddingLeft
    frame.paddingRight  = groupCtrl.paddingRight
    frame.paddingTop    = groupCtrl.paddingTop
    frame.paddingBottom = groupCtrl.paddingBottom
    classContents[class] = frame

    NS.groupClassFrames[class] = NS.CB_BuildClassTabContent(frame, class,
        CB_GroupClassSlot(class), "G_" .. class)
end

-- Lays the inner tab row out for the classes present in the selected group:
-- Combat → Non-Combat → class tabs in roster order. Class tabs for absent
-- classes hide (their built content is kept for the next group that needs
-- it). Falls back to the Combat tab when the active class tab vanishes.
---@param classesPresent table  Array of class tokens in roster order.
local function CB_LayoutGroupInnerTabs(classesPresent)
    for _, btn in pairs(classTabBtns) do btn:Hide() end

    local prev = innerTabBtns[2]
    for _, class in ipairs(classesPresent) do
        CB_EnsureGroupClassTab(class)
        local btn = classTabBtns[class]
        btn:ClearAllPoints()
        NS.CB_AnchorAhead(btn, prev)
        btn:Show()
        prev = btn
    end

    if type(activeInnerKey) == "string" then
        local found = false
        for _, class in ipairs(classesPresent) do
            if class == activeInnerKey then found = true break end
        end
        if not found then CB_SelectGroupInnerTab(1) end
    end
end

-- ============================================================
-- Selection and refresh
-- ============================================================

-- Applies a group selection: swaps the slot member sets, (lazily) builds the
-- class tabs, re-aggregates, syncs the strategy panel, and kicks a silent
-- bridge-path state re-read so the aggregate reflects fresh server state.
-- (The whisper path deliberately relies on the per-toggle ",?" self-heal
-- instead of mass co?/nc? probes per selection.)
---@param value string  "class:CLASS" or "custom:Name".
local function CB_OnGroupSelected(value)
    selectedGroupValue = value
    local members, items = CB_ResolveMembers(value)
    memberList:SetItems(items)

    NS.groupSlot.members = members

    -- Classes present, in roster order; class slots get the filtered member
    -- lists (absent classes cleared so a stale tab never sends to old members).
    local classes, seen = {}, {}
    for _, cs in pairs(NS.groupClassSlots) do cs.members = {} end
    for _, m in ipairs(members) do
        if not seen[m.class] then
            seen[m.class] = true
            classes[#classes + 1] = m.class
        end
        local cs = CB_GroupClassSlot(m.class)
        cs.members[#cs.members + 1] = m
    end

    CB_LayoutGroupInnerTabs(classes)

    NS.CB_RefreshGroupAggregate(NS.groupSlot)
    for _, class in ipairs(classes) do
        NS.CB_RefreshGroupAggregate(NS.groupClassSlots[class])
    end

    CB_SyncGroupViews()
    NS.CB_RequestStates()
end

-- Rebuilds the Group tab from the current roster: group items, grey states,
-- selection restore, and the empty state. Hooked from CleanBot_RefreshTabs
-- (both exits), so every roster change flows through here.
NS.CB_RefreshGroupTab = function()
    if not NS.groupPanel then return end

    local haveBots = NS.desiredBots and #NS.desiredBots > 0
    if not haveBots then
        groupEmptyLabel:SetText("No bots found in your party or raid.")
        listsRegion:Hide()
        groupStratPanel:Hide()
        -- Empty roster is the one case the Group tab follows the saved
        -- expand/collapse state instead of forcing the expanded width.
        if NS.activeTopTabIndex == 3 and NS.COLLAPSED_WIDTH then
            NS.CB_ResizeFrame(NS.individualExpanded and NS.EXPANDED_WIDTH or NS.COLLAPSED_WIDTH)
        end
        return
    end

    groupEmptyLabel:SetText("")
    listsRegion:Show()
    groupStratPanel:Show()
    if NS.activeTopTabIndex == 3 and NS.COLLAPSED_WIDTH then
        NS.CB_ResizeFrame(NS.EXPANDED_WIDTH)
    end

    local items = CB_GroupItems()
    groupList:SetItems(items)
    if not (selectedGroupValue and groupList:SetSelectedValue(selectedGroupValue)) then
        selectedGroupValue = items[1] and items[1].value or nil
        if selectedGroupValue then groupList:SetSelectedValue(selectedGroupValue) end
    end
    if selectedGroupValue then
        CB_OnGroupSelected(selectedGroupValue)
    else
        memberList:SetItems({})
    end
end

-- Hooked from CB_UpdateTabData (Individual.lua): when a member of the
-- selected group gets fresh data (STATE~ packet, whisper reconcile), the
-- aggregate view refreshes too — even for members not bound to a slot.
---@param key string  Bot name-key whose entry just changed.
NS.CB_OnMemberDataChanged = function(key)
    if not NS.groupPanel then return end
    local isMember = false
    for _, m in ipairs(NS.groupSlot.members) do
        if m.key == key then isMember = true break end
    end
    if not isMember then return end

    NS.CB_RefreshGroupAggregate(NS.groupSlot)
    for _, cs in pairs(NS.groupClassSlots) do
        if #cs.members > 0 then NS.CB_RefreshGroupAggregate(cs) end
    end
    CB_SyncGroupViews()
end

-- Hooked from the fan-out write helpers (Individual.lua) after a group-slot
-- control sends: folds the optimistic per-member writes back into the
-- aggregate view and mirrors them onto any bound Individual tabs.
---@param slot table  The group slot that was written through.
NS.CB_OnGroupWrite = function(slot)
    NS.CB_RefreshGroupAggregate(slot)
    CB_SyncGroupViews()
    for _, m in ipairs(slot.members) do
        NS.CB_UpdateTabData(m.key)
    end
end

-- ============================================================
-- Panel construction (called once at PLAYER_LOGIN via NS.CB_BuildFrames,
-- after CleanBot_BuildIndividualTab — the lists region width mirrors the
-- Individual tab's model panel so the strategy panels line up).
-- ============================================================
--- Builds the Group tab: group/member lists, add/remove buttons + popups, and
--- the mirrored strategy panel rendered once against the generic group slot.
NS.CleanBot_BuildGroupTab = function()
    local panel = NS.CB_CreatePanel(NS.contentFrame, "CleanBotGroupPanel", 2, "panel")
    panel:SetAllPoints(NS.contentFrame)
    NS.groupPanel = panel

    groupEmptyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    groupEmptyLabel:SetPoint("TOP", panel, "TOP", 0, -(NS.BOT_BAR_H + 20))
    groupEmptyLabel:SetText("")

    -- Content area: the Group tab has no per-bot selector row, so content
    -- starts at the panel's own top padding (unlike individualContent's
    -- extra BOT_BAR_H inset).
    local content = CreateFrame("Frame", "CleanBotGroupContent", panel)
    content:SetPoint("TOPLEFT",     panel, "TOPLEFT",      panel.paddingLeft,  -panel.paddingTop)
    content:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -panel.paddingRight,  panel.paddingBottom)

    -- Static height (frame height never changes); GetHeight is 0 until first
    -- layout, so fall back to the same arithmetic Individual.lua uses.
    local contentH = content:GetHeight()
    if contentH == 0 then
        contentH = NS.FRAME_HEIGHT - NS.TITLE_H - NS.TOP_BAR_H
                   - (CleanBotFrame.paddingBottom or NS.PADDING.frame.bottom)
                   - panel.paddingTop - panel.paddingBottom
    end

    -- ── Lists region (left column, same width as the Individual model panel
    --    so the mirrored strategy panel matches the Individual tab's) ──────
    local listsW = (NS.individualModelPanel and NS.individualModelPanel:GetWidth() or 0)
    if listsW == 0 then listsW = 360 end
    listsRegion = CreateFrame("Frame", "CleanBotGroupLists", content)
    listsRegion:SetPoint("TOPLEFT",    content, "TOPLEFT",    0, 0)
    listsRegion:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    listsRegion:SetWidth(listsW)

    -- Two equal columns; CB_CreateSelectList adds 20px (scrollbar) to the
    -- requested content width, so subtract it from each column's share.
    local colW  = math.floor((listsW - NS.COLUMN_GAP) / 2)
    local listW = colW - 20
    local bm    = NS.MARGIN.button
    local btnW  = math.floor((colW - bm.right - bm.left) / 2)
    local listH = math.floor(contentH
        - (bm.top + 24 + bm.bottom)   -- button row
        - (bm.top + bm.bottom))       -- list container margins (stamped from button margins)

    -- ── Button row ────────────────────────────────────────────
    local addGroupBtn = NS.CB_CreateButton(listsRegion, "CleanBotAddGroupBtn",
        "Add Group", btnW, 24)
    addGroupBtn:SetPoint("TOPLEFT", listsRegion, "TOPLEFT",
        (addGroupBtn.marginLeft or 0), -(addGroupBtn.marginTop or 0))

    local removeGroupBtn = NS.CB_CreateButton(listsRegion, "CleanBotRemoveGroupBtn",
        "Remove Group", btnW, 24)
    NS.CB_AnchorAhead(removeGroupBtn, addGroupBtn)

    local addBotBtn = NS.CB_CreateButton(listsRegion, "CleanBotGroupAddBotBtn",
        "Add Bot", btnW, 24)
    local removeBotBtn = NS.CB_CreateButton(listsRegion, "CleanBotGroupRemoveBotBtn",
        "Remove Bot", btnW, 24)
    NS.CB_AnchorAhead(removeBotBtn, addBotBtn)

    -- ── Lists ─────────────────────────────────────────────────
    groupList = NS.CB_CreateSelectList(listsRegion, "CleanBotGroupList", listW, listH,
        function(value) CB_OnGroupSelected(value) end)
    NS.CB_AnchorBelow(groupList, addGroupBtn)

    memberList = NS.CB_CreateSelectList(listsRegion, "CleanBotGroupMemberList", listW, listH)
    memberList.marginLeft = NS.COLUMN_GAP
    NS.CB_AnchorAhead(memberList, groupList)

    -- Align the bot buttons with the member list's left edge (mirror of the
    -- ManageTab presets layout: pin BOTTOMLEFT → list TOPLEFT with the
    -- combined facing margins as the gap).
    addBotBtn:ClearAllPoints()
    addBotBtn:SetPoint("BOTTOMLEFT", memberList, "TOPLEFT",
        0, (memberList.marginTop or 0) + (addBotBtn.marginBottom or 0))

    -- ── Mirrored strategy panel (right column) ────────────────
    groupStratPanel = CreateFrame("Frame", "CleanBotGroupStratPanel", content)
    groupStratPanel:SetPoint("TOPLEFT",     listsRegion, "TOPRIGHT",    NS.MODEL_GAP, 0)
    groupStratPanel:SetPoint("BOTTOMRIGHT", content,     "BOTTOMRIGHT", 0,            0)

    groupCtrl = NS.CB_CreatePanel(groupStratPanel, "CleanBotGroupCtrl", 3, "panel")
    groupCtrl:SetPoint("TOPLEFT",     groupStratPanel, "TOPLEFT",     0, 0)
    groupCtrl:SetPoint("BOTTOMRIGHT", groupStratPanel, "BOTTOMRIGHT", 0, 0)

    groupContainer = CreateFrame("Frame", nil, groupCtrl)
    groupContainer:SetAllPoints(groupCtrl)

    -- Legend footer: explains the " (?)" / " (*)" suffixes the aggregate view
    -- appends. Two stacked lines pinned to the panel's bottom-left; the content
    -- frames reserve GROUP_LEGEND_H above it so strategies never overlap them.
    local legendBottom = groupContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    legendBottom:SetPoint("BOTTOMLEFT", groupContainer, "BOTTOMLEFT",
        (groupCtrl.paddingLeft or 0), (groupCtrl.paddingBottom or 0))
    legendBottom:SetText("? - Strategy is different for some characters")
    local legendTop = groupContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    legendTop:SetPoint("BOTTOMLEFT", legendBottom, "TOPLEFT", 0, 2)
    legendTop:SetText("* - Strategy is not available for some characters")
    local GROUP_LEGEND_H = NS.BOT_BAR_H

    -- Inner tab bar + content frames mirror CB_BuildBotContent's scaffolding.
    innerTabBar = CreateFrame("Frame", nil, groupContainer)
    innerTabBar:SetPoint("TOPLEFT",  groupContainer, "TOPLEFT",  0, 0)
    innerTabBar:SetPoint("TOPRIGHT", groupContainer, "TOPRIGHT", 0, 0)
    innerTabBar:SetHeight(NS.BOT_BAR_H)

    combatContent = CreateFrame("Frame", nil, groupContainer)
    combatContent:SetPoint("TOPLEFT",     groupContainer, "TOPLEFT",     0, -NS.BOT_BAR_H)
    combatContent:SetPoint("BOTTOMRIGHT", groupContainer, "BOTTOMRIGHT", 0, GROUP_LEGEND_H)
    combatContent.paddingLeft   = groupCtrl.paddingLeft
    combatContent.paddingRight  = groupCtrl.paddingRight
    combatContent.paddingTop    = groupCtrl.paddingTop
    combatContent.paddingBottom = groupCtrl.paddingBottom

    nonCombatContent = CreateFrame("Frame", nil, groupContainer)
    nonCombatContent:SetPoint("TOPLEFT",     groupContainer, "TOPLEFT",     0, -NS.BOT_BAR_H)
    nonCombatContent:SetPoint("BOTTOMRIGHT", groupContainer, "BOTTOMRIGHT", 0, GROUP_LEGEND_H)
    nonCombatContent:Hide()
    nonCombatContent.paddingLeft   = groupCtrl.paddingLeft
    nonCombatContent.paddingRight  = groupCtrl.paddingRight
    nonCombatContent.paddingTop    = groupCtrl.paddingTop
    nonCombatContent.paddingBottom = groupCtrl.paddingBottom

    for j, lbl in ipairs({ "Combat", "Non-Combat" }) do
        local jj = j
        local itab = NS.CB_CreateTab(innerTabBar, "CleanBotGroupInnerTab" .. j, lbl,
                                     function() CB_SelectGroupInnerTab(jj) end)
        if j == 1 then
            itab:SetPoint("LEFT", innerTabBar, "LEFT",
                (groupCtrl.paddingLeft or 0) + (itab.marginLeft or 0), 0)
        else
            NS.CB_AnchorAhead(itab, innerTabBtns[j - 1])
        end
        innerTabBtns[j] = itab
    end

    -- The generic content is built exactly once against the mutable group
    -- slot — selecting a group only swaps members and re-syncs, so changes
    -- to Strategies.lua automatically reach this tab.
    NS.CB_BuildTwoColumnContent(combatContent,    NS.STRATEGIES,    "co", NS.groupSlot, "G",
        NS.groupFrames, function(e) return e and e.combat    end)
    NS.CB_BuildTwoColumnContent(nonCombatContent, NS.NC_STRATEGIES, "nc", NS.groupSlot, "G",
        NS.groupFrames, function(e) return e and e.nonCombat end)
    CB_SelectGroupInnerTab(1)

    -- ── Popups ────────────────────────────────────────────────
    NS.CB_RegisterEditPopup("CLEANBOT_ADD_GROUP",
        "Enter a name for the new group:",
        function(self)
            local name = self.editBox and self.editBox:GetText()
            name = name and name:match("^%s*(.-)%s*$")
            if not name or name == "" then
                NS.CB_Print("Please enter a group name.")
                return
            end
            if CleanBot_SavedVars.botGroups[name] then
                NS.CB_Print("A group named '" .. name .. "' already exists.")
                return
            end
            -- Refuse names that collide with the built-in class groups —
            -- two identical labels in the list would be indistinguishable.
            for _, display in pairs(NS.CLASS_DISPLAY or {}) do
                if strlower(display) == strlower(name) then
                    NS.CB_Print("'" .. name .. "' matches a built-in class group and cannot be used.")
                    return
                end
            end
            CleanBot_SavedVars.botGroups[name] = {}
            selectedGroupValue = "custom:" .. name
            NS.CB_RefreshGroupTab()
        end)

    NS.CB_RegisterConfirmPopup("CLEANBOT_REMOVE_GROUP",
        "Are you sure you want to remove the '%s' group?",
        function(self, data)
            if data and CleanBot_SavedVars.botGroups then
                CleanBot_SavedVars.botGroups[data] = nil
            end
            selectedGroupValue = nil
            NS.CB_RefreshGroupTab()
        end)

    NS.CB_RegisterEditPopup("CLEANBOT_ADD_BOT_TO_GROUP",
        "Enter a bot name to add to the '%s' group:",
        function(self, data)
            local botName = self.editBox and self.editBox:GetText()
            botName = botName and botName:match("^%s*(.-)%s*$")
            if not botName or botName == "" then
                NS.CB_Print("Please enter a bot name.")
                return
            end
            -- Title-case and strip spaces (matches the bot add command convention).
            botName = botName:gsub("(%a)([%a]*)", function(first, rest)
                return first:upper() .. rest:lower()
            end):gsub("%s+", "")
            local group = data and CleanBot_SavedVars.botGroups[data]
            if not group then return end
            for _, existing in ipairs(group) do
                if strlower(existing) == strlower(botName) then
                    NS.CB_Print("'" .. botName .. "' is already in the '" .. data .. "' group.")
                    return
                end
            end
            group[#group + 1] = botName
            NS.CB_RefreshGroupTab()
        end)

    NS.CB_RegisterConfirmPopup("CLEANBOT_REMOVE_BOT_FROM_GROUP",
        "Remove '%s' from the '%s' group?",
        function(self, data)
            local group = data and CleanBot_SavedVars.botGroups[data.group]
            if not group then return end
            for i, existing in ipairs(group) do
                if strlower(existing) == strlower(data.bot) then
                    table.remove(group, i)
                    break
                end
            end
            NS.CB_RefreshGroupTab()
        end)

    -- ── Button handlers ───────────────────────────────────────
    addGroupBtn:SetScript("OnClick", function()
        StaticPopup_Show("CLEANBOT_ADD_GROUP")
    end)

    removeGroupBtn:SetScript("OnClick", function()
        if not selectedGroupValue then
            NS.CB_Print("No group selected.")
            return
        end
        local name = CB_SelectedCustomGroupName()
        if not name then
            NS.CB_Print("Class groups are managed automatically and cannot be removed.")
            return
        end
        local popup = StaticPopup_Show("CLEANBOT_REMOVE_GROUP", name, nil, name)
        if popup then
            popup:SetWidth(420)
            popup.text:SetWidth(380)
        end
    end)

    addBotBtn:SetScript("OnClick", function()
        if not selectedGroupValue then
            NS.CB_Print("No group selected.")
            return
        end
        local name = CB_SelectedCustomGroupName()
        if not name then
            NS.CB_Print("Class groups are managed automatically and cannot be edited.")
            return
        end
        StaticPopup_Show("CLEANBOT_ADD_BOT_TO_GROUP", name, nil, name)
    end)

    removeBotBtn:SetScript("OnClick", function()
        local name = CB_SelectedCustomGroupName()
        if not selectedGroupValue then
            NS.CB_Print("No group selected.")
            return
        end
        if not name then
            NS.CB_Print("Class groups are managed automatically and cannot be edited.")
            return
        end
        local sel = memberList:GetSelected()
        if not sel then
            NS.CB_Print("No bot selected.")
            return
        end
        local botName = type(sel) == "table" and sel.value or sel
        local popup = StaticPopup_Show("CLEANBOT_REMOVE_BOT_FROM_GROUP",
            botName, name, { group = name, bot = botName })
        if popup then
            popup:SetWidth(420)
            popup.text:SetWidth(380)
        end
    end)

    -- Initial state (roster is unknown at login → empty state until the
    -- first CleanBot_RefreshTabs lands).
    NS.CB_RefreshGroupTab()
end
