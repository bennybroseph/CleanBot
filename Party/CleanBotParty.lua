-- ============================================================
-- CleanBotParty.lua  —  character tab state, tab management,
--                        strategy section builders, RefreshTabs
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- Per-bot frame registries  (reset on each RefreshTabs call)
-- ============================================================
NS.activeBotTabs    = {}
NS.activeBotNames   = {}  -- [tabIndex] = { name, unit, key }
NS.activeTabIndex   = 0
NS.selectedBotKey    = nil   -- strlower name of the currently selected bot; survives rebuilds
NS.selectedIsTarget  = false -- true when the Target tab is active; keeps it selected while cycling targets
NS.lastWavedAt      = nil -- bot name we most recently sent a wave to
NS.botModelFrames   = {}
NS.botControlFrames = {}
NS.botRoleDDs        = {}
NS.botTankFrames     = {}
NS.botDpsFrames      = {}
NS.botHealFrames     = {}
NS.botCombatFrames   = {}
NS.botPositionFrames = {}
NS.botTimingFrames   = {}
NS.botInnerTabs      = {}
NS.botNcFrames       = {}
-- { [key] = { combatCheckboxes = {field->cb}, nonCombatCheckboxes = {field->cb} } }
NS.botClassFrames    = {}
-- { [key] = UpdateStar fn } — call after toggling favoriteBots to refresh the star
NS.botStarUpdaters   = {}

-- ============================================================
-- Internal tab helpers
-- ============================================================
local function CleanBot_ClearTabs()
    for _, tab in ipairs(NS.activeBotTabs) do
        tab:Hide(); tab:SetParent(nil)
    end
    NS.activeBotTabs = {}
    for _, model in ipairs(NS.botModelFrames) do
        model:Hide(); model:SetParent(nil)
    end
    NS.botModelFrames = {}
    for _, ctrl in ipairs(NS.botControlFrames) do
        ctrl:Hide(); ctrl:SetParent(nil)
    end
    NS.botControlFrames  = {}
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
    NS.activeBotNames    = {}
    NS.activeTabIndex    = 0
end

local CleanBot_SelectTab
CleanBot_SelectTab = function(index)
    -- Always update selection state so RefreshTabs can restore it after rebuilds
    local info = NS.activeBotNames and NS.activeBotNames[index]
    NS.selectedBotKey   = info and info.key
    NS.selectedIsTarget = info and info.isTarget or false

    if NS.activeTabIndex == index then return end
    NS.activeTabIndex = index

    for i, tab in ipairs(NS.activeBotTabs) do
        if i == index then
            tab:SetNormalFontObject(GameFontHighlightSmall)
            tab:SetButtonState("PUSHED", true)
        else
            tab:SetNormalFontObject(GameFontNormalSmall)
            tab:SetButtonState("NORMAL")
        end
    end
    for i, model in ipairs(NS.botModelFrames) do
        if i == index then
            model:Show()
        else
            model:Hide()
        end
    end
    for i, ctrl in ipairs(NS.botControlFrames) do
        if i == index then ctrl:Show() else ctrl:Hide() end
    end

    if info and info.name ~= NS.lastWavedAt then
        NS.lastWavedAt = info.name
        SendChatMessage("emote wave", "WHISPER", nil, info.name)
    end
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

        local cbEntry = CleanBot_KnownBots[key]
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
                local e = CleanBot_KnownBots[strlower(botName)]
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
-- Class tab content builder
-- Lays out class-specific combat (left col) and non-combat (right col) groups.
-- Groups with type="dropdown" render a UIDropDownMenu (exclusive selection).
-- Populates NS.botClassFrames[key] with checkbox and dropdown registries.
-- ============================================================
local function CB_BuildClassTabContent(classContent, class, key, botName, counter)
    local cs    = NS.CLASS_STRATEGIES and NS.CLASS_STRATEGIES[class]
    local entry = CleanBot_KnownBots[key]

    local combatCBs    = {}
    local nonCombatCBs = {}
    local combatDDs    = {}
    local nonCombatDDs = {}

    if not cs or (not cs.combat and not cs.nonCombat) then
        local label = classContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", classContent, "TOPLEFT", 12, -12)
        label:SetText("No class-specific options.")
        NS.botClassFrames[key] = {
            combatCheckboxes    = combatCBs,
            nonCombatCheckboxes = nonCombatCBs,
            combatDropdowns     = combatDDs,
            nonCombatDropdowns  = nonCombatDDs,
        }
        return
    end

    -- ── Spec group: rendered full-width above both columns ───────
    -- The first combat group with a whisper field is the Spec selector.
    -- It spans the top of classContent so both columns can start at the same Y.
    local specGroup     = cs.combat and cs.combat[1] and cs.combat[1].whisper and cs.combat[1] or nil
    local combatStartGi = specGroup and 2 or 1  -- index to start remaining combat groups from
    local colTopAnchor  = nil                   -- set to setBtn bottom after Spec is rendered

    if specGroup then
        local gi          = 1
        local strategies  = specGroup.strategies
        local specWhisper = specGroup.whisper

        local header = classContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        header:SetPoint("TOPLEFT", classContent, "TOPLEFT", 8, -10)
        header:SetText(specGroup.header)

        local showBtn = CreateFrame("Button",
            "CleanBotShowTal_" .. counter .. "_" .. gi,
            classContent, "UIPanelButtonTemplate")
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
                if text and strfind(strlower(text), "talent") then
                    tab:Click()
                    break
                end
            end
        end)
        if NS.ElvUI_S then NS.ElvUI_S:HandleButton(showBtn) end

        local setBtn = CreateFrame("Button",
            "CleanBotSetTal_" .. counter .. "_" .. gi,
            classContent, "UIPanelButtonTemplate")
        setBtn:SetSize(100, 22)
        setBtn:SetPoint("TOPLEFT", showBtn, "BOTTOMLEFT", 0, -4)
        setBtn:SetText("Set Talents")
        if NS.ElvUI_S then NS.ElvUI_S:HandleButton(setBtn) end

        local ddName = "CleanBotClassDD_" .. counter .. "_" .. gi
        local dd = CreateFrame("Frame", ddName, classContent, "UIDropDownMenuTemplate")
        dd:SetPoint("LEFT", setBtn, "RIGHT", -10, 0)
        UIDropDownMenu_SetWidth(dd, 130)
        if NS.ElvUI_S then NS.ElvUI_S:HandleDropDownBox(dd, 130) end

        local ddInfo = { dd = dd, strategies = strategies, selectedCmd = nil }
        local cd = entry and entry.classData and entry.classData.combat
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
                    local e = CleanBot_KnownBots[strlower(botName)]
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
        combatDDs[#combatDDs + 1] = ddInfo
        colTopAnchor = setBtn
    end

    -- ── Two-column layout below Spec (combat left, non-combat right) ──
    -- A full-width divider frame provides a shared Y anchor for both columns.
    -- Its TOP point sits exactly at classContent's horizontal midpoint.
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

    -- ── Left column: remaining combat groups ─────────────────────
    if cs.combat then
        local prevBottom = nil
        for gi = combatStartGi, #cs.combat do
            local group = cs.combat[gi]

            if group.type == "dropdown" and group.whisper then
                -- Secondary whisper-dropdown (unlikely but handled)
                local strategies  = group.strategies
                local specWhisper = group.whisper

                local header = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                if prevBottom then
                    header:SetPoint("TOPLEFT", prevBottom, "BOTTOMLEFT", 0, -12)
                else
                    header:SetPoint("TOPLEFT", leftCol, "TOPLEFT", 8, -10)
                end
                header:SetText(group.header)

                local showBtn = CreateFrame("Button",
                    "CleanBotShowTal_" .. counter .. "_" .. gi,
                    leftCol, "UIPanelButtonTemplate")
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
                        if text and strfind(strlower(text), "talent") then
                            tab:Click()
                            break
                        end
                    end
                end)
                if NS.ElvUI_S then NS.ElvUI_S:HandleButton(showBtn) end

                local setBtn = CreateFrame("Button",
                    "CleanBotSetTal_" .. counter .. "_" .. gi,
                    leftCol, "UIPanelButtonTemplate")
                setBtn:SetSize(100, 22)
                setBtn:SetPoint("TOPLEFT", showBtn, "BOTTOMLEFT", 0, -4)
                setBtn:SetText("Set Talents")
                if NS.ElvUI_S then NS.ElvUI_S:HandleButton(setBtn) end

                local ddName = "CleanBotClassDD_" .. counter .. "_" .. gi
                local dd = CreateFrame("Frame", ddName, leftCol, "UIDropDownMenuTemplate")
                dd:SetPoint("LEFT", setBtn, "RIGHT", -10, 0)
                UIDropDownMenu_SetWidth(dd, 130)
                if NS.ElvUI_S then NS.ElvUI_S:HandleDropDownBox(dd, 130) end

                local ddInfo = { dd = dd, strategies = strategies, selectedCmd = nil }
                local cd = entry and entry.classData and entry.classData.combat
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
                            local e = CleanBot_KnownBots[strlower(botName)]
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
                combatDDs[#combatDDs + 1] = ddInfo
                prevBottom = setBtn

            elseif group.type == "dropdown" then
                -- Regular exclusive dropdown — sends co +/- on selection
                local strategies = group.strategies

                local header = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                if prevBottom then
                    header:SetPoint("TOPLEFT", prevBottom, "BOTTOMLEFT", 0, -12)
                else
                    header:SetPoint("TOPLEFT", leftCol, "TOPLEFT", 8, -10)
                end
                header:SetText(group.header)

                local ddName = "CleanBotClassDD_" .. counter .. "_" .. gi
                local dd = CreateFrame("Frame", ddName, leftCol, "UIDropDownMenuTemplate")
                dd:SetPoint("TOPLEFT", header, "BOTTOMLEFT", -16, -4)
                UIDropDownMenu_SetWidth(dd, 160)
                if NS.ElvUI_S then NS.ElvUI_S:HandleDropDownBox(dd, 160) end

                local ddInfo = { dd = dd, strategies = strategies, selectedCmd = nil }
                local cd = entry and entry.classData and entry.classData.combat
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
                            local parts = {}
                            for _, rs in ipairs(strategies) do
                                parts[#parts + 1] = (rs.field == s.field and "+" or "-") .. rs.cmd
                            end
                            SendChatMessage("co " .. table.concat(parts, ","), "WHISPER", nil, botName)
                            local e = CleanBot_KnownBots[strlower(botName)]
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

                if group.readonly then UIDropDownMenu_DisableDropDown(dd) end
                combatDDs[#combatDDs + 1] = ddInfo
                local ddAnchor = CreateFrame("Frame", nil, leftCol)
                ddAnchor:SetSize(1, 1)
                ddAnchor:SetPoint("TOPLEFT", dd, "TOPLEFT", 16, -28)
                prevBottom = ddAnchor

            else
                -- Checkbox group
                local header = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                if prevBottom then
                    header:SetPoint("TOPLEFT", prevBottom, "BOTTOMLEFT", 0, -12)
                else
                    header:SetPoint("TOPLEFT", leftCol, "TOPLEFT", 8, -10)
                end
                header:SetText(group.header)

                local section, checkboxes = CB_BuildStrategySection(
                    leftCol, header, group.strategies, key, botName, counter,
                    function(s, checked)
                        local toggle = (checked and "+" or "-") .. s.cmd
                        SendChatMessage("co " .. toggle, "WHISPER", nil, botName)
                        local e = CleanBot_KnownBots[strlower(botName)]
                        if e and e.classData then e.classData.combat[s.field] = checked end
                    end)

                if entry and entry.classData and entry.classData.combat then
                    for _, s in ipairs(group.strategies) do
                        local cb = checkboxes[s.field]
                        if cb then cb:SetChecked(entry.classData.combat[s.field] == true) end
                    end
                end

                section:Show()
                for field, cb in pairs(checkboxes) do combatCBs[field] = cb end
                prevBottom = section
            end
        end
    end

    -- ── Right column: class non-combat groups ─────────────────
    if cs.nonCombat then
        local prevBottom = nil
        for gi, group in ipairs(cs.nonCombat) do
            local header = rightCol:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            if prevBottom then
                header:SetPoint("TOPLEFT", prevBottom, "BOTTOMLEFT", 0, -12)
            else
                header:SetPoint("TOPLEFT", rightCol, "TOPLEFT", 8, -10)
            end
            header:SetText(group.header)

            if group.type == "dropdown" then
                local strategies = group.strategies
                local ddName = "CleanBotClassNCDD_" .. counter .. "_" .. gi
                local dd = CreateFrame("Frame", ddName, rightCol, "UIDropDownMenuTemplate")
                dd:SetPoint("TOPLEFT", header, "BOTTOMLEFT", -16, -4)
                UIDropDownMenu_SetWidth(dd, 160)
                if NS.ElvUI_S then NS.ElvUI_S:HandleDropDownBox(dd, 160) end

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
                            SendChatMessage("nc " .. table.concat(parts, ","), "WHISPER", nil, botName)
                            local e = CleanBot_KnownBots[strlower(botName)]
                            if e and e.classData then
                                for _, rs in ipairs(strategies) do
                                    e.classData.nonCombat[rs.field] = (rs.field == s.field)
                                end
                            end
                        end
                        local cd = entry and entry.classData and entry.classData.nonCombat
                        info.checked = cd and (cd[s.field] == true)
                        UIDropDownMenu_AddButton(info)
                    end
                end)

                local cd = entry and entry.classData and entry.classData.nonCombat
                if cd then
                    for _, s in ipairs(strategies) do
                        if cd[s.field] == true then
                            UIDropDownMenu_SetText(dd, s.name)
                            break
                        end
                    end
                end

                nonCombatDDs[#nonCombatDDs + 1] = { dd = dd, strategies = strategies }
                local ddAnchor = CreateFrame("Frame", nil, rightCol)
                ddAnchor:SetSize(1, 1)
                ddAnchor:SetPoint("TOPLEFT", dd, "TOPLEFT", 16, -28)
                prevBottom = ddAnchor
            else
                local section, checkboxes = CB_BuildStrategySection(
                    rightCol, header, group.strategies, key, botName, counter,
                    function(s, checked)
                        local toggle = (checked and "+" or "-") .. s.cmd
                        SendChatMessage("nc " .. toggle, "WHISPER", nil, botName)
                        local e = CleanBot_KnownBots[strlower(botName)]
                        if e and e.classData then e.classData.nonCombat[s.field] = checked end
                    end)

                if entry and entry.classData and entry.classData.nonCombat then
                    for _, s in ipairs(group.strategies) do
                        local cb = checkboxes[s.field]
                        if cb then cb:SetChecked(entry.classData.nonCombat[s.field] == true) end
                    end
                end

                section:Show()
                for field, cb in pairs(checkboxes) do nonCombatCBs[field] = cb end
                prevBottom = section
            end
        end
    end

    NS.botClassFrames[key] = {
        combatCheckboxes    = combatCBs,
        nonCombatCheckboxes = nonCombatCBs,
        combatDropdowns     = combatDDs,
        nonCombatDropdowns  = nonCombatDDs,
    }
end

-- ============================================================
-- CB_BuildBotContent
-- Wires up model rotation, star, inner tabs, and all
-- combat/non-combat/class content for one bot.
-- ctrl  — right-side control frame (parent for all UI content)
-- model — DressUpModel frame (parent for star button)
-- ============================================================
local function CB_BuildBotContent(ctrl, model, key, botName, botClass, entry, counter)
    local topFrames = {}

    -- ── Model rotation via right-click drag ───────────────────
    local modelRotation = 0
    local dragLastX     = 0

    local dragCapture = CreateFrame("Frame", "CleanBotDragCapture" .. counter, UIParent)
    dragCapture:SetAllPoints(UIParent)
    dragCapture:SetFrameStrata("FULLSCREEN_DIALOG")
    dragCapture:EnableMouse(true)
    dragCapture:Hide()
    topFrames[#topFrames + 1] = dragCapture

    local function stopDrag()
        dragCapture:Hide()
        SetCursor(nil)
    end
    dragCapture:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then stopDrag() end
    end)
    dragCapture:SetScript("OnUpdate", function()
        local x     = select(1, GetCursorPosition())
        local delta = x - dragLastX
        dragLastX   = x
        if delta ~= 0 then
            modelRotation = modelRotation + delta * 0.013
            model:SetRotation(modelRotation)
        end
    end)
    model:EnableMouse(true)
    model:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then
            dragLastX = select(1, GetCursorPosition())
            SetCursor("none")
            dragCapture:Show()
        end
    end)
    model:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then stopDrag() end
    end)

    -- ── Favorite star button ──────────────────────────────────
    local starBtn = CreateFrame("Button", "CleanBotStar" .. counter, model)
    starBtn:SetSize(24, 24)
    starBtn:SetPoint("TOPLEFT", model, "TOPLEFT", 6, -6)
    local starTex = starBtn:CreateTexture(nil, "OVERLAY")
    starTex:SetAllPoints()
    starTex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
    local function UpdateStar()
        if CleanBot_SavedVars and CleanBot_SavedVars.favoriteBots and CleanBot_SavedVars.favoriteBots[key] then
            starTex:SetVertexColor(1, 0.82, 0)
        else
            starTex:SetVertexColor(0.4, 0.4, 0.4)
        end
    end
    NS.botStarUpdaters[key] = UpdateStar
    UpdateStar()
    starBtn:SetScript("OnClick", function()
        if not CleanBot_SavedVars then return end
        if not CleanBot_SavedVars.favoriteBots then CleanBot_SavedVars.favoriteBots = {} end
        if CleanBot_SavedVars.favoriteBots[key] then
            CleanBot_SavedVars.favoriteBots[key] = nil
        else
            CleanBot_SavedVars.favoriteBots[key] = true
        end
        UpdateStar()
    end)
    starBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local isFav = CleanBot_SavedVars and CleanBot_SavedVars.favoriteBots and CleanBot_SavedVars.favoriteBots[key]
        GameTooltip:AddLine(isFav and "Remove from Favorites" or "Add to Favorites", 1, 1, 1)
        GameTooltip:Show()
    end)
    starBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    topFrames[#topFrames + 1] = starBtn

    -- ── Inner tab bar (Combat / Non-Combat / Class) ───────────
    local innerTabBar = CreateFrame("Frame", nil, ctrl)
    innerTabBar:SetPoint("TOPLEFT",  ctrl, "TOPLEFT",  0, 0)
    innerTabBar:SetPoint("TOPRIGHT", ctrl, "TOPRIGHT", 0, 0)
    innerTabBar:SetHeight(NS.BOT_BAR_H)
    topFrames[#topFrames + 1] = innerTabBar

    local contentBg = CreateFrame("Frame", nil, ctrl)
    contentBg:SetPoint("TOPLEFT",     ctrl, "TOPLEFT",     0, -NS.BOT_BAR_H)
    contentBg:SetPoint("BOTTOMRIGHT", ctrl, "BOTTOMRIGHT", 0, 0)
    NS.CB_ApplyInnerSkin(contentBg)
    topFrames[#topFrames + 1] = contentBg

    local combatContent = CreateFrame("Frame", nil, ctrl)
    combatContent:SetPoint("TOPLEFT",     ctrl, "TOPLEFT",     0, -NS.BOT_BAR_H)
    combatContent:SetPoint("BOTTOMRIGHT", ctrl, "BOTTOMRIGHT", 0, 0)
    topFrames[#topFrames + 1] = combatContent

    local nonCombatContent = CreateFrame("Frame", nil, ctrl)
    nonCombatContent:SetPoint("TOPLEFT",     ctrl, "TOPLEFT",     0, -NS.BOT_BAR_H)
    nonCombatContent:SetPoint("BOTTOMRIGHT", ctrl, "BOTTOMRIGHT", 0, 0)
    nonCombatContent:Hide()
    topFrames[#topFrames + 1] = nonCombatContent

    local classContent = CreateFrame("Frame", nil, ctrl)
    classContent:SetPoint("TOPLEFT",     ctrl, "TOPLEFT",     0, -NS.BOT_BAR_H)
    classContent:SetPoint("BOTTOMRIGHT", ctrl, "BOTTOMRIGHT", 0, 0)
    classContent:Hide()
    topFrames[#topFrames + 1] = classContent

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

    -- ── Class tab content ─────────────────────────────────────
    CB_BuildClassTabContent(classContent, botClass, key, botName, counter)

    -- ── Non-Combat tab content ────────────────────────────────
    local ncHeader = nonCombatContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ncHeader:SetPoint("TOPLEFT", nonCombatContent, "TOPLEFT", 12, -10)
    ncHeader:SetText("General")

    local ncSection, ncCheckboxes = CB_BuildStrategySection(
        nonCombatContent, ncHeader, NS.NC_GENERAL_STRATEGIES, key, botName, counter,
        function(s, checked)
            local toggle = (checked and "+" or "-") .. s.cmd
            SendChatMessage("nc " .. toggle, "WHISPER", nil, botName)
            local e = CleanBot_KnownBots[strlower(botName)]
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

    -- ── Two-column combat layout ──────────────────────────────
    local leftCol = CreateFrame("Frame", nil, combatContent)
    leftCol:SetPoint("TOPLEFT",     combatContent, "TOPLEFT", 0,  0)
    leftCol:SetPoint("BOTTOMRIGHT", combatContent, "BOTTOM",  -4, 0)

    local rightCol = CreateFrame("Frame", nil, combatContent)
    rightCol:SetPoint("TOPLEFT",     combatContent, "TOP",         4, 0)
    rightCol:SetPoint("BOTTOMRIGHT", combatContent, "BOTTOMRIGHT", 0, 0)

    -- ── LEFT COLUMN: Role + role-specific sections + Combat Control ──
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
                local e = CleanBot_KnownBots[strlower(botName)]
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

    -- ── RIGHT COLUMN: Positioning + Timing & Marking ──────────
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

    return topFrames
end

-- ============================================================
-- RefreshTabs  — rebuild all bot character tabs from scratch.
-- Party bots are listed first; if the player is targeting a known
-- bot that is NOT already in the party it is appended as a
-- "Target" tab at the end.  Selection is restored by bot key so
-- the active tab survives back-to-back rebuilds.
-- ============================================================
NS.CleanBot_RefreshTabs = function()
    local prevKey = NS.selectedBotKey   -- save before ClearTabs wipes everything
    CleanBot_ClearTabs()

    -- ── Collect party bots ─────────────────────────────────────
    local bots = {}
    local numMembers = GetNumPartyMembers and GetNumPartyMembers() or 0
    for i = 1, numMembers do
        local unit = "party" .. i
        if UnitExists(unit) and NS.CleanBot_IsBot(unit) then
            local name = UnitName(unit)
            local _, class = UnitClass(unit)
            table.insert(bots, { unit = unit, name = name, class = class or "WARRIOR", key = strlower(name) })
        end
    end

    -- ── Append target if it is a known bot not already in party ──
    local targetName = UnitExists("target") and UnitIsPlayer("target") and UnitName("target")
    local targetKey  = targetName and strlower(targetName)
    if targetKey and CleanBot_KnownBots[targetKey] then
        local tEntry = CleanBot_KnownBots[targetKey]
        if not tEntry.queried then
            tEntry.queried    = true
            tEntry.awaitingCo = true
            tEntry.awaitingNc = false
            SendChatMessage("co ?", "WHISPER", nil, targetName)
        end
        local _, targetClass = UnitClass("target")
        table.insert(bots, {
            unit     = "target",
            name     = targetName,
            class    = targetClass or tEntry.class or "WARRIOR",
            key      = targetKey,
            isTarget = true,
        })
    end

    if #bots == 0 then
        if NS.partyEmptyLabel then NS.partyEmptyLabel:SetText("No bots found in party.") end
        return
    end
    if NS.partyEmptyLabel then NS.partyEmptyLabel:SetText("") end

    local contentW = NS.partyContent:GetWidth()
    local contentH = NS.partyContent:GetHeight()
    if contentW == 0 then contentW = NS.FRAME_WIDTH - 8 end
    if contentH == 0 then contentH = NS.FRAME_HEIGHT - NS.TITLE_H - NS.TOP_BAR_H - NS.BOT_BAR_H - NS.FOOTER_H - NS.PAD * 2 end

    for i, bot in ipairs(bots) do
        NS.tabCounter = NS.tabCounter + 1
        local counter = NS.tabCounter

        -- ── Character tab button ──────────────────────────────────
        local tab = CreateFrame("Button", "CleanBotCharTab" .. counter,
                                NS.botTabBar, "UIPanelButtonTemplate")
        tab:SetSize(NS.TAB_WIDTH, NS.TAB_HEIGHT)
        tab:SetPoint("LEFT", NS.botTabBar, "LEFT", NS.PAD + (i - 1) * (NS.TAB_WIDTH + 2), 0)
        tab:SetNormalFontObject(GameFontNormalSmall)

        if bot.isTarget then
            tab:SetText("Target")
        else
            tab:SetText("  " .. bot.name)
            local icon = tab:CreateTexture(nil, "OVERLAY")
            icon:SetSize(14, 14)
            icon:SetPoint("LEFT", tab, "LEFT", 4, 0)
            icon:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
            local coords = NS.CLASS_ICON_COORDS[bot.class] or NS.CLASS_ICON_COORDS["WARRIOR"]
            icon:SetTexCoord(unpack(coords))
        end

        local idx = i
        tab:SetScript("OnClick", function() CleanBot_SelectTab(idx) end)
        table.insert(NS.activeBotTabs, tab)
        NS.activeBotNames[i] = { name = bot.name, unit = bot.unit, key = bot.key, isTarget = bot.isTarget }
        if NS.ElvUI_S then NS.ElvUI_S:HandleButton(tab) end

        -- ── Model + control frames ────────────────────────────────
        local model = CreateFrame("DressUpModel", "CleanBotModel" .. counter, NS.partyContent)
        model:SetSize(contentW / 3, contentH)
        model:SetPoint("TOPLEFT", NS.partyContent, "TOPLEFT", 0, 0)
        model:SetUnit(bot.unit)
        model:Hide()
        table.insert(NS.botModelFrames, model)

        local ctrl = CreateFrame("Frame", "CleanBotCtrl" .. counter, NS.partyContent)
        ctrl:SetPoint("TOPLEFT",     NS.partyContent, "TOPLEFT",     contentW / 3 + NS.PAD, -NS.PAD)
        ctrl:SetPoint("BOTTOMRIGHT", NS.partyContent, "BOTTOMRIGHT", -NS.PAD, NS.PAD)
        ctrl:Hide()
        table.insert(NS.botControlFrames, ctrl)

        local entry = CleanBot_KnownBots[bot.key]
        CB_BuildBotContent(ctrl, model, bot.key, bot.name, bot.class, entry, counter)
    end

    -- Restore selection: if the user was on the Target tab, find the new target entry
    -- (bot key may have changed); otherwise restore by key, defaulting to first.
    local restoreIdx = nil
    if NS.selectedIsTarget then
        for i, info in ipairs(NS.activeBotNames) do
            if info.isTarget then restoreIdx = i; break end
        end
    elseif prevKey then
        for i, info in ipairs(NS.activeBotNames) do
            if info.key == prevKey then restoreIdx = i; break end
        end
    end
    CleanBot_SelectTab(restoreIdx or 1)
end
