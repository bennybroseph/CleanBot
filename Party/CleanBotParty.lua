-- ============================================================
-- CleanBotParty.lua  —  character tab state, tab management,
--                        strategy section builders, RefreshTabs
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- Unified tab list and selection state
-- Each entry: { key, unit, name, class, isTarget, tabBtn, model, ctrl }
-- ============================================================
NS.tabList          = {}   -- ordered list of all active tabs (party + target)
NS.selectedTabIndex = 0    -- index into tabList of the currently shown tab
NS.selectedBotKey   = nil  -- key of selected tab; survives RefreshTabs rebuilds
NS.selectedIsTarget = false
NS.lastWavedAt      = nil

-- Per-key registries (keyed by strlower(botName))
NS.botRoleDDs        = {}
NS.botTankFrames     = {}
NS.botDpsFrames      = {}
NS.botHealFrames     = {}
NS.botCombatFrames   = {}
NS.botPositionFrames = {}
NS.botTimingFrames   = {}
NS.botInnerTabs      = {}
NS.botNcFrames       = {}
NS.botClassFrames    = {}
NS.botStarUpdaters   = {}
NS.botEquipSlots     = {}

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
    local eqStep   = math.floor(modelH / 8)
    local eqSlot   = math.floor(eqStep * 0.88)
    local eqGapX   = math.max(2, math.floor(modelW * 0.03))
    local eqColW   = eqSlot + eqGapX
    local ctrlLeft = eqColW + modelW + eqColW + NS.PAD
    return contentW, contentH, modelH, eqColW, ctrlLeft
end

-- ============================================================
-- Strategy section builder — shared by combat, non-combat, and class tabs.
-- onClickFn(strategy, checked) overrides the default "co +/-cmd" whisper.
-- Returns (sectionFrame, checkboxes) where checkboxes is keyed by field name.
-- ============================================================
local function CB_BuildStrategySection(ctrl, anchor, strategies, key, botName, counter, onClickFn)
    local section = CreateFrame("Frame", nil, ctrl)
    section:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -12)
    section:SetPoint("RIGHT",   ctrl,   "RIGHT",       0,   0)
    section:SetHeight(#strategies * 26)

    local checkboxes = {}
    for i, s in ipairs(strategies) do
        local cb = CreateFrame("CheckButton",
                               "CleanBotCB_" .. s.field .. "_" .. counter,
                               section, "UICheckButtonTemplate")
        cb:SetSize(20, 20)
        cb:SetPoint("TOPLEFT", section, "TOPLEFT", 4, -(i - 1) * 26)

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

        local cbEntry = CleanBot_PartyBots[key]
        cb:SetChecked(cbEntry and cbEntry.combat and cbEntry.combat[s.field] == true)

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
                SendChatMessage("co " .. toggle, "WHISPER", nil, botName)
                local e = CleanBot_PartyBots[strlower(botName)]
                if e and e.combat then
                    e.combat[cbField] = self:GetChecked() and true or false
                end
            end)
        end

        if NS.ElvUI_S then NS.ElvUI_S:HandleCheckBox(cb) end
        checkboxes[s.field] = cb
    end

    return section, checkboxes
end

-- Returns the party unit ID for a bot by name, or nil.
local function CB_GetBotUnit(name)
    for i = 1, GetNumPartyMembers() do
        local unit = "party" .. i
        if UnitName(unit) == name then return unit end
    end
    return nil
end

-- ============================================================
-- CB_BuildTalentGroup
-- Renders: header → Show Talents btn → Set Talents btn → whisper dropdown.
-- Used for the full-width spec group and any whisper dropdown inside a column.
-- prevBottom=nil anchors the header to parent's TOPLEFT; otherwise to prevBottom.
-- Returns the Set Talents button, which becomes the next prevBottom.
-- ============================================================
local function CB_BuildTalentGroup(parent, prevBottom, group, botName, counter, gi)
    local strategies  = group.strategies
    local specWhisper = group.whisper

    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if prevBottom then
        header:SetPoint("TOPLEFT", prevBottom, "BOTTOMLEFT", 0, -12)
    else
        header:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -10)
    end
    header:SetText(group.header)

    local showBtn = CreateFrame("Button", "CleanBotShowTal_" .. counter .. "_" .. gi,
                                parent, "UIPanelButtonTemplate")
    showBtn:SetSize(100, 22)
    showBtn:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    showBtn:SetText("Show Talents")
    showBtn:SetScript("OnClick", function()
        local unit = CB_GetBotUnit(botName)
        if not unit then return end
        InspectUnit(unit)
        for i = 1, 10 do
            local tab = _G["InspectFrameTab" .. i]
            if not tab then break end
            local text = tab:GetText()
            if text and strfind(strlower(text), "talent") then tab:Click(); break end
        end
    end)
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(showBtn) end

    local setBtn = CreateFrame("Button", "CleanBotSetTal_" .. counter .. "_" .. gi .. "s",
                               parent, "UIPanelButtonTemplate")
    setBtn:SetSize(100, 22)
    setBtn:SetPoint("TOPLEFT", showBtn, "BOTTOMLEFT", 0, -4)
    setBtn:SetText("Set Talents")
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(setBtn) end

    local dd = CreateFrame("Frame", "CleanBotClassDD_" .. counter .. "_" .. gi,
                           parent, "UIDropDownMenuTemplate")
    dd:SetPoint("LEFT", setBtn, "RIGHT", -10, 0)
    UIDropDownMenu_SetWidth(dd, 130)
    if NS.ElvUI_S then NS.ElvUI_S:HandleDropDownBox(dd, 130) end

    local ddInfo = { selectedCmd = nil }
    local entry  = CleanBot_PartyBots[strlower(botName)]
    local cd     = entry and entry.classData and entry.classData.combat
    UIDropDownMenu_Initialize(dd, function(self)
        for _, s in ipairs(strategies) do
            local info           = UIDropDownMenu_CreateInfo()
            info.text            = s.name
            info.value           = s.field
            info.tooltipTitle    = s.name
            info.tooltipText     = s.desc
            info.tooltipOnButton = 1
            info.func            = function()
                UIDropDownMenu_SetText(self, s.name)
                ddInfo.selectedCmd = s.cmd
                local e = CleanBot_PartyBots[strlower(botName)]
                if e and e.classData then
                    for _, rs in ipairs(strategies) do
                        e.classData.combat[rs.field] = (rs.field == s.field)
                    end
                end
            end
            info.checked = cd and (cd[s.field] == true)
            UIDropDownMenu_AddButton(info)
        end
    end)
    if cd then
        for _, s in ipairs(strategies) do
            if cd[s.field] == true then
                UIDropDownMenu_SetText(dd, s.name)
                ddInfo.selectedCmd = s.cmd
                break
            end
        end
    end
    setBtn:SetScript("OnClick", function()
        if ddInfo.selectedCmd then
            SendChatMessage(specWhisper .. " " .. ddInfo.selectedCmd, "WHISPER", nil, botName)
        end
    end)

    return setBtn
end

-- ============================================================
-- CB_BuildColumnGroups
-- Renders one column's worth of class strategy groups into `col`.
-- cmd       = "co" or "nc"
-- dataField = "combat" or "nonCombat" (key into entry.classData)
-- startGi   = first group index to process (used to skip spec group on left col)
-- ============================================================
local function CB_BuildColumnGroups(col, groups, cmd, dataField, key, botName, counter, startGi)
    local entry      = CleanBot_PartyBots[key]
    local prevBottom = nil

    for gi = (startGi or 1), #groups do
        local group = groups[gi]

        if group.type == "dropdown" and group.whisper then
            -- Talent/whisper group: Show Talents + Set Talents + whisper dropdown
            prevBottom = CB_BuildTalentGroup(col, prevBottom, group, botName, counter, gi)

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

            local dd = CreateFrame("Frame", "CleanBotClassDD_" .. cmd .. counter .. "_" .. gi,
                                   col, "UIDropDownMenuTemplate")
            dd:SetPoint("TOPLEFT", header, "BOTTOMLEFT", -16, -4)
            UIDropDownMenu_SetWidth(dd, 160)
            if NS.ElvUI_S then NS.ElvUI_S:HandleDropDownBox(dd, 160) end

            local cd = entry and entry.classData and entry.classData[dataField]
            UIDropDownMenu_Initialize(dd, function(self)
                for _, s in ipairs(strategies) do
                    local info           = UIDropDownMenu_CreateInfo()
                    info.text            = s.name
                    info.value           = s.field
                    info.tooltipTitle    = s.name
                    info.tooltipText     = s.desc
                    info.tooltipOnButton = 1
                    info.func            = function()
                        UIDropDownMenu_SetText(self, s.name)
                        local parts = {}
                        for _, rs in ipairs(strategies) do
                            parts[#parts + 1] = (rs.field == s.field and "+" or "-") .. rs.cmd
                        end
                        SendChatMessage(cmd .. " " .. table.concat(parts, ","), "WHISPER", nil, botName)
                        local e = CleanBot_PartyBots[strlower(botName)]
                        if e and e.classData then
                            for _, rs in ipairs(strategies) do
                                e.classData[dataField][rs.field] = (rs.field == s.field)
                            end
                        end
                    end
                    info.checked = cd and (cd[s.field] == true)
                    UIDropDownMenu_AddButton(info)
                end
            end)
            if cd then
                for _, s in ipairs(strategies) do
                    if cd[s.field] == true then UIDropDownMenu_SetText(dd, s.name); break end
                end
            end
            if group.readonly then UIDropDownMenu_DisableDropDown(dd) end

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

            local section, checkboxes = CB_BuildStrategySection(col, header, group.strategies, key, botName, counter,
                function(s, checked)
                    local toggle = (checked and "+" or "-") .. s.cmd
                    SendChatMessage(cmd .. " " .. toggle, "WHISPER", nil, botName)
                    local e = CleanBot_PartyBots[strlower(botName)]
                    if e and e.classData then e.classData[dataField][s.field] = checked end
                end)
            if entry and entry.classData and entry.classData[dataField] then
                for _, s in ipairs(group.strategies) do
                    local cb = checkboxes[s.field]
                    if cb then cb:SetChecked(entry.classData[dataField][s.field] == true) end
                end
            end
            section:Show()
            prevBottom = section
        end
    end
end

-- ============================================================
-- Class tab content builder
-- ============================================================
local function CB_BuildClassTabContent(classContent, class, key, botName, counter)
    local cs = NS.CLASS_STRATEGIES and NS.CLASS_STRATEGIES[class]

    if not cs or (not cs.combat and not cs.nonCombat) then
        local label = classContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", classContent, "TOPLEFT", 12, -12)
        label:SetText("No class-specific options.")
        NS.botClassFrames[key] = {}
        return
    end

    -- Spec group: full-width above both columns (first combat group with a whisper field)
    local specGroup     = cs.combat and cs.combat[1] and cs.combat[1].whisper and cs.combat[1] or nil
    local combatStartGi = specGroup and 2 or 1
    local colTopAnchor  = specGroup and CB_BuildTalentGroup(classContent, nil, specGroup, botName, counter, 1) or nil

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

    if cs.combat   then CB_BuildColumnGroups(leftCol,  cs.combat,    "co", "combat",    key, botName, counter, combatStartGi) end
    if cs.nonCombat then CB_BuildColumnGroups(rightCol, cs.nonCombat, "nc", "nonCombat", key, botName, counter, 1)            end

    NS.botClassFrames[key] = {}
end

-- ============================================================
-- CB_BuildBotContent
-- Builds the inner tab bar and all combat/non-combat/class
-- content for one bot inside the provided ctrl frame.
-- ============================================================
local function CB_BuildBotContent(ctrl, key, botName, botClass, entry, counter)
    local innerTabBar = CreateFrame("Frame", nil, ctrl)
    innerTabBar:SetPoint("TOPLEFT",  ctrl, "TOPLEFT",  0, 0)
    innerTabBar:SetPoint("TOPRIGHT", ctrl, "TOPRIGHT", 0, 0)
    innerTabBar:SetHeight(NS.BOT_BAR_H)

    local contentBg = CreateFrame("Frame", nil, ctrl)
    contentBg:SetPoint("TOPLEFT",     ctrl, "TOPLEFT",     0, -NS.BOT_BAR_H)
    contentBg:SetPoint("BOTTOMRIGHT", ctrl, "BOTTOMRIGHT", 0, 0)
    NS.CB_ApplyInnerSkin(contentBg)

    local combatContent = CreateFrame("Frame", nil, ctrl)
    combatContent:SetPoint("TOPLEFT",     ctrl, "TOPLEFT",     0, -NS.BOT_BAR_H)
    combatContent:SetPoint("BOTTOMRIGHT", ctrl, "BOTTOMRIGHT", 0, 0)

    local nonCombatContent = CreateFrame("Frame", nil, ctrl)
    nonCombatContent:SetPoint("TOPLEFT",     ctrl, "TOPLEFT",     0, -NS.BOT_BAR_H)
    nonCombatContent:SetPoint("BOTTOMRIGHT", ctrl, "BOTTOMRIGHT", 0, 0)
    nonCombatContent:Hide()

    local classContent = CreateFrame("Frame", nil, ctrl)
    classContent:SetPoint("TOPLEFT",     ctrl, "TOPLEFT",     0, -NS.BOT_BAR_H)
    classContent:SetPoint("BOTTOMRIGHT", ctrl, "BOTTOMRIGHT", 0, 0)
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

    local classDisplayName = (NS.CLASS_DISPLAY and NS.CLASS_DISPLAY[botClass]) or botClass
    for j, lbl in ipairs({ "Combat", "Non-Combat", classDisplayName }) do
        local itab = CreateFrame("Button", "CleanBotInnerTab" .. counter .. "_" .. j,
                                 innerTabBar, "UIPanelButtonTemplate")
        itab:SetSize(NS.TAB_WIDTH, NS.TAB_HEIGHT)
        itab:SetPoint("LEFT", innerTabBar, "LEFT", NS.PAD + (j - 1) * (NS.TAB_WIDTH + 2), 0)
        itab:SetText(lbl)
        itab:SetNormalFontObject(GameFontNormalSmall)
        local jj = j
        itab:SetScript("OnClick", function() selectInnerTab(jj) end)
        if NS.ElvUI_S then NS.ElvUI_S:HandleButton(itab) end
        innerTabBtns[j] = itab
    end
    selectInnerTab(1)

    NS.botInnerTabs[key] = {
        combatPanel    = combatContent,
        nonCombatPanel = nonCombatContent,
        classPanel     = classContent,
    }

    CB_BuildClassTabContent(classContent, botClass, key, botName, counter)

    local ncHeader = nonCombatContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ncHeader:SetPoint("TOPLEFT", nonCombatContent, "TOPLEFT", 12, -10)
    ncHeader:SetText("General")

    local ncSection, ncCheckboxes = CB_BuildStrategySection(
        nonCombatContent, ncHeader, NS.NC_GENERAL_STRATEGIES, key, botName, counter,
        function(s, checked)
            local toggle = (checked and "+" or "-") .. s.cmd
            SendChatMessage("nc " .. toggle, "WHISPER", nil, botName)
            local e = CleanBot_PartyBots[strlower(botName)]
            if e and e.nonCombat then e.nonCombat[s.field] = checked end
        end)
    if entry and entry.nonCombat then
        for _, s in ipairs(NS.NC_GENERAL_STRATEGIES) do
            local cb = ncCheckboxes[s.field]
            if cb then cb:SetChecked(entry.nonCombat[s.field] == true) end
        end
    end
    ncSection:Show()
    NS.botNcFrames[key] = { section = ncSection, checkboxes = ncCheckboxes }

    local leftCol = CreateFrame("Frame", nil, combatContent)
    leftCol:SetPoint("TOPLEFT",     combatContent, "TOPLEFT", 0,  0)
    leftCol:SetPoint("BOTTOMRIGHT", combatContent, "BOTTOM",  -4, 0)

    local rightCol = CreateFrame("Frame", nil, combatContent)
    rightCol:SetPoint("TOPLEFT",     combatContent, "TOP",         4, 0)
    rightCol:SetPoint("BOTTOMRIGHT", combatContent, "BOTTOMRIGHT", 0, 0)

    local roleLabel = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    roleLabel:SetPoint("TOPLEFT", leftCol, "TOPLEFT", 8, -10)
    roleLabel:SetText("Role")

    local activeRole  = nil
    local activeCount = 0
    if entry and entry.combat then
        for _, s in ipairs(NS.ROLE_STRATEGIES) do
            if entry.combat[s.field] == true then
                activeCount = activeCount + 1
                if not activeRole then activeRole = s.field end
            end
        end
    end
    local multipleRoles = activeCount > 1

    local multiRoleLabel = leftCol:CreateFontString(nil, "OVERLAY", "GameFontRed")
    multiRoleLabel:SetPoint("TOPLEFT", roleLabel, "BOTTOMLEFT", 4, -8)
    multiRoleLabel:SetText("Multiple Roles Selected")
    if multipleRoles then multiRoleLabel:Show() else multiRoleLabel:Hide() end

    local dd = CreateFrame("Frame", "CleanBotRoleDD" .. counter, leftCol, "UIDropDownMenuTemplate")
    dd:SetPoint("LEFT", roleLabel, "RIGHT", 2, -2)
    UIDropDownMenu_SetWidth(dd, 90)
    if NS.ElvUI_S then NS.ElvUI_S:HandleDropDownBox(dd, 90) end
    UIDropDownMenu_Initialize(dd, function(self)
        for _, s in ipairs(NS.ROLE_STRATEGIES) do
            local info           = UIDropDownMenu_CreateInfo()
            info.text            = s.name
            info.value           = s.field
            info.tooltipTitle    = s.name
            info.tooltipText     = s.desc
            info.tooltipOnButton = 1
            info.func            = function()
                UIDropDownMenu_SetText(self, s.name)
                local parts = {}
                for _, rs in ipairs(NS.ROLE_STRATEGIES) do
                    parts[#parts + 1] = (rs.field == s.field and "+" or "-") .. rs.cmd
                end
                SendChatMessage("co " .. table.concat(parts, ","), "WHISPER", nil, botName)
                local e = CleanBot_PartyBots[strlower(botName)]
                if e and e.combat then
                    for _, rs in ipairs(NS.ROLE_STRATEGIES) do
                        e.combat[rs.field] = (rs.field == s.field)
                    end
                end
                local bk = strlower(botName)
                local function showIf(tbl, roleField)
                    if tbl[bk] then
                        if s.field == roleField then tbl[bk].section:Show()
                        else                         tbl[bk].section:Hide() end
                    end
                end
                showIf(NS.botTankFrames, "isTank")
                showIf(NS.botDpsFrames,  "isDPS")
                showIf(NS.botHealFrames, "isHealer")
                multiRoleLabel:Hide()
            end
            info.checked = entry and entry.combat and (entry.combat[s.field] == true)
            UIDropDownMenu_AddButton(info)
        end
    end)
    if entry and entry.combat then
        for _, s in ipairs(NS.ROLE_STRATEGIES) do
            if entry.combat[s.field] == true then
                UIDropDownMenu_SetText(dd, s.name)
                break
            end
        end
    end
    NS.botRoleDDs[key] = dd

    local ROLE_AREA_H = math.max(#NS.TANK_STRATEGIES, #NS.DPS_STRATEGIES, #NS.HEAL_STRATEGIES) * 26

    local tankSection, tankCBs = CB_BuildStrategySection(leftCol, roleLabel, NS.TANK_STRATEGIES, key, botName, counter)
    if not multipleRoles and activeRole == "isTank" then tankSection:Show() else tankSection:Hide() end
    NS.botTankFrames[key] = { section = tankSection, checkboxes = tankCBs }

    local dpsSection, dpsCBs = CB_BuildStrategySection(leftCol, roleLabel, NS.DPS_STRATEGIES, key, botName, counter)
    if not multipleRoles and activeRole == "isDPS" then dpsSection:Show() else dpsSection:Hide() end
    NS.botDpsFrames[key] = { section = dpsSection, checkboxes = dpsCBs }

    local healSection, healCBs = CB_BuildStrategySection(leftCol, roleLabel, NS.HEAL_STRATEGIES, key, botName, counter)
    if not multipleRoles and activeRole == "isHealer" then healSection:Show() else healSection:Hide() end
    NS.botHealFrames[key] = { section = healSection, checkboxes = healCBs }

    local roleAreaEnd = CreateFrame("Frame", nil, leftCol)
    roleAreaEnd:SetSize(1, 1)
    roleAreaEnd:SetPoint("TOPLEFT", roleLabel, "BOTTOMLEFT", 0, -(12 + ROLE_AREA_H))

    local combatHeader = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    combatHeader:SetPoint("TOPLEFT", roleAreaEnd, "TOPLEFT", 4, -10)
    combatHeader:SetText("Combat Control")

    local combatSection, combatCBs = CB_BuildStrategySection(leftCol, combatHeader, NS.COMBAT_STRATEGIES, key, botName, counter)
    combatSection:Show()
    NS.botCombatFrames[key] = { section = combatSection, checkboxes = combatCBs }

    local posHeader = rightCol:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    posHeader:SetPoint("TOPLEFT", rightCol, "TOPLEFT", 4, -10)
    posHeader:SetText("Positioning")

    local posSection, posCBs = CB_BuildStrategySection(rightCol, posHeader, NS.POSITION_STRATEGIES, key, botName, counter)
    posSection:Show()
    NS.botPositionFrames[key] = { section = posSection, checkboxes = posCBs }

    local timingHeader = rightCol:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    timingHeader:SetPoint("TOPLEFT", posSection, "BOTTOMLEFT", 4, -12)
    timingHeader:SetText("Timing & Marking")

    local timingSection, timingCBs = CB_BuildStrategySection(rightCol, timingHeader, NS.TIMING_STRATEGIES, key, botName, counter)
    timingSection:Show()
    NS.botTimingFrames[key] = { section = timingSection, checkboxes = timingCBs }
end

-- ============================================================
-- Tab lifecycle helpers
-- ============================================================

-- Tears down all frames for one tab entry and clears its per-key registry slots.
-- Deparenting ctrl is sufficient — all content frames are children of ctrl.
local function CB_TearDownTabEntry(info)
    if info.tabBtn then info.tabBtn:Hide(); info.tabBtn:SetParent(nil) end
    if info.model then
        if info.model._dragCapture then
            info.model._dragCapture:Hide()
            info.model._dragCapture:SetParent(nil)
        end
        info.model:Hide(); info.model:SetParent(nil)
    end
    if info.ctrl then info.ctrl:Hide(); info.ctrl:SetParent(nil) end
    local k = info.key
    NS.botStarUpdaters[k]    = nil
    NS.botEquipSlots[k]      = nil
    NS.botRoleDDs[k]         = nil
    NS.botTankFrames[k]      = nil
    NS.botDpsFrames[k]       = nil
    NS.botHealFrames[k]      = nil
    NS.botCombatFrames[k]    = nil
    NS.botPositionFrames[k]  = nil
    NS.botTimingFrames[k]    = nil
    NS.botInnerTabs[k]       = nil
    NS.botNcFrames[k]        = nil
    NS.botClassFrames[k]     = nil
end

local function CleanBot_ClearTabs()
    for _, info in ipairs(NS.tabList) do
        CB_TearDownTabEntry(info)
    end
    NS.tabList          = {}
    NS.selectedTabIndex = 0
    -- Bulk-clear registries (CB_TearDownTabEntry nils per-key; this handles any stragglers)
    NS.botRoleDDs = {}; NS.botTankFrames = {}; NS.botDpsFrames = {}
    NS.botHealFrames = {}; NS.botCombatFrames = {}; NS.botPositionFrames = {}
    NS.botTimingFrames = {}; NS.botInnerTabs = {}; NS.botNcFrames = {}
    NS.botClassFrames = {}; NS.botStarUpdaters = {}; NS.botEquipSlots = {}
end

-- ============================================================
-- Unified tab selection — works for any index in NS.tabList
-- ============================================================
local CleanBot_SelectTab  -- forward declaration (used inside CB_BuildTabEntry closures)

CleanBot_SelectTab = function(index)
    if not index or index < 1 or index > #NS.tabList then return end
    local info = NS.tabList[index]
    NS.selectedTabIndex = index
    NS.selectedBotKey   = info.key
    NS.selectedIsTarget = info.isTarget or false

    for i, t in ipairs(NS.tabList) do
        local sel = (i == index)
        t.tabBtn:SetNormalFontObject(sel and GameFontHighlightSmall or GameFontNormalSmall)
        t.tabBtn:SetButtonState(sel and "PUSHED" or "NORMAL", sel)
        if t.model then if sel then t.model:Show() else t.model:Hide() end end
        if t.ctrl  then if sel then t.ctrl:Show()  else t.ctrl:Hide()  end end
    end

    if info.name ~= NS.lastWavedAt then
        NS.lastWavedAt = info.name
        SendChatMessage("emote wave", "WHISPER", nil, info.name)
    end
end

-- ============================================================
-- CB_GetTargetEntry — returns a tab descriptor for the current
-- target if it is a known bot, or nil.
-- ============================================================
local function CB_GetTargetEntry()
    if not UnitExists("target") or not UnitIsPlayer("target") then return nil end
    local name = UnitName("target")
    if not name then return nil end
    local key   = strlower(name)
    if not CleanBot_PartyBots[key] then return nil end
    local _, class = UnitClass("target")
    return { unit = "target", name = name, class = class or "WARRIOR", key = key, isTarget = true }
end

-- ============================================================
-- CB_BuildTabEntry — builds all frames for one tab slot.
-- info = { key, unit, name, class, [isTarget] }
-- index = position in NS.tabList (governs tab button X offset).
-- Stores tabBtn, model, ctrl back onto info.
-- ============================================================
local function CB_BuildTabEntry(info, index)
    NS.tabCounter = NS.tabCounter + 1
    local counter = NS.tabCounter
    local contentW, contentH, modelH, eqColW, ctrlLeft = CB_GetGeometry()

    -- ── Tab button ────────────────────────────────────────────
    local tab = CreateFrame("Button", "CleanBotCharTab" .. counter,
                            NS.botTabBar, "UIPanelButtonTemplate")
    tab:SetSize(NS.TAB_WIDTH, NS.TAB_HEIGHT)
    tab:SetPoint("LEFT", NS.botTabBar, "LEFT", NS.PAD + (index - 1) * (NS.TAB_WIDTH + 2), 0)
    tab:SetNormalFontObject(GameFontNormalSmall)

    tab:SetText("  " .. info.name)
    local icon = tab:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("LEFT", tab, "LEFT", 4, 0)
    icon:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
    local coords = NS.CLASS_ICON_COORDS[info.class] or NS.CLASS_ICON_COORDS["WARRIOR"]
    icon:SetTexCoord(unpack(coords))

    info._tabIdx = index
    tab:SetScript("OnClick", function() CleanBot_SelectTab(info._tabIdx) end)
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(tab) end
    info.tabBtn = tab

    -- ── Model ─────────────────────────────────────────────────
    local model = NS.CB_CreateModel(NS.partyContent, contentW, modelH, info.unit, info.key, counter)
    model:ClearAllPoints()
    model:SetPoint("TOPLEFT", NS.partyContent, "TOPLEFT", eqColW, 0)
    info.model = model

    -- ── Ctrl panel ────────────────────────────────────────────
    local ctrl = CreateFrame("Frame", "CleanBotCtrl" .. counter, NS.partyContent)
    ctrl:SetPoint("TOPLEFT",     NS.partyContent, "TOPLEFT",     ctrlLeft, -NS.PAD)
    ctrl:SetPoint("BOTTOMRIGHT", NS.partyContent, "BOTTOMRIGHT", -NS.PAD,   NS.PAD)
    ctrl:Hide()
    info.ctrl = ctrl

    local entry = CleanBot_PartyBots[info.key]
    CB_BuildBotContent(ctrl, info.key, info.name, info.class, entry, counter)

    -- Send co ? on first visit to a target tab bot
    if info.isTarget and entry and not entry.queried then
        entry.queried    = true
        entry.awaitingCo = true
        entry.awaitingNc = false
        SendChatMessage("co ?", "WHISPER", nil, info.name)
    end

end

-- Updates a tab button's position and stored index after a list reshuffle.
local function CB_RepositionTabButton(info, index)
    info._tabIdx = index
    info.tabBtn:ClearAllPoints()
    info.tabBtn:SetPoint("LEFT", NS.botTabBar, "LEFT", NS.PAD + (index - 1) * (NS.TAB_WIDTH + 2), 0)
end

-- ============================================================
-- RefreshTabs — diff-based: only adds/removes/repositions what changed.
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

    local partyBotCount = #desired
    local targetEntry = CB_GetTargetEntry()
    if targetEntry then
        local inParty = false
        for _, d in ipairs(desired) do
            if d.key == targetEntry.key then inParty = true; break end
        end
        if inParty then
            -- Target is already a party tab — select it instead of creating a duplicate
            NS.selectedBotKey   = targetEntry.key
            NS.selectedIsTarget = false
        else
            table.insert(desired, targetEntry)
            NS.selectedIsTarget = true
        end
    end

    if NS.partyEmptyLabel then
        NS.partyEmptyLabel:SetText(#desired == 0 and "No bots found in party." or "")
    end

    -- ── 2. Build lookups ───────────────────────────────────────
    local currentByKey = {}
    for _, info in ipairs(NS.tabList) do currentByKey[info.key] = info end

    local newTabList  = {}
    local newEntries  = {}
    local desiredByKey = {}
    for i, d in ipairs(desired) do
        desiredByKey[d.key] = true
        local existing = currentByKey[d.key]
        if existing then
            -- Keep existing tab; update unit if it shifted party slots
            if existing.unit ~= d.unit then
                existing.unit = d.unit
                if existing.model then existing.model:SetUnit(d.unit) end
            end
            newTabList[i] = existing
        else
            newTabList[i] = d
            newEntries[#newEntries + 1] = { info = d, index = i }
        end
    end

    -- ── 3. Tear down tabs no longer in the desired list ────────
    for _, info in ipairs(NS.tabList) do
        if not desiredByKey[info.key] then CB_TearDownTabEntry(info) end
    end
    NS.tabList = newTabList

    -- ── 4. Build frames for new entries ───────────────────────
    for _, e in ipairs(newEntries) do CB_BuildTabEntry(e.info, e.index) end

    -- ── 5. Reposition all tab buttons ─────────────────────────
    for i, info in ipairs(NS.tabList) do CB_RepositionTabButton(info, i) end

    -- ── 6. Equip refresh for new entries only ─────────────────
    if NS.CB_QueueEquipRefresh and #newEntries > 0 then
        local toInspect = {}
        for _, e in ipairs(newEntries) do
            if e.info.unit and UnitExists(e.info.unit) then
                table.insert(toInspect, e.info)
            end
        end
        NS.CB_QueueEquipRefresh(toInspect)
    end

    -- ── 7. Restore or establish selection ─────────────────────
    if #NS.tabList == 0 then return end
    local restoreIdx = nil
    if NS.selectedIsTarget then
        for i, info in ipairs(NS.tabList) do
            if info.isTarget then restoreIdx = i; break end
        end
    elseif NS.selectedBotKey then
        for i, info in ipairs(NS.tabList) do
            if info.key == NS.selectedBotKey then restoreIdx = i; break end
        end
    end
    CleanBot_SelectTab(restoreIdx or NS.selectedTabIndex or 1)
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

    local combat     = entry.combat or {}
    local activeRole = nil
    if NS.botRoleDDs[key] then
        for _, s in ipairs(NS.ROLE_STRATEGIES) do
            if combat[s.field] == true then
                UIDropDownMenu_SetText(NS.botRoleDDs[key], s.name)
                activeRole = s.field; break
            end
        end
    end

    local function syncSection(tbl, roleField, stratList)
        local data = tbl[key]; if not data then return end
        if activeRole == roleField then data.section:Show() else data.section:Hide() end
        for _, s in ipairs(stratList) do
            local cb = data.checkboxes[s.field]
            if cb then cb:SetChecked(combat[s.field] == true) end
        end
    end
    syncSection(NS.botTankFrames,  "isTank",   NS.TANK_STRATEGIES)
    syncSection(NS.botDpsFrames,   "isDPS",    NS.DPS_STRATEGIES)
    syncSection(NS.botHealFrames,  "isHealer", NS.HEAL_STRATEGIES)

    local function syncCheckboxes(tbl, stratList)
        local data = tbl[key]; if not data then return end
        for _, s in ipairs(stratList) do
            local cb = data.checkboxes[s.field]
            if cb then cb:SetChecked(combat[s.field] == true) end
        end
    end
    syncCheckboxes(NS.botCombatFrames,   NS.COMBAT_STRATEGIES)
    syncCheckboxes(NS.botPositionFrames, NS.POSITION_STRATEGIES)
    syncCheckboxes(NS.botTimingFrames,   NS.TIMING_STRATEGIES)

    local nonCombat = entry.nonCombat or {}
    if NS.botNcFrames[key] then
        for _, s in ipairs(NS.NC_GENERAL_STRATEGIES) do
            local cb = NS.botNcFrames[key].checkboxes[s.field]
            if cb then cb:SetChecked(nonCombat[s.field] == true) end
        end
    end
end
