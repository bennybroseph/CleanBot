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
local lastAppliedGroupValue = nil ---@type string?  the value CB_OnGroupSelected last applied (detects group change vs refresh)
local currentMembers     = {}    ---@type table    live members ({key,name,class,value}) of the selected group
local currentItems       = {}    ---@type table    the member list's current item tables (mutated in place for live role icons)
local groupList, memberList      -- the two select lists
local listsRegion                -- container for buttons + both lists (hidden in the empty state)
local groupStratPanel            -- right-hand mirrored strategy panel
local groupEmptyLabel            -- "No bots found..." (mirrors the Individual tab)
local managingLabel              -- "Managing: <bots>" header atop the strategy panel
local emptyStratLabel            -- "Select a Bot to Begin" (shown when nothing is selected)
local groupCtrl, groupContainer  -- ctrl panel + content container (class tabs build into it)
local innerTabBar                -- inner tab bar (Combat / Non-Combat / Class)
local innerTabBtns = {}          -- [1] = Combat, [2] = Non-Combat
local sharedClassTab             -- single "Class" inner tab (labeled per-class when only one)
local classDropdown              -- class switcher (shown only when >1 unique class)
local classContents  = {}        -- [class] = lazily built class content frame
local combatContent, nonCombatContent
local selectedClass              ---@type string?  class token shown by the Class tab
local presentClasses = {}        ---@type table    unique classes in the selected group (roster order)
local activeInnerKey = 1         ---@type number|string  1 | 2 | "class"

-- ============================================================
-- Dynamic role groups — auto-derived from each bot's current role state
-- (entry.combat role fields), shown only when populated.
-- ============================================================
-- LFG role icons (Interface\LFGFrame\UI-LFG-ICON-PORTRAITROLES, 64x64; texel
-- coords lifted from FrameXML LFGFrame.lua, as 0-1 fractions for the right-icon
-- textures (SetTexCoord) on both the group list (role groups) and member list.
local ROLE_TEX  = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"
local ROLE_TANK = { 0,     19 / 64, 22 / 64, 41 / 64 }
local ROLE_HEAL = { 20/64, 39 / 64,  1 / 64, 20 / 64 }
local ROLE_DMG  = { 20/64, 39 / 64, 22 / 64, 41 / 64 }

-- A bot belongs to a role group if ANY of the listed combat fields is set; coords
-- give the role's right-aligned list icon.
local ROLE_GROUPS = {
    { label = "Tanks",        value = "role:tank",      coords = ROLE_TANK, fields = { "isTank" } },
    { label = "DPS",          value = "role:dps",       coords = ROLE_DMG,  fields = { "isDPS", "isDPSAoe" } },
    { label = "DPS (Single)", value = "role:dpsSingle", coords = ROLE_DMG,  fields = { "isDPS" } },
    { label = "DPS (AoE)",    value = "role:dpsAoe",    coords = ROLE_DMG,  fields = { "isDPSAoe" } },
    { label = "Healers",      value = "role:healer",    coords = ROLE_HEAL, fields = { "isHealer" } },
}
local roleByValue = {}
for _, rg in ipairs(ROLE_GROUPS) do roleByValue[rg.value] = rg end

-- Whether a bot entry currently fills a role group (any field true).
---@param entry  table?  CleanBot_PartyBots[key].
---@param fields table   Role field names to test.
---@return boolean
local function CB_BotInRole(entry, fields)
    if not (entry and entry.combat) then return false end
    for _, f in ipairs(fields) do
        if entry.combat[f] == true then return true end
    end
    return false
end

-- The role-icon descriptor for a bot's CURRENT role (priority tank > heal > dps),
-- as a member-list `rightIcon`, or nil when no role is set / no combat data.
---@param key string  Bot name-key.
---@return table?     { texture, coords } for CB_CreateSelectList's rightIcon.
local function CB_RoleIconForKey(key)
    local cd = CleanBot_PartyBots[key] and CleanBot_PartyBots[key].combat
    if not cd then return nil end
    local coords
    if cd.isTank then coords = ROLE_TANK
    elseif cd.isHealer then coords = ROLE_HEAL
    elseif cd.isDPS or cd.isDPSAoe then coords = ROLE_DMG end
    if not coords then return nil end
    return { texture = ROLE_TEX, coords = coords }
end

-- Class display name (sort key), and a role rank for sorting (tank < heal < dps <
-- none) from a bot's current combat state.
---@param class string?  Class token.
---@return string
local function classDisplay(class)
    return (NS.CLASS_DISPLAY and NS.CLASS_DISPLAY[class]) or class or ""
end
---@param key string  Bot name-key.
---@return number     1 tank, 2 heal, 3 dps, 9 none.
local function roleRank(key)
    local cd = CleanBot_PartyBots[key] and CleanBot_PartyBots[key].combat
    if cd then
        if cd.isTank then return 1
        elseif cd.isHealer then return 2
        elseif cd.isDPS or cd.isDPSAoe then return 3 end
    end
    return 9
end

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

-- Whether a name collides with a built-in (class or role) group label — those
-- are managed automatically, so a custom group can't reuse the name (the list
-- would show two indistinguishable entries).
---@param name string  Candidate custom-group name.
---@return boolean
local function CB_IsReservedGroupName(name)
    local lower = strlower(name)
    if lower == "all" then return true end
    for _, display in pairs(NS.CLASS_DISPLAY or {}) do
        if strlower(display) == lower then return true end
    end
    for _, rg in ipairs(ROLE_GROUPS) do
        if strlower(rg.label) == lower then return true end
    end
    return false
end

-- Items for the groups list: the managed "All" group, then class groups
-- (alphabetical, class-colored + icon), then role groups, then custom groups
-- sorted by name. A custom group greys when ANY stored member is missing from
-- the party/raid.
---@return table  Array of select-list item tables.
local function CB_GroupItems()
    local items = {}
    -- "All" — every party/raid member bot; managed, never editable/removable.
    items[#items + 1] = { text = "All", value = "all:all" }
    -- Class groups, alphabetical by class display name.
    local seen, classes = {}, {}
    for _, d in ipairs(NS.desiredBots or {}) do
        if not seen[d.class] then seen[d.class] = true; classes[#classes + 1] = d.class end
    end
    table.sort(classes, function(a, b) return classDisplay(a) < classDisplay(b) end)
    for _, c in ipairs(classes) do
        items[#items + 1] = { text = classDisplay(c), value = "class:" .. c, class = c }
    end

    -- Role groups (dynamic; only when ≥1 live bot currently fills the role).
    -- The role icon is right-aligned (rightIcon), matching the member list.
    for _, rg in ipairs(ROLE_GROUPS) do
        local count = 0
        for _, d in ipairs(NS.desiredBots or {}) do
            if CB_BotInRole(CleanBot_PartyBots[d.key], rg.fields) then count = count + 1 end
        end
        if count > 0 then
            items[#items + 1] = { text = rg.label, value = rg.value,
                                  rightIcon = { texture = ROLE_TEX, coords = rg.coords } }
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
-- Each live member carries `.value` matching its member-list item value, so a
-- multiselect value maps back to a member (greys have an item but no member).
---@param value string  "class:CLASS" or "custom:Name".
---@return table members  Array of {key,name,class,value}.
---@return table items    Select-list item tables for the member list.
local function CB_ResolveMembers(value)
    local members, items = {}, {}
    local kind, rest = value:match("^(%a+):(.+)$")
    if kind == "all" then
        for _, d in ipairs(NS.desiredBots or {}) do
            members[#members + 1] = { key = d.key, name = d.name, class = d.class, value = d.key }
            items[#items + 1]     = { text = d.name, value = d.key, class = d.class,
                                      botKey = d.key, rightIcon = CB_RoleIconForKey(d.key) }
        end
    elseif kind == "class" then
        for _, d in ipairs(NS.desiredBots or {}) do
            if d.class == rest then
                members[#members + 1] = { key = d.key, name = d.name, class = d.class, value = d.key }
                items[#items + 1]     = { text = d.name, value = d.key, class = d.class,
                                          botKey = d.key, rightIcon = CB_RoleIconForKey(d.key) }
            end
        end
    elseif kind == "role" then
        -- Dynamic membership: every live bot currently filling the role. A
        -- snapshot at selection time (like a custom group's stored list), so the
        -- aggregate stays stable while you edit it; re-resolves on reselection.
        local rg = roleByValue[value]
        if rg then
            for _, d in ipairs(NS.desiredBots or {}) do
                if CB_BotInRole(CleanBot_PartyBots[d.key], rg.fields) then
                    members[#members + 1] = { key = d.key, name = d.name, class = d.class, value = d.key }
                    items[#items + 1]     = { text = d.name, value = d.key, class = d.class,
                                              botKey = d.key, rightIcon = CB_RoleIconForKey(d.key) }
                end
            end
        end
    elseif kind == "custom" then
        local stored = (CleanBot_SavedVars and CleanBot_SavedVars.botGroups or {})[rest] or {}
        local live   = CB_LiveByKey()
        for _, botName in ipairs(stored) do
            local d = live[strlower(botName)]
            if d then
                members[#members + 1] = { key = d.key, name = d.name, class = d.class, value = botName }
                items[#items + 1]     = { text = d.name, value = botName, class = d.class,
                                          botKey = d.key, rightIcon = CB_RoleIconForKey(d.key) }
            else
                items[#items + 1]     = { text = botName, value = botName, grey = true }
            end
        end
    end

    -- Sort key depends on the group kind: "all" → Class → Role → Name; a single
    -- class group → Role → Name (class is constant); role/custom → Class → Name.
    -- Members follow the same order so the class tabs appear sorted; greyed items
    -- sort last. Compares (class, key, name) tuples shared by members and items.
    local function cmp(aClass, aKey, aName, bClass, bKey, bName)
        if kind ~= "class" then
            local ac, bc = classDisplay(aClass), classDisplay(bClass)
            if ac ~= bc then return ac < bc end
        end
        if kind == "all" or kind == "class" then
            local ar, br = roleRank(aKey), roleRank(bKey)
            if ar ~= br then return ar < br end
        end
        return aName < bName
    end
    table.sort(members, function(a, b)
        return cmp(a.class, a.key, a.name or "", b.class, b.key, b.name or "")
    end)
    table.sort(items, function(a, b)
        local ag, bg = a.grey and 1 or 0, b.grey and 1 or 0
        if ag ~= bg then return ag < bg end
        if a.grey then return (a.text or "") < (b.text or "") end
        return cmp(a.class, a.botKey, a.text or "", b.class, b.botKey, b.text or "")
    end)

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
-- Inner tab bar — fixed Combat / Non-Combat tabs plus a single "Class" tab.
-- With one unique class the Class tab is labeled with that class's name; with
-- several it collapses to "Class" + a class-switcher dropdown (avoids tab
-- overflow, mirroring the Individual tab's bot tab-vs-dropdown behavior).
-- ============================================================

-- The class dropdown belongs to the Class tab: visible only while that tab is
-- active and the group spans more than one class (single-class groups have no
-- dropdown). Anchored in a reserved row that the class content sits below.
local function CB_UpdateClassDropdownShown()
    if not classDropdown then return end
    if activeInnerKey == "class" and #presentClasses > 1 then
        classDropdown:Show()
    else
        classDropdown:Hide()
    end
end

-- Shows the content frame matching tabKey (1 = Combat, 2 = Non-Combat,
-- "class" = the selected class's content) and toggles the tab active states.
---@param tabKey number|string  Inner tab key: 1 | 2 | "class".
local function CB_SelectGroupInnerTab(tabKey)
    activeInnerKey = tabKey
    innerTabBtns[1]:SetActive(tabKey == 1)
    innerTabBtns[2]:SetActive(tabKey == 2)
    if sharedClassTab then sharedClassTab:SetActive(tabKey == "class") end

    if tabKey == 1 then combatContent:Show()    else combatContent:Hide()    end
    if tabKey == 2 then nonCombatContent:Show() else nonCombatContent:Hide() end
    for class, frame in pairs(classContents) do
        if tabKey == "class" and class == selectedClass then frame:Show() else frame:Hide() end
    end
    CB_UpdateClassDropdownShown()
end

-- Re-anchors a class content frame's top: pushed down by a dropdown row when the
-- group is multi-class (the dropdown occupies that row), flush under the tab bar
-- otherwise. Bottom reserves the legend-footer height (GROUP_LEGEND_H = NS.BOT_BAR_H).
---@param frame        table    A class content frame.
---@param dropdownRow  boolean  Whether to reserve the class-dropdown row at the top.
local function CB_AnchorClassContentTop(frame, dropdownRow)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT",     groupContainer, "TOPLEFT",
        0, -(NS.BOT_BAR_H + (dropdownRow and NS.BOT_BAR_H or 0)))
    frame:SetPoint("BOTTOMRIGHT", groupContainer, "BOTTOMRIGHT", 0, NS.BOT_BAR_H)
end

-- Builds (once) the class content frame + registry for a class, rendering the
-- same ClassData strategies the Individual tab shows — against the per-class
-- group slot, so writes fan out to that class's members only. No tab button:
-- navigation is the shared Class tab + dropdown.
---@param class string  Class token.
local function CB_EnsureGroupClassContent(class)
    if classContents[class] then return end

    local frame = CreateFrame("Frame", nil, groupContainer)
    -- Base anchor (no dropdown row); CB_LayoutGroupInnerTabs re-anchors with the
    -- reserved dropdown row when the group turns out to be multi-class.
    CB_AnchorClassContentTop(frame, false)
    frame:Hide()
    frame.paddingLeft   = groupCtrl.paddingLeft
    frame.paddingRight  = groupCtrl.paddingRight
    frame.paddingTop    = groupCtrl.paddingTop
    frame.paddingBottom = groupCtrl.paddingBottom
    classContents[class] = frame

    NS.groupClassFrames[class] = NS.CB_BuildClassTabContent(frame, class,
        CB_GroupClassSlot(class), "G_" .. class)
end

-- Class-colored display name for the dropdown entries and collapsed value.
---@param class string  Class token.
---@return string       Color-coded display name.
local function CB_ClassColoredName(class)
    local display = (NS.CLASS_DISPLAY and NS.CLASS_DISPLAY[class]) or class
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, display) end
    return display
end

-- Switches the Class tab to a specific class: updates the dropdown's collapsed
-- value (icon + colored name, mirroring the bot dropdown) and shows that class's
-- content. Used by the class dropdown entries.
---@param class string  Class token to display.
local function CB_SelectGroupClass(class)
    selectedClass = class
    if classDropdown then
        UIDropDownMenu_SetText(classDropdown,
            NS.CB_ClassIconMarkup(class) .. " " .. CB_ClassColoredName(class))
    end
    CB_SelectGroupInnerTab("class")
end

-- Lays the inner tab row out for the classes present in the selected group.
-- One class: the Class tab is labeled with that class's name, no dropdown.
-- Several: the Class tab reads "Class" and a class-switcher dropdown appears.
-- Class content frames for absent classes stay built for the next group that
-- needs them. Falls back to the Combat tab when no class is present.
---@param classesPresent table  Array of class tokens in roster order.
local function CB_LayoutGroupInnerTabs(classesPresent)
    presentClasses = classesPresent
    for _, class in ipairs(classesPresent) do CB_EnsureGroupClassContent(class) end

    if #classesPresent == 0 then
        sharedClassTab:Hide()
        selectedClass = nil
        if activeInnerKey == "class" then CB_SelectGroupInnerTab(1) end
        CB_UpdateClassDropdownShown()
        return
    end

    -- Keep the current class if it's still present, else default to the first.
    local keep = false
    for _, class in ipairs(classesPresent) do
        if class == selectedClass then keep = true break end
    end
    if not keep then selectedClass = classesPresent[1] end

    -- Multi-class groups reserve a dropdown row at the top of the class content.
    local multi = #classesPresent > 1
    for _, class in ipairs(classesPresent) do
        CB_AnchorClassContentTop(classContents[class], multi)
    end

    sharedClassTab:ClearAllPoints()
    NS.CB_AnchorAhead(sharedClassTab, innerTabBtns[2])
    sharedClassTab:Show()

    if multi then
        sharedClassTab:SetText("Class")
        UIDropDownMenu_Initialize(classDropdown, function()
            for _, class in ipairs(presentClasses) do
                local info        = UIDropDownMenu_CreateInfo()
                info.text         = NS.CB_ClassIconMarkup(class) .. " "
                                    .. ((NS.CLASS_DISPLAY and NS.CLASS_DISPLAY[class]) or class)
                info.value        = class
                info.notCheckable = true
                local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
                if c then info.colorCode = string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
                info.func         = function() CB_SelectGroupClass(class) end
                UIDropDownMenu_AddButton(info)
            end
        end)
        UIDropDownMenu_SetText(classDropdown,
            NS.CB_ClassIconMarkup(selectedClass) .. " " .. CB_ClassColoredName(selectedClass))
    else
        sharedClassTab:SetText((NS.CLASS_DISPLAY and NS.CLASS_DISPLAY[selectedClass]) or selectedClass)
    end

    -- If the Class tab is active, re-show content for the (possibly new) class.
    if activeInnerKey == "class" then CB_SelectGroupInnerTab("class") end
    CB_UpdateClassDropdownShown()
end

-- ============================================================
-- Selection and refresh
-- ============================================================

-- Builds the "Managing: <bots>" header text — each managed bot shown as its class
-- icon + class-colored name. Falls back to a plain count past a handful so the
-- single-line label can't overflow (and to keep many icons from getting busy).
---@param managed table  Managed members ({name, class, ...}).
---@return string
local function CB_ManagingText(managed)
    if #managed > 6 then return "Managing: " .. #managed .. " bots" end
    local parts = {}
    for _, m in ipairs(managed) do
        local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[m.class]
        local name = c and string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, m.name) or m.name
        parts[#parts + 1] = NS.CB_ClassIconMarkup(m.class) .. " " .. name
    end
    return "Managing: " .. table.concat(parts, ", ")
end

-- Applies the member list's current selection as the managed set: the strategy
-- panel aggregates over and fans out to only the selected (live) bots. Greys map
-- to no member and are filtered out. No selection → the empty state.
local function CB_ApplyMemberSelection()
    local byValue = {}
    for _, m in ipairs(currentMembers) do byValue[m.value] = m end

    local managed = {}
    for _, v in ipairs(memberList:GetSelectedValues()) do
        local m = byValue[v]
        if m then managed[#managed + 1] = m end
    end

    NS.groupSlot.members = managed

    -- Per-class slots filtered to the managed subset (absent classes cleared so a
    -- stale tab never sends to old members).
    local classes, seen = {}, {}
    for _, cs in pairs(NS.groupClassSlots) do cs.members = {} end
    for _, m in ipairs(managed) do
        if not seen[m.class] then
            seen[m.class] = true
            classes[#classes + 1] = m.class
        end
        local cs = CB_GroupClassSlot(m.class)
        cs.members[#cs.members + 1] = m
    end

    if #managed == 0 then
        -- Nothing managed: hide the strategy controls, show the prompt.
        managingLabel:Hide()
        groupContainer:Hide()
        emptyStratLabel:Show()
        return
    end

    emptyStratLabel:Hide()
    managingLabel:SetText(CB_ManagingText(managed))
    managingLabel:Show()
    groupContainer:Show()

    CB_LayoutGroupInnerTabs(classes)

    NS.CB_RefreshGroupAggregate(NS.groupSlot)
    for _, class in ipairs(classes) do
        NS.CB_RefreshGroupAggregate(NS.groupClassSlots[class])
    end

    CB_SyncGroupViews()
end

-- Applies a group selection: resolves the members, sets the member list, picks
-- the managed selection (all by default; preserved across an internal refresh of
-- the same group), then applies it. Kicks a silent bridge-path state re-read.
-- (The whisper path deliberately relies on the per-toggle ",?" self-heal instead
-- of mass co?/nc? probes per selection.)
---@param value         string   "class:CLASS" | "role:..." | "custom:Name".
---@param fromUserClick boolean?  True when the user clicked the group row (→ reselect all).
local function CB_OnGroupSelected(value, fromUserClick)
    local newGroup = (value ~= lastAppliedGroupValue)
    selectedGroupValue = value

    -- Preserve the current selection only when an internal refresh re-applies the
    -- SAME group (so a state packet can't reset a narrowed selection); a user
    -- click, a new group, or the first show all (re)select every row.
    local prev = (not fromUserClick and not newGroup) and memberList:GetSelectedValues() or nil

    local members, items = CB_ResolveMembers(value)
    currentMembers = members
    currentItems   = items
    memberList:SetItems(items)
    if prev then memberList:SetSelectedValues(prev) else memberList:SelectAllValues() end

    lastAppliedGroupValue = value
    CB_ApplyMemberSelection()
    NS.CB_RequestStates()
end

-- Rebuilds only the left group list (items + re-highlight) without touching the
-- selected group's member list, aggregate, or fetching states. Lets dynamic role
-- groups appear/disappear as role state changes, with no disruption to the open
-- group (SetSelectedValue re-highlights without firing onSelect).
local function CB_RebuildGroupListOnly()
    if not (NS.groupPanel and groupList) then return end
    groupList:SetItems(CB_GroupItems())
    if selectedGroupValue then groupList:SetSelectedValue(selectedGroupValue) end
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

-- Updates the member list's right-aligned role icon for a bot whose role just
-- changed, in place (no membership/selection change), so icons track live state.
---@param key string  Bot name-key whose entry just changed.
local function CB_UpdateMemberRoleIcons(key)
    if not memberList then return end
    local dirty = false
    for _, item in ipairs(currentItems) do
        if item.botKey == key then
            item.rightIcon = CB_RoleIconForKey(key)
            dirty = true
        end
    end
    if dirty then memberList:RefreshDisplay() end
end

-- Hooked from CB_UpdateTabData (Individual.lua): when a member of the
-- selected group gets fresh data (STATE~ packet, whisper reconcile), the
-- aggregate view refreshes too — even for members not bound to a slot.
---@param key string  Bot name-key whose entry just changed.
NS.CB_OnMemberDataChanged = function(key)
    if not NS.groupPanel then return end

    -- Role-group presence depends on every bot's role state, not just the
    -- selected group's members — refresh the list whenever any bot changes.
    CB_RebuildGroupListOnly()
    -- The member's role icon tracks live state too.
    CB_UpdateMemberRoleIcons(key)

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
    -- extra BOT_BAR_H inset). Keep the normal right padding so the strategy
    -- panel isn't flush against the frame border.
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
    -- The Individual tab puts a wide MODEL_GAP between its model and strategy
    -- panels; the Group tab has no model, so the lists expand into most of that
    -- gap (leaving LIST_STRAT_GAP) while the strategy panel stays exactly where
    -- it is — its left edge = listsRegion.right + LIST_STRAT_GAP, and listsW grows
    -- by (MODEL_GAP - LIST_STRAT_GAP) so that sum is unchanged.
    local LIST_STRAT_GAP = 8
    listsW = listsW + (NS.MODEL_GAP - LIST_STRAT_GAP)
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
    -- Two button rows now (Add/Rename over Remove; Add Bot/Add Target over Remove Bot).
    local listH = math.floor(contentH
        - 2 * (bm.top + 24 + bm.bottom)   -- two button rows
        - (bm.top + bm.bottom))           -- list container margins (stamped from button margins)

    -- Row 1 is the Add/Rename (Add Bot/Add Target) pair; the Remove button sits
    -- centered on row 2 and is wider so its label doesn't clip.
    local btnGap  = bm.right + bm.left   -- horizontal gap CB_AnchorAhead inserts
    local vGap    = bm.bottom + bm.top   -- inter-row vertical gap (CB_AnchorBelow)
    local removeW = btnW + 30            -- wider so "Remove Group"/"Remove Bot" fit

    -- ── Group column buttons: [Add] [Rename] / [Remove] (centered) ──
    local addGroupBtn = NS.CB_CreateButton(listsRegion, "CleanBotAddGroupBtn",
        "Add Group", btnW, 24)
    addGroupBtn:SetPoint("TOPLEFT", listsRegion, "TOPLEFT",
        (addGroupBtn.marginLeft or 0), -(addGroupBtn.marginTop or 0))

    local renameGroupBtn = NS.CB_CreateButton(listsRegion, "CleanBotRenameGroupBtn",
        "Rename Group", btnW, 24)
    NS.CB_AnchorAhead(renameGroupBtn, addGroupBtn)

    local removeGroupBtn = NS.CB_CreateButton(listsRegion, "CleanBotRemoveGroupBtn",
        "Remove Group", removeW, 24)
    -- Top-center pinned to the Add/Rename pair's midpoint (addGroupBtn right edge
    -- + half the inter-button gap).
    removeGroupBtn:SetPoint("TOP", addGroupBtn, "BOTTOMRIGHT", btnGap / 2, -vGap)

    -- ── Bot column buttons: [Add Bot] [Add Target] / [Remove Bot] (centered) ──
    local addBotBtn    = NS.CB_CreateButton(listsRegion, "CleanBotGroupAddBotBtn",
        "Add Bot", btnW, 24)
    local addTargetBtn = NS.CB_CreateButton(listsRegion, "CleanBotGroupAddTargetBtn",
        "Add Target", btnW, 24)
    local removeBotBtn = NS.CB_CreateButton(listsRegion, "CleanBotGroupRemoveBotBtn",
        "Remove Bot", removeW, 24)

    -- ── Lists ─────────────────────────────────────────────────
    -- Group list: single-select; a user click reselects all members of that group.
    groupList = NS.CB_CreateSelectList(listsRegion, "CleanBotGroupList", listW, listH,
        function(value) CB_OnGroupSelected(value, true) end)
    NS.CB_AnchorBelow(groupList, removeGroupBtn)

    -- Member list: Windows-style multi-select; the selection is the managed set.
    -- Center-justified row labels (bot names).
    memberList = NS.CB_CreateSelectList(listsRegion, "CleanBotGroupMemberList", listW, listH,
        function() CB_ApplyMemberSelection() end, true, "CENTER")
    memberList.marginLeft = NS.COLUMN_GAP
    NS.CB_AnchorAhead(memberList, groupList)

    -- Bot column anchored top-down at the member list's column so both columns'
    -- rows line up (x mirrors how memberList lands ahead of groupList); Remove Bot
    -- centered below the Add Bot / Add Target pair.
    local rightColX = (groupList.marginLeft or 0) + colW + (groupList.marginRight or 0) + NS.COLUMN_GAP
    addBotBtn:SetPoint("TOPLEFT", listsRegion, "TOPLEFT", rightColX, -(addBotBtn.marginTop or 0))
    NS.CB_AnchorAhead(addTargetBtn, addBotBtn)
    removeBotBtn:SetPoint("TOP", addBotBtn, "BOTTOMRIGHT", btnGap / 2, -vGap)

    -- ── Mirrored strategy panel (right column) ────────────────
    groupStratPanel = CreateFrame("Frame", "CleanBotGroupStratPanel", content)
    groupStratPanel:SetPoint("TOPLEFT",     listsRegion, "TOPRIGHT",    LIST_STRAT_GAP, 0)
    groupStratPanel:SetPoint("BOTTOMRIGHT", content,     "BOTTOMRIGHT", 0,            0)

    -- "Managing: <bots>" header — which bots the controls below are driving.
    local HEADER_H = 18
    managingLabel = groupStratPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    managingLabel:SetPoint("TOPLEFT",  groupStratPanel, "TOPLEFT",  0, 0)
    managingLabel:SetPoint("TOPRIGHT", groupStratPanel, "TOPRIGHT", 0, 0)
    managingLabel:SetJustifyH("LEFT")
    managingLabel:SetHeight(HEADER_H)

    -- Empty state shown when nothing is selected (replaces the controls).
    emptyStratLabel = groupStratPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    emptyStratLabel:SetPoint("CENTER", groupStratPanel, "CENTER", 0, 0)
    emptyStratLabel:SetText("Select a Bot to Begin")
    emptyStratLabel:Hide()

    groupCtrl = NS.CB_CreatePanel(groupStratPanel, "CleanBotGroupCtrl", 3, "panel")
    groupCtrl:SetPoint("TOPLEFT",     groupStratPanel, "TOPLEFT",     0, -HEADER_H)
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

    -- Single Class tab. With several unique classes it collapses to "Class" and a
    -- class-switcher dropdown appears at the TOP OF THE CLASS CONTENT (a reserved
    -- row), both toggled by CB_LayoutGroupInnerTabs / CB_SelectGroupInnerTab.
    sharedClassTab = NS.CB_CreateTab(innerTabBar, "CleanBotGroupClassTab", "Class",
                                     function() CB_SelectGroupInnerTab("class") end)
    NS.CB_AnchorAhead(sharedClassTab, innerTabBtns[2])
    sharedClassTab:Hide()

    -- Lives inside the class content region (parented to groupContainer), pinned to
    -- the reserved top row; class content frames are pushed down by CLASS_DD_ROW
    -- when it's shown. x pulls left to offset the template's built-in inset.
    classDropdown = NS.CB_CreateDropdown(groupContainer, "CleanBotGroupClassDropdown", 160)
    classDropdown:ClearAllPoints()
    classDropdown:SetPoint("TOPLEFT", groupContainer, "TOPLEFT",
        (groupCtrl.paddingLeft or 0) - 16, -(NS.BOT_BAR_H + 2))
    classDropdown:Hide()

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
            if CB_IsReservedGroupName(name) then
                NS.CB_Print("'" .. name .. "' matches a built-in class/role group and cannot be used.")
                return
            end
            CleanBot_SavedVars.botGroups[name] = {}
            selectedGroupValue = "custom:" .. name
            NS.CB_RefreshGroupTab()
        end)

    NS.CB_RegisterEditPopup("CLEANBOT_RENAME_GROUP",
        "Enter a new name for the '%s' group:",
        function(self, data)
            local newName = self.editBox and self.editBox:GetText()
            newName = newName and newName:match("^%s*(.-)%s*$")
            if not newName or newName == "" then
                NS.CB_Print("Please enter a group name.")
                return
            end
            local oldName = data
            if not oldName or not CleanBot_SavedVars.botGroups[oldName] then return end
            if CleanBot_SavedVars.botGroups[newName] then
                NS.CB_Print("A group named '" .. newName .. "' already exists.")
                return
            end
            if CB_IsReservedGroupName(newName) then
                NS.CB_Print("'" .. newName .. "' matches a built-in class/role group and cannot be used.")
                return
            end
            CleanBot_SavedVars.botGroups[newName] = CleanBot_SavedVars.botGroups[oldName]
            CleanBot_SavedVars.botGroups[oldName] = nil
            selectedGroupValue = "custom:" .. newName
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

    -- Title-cases + strips spaces, dedupes, and appends a bot name to a custom
    -- group. Shared by the Add Bot popup and the Add Target button.
    ---@param groupName string  Custom group name.
    ---@param rawName   string  Raw bot name (any casing/spacing).
    local function CB_AddBotToCustomGroup(groupName, rawName)
        local botName = rawName and rawName:match("^%s*(.-)%s*$")
        if not botName or botName == "" then
            NS.CB_Print("Please enter a bot name.")
            return
        end
        botName = botName:gsub("(%a)([%a]*)", function(first, rest)
            return first:upper() .. rest:lower()
        end):gsub("%s+", "")
        local group = CleanBot_SavedVars.botGroups[groupName]
        if not group then return end
        for _, existing in ipairs(group) do
            if strlower(existing) == strlower(botName) then
                NS.CB_Print("'" .. botName .. "' is already in the '" .. groupName .. "' group.")
                return
            end
        end
        group[#group + 1] = botName
        NS.CB_RefreshGroupTab()
    end

    NS.CB_RegisterEditPopup("CLEANBOT_ADD_BOT_TO_GROUP",
        "Enter a bot name to add to the '%s' group:",
        function(self, data)
            CB_AddBotToCustomGroup(data, self.editBox and self.editBox:GetText())
        end)

    NS.CB_RegisterConfirmPopup("CLEANBOT_REMOVE_BOTS_FROM_GROUP",
        "Remove %d bot(s) from the '%s' group?",
        function(self, data)
            local group = data and CleanBot_SavedVars.botGroups[data.group]
            if not group then return end
            -- Build a lowercase set of the names to drop, then filter the list.
            local drop = {}
            for _, name in ipairs(data.bots) do drop[strlower(name)] = true end
            for i = #group, 1, -1 do
                if drop[strlower(group[i])] then table.remove(group, i) end
            end
            NS.CB_RefreshGroupTab()
        end)

    -- ── Button handlers ───────────────────────────────────────
    addGroupBtn:SetScript("OnClick", function()
        StaticPopup_Show("CLEANBOT_ADD_GROUP")
    end)

    renameGroupBtn:SetScript("OnClick", function()
        if not selectedGroupValue then
            NS.CB_Print("No group selected.")
            return
        end
        local name = CB_SelectedCustomGroupName()
        if not name then
            NS.CB_Print("Class and role groups are managed automatically and cannot be renamed.")
            return
        end
        StaticPopup_Show("CLEANBOT_RENAME_GROUP", name, nil, name)
    end)

    removeGroupBtn:SetScript("OnClick", function()
        if not selectedGroupValue then
            NS.CB_Print("No group selected.")
            return
        end
        local name = CB_SelectedCustomGroupName()
        if not name then
            NS.CB_Print("Class and role groups are managed automatically and cannot be removed.")
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
            NS.CB_Print("Class and role groups are managed automatically and cannot be edited.")
            return
        end
        StaticPopup_Show("CLEANBOT_ADD_BOT_TO_GROUP", name, nil, name)
    end)

    addTargetBtn:SetScript("OnClick", function()
        if not selectedGroupValue then
            NS.CB_Print("No group selected.")
            return
        end
        local name = CB_SelectedCustomGroupName()
        if not name then
            NS.CB_Print("Class and role groups are managed automatically and cannot be edited.")
            return
        end
        if not UnitExists("target") then
            NS.CB_Print("You have no target.")
            return
        end
        if not UnitIsPlayer("target") then
            NS.CB_Print("Your target is not a player.")
            return
        end
        CB_AddBotToCustomGroup(name, UnitName("target"))
    end)

    removeBotBtn:SetScript("OnClick", function()
        local name = CB_SelectedCustomGroupName()
        if not selectedGroupValue then
            NS.CB_Print("No group selected.")
            return
        end
        if not name then
            NS.CB_Print("Class and role groups are managed automatically and cannot be edited.")
            return
        end
        -- Remove every selected bot (values are the stored names for custom groups).
        local bots = memberList:GetSelectedValues()
        if #bots == 0 then
            NS.CB_Print("No bots selected.")
            return
        end
        local popup = StaticPopup_Show("CLEANBOT_REMOVE_BOTS_FROM_GROUP",
            #bots, name, { group = name, bots = bots })
        if popup then
            popup:SetWidth(420)
            popup.text:SetWidth(380)
        end
    end)

    -- Initial state (roster is unknown at login → empty state until the
    -- first CleanBot_RefreshTabs lands).
    NS.CB_RefreshGroupTab()
end
