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
-- Group-slot support — the build engine below serves two slot shapes:
--   * a real bot slot   ({ key, name, class, ... } — resolves one bot)
--   * a group slot      ({ isGroup = true, members = {{key,name,class},...},
--                          aggEntry = {...} } — GroupTab.lua)
-- Group slots read state from their aggregate entry and fan writes out to
-- every member, re-resolving class tokens/support per member.
-- ============================================================

-- Sentinel stored in a group aggregate entry when members disagree on a field.
-- A unique table so it can never collide with real strategy values.
NS.MIXED = {}

-- The state entry a slot's controls read: the group aggregate for group slots,
-- the live roster entry otherwise.
---@param slot table  A bot slot or group slot.
---@return table?     The entry whose combat/nonCombat/classData tables back the UI.
local function CB_SlotEntry(slot)
    return slot.isGroup and slot.aggEntry or CleanBot_PartyBots[slot.key]
end

-- The send/write targets for a slot: the group's members, or the slot itself.
---@param slot table  A bot slot or group slot.
---@return table      Array of {key,name,class} target tables.
local function CB_SlotTargets(slot)
    return slot.isGroup and slot.members or { slot }
end

-- Shared checkbox/sub-section toggle: per-target class gating + class token
-- resolution + optimistic write to the target's real entry + send. For a
-- single bot this is exactly the old inline OnClick body.
---@param slot      table    A bot slot or group slot.
---@param s         table    The strategy definition being toggled.
---@param checked   boolean  New checkbox state.
---@param cmd       string   Bot command prefix ("co" or "nc").
---@param getSource fun(entry:table?):table?  Extracts the state table from an entry.
local function CB_ToggleStrategy(slot, s, checked, cmd, getSource)
    for _, m in ipairs(CB_SlotTargets(slot)) do
        if NS.CB_StrategyShown(s, m.class) then
            local toggle = (checked and "+" or "-") .. NS.CB_EffStrategyCmd(s, m.class)
            local ds = getSource(CleanBot_PartyBots[m.key])
            if ds then ds[s.field] = checked end
            NS.CB_SendStrategyToggle(m, cmd, toggle, { [s.field] = checked })
        end
    end
    if slot.isGroup and NS.CB_OnGroupWrite then NS.CB_OnGroupWrite(slot) end
end

-- Timer-slider value send: every target gets "cmd N" plus the optimistic
-- entry.combat write (timer strategies only exist in the combat list).
---@param slot  table   A bot slot or group slot.
---@param strat table   The timerSlider strategy definition.
---@param v     number  The new timer value.
local function CB_SendTimerValue(slot, strat, v)
    for _, m in ipairs(CB_SlotTargets(slot)) do
        NS.CB_SendBotCommand(m.name, strat.cmd .. " " .. v)
        local e = CleanBot_PartyBots[m.key]
        if e and e.combat then e.combat[strat.field] = v end
    end
    if slot.isGroup and NS.CB_OnGroupWrite then NS.CB_OnGroupWrite(slot) end
end

-- Forward declaration: inline exclusive-dropdown renderer for a `type="dropdown"`
-- strategy bundle. Defined later (after the exclusive-selection + suffix helpers it
-- depends on), but referenced here in CB_BuildStrategySection.
local CB_BuildInlineDropdown

-- ============================================================
-- Strategy section builder — shared by combat, non-combat, and class tabs.
-- onClickFn(strategy, checked) overrides the default "co +/-cmd" whisper.
-- sourceTable supplies each checkbox's initial checked state (entry.combat,
-- entry.nonCombat, or a classData section); nil leaves boxes unchecked.
-- A strategy with type="dropdown" renders as an inline exclusive dropdown (its
-- nested `strategies` are the options) — those need cmd/getSource/registry, which
-- the checkbox path ignores.
-- Returns (sectionFrame, checkboxes) where checkboxes is keyed by field name.
-- ============================================================
---@param ctrl        table   Container frame the section is built into.
---@param anchor       table   Widget the section's first row anchors below.
---@param strategies   table   Strategy definitions to render as toggles.
---@param slot         table   The bound slot (resolves the live bot).
---@param tag          string  Disambiguating tag for frame names.
---@param onClickFn    fun()   Handler invoked when a strategy toggle is clicked.
---@param sourceTable  table   State table the toggles read/write.
---@param cmd          string?  Bot command prefix (for inline dropdown bundles).
---@param getSource    fun(entry:table?):table?  State-table extractor (inline dropdowns).
---@param registry     table?   Registry inline dropdowns self-register into for sync.
local function CB_BuildStrategySection(ctrl, anchor, strategies, slot, tag, onClickFn, sourceTable, cmd, getSource, registry)
    local section = CreateFrame("Frame", nil, ctrl)
    NS.CB_AnchorBelow(section, anchor)
    section:SetPoint("RIGHT", ctrl, "RIGHT", -(ctrl.paddingRight or 0), 0)
    section:SetHeight(#strategies * (NS.MARGIN.checkbox.top + 20 + NS.MARGIN.checkbox.bottom))
    NS.CB_ApplyFrameSkin(section, 4)

    local controls = {}
    -- Ordered render metadata for CB_RelayoutSection: each item carries its strategy
    -- (for the visibility test), the frames to show/hide, a `place(y)` that re-pins the
    -- row at a vertical offset, and the height it consumes. Bundles flag isBundle so the
    -- relayout tests "any nested option shown" instead of a single field.
    local layoutItems = {}
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
                    -- (Sync paths use SetValueSilent and never reach here.)
                    if ready and not dragging then
                        CB_SendTimerValue(slot, strat, v)
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
                CB_SendTimerValue(slot, strat, v)
            end)

            controls[s.field] = sl
            local sHeight = NS.MARGIN.slider.top + 54 + NS.MARGIN.slider.bottom
            layoutItems[#layoutItems + 1] = {
                strat = s, frames = { sl }, height = sHeight,
                place = function(y) sl:SetPoint("TOPLEFT", section, "TOPLEFT",
                    NS.PADDING.section.left + NS.MARGIN.slider.left, -y) end,
            }
            yOffset = yOffset + sHeight
        elseif s.type == "dropdown" then
            -- Inline exclusive dropdown bundle (e.g. the DPS "Rotation" selector).
            local consumed, place, frames =
                CB_BuildInlineDropdown(section, s, yOffset, slot, tag, cmd, getSource, registry)
            layoutItems[#layoutItems + 1] = {
                strat = s, isBundle = true, frames = frames, height = consumed, place = place,
            }
            yOffset = yOffset + consumed
        else
            local cb = NS.CB_CreateCheckBox(section, "CleanBotCB_" .. s.field .. "_" .. tag)
            cb:SetSize(20, 20)
            cb:SetPoint("TOPLEFT", section, "TOPLEFT", NS.PADDING.section.left + NS.MARGIN.checkbox.left, -yOffset)

            local lbl = section:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
            lbl:SetText(s.name)
            -- Stamped so CB_SyncRegistry can compose group suffixes (" (?)" mixed,
            -- " (*)" partially supported) and reset to the base label afterwards.
            cb.labelFS   = lbl
            cb.labelBase = s.name

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
                -- Unreachable today: every live call site supplies onClickFn.
                -- Kept as a single-bot "co" fallback should one ever omit it.
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
            local cHeight = NS.MARGIN.checkbox.top + 20 + NS.MARGIN.checkbox.bottom
            -- The label is anchored to cb (so re-pinning cb carries it along) but is parented to
            -- the section, not cb — so it must be shown/hidden explicitly alongside cb, else a
            -- hidden row's label floats over the rows that repack into its place.
            layoutItems[#layoutItems + 1] = {
                strat = s, frames = { cb, lbl }, height = cHeight,
                place = function(y) cb:SetPoint("TOPLEFT", section, "TOPLEFT",
                    NS.PADDING.section.left + NS.MARGIN.checkbox.left, -y) end,
            }
            yOffset = yOffset + cHeight
        end
    end

    section.layoutItems = layoutItems
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

-- Whether a section layout item is supported by a slot: a bundle is shown when ANY of its
-- nested options is, an ordinary row when its own strategy is (CB_StrategyShownForSlot).
---@param item table  A section.layoutItems entry.
---@param slot table  The bound slot.
---@return boolean
local function CB_LayoutItemShown(item, slot)
    if item.isBundle then
        for _, ns in ipairs(item.strat.strategies) do
            if NS.CB_StrategyShownForSlot(ns, slot) then return true end
        end
        return false
    end
    return NS.CB_StrategyShownForSlot(item.strat, slot)
end

-- Reflows a strategy section for the slot's current members: hides rows no member supports,
-- re-pins the shown rows so the gaps close, and resizes the section. The running offset
-- mirrors CB_BuildStrategySection exactly (the per-row place closures reuse the same
-- constants), so a fully-shown section lands identically to its build-time layout. Returns
-- the new section height (the column relayout uses it to recompute reserved sub-section room).
---@param section table  A section frame stamped with `layoutItems` by CB_BuildStrategySection.
---@param slot    table  The bound slot.
---@return number        The section's new height.
local function CB_RelayoutSection(section, slot)
    local items = section.layoutItems
    if not items then return section:GetHeight() end
    local yOffset = NS.PADDING.section.top
    for _, item in ipairs(items) do
        if CB_LayoutItemShown(item, slot) then
            item.place(yOffset)
            for _, f in ipairs(item.frames) do f:Show() end
            yOffset = yOffset + item.height
        else
            for _, f in ipairs(item.frames) do f:Hide() end
        end
    end
    local h = yOffset + NS.PADDING.section.bottom
    section:SetHeight(h)
    return h
end

-- Applies a mutually-exclusive strategy selection per target: each gets a
-- single "cmd +sel,-other,-other..." toggle list built from ITS class tokens,
-- restricted to the strategies its class supports, with the matching
-- optimistic write into its real entry.
--
-- Group semantics: a member whose class can't take the SELECTED strategy is
-- skipped entirely (it keeps its current selection — no bare "-" stripping).
-- selectedField = nil (a noneLabel pick) clears the set on every target.
---@param strategies    table    The mutually-exclusive strategy group.
---@param selectedField string?  Field of the chosen strategy (nil clears all).
---@param cmd           string   Bot command prefix to send for the selection.
---@param slot          table    A bot slot or group slot.
---@param getSource     fun(entry:table?):table?  Extracts the state table from an entry.
---@param addCmdFn      fun(m:table):string?  Optional per-member resolver returning a token to
---                              ALSO add (`+token`). Used by the Role group's "DPS" pick to
---                              re-add the spec damage rotation (matched to each bot's detected
---                              talent spec) that the engine dropped when tank/heal was set —
---                              otherwise the bot is left with no rotation. The added token has
---                              no UI field, so it isn't optimistically written; co? reconciles.
local function CB_ApplyExclusiveSelection(strategies, selectedField, cmd, slot, getSource, addCmdFn)
    local selStrat = nil
    if selectedField then
        for _, rs in ipairs(strategies) do
            if rs.field == selectedField then selStrat = rs break end
        end
    end
    for _, m in ipairs(CB_SlotTargets(slot)) do
        if not (selStrat and not NS.CB_StrategyShown(selStrat, m.class)) then
            local parts  = {}
            local expect = {}
            local ds     = getSource(CleanBot_PartyBots[m.key])
            for _, rs in ipairs(strategies) do
                if NS.CB_StrategyShown(rs, m.class) then
                    local on = (rs.field == selectedField)
                    parts[#parts + 1] = (on and "+" or "-") .. NS.CB_EffStrategyCmd(rs, m.class)
                    expect[rs.field] = on
                    if ds then ds[rs.field] = on end
                end
            end
            local addCmd = addCmdFn and addCmdFn(m)
            if addCmd then parts[#parts + 1] = "+" .. addCmd end
            if #parts > 0 then
                -- Optimistic write above; toggle + authoritative reconcile (self-healing).
                NS.CB_SendStrategyToggle(m, cmd, table.concat(parts, ","), expect)
            end
        end
    end
    if slot.isGroup and NS.CB_OnGroupWrite then NS.CB_OnGroupWrite(slot) end
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

    -- "Show Talents" rides the single-unit inspect path, which has no group
    -- equivalent — group slots skip the button and anchor the spec controls
    -- straight below the header.
    local specAnchor = header
    if not slot.isGroup then
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
        specAnchor = showBtn
    end

    local setBtn = NS.CB_CreateButton(parent, "CleanBotSetTal_" .. tag .. "_" .. gi .. "s",
                                      "Set Talents", 100, 22)
    NS.CB_AnchorBelow(setBtn, specAnchor)

    local dd = NS.CB_CreateDropdown(parent, "CleanBotClassDD_" .. tag .. "_" .. gi, 130)
    NS.CB_AnchorAhead(dd, setBtn)

    -- Group note: the aggregate pass skips whisper groups (spec state is
    -- inspect-driven, not parseable from co?/nc?), so a group's spec dropdown
    -- stays blank until the user picks one here — the optimistic write below
    -- then survives aggregate rebuilds.
    UIDropDownMenu_Initialize(dd, function(self)
        local e  = CB_SlotEntry(slot)
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
                local cd2 = getSource(CB_SlotEntry(slot))
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
        local cd = getSource(CB_SlotEntry(slot))
        if not cd then return end
        for _, s in ipairs(strategies) do
            if cd[s.field] == true then
                for _, m in ipairs(CB_SlotTargets(slot)) do
                    NS.CB_SendBotCommand(m.name, specWhisper .. " " .. s.cmd)
                end
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

-- " (*)" when a group slot's members only PARTIALLY support a strategy (the
-- send will skip the unsupported ones). Mirrors the partial map the aggregate
-- pass computes, but cheap enough to evaluate live for dropdown menu entries.
---@param slot table  A bot slot or group slot.
---@param s    table  Strategy definition.
---@return string     " (*)" or "".
local function CB_PartialSuffix(slot, s)
    if not slot.isGroup then return "" end
    local supported, total = 0, 0
    for _, m in ipairs(slot.members) do
        total = total + 1
        if NS.CB_StrategyShown(s, m.class) then supported = supported + 1 end
    end
    return (supported > 0 and supported < total) and " (*)" or ""
end

-- Renders an inline exclusive dropdown (a `type="dropdown"` strategy bundle) inside a
-- strategy section: a header label + a dropdown whose options are the bundle's nested
-- strategies (class-filtered), led by the noneLabel "clear" entry. Picking one sends the
-- mutually-exclusive toggle via CB_ApplyExclusiveSelection, and the dropdown self-registers
-- a type="dropdown" entry so CB_SyncRegistry repaints it from bot state (Individual + Group).
-- Returns the vertical space consumed (so the section flow continues below it), plus a
-- `place(y)` that re-pins the header + dropdown for the reflow, and the frames to show/hide.
---@param section   table   The section frame to render into.
---@param s         table   The dropdown bundle definition.
---@param yOffset   number  Current vertical offset within the section.
---@param slot      table   The bound slot.
---@param tag       string  Disambiguating frame-name tag.
---@param cmd       string  Bot command prefix ("co"/"nc").
---@param getSource fun(entry:table?):table?  State-table extractor.
---@param registry  table?  Registry to self-register into for sync.
---@return number           Vertical space consumed (px).
---@return fun(y:number)    place — re-pins the header + dropdown at a new vertical offset.
---@return table            frames — { header, dropdown } to show/hide during reflow.
function CB_BuildInlineDropdown(section, s, yOffset, slot, tag, cmd, getSource, registry)
    local nested    = CB_ShownStrategies(s.strategies, slot.class)
    local noneLabel = s.noneLabel
    local noneDesc  = s.noneDesc
    local key       = s.group or s.field or "dd"

    local hdr = section:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    hdr:SetPoint("TOPLEFT", section, "TOPLEFT",
        NS.PADDING.section.left + NS.MARGIN.checkbox.left, -yOffset)
    hdr:SetText(s.header)
    local used = NS.MARGIN.checkbox.top + 16 + NS.MARGIN.checkbox.bottom

    local dd = NS.CB_CreateDropdown(section, "CleanBotSubDD_" .. cmd .. key .. "_" .. tag, 140)
    dd:SetPoint("TOPLEFT", section, "TOPLEFT", NS.PADDING.section.left, -(yOffset + used))

    UIDropDownMenu_Initialize(dd, function(self)
        local cd = (getSource and getSource(CB_SlotEntry(slot))) or {}
        if noneLabel then
            local info = UIDropDownMenu_CreateInfo()
            info.text = noneLabel
            if noneDesc then
                info.tooltipTitle    = noneLabel
                info.tooltipText     = noneDesc
                info.tooltipOnButton = 1
            end
            local anyActive = false
            for _, ns in ipairs(nested) do
                if cd[ns.field] == true or cd[ns.field] == NS.MIXED then anyActive = true break end
            end
            info.checked = not anyActive
            info.func = function()
                UIDropDownMenu_SetText(self, noneLabel)
                CB_ApplyExclusiveSelection(nested, nil, cmd, slot, getSource)
            end
            UIDropDownMenu_AddButton(info)
        end
        for _, ns in ipairs(nested) do
            -- Drop options no current member's class supports (group slot); always
            -- shown on the single-bot path where nested is already class-filtered.
            if NS.CB_StrategyShownForSlot(ns, slot) then
                local info           = UIDropDownMenu_CreateInfo()
                info.text            = ns.name .. CB_PartialSuffix(slot, ns)
                info.value           = ns.field
                info.tooltipTitle    = ns.name
                info.tooltipText     = ns.desc
                info.tooltipOnButton = 1
                info.func            = function()
                    UIDropDownMenu_SetText(self, ns.name)
                    CB_ApplyExclusiveSelection(nested, ns.field, cmd, slot, getSource)
                end
                info.checked = cd[ns.field] == true
                UIDropDownMenu_AddButton(info)
            end
        end
    end)

    if registry then
        registry[#registry + 1] = {
            type = "dropdown", dd = dd, strategies = nested, getSource = getSource,
            noneLabel = noneLabel, groupId = cmd .. ":" .. key,
        }
    end

    -- Relayout closure: re-pin the header + dropdown to a new vertical offset (used by
    -- CB_RelayoutSection when earlier rows hide and this bundle slides up).
    local function place(y)
        hdr:SetPoint("TOPLEFT", section, "TOPLEFT",
            NS.PADDING.section.left + NS.MARGIN.checkbox.left, -y)
        dd:SetPoint("TOPLEFT", section, "TOPLEFT", NS.PADDING.section.left, -(y + used))
    end
    return used + NS.MARGIN.dropdown.top + 32 + NS.MARGIN.dropdown.bottom, place, { hdr, dd }
end

-- Unique key for a roleDropdown's none-subsection (the subGroup with `none = true`, shown
-- when no rotation token is set — the "DPS" default). A table sentinel can't collide with a
-- strategy field name in the subSections / roleToSection maps.
local ROLE_NONE = {}

---@param col       table   The column frame to build into.
---@param groups    table   Array of group definitions for this column.
---@param cmd       string  Bot command prefix for the column's toggles.
---@param slot      table   The bound slot (resolves the live bot).
---@param tag       string  Disambiguating tag for frame names.
---@param startGi   number  Group index of the first group in this column.
---@param registry  table   Widget registry the created controls register into.
---@param getSource fun(entry:table):table?  Returns the state table the controls read/write.
local function CB_BuildColumnGroups(col, groups, cmd, slot, tag, startGi, registry, getSource)
    local entry      = CB_SlotEntry(slot)
    local prevBottom = nil
    -- A roleDropdown with `subAfter = <group key>` defers its sub-sections to render below
    -- that later group (so the Role and Assist dropdowns sit one after the other). Holds
    -- { anchor, maxSubH, afterKey } until that group renders; resolved at the loop's tail.
    local deferredSub = nil

    -- Generic Group columns (group slot, no fixed class) build the FULL strategy list and
    -- later reflow per selection (CB_RelayoutColumn) to hide strategies no member supports.
    -- Record an ordered node per top-level group so the reflow can re-run this same anchor
    -- walk over the built frames. Single-bot / per-class columns build class-filtered and
    -- never reflow, so they skip this bookkeeping entirely.
    local isGenericGroup = slot.isGroup and not slot.class
    local chain = isGenericGroup and {} or nil
    -- Builds a header re-anchor closure mirroring the build-time anchoring (below prevBottom,
    -- or the column's top-left when it's the first shown node).
    local function makeAnchorHead(hdr)
        return function(pb)
            if pb then
                NS.CB_AnchorBelow(hdr, pb)
            else
                hdr:ClearAllPoints()
                hdr:SetPoint("TOPLEFT", col, "TOPLEFT",
                    (col.paddingLeft or 0) + (hdr.marginLeft or 0),
                    -((col.paddingTop or 0) + (hdr.marginTop or 0)))
            end
        end
    end
    -- Whether ANY leaf strategy in a group list is shown for the slot (descends inline
    -- dropdown bundles). A group node hides when this is false (no member supports anything).
    local function anyStrategyShown(strategies)
        for _, s in ipairs(strategies) do
            if s.type == "dropdown" then
                for _, ns in ipairs(s.strategies) do
                    if NS.CB_StrategyShownForSlot(ns, slot) then return true end
                end
            elseif NS.CB_StrategyShownForSlot(s, slot) then
                return true
            end
        end
        return false
    end

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

            -- Build all sub-sections anchored to ddAnchor; only one shows at a time. The
            -- none-subsection (sg.none — the "DPS" default) is keyed under the ROLE_NONE
            -- sentinel since it has no field of its own.
            local subSections = {}
            local subSecList  = {}   -- ordered sections, for the reflow's maxSubH recompute
            local maxSubH     = 0
            local initSrc     = getSource(entry) or {}
            for _, sg in ipairs(group.subGroups) do
                local sgStrats = CB_ShownStrategies(sg.strategies, slot.class)
                local sec, cbs = CB_BuildStrategySection(col, ddAnchor, sgStrats, slot, tag,
                    function(s, checked)
                        CB_ToggleStrategy(slot, s, checked, cmd, getSource)
                    end,
                    initSrc, cmd, getSource, registry)
                sec:Hide()
                subSections[sg.none and ROLE_NONE or sg.field] =
                    { section = sec, checkboxes = cbs, strategies = sgStrats }
                subSecList[#subSecList + 1] = sec
                -- Use the section's own resolved height: subsections may contain an inline
                -- dropdown (taller than a checkbox row), so a per-row estimate underreserves.
                maxSubH = math.max(maxSubH, sec:GetHeight())
            end

            -- Map every role field to its sub-section. A subgroup may serve multiple
            -- roles (sg.roles) — e.g. the none/DPS section also serves the Paladin Off-Heal
            -- role (sg.roles = { "offheal" }). The none case itself is keyed by ROLE_NONE.
            local roleToSection = {}
            for _, sg in ipairs(group.subGroups) do
                local sec = subSections[sg.none and ROLE_NONE or sg.field]
                for _, rf in ipairs(sg.roles or { sg.field }) do roleToSection[rf] = sec end
            end
            local noneSection = subSections[ROLE_NONE]

            -- Show the right sub-section: exactly one active rotation token → that role's
            -- section; otherwise (the "DPS" default — rotation tokens are true engine siblings
            -- so >1 can't happen) → the none section. Returns the active field, or nil.
            local function showSection(src)
                local count, field = 0, nil
                for _, s in ipairs(strategies) do
                    if src[s.field] == true then count = count + 1; if not field then field = s.field end end
                end
                for _, sub in pairs(subSections) do sub.section:Hide() end
                if count == 1 and roleToSection[field] then
                    roleToSection[field].section:Show()
                    return field
                end
                if noneSection then noneSection.section:Show() end
                return nil
            end
            local initField = showSection(initSrc)
            do  -- collapsed dropdown text: the active role's name, else the noneLabel ("DPS")
                local label = group.noneLabel
                for _, s in ipairs(strategies) do if s.field == initField then label = s.name end end
                UIDropDownMenu_SetText(dd, label)
            end

            UIDropDownMenu_Initialize(dd, function(self)
                local src = getSource(CB_SlotEntry(slot)) or {}
                -- Leading "DPS" (noneLabel) entry: clears every rotation token, shows none section.
                if group.noneLabel then
                    local info           = UIDropDownMenu_CreateInfo()
                    info.text            = group.noneLabel
                    if group.noneDesc then
                        info.tooltipTitle    = group.noneLabel
                        info.tooltipText     = group.noneDesc
                        info.tooltipOnButton = 1
                    end
                    info.func            = function()
                        UIDropDownMenu_SetText(self, group.noneLabel)
                        -- Re-add the bot's detected-spec DPS rotation (preserve intent),
                        -- falling back to the class canonical token if its spec isn't known.
                        local addCmdFn = function(m)
                            local e = CleanBot_PartyBots[m.key]
                            return (NS.CB_DetectedDpsToken and NS.CB_DetectedDpsToken(e))
                                or (group.dpsCmdByClass and group.dpsCmdByClass[m.class])
                        end
                        CB_ApplyExclusiveSelection(strategies, nil, cmd, slot, getSource, addCmdFn)
                        for _, sub in pairs(subSections) do sub.section:Hide() end
                        if noneSection then noneSection.section:Show() end
                    end
                    -- "Checked" when no rotation token is set.
                    local anyOn = false
                    for _, s in ipairs(strategies) do if src[s.field] == true then anyOn = true break end end
                    info.checked = not anyOn
                    UIDropDownMenu_AddButton(info)
                end
                for _, s in ipairs(strategies) do
                    -- Hide role options no current member's class can perform (group slot).
                    if NS.CB_StrategyShownForSlot(s, slot) then
                        local info           = UIDropDownMenu_CreateInfo()
                        info.text            = s.name .. CB_PartialSuffix(slot, s)
                        info.value           = s.field
                        info.tooltipTitle    = s.name
                        info.tooltipText     = s.desc
                        info.tooltipOnButton = 1
                        info.func            = function()
                            UIDropDownMenu_SetText(self, s.name)
                            CB_ApplyExclusiveSelection(strategies, s.field, cmd, slot, getSource)
                            for _, sub in pairs(subSections) do sub.section:Hide() end
                            local sec = roleToSection[s.field]
                            if sec then sec.section:Show() end
                        end
                        info.checked = src[s.field] == true
                        UIDropDownMenu_AddButton(info)
                    end
                end
            end)

            -- Reflow node (generic Group only): the role dropdown stays visible (its "DPS"
            -- default is always meaningful — every class is at least a damage dealer); the
            -- reflow only re-pins the header, re-flows each sub-section's rows, and recomputes
            -- the reserved sub-section height from the rows that survive for the members.
            local roleNode
            if isGenericGroup then
                roleNode = {
                    kind = "role", groupKey = group.group, shown = function() return true end,
                    anchorHead = makeAnchorHead(header), dd = dd, ddAnchor = ddAnchor,
                    subAfter = group.subAfter, maxSubH = maxSubH, frames = { header, dd },
                    relayoutSubs = function()
                        local m = 0
                        for _, sec in ipairs(subSecList) do
                            m = math.max(m, CB_RelayoutSection(sec, slot))
                        end
                        roleNode.maxSubH = m
                        return m
                    end,
                }
                chain[#chain + 1] = roleNode
            end

            if group.subAfter then
                -- Defer the sub-sections (and their reserved height) to render below a later
                -- group; the loop tail re-anchors ddAnchor + drops the spacer once it renders.
                -- The next group anchors right under the role dropdown → adjacent dropdowns.
                prevBottom  = dd
                deferredSub = { anchor = ddAnchor, maxSubH = maxSubH, afterKey = group.subAfter, node = roleNode }
            else
                -- Spacer to hold vertical room for the dropdown + tallest sub-section.
                local spacer = CreateFrame("Frame", nil, col)
                spacer:SetSize(1, 1)
                spacer.marginTop    = 0
                spacer.marginBottom = 0
                spacer:SetPoint("TOPLEFT", ddAnchor, "TOPLEFT", 0, -maxSubH)
                prevBottom = spacer
                if roleNode then roleNode.spacer = spacer end
            end

            if registry then
                registry[#registry + 1] = {
                    type          = "roleDropdown",
                    dd            = dd,
                    strategies    = strategies,
                    getSource     = getSource,
                    groupId       = cmd .. ":" .. (group.group or group.header),
                    noneLabel     = group.noneLabel,
                    subSections   = subSections,
                    roleToSection = roleToSection,
                    noneSection   = noneSection,
                }
            end

        elseif group.type == "dropdown" then
            -- Exclusive dropdown: selection sends cmd +/- for each strategy. An optional
            -- group.noneLabel adds a leading clear entry that deselects all (e.g. "None"
            -- to drop every blessing) — nil selection → CB_ApplyExclusiveSelection sends
            -- all "-".
            local strategies = group.strategies
            local noneLabel  = group.noneLabel
            local noneDesc   = group.noneDesc
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
                local cd = getSource(CB_SlotEntry(slot)) or {}
                if noneLabel then
                    local info        = UIDropDownMenu_CreateInfo()
                    info.text         = noneLabel
                    if noneDesc then
                        info.tooltipTitle    = noneLabel
                        info.tooltipText     = noneDesc
                        info.tooltipOnButton = 1
                    end
                    -- NS.MIXED counts as active: members disagree, so "None"
                    -- must not show as the settled choice.
                    local anyActive = false
                    for _, s in ipairs(strategies) do
                        if cd[s.field] == true or cd[s.field] == NS.MIXED then anyActive = true break end
                    end
                    info.checked      = not anyActive
                    info.func         = function()
                        UIDropDownMenu_SetText(self, noneLabel)
                        CB_ApplyExclusiveSelection(strategies, nil, cmd, slot, getSource)
                    end
                    UIDropDownMenu_AddButton(info)
                end
                for _, s in ipairs(strategies) do
                    -- Drop options no current member's class supports (group slot).
                    if NS.CB_StrategyShownForSlot(s, slot) then
                        local info           = UIDropDownMenu_CreateInfo()
                        info.text            = s.name .. CB_PartialSuffix(slot, s)
                        info.value           = s.field
                        info.tooltipTitle    = s.name
                        info.tooltipText     = s.desc
                        info.tooltipOnButton = 1
                        info.func            = function()
                            UIDropDownMenu_SetText(self, s.name)
                            CB_ApplyExclusiveSelection(strategies, s.field, cmd, slot, getSource)
                        end
                        info.checked = cd[s.field] == true
                        UIDropDownMenu_AddButton(info)
                    end
                end
            end)
            if group.readonly then UIDropDownMenu_DisableDropDown(dd) end

            if registry then
                -- groupId is cmd-prefixed: the combat and non-combat Movement groups
                -- share group="movement", and the none-state map must keep them apart.
                registry[#registry + 1] = { type = "dropdown", dd = dd, strategies = strategies, getSource = getSource, noneLabel = noneLabel, groupId = cmd .. ":" .. (group.group or group.header) }
            end
            if isGenericGroup then
                chain[#chain + 1] = {
                    kind = "simple", groupKey = group.group, frames = { header, dd },
                    anchorHead = makeAnchorHead(header), bottom = dd,
                    shown = function() return anyStrategyShown(strategies) end,
                }
            end
            prevBottom = dd

        elseif group.type == "settingDropdown" then
            -- A queried command SETTING (e.g. loot quality via "ll"), not a co/nc strategy: it reads
            -- a TOP-LEVEL entry field (group.field, e.g. entry.lootStrategy — set from the bot's
            -- "Loot strategy:" reply) and sends "<group.cmd> <value>" to the slot's targets. It
            -- self-refreshes via NS.commandRefreshers (driven by CB_RefreshCommands), NOT the
            -- strategy registry/sync. Renders for Individual and Group alike via CB_SlotTargets.
            local options = group.options
            local field   = group.field
            local nameByValue = {}
            for _, o in ipairs(options) do nameByValue[o.value] = o.name end

            local header = NS.CB_CreateLabel(col, group.header)
            if prevBottom then NS.CB_AnchorBelow(header, prevBottom)
            else header:SetPoint("TOPLEFT", col, "TOPLEFT",
                (col.paddingLeft or 0) + (header.marginLeft or 0),
                -((col.paddingTop or 0) + (header.marginTop  or 0))) end

            local dd = NS.CB_CreateDropdown(col, "CleanBotSetDD_" .. cmd .. tag .. "_" .. (group.group or gi), 160)
            NS.CB_AnchorBelow(dd, header)

            UIDropDownMenu_Initialize(dd, function(self)
                for _, o in ipairs(options) do
                    local info           = UIDropDownMenu_CreateInfo()
                    info.text            = o.name
                    info.value           = o.value
                    info.tooltipTitle    = o.name
                    info.tooltipText     = o.desc
                    info.tooltipOnButton = 1
                    info.func            = function()
                        UIDropDownMenu_SetText(self, o.name)        -- immediate feedback
                        for _, m in ipairs(CB_SlotTargets(slot)) do
                            NS.CB_SendBotCommand(m.name, group.cmd .. " " .. o.value)
                            local e = CleanBot_PartyBots[m.key]
                            if e then e[field] = o.value end         -- optimistic cache
                        end
                        if NS.CB_RefreshCommands then NS.CB_RefreshCommands() end
                    end
                    UIDropDownMenu_AddButton(info)
                end
            end)

            -- Reflect the slot's current value: all targets agree → that option; differ → "Mixed";
            -- any unknown (not yet queried) → "Select…".
            local function refresh()
                local result
                for _, m in ipairs(CB_SlotTargets(slot)) do
                    local e = CleanBot_PartyBots[m.key]
                    local v = e and e[field]
                    if not v then result = nil break end
                    if result == nil then result = v
                    elseif result ~= v then result = NS.MIXED break end
                end
                if result == NS.MIXED then
                    UIDropDownMenu_SetText(dd, "Mixed")
                elseif result then
                    UIDropDownMenu_SetText(dd, nameByValue[result] or result)
                else
                    UIDropDownMenu_SetText(dd, "Select\226\128\166")  -- "Select…"
                end
            end
            refresh()
            NS.commandRefreshers[#NS.commandRefreshers + 1] = refresh
            if isGenericGroup then
                -- A command setting, not a class-gated strategy → always shown.
                chain[#chain + 1] = {
                    kind = "simple", groupKey = group.group, frames = { header, dd },
                    anchorHead = makeAnchorHead(header), bottom = dd,
                    shown = function() return true end,
                }
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
                    CB_ToggleStrategy(slot, s, checked, cmd, getSource)
                end,
                getSource(entry), cmd, getSource, registry)
            section:Show()
            if registry then
                registry[#registry + 1] = { type = "checkboxes", checkboxes = checkboxes, strategies = groupStrats, getSource = getSource }
            end
            if isGenericGroup then
                chain[#chain + 1] = {
                    kind = "simple", groupKey = group.group, frames = { header, section },
                    anchorHead = makeAnchorHead(header), bottom = section, section = section,
                    shown = function() return anyStrategyShown(group.strategies) end,
                }
            end
            prevBottom = section
        end

        -- Resolve a deferred roleDropdown sub-section: once its target group has rendered,
        -- drop the sub-sections + reserved height below it (prevBottom = that group's bottom).
        if deferredSub and group.group == deferredSub.afterKey then
            deferredSub.anchor:ClearAllPoints()
            deferredSub.anchor:SetPoint("TOPLEFT", prevBottom, "BOTTOMLEFT", 0, 0)
            local spacer = CreateFrame("Frame", nil, col)
            spacer:SetSize(1, 1)
            spacer.marginTop    = 0
            spacer.marginBottom = 0
            spacer:SetPoint("TOPLEFT", deferredSub.anchor, "TOPLEFT", 0, -deferredSub.maxSubH)
            prevBottom  = spacer
            if deferredSub.node then deferredSub.node.spacer = spacer end
            deferredSub = nil
        end
    end

    -- Fallback: target group never rendered (e.g. filtered out) — reserve the sub-section
    -- height at its initial position (directly under the role dropdown) so nothing overlaps.
    if deferredSub then
        local spacer = CreateFrame("Frame", nil, col)
        spacer:SetSize(1, 1)
        spacer.marginTop    = 0
        spacer.marginBottom = 0
        spacer:SetPoint("TOPLEFT", deferredSub.anchor, "TOPLEFT", 0, -deferredSub.maxSubH)
        if deferredSub.node then deferredSub.node.spacer = spacer end
    end

    if isGenericGroup then col.__layoutChain = chain end
end

-- Reflows one generic Group column for the slot's current members: re-runs the build's
-- anchor walk over the recorded node chain, hiding groups no member supports and closing
-- the gap (prevBottom is only advanced past shown nodes). The role dropdown stays put but
-- re-flows its sub-sections and updates its reserved height; the deferred sub-section block
-- and its spacer are re-anchored exactly as the build does. Reuses every built frame — no
-- frame is created here, so repeated relayouts never leak.
---@param col  table  A column frame stamped with `__layoutChain` (generic Group only).
---@param slot table  The generic group slot (NS.groupSlot).
local function CB_RelayoutColumn(col, slot)
    local chain = col.__layoutChain
    if not chain then return end
    local prevBottom = nil
    local deferred   = nil   -- a role node awaiting its `subAfter` target group

    -- Re-anchor a role node's deferred sub-section block (ddAnchor) below `below`, then its
    -- spacer below ddAnchor reserving the current maxSubH.
    local function placeRoleTail(node, below)
        node.ddAnchor:ClearAllPoints()
        node.ddAnchor:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, 0)
        node.spacer:ClearAllPoints()
        node.spacer:SetPoint("TOPLEFT", node.ddAnchor, "TOPLEFT", 0, -node.maxSubH)
    end

    for _, node in ipairs(chain) do
        if node.kind == "role" then
            -- Always shown; re-pin the header (dd + ddAnchor chain follow) and re-flow subs.
            node.anchorHead(prevBottom)
            for _, f in ipairs(node.frames) do f:Show() end
            node.relayoutSubs()   -- recomputes node.maxSubH from the surviving rows
            if node.subAfter then
                prevBottom = node.dd
                deferred   = node
            else
                placeRoleTail(node, node.dd)
                prevBottom = node.spacer
            end
        elseif node.shown(slot) then
            node.anchorHead(prevBottom)
            for _, f in ipairs(node.frames) do f:Show() end
            if node.section then CB_RelayoutSection(node.section, slot) end
            prevBottom = node.bottom
        else
            for _, f in ipairs(node.frames) do f:Hide() end
            -- prevBottom unchanged → the next shown node anchors here, closing the gap.
        end

        -- Resolve a deferred role node once its subAfter target group has been processed
        -- (matches the build's loop-tail resolution; fires regardless of that node's state).
        if deferred and node.groupKey == deferred.subAfter then
            placeRoleTail(deferred, prevBottom)
            prevBottom = deferred.spacer
            deferred   = nil
        end
    end

    -- Fallback: the subAfter target never appeared — reserve below the role dropdown.
    if deferred then placeRoleTail(deferred, deferred.dd) end
end

-- Reflows the generic Group Combat / Non-Combat columns for NS.groupSlot's current members.
-- Called from the Group tab whenever the managed class-set changes (GroupTab.lua).
NS.CB_RelayoutGroupContent = function()
    for _, col in ipairs(NS.groupLayoutChains or {}) do
        CB_RelayoutColumn(col, NS.groupSlot)
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
-- Exported for GroupTab.lua, which builds the same class content against a
-- per-class group slot so ClassData.lua changes reach both tabs for free.
NS.CB_BuildClassTabContent = CB_BuildClassTabContent

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

    -- Generic Group columns carry a reflow chain (single-bot / per-class columns don't).
    -- Register them so CB_RelayoutGroupContent can hide unsupported strategies per selection.
    if leftCol.__layoutChain or rightCol.__layoutChain then
        NS.groupLayoutChains = NS.groupLayoutChains or {}
        if leftCol.__layoutChain  then NS.groupLayoutChains[#NS.groupLayoutChains + 1] = leftCol  end
        if rightCol.__layoutChain then NS.groupLayoutChains[#NS.groupLayoutChains + 1] = rightCol end
    end
end
-- Exported for GroupTab.lua, which renders NS.STRATEGIES / NS.NC_STRATEGIES
-- against its group slot so Strategies.lua changes reach both tabs for free.
NS.CB_BuildTwoColumnContent = CB_BuildTwoColumnContent

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

    local commandsContent = CreateFrame("Frame", nil, container)
    commandsContent:SetPoint("TOPLEFT",     container, "TOPLEFT",     0, -NS.BOT_BAR_H)
    commandsContent:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    commandsContent.paddingLeft   = ctrl.paddingLeft
    commandsContent.paddingRight  = ctrl.paddingRight
    commandsContent.paddingTop    = ctrl.paddingTop
    commandsContent.paddingBottom = ctrl.paddingBottom

    local combatContent = CreateFrame("Frame", nil, container)
    combatContent:SetPoint("TOPLEFT",     container, "TOPLEFT",     0, -NS.BOT_BAR_H)
    combatContent:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    combatContent:Hide()
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
        commandsContent:Hide(); combatContent:Hide(); nonCombatContent:Hide(); classContent:Hide()
        if idx == 1 then
            commandsContent:Show()
        elseif idx == 2 then
            combatContent:Show()
        elseif idx == 3 then
            nonCombatContent:Show()
        else
            classContent:Show()
        end
    end

    local classDisplayName = (NS.CLASS_DISPLAY and NS.CLASS_DISPLAY[class]) or class
    for j, lbl in ipairs({ "Commands", "Combat", "Non-Combat", classDisplayName }) do
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

    -- Commands tab: the shared command set, scoped to THIS bot (whisper the open bot).
    -- The Formation dropdown reflects/optimistically caches this bot's formation.
    NS.CB_BuildPartyRaidCommands(commandsContent, tag,
        function(cmd)
            local e  = CleanBot_PartyBots[slot.key]
            local bn = (e and e.name) or slot.name
            if bn then NS.CB_SendBotCommand(bn, cmd) end
        end,
        function()
            local e  = CleanBot_PartyBots[slot.key]
            local bn = (e and e.name) or slot.name
            return (bn or "this bot") .. "'s"
        end,
        function() local e = CleanBot_PartyBots[slot.key]; return e and e.formation end,
        function(t) local e = CleanBot_PartyBots[slot.key]; if e then e.formation = t end end,
        function() local e = CleanBot_PartyBots[slot.key]; return e and e.combat and e.combat.passive end,
        function(b) local e = CleanBot_PartyBots[slot.key]; if e then e.combat = e.combat or {}; e.combat.passive = b end end)

    CB_BuildTwoColumnContent(combatContent,    NS.STRATEGIES,    "co", slot, tag, allFrames, function(e) return e and e.combat    end)
    CB_BuildTwoColumnContent(nonCombatContent, NS.NC_STRATEGIES, "nc", slot, tag, allFrames, function(e) return e and e.nonCombat end)

    -- Class tab.
    local classFrames = CB_BuildClassTabContent(classContent, class, slot, tag)
    for _, cf in ipairs(classFrames) do allFrames[#allFrames + 1] = cf end

    return {
        container      = container,
        selectInnerTab = selectInnerTab,
        innerTabs      = { commandsPanel = commandsContent, combatPanel = combatContent, nonCombatPanel = nonCombatContent, classPanel = classContent },
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
    if NS.CB_RefreshXPBar then NS.CB_RefreshXPBar(slot) end
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

    -- Fetch the bot's "stats" so the XP bar populates on both bridge and whisper
    -- paths (the bridge's INV_SUMMARY carries no XP). The reply repaints the bar
    -- via CB_RefreshXPBarForKey. Refresh now too so the level label shows instantly.
    -- Only fetch when the selection actually changes. At this point NS.selectedBotKey
    -- still holds the PREVIOUS selection (CleanBot_SelectTab updates it below), so a
    -- re-click of the active tab — and the post-login RefreshTabs burst that keeps
    -- re-selecting the same first bot — skip the whisper entirely. CB_FetchStats's
    -- in-flight + TTL guards make this an optimization rather than the sole protection.
    local entry = CleanBot_PartyBots[slot.key]
    if entry and NS.CB_FetchStats and slot.key ~= NS.selectedBotKey then
        NS.CB_FetchStats(entry)
    end
    if NS.CB_RefreshXPBar then NS.CB_RefreshXPBar(slot) end

    -- Surface this bot's current formation in the Commands tab: query it if unknown
    -- (reply repaints via CB_RefreshCommands) and repaint now so the cached value
    -- shows immediately on selection.
    if entry and NS.CB_FetchFormation then NS.CB_FetchFormation(entry) end
    if entry and NS.CB_FetchLootStrategy then NS.CB_FetchLootStrategy(entry) end
    if NS.CB_RefreshCommands then NS.CB_RefreshCommands() end

    NS.lruClock = NS.lruClock + 1
    slot.lru = NS.lruClock

    local idx
    for i, s in ipairs(NS.tabList) do if s == slot then idx = i; break end end
    NS.selectedTabIndex = 0   -- force SelectTab to re-apply (slots may have rebound)
    CleanBot_SelectTab(idx, silent)

    if NS.selectorMode == "dropdown" and NS.botDropdown then
        -- Match the open entries: class icon + class-colored name on the closed selector.
        local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[slot.class]
        local label = NS.CB_ClassIconMarkup(slot.class) .. " "
            .. (c and string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, slot.name) or slot.name)
        UIDropDownMenu_SetText(NS.botDropdown, label)
    end
end

-- Exposed for the unit-frame right-click menu (UnitMenu.lua).
NS.CB_SelectBot = SelectBot

-- ============================================================
-- NS.CB_ManageBot — opens the main window on the Individual tab focused on a
-- specific bot. Used by the party/raid right-click "Manage" entry.
-- ============================================================
--- @param key string  Bot name-key (strlower of the bot's name).
NS.CB_ManageBot = function(key)
    if not key then return end
    NS.selectedBotKey = key                 -- CleanBot_RefreshTabs selects this (step 4)
    CleanBotFrame:Show()
    if NS.CleanBot_RefreshTabs then NS.CleanBot_RefreshTabs() end
    NS.CleanBot_SelectTopTab(2)             -- 2 = "Individual" (tab order in CleanBot.lua)
    NS.CB_RequestRosterThenRefresh()        -- freshen the roster like a normal window open
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
    -- Include the player themselves when they are a live self-bot (driven by the server's
    -- "Enable/Disable player botAI" messages, applied via CB_SetSelfBotActive). The player
    -- is never yielded by CB_ForEachGroupMember, so this can't double-add. Works solo too.
    if NS.selfBotActive then
        local selfName = UnitName("player")
        if selfName and NS.CleanBot_IsBot("player") then
            local _, selfClass = UnitClass("player")
            table.insert(desired, { unit = "player", name = selfName, class = selfClass or "WARRIOR", key = strlower(selfName) })
        end
    end
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
        -- The Group tab swaps to its empty state on this exit too.
        if NS.CB_RefreshGroupTab then NS.CB_RefreshGroupTab() end
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
                    -- Class icon (inline markup) + name; colorCode tints the name only
                    -- (color codes don't affect the inline texture). Mirrors the Group
                    -- tab's class-colored, icon-on-left select-list rows.
                    info.text         = NS.CB_ClassIconMarkup(d.class) .. " " .. d.name
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

    -- ── 5. Mirror the roster change into the Group tab ──────────
    -- (group list contents, gray states, selected group's member set).
    if NS.CB_RefreshGroupTab then NS.CB_RefreshGroupTab() end
end

-- ============================================================
-- NS.CB_SyncRegistry — pushes an entry's state into one registry of built
-- strategy controls (the array CB_BuildColumnGroups appends to). Shared by
-- the Individual tab (real bot entries, groupCtx = nil — behavior identical
-- to the original per-bot sync) and the Group tab (aggregate entries whose
-- fields may hold NS.MIXED, plus the suffix maps in groupCtx).
--
-- groupCtx (Group tab only):
--   partial    field→true:   some-but-not-all members support the strategy → " (*)"
--   noneActive groupId→true: some member has nothing active in a noneLabel
--                             set → the noneLabel joins the dropdown display
-- ============================================================
---@param frames   table   Registry array (NS.botFrames[key] or a group registry).
---@param entry    table   Bot entry or group aggregate entry.
---@param groupCtx table?  { partial = table?, noneActive = table? }; nil on the Individual path.
NS.CB_SyncRegistry = function(frames, entry, groupCtx)
    local partial    = groupCtx and groupCtx.partial    or nil
    local noneActive = groupCtx and groupCtx.noneActive or nil

    -- " (*)" when the group only partially supports this field.
    ---@param f string  Strategy field name.
    ---@return string   The suffix, or "".
    local function starSuffix(f)
        return (partial and partial[f]) and " (*)" or ""
    end

    local function syncControls(controls, stratList, source)
        if not controls or not source then return end
        for _, s in ipairs(stratList) do
            local ctrl = controls[s.field]
            if not ctrl then
            elseif s.type == "timerSlider" then
                -- SetValueSilent: sync must never fire the slider's onChange,
                -- which would echo the value back as a command (fatal for a
                -- group slot — the default would fan out to every member).
                local val  = source[s.field]
                local star = starSuffix(s.field)
                if val == NS.MIXED then
                    ctrl:SetValueSilent(s.default or s.min or 0, "???" .. star)
                else
                    local v = val or s.min or 0
                    ctrl:SetValueSilent(v, star ~= "" and (math.floor(v + 0.5) .. star) or nil)
                end
                if s.dependsOn then
                    -- NS.MIXED is truthy on purpose: a half-checked controller
                    -- still leaves the timer settable for the whole group.
                    local enabled = source[s.dependsOn] and true or false
                    if enabled then ctrl:Enable() else ctrl:Disable() end
                end
            else
                local v = source[s.field]
                ctrl:SetChecked(v == true)
                if ctrl.labelFS then
                    ctrl.labelFS:SetText(ctrl.labelBase
                        .. (v == NS.MIXED and " (?)" or "")
                        .. starSuffix(s.field))
                end
            end
        end
    end

    -- Sets the dropdown text and returns (settledField, shownCount).
    -- Display list, in strategies order: every field that is set (true) or
    -- contested (NS.MIXED) contributes its name + " (*)" suffix; the
    -- noneLabel leads the list when noneActive flags this group (a member
    -- sits at none). Multiple entries comma-join ("Tank, DPS (Single)");
    -- exactly one uniformly-true entry renders classically and is returned
    -- as settledField for the role sub-section logic.
    local function syncDropdown(dd, stratList, source, noneLabel, groupId)
        if not dd or not source then return nil, 0 end
        local names       = {}
        local activeField = nil
        local trueCount   = 0
        if noneLabel and noneActive and groupId and noneActive[groupId] then
            names[#names + 1] = noneLabel
        end
        for _, s in ipairs(stratList) do
            local v = source[s.field]
            if v == true or v == NS.MIXED then
                names[#names + 1] = s.name .. starSuffix(s.field)
                if v == true then
                    trueCount   = trueCount + 1
                    activeField = s.field
                end
            end
        end
        UIDropDownMenu_SetText(dd, table.concat(names, ", "))
        if #names == 1 and trueCount == 1 then
            return activeField, 1
        end
        return nil, #names
    end

    for _, cf in ipairs(frames) do
        local cd = cf.getSource and cf.getSource(entry)
        if cf.type == "dropdown" then
            local _, shown = syncDropdown(cf.dd, cf.strategies, cd, cf.noneLabel, cf.groupId)
            if shown == 0 and cf.noneLabel then
                UIDropDownMenu_SetText(cf.dd, cf.noneLabel)
            end

        elseif cf.type == "checkboxes" then
            syncControls(cf.checkboxes, cf.strategies, cd)

        elseif cf.type == "roleDropdown" then
            local activeRole, shown = syncDropdown(cf.dd, cf.strategies, cd, cf.noneLabel, cf.groupId)
            if shown == 0 and cf.noneLabel then
                UIDropDownMenu_SetText(cf.dd, cf.noneLabel)
            end
            -- Exactly one settled rotation token → that role's section. No token (shown 0 on the
            -- Individual path, or 1 noneLabel for an all-DPS group) → the none/DPS section.
            -- shown > 1 (genuinely mixed roles across a group) → hide all (ambiguous).
            local activeSection
            if activeRole then activeSection = cf.roleToSection[activeRole]
            elseif shown <= 1 then activeSection = cf.noneSection end
            for _, sub in pairs(cf.subSections) do
                if sub == activeSection then sub.section:Show() else sub.section:Hide() end
                syncControls(sub.checkboxes, sub.strategies, cd)
            end
        end
    end
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

    -- Group hook BEFORE the botFrames guard: a member that isn't bound to an
    -- Individual slot must still refresh the Group tab's aggregate view.
    if NS.CB_OnMemberDataChanged then NS.CB_OnMemberDataChanged(key) end

    -- Repaint the Commands-tab controls (e.g. the Passive checkbox reads entry.combat.passive,
    -- which a co? reply just updated). Also before the guard so the Group host's aggregate
    -- reflects members not bound to an Individual slot.
    if NS.CB_RefreshCommands then NS.CB_RefreshCommands() end

    local frames = NS.botFrames[key]
    if not frames then return end

    NS.CB_SyncRegistry(frames, entry, nil)
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
