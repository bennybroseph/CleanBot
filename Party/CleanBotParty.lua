-- ============================================================
-- CleanBotParty.lua  —  character tab state, tab management,
--                        strategy section builder, RefreshTabs
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- Per-bot frame registries  (reset on each RefreshTabs call)
-- ============================================================
NS.activeBotTabs    = {}
NS.activeTabIndex   = 0
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
    NS.activeTabIndex    = 0
end

local function CleanBot_SelectTab(index)
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
        if i == index then model:Show() else model:Hide() end
    end
    for i, ctrl in ipairs(NS.botControlFrames) do
        if i == index then ctrl:Show() else ctrl:Hide() end
    end
end

-- ============================================================
-- Strategy section builder
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

-- ============================================================
-- RefreshTabs  — rebuild all bot character tabs from scratch
-- ============================================================
NS.CleanBot_RefreshTabs = function()
    CleanBot_ClearTabs()

    local bots = {}
    local numMembers = GetNumPartyMembers and GetNumPartyMembers() or 0
    for i = 1, numMembers do
        local unit = "party" .. i
        if UnitExists(unit) and NS.CleanBot_IsBot(unit) then
            local name = UnitName(unit)
            local _, class = UnitClass(unit)
            table.insert(bots, { unit = unit, name = name, class = class or "WARRIOR" })
        end
    end

    if #bots == 0 then
        CleanBotFrameText:SetText("No bots found in party.")
        return
    end
    CleanBotFrameText:SetText("")

    CleanBotFrame:SetHeight(NS.FRAME_HEIGHT)
    CleanBotFrame:SetWidth(NS.FRAME_WIDTH)

    local contentW = NS.partyContent:GetWidth()
    local contentH = NS.partyContent:GetHeight()
    if contentW == 0 then contentW = NS.FRAME_WIDTH - 8 end
    if contentH == 0 then contentH = NS.FRAME_HEIGHT - NS.TITLE_H - NS.TOP_BAR_H - NS.BOT_BAR_H - NS.FOOTER_H - NS.PAD * 2 end

    for i, bot in ipairs(bots) do
        NS.tabCounter = NS.tabCounter + 1
        local counter = NS.tabCounter

        -- ── Character tab button ───────────────────────────────────
        local tab = CreateFrame("Button", "CleanBotCharTab" .. counter,
                                NS.botTabBar, "UIPanelButtonTemplate")
        tab:SetSize(NS.TAB_WIDTH, NS.TAB_HEIGHT)
        tab:SetPoint("LEFT", NS.botTabBar, "LEFT", NS.PAD + (i - 1) * (NS.TAB_WIDTH + 2), 0)
        tab:SetText("  " .. bot.name)
        tab:SetNormalFontObject(GameFontNormalSmall)

        local icon = tab:CreateTexture(nil, "OVERLAY")
        icon:SetSize(14, 14)
        icon:SetPoint("LEFT", tab, "LEFT", 4, 0)
        icon:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
        local coords = NS.CLASS_ICON_COORDS[bot.class] or NS.CLASS_ICON_COORDS["WARRIOR"]
        icon:SetTexCoord(unpack(coords))

        local idx = i
        tab:SetScript("OnClick", function() CleanBot_SelectTab(idx) end)
        table.insert(NS.activeBotTabs, tab)
        if NS.ElvUI_S then NS.ElvUI_S:HandleButton(tab) end

        -- ── Model + control frames ─────────────────────────────────
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

        local botName = bot.name
        local key     = strlower(bot.name)
        local entry   = CleanBot_KnownBots[key]

        -- ── Inner tab bar (Combat / Non-Combat) ───────────────────
        local innerTabBar = CreateFrame("Frame", nil, ctrl)
        innerTabBar:SetPoint("TOPLEFT",  ctrl, "TOPLEFT",  0, 0)
        innerTabBar:SetPoint("TOPRIGHT", ctrl, "TOPRIGHT", 0, 0)
        innerTabBar:SetHeight(NS.BOT_BAR_H)

        local combatContent = CreateFrame("Frame", nil, ctrl)
        combatContent:SetPoint("TOPLEFT",     ctrl, "TOPLEFT",     0, -NS.BOT_BAR_H)
        combatContent:SetPoint("BOTTOMRIGHT", ctrl, "BOTTOMRIGHT", 0, 0)

        local nonCombatContent = CreateFrame("Frame", nil, ctrl)
        nonCombatContent:SetPoint("TOPLEFT",     ctrl, "TOPLEFT",     0, -NS.BOT_BAR_H)
        nonCombatContent:SetPoint("BOTTOMRIGHT", ctrl, "BOTTOMRIGHT", 0, 0)
        nonCombatContent:Hide()

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
            if idx == 1 then combatContent:Show(); nonCombatContent:Hide()
            else              combatContent:Hide(); nonCombatContent:Show() end
        end

        local innerLabels = { "Combat", "Non-Combat" }
        for j, lbl in ipairs(innerLabels) do
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

        NS.botInnerTabs[key] = { combatPanel = combatContent, nonCombatPanel = nonCombatContent }

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
        local ncEntry = CleanBot_KnownBots[key]
        if ncEntry and ncEntry.nonCombat then
            for _, s in ipairs(NS.NC_GENERAL_STRATEGIES) do
                local cb = ncCheckboxes[s.field]
                if cb then cb:SetChecked(ncEntry.nonCombat[s.field] == true) end
            end
        end
        ncSection:Show()
        NS.botNcFrames[key] = { section = ncSection, checkboxes = ncCheckboxes }

        -- ── Two-column layout ─────────────────────────────────────
        local leftCol = CreateFrame("Frame", nil, combatContent)
        leftCol:SetPoint("TOPLEFT",     combatContent, "TOPLEFT", 0,  0)
        leftCol:SetPoint("BOTTOMRIGHT", combatContent, "BOTTOM",  -4, 0)

        local rightCol = CreateFrame("Frame", nil, combatContent)
        rightCol:SetPoint("TOPLEFT",     combatContent, "TOP",         4, 0)
        rightCol:SetPoint("BOTTOMRIGHT", combatContent, "BOTTOMRIGHT", 0, 0)

        -- ── LEFT COLUMN: Role + role-specific section + Combat Control ──

        local roleLabel = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        roleLabel:SetPoint("TOPLEFT", leftCol, "TOPLEFT", 8, -10)
        roleLabel:SetText("Role")

        local dd = CreateFrame("Frame", "CleanBotRoleDD" .. counter,
                               leftCol, "UIDropDownMenuTemplate")
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
        if entry and entry.combat and entry.combat["isTank"] == true then tankSection:Show() else tankSection:Hide() end
        NS.botTankFrames[key] = { section = tankSection, checkboxes = tankCBs }

        local dpsSection, dpsCBs = CB_BuildStrategySection(leftCol, roleLabel, NS.DPS_STRATEGIES, key, botName, counter)
        if entry and entry.combat and entry.combat["isDPS"] == true then dpsSection:Show() else dpsSection:Hide() end
        NS.botDpsFrames[key] = { section = dpsSection, checkboxes = dpsCBs }

        local healSection, healCBs = CB_BuildStrategySection(leftCol, roleLabel, NS.HEAL_STRATEGIES, key, botName, counter)
        if entry and entry.combat and entry.combat["isHealer"] == true then healSection:Show() else healSection:Hide() end
        NS.botHealFrames[key] = { section = healSection, checkboxes = healCBs }

        -- Spacer so Combat Control always starts below the tallest possible role section.
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
    end

    if NS.activeTabIndex == 0 then
        CleanBot_SelectTab(1)
    end
end
