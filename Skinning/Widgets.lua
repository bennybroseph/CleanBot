-- ============================================================
-- Skinning\Widgets.lua  —  generic skinned widget factories.
--
-- Each factory creates a widget, applies the ElvUI skin, and stamps
-- NS.MARGIN values onto the returned frame so CB_AnchorBelow can
-- compute gaps automatically. Also owns the global edit-box focus
-- clearing hooks at the bottom of the file.
-- ============================================================
local NS = CleanBotNS

-- Native Blizzard +/− circle button art, shared by the standalone collapse button
-- and the Manage-tab section toggle. No FrameXML template exists for these (Blizzard's
-- own quest/reputation/skill headers set the same textures inline), so both call sites
-- route through CB_SetCollapseTexture instead of duplicating the paths.
local COLLAPSE_MINUS_UP = "Interface\\Buttons\\UI-MinusButton-Up"
local COLLAPSE_MINUS_DN = "Interface\\Buttons\\UI-MinusButton-Down"
local COLLAPSE_PLUS_UP  = "Interface\\Buttons\\UI-PlusButton-Up"
local COLLAPSE_PLUS_DN  = "Interface\\Buttons\\UI-PlusButton-Down"
local COLLAPSE_PLUS_HL  = "Interface\\Buttons\\UI-PlusButton-Hilight"

--- Sets a button's normal/pushed textures to the + (collapsed) or − (expanded) art.
---@param btn       table    The button to texture.
---@param collapsed boolean  true → plus (collapsed), false → minus (expanded).
local function CB_SetCollapseTexture(btn, collapsed)
    if collapsed then
        btn:SetNormalTexture(COLLAPSE_PLUS_UP) ; btn:SetPushedTexture(COLLAPSE_PLUS_DN)
    else
        btn:SetNormalTexture(COLLAPSE_MINUS_UP) ; btn:SetPushedTexture(COLLAPSE_MINUS_DN)
    end
end

-- FontString label. fontObj defaults to "GameFontNormal".
---@param parent  table    Parent frame to create the FontString inside.
---@param text    string?  Optional initial label text.
---@param fontObj string?  Optional font object name (default "GameFontNormal").
---@return table            The created FontString with margins stamped.
NS.CB_CreateLabel = function(parent, text, fontObj)
    local lbl = parent:CreateFontString(nil, "OVERLAY", fontObj or "GameFontNormal")
    if text then lbl:SetText(text) end
    lbl.marginTop    = NS.MARGIN.label.top
    lbl.marginBottom = NS.MARGIN.label.bottom
    lbl.marginLeft   = NS.MARGIN.label.left
    lbl.marginRight  = NS.MARGIN.label.right
    return lbl
end

-- FontString section header. Larger than a label (GameFontNormalLarge) with
-- wider top/bottom margins so it reads as a visual section break.
-- fontObj can override the font object if desired.
---@param parent  table    Parent frame to create the FontString inside.
---@param text    string?  Optional initial header text.
---@param fontObj string?  Optional font object name (default "GameFontNormalLarge").
---@return table            The created FontString with margins stamped.
NS.CB_CreateHeader = function(parent, text, fontObj)
    local hdr = parent:CreateFontString(nil, "OVERLAY", fontObj or "GameFontNormalLarge")
    if text then hdr:SetText(text) end
    hdr.marginTop    = NS.MARGIN.header.top
    hdr.marginBottom = NS.MARGIN.header.bottom
    hdr.marginLeft   = NS.MARGIN.header.left
    hdr.marginRight  = NS.MARGIN.header.right
    return hdr
end

-- Creates a standalone collapse/expand button using the native Blizzard +/−
-- circle textures. ElvUI is applied via HandleCollapseExpandButton when present.
-- Size defaults to 16×16 to match the quest list header row height.
---@param parent      table   Parent frame.
---@param isCollapsed boolean Initial collapsed state (drives + vs − texture).
---@return table              The created Button.
NS.CB_CreateCollapseButton = function(parent, isCollapsed)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(16, 16)
    CB_SetCollapseTexture(btn, isCollapsed)
    btn:SetHighlightTexture(COLLAPSE_PLUS_HL, "ADD")

    if NS.ElvUI_S then
        NS.ElvUI_S:HandleCollapseExpandButton(btn, isCollapsed and "+" or "-")
    end

    return btn
end

-- Creates a collapsible section for the Manage tab.
--
-- The toggle button and title label are children of parent (scroll child, MEDIUM
-- strata). The visual bg frame is also a child of parent but forced to BACKGROUND
-- strata so it renders behind everything else.
--
-- IMPORTANT: In WoW 3.3.5a child frames INHERIT their parent's strata. section.bg
-- defaults to MEDIUM (no explicit SetFrameStrata call), so content widgets parented
-- to it are also MEDIUM and remain mouse-interactive. Do NOT call SetFrameStrata on bg.
--
-- section.frame starts as the toggle button. Call section:Finalize(lastWidget)
-- once all content widgets are added; this sets section.frame to lastWidget so
-- the next section can chain its CB_AnchorBelow off the correct anchor point.
--
-- Content widgets are children of bg and hide/show automatically with it — no
-- manual contentWidgets registration needed.
--
-- Collapsed state is persisted in CleanBot_SavedVars.collapsedSections[key].
-- parent must have paddingRight stamped (via CB_CreatePanel) so Apply() can compute
-- the section background's right edge without guessing the parent's role.
---@param parent    table   Parent scroll child (must have padding fields stamped).
---@param key       string  Unique key for persistence and frame naming.
---@param title     string  Section header label text.
---@param nestLevel number? Nesting depth for the bg panel (default 3).
---@return table            A section table with Apply/Toggle/Finalize/UpdateBackground/GetAnchor.
NS.CB_CreateSection = function(parent, key, title, nestLevel)
    local section = {}

    -- Toggle button using the native Blizzard gold +/- circle textures — the same
    -- art used by the Reputation, Skills, TradeSkill, and Trainer panels since vanilla.
    local toggleBtn = CreateFrame("Button", "CleanBotSection_" .. key .. "_Toggle", parent)
    toggleBtn:SetSize(14, 14)

    CB_SetCollapseTexture(toggleBtn, false)  -- start expanded (−)
    toggleBtn:SetHighlightTexture(COLLAPSE_PLUS_HL, "ADD")

    -- ElvUI hooks SetNormalTexture internally to swap in its own Plus/Minus textures,
    -- so our SetText override (which calls SetNormalTexture) still drives the state.
    if NS.ElvUI_S then NS.ElvUI_S:HandleCollapseExpandButton(toggleBtn, "-") end

    -- Swap between + (collapsed) and − (expanded) by swapping normal/pushed textures.
    toggleBtn.SetText = function(self, text)
        CB_SetCollapseTexture(self, text == "+")
    end

    -- Title label: FontString on parent, to the right of the toggle button.
    local titleLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleLabel:SetText(title)
    titleLabel:SetPoint("LEFT", toggleBtn, "RIGHT", 4, 0)

    -- Load saved collapse state.
    local saved = CleanBot_SavedVars and CleanBot_SavedVars.collapsedSections
    section.collapsed  = saved and saved[key] == true or false
    section.key        = key
    section.toggleBtn  = toggleBtn   -- always the section header; never hidden
    section.lastWidget = nil         -- set by Finalize; deepest content widget
    section.frame      = toggleBtn   -- updated to lastWidget in Finalize
    section.onToggle   = nil         -- optional callback fired after each toggle

    -- Returns the bottommost currently-visible widget for this section.
    -- Collapsed → header toggle button only; expanded → last content widget.
    -- Falls back to toggleBtn if Finalize has not been called yet.
    section.GetAnchor = function(self)
        return self.collapsed and self.toggleBtn or (self.lastWidget or self.toggleBtn)
    end

    -- Shared width calculation used by both Apply and the OnSizeChanged hook.
    local function calcBgWidth()
        local mar        = NS.MARGIN.section
        local rightInset = (parent.paddingRight or 0) + mar.right
        local pw         = parent:GetWidth()
        return math.max(pw > 0 and (pw - (parent.paddingLeft or 0) - (toggleBtn.marginLeft or 0) - rightInset) or 200, 1)
    end

    section.Apply = function(self)
        -- Content widgets are children of bg and hide/show automatically with it.
        if self.collapsed then
            self.bg:Hide()
        else
            local mar    = NS.MARGIN.section
            local topGap = (toggleBtn.marginBottom or 0) + mar.top
            -- Anchor TOPLEFT to toggleBtn BOTTOMLEFT so bg tracks the toggle when
            -- reflow moves it. toggleBtn is already at panel.left from the panel wall,
            -- so only the section margin delta is needed as an X offset — not leftX
            -- (which would double-count the panel padding).
            self.bg:ClearAllPoints()
            self.bg:SetPoint("TOPLEFT", toggleBtn, "BOTTOMLEFT",
                mar.left - (toggleBtn.marginLeft or 0), -topGap)
            self.bg:SetWidth(calcBgWidth())
            self.bg:SetHeight(2000)  -- corrected by UpdateBackground after first render
            self.bg:Show()
        end
        toggleBtn:SetText(self.collapsed and "+" or "-")
    end

    -- Re-sync bg width whenever the parent (scroll child) changes size — e.g. when
    -- the frame collapses or expands on tab switch. Only updates width; height is
    -- managed separately by UpdateBackground to avoid resetting the 2000px placeholder.
    parent:HookScript("OnSizeChanged", function()
        if not section.collapsed and section.bg:IsShown() then
            section.bg:SetWidth(calcBgWidth())
        end
    end)

    section.Toggle = function(self)
        self.collapsed = not self.collapsed
        if CleanBot_SavedVars then
            if not CleanBot_SavedVars.collapsedSections then
                CleanBot_SavedVars.collapsedSections = {}
            end
            CleanBot_SavedVars.collapsedSections[self.key] = self.collapsed or nil
        end
        self:Apply()
        -- Fire after Apply so GetAnchor already reflects the new state.
        if self.onToggle then self.onToggle() end
    end

    -- Call once all content widgets have been added and registered.
    -- lastWidget: the bottommost content widget in the section.
    -- Sets section.frame / section.lastWidget so GetAnchor and the next
    -- section's anchor both resolve correctly.
    section.Finalize = function(self, lastWidget)
        self.lastWidget = lastWidget
        self.frame      = lastWidget
        self:Apply()
    end

    toggleBtn:SetScript("OnClick", function() section:Toggle() end)

    -- Match label margins so CB_AnchorBelow spacing is consistent with the
    -- old plain-label style that sections replace.
    toggleBtn.marginTop    = NS.MARGIN.label.top
    toggleBtn.marginBottom = NS.MARGIN.label.bottom
    toggleBtn.marginLeft   = NS.MARGIN.label.left
    toggleBtn.marginRight  = NS.MARGIN.label.right

    -- Visual background frame. Stays at MEDIUM strata (default) so that child
    -- content widgets inherit MEDIUM and remain mouse-interactive. WoW 3.3.5a
    -- renders same-strata same-level frames in creation order, so subsequent
    -- sections' toggle buttons (created later) always render on top of this bg
    -- even during the height=2000 expansion phase.
    -- Hidden until Apply() shows it on first expand.
    local bg = NS.CB_CreatePanel(parent, "CleanBotSection_" .. key .. "_BG", nestLevel or 3, "section")
    bg:Hide()
    section.bg = bg

    -- Corrects the bg height to exactly wrap the section's content area.
    -- Apply() already positions and shows bg (anchored to toggleBtn BOTTOMLEFT)
    -- with a generous temporary height. This trims it to fit once layout resolves.
    -- lastWidget:GetBottom() is valid here because bg is positioned and its
    -- children (content widgets) therefore have real screen coordinates.
    section.UpdateBackground = function(self)
        if self.collapsed or not self.lastWidget then
            self.bg:Hide()
            return
        end
        local bgTop  = self.bg:GetTop()
        local lastBt = self.lastWidget:GetBottom()
        if not (bgTop and lastBt) then return end
        local botGap = (self.lastWidget.marginBottom or 0) + (self.bg.paddingBottom or 0)
        self.bg:SetHeight(math.max(bgTop - lastBt + botGap, 4))
    end

    return section
end

-- Inline-texture escape ("|T...|t") for embedding an icon inside any FontString
-- (dropdown entries, the collapsed dropdown value, labels, tab text). The icon
-- renders to the left of whatever text follows it, with no anchor work, in both
-- ElvUI and Blizzard skins. `coords` are the 0-1 texcoord fractions
-- {left,right,top,bottom}; converted to the texel units the escape expects using
-- `texDim` (the source texture's pixel size). 3.3.5a's own FrameXML uses this
-- extended form (e.g. LFGFrame.lua role icons).
---@param path   string  Texture path.
---@param size   number  Rendered icon size in pixels (square).
---@param coords table   {left,right,top,bottom} in 0-1.
---@param texDim number? Source texture pixel size for texel conversion (default 256).
---@param yOff   number? Vertical pixel offset for baseline tuning (default 0).
---@return string        The "|T...|t" escape string.
NS.CB_InlineIcon = function(path, size, coords, texDim, yOff)
    texDim = texDim or 256
    return string.format("|T%s:%d:%d:0:%d:%d:%d:%d:%d:%d:%d|t",
        path, size, size, yOff or 0, texDim, texDim,
        coords[1] * texDim, coords[2] * texDim, coords[3] * texDim, coords[4] * texDim)
end

-- A bordered, scrollable list of selectable rows.
--
-- Items are plain strings, or tables for decorated rows:
--   { text = "Label", value = "key", class = "WARRIOR"|nil, grey = boolean|nil }
-- class colors the label (RAID_CLASS_COLORS) and shows the class icon;
-- grey renders the label 50% grey with no icon (e.g. a bot missing from the
-- party/raid). String rows keep the template's default look.
--
-- Returns a container frame with the following API:
--   container:SetItems(items)           — populates rows; clears any previous selection.
--   container:GetSelected()             — returns the currently selected item (string or
--                                         table), or nil if nothing is selected.
--   container:SetSelectedValue(value)   — programmatic selection by row value; no onSelect.
-- Multi-select mode (multiSelect = true) adds:
--   container:GetSelectedValues()       — array of selected row values, in items order.
--   container:SetSelectedValues(list)   — programmatic multi-selection; no callback.
--   container:SelectAllValues()         — select every row; no callback.
--
-- onSelect(value) fires on a single-select click (item.value, falling back to text).
-- In multi-select mode it is the SELECTION-CHANGED handler: it fires (no argument
-- needed — read GetSelectedValues) on user clicks and empty-area clicks, with
-- Windows-style modifiers (plain = that row only, Ctrl = toggle, Shift = range).
-- width / height size the visible container; rows scroll inside it.
-- ElvUI skins the inner scroll bar when present.
---@param parent     table     Parent frame.
---@param name       string    Global name; sub-frames derive from it (name.."SF", etc.).
---@param width      number    Content area width (container is width + 20 for the scrollbar).
---@param height     number    Visible container height.
---@param onSelect   fun(value:string?)? Click handler (single) / selection-changed (multi).
---@param multiSelect boolean? Enable Windows-style multi-selection.
---@return table               The container frame with the list API.
NS.CB_CreateSelectList = function(parent, name, width, height, onSelect, multiSelect)
    local ROW_H      = 20
    -- Number of physical row buttons that fit; scrolling remaps these onto the data
    -- rather than creating a button per item.
    local numVisible = math.max(1, math.floor((height - 4) / ROW_H))

    -- Outer bordered container. CB_ApplyInnerSkin gives it the panel-inset look
    -- without registering it for theme-refresh (the list colour is fixed art).
    local container = CreateFrame("Frame", name, parent)
    -- width is the content area; add 20px (2px left inset + 18px scrollbar) for the container.
    container:SetSize(width + 20, height)
    NS.CB_ApplyInnerSkin(container)

    -- Backing data and selection. selectedIndex is an ABSOLUTE index into `items`
    -- so the highlighted entry survives scrolling and row recycling. In multi mode
    -- selection is a value-keyed set (survives SetItems/refresh like SetSelectedValue),
    -- with anchorIndex marking the Shift-range origin.
    local items         = {}
    local selectedIndex = nil
    local selectedSet   = {}    -- multi mode: [value] = true
    local anchorIndex   = nil   -- multi mode: Shift-range anchor (absolute index)

    -- FauxScrollFrame inset 2px from the container walls; 20px right gap keeps the
    -- scrollbar (18px) plus a 2px mirror of the left inset inside the container border.
    local sf = CreateFrame("ScrollFrame", name .. "SF", container, "FauxScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     container, "TOPLEFT",      2,  -2)
    sf:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -20,  2)

    -- Re-anchor the scrollbar explicitly so it sits inside the container's right
    -- zone rather than floating to the right of the scroll frame (template default).
    local scrollBar = _G[name .. "SFScrollBar"]
    if scrollBar then
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOPLEFT",    container, "TOPRIGHT",    -20, -20)
        scrollBar:SetPoint("BOTTOMLEFT", container, "BOTTOMRIGHT", -20,  20)
        if NS.ElvUI_S then NS.ElvUI_S:HandleScrollBar(scrollBar) end
    end

    local rows = {}

    -- The clickable value of an item: item.value (fallback item.text) for
    -- table items, the string itself otherwise.
    ---@param item string|table  A list item.
    ---@return string            The value onSelect/SetSelectedValue match on.
    local function itemValue(item)
        if type(item) == "table" then return item.value or item.text end
        return item
    end

    -- Re-maps the fixed row pool onto items[offset+1 .. offset+numVisible] and
    -- refreshes the FauxScrollFrame's scrollbar range. Rows are recycled, so
    -- every visual attribute (color, icon, label anchor) is reset on each pass
    -- — a row that held a class-colored table item must not bleed its look
    -- into the plain string item that lands on it next.
    local function refresh()
        local offset = FauxScrollFrame_GetOffset(sf)
        for i = 1, numVisible do
            local row     = rows[i]
            local dataIdx = i + offset
            local item    = items[dataIdx]
            if item then
                local isTable = type(item) == "table"
                row.index = dataIdx
                row.value = itemValue(item)
                row.label:SetText(isTable and item.text or item)

                -- Class icon only for class-decorated, present (non-grey) rows.
                local showIcon = isTable and item.class and not item.grey
                if showIcon then
                    local coords = NS.CLASS_ICON_COORDS and NS.CLASS_ICON_COORDS[item.class]
                    if coords then row.icon:SetTexCoord(unpack(coords)) end
                    row.icon:Show()
                else
                    row.icon:Hide()
                end
                row.label:ClearAllPoints()
                if showIcon then
                    row.label:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
                else
                    row.label:SetPoint("LEFT", row, "LEFT", 4, 0)
                end

                local classColor = isTable and item.class and RAID_CLASS_COLORS
                                   and RAID_CLASS_COLORS[item.class]
                if isTable and item.grey then
                    row.label:SetTextColor(0.5, 0.5, 0.5)
                elseif classColor then
                    row.label:SetTextColor(classColor.r, classColor.g, classColor.b)
                else
                    row.label:SetTextColor(row.defR, row.defG, row.defB)
                end

                local on = multiSelect and selectedSet[row.value] or (not multiSelect and dataIdx == selectedIndex)
                row.hl:SetAlpha(on and 0.4 or 0)
                row:Show()
            else
                row.index = nil
                row.value = nil
                row:Hide()
            end
        end
        FauxScrollFrame_Update(sf, #items, numVisible, ROW_H)
    end

    -- Fixed pool of row buttons at static offsets over the scroll area. They are
    -- parented to `container`, NOT to `sf`: FauxScrollFrame_Update calls sf:Hide()
    -- whenever the items fit without scrolling, which would also hide any rows
    -- parented to sf. Anchoring to sf (cross-frame) still positions them correctly.
    for i = 1, numVisible do
        local row = CreateFrame("Button", nil, container)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT",  sf, "TOPLEFT",  0, -(i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", sf, "TOPRIGHT", 0, -(i - 1) * ROW_H)

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.label = lbl
        -- Snapshot the template's text color so refresh() can reset a recycled
        -- row after a class-colored or greyed table item occupied it.
        row.defR, row.defG, row.defB = lbl:GetTextColor()

        -- Class icon for decorated table items; hidden for plain string rows.
        local icn = row:CreateTexture(nil, "ARTWORK")
        icn:SetSize(14, 14)
        icn:SetPoint("LEFT", row, "LEFT", 4, 0)
        icn:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
        icn:Hide()
        row.icon = icn

        -- Highlight texture shown at reduced alpha when the row is selected.
        local hl = row:CreateTexture(nil, "BACKGROUND")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0)
        row.hl = hl

        row:SetScript("OnClick", function(self)
            if not self.index then return end
            if multiSelect then
                if IsShiftKeyDown() and anchorIndex then
                    -- Range select anchorIndex..index (replace selection).
                    selectedSet = {}
                    local lo, hi = anchorIndex, self.index
                    if lo > hi then lo, hi = hi, lo end
                    for j = lo, hi do
                        local it = items[j]
                        if it then selectedSet[itemValue(it)] = true end
                    end
                elseif IsControlKeyDown() then
                    -- Toggle this row.
                    if selectedSet[self.value] then selectedSet[self.value] = nil
                    else selectedSet[self.value] = true end
                    anchorIndex = self.index
                else
                    -- Plain click: this row only.
                    selectedSet = { [self.value] = true }
                    anchorIndex = self.index
                end
                refresh()
                if onSelect then onSelect() end
            else
                selectedIndex = self.index
                refresh()
                if onSelect then onSelect(self.value) end
            end
        end)

        row:Hide()
        rows[i] = row
    end

    -- Multi-select: a click on empty list space (not on a visible row — hidden
    -- rows don't consume clicks) clears the whole selection. Attached to both the
    -- container and the scroll frame so it fires wherever the empty click lands.
    if multiSelect then
        local function clearSelection()
            if not next(selectedSet) then return end
            selectedSet = {}
            anchorIndex = nil
            refresh()
            if onSelect then onSelect() end
        end
        container:EnableMouse(true)
        container:HookScript("OnMouseUp", clearSelection)
        sf:EnableMouse(true)
        sf:SetScript("OnMouseUp", clearSelection)
    end

    -- Scrolling the bar (drag, wheel, or step buttons) re-maps the visible rows.
    sf:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, refresh)
    end)
    -- Wheel handling lives on `container`: the rows (and sf, when it hides itself for
    -- short lists) may not be under the cursor, but the container always is.
    container:EnableMouseWheel(true)
    container:SetScript("OnMouseWheel", function(_, delta)
        if scrollBar then scrollBar:SetValue(scrollBar:GetValue() - delta * ROW_H) end
    end)

    container.SetItems = function(self, newItems)
        items         = newItems or {}
        selectedIndex = nil
        selectedSet   = {}
        anchorIndex   = nil
        sf.offset = 0
        if scrollBar then scrollBar:SetValue(0) end
        refresh()
    end

    container.GetSelected = function(self)
        return selectedIndex and items[selectedIndex] or nil
    end

    -- Programmatic selection by row value — restores a selection across the
    -- SetItems rebuilds that roster refreshes trigger. Does NOT fire onSelect;
    -- callers invoke their own handler explicitly when needed.
    ---@param value string?  The row value to select; nil clears the selection.
    ---@return boolean       True when a matching item was found and selected.
    container.SetSelectedValue = function(self, value)
        selectedIndex = nil
        if value ~= nil then
            for i, item in ipairs(items) do
                if itemValue(item) == value then
                    selectedIndex = i
                    break
                end
            end
        end
        refresh()
        return selectedIndex ~= nil
    end

    -- ── Multi-select API ──────────────────────────────────────
    -- Selected row values, in items order (stable for display).
    ---@return table  Array of selected values.
    container.GetSelectedValues = function(self)
        local out = {}
        for _, item in ipairs(items) do
            local v = itemValue(item)
            if selectedSet[v] then out[#out + 1] = v end
        end
        return out
    end

    -- Programmatic multi-selection by value (values absent from items are ignored
    -- at highlight time). Does NOT fire the callback.
    ---@param values table?  Array of values to select; nil/empty clears.
    container.SetSelectedValues = function(self, values)
        selectedSet = {}
        anchorIndex = nil
        if values then
            for _, v in ipairs(values) do selectedSet[v] = true end
        end
        refresh()
    end

    -- Selects every current row. Does NOT fire the callback.
    container.SelectAllValues = function(self)
        selectedSet = {}
        for _, item in ipairs(items) do selectedSet[itemValue(item)] = true end
        anchorIndex = nil
        refresh()
    end

    container.marginTop    = NS.MARGIN.button.top
    container.marginBottom = NS.MARGIN.button.bottom
    container.marginLeft   = NS.MARGIN.button.left
    container.marginRight  = NS.MARGIN.button.right

    return container
end

-- UIPanelButtonTemplate button. w/h, text and onClick are optional.
---@param parent  table    Parent frame.
---@param name    string?  Optional global frame name.
---@param text    string?  Button label.
---@param w       number?  Width (set only when both w and h given).
---@param h       number?  Height.
---@param onClick fun()?   Click handler.
---@return table           The created Button with margins stamped.
NS.CB_CreateButton = function(parent, name, text, w, h, onClick)
    local btn = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    if w and h then btn:SetSize(w, h) end
    if text then btn:SetText(text) end
    if onClick then btn:SetScript("OnClick", onClick) end
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(btn) end
    btn.marginTop    = NS.MARGIN.button.top
    btn.marginBottom = NS.MARGIN.button.bottom
    btn.marginLeft   = NS.MARGIN.button.left
    btn.marginRight  = NS.MARGIN.button.right
    return btn
end

-- UIDropDownMenuTemplate dropdown. When width is given the dropdown
-- is sized and the ElvUI skin is sized to match.
---@param parent table    Parent frame.
---@param name   string   Global frame name; sub-frames derive from it (name.."Button"/"Text").
---@param width  number?  Dropdown width.
---@return table          The created dropdown Frame with margins stamped.
NS.CB_CreateDropdown = function(parent, name, width)
    local dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    if width then UIDropDownMenu_SetWidth(dd, width) end
    if NS.ElvUI_S then
        NS.ElvUI_S:HandleDropDownBox(dd, width)

        -- ElvUI's HandleDropDownBox builds a `.backdrop` child frame and parks it at
        -- dd's OWN frame level. A same-level child renders above dd's button + text,
        -- so the arrow and label get obscured when the dropdown is nested in a
        -- ScrollFrame (the same root cause documented on CB_SkinEditBoxSafe). Rather
        -- than fight frame levels, reparent the button and text onto dd.backdrop so
        -- they render above it; this also mirrors ElvUI's own Ace3 dropdown skin.
        local backdrop = dd.backdrop
        if backdrop then
            local btn  = _G[name .. "Button"]
            local text = _G[name .. "Text"]

            -- HandleDropDownBox anchors backdrop BOTTOMRIGHT to the button, which
            -- creates a circular dependency when we then try to anchor the button to
            -- the backdrop. Re-anchor backdrop to dd directly first to break the cycle.
            backdrop:ClearAllPoints()
            backdrop:SetPoint("TOPLEFT",     dd, "TOPLEFT",     20,  0)
            backdrop:SetPoint("BOTTOMRIGHT", dd, "BOTTOMRIGHT", -8,  8)

            if btn then
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT",     backdrop, "TOPRIGHT",    -22, -2)
                btn:SetPoint("BOTTOMRIGHT", backdrop, "BOTTOMRIGHT",  -2,  2)
                btn:SetParent(backdrop)
                -- After reparenting, self:GetParent() is the unnamed backdrop frame,
                -- breaking UIDropDownMenu's name-based lookup. Reference dd directly.
                btn:SetScript("OnClick", function()
                    ToggleDropDownMenu(1, nil, dd)
                end)
            end

            if text then
                text:ClearAllPoints()
                text:SetJustifyH("RIGHT")
                text:SetPoint("RIGHT", btn,      "LEFT",  -3, 0)
                text:SetPoint("LEFT",  backdrop, "LEFT",   2, 0)
                text:SetParent(backdrop)
            end
        end
    end
    dd.marginTop    = NS.MARGIN.dropdown.top
    dd.marginBottom = NS.MARGIN.dropdown.bottom
    dd.marginLeft   = NS.MARGIN.dropdown.left
    dd.marginRight  = NS.MARGIN.dropdown.right
    return dd
end

-- UICheckButtonTemplate check button.
---@param parent table   Parent frame.
---@param name   string? Optional global frame name.
---@return table         The created CheckButton with margins stamped.
NS.CB_CreateCheckBox = function(parent, name)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    if NS.ElvUI_S then NS.ElvUI_S:HandleCheckBox(cb) end
    cb.marginTop    = NS.MARGIN.checkbox.top
    cb.marginBottom = NS.MARGIN.checkbox.bottom
    cb.marginLeft   = NS.MARGIN.checkbox.left
    cb.marginRight  = NS.MARGIN.checkbox.right
    return cb
end

-- Tab button built on UIPanelButtonTemplate, with the active/inactive state layered
-- on top. The native TabButtonTemplate was tried but ElvUI's HandleTab insets its
-- backdrop 10px per side (tuned for full-size frame tabs), which renders this addon's
-- compact NS.TAB_WIDTH (88px) tabs far too small — so the button template + HandleButton
-- gives a correctly-sized, ElvUI-consistent result instead.
-- Exposes tab:SetActive(bool) so call sites do not need to manage font objects or states.
---@param parent  table    Parent frame.
---@param name    string?  Optional global frame name.
---@param text    string?  Tab label.
---@param onClick fun()?   Click handler.
---@return table           The created Button with a SetActive(bool) method.
NS.CB_CreateTab = function(parent, name, text, onClick)
    local tab = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    tab:SetSize(NS.TAB_WIDTH, NS.TAB_HEIGHT)
    if text    then tab:SetText(text)                   end
    if onClick then tab:SetScript("OnClick", onClick)   end
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(tab)     end

    -- Unified active/inactive toggle.
    tab.SetActive = function(self, active)
        if active then
            self:SetNormalFontObject(GameFontHighlightSmall)
            self:SetButtonState("PUSHED", true)
        else
            self:SetNormalFontObject(GameFontNormalSmall)
            self:SetButtonState("NORMAL", false)
        end
    end

    tab.marginTop    = NS.MARGIN.tab.top
    tab.marginBottom = NS.MARGIN.tab.bottom
    tab.marginLeft   = NS.MARGIN.tab.left
    tab.marginRight  = NS.MARGIN.tab.right
    tab:SetActive(false)  -- start inactive
    return tab
end

-- Applies an ElvUI-matching skin to an EditBox by calling SetBackdrop directly on
-- the box, deliberately NOT using ElvUI's HandleEditBox.
--
-- Why not HandleEditBox: it builds a separate `.backdrop` child frame. A child frame
-- renders above its parent's text unless its frame level is explicitly lower, and a
-- fixed level − 1 offset is NOT enough for editboxes nested several frames deep — the
-- slider value boxes inside the Settings (Theme/Layout) scroll render visually blank
-- because the backdrop ends up behind the panel. (Verified by testing: HandleEditBox
-- is fine for shallow editboxes but blanks the nested slider boxes.) SetBackdrop on
-- the box itself has no child frame, so there is no level-stacking fragility at any
-- nesting depth.
-- No-op when ElvUI is absent (InputBoxTemplate provides its own look).
---@param box table  The EditBox to skin.
NS.CB_SkinEditBoxSafe = function(box)
    if not NS.ElvUI_S then return end
    local E   = NS.ElvUI_E
    -- Use ElvUI's own blank texture when available so the fill is pure white and
    -- can be tinted accurately; fall back to a reliable Blizzard solid texture.
    local tex = (E and E.media and E.media.blank) or "Interface\\ChatFrame\\ChatFrameBackground"
    local bc  = (E and E.db and E.db.general and E.db.general.bordercolor) or {}
    -- Hide only Texture regions to remove InputBoxTemplate's default art.
    -- GetRegions() returns Textures and FontStrings but never child Frames, so this
    -- is safe for input handling. We filter to Texture only so the EditBox's text
    -- FontString stays visible. StripTextures is avoided entirely — ElvUI's version
    -- also iterates child frames and hides something InputBoxTemplate needs for focus.
    for _, region in pairs({box:GetRegions()}) do
        if region:GetObjectType() == "Texture" then
            region:Hide()
        end
    end
    box:SetBackdrop({
        bgFile   = tex,
        edgeFile = tex,
        tile     = false,
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    box:SetBackdropColor(0.06, 0.06, 0.06, 1)
    box:SetBackdropBorderColor(bc.r or 0.3, bc.g or 0.3, bc.b or 0.3, 1)
end

-- InputBoxTemplate edit box. w/h are optional.
---@param parent table   Parent frame.
---@param name   string? Optional global frame name.
---@param w      number? Width (set only when both w and h given).
---@param h      number? Height.
---@return table         The created EditBox with margins stamped.
NS.CB_CreateEditBox = function(parent, name, w, h)
    local box = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
    if w and h then box:SetSize(w, h) end
    NS.CB_SkinEditBoxSafe(box)
    box.marginTop    = NS.MARGIN.editBox.top
    box.marginBottom = NS.MARGIN.editBox.bottom
    box.marginLeft   = NS.MARGIN.editBox.left
    box.marginRight  = NS.MARGIN.editBox.right
    return box
end

-- OptionsSliderTemplate slider paired with an optional title label and a centered EditBox.
-- Returns a wrapper frame; callers use wrapper:SetWidth() to size it.
-- The slider and EditBox are kept in sync: dragging updates the EditBox, and typing
-- (confirmed with Enter or focus loss) updates the slider.
-- onChange(v) fires whenever the committed integer value changes from either input path.
--
-- title:          optional label rendered above the slider bar (GameFontNormal / gold).
-- softMin/softMax define the slider's draggable range.
-- hardMin/hardMax define the EditBox's allowed input range (default = softMin/softMax).
--   Typing outside [softMin,softMax] pins the thumb to the boundary while onChange
--   still receives the full typed value.
--
-- Wrapper exposes :SetValue(v) / :GetValue() proxies plus sub-element refs:
--   .label, .slider, .editBox, .lowLabel, .highLabel, .textLabel (hidden built-in).
-- marginTop uses label.top when a title is present, slider.top otherwise.
---@param parent     table    Parent frame.
---@param name       string   Global name; sub-frames derive from it (name.."Text"/"Low"/"High").
---@param title      string?  Optional label above the slider bar.
---@param softMin    number   Slider draggable minimum.
---@param softMax    number   Slider draggable maximum.
---@param defaultVal number?  Initial value (default softMin).
---@param lowText    string?  Left-end label (default tostring(softMin)).
---@param highText   string?  Right-end label (default tostring(softMax)).
---@param onChange   fun(v:number)? Fires on committed integer value change.
---@param hardMin    number?  EditBox allowed minimum (default softMin).
---@param hardMax    number?  EditBox allowed maximum (default softMax).
---@return table              Wrapper frame with SetValue/GetValue/Enable/Disable and sub-refs.
NS.CB_CreateSlider = function(parent, name, title, softMin, softMax, defaultVal, lowText, highText, onChange, hardMin, hardMax)
    hardMin = hardMin or softMin
    hardMax = hardMax or softMax

    local wrapper = CreateFrame("Frame", nil, parent)

    -- Optional title label spanning the full widget width.
    local label = nil
    if title then
        label = wrapper:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetText(title)
        label:SetPoint("TOPLEFT",  wrapper, "TOPLEFT",  0, 0)
        label:SetPoint("TOPRIGHT", wrapper, "TOPRIGHT", 0, 0)
        label:SetJustifyH("CENTER")
        label:SetHeight(15)
    end

    -- Inner slider fills wrapper horizontally; anchored below label when present.
    local s = CreateFrame("Slider", name, wrapper, "OptionsSliderTemplate")
    s:SetHeight(17)
    if label then
        s:SetPoint("TOPLEFT",  label, "BOTTOMLEFT",  0, -2)
        s:SetPoint("TOPRIGHT", label, "BOTTOMRIGHT", 0, -2)
    else
        s:SetPoint("TOPLEFT",  wrapper, "TOPLEFT",  0, 0)
        s:SetPoint("TOPRIGHT", wrapper, "TOPRIGHT", 0, 0)
    end
    s:SetMinMaxValues(softMin, softMax)
    s:SetValueStep(1)

    local textLabel = _G[name .. "Text"]
    local lowLabel  = _G[name .. "Low"]
    local highLabel = _G[name .. "High"]
    if textLabel then textLabel:Hide() end
    if lowLabel  then lowLabel:SetText(lowText  or tostring(softMin)) end
    if highLabel then highLabel:SetText(highText or tostring(softMax)) end

    -- EditBox sits centred between the low/high labels, directly below the slider bar.
    -- Created directly (not via CB_CreateEditBox) so we can apply CB_SkinEditBoxSafe
    -- instead of HandleEditBox — see CB_SkinEditBoxSafe for the full explanation.
    local box = CreateFrame("EditBox", name .. "EditBox", wrapper, "InputBoxTemplate")
    box:SetSize(70, 18)
    NS.CB_SkinEditBoxSafe(box)
    box:SetPoint("TOP", s, "BOTTOM", 0, -2)
    box:SetAutoFocus(false)
    box:SetJustifyH("CENTER")

    -- Guard against re-entrancy when applyBoxValue moves the slider thumb.
    local updating = false

    -- Sync: slider → editbox → onChange.
    -- Skipped when applyBoxValue is already driving the update to avoid double-firing.
    s:SetScript("OnValueChanged", function(self, val)
        if updating then return end
        local v = math.floor(val + 0.5)
        box:SetText(tostring(v))
        if onChange then onChange(v) end
    end)

    -- Sync: editbox → slider.
    -- Hard range clamps the data value; soft range clamps the slider thumb position.
    -- Invalid text reverts to the current slider value without firing onChange.
    local function applyBoxValue()
        local v = tonumber(box:GetText())
        if v then
            v = math.max(hardMin, math.min(hardMax, math.floor(v + 0.5)))
            box:SetText(tostring(v))
            local thumbPos = math.max(softMin, math.min(softMax, v))
            updating = true
            s:SetValue(thumbPos)
            updating = false
            if onChange then onChange(v) end
        else
            box:SetText(tostring(math.floor(s:GetValue() + 0.5)))
        end
    end
    box:SetScript("OnEnterPressed", function(self) applyBoxValue(); self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self)
        box:SetText(tostring(math.floor(s:GetValue() + 0.5)))
        self:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", applyBoxValue)

    s:SetValue(defaultVal or softMin)
    if NS.ElvUI_S then NS.ElvUI_S:HandleSliderFrame(s) end

    -- Proxy SetValue/GetValue so callers treat the wrapper like a slider.
    wrapper.SetValue = function(self, v) s:SetValue(v) end
    wrapper.GetValue = function(self) return s:GetValue() end

    -- Moves the thumb WITHOUT firing onChange — for sync paths, so reconciles
    -- and group aggregates never echo a command back to the bot. `text`
    -- overrides the editbox content (e.g. "???" for mixed group values).
    ---@param v    number   New slider value.
    ---@param text string?  Editbox override; defaults to the rounded value.
    wrapper.SetValueSilent = function(self, v, text)
        updating = true
        s:SetValue(v)
        updating = false
        box:SetText(text or tostring(math.floor(v + 0.5)))
    end

    -- Snapshot original colors for Enable/Disable — must be read after HandleSliderFrame
    -- so ElvUI's thumb replacement is already in place. The stored values are the
    -- "enabled" colors; wrapper.SetTextColor overrides them for call sites that
    -- need a specific text color (e.g. the Combat tab's timer slider uses white
    -- to match its neighboring checkbox labels).
    local thumbTex                    = s:GetThumbTexture()
    local thumbR, thumbG, thumbB      = thumbTex:GetVertexColor()
    local labelR, labelG, labelB
    if label then labelR, labelG, labelB = label:GetTextColor() end
    local lowR, lowG, lowB
    if lowLabel then lowR, lowG, lowB = lowLabel:GetTextColor() end
    local highR, highG, highB
    if highLabel then highR, highG, highB = highLabel:GetTextColor() end
    local boxR,   boxG,   boxB        = box:GetTextColor()
    local GREY                        = 0.5

    -- Sets the slider's text color (title, endpoints, value box) and makes it
    -- the color Enable() restores — so a Disable/Enable cycle can't resurrect
    -- the skin's original (possibly off-theme) color.
    ---@param r number  Red 0-1.
    ---@param g number  Green 0-1.
    ---@param b number  Blue 0-1.
    wrapper.SetTextColor = function(self, r, g, b)
        labelR, labelG, labelB = r, g, b
        lowR,   lowG,   lowB   = r, g, b
        highR,  highG,  highB  = r, g, b
        boxR,   boxG,   boxB   = r, g, b
        if label     then label:SetTextColor(r, g, b) end
        if lowLabel  then lowLabel:SetTextColor(r, g, b) end
        if highLabel then highLabel:SetTextColor(r, g, b) end
        box:SetTextColor(r, g, b)
    end

    wrapper.Disable = function(self)
        if label    then label:SetTextColor(GREY, GREY, GREY) end
        if lowLabel  then lowLabel:SetTextColor(GREY, GREY, GREY) end
        if highLabel then highLabel:SetTextColor(GREY, GREY, GREY) end
        box:SetTextColor(GREY, GREY, GREY)
        thumbTex:SetVertexColor(GREY, GREY, GREY)
        s:EnableMouse(false)
        box:EnableMouse(false)
    end

    wrapper.Enable = function(self)
        if label    then label:SetTextColor(labelR, labelG, labelB) end
        if lowLabel  then lowLabel:SetTextColor(lowR, lowG, lowB) end
        if highLabel then highLabel:SetTextColor(highR, highG, highB) end
        box:SetTextColor(boxR, boxG, boxB)
        thumbTex:SetVertexColor(thumbR, thumbG, thumbB)
        s:EnableMouse(true)
        box:EnableMouse(true)
    end

    wrapper.label     = label
    wrapper.slider    = s
    wrapper.editBox   = box
    wrapper.lowLabel  = lowLabel
    wrapper.highLabel = highLabel
    wrapper.textLabel = textLabel  -- hidden; kept for reference

    -- Height: title (15px label + 2px gap) when present, + slider (17px) + gap (2px) + editbox (18px).
    local titleH = title and 17 or 0
    wrapper:SetHeight(titleH + 37)
    wrapper.marginTop    = title and NS.MARGIN.label.top or NS.MARGIN.slider.top
    wrapper.marginBottom = NS.MARGIN.slider.bottom
    wrapper.marginLeft   = NS.MARGIN.slider.left
    wrapper.marginRight  = NS.MARGIN.slider.right
    return wrapper
end

-- Wrapper containing a 20×20 colored swatch button on the left and an optional
-- text label to its right, aligned to the same vertical centre.
-- Clicking the swatch opens the WoW ColorPickerFrame.
--
-- showAlpha (optional bool): when true, the picker shows an opacity slider and
--   onChange(r, g, b, a) fires with all four channels.
--   When false/nil, onChange(r, g, b) fires as before (backward compatible).
-- initA (optional number 0–1): starting alpha when showAlpha is true. Defaults to 1.
--
-- The wrapper exposes :setColor(r, g, b [, a]) and a .swatch texture reference.
-- WoW's ColorPickerFrame uses an inverted opacity convention: opacity 0 = fully opaque,
-- opacity 1 = fully transparent. We convert: opacity = 1 - a on the way in/out.
---@param parent    table    Parent frame.
---@param name      string?  Optional global name for the swatch button.
---@param text      string?  Optional label to the right of the swatch.
---@param initR     number?  Initial red 0–1 (default 1).
---@param initG     number?  Initial green 0–1 (default 1).
---@param initB     number?  Initial blue 0–1 (default 1).
---@param onChange  fun(r:number,g:number,b:number,a:number?)? Fires on colour change.
---@param showAlpha boolean? When true, the picker exposes an opacity slider.
---@param initA     number?  Initial alpha 0–1 when showAlpha (default 1).
---@return table             Wrapper frame with :setColor and .swatch.
NS.CB_CreateColorSwatch = function(parent, name, text, initR, initG, initB, onChange, showAlpha, initA)
    local r, g, b = initR or 1, initG or 1, initB or 1
    local a       = (showAlpha and initA) or 1

    local wrapper = CreateFrame("Frame", nil, parent)
    wrapper:SetSize(160, 20)

    local btn = CreateFrame("Button", name, wrapper)
    btn:SetSize(20, 20)
    btn:SetPoint("LEFT", wrapper, "LEFT", 0, 0)

    local swatch = btn:CreateTexture(nil, "BACKGROUND")
    swatch:SetAllPoints()
    swatch:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    swatch:SetVertexColor(r, g, b, a)
    btn.swatch = swatch

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    if text then
        local lbl = wrapper:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetText(text)
        -- "LEFT" is the middle-left anchor point, so this centres the label
        -- vertically with the swatch button without extra math.
        lbl:SetPoint("LEFT", btn, "RIGHT", 4, 0)
    end

    btn:SetScript("OnClick", function()
        local prevR, prevG, prevB, prevA = r, g, b, a

        -- Fires when the user moves the RGB sliders.
        -- Intentionally does NOT read OpacitySliderFrame — SetColorRGB triggers this
        -- callback immediately (before ShowUIPanel initialises the opacity slider),
        -- so reading the slider here would clobber alpha with a stale value.
        local function applyRGB()
            r, g, b = ColorPickerFrame:GetColorRGB()
            swatch:SetVertexColor(r, g, b, a)
            if onChange then
                if showAlpha then onChange(r, g, b, a) else onChange(r, g, b) end
            end
        end

        -- Fires only when the user moves the opacity slider.
        -- WoW opacity convention: 0 = fully opaque, 1 = fully transparent (inverted).
        local function applyOpacity()
            a = 1 - OpacitySliderFrame:GetValue()
            swatch:SetVertexColor(r, g, b, a)
            if onChange then onChange(r, g, b, a) end
        end

        ColorPickerFrame.func       = applyRGB
        ColorPickerFrame.cancelFunc = function()
            r, g, b, a = prevR, prevG, prevB, prevA
            swatch:SetVertexColor(r, g, b, a)
            if onChange then
                if showAlpha then onChange(r, g, b, a) else onChange(r, g, b) end
            end
        end

        ColorPickerFrame:SetColorRGB(r, g, b)

        if showAlpha then
            ColorPickerFrame.hasOpacity  = true
            ColorPickerFrame.opacity     = 1 - a  -- convert alpha → WoW opacity
            ColorPickerFrame.opacityFunc = applyOpacity
        else
            ColorPickerFrame.hasOpacity  = false
            ColorPickerFrame.opacityFunc = nil
        end

        ShowUIPanel(ColorPickerFrame)
    end)

    wrapper.swatch   = swatch
    wrapper.setColor = function(self, nr, ng, nb, na)
        r, g, b = nr, ng, nb
        if showAlpha and na ~= nil then a = na end
        swatch:SetVertexColor(r, g, b, a)
    end

    wrapper.marginTop    = NS.MARGIN.swatch.top
    wrapper.marginBottom = NS.MARGIN.swatch.bottom
    wrapper.marginLeft   = NS.MARGIN.swatch.left
    wrapper.marginRight  = NS.MARGIN.swatch.right
    return wrapper
end

-- Clears keyboard focus from any focused EditBox (e.g. a slider EditBox) when
-- the user clicks in the 3D world or on the CleanBot frame's own background.
-- Without this, EditBoxes hold focus indefinitely until Escape is pressed.
local function CB_ClearKeyboardFocus()
    local focused = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    if focused then focused:ClearFocus() end
end
WorldFrame:HookScript("OnMouseDown",    CB_ClearKeyboardFocus)
CleanBotFrame:HookScript("OnMouseDown", CB_ClearKeyboardFocus)
