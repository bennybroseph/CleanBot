-- ============================================================
-- Individual.lua  —  Individual tab panel construction, per-bot
--                        tab state, tab management, strategy
--                        section builders, and RefreshTabs.
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- Panel construction (called once at PLAYER_LOGIN via NS.CB_BuildFrames)
-- ============================================================
--- Builds the Individual tab: the model/strategy panels and the per-bot slot pool.
NS.CleanBot_BuildIndividualTab = function()
    NS.individualPanel = NS.CB_CreatePanel(NS.contentFrame, "CleanBotIndividualPanel", 2, "panel")
    NS.individualPanel:SetAllPoints(NS.contentFrame)

    NS.botTabBar = CreateFrame("Frame", "CleanBotBotTabBar", NS.individualPanel)
    NS.botTabBar:SetPoint("TOPLEFT",  NS.individualPanel, "TOPLEFT",  0, 0)
    NS.botTabBar:SetPoint("TOPRIGHT", NS.individualPanel, "TOPRIGHT", 0, 0)
    NS.botTabBar:SetHeight(NS.BOT_BAR_H)

    -- Bot selector dropdown — shown instead of the tab row when the group has more
    -- than NS.TAB_DROPDOWN_THRESHOLD bots (RefreshTabs toggles it). Created once,
    -- hidden by default; populated per refresh in dropdown mode.
    NS.botDropdown = NS.CB_CreateDropdown(NS.botTabBar, "CleanBotBotDropdown", 180)
    NS.botDropdown:ClearAllPoints()
    NS.botDropdown:SetPoint("LEFT", NS.botTabBar, "LEFT", NS.PADDING.panel.left, 0)
    NS.botDropdown:Hide()

    -- The XML-defined CleanBotFrameText is a child of CleanBotFrame and would
    -- bleed through across tabs. Hide it and use an individualPanel-parented label instead.
    CleanBotFrameText:SetText("")
    CleanBotFrameText:Hide()

    NS.individualEmptyLabel = NS.individualPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    NS.individualEmptyLabel:SetPoint("TOP", NS.individualPanel, "TOP", 0, -(NS.BOT_BAR_H + 20))
    NS.individualEmptyLabel:SetText("")

    NS.individualContent = CreateFrame("Frame", "CleanBotIndividualContent", NS.individualPanel)
    -- Inset individualContent by individualPanel's stamped padding so all model/equip/strategy
    -- content respects the panel border. BOT_BAR_H is added to paddingTop because
    -- the bot tab bar sits above the content area and is intentionally edge-to-edge.
    NS.individualContent:SetPoint("TOPLEFT",     NS.individualPanel, "TOPLEFT",
         NS.individualPanel.paddingLeft,
       -(NS.BOT_BAR_H + NS.individualPanel.paddingTop))
    NS.individualContent:SetPoint("BOTTOMRIGHT", NS.individualPanel, "BOTTOMRIGHT",
        -NS.individualPanel.paddingRight,
         NS.individualPanel.paddingBottom)

    -- ── Two-column panel structure ────────────────────────────────
    -- Compute model panel width from frame height (decoupled from frame width).
    -- This means the model area never changes size when the frame expands/collapses.
    -- modelW factor (0.7) approximates the original contentW/3 at 850px width.
    -- Adjust in-game via this multiplier if the model looks too wide or narrow.
    local panelH  = NS.individualContent:GetHeight()
    if panelH == 0 then
        panelH = NS.FRAME_HEIGHT - NS.TITLE_H - NS.TOP_BAR_H - NS.BOT_BAR_H
                 - (CleanBotFrame.paddingBottom or NS.PADDING.frame.bottom)
    end
    local modelH  = panelH - NS.EQUIP_WEAPON_PAD
    local modelW  = math.floor(modelH * 0.7)
    local g       = NS.CB_SlotGeometry(modelW, modelH)
    local panelW  = g.colW + modelW + g.colW

    -- Column 1: model + equip slots. Fixed width, never resizes.
    NS.individualModelPanel = CreateFrame("Frame", "CleanBotIndividualModelPanel", NS.individualContent)
    NS.individualModelPanel:SetPoint("TOPLEFT",    NS.individualContent, "TOPLEFT",    0, 0)
    NS.individualModelPanel:SetPoint("BOTTOMLEFT", NS.individualContent, "BOTTOMLEFT", 0, 0)
    NS.individualModelPanel:SetWidth(panelW)

    -- Column 2: strategy tabs and controls. Fills the remaining width via BOTTOMRIGHT.
    NS.individualStratPanel = CreateFrame("Frame", "CleanBotIndividualStratPanel", NS.individualContent)
    NS.individualStratPanel:SetPoint("TOPLEFT",     NS.individualModelPanel, "TOPRIGHT",    NS.MODEL_GAP, 0)
    NS.individualStratPanel:SetPoint("BOTTOMRIGHT", NS.individualContent,    "BOTTOMRIGHT", 0, 0)

    -- Collapsed width = model panel + frame padding + panel padding on both sides.
    -- MODEL_GAP is included so the collapsed frame visually absorbs the gap between
    -- the model panel and the strategy panel edge.
    NS.COLLAPSED_WIDTH = panelW
        + NS.PADDING.frame.left  + NS.PADDING.frame.right
        + NS.individualPanel.paddingLeft + NS.individualPanel.paddingRight
        + NS.MODEL_GAP

    -- ── Expand / collapse toggle button ─────────────────────────
    -- Parented to CleanBotFrame and anchored to its RIGHT edge.
    -- IMPORTANT: static pixel offset intentionally bypasses the padding/margin
    -- model. This is a fixed UI affordance at the frame edge; do not convert
    -- these offsets to NS.PADDING or margin values.
    NS.individualExpandBtn = NS.CB_CreateButton(CleanBotFrame, "CleanBotIndividualExpandBtn",
        ">", 17, 35, function() NS.CB_ToggleIndividualExpand() end)
    NS.individualExpandBtn:ClearAllPoints()
    NS.individualExpandBtn:SetPoint("RIGHT", CleanBotFrame, "RIGHT", 0, 0)
    NS.individualExpandBtn:SetFrameLevel(CleanBotFrame:GetFrameLevel() + 20)
    NS.individualExpandBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(NS.individualExpanded and "Hide Strategies" or "Show Strategies", 1, 1, 1)
        GameTooltip:Show()
    end)
    NS.individualExpandBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    NS.individualExpandBtn:Hide()  -- shown only when Individual tab is active (CleanBot_SelectTopTab)
end

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
NS.tabList          = {}   -- currently BOUND slots (heavy content live). In tab mode this
                           -- mirrors desiredBots; in dropdown mode it's the LRU-bound subset.
NS.desiredBots      = {}   -- ordered cheap roster {key,name,class,unit} the selector enumerates
NS.selectorMode     = "tabs" -- "tabs" | "dropdown"; chosen by group size in RefreshTabs
NS.selectedTabIndex = 0    -- index into tabList of the currently shown tab
NS.selectedBotKey   = nil  -- key of selected bot; survives RefreshTabs rebuilds
NS.lruClock         = 0    -- monotonic counter stamped onto slot.lru for LRU eviction
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
-- Layout geometry derived from the live model size.
---@return number contentW  Content area width.
---@return number contentH  Content area height.
---@return number modelH     Model height.
---@return number colW       Equip column width.
---@return number modelW      Model width.
local function CB_GetGeometry()
    local contentW = NS.individualContent and NS.individualContent:GetWidth()  or 0
    local contentH = NS.individualContent and NS.individualContent:GetHeight() or 0
    if contentW == 0 then contentW = NS.EXPANDED_WIDTH - NS.PADDING.frame.left - NS.PADDING.frame.right end
    if contentH == 0 then contentH = NS.FRAME_HEIGHT - NS.TITLE_H - NS.TOP_BAR_H - NS.BOT_BAR_H - (CleanBotFrame.paddingBottom or NS.PADDING.frame.bottom) end

    -- modelW is derived from modelH, not contentW, so the model panel width is
    -- stable regardless of whether the frame is expanded or collapsed.
    local modelH = contentH - NS.EQUIP_WEAPON_PAD
    local modelW = math.floor(modelH * 0.7)
    local g      = NS.CB_SlotGeometry(modelW, modelH)
    return contentW, contentH, modelH, g.colW, modelW
end

-- ============================================================
-- Strategy section builder — shared by combat, non-combat, and class tabs.
-- onClickFn(strategy, checked) overrides the default "co +/-cmd" whisper.
-- sourceTable supplies each checkbox's initial checked state (entry.combat,
-- entry.nonCombat, or a classData section); nil leaves boxes unchecked.
-- Returns (sectionFrame, checkboxes) where checkboxes is keyed by field name.
-- ============================================================
---@param ctrl        table   Container frame the section is built into.
---@param anchor       table   Widget the section's first row anchors below.
---@param strategies   table   Strategy definitions to render as toggles.
---@param slot         table   The bound slot (resolves the live bot).
---@param tag          string  Disambiguating tag for frame names.
---@param onClickFn    fun()   Handler invoked when a strategy toggle is clicked.
---@param sourceTable  table   State table the toggles read/write.
local function CB_BuildStrategySection(ctrl, anchor, strategies, slot, tag, onClickFn, sourceTable)
    local section = CreateFrame("Frame", nil, ctrl)
    NS.CB_AnchorBelow(section, anchor)
    section:SetPoint("RIGHT", ctrl, "RIGHT", -(ctrl.paddingRight or 0), 0)
    section:SetHeight(#strategies * (NS.MARGIN.checkbox.top + 20 + NS.MARGIN.checkbox.bottom))
    NS.CB_ApplyFrameSkin(section, 4)

    local controls = {}
    local yOffset  = NS.PADDING.section.top

    for _, s in ipairs(strategies) do
        if s.type == "timerSlider" then
            local slMin   = s.min or 0
            local slMax   = s.max or 60
            local initVal = sourceTable and sourceTable[s.field] or slMin

            local dragging = false
            local ready    = false  -- suppresses the SetValue fired during construction
            local strat    = s
            local sl = NS.CB_CreateSlider(section, "CleanBotTimerSL_" .. s.field .. "_" .. tag,
                s.name, slMin, slMax, initVal, tostring(slMin), tostring(slMax),
                function(v)
                    -- Editbox path: ready=true, dragging=false → send immediately.
                    -- Drag path: suppressed here; OnMouseUp sends once on release.
                    -- Construction path: ready=false → suppressed.
                    if ready and not dragging then
                        NS.CB_SendBotCommand(slot.name, strat.cmd .. " " .. v)
                        local e = CleanBot_PartyBots[slot.key]
                        if e and e.combat then e.combat[strat.field] = v end
                    end
                end)
            ready = true
            sl:SetWidth(140)
            -- White text to match the checkbox labels around it in the strategy
            -- sections; also becomes the color Enable() restores after a
            -- dependsOn Disable/Enable cycle (other sliders keep skin defaults).
            sl:SetTextColor(1, 1, 1)
            sl:SetPoint("TOPLEFT", section, "TOPLEFT", NS.PADDING.section.left + NS.MARGIN.slider.left, -yOffset)

            sl.slider:SetScript("OnMouseDown", function() dragging = true end)
            sl.slider:SetScript("OnMouseUp", function()
                dragging = false
                local v = math.floor(sl.slider:GetValue() + 0.5)
                NS.CB_SendBotCommand(slot.name, strat.cmd .. " " .. v)
                local e = CleanBot_PartyBots[slot.key]
                if e and e.combat then e.combat[strat.field] = v end
            end)

            controls[s.field] = sl
            yOffset = yOffset + NS.MARGIN.slider.top + 54 + NS.MARGIN.slider.bottom
        else
            local cb = NS.CB_CreateCheckBox(section, "CleanBotCB_" .. s.field .. "_" .. tag)
            cb:SetSize(20, 20)
            cb:SetPoint("TOPLEFT", section, "TOPLEFT", NS.PADDING.section.left + NS.MARGIN.checkbox.left, -yOffset)

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
                    local checked = self:GetChecked() and true or false
                    local toggle  = (checked and "+" or "-") .. cbCmd
                    local e = CleanBot_PartyBots[slot.key]
                    if e and e.combat then e.combat[cbField] = checked end
                    NS.CB_SendStrategyToggle(slot, "co", toggle, { [cbField] = checked })
                end)
            end

            controls[s.field] = cb
            yOffset = yOffset + NS.MARGIN.checkbox.top + 20 + NS.MARGIN.checkbox.bottom
        end
    end

    section:SetHeight(yOffset + NS.PADDING.section.bottom)

    -- Wire dependsOn: patch the checkbox's OnClick to enable/disable the linked slider.
    for _, s in ipairs(strategies) do
        if s.type == "timerSlider" and s.dependsOn then
            local cb = controls[s.dependsOn]
            local sl = controls[s.field]
            if cb and sl then
                local function setSliderEnabled(enabled)
                    if enabled then sl:Enable() else sl:Disable() end
                end
                setSliderEnabled(cb:GetChecked())
                local orig = cb:GetScript("OnClick")
                cb:SetScript("OnClick", function(self)
                    if orig then orig(self) end
                    setSliderEnabled(self:GetChecked() and true or false)
                end)
            end
        end
    end

    return section, controls
end

-- Applies a mutually-exclusive strategy selection: whispers a single
-- "cmd +sel,-other,-other..." toggle list and mirrors the choice into
-- dataTable (entry.combat or a classData section), if supplied.
---@param strategies    table   The mutually-exclusive strategy group.
---@param selectedField string  Field of the chosen strategy (others are cleared).
---@param cmd           string  Bot command prefix to send for the selection.
---@param slot          table   The bound slot (resolves the live bot).
---@param dataTable     table   State table updated to reflect the selection.
local function CB_ApplyExclusiveSelection(strategies, selectedField, cmd, slot, dataTable)
    local parts  = {}
    local expect = {}
    for _, rs in ipairs(strategies) do
        local on = (rs.field == selectedField)
        parts[#parts + 1] = (on and "+" or "-") .. NS.CB_EffStrategyCmd(rs, slot.class)
        expect[rs.field] = on
    end
    if dataTable then
        for _, rs in ipairs(strategies) do
            dataTable[rs.field] = (rs.field == selectedField)
        end
    end
    -- Optimistic write above; toggle + authoritative reconcile (self-healing).
    NS.CB_SendStrategyToggle(slot, cmd, table.concat(parts, ","), expect)
end

-- ============================================================
-- CB_BuildTalentGroup
-- Renders: header → Show Talents btn → Set Talents btn → whisper dropdown.
-- Used for the full-width spec group and any whisper dropdown inside a column.
-- prevBottom=nil anchors the header to parent's TOPLEFT; otherwise to prevBottom.
-- Returns the Set Talents button, which becomes the next prevBottom.
-- ============================================================
---@param parent     table   Container frame the group is built into.
---@param prevBottom table   Widget the group anchors below.
---@param group      table   The talent/strategy group definition.
---@param slot       table   The bound slot (resolves the live bot).
---@param tag        string  Disambiguating tag for frame names.
---@param gi         number  Group index within the column.
---@param registry   table   Widget registry the created controls register into.
---@param getSource  fun(entry:table):table?  Returns the state table the controls read/write.
---@return table             The bottommost widget of the built group.
local function CB_BuildTalentGroup(parent, prevBottom, group, slot, tag, gi, registry, getSource)
    local strategies  = group.strategies
    local specWhisper = group.whisper

    local header = NS.CB_CreateLabel(parent, group.header)
    if prevBottom then
        NS.CB_AnchorBelow(header, prevBottom)
    else
        header:SetPoint("TOPLEFT", parent, "TOPLEFT",
            (parent.paddingLeft or 0) + (header.marginLeft or 0),
            -((parent.paddingTop or 0) + (header.marginTop  or 0)))
    end

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
    NS.CB_AnchorBelow(showBtn, header)

    local setBtn = NS.CB_CreateButton(parent, "CleanBotSetTal_" .. tag .. "_" .. gi .. "s",
                                      "Set Talents", 100, 22)
    NS.CB_AnchorBelow(setBtn, showBtn)

    local dd = NS.CB_CreateDropdown(parent, "CleanBotClassDD_" .. tag .. "_" .. gi, 130)
    NS.CB_AnchorAhead(dd, setBtn)

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
        -- whisper = true marks this as the talent-spec dropdown so
        -- CB_SyncTalentSpec can find its dd for the tree-name fallback label.
        registry[#registry + 1] = { type = "dropdown", dd = dd, strategies = strategies, getSource = getSource, whisper = true }
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
-- Filters a strategy list to the entries shown for a class (NS.CB_StrategyShown),
-- hiding tokens the bot's class doesn't register (e.g. cc/boost on a warrior).
---@param list  table    Strategy definitions.
---@param class string?  Class token.
---@return table         A new list containing only the shown entries.
local function CB_ShownStrategies(list, class)
    local out = {}
    for _, s in ipairs(list) do
        if NS.CB_StrategyShown(s, class) then out[#out + 1] = s end
    end
    return out
end

---@param col       table   The column frame to build into.
---@param groups    table   Array of group definitions for this column.
---@param cmd       string  Bot command prefix for the column's toggles.
---@param slot      table   The bound slot (resolves the live bot).
---@param tag       string  Disambiguating tag for frame names.
---@param startGi   number  Group index of the first group in this column.
---@param registry  table   Widget registry the created controls register into.
---@param getSource fun(entry:table):table?  Returns the state table the controls read/write.
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
            -- Roles the bot's class can't perform are filtered out (e.g. a priest
            -- has no Tank role token).
            local strategies = CB_ShownStrategies(group.strategies, slot.class)
            local header = NS.CB_CreateLabel(col, group.header)
            if prevBottom then NS.CB_AnchorBelow(header, prevBottom)
            else header:SetPoint("TOPLEFT", col, "TOPLEFT",
                (col.paddingLeft or 0) + (header.marginLeft or 0),
                -((col.paddingTop or 0) + (header.marginTop  or 0))) end

            local dd = NS.CB_CreateDropdown(col, "CleanBotRoleDD_" .. tag, 120)
            NS.CB_AnchorBelow(dd, header)

            -- Anchor point for sub-sections: just below the dropdown frame.
            local ddAnchor = CreateFrame("Frame", nil, col)
            ddAnchor:SetSize(1, 1)
            ddAnchor.marginTop    = 0
            ddAnchor.marginBottom = 0
            ddAnchor:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, 0)

            local multiRoleLabel = NS.CB_CreateLabel(col, "Multiple Roles Selected", "GameFontRed")
            NS.CB_AnchorBelow(multiRoleLabel, ddAnchor)
            multiRoleLabel:Hide()

            -- Build all sub-sections anchored to ddAnchor; only one shows at a time.
            local subSections = {}
            local maxSubH     = 0
            local initSrc     = getSource(entry) or {}
            for _, sg in ipairs(group.subGroups) do
                local sgStrats = CB_ShownStrategies(sg.strategies, slot.class)
                local sec, cbs = CB_BuildStrategySection(col, ddAnchor, sgStrats, slot, tag,
                    function(s, checked)
                        local toggle = (checked and "+" or "-") .. NS.CB_EffStrategyCmd(s, slot.class)
                        local ds = getSource(CleanBot_PartyBots[slot.key])
                        if ds then ds[s.field] = checked end
                        NS.CB_SendStrategyToggle(slot, cmd, toggle, { [s.field] = checked })
                    end,
                    initSrc)
                sec:Hide()
                subSections[sg.field] = { section = sec, checkboxes = cbs, strategies = sgStrats }
                local sectionH = NS.PADDING.section.top
                    + #sgStrats * (NS.MARGIN.checkbox.top + 20 + NS.MARGIN.checkbox.bottom)
                    + NS.PADDING.section.bottom
                maxSubH = math.max(maxSubH, sectionH)
            end

            -- Map every role field to its sub-section. A subgroup may serve multiple
            -- roles (sg.roles) — e.g. one DPS section shared by DPS (Single) and DPS (AoE).
            local roleToSection = {}
            for _, sg in ipairs(group.subGroups) do
                local sec = subSections[sg.field]
                for _, rf in ipairs(sg.roles or { sg.field }) do roleToSection[rf] = sec end
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
            elseif activeField and roleToSection[activeField] then
                roleToSection[activeField].section:Show()
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
                        for _, sub in pairs(subSections) do sub.section:Hide() end
                        local sec = roleToSection[s.field]
                        if sec then sec.section:Show() end
                    end
                    info.checked = src[s.field] == true
                    UIDropDownMenu_AddButton(info)
                end
            end)

            -- Spacer to hold vertical room for the dropdown + tallest sub-section.
            local spacer = CreateFrame("Frame", nil, col)
            spacer:SetSize(1, 1)
            spacer.marginTop    = 0
            spacer.marginBottom = 0
            spacer:SetPoint("TOPLEFT", ddAnchor, "TOPLEFT", 0, -maxSubH)
            prevBottom = spacer

            if registry then
                registry[#registry + 1] = {
                    type           = "roleDropdown",
                    dd             = dd,
                    strategies     = strategies,
                    getSource      = getSource,
                    subSections    = subSections,
                    roleToSection  = roleToSection,
                    multiRoleLabel = multiRoleLabel,
                }
            end

        elseif group.type == "dropdown" then
            -- Exclusive dropdown: selection sends cmd +/- for each strategy. An optional
            -- group.noneLabel adds a leading clear entry that deselects all (e.g. "None"
            -- to drop every blessing) — nil selection → CB_ApplyExclusiveSelection sends
            -- all "-".
            local strategies = group.strategies
            local noneLabel  = group.noneLabel
            local header = NS.CB_CreateLabel(col, group.header)
            if prevBottom then NS.CB_AnchorBelow(header, prevBottom)
            else header:SetPoint("TOPLEFT", col, "TOPLEFT",
                (col.paddingLeft or 0) + (header.marginLeft or 0),
                -((col.paddingTop or 0) + (header.marginTop  or 0))) end

            -- Frame name keyed on the group's semantic key when present (generic groups
            -- like "movement"), else the group index (class groups have no `group` field).
            -- This keeps generic and class dropdowns from colliding when they share the
            -- same cmd+tag+gi (e.g. nc Movement vs a class nc dropdown both at index 2).
            local dd = NS.CB_CreateDropdown(col, "CleanBotClassDD_" .. cmd .. tag .. "_" .. (group.group or gi), 160)
            NS.CB_AnchorBelow(dd, header)

            UIDropDownMenu_Initialize(dd, function(self)
                local cd = getSource(CleanBot_PartyBots[slot.key]) or {}
                if noneLabel then
                    local info        = UIDropDownMenu_CreateInfo()
                    info.text         = noneLabel
                    local anyActive = false
                    for _, s in ipairs(strategies) do if cd[s.field] == true then anyActive = true break end end
                    info.checked      = not anyActive
                    info.func         = function()
                        UIDropDownMenu_SetText(self, noneLabel)
                        CB_ApplyExclusiveSelection(strategies, nil, cmd, slot,
                            getSource(CleanBot_PartyBots[slot.key]))
                    end
                    UIDropDownMenu_AddButton(info)
                end
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
                    info.checked = cd[s.field] == true
                    UIDropDownMenu_AddButton(info)
                end
            end)
            if group.readonly then UIDropDownMenu_DisableDropDown(dd) end

            if registry then
                registry[#registry + 1] = { type = "dropdown", dd = dd, strategies = strategies, getSource = getSource, noneLabel = noneLabel }
            end
            prevBottom = dd

        else
            -- Checkbox group — drop entries the bot's class doesn't register
            -- (e.g. cc/boost on a warrior).
            local groupStrats = CB_ShownStrategies(group.strategies, slot.class)
            local header = NS.CB_CreateLabel(col, group.header)
            if prevBottom then NS.CB_AnchorBelow(header, prevBottom)
            else header:SetPoint("TOPLEFT", col, "TOPLEFT",
                (col.paddingLeft or 0) + (header.marginLeft or 0),
                -((col.paddingTop or 0) + (header.marginTop  or 0))) end

            local section, checkboxes = CB_BuildStrategySection(col, header, groupStrats, slot, tag,
                function(s, checked)
                    local toggle = (checked and "+" or "-") .. NS.CB_EffStrategyCmd(s, slot.class)
                    local ds = getSource(CleanBot_PartyBots[slot.key])
                    if ds then ds[s.field] = checked end
                    NS.CB_SendStrategyToggle(slot, cmd, toggle, { [s.field] = checked })
                end,
                getSource(entry))
            section:Show()
            if registry then
                registry[#registry + 1] = { type = "checkboxes", checkboxes = checkboxes, strategies = groupStrats, getSource = getSource }
            end
            prevBottom = section
        end
    end
end

-- ============================================================
-- Class tab content builder
-- ============================================================
---@param classContent table   The class sub-tab content frame to build into.
---@param class        string  Class token (e.g. "WARRIOR").
---@param slot         table   The bound slot (resolves the live bot).
---@param tag          string  Disambiguating tag for frame names.
local function CB_BuildClassTabContent(classContent, class, slot, tag)
    local cs = NS.CLASS_STRATEGIES and NS.CLASS_STRATEGIES[class]

    if not cs or (not cs.combat and not cs.nonCombat) then
        local label = classContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", classContent, "TOPLEFT",
            (classContent.paddingLeft or 0) + (label.marginLeft or 0),
            -((classContent.paddingTop or 0) + (label.marginTop  or 0)))
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
    colDivider.marginTop    = 0
    colDivider.marginBottom = 0
    if colTopAnchor then
        NS.CB_AnchorBelow(colDivider, colTopAnchor)
    else
        colDivider:SetPoint("TOPLEFT", classContent, "TOPLEFT", 0, 0)
    end
    colDivider:SetPoint("RIGHT", classContent, "RIGHT", 0, 0)

    local leftCol = CreateFrame("Frame", nil, classContent)
    leftCol:SetPoint("TOPLEFT",     colDivider,   "TOPLEFT",     0,                 0)
    leftCol:SetPoint("BOTTOMRIGHT", classContent, "BOTTOM",     -NS.COLUMN_GAP,    0)
    leftCol.paddingLeft   = classContent.paddingLeft
    leftCol.paddingRight  = classContent.paddingRight
    leftCol.paddingTop    = classContent.paddingTop
    leftCol.paddingBottom = classContent.paddingBottom

    local rightCol = CreateFrame("Frame", nil, classContent)
    rightCol:SetPoint("TOPLEFT",     colDivider,   "TOP",         NS.COLUMN_GAP,    0)
    rightCol:SetPoint("BOTTOMRIGHT", classContent, "BOTTOMRIGHT", 0,                0)
    rightCol.paddingLeft   = classContent.paddingLeft
    rightCol.paddingRight  = classContent.paddingRight
    rightCol.paddingTop    = classContent.paddingTop
    rightCol.paddingBottom = classContent.paddingBottom

    if cs.combat    then CB_BuildColumnGroups(leftCol,  cs.combat,    "co", slot, tag, combatStartGi, classRegistry, function(e) return e and e.classData and e.classData.combat    end) end
    if cs.nonCombat then CB_BuildColumnGroups(rightCol, cs.nonCombat, "nc", slot, tag, 1,            classRegistry, function(e) return e and e.classData and e.classData.nonCombat end) end

    return classRegistry
end

-- Splits groups by `column` field and renders them into two side-by-side
-- columns inside `parent`. Groups without a column field go left by default.
---@param parent    table   Container frame split into two columns.
---@param groups    table   Array of group definitions to distribute across columns.
---@param cmd       string  Bot command prefix for the toggles.
---@param slot      table   The bound slot (resolves the live bot).
---@param tag       string  Disambiguating tag for frame names.
---@param registry  table   Widget registry the created controls register into.
---@param getSource fun(entry:table):table?  Returns the state table the controls read/write.
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
    leftCol:SetPoint("TOPLEFT",     parent, "TOPLEFT", 0,                0)
    leftCol:SetPoint("BOTTOMRIGHT", parent, "BOTTOM",  -NS.COLUMN_GAP,   0)
    leftCol.paddingLeft   = parent.paddingLeft
    leftCol.paddingRight  = parent.paddingRight
    leftCol.paddingTop    = parent.paddingTop
    leftCol.paddingBottom = parent.paddingBottom

    local rightCol = CreateFrame("Frame", nil, parent)
    rightCol:SetPoint("TOPLEFT",     parent, "TOP",         NS.COLUMN_GAP,  0)
    rightCol:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0,              0)
    rightCol.paddingLeft   = parent.paddingLeft
    rightCol.paddingRight  = parent.paddingRight
    rightCol.paddingTop    = parent.paddingTop
    rightCol.paddingBottom = parent.paddingBottom

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
---@param container table   The bot content container to build into.
---@param slot      table   The bound slot (resolves the live bot).
---@param class     string  Class token (e.g. "WARRIOR").
---@param tag       string  Disambiguating tag for frame names.
local function CB_BuildBotContent(container, slot, class, tag)
    local entry = CleanBot_PartyBots[slot.key]

    local innerTabBar = CreateFrame("Frame", nil, container)
    innerTabBar:SetPoint("TOPLEFT",  container, "TOPLEFT",  0, 0)
    innerTabBar:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
    innerTabBar:SetHeight(NS.BOT_BAR_H)

    -- ctrl has padding stamped via CB_CreatePanel; propagate to all content frames
    -- so CB_AnchorBelow and first-item explicit anchors read the correct offsets.
    local ctrl = container:GetParent()

    local combatContent = CreateFrame("Frame", nil, container)
    combatContent:SetPoint("TOPLEFT",     container, "TOPLEFT",     0, -NS.BOT_BAR_H)
    combatContent:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    combatContent.paddingLeft   = ctrl.paddingLeft
    combatContent.paddingRight  = ctrl.paddingRight
    combatContent.paddingTop    = ctrl.paddingTop
    combatContent.paddingBottom = ctrl.paddingBottom

    local nonCombatContent = CreateFrame("Frame", nil, container)
    nonCombatContent:SetPoint("TOPLEFT",     container, "TOPLEFT",     0, -NS.BOT_BAR_H)
    nonCombatContent:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    nonCombatContent:Hide()
    nonCombatContent.paddingLeft   = ctrl.paddingLeft
    nonCombatContent.paddingRight  = ctrl.paddingRight
    nonCombatContent.paddingTop    = ctrl.paddingTop
    nonCombatContent.paddingBottom = ctrl.paddingBottom

    local classContent = CreateFrame("Frame", nil, container)
    classContent:SetPoint("TOPLEFT",     container, "TOPLEFT",     0, -NS.BOT_BAR_H)
    classContent:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    classContent:Hide()
    classContent.paddingLeft   = ctrl.paddingLeft
    classContent.paddingRight  = ctrl.paddingRight
    classContent.paddingTop    = ctrl.paddingTop
    classContent.paddingBottom = ctrl.paddingBottom

    local innerTabBtns = {}
    local function selectInnerTab(idx)
        for j, t in ipairs(innerTabBtns) do
            t:SetActive(j == idx)
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
        local itab = NS.CB_CreateTab(innerTabBar, "CleanBotInnerTab" .. tag .. "_" .. j,
                                     lbl, function() selectInnerTab(jj) end)
        if j == 1 then
            itab:SetPoint("LEFT", innerTabBar, "LEFT", (ctrl.paddingLeft or 0) + (itab.marginLeft or 0), 0)
        else
            NS.CB_AnchorAhead(itab, innerTabBtns[j - 1])
        end
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
local SelectBot           -- forward declaration: key-based selection used by both selectors

-- silent=true suppresses the emote wave for programmatic selections (e.g. RefreshTabs).
CleanBot_SelectTab = function(index, silent)
    if not index or index < 1 or index > #NS.tabList then return end
    local slot = NS.tabList[index]
    NS.selectedTabIndex = index
    NS.selectedBotKey   = slot.key

    for i, t in ipairs(NS.tabList) do
        local sel = (i == index)
        t.tabBtn:SetActive(sel)
        if sel then t.model:Show()  else t.model:Hide()  end
        if sel then t.ctrl:Show()   else t.ctrl:Hide()   end
    end

    if not silent and NS.botEmotes and slot.name ~= NS.lastWavedAt then
        NS.CB_SendBotCommand(slot.name, "emote wave")
    end
    NS.lastWavedAt = slot.name  -- always track so the first user click on the active tab doesn't re-fire
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
---@param index number  1-based pool index for naming the slot's frames.
---@return table         The created (unbound) slot table.
local function CB_CreateSlot(index)
    local contentW, contentH, modelH, eqColW, modelW = CB_GetGeometry()
    local slot = { index = index, contentByClass = {}, active = false }

    -- ── Tab button ────────────────────────────────────────────
    local tab = NS.CB_CreateTab(NS.botTabBar, "CleanBotCharTab" .. index,
                                "", function() SelectBot(slot.key) end)
    tab:SetWidth(NS.TAB_WIDTH)
    local icon = tab:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("LEFT", tab, "LEFT", NS.PADDING.panel.left, 0)
    icon:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
    tab:Hide()
    slot.tabBtn  = tab
    slot.tabIcon = icon

    -- ── Model (also builds star + equip slots, all class-agnostic) ──
    -- Parented to individualModelPanel so the model column is self-contained.
    -- Positioned at eqColW from the panel's left edge, leaving room for the
    -- left equip column. Equip buttons extend outside the model frame into
    -- that column area — this is intentional and valid in WoW.
    local model = NS.CB_CreateModel(slot, NS.individualModelPanel, modelW, modelH)
    model:ClearAllPoints()
    model:SetPoint("TOPLEFT", NS.individualModelPanel, "TOPLEFT", eqColW, 0)
    model:Hide()
    slot.model = model

    -- ── Ctrl container (holds the per-class content frames) ────
    -- CB_CreatePanel stamps paddingLeft/Right/Top/Bottom from the "panel" role,
    -- which downstream code reads to respect insets without raw NS.PADDING lookups.
    -- Positioned flush against individualStratPanel so the panel's own background and
    -- padding define the content area — no double-inset.
    local ctrl = NS.CB_CreatePanel(NS.individualStratPanel, "CleanBotCtrl" .. index, 3, "panel")
    ctrl:SetPoint("TOPLEFT",     NS.individualStratPanel, "TOPLEFT",     0, 0)
    ctrl:SetPoint("BOTTOMRIGHT", NS.individualStratPanel, "BOTTOMRIGHT", 0, 0)
    ctrl:Hide()
    slot.ctrl = ctrl

    return slot
end

-- Returns a free slot from the pool, growing the pool if all are in use.
---@return table  A free pool slot, creating a new one if none are available.
local function CB_AcquireSlot()
    for _, slot in ipairs(NS.tabPool) do
        if not slot.active then return slot end
    end
    local slot = CB_CreateSlot(#NS.tabPool + 1)
    NS.tabPool[#NS.tabPool + 1] = slot
    return slot
end

-- Builds (once) and returns the content handle for a class in this slot.
---@param slot  table   The slot whose content should be built if missing.
---@param class string  Class token used to build class-specific content.
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
---@param slot table  The slot whose per-key widget registries are repointed.
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
---@param slot table  The slot to unbind from its current bot and hide.
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
---@param slot table  The pool slot to bind.
---@param info table  The bot roster entry (name, class, unit, key) to bind to the slot.
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
-- Lazy binding + LRU + key-based selection
--
-- The selector (tabs or dropdown) enumerates the cheap NS.desiredBots list, but
-- heavy slots (model + equip + ctrl) are only bound on demand at selection and
-- capped at NS.MAX_LIVE_SLOTS via an LRU. This keeps big raids from building a
-- model per bot and is the shared machinery the future Group tab feeds.
-- ============================================================

-- Returns the desiredBots entry for a key, or nil.
local function CB_DesiredForKey(key)
    for _, d in ipairs(NS.desiredBots) do
        if d.key == key then return d end
    end
end

-- Returns the currently-bound (live) slot for a key, or nil.
local function CB_LiveSlotForKey(key)
    for _, slot in ipairs(NS.tabList) do
        if slot.key == key then return slot end
    end
end

-- Unbinds least-recently-used bound slots until there is room to bind one more
-- without exceeding NS.MAX_LIVE_SLOTS. keepKey is never evicted.
local function CB_EvictForBind(keepKey)
    while #NS.tabList >= NS.MAX_LIVE_SLOTS do
        local victim, victimIdx
        for i, slot in ipairs(NS.tabList) do
            if slot.key ~= keepKey and (not victim or (slot.lru or 0) < (victim.lru or 0)) then
                victim, victimIdx = slot, i
            end
        end
        if not victim then break end
        CB_UnbindSlot(victim)
        table.remove(NS.tabList, victimIdx)
    end
end

-- Key-based selection shared by the tab buttons and the dropdown. Binds the
-- bot's slot on demand (evicting the LRU slot if at capacity), then shows it.
-- silent=true suppresses the emote wave (programmatic selections).
SelectBot = function(key, silent)
    if not key then return end
    local slot = CB_LiveSlotForKey(key)
    if not slot then
        local d = CB_DesiredForKey(key)
        if not d then return end
        CB_EvictForBind(key)
        slot = CB_AcquireSlot()
        CB_BindSlot(slot, d)
        NS.tabList[#NS.tabList + 1] = slot
    end

    -- Re-inspect on every selection (not just on fresh bind). The client caches
    -- inspect data for only the last-inspected unit, so viewing another bot evicts
    -- this one's data — re-warming on each select keeps SetInventoryItem tooltips
    -- (gems/enchants/set bonuses) rich instead of falling back to generic links.
    -- CB_QueueEquipRefresh dedups against in-flight/queued entries, so rapid
    -- re-selects don't pile up.
    if NS.CB_QueueEquipRefresh and slot.unit and UnitExists(slot.unit) then
        NS.CB_QueueEquipRefresh({ { key = slot.key, unit = slot.unit } })
    end

    NS.lruClock = NS.lruClock + 1
    slot.lru = NS.lruClock

    local idx
    for i, s in ipairs(NS.tabList) do if s == slot then idx = i; break end end
    NS.selectedTabIndex = 0   -- force SelectTab to re-apply (slots may have rebound)
    CleanBot_SelectTab(idx, silent)

    if NS.selectorMode == "dropdown" and NS.botDropdown then
        UIDropDownMenu_SetText(NS.botDropdown, slot.name)
    end
end

-- ============================================================
-- NS.CB_ToggleIndividualExpand — shows/hides the strategy panel and resizes
-- CleanBotFrame. No slot relayout is needed because each panel (model and
-- strategy) tracks its own anchors independently.
-- ============================================================
--- Toggles the Individual strategy panel's expanded/collapsed state and resizes the frame.
NS.CB_ToggleIndividualExpand = function()
    NS.individualExpanded = not NS.individualExpanded
    if CleanBot_SavedVars then
        CleanBot_SavedVars.individualExpanded = NS.individualExpanded
    end

    NS.CB_ResizeFrame(NS.individualExpanded and NS.EXPANDED_WIDTH or NS.COLLAPSED_WIDTH)

    if NS.individualExpanded then
        NS.individualStratPanel:Show()
        NS.individualExpandBtn:SetText("<")
        -- Ensure the active slot's ctrl is visible now that the panel is open.
        local sel = NS.tabList[NS.selectedTabIndex]
        if sel and sel.ctrl then sel.ctrl:Show() end
    else
        NS.individualStratPanel:Hide()
        NS.individualExpandBtn:SetText(">")
    end
end

-- ============================================================
-- RefreshTabs — recomputes the cheap desired-bot roster, picks the tab vs
-- dropdown selector by group size, and (lazily, in dropdown mode) binds heavy
-- slots. Selection is key-based via SelectBot so it survives rebuilds and mode
-- switches. The future Group tab reuses this by supplying its own desiredBots.
-- ============================================================
--- Rebuilds the bot selector + bound slots from the current roster.
NS.CleanBot_RefreshTabs = function()
    -- ── 1. Compute the cheap desired-bot roster (party OR raid) ──
    local desired = {}
    NS.CB_ForEachGroupMember(function(unit, name)
        if name and UnitExists(unit) and NS.CleanBot_IsBot(unit) then
            local _, class = UnitClass(unit)
            table.insert(desired, { unit = unit, name = name, class = class or "WARRIOR", key = strlower(name) })
        end
    end)
    NS.desiredBots = desired

    local desiredByKey = {}
    for _, d in ipairs(desired) do desiredByKey[d.key] = true end

    -- Prune CleanBot_PartyBots to only current group members
    for key in pairs(CleanBot_PartyBots) do
        if not desiredByKey[key] then CleanBot_PartyBots[key] = nil end
    end

    -- If targeting a current group bot, pre-select it (drives the selector below).
    if UnitExists("target") and UnitIsPlayer("target") then
        local targetKey = strlower(UnitName("target") or "")
        if desiredByKey[targetKey] then NS.selectedBotKey = targetKey end
    end

    if NS.individualEmptyLabel then
        NS.individualEmptyLabel:SetText(#desired == 0 and "No bots found in your party or raid." or "")
    end

    -- ── 2. Drop any bound slot whose bot is no longer in the group ──
    for i = #NS.tabList, 1, -1 do
        local slot = NS.tabList[i]
        if not desiredByKey[slot.key] then
            CB_UnbindSlot(slot)
            table.remove(NS.tabList, i)
        end
    end

    -- ── 3. Choose the selector mode by group size ──────────────
    local useTabs   = (#desired <= NS.TAB_DROPDOWN_THRESHOLD)
    NS.selectorMode = useTabs and "tabs" or "dropdown"

    if #desired == 0 then
        if NS.botDropdown then NS.botDropdown:Hide() end
        for _, slot in ipairs(NS.tabPool) do slot.tabBtn:Hide() end
        NS.selectedTabIndex = 0
        return
    end

    if useTabs then
        -- Tab mode: bind a slot for every desired bot (≤ threshold ≤ cap, all warm)
        -- and lay the tab buttons out left→right in roster order.
        local existing = {}
        for _, slot in ipairs(NS.tabList) do existing[slot.key] = slot end
        local newList = {}
        for _, d in ipairs(desired) do
            local slot = existing[d.key]
            if slot then
                if slot.unit ~= d.unit then slot.unit = d.unit; slot.model:SetUnit(d.unit) end
                if slot.class ~= d.class then CB_BindSlot(slot, d) end
            else
                slot = CB_AcquireSlot()
                CB_BindSlot(slot, d)
            end
            newList[#newList + 1] = slot
        end
        NS.tabList = newList

        -- Equipment inspect is deliberately NOT batched across all bound bots. The
        -- client caches inspect data for only one unit at a time, so inspecting every
        -- bot would leave the cache on whichever finished LAST — not the viewed bot —
        -- making its rich SetInventoryItem tooltips (gems/enchants/set bonuses) revert
        -- to generic once the background queue drains. Instead, SelectBot inspects the
        -- viewed bot on every selection, keeping the cache warm for exactly the bot on
        -- screen (matches the lazy "only inspect bots we view" intent).

        local prevTabBtn = nil
        for _, slot in ipairs(NS.tabList) do
            slot.tabBtn:ClearAllPoints()
            if prevTabBtn then
                NS.CB_AnchorAhead(slot.tabBtn, prevTabBtn)
            else
                slot.tabBtn:SetPoint("LEFT", NS.botTabBar, "LEFT", NS.PADDING.panel.left + (slot.tabBtn.marginLeft or 0), 0)
            end
            slot.tabBtn:Show()
            prevTabBtn = slot.tabBtn
        end

        if NS.botDropdown then NS.botDropdown:Hide() end
    else
        -- Dropdown mode: enumerate all desired bots in the dropdown but bind slots
        -- lazily on selection (LRU-capped). Hide all tab buttons.
        for _, slot in ipairs(NS.tabPool) do slot.tabBtn:Hide() end
        if NS.botDropdown then
            UIDropDownMenu_Initialize(NS.botDropdown, function()
                for _, d in ipairs(NS.desiredBots) do
                    local info = UIDropDownMenu_CreateInfo()
                    info.text         = d.name
                    info.value        = d.key
                    info.notCheckable = true
                    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[d.class]
                    if c then info.colorCode = string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
                    info.func = function() SelectBot(d.key) end
                    UIDropDownMenu_AddButton(info)
                end
            end)
            NS.botDropdown:Show()
        end
    end

    -- ── 4. Establish selection (binds on demand in dropdown mode) ──
    local selKey = NS.selectedBotKey
    if not selKey or not desiredByKey[selKey] then selKey = desired[1].key end
    SelectBot(selKey, true)
end

-- ============================================================
-- NS.CB_UpdateTabData — refreshes all UI elements for one tab
-- from CleanBot_PartyBots[key] without touching layout.
-- Call after any code that modifies a bot's combat/nonCombat data.
-- ============================================================
---@param key string  Bot name-key whose bound slot should refresh its displayed data.
NS.CB_UpdateTabData = function(key)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    if NS.botStarUpdaters[key] then NS.botStarUpdaters[key]() end

    local function syncControls(controls, stratList, source)
        if not controls or not source then return end
        for _, s in ipairs(stratList) do
            local ctrl = controls[s.field]
            if not ctrl then
            elseif s.type == "timerSlider" then
                local val = source[s.field]
                ctrl:SetValue(val or s.min or 0)
                if s.dependsOn then
                    local enabled = source[s.dependsOn] and true or false
                    if enabled then ctrl:Enable() else ctrl:Disable() end
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
            if not syncDropdown(cf.dd, cf.strategies, cd) and cf.noneLabel then
                UIDropDownMenu_SetText(cf.dd, cf.noneLabel)
            end

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
            local activeSection = count <= 1 and activeRole and cf.roleToSection[activeRole] or nil
            for _, sub in pairs(cf.subSections) do
                if sub == activeSection then sub.section:Show() else sub.section:Hide() end
                syncControls(sub.checkboxes, sub.strategies, cd)
            end
        end
    end
end

-- ============================================================
-- NS.CB_SyncTalentSpec — sets the talent-spec dropdown from the bot's REAL
-- talents. Called from CB_OnInspectReady (Equip.lua) right after
-- INSPECT_TALENT_READY fires for the viewed bot, while its talent data is
-- readable via the inspect Talent APIs.
--
-- Identification: the bot's per-tree point totals are matched against the
-- per-class premade spreads cached from "talents spec list" (NS.premadeSpecs,
-- Bridge.lua) — the premade name there is the exact dropdown cmd. A unique
-- spread match selects that premade; zero/multiple matches fall back to
-- showing the dominant tree's name as the collapsed label only (no list entry
-- is checked — totals are the finest signal the server exposes).
-- ============================================================
---@param key string  Bot name-key of the bot whose inspect data just loaded.
NS.CB_SyncTalentSpec = function(key)
    local entry = CleanBot_PartyBots[key]
    if not entry or not entry.class then return end

    -- The class's talent-spec group (whisper = "talents spec"); bail if none.
    local cs = NS.CLASS_STRATEGIES and NS.CLASS_STRATEGIES[entry.class]
    if not cs or not cs.combat then return end
    local talentGroup = nil
    for _, group in ipairs(cs.combat) do
        if group.whisper then talentGroup = group; break end
    end
    if not talentGroup then return end

    -- Per-tree totals from the inspected unit's talent data. Summing
    -- GetTalentInfo ranks (same pattern as the Talented integration above)
    -- avoids GetTalentTabInfo return-order ambiguity for the points value.
    local totals    = {}
    local bestTab   = 1
    local allZero   = true
    local numTabs   = GetNumTalentTabs(true)
    if not numTabs or numTabs == 0 then return end
    for tab = 1, numTabs do
        local sum = 0
        for index = 1, GetNumTalents(tab, true) do
            sum = sum + (select(5, GetTalentInfo(tab, index, true)) or 0)
        end
        totals[tab] = sum
        if sum > 0 then allZero = false end
        if sum > (totals[bestTab] or 0) then bestTab = tab end
    end
    if allZero then return end   -- inspect data not actually readable (or untalented)

    -- Need the premade spread list for this class; fetch (once) and retry on finalize.
    local specs = NS.premadeSpecs and NS.premadeSpecs[entry.class]
    if not specs then
        if NS.CB_FetchSpecList then NS.CB_FetchSpecList(key, entry) end
        return
    end

    -- Match the bot's spread against the premades.
    local matched = nil
    local matchCount = 0
    for _, spec in ipairs(specs) do
        if spec.t[1] == (totals[1] or 0)
        and spec.t[2] == (totals[2] or 0)
        and spec.t[3] == (totals[3] or 0) then
            matchCount = matchCount + 1
            matched    = spec
        end
    end

    if not entry.classData then entry.classData = NS.CB_DefaultClassData(entry.class) end
    local src = entry.classData.combat
    if not src then return end

    local matchedStrat = nil
    if matchCount == 1 and matched then
        for _, s in ipairs(talentGroup.strategies) do
            if s.cmd == matched.name then matchedStrat = s; break end
        end
    end

    -- Write the resolved selection (or clear on ambiguity) and let the existing
    -- registry sync set the dropdown text + checked state.
    for _, s in ipairs(talentGroup.strategies) do
        src[s.field] = (s == matchedStrat) or false
    end
    if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key) end

    -- Ambiguous / unmatched: label the collapsed button with the dominant tree's
    -- name (display only — the list itself still shows the real premade entries).
    if not matchedStrat then
        local a, b = GetTalentTabInfo(bestTab, true)
        local treeName = (type(a) == "string" and a) or (type(b) == "string" and b) or nil
        if treeName then
            local frames = NS.botFrames and NS.botFrames[key]
            if frames then
                for _, cf in ipairs(frames) do
                    if cf.whisper and cf.dd then
                        UIDropDownMenu_SetText(cf.dd, treeName)
                        break
                    end
                end
            end
        end
    end
end
