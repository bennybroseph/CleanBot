-- ============================================================
-- CleanBotParty.lua  —  character tab state, tab management,
--                        strategy section builders, RefreshTabs
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- Tab slot pool and selection state
--
-- A "slot" is a reusable UI container (tab button + model + ctrl panel)
-- that is bound to whichever bot occupies its position. Slots persist for
-- the session and are rebound rather than recreated, so frame and global-
-- name counts stay bounded no matter how many bots cycle through the party.
--
-- Each slot: {
--   index, tabBtn, tabIcon, model, ctrl,    -- created once
--   equipSlots, updateStar,                  -- model sub-parts (class-agnostic)
--   contentByClass = { [class] = contentHandle },  -- built lazily, once per class
--   activeContent,                           -- contentHandle for the bound class
--   key, name, unit, class, active,          -- current binding
-- }
-- A contentHandle holds the per-class widget registries (roleDD, tankFrames,
-- …) plus its container frame and selectInnerTab fn.
-- ============================================================
NS.tabPool          = {}   -- all slots ever created, indexed by slot number
NS.tabList          = {}   -- ordered active slots, in party order
NS.selectedTabIndex = 0    -- index into tabList of the currently shown tab
NS.selectedBotKey   = nil  -- key of selected tab; survives RefreshTabs rebuilds
NS.lastWavedAt      = nil

-- Per-key registries (keyed by strlower(botName)). On bind these are repointed
-- to the bound slot's active frames; CB_UpdateTabData and the bridge read them
-- by key without needing to know about slots.
NS.botInnerTabs    = {}
NS.botFrames       = {}   -- unified registry: all strategy groups (combat, nc, class)
NS.botStarUpdaters = {}
NS.botEquipSlots   = {}

-- All per-key registries above, gathered so a slot's key entries can be
-- cleared in one loop when it is unbound (adding a registry only needs the
-- line above, plus a repoint in CB_BindRegistries).
NS.botRegistries = {
    NS.botInnerTabs, NS.botFrames,
    NS.botStarUpdaters, NS.botEquipSlots,
}

-- ============================================================
-- Geometry helper — single source of truth for layout constants
-- ============================================================
local function CB_GetGeometry()
    local contentW = NS.partyContent and NS.partyContent:GetWidth()  or 0
    local contentH = NS.partyContent and NS.partyContent:GetHeight() or 0
    if contentW == 0 then contentW = NS.FRAME_WIDTH - 8 end
    if contentH == 0 then contentH = NS.FRAME_HEIGHT - NS.TITLE_H - NS.TOP_BAR_H - NS.BOT_BAR_H - NS.FOOTER_H - NS.PAD * 2 end

    local modelH   = contentH - NS.EQUIP_WEAPON_PAD
    local modelW   = math.floor(contentW / 3)
    local g        = NS.CB_SlotGeometry(modelW, modelH)
    local ctrlLeft = g.colW + modelW + g.colW + NS.PAD
    return contentW, contentH, modelH, g.colW, ctrlLeft
end

-- ============================================================
-- Strategy section builder — shared by combat, non-combat, and class tabs.
-- onClickFn(strategy, checked) overrides the default "co +/-cmd" whisper.
-- sourceTable supplies each checkbox's initial checked state (entry.combat,
-- entry.nonCombat, or a classData section); nil leaves boxes unchecked.
-- Returns (sectionFrame, checkboxes) where checkboxes is keyed by field name.
-- ============================================================
local function CB_BuildStrategySection(ctrl, anchor, strategies, slot, tag, onClickFn, sourceTable)
    local section = CreateFrame("Frame", nil, ctrl)
    section:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -12)
    section:SetPoint("RIGHT",   ctrl,   "RIGHT",       0,   0)
    section:SetHeight(#strategies * 26)

    local controls = {}
    local rowIndex = 0
    for _, s in ipairs(strategies) do
        if s.type == "timerDropdown" then
            local lbl = section:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            lbl:SetPoint("TOPLEFT", section, "TOPLEFT", 28, -(rowIndex * 26) - 3)
            lbl:SetText(s.name .. ":")

            local dd = NS.CB_CreateDropdown(section, "CleanBotTimerDD_" .. s.field .. "_" .. tag, 80)
            dd:SetPoint("LEFT", lbl, "RIGHT", -8, -1)

            local strat = s
            UIDropDownMenu_Initialize(dd, function(self)
                local src = sourceTable
                for _, v in ipairs(strat.values) do
                    local info           = UIDropDownMenu_CreateInfo()
                    info.text            = v .. " sec"
                    info.value           = v
                    info.notCheckable    = false
                    info.tooltipTitle    = strat.name
                    info.tooltipText     = strat.desc
                    info.tooltipOnButton = 1
                    info.func            = function()
                        UIDropDownMenu_SetText(self, v .. " sec")
                        NS.CB_SendBotCommand(slot.name, strat.cmd .. " " .. v)
                        local e = CleanBot_PartyBots[slot.key]
                        if e and e.combat then e.combat[strat.field] = v end
                    end
                    info.checked = src and (src[strat.field] == v)
                    UIDropDownMenu_AddButton(info)
                end
            end)

            local initVal = sourceTable and sourceTable[s.field]
            UIDropDownMenu_SetText(dd, initVal and (initVal .. " sec") or "")

            controls[s.field] = dd
            rowIndex = rowIndex + 1
        else
            local cb = NS.CB_CreateCheckBox(section, "CleanBotCB_" .. s.field .. "_" .. tag)
            cb:SetSize(20, 20)
            cb:SetPoint("TOPLEFT", section, "TOPLEFT", 4, -rowIndex * 26)

            local lbl = section:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
            lbl:SetText(s.name)

            cb:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(s.name, 1, 1, 1)
                GameTooltip:AddLine(s.desc, 0.8, 0.8, 0.8, true)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)

            cb:SetChecked(sourceTable and sourceTable[s.field] == true)

            local strat = s
            if onClickFn then
                cb:SetScript("OnClick", function(self)
                    onClickFn(strat, self:GetChecked() and true or false)
                end)
            else
                local cbCmd   = s.cmd
                local cbField = s.field
                cb:SetScript("OnClick", function(self)
                    local toggle = (self:GetChecked() and "+" or "-") .. cbCmd
                    NS.CB_SendBotCommand(slot.name, "co " .. toggle)
                    local e = CleanBot_PartyBots[slot.key]
                    if e and e.combat then
                        e.combat[cbField] = self:GetChecked() and true or false
                    end
                end)
            end

            controls[s.field] = cb
            rowIndex = rowIndex + 1
        end
    end

    -- Wire dependsOn: patch the checkbox's OnClick to enable/disable the linked dropdown.
    for _, s in ipairs(strategies) do
        if s.type == "timerDropdown" and s.dependsOn then
            local cb = controls[s.dependsOn]
            local dd = controls[s.field]
            if cb and dd then
                if not cb:GetChecked() then UIDropDownMenu_DisableDropDown(dd) end
                local orig = cb:GetScript("OnClick")
                cb:SetScript("OnClick", function(self)
                    if orig then orig(self) end
                    if self:GetChecked() then UIDropDownMenu_EnableDropDown(dd)
                    else UIDropDownMenu_DisableDropDown(dd) end
                end)
            end
        end
    end

    return section, controls
end

-- Applies a mutually-exclusive strategy selection: whispers a single
-- "cmd +sel,-other,-other..." toggle list and mirrors the choice into
-- dataTable (entry.combat or a classData section), if supplied.
local function CB_ApplyExclusiveSelection(strategies, selectedField, cmd, slot, dataTable)
    local parts = {}
    for _, rs in ipairs(strategies) do
        parts[#parts + 1] = (rs.field == selectedField and "+" or "-") .. rs.cmd
    end
    NS.CB_SendBotCommand(slot.name, cmd .. " " .. table.concat(parts, ","))
    if dataTable then
        for _, rs in ipairs(strategies) do
            dataTable[rs.field] = (rs.field == selectedField)
        end
    end
end

-- ============================================================
-- CB_BuildTalentGroup
-- Renders: header → Show Talents btn → Set Talents btn → whisper dropdown.
-- Used for the full-width spec group and any whisper dropdown inside a column.
-- prevBottom=nil anchors the header to parent's TOPLEFT; otherwise to prevBottom.
-- Returns the Set Talents button, which becomes the next prevBottom.
-- ============================================================
local function CB_BuildTalentGroup(parent, prevBottom, group, slot, tag, gi, registry, getSource)
    local strategies  = group.strategies
    local specWhisper = group.whisper

    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if prevBottom then
        header:SetPoint("TOPLEFT", prevBottom, "BOTTOMLEFT", 0, -12)
    else
        header:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -10)
    end
    header:SetText(group.header)

    local showBtn = NS.CB_CreateButton(parent, "CleanBotShowTal_" .. tag .. "_" .. gi,
                                       "Show Talents", 100, 22, function()
        local botName = slot.name
        local unit = NS.CB_FindPartyUnit(botName)
        if not unit then return end
        InspectUnit(unit)
        NS.CB_After(0.05, function()
            if Talented then
                local entry = CleanBot_PartyBots[slot.key]
                local class = entry and entry.class or select(2, UnitClass(unit)) or "WARRIOR"
                local template = { name = botName, class = class }
                local numTabs = GetNumTalentTabs(true)
                for tab = 1, numTabs do
                    local ranks = {}
                    for index = 1, GetNumTalents(tab, true) do
                        ranks[index] = select(5, GetTalentInfo(tab, index, true)) or 0
                    end
                    template[tab] = ranks
                end
                local ok = pcall(Talented.OpenTemplate, Talented, template)
                if not ok then
                    pcall(function()
                        Talented:CreateBaseFrame()
                        Talented:SetTemplate(template)
                        local base = Talented.base
                        if base and not base:IsVisible() then ShowUIPanel(base) end
                    end)
                end
                HideUIPanel(InspectFrame)
            else
                for i = 1, 10 do
                    local tab = _G["InspectFrameTab" .. i]
                    if not tab then break end
                    local text = tab:GetText()
                    if text and strfind(strlower(text), "talent") then tab:Click(); break end
                end
            end
        end)
    end)
    showBtn:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)

    local setBtn = NS.CB_CreateButton(parent, "CleanBotSetTal_" .. tag .. "_" .. gi .. "s",
                                      "Set Talents", 100, 22)
    setBtn:SetPoint("TOPLEFT", showBtn, "BOTTOMLEFT", 0, -4)

    local dd = NS.CB_CreateDropdown(parent, "CleanBotClassDD_" .. tag .. "_" .. gi, 130)
    dd:SetPoint("LEFT", setBtn, "RIGHT", -10, 0)

    UIDropDownMenu_Initialize(dd, function(self)
        local e  = CleanBot_PartyBots[slot.key]
        local cd = getSource(e)
        for _, s in ipairs(strategies) do
            local info           = UIDropDownMenu_CreateInfo()
            info.text            = s.name
            info.value           = s.field
            info.tooltipTitle    = s.name
            info.tooltipText     = s.desc
            info.tooltipOnButton = 1
            info.func            = function()
                UIDropDownMenu_SetText(self, s.name)
                local cd2 = getSource(CleanBot_PartyBots[slot.key])
                if cd2 then
                    for _, rs in ipairs(strategies) do
                        cd2[rs.field] = (rs.field == s.field)
                    end
                end
            end
            info.checked = cd and (cd[s.field] == true)
            UIDropDownMenu_AddButton(info)
        end
    end)
    setBtn:SetScript("OnClick", function()
        local cd = getSource(CleanBot_PartyBots[slot.key])
        if not cd then return end
        for _, s in ipairs(strategies) do
            if cd[s.field] == true then
                NS.CB_SendBotCommand(slot.name, specWhisper .. " " .. s.cmd)
                return
            end
        end
    end)

    if registry then
        registry[#registry + 1] = { type = "dropdown", dd = dd, strategies = strategies, getSource = getSource }
    end
    return setBtn
end

-- ============================================================
-- CB_BuildColumnGroups
-- Renders one column's worth of strategy groups into `col`.
-- cmd       = "co" or "nc"
-- getSource = function(entry) -> mutable data table to read/write
-- startGi   = first group index to process (used to skip spec group on left col)
-- ============================================================
local function CB_BuildColumnGroups(col, groups, cmd, slot, tag, startGi, registry, getSource)
    local entry      = CleanBot_PartyBots[slot.key]
    local prevBottom = nil

    for gi = (startGi or 1), #groups do
        local group = groups[gi]

        if group.type == "dropdown" and group.whisper then
            -- Talent/whisper group: Show Talents + Set Talents + whisper dropdown
            prevBottom = CB_BuildTalentGroup(col, prevBottom, group, slot, tag, gi, registry, getSource)

        elseif group.type == "roleDropdown" then
            -- Exclusive dropdown that also shows/hides per-role sub-sections.
            local strategies = group.strategies
            local header = col:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            if prevBottom then
                header:SetPoint("TOPLEFT", prevBottom, "BOTTOMLEFT", 0, -12)
            else
                header:SetPoint("TOPLEFT", col, "TOPLEFT", 8, -10)
            end
            header:SetText(group.header)

            local multiRoleLabel = col:CreateFontString(nil, "OVERLAY", "GameFontRed")
            multiRoleLabel:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 4, -8)
            multiRoleLabel:SetText("Multiple Roles Selected")
            multiRoleLabel:Hide()

            local dd = NS.CB_CreateDropdown(col, "CleanBotRoleDD_" .. tag, 90)
            dd:SetPoint("LEFT", header, "RIGHT", 2, -2)

            -- Build all sub-sections anchored to the same point; only one shows at a time.
            local subSections = {}
            local maxSubH     = 0
            local initSrc     = getSource(entry) or {}
            for _, sg in ipairs(group.subGroups) do
                local sec, cbs = CB_BuildStrategySection(col, header, sg.strategies, slot, tag,
                    function(s, checked)
                        local toggle = (checked and "+" or "-") .. s.cmd
                        NS.CB_SendBotCommand(slot.name, cmd .. " " .. toggle)
                        local ds = getSource(CleanBot_PartyBots[slot.key])
                        if ds then ds[s.field] = checked end
                    end,
                    initSrc)
                sec:Hide()
                subSections[sg.field] = { section = sec, checkboxes = cbs, strategies = sg.strategies }
                maxSubH = math.max(maxSubH, #sg.strategies * 26)
            end

            -- Show the correct sub-section based on initial data.
            local activeCount = 0
            local activeField = nil
            for _, s in ipairs(strategies) do
                if initSrc[s.field] == true then
                    activeCount = activeCount + 1
                    if not activeField then activeField = s.field end
                end
            end
            if activeCount > 1 then
                multiRoleLabel:Show()
            elseif activeField and subSections[activeField] then
                subSections[activeField].section:Show()
            end

            UIDropDownMenu_Initialize(dd, function(self)
                local src = getSource(CleanBot_PartyBots[slot.key]) or {}
                for _, s in ipairs(strategies) do
                    local info           = UIDropDownMenu_CreateInfo()
                    info.text            = s.name
                    info.value           = s.field
                    info.tooltipTitle    = s.name
                    info.tooltipText     = s.desc
                    info.tooltipOnButton = 1
                    info.func            = function()
                        UIDropDownMenu_SetText(self, s.name)
                        CB_ApplyExclusiveSelection(strategies, s.field, cmd, slot,
                            getSource(CleanBot_PartyBots[slot.key]))
                        multiRoleLabel:Hide()
                        for field, sub in pairs(subSections) do
                            if field == s.field then sub.section:Show() else sub.section:Hide() end
                        end
                    end
                    info.checked = src[s.field] == true
                    UIDropDownMenu_AddButton(info)
                end
            end)

            -- Spacer to hold vertical room for the tallest sub-section.
            local spacer = CreateFrame("Frame", nil, col)
            spacer:SetSize(1, 1)
            spacer:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -(12 + maxSubH))
            prevBottom = spacer

            if registry then
                registry[#registry + 1] = {
                    type           = "roleDropdown",
                    dd             = dd,
                    strategies     = strategies,
                    getSource      = getSource,
                    subSections    = subSections,
                    multiRoleLabel = multiRoleLabel,
                }
            end

        elseif group.type == "dropdown" then
            -- Exclusive dropdown: selection sends cmd +/- for each strategy
            local strategies = group.strategies
            local header = col:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            if prevBottom then
                header:SetPoint("TOPLEFT", prevBottom, "BOTTOMLEFT", 0, -12)
            else
                header:SetPoint("TOPLEFT", col, "TOPLEFT", 8, -10)
            end
            header:SetText(group.header)

            local dd = NS.CB_CreateDropdown(col, "CleanBotClassDD_" .. cmd .. tag .. "_" .. gi, 160)
            dd:SetPoint("TOPLEFT", header, "BOTTOMLEFT", -16, -4)

            UIDropDownMenu_Initialize(dd, function(self)
                local cd = getSource(CleanBot_PartyBots[slot.key])
                for _, s in ipairs(strategies) do
                    local info           = UIDropDownMenu_CreateInfo()
                    info.text            = s.name
                    info.value           = s.field
                    info.tooltipTitle    = s.name
                    info.tooltipText     = s.desc
                    info.tooltipOnButton = 1
                    info.func            = function()
                        UIDropDownMenu_SetText(self, s.name)
                        CB_ApplyExclusiveSelection(strategies, s.field, cmd, slot,
                            getSource(CleanBot_PartyBots[slot.key]))
                    end
                    info.checked = cd and (cd[s.field] == true)
                    UIDropDownMenu_AddButton(info)
                end
            end)
            if group.readonly then UIDropDownMenu_DisableDropDown(dd) end

            if registry then
                registry[#registry + 1] = { type = "dropdown", dd = dd, strategies = strategies, getSource = getSource }
            end
            local ddAnchor = CreateFrame("Frame", nil, col)
            ddAnchor:SetSize(1, 1)
            ddAnchor:SetPoint("TOPLEFT", dd, "TOPLEFT", 16, -28)
            prevBottom = ddAnchor

        else
            -- Checkbox group
            local header = col:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            if prevBottom then
                header:SetPoint("TOPLEFT", prevBottom, "BOTTOMLEFT", 0, -12)
            else
                header:SetPoint("TOPLEFT", col, "TOPLEFT", 8, -10)
            end
            header:SetText(group.header)

            local section, checkboxes = CB_BuildStrategySection(col, header, group.strategies, slot, tag,
                function(s, checked)
                    local toggle = (checked and "+" or "-") .. s.cmd
                    NS.CB_SendBotCommand(slot.name, cmd .. " " .. toggle)
                    local ds = getSource(CleanBot_PartyBots[slot.key])
                    if ds then ds[s.field] = checked end
                end,
                getSource(entry))
            section:Show()
            if registry then
                registry[#registry + 1] = { type = "checkboxes", checkboxes = checkboxes, strategies = group.strategies, getSource = getSource }
            end
            prevBottom = section
        end
    end
end

-- ============================================================
-- Class tab content builder
-- ============================================================
local function CB_BuildClassTabContent(classContent, class, slot, tag)
    local cs = NS.CLASS_STRATEGIES and NS.CLASS_STRATEGIES[class]

    if not cs or (not cs.combat and not cs.nonCombat) then
        local label = classContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", classContent, "TOPLEFT", 12, -12)
        label:SetText("No class-specific options.")
        return {}
    end

    -- Spec group: full-width above both columns (first combat group with a whisper field)
    local specGroup     = cs.combat and cs.combat[1] and cs.combat[1].whisper and cs.combat[1] or nil
    local combatStartGi = specGroup and 2 or 1
    local classRegistry = {}
    local colTopAnchor  = specGroup and CB_BuildTalentGroup(classContent, nil, specGroup, slot, tag, 1, classRegistry, function(e) return e and e.classData and e.classData.combat end) or nil

    local colDivider = CreateFrame("Frame", nil, classContent)
    colDivider:SetHeight(1)
    if colTopAnchor then
        colDivider:SetPoint("TOPLEFT", colTopAnchor, "BOTTOMLEFT", 0, -12)
    else
        colDivider:SetPoint("TOPLEFT", classContent, "TOPLEFT", 0, 0)
    end
    colDivider:SetPoint("RIGHT", classContent, "RIGHT", 0, 0)

    local leftCol = CreateFrame("Frame", nil, classContent)
    leftCol:SetPoint("TOPLEFT",     colDivider,   "TOPLEFT",     0,  0)
    leftCol:SetPoint("BOTTOMRIGHT", classContent, "BOTTOM",     -4,  0)

    local rightCol = CreateFrame("Frame", nil, classContent)
    rightCol:SetPoint("TOPLEFT",     colDivider,   "TOP",         4,  0)
    rightCol:SetPoint("BOTTOMRIGHT", classContent, "BOTTOMRIGHT", 0,  0)

    if cs.combat    then CB_BuildColumnGroups(leftCol,  cs.combat,    "co", slot, tag, combatStartGi, classRegistry, function(e) return e and e.classData and e.classData.combat    end) end
    if cs.nonCombat then CB_BuildColumnGroups(rightCol, cs.nonCombat, "nc", slot, tag, 1,            classRegistry, function(e) return e and e.classData and e.classData.nonCombat end) end

    return classRegistry
end

-- Splits groups by `column` field and renders them into two side-by-side
-- columns inside `parent`. Groups without a column field go left by default.
local function CB_BuildTwoColumnContent(parent, groups, cmd, slot, tag, registry, getSource)
    local leftGroups, rightGroups = {}, {}
    for _, grp in ipairs(groups) do
        if grp.column == "right" then
            rightGroups[#rightGroups + 1] = grp
        else
            leftGroups[#leftGroups + 1] = grp
        end
    end

    local leftCol = CreateFrame("Frame", nil, parent)
    leftCol:SetPoint("TOPLEFT",     parent, "TOPLEFT", 0,  0)
    leftCol:SetPoint("BOTTOMRIGHT", parent, "BOTTOM",  -4, 0)

    local rightCol = CreateFrame("Frame", nil, parent)
    rightCol:SetPoint("TOPLEFT",     parent, "TOP",         4, 0)
    rightCol:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)

    CB_BuildColumnGroups(leftCol,  leftGroups,  cmd, slot, tag, 1, registry, getSource)
    CB_BuildColumnGroups(rightCol, rightGroups, cmd, slot, tag, 1, registry, getSource)
end

-- ============================================================
-- CB_BuildBotContent
-- Builds the inner tab bar and all combat/non-combat/class content for one
-- class into `container` (a child of the slot's ctrl). Event handlers resolve
-- the bound bot live via `slot`, so the built content can be rebound to any
-- bot of the same class. Returns a content handle holding the widget
-- registries; the caller repoints the per-key registries to it on bind.
-- ============================================================
local function CB_BuildBotContent(container, slot, class, tag)
    local entry = CleanBot_PartyBots[slot.key]

    local innerTabBar = CreateFrame("Frame", nil, container)
    innerTabBar:SetPoint("TOPLEFT",  container, "TOPLEFT",  0, 0)
    innerTabBar:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
    innerTabBar:SetHeight(NS.BOT_BAR_H)

    local contentBg = CreateFrame("Frame", nil, container)
    contentBg:SetPoint("TOPLEFT",     container, "TOPLEFT",     0, -NS.BOT_BAR_H)
    contentBg:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    NS.CB_ApplyInnerSkin(contentBg)

    local combatContent = CreateFrame("Frame", nil, container)
    combatContent:SetPoint("TOPLEFT",     container, "TOPLEFT",     0, -NS.BOT_BAR_H)
    combatContent:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)

    local nonCombatContent = CreateFrame("Frame", nil, container)
    nonCombatContent:SetPoint("TOPLEFT",     container, "TOPLEFT",     0, -NS.BOT_BAR_H)
    nonCombatContent:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    nonCombatContent:Hide()

    local classContent = CreateFrame("Frame", nil, container)
    classContent:SetPoint("TOPLEFT",     container, "TOPLEFT",     0, -NS.BOT_BAR_H)
    classContent:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    classContent:Hide()

    local innerTabBtns = {}
    local function selectInnerTab(idx)
        for j, t in ipairs(innerTabBtns) do
            if j == idx then
                t:SetNormalFontObject(GameFontHighlightSmall)
                t:SetButtonState("PUSHED", true)
            else
                t:SetNormalFontObject(GameFontNormalSmall)
                t:SetButtonState("NORMAL")
            end
        end
        if idx == 1 then
            combatContent:Show(); nonCombatContent:Hide(); classContent:Hide()
        elseif idx == 2 then
            combatContent:Hide(); nonCombatContent:Show(); classContent:Hide()
        else
            combatContent:Hide(); nonCombatContent:Hide(); classContent:Show()
        end
    end

    local classDisplayName = (NS.CLASS_DISPLAY and NS.CLASS_DISPLAY[class]) or class
    for j, lbl in ipairs({ "Combat", "Non-Combat", classDisplayName }) do
        local jj = j
        local itab = NS.CB_CreateButton(innerTabBar, "CleanBotInnerTab" .. tag .. "_" .. j,
                                        lbl, NS.TAB_WIDTH, NS.TAB_HEIGHT,
                                        function() selectInnerTab(jj) end)
        itab:SetPoint("LEFT", innerTabBar, "LEFT", NS.PAD + (j - 1) * (NS.TAB_WIDTH + 2), 0)
        itab:SetNormalFontObject(GameFontNormalSmall)
        innerTabBtns[j] = itab
    end
    selectInnerTab(1)

    local allFrames = {}

    CB_BuildTwoColumnContent(combatContent,    NS.STRATEGIES,    "co", slot, tag, allFrames, function(e) return e and e.combat    end)
    CB_BuildTwoColumnContent(nonCombatContent, NS.NC_STRATEGIES, "nc", slot, tag, allFrames, function(e) return e and e.nonCombat end)

    -- Class tab.
    local classFrames = CB_BuildClassTabContent(classContent, class, slot, tag)
    for _, cf in ipairs(classFrames) do allFrames[#allFrames + 1] = cf end

    return {
        container      = container,
        selectInnerTab = selectInnerTab,
        innerTabs      = { combatPanel = combatContent, nonCombatPanel = nonCombatContent, classPanel = classContent },
        frames         = allFrames,
    }
end

-- ============================================================
-- Unified tab selection — works for any index in NS.tabList (a slot)
-- ============================================================
local CleanBot_SelectTab  -- forward declaration (used inside slot closures)

CleanBot_SelectTab = function(index)
    if not index or index < 1 or index > #NS.tabList then return end
    local slot = NS.tabList[index]
    NS.selectedTabIndex = index
    NS.selectedBotKey   = slot.key

    for i, t in ipairs(NS.tabList) do
        local sel = (i == index)
        t.tabBtn:SetNormalFontObject(sel and GameFontHighlightSmall or GameFontNormalSmall)
        t.tabBtn:SetButtonState(sel and "PUSHED" or "NORMAL", sel)
        if sel then t.model:Show()  else t.model:Hide()  end
        if sel then t.ctrl:Show()   else t.ctrl:Hide()   end
    end

    if slot.name ~= NS.lastWavedAt then
        NS.lastWavedAt = slot.name
        NS.CB_SendBotCommand(slot.name, "emote wave")
    end
end

-- ============================================================
-- Slot pool — create / acquire / bind / unbind
--
-- A slot's container frames (tab button, model, ctrl) and per-class content
-- are created at most once each and reused across bots. Binding a slot to a
-- bot repoints the per-key registries to the slot's active frames so the
-- existing key-based sync paths (CB_UpdateTabData, the bridge) keep working.
-- ============================================================

-- Build the container frames for a new pool slot (once per slot index).
local function CB_CreateSlot(index)
    local contentW, contentH, modelH, eqColW, ctrlLeft = CB_GetGeometry()
    local slot = { index = index, contentByClass = {}, active = false }

    -- ── Tab button ────────────────────────────────────────────
    local tab = NS.CB_CreateButton(NS.botTabBar, "CleanBotCharTab" .. index,
                                   "", NS.TAB_WIDTH, NS.TAB_HEIGHT,
                                   function() CleanBot_SelectTab(slot._tabIdx) end)
    tab:SetNormalFontObject(GameFontNormalSmall)
    local icon = tab:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("LEFT", tab, "LEFT", 4, 0)
    icon:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
    tab:Hide()
    slot.tabBtn  = tab
    slot.tabIcon = icon

    -- ── Model (also builds star + equip slots, all class-agnostic) ──
    local model = NS.CB_CreateModel(slot, NS.partyContent, contentW, modelH)
    model:ClearAllPoints()
    model:SetPoint("TOPLEFT", NS.partyContent, "TOPLEFT", eqColW, 0)
    model:Hide()
    slot.model = model

    -- ── Ctrl container (holds the per-class content frames) ────
    local ctrl = CreateFrame("Frame", "CleanBotCtrl" .. index, NS.partyContent)
    ctrl:SetPoint("TOPLEFT",     NS.partyContent, "TOPLEFT",     ctrlLeft, -NS.PAD)
    ctrl:SetPoint("BOTTOMRIGHT", NS.partyContent, "BOTTOMRIGHT", -NS.PAD,   NS.PAD)
    ctrl:Hide()
    slot.ctrl = ctrl

    return slot
end

-- Returns a free slot from the pool, growing the pool if all are in use.
local function CB_AcquireSlot()
    for _, slot in ipairs(NS.tabPool) do
        if not slot.active then return slot end
    end
    local slot = CB_CreateSlot(#NS.tabPool + 1)
    NS.tabPool[#NS.tabPool + 1] = slot
    return slot
end

-- Builds (once) and returns the content handle for a class in this slot.
local function CB_EnsureContent(slot, class)
    local content = slot.contentByClass[class]
    if content then return content end
    local container = CreateFrame("Frame", nil, slot.ctrl)
    container:SetAllPoints(slot.ctrl)
    content = CB_BuildBotContent(container, slot, class, slot.index .. "_" .. class)
    slot.contentByClass[class] = content
    return content
end

-- Repoints all per-key registries at the slot's active frames.
local function CB_BindRegistries(slot)
    local k = slot.key
    local c = slot.activeContent
    NS.botStarUpdaters[k] = slot.updateStar
    NS.botEquipSlots[k]   = slot.equipSlots
    NS.botInnerTabs[k]    = c.innerTabs
    NS.botFrames[k]       = c.frames
end

-- Frees a slot: clears its key registries and hides its frames. The container
-- frames and per-class content persist on the slot for the next bind.
local function CB_UnbindSlot(slot)
    if slot.key then
        for _, reg in ipairs(NS.botRegistries) do reg[slot.key] = nil end
    end
    slot.active        = false
    slot.key           = nil
    slot.name          = nil
    slot.unit          = nil
    slot.class         = nil
    slot.activeContent = nil
    slot.tabBtn:Hide()
    slot.model:Hide()
    slot.ctrl:Hide()
end

-- Binds a slot to a bot: rebinds the model, swaps in the class content,
-- repoints registries, and syncs all widget state from the bot's data.
local function CB_BindSlot(slot, info)
    if slot.key and slot.key ~= info.key then
        for _, reg in ipairs(NS.botRegistries) do reg[slot.key] = nil end
    end

    slot.key    = info.key
    slot.name   = info.name
    slot.unit   = info.unit
    slot.class  = info.class
    slot.active = true

    -- Model + tab button identity
    slot.model:SetUnit(info.unit)
    slot.tabBtn:SetText("  " .. info.name)
    slot.tabIcon:SetTexCoord(unpack(NS.CLASS_ICON_COORDS[info.class] or NS.CLASS_ICON_COORDS["WARRIOR"]))
    slot.tabBtn:Show()

    -- Activate this class's content, hide the slot's other class contents
    local content = CB_EnsureContent(slot, info.class)
    for _, c in pairs(slot.contentByClass) do
        if c == content then c.container:Show() else c.container:Hide() end
    end
    slot.activeContent = content
    content.selectInnerTab(1)

    CB_BindRegistries(slot)

    -- Sync everything from data
    if slot.updateStar then slot.updateStar() end
    if NS.CB_RefreshEquipSlots then NS.CB_RefreshEquipSlots(slot.key, slot.unit) end
    NS.CB_UpdateTabData(info.key)
end

-- ============================================================
-- RefreshTabs — assigns desired party bots to pooled slots,
-- binding/rebinding/freeing only what changed.
-- ============================================================
NS.CleanBot_RefreshTabs = function()
    -- ── 1. Compute desired tab list ────────────────────────────
    local desired    = {}
    local numMembers = GetNumPartyMembers and GetNumPartyMembers() or 0
    for i = 1, numMembers do
        local unit = "party" .. i
        if UnitExists(unit) and NS.CleanBot_IsBot(unit) then
            local name = UnitName(unit)
            local _, class = UnitClass(unit)
            table.insert(desired, { unit = unit, name = name, class = class or "WARRIOR", key = strlower(name) })
        end
    end
    -- Prune CleanBot_PartyBots to only current party members
    local partyKeySet = {}
    for _, d in ipairs(desired) do partyKeySet[d.key] = true end
    for key in pairs(CleanBot_PartyBots) do
        if not partyKeySet[key] then CleanBot_PartyBots[key] = nil end
    end

    -- If targeting a current party bot, pre-select their tab
    if UnitExists("target") and UnitIsPlayer("target") then
        local targetKey = strlower(UnitName("target") or "")
        if CleanBot_PartyBots[targetKey] then NS.selectedBotKey = targetKey end
    end

    if NS.partyEmptyLabel then
        NS.partyEmptyLabel:SetText(#desired == 0 and "No bots found in party." or "")
    end

    -- ── 2. Free slots whose bot left the desired list ──────────
    local desiredByKey = {}
    for _, d in ipairs(desired) do desiredByKey[d.key] = true end
    local slotByKey = {}
    for _, slot in ipairs(NS.tabList) do
        if desiredByKey[slot.key] then
            slotByKey[slot.key] = slot
        else
            CB_UnbindSlot(slot)
        end
    end

    -- ── 3. Assign desired bots to slots (reuse, rebind, or acquire) ──
    local newTabList = {}
    local newlyBound = {}
    for i, d in ipairs(desired) do
        local slot = slotByKey[d.key]
        if slot then
            -- Same bot kept its slot; update unit / class if they shifted
            if slot.unit ~= d.unit then
                slot.unit = d.unit
                slot.model:SetUnit(d.unit)
            end
            if slot.class ~= d.class then
                CB_BindSlot(slot, d)
                newlyBound[#newlyBound + 1] = d
            end
        else
            slot = CB_AcquireSlot()
            CB_BindSlot(slot, d)
            newlyBound[#newlyBound + 1] = d
        end
        newTabList[i] = slot
    end
    NS.tabList = newTabList

    -- ── 4. Reposition tab buttons by display order ─────────────
    for i, slot in ipairs(NS.tabList) do
        slot._tabIdx = i
        slot.tabBtn:ClearAllPoints()
        slot.tabBtn:SetPoint("LEFT", NS.botTabBar, "LEFT", NS.PAD + (i - 1) * (NS.TAB_WIDTH + 2), 0)
    end

    -- ── 5. Equip refresh for newly-bound bots only ────────────
    if NS.CB_QueueEquipRefresh and #newlyBound > 0 then
        local toInspect = {}
        for _, d in ipairs(newlyBound) do
            if d.unit and UnitExists(d.unit) then
                table.insert(toInspect, { key = d.key, unit = d.unit })
            end
        end
        NS.CB_QueueEquipRefresh(toInspect)
    end

    -- ── 6. Restore or establish selection ─────────────────────
    if #NS.tabList == 0 then NS.selectedTabIndex = 0; return end
    local restoreIdx = nil
    if NS.selectedBotKey then
        for i, slot in ipairs(NS.tabList) do
            if slot.key == NS.selectedBotKey then restoreIdx = i; break end
        end
    end
    NS.selectedTabIndex = 0   -- force SelectTab to re-apply (slots may have rebound)
    CleanBot_SelectTab(restoreIdx or 1)
end

-- ============================================================
-- NS.CB_UpdateTabData — refreshes all UI elements for one tab
-- from CleanBot_PartyBots[key] without touching layout.
-- Call after any code that modifies a bot's combat/nonCombat data.
-- ============================================================
NS.CB_UpdateTabData = function(key)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    if NS.botStarUpdaters[key] then NS.botStarUpdaters[key]() end

    local function syncControls(controls, stratList, source)
        if not controls or not source then return end
        for _, s in ipairs(stratList) do
            local ctrl = controls[s.field]
            if not ctrl then
            elseif s.type == "timerDropdown" then
                local val = source[s.field]
                UIDropDownMenu_SetText(ctrl, val and (val .. " sec") or "")
                if s.dependsOn then
                    if source[s.dependsOn] then UIDropDownMenu_EnableDropDown(ctrl)
                    else UIDropDownMenu_DisableDropDown(ctrl) end
                end
            else
                ctrl:SetChecked(source[s.field] == true)
            end
        end
    end
    local function syncDropdown(dd, stratList, source)
        if not dd or not source then return nil end
        UIDropDownMenu_SetText(dd, "")
        for _, s in ipairs(stratList) do
            if source[s.field] == true then
                UIDropDownMenu_SetText(dd, s.name)
                return s.field
            end
        end
        return nil
    end

    local frames = NS.botFrames[key]
    if not frames then return end

    for _, cf in ipairs(frames) do
        local cd = cf.getSource and cf.getSource(entry)
        if cf.type == "dropdown" then
            syncDropdown(cf.dd, cf.strategies, cd)

        elseif cf.type == "checkboxes" then
            syncControls(cf.checkboxes, cf.strategies, cd)

        elseif cf.type == "roleDropdown" then
            local activeRole = syncDropdown(cf.dd, cf.strategies, cd)
            local count = 0
            if cd then
                for _, s in ipairs(cf.strategies) do
                    if cd[s.field] == true then count = count + 1 end
                end
            end
            if cf.multiRoleLabel then
                if count > 1 then cf.multiRoleLabel:Show() else cf.multiRoleLabel:Hide() end
            end
            for field, sub in pairs(cf.subSections) do
                if count <= 1 and activeRole == field then
                    sub.section:Show()
                else
                    sub.section:Hide()
                end
                syncControls(sub.checkboxes, sub.strategies, cd)
            end
        end
    end
end
