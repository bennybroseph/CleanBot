-- ============================================================
-- CleanBotEquip.lua  —  Paperdoll equipment slot buttons.
--
-- All geometry is derived proportionally from the live model
-- frame dimensions so the layout scales correctly if the model
-- is resized:
--
--   step     = modelH / 8   (evenly distributes 8 slots across height)
--   slotSize = step * 0.88  (12% gap between consecutive slots)
--   gapX     = modelW * 0.03  (column separation from model edge, ~7px
--                               at Blizzard's 237px model width)
--   gapYBot  = modelH * 0.02  (weapon row clearance below model bottom)
--
-- Icons and tooltips use WoW's built-in unit inventory APIs:
--   GetInventoryItemTexture(unit, slotId)   — item icon
--   GameTooltip:SetInventoryItem(unit, slotId) — full rich tooltip
--
-- Slot buttons are stored in slot.equipSlots[slotId]; on bind the per-key
-- registry NS.botEquipSlots[key] is repointed there for refresh/drag lookups.
-- ============================================================
local NS = CleanBotNS

-- ── Shared Wowhead URL popup ──────────────────────────────────────────────
-- Plain-text URL in a selectable EditBox — Ctrl+C works fine on regular text.
-- Populates `info` with the Wowhead menu entry for `itemLink` and adds it.
-- Reusable across any UIDropDownMenu that has an item link in scope.
NS.CB_AddWowheadMenuButton = function(info, itemLink)
    info.text         = "Open on Wowhead"
    info.notCheckable = true
    info.func         = function()
        local itemId = strmatch(itemLink, "item:(%d+)")
        if not itemId then return end
        local url   = "https://www.wowhead.com/wotlk/item=" .. itemId
        local popup = NS.CB_GetWowheadPopup()
        popup.box:SetText(url)
        popup:Show()
        popup.box:SetFocus()
        popup.box:HighlightText()
    end
    UIDropDownMenu_AddButton(info)
end

NS.CB_GetWowheadPopup = function()
    if NS.wowheadPopup then return NS.wowheadPopup end

    local popup = CreateFrame("Frame", "CleanBotWowheadPopup", UIParent)
    popup:SetSize(380, 110)
    popup:SetPoint("CENTER")
    popup:SetFrameStrata("DIALOG")
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop",  popup.StopMovingOrSizing)
    NS.CB_ApplyFrameSkin(popup, 1)
    popup:Hide()

    local label = NS.CB_CreateLabel(popup, "Wowhead  (Ctrl+C to copy, then open in browser)")
    label:SetPoint("TOPLEFT", popup, "TOPLEFT", 18, -16)

    local box = NS.CB_CreateEditBox(popup, nil, 344, 20)
    NS.CB_AnchorBelow(box, label)
    box:SetAutoFocus(true)
    box:SetScript("OnEscapePressed", function(self) self:GetParent():Hide() end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    popup.box = box

    local closeBtn = NS.CB_CreateButton(popup, nil, "Close", 80, 22, function() popup:Hide() end)
    closeBtn:SetPoint("BOTTOM", popup, "BOTTOM", 0, 12)

    NS.wowheadPopup = popup
    return popup
end

-- ── Shared right-click context menu ──────────────────────────────────────
local equipMenu = CreateFrame("Frame", "CleanBotEquipMenu", UIParent, "UIDropDownMenuTemplate")

local function CB_ShowEquipMenu(btn)
    if not btn.itemLink then return end
    UIDropDownMenu_Initialize(equipMenu, function()
        local info = UIDropDownMenu_CreateInfo()

        info.text         = "Unequip"
        info.notCheckable = true
        info.func         = function()
            local botName = btn.slot.name
            if not botName then return end
            NS.CB_SendBotCommand(botName, "ue " .. btn.itemLink)
        end
        UIDropDownMenu_AddButton(info)

        NS.CB_AddWowheadMenuButton(info, btn.itemLink)

        info.text         = "Close"
        info.notCheckable = true
        info.func         = function() CloseDropDownMenus() end
        UIDropDownMenu_AddButton(info)
    end, "MENU")
    ToggleDropDownMenu(1, nil, equipMenu, btn, 0, 0)
end

-- ── Unequip drag (equip slot → inventory frame) ──────────────────────────

local function CB_StopUnequipDrag()
    if not NS.unequipDragging then return end
    local d = NS.unequipDragging

    if d.hoverCell then d.hoverCell:UnlockHighlight() end

    if d.sourceBtn and d.sourceBtn.icon then
        d.sourceBtn.icon:SetDesaturated(false)
    end

    if d.dropCell then
        local entry = CleanBot_PartyBots[d.slot.key]
        if entry then
            local itemId   = strmatch(d.itemLink, "item:(%d+)")
            local iconPath = GetItemIcon(tonumber(itemId) or 0)
            d.sourceBtn.icon:Hide()
            d.sourceBtn.itemLink = nil
            d.dropCell.icon:SetTexture(iconPath)
            d.dropCell.icon:Show()
            d.dropCell.itemLink = d.itemLink

            entry.pendingValidation = { link = d.itemLink, expectPresent = true }
            NS.CB_SendBotCommand(entry.name, "ue " .. d.itemLink)
            local capturedSlot = d.slot
            local capturedKey  = d.slot.key
            NS.CB_After(1.5, function()
                if capturedSlot.unit and UnitExists(capturedSlot.unit) then
                    NS.CB_QueueEquipRefresh({{ key = capturedKey, unit = capturedSlot.unit }})
                end
                NS.CB_FetchInventory(capturedKey, entry.name)
            end)
        end
    end

    NS.unequipDragging = nil
    NS.CB_EndCapture()
    ResetCursor()
end

local function CB_UnequipDragOnUpdate()
    if not NS.unequipDragging then return end
    local d = NS.unequipDragging

    local invFrame  = NS.botInventoryFrames and NS.botInventoryFrames[d.slot.key]
    local foundCell = nil
    if invFrame and invFrame:IsShown() then
        local scale  = UIParent:GetEffectiveScale()
        local mx, my = GetCursorPosition()
        mx, my = mx / scale, my / scale
        for _, cell in ipairs(invFrame.cells) do
            if cell:IsShown() and not cell.itemLink then
                local l, r, b, t = cell:GetLeft(), cell:GetRight(), cell:GetBottom(), cell:GetTop()
                if l and r and b and t and mx >= l and mx <= r and my >= b and my <= t then
                    foundCell = cell
                    break
                end
            end
        end
    end

    if foundCell ~= d.hoverCell then
        if d.hoverCell then d.hoverCell:UnlockHighlight() end
        if foundCell then foundCell:LockHighlight() end
        d.hoverCell = foundCell
    end
    d.dropCell = foundCell
end

local function CB_BeginUnequipDrag()
    NS.CB_BeginCapture(CB_UnequipDragOnUpdate, function(btn)
        if btn == "LeftButton" then CB_StopUnequipDrag() end
    end)
end

NS.CB_CreateEquipSlots = function(slot, model)
    slot.equipSlots = {}

    local modelW = model:GetWidth()
    local modelH = model:GetHeight()

    -- ── Proportional geometry (shared with CB_GetGeometry) ────
    local g        = NS.CB_SlotGeometry(modelW, modelH)
    local step     = g.step
    local slotSize = g.slot
    local gapX     = g.gapX
    local gapYBot  = g.gapYBot

    for _, eqdef in ipairs(NS.EQUIP_SLOTS) do
        local btnName = "CleanBotEquip_" .. slot.index .. "_" .. eqdef.id
        local btn = CreateFrame("Button", btnName, model, "ItemButtonTemplate")
        btn:SetSize(slotSize, slotSize)
        btn.slot = slot

        -- ── Position ──────────────────────────────────────────
        local yOff = -((eqdef.order - 1) * step)

        if eqdef.side == "left" then
            btn:SetPoint("TOPRIGHT", model, "TOPLEFT", -gapX, yOff)
        elseif eqdef.side == "right" then
            btn:SetPoint("TOPLEFT", model, "TOPRIGHT", gapX, yOff)
        else  -- "bottom" — three weapon slots centred below the model
            local totalW = 3 * slotSize + 2 * gapX
            local xOff   = math.floor((modelW - totalW) / 2)
                         + (eqdef.order - 1) * (slotSize + gapX)
            btn:SetPoint("TOPLEFT", model, "BOTTOMLEFT", xOff, -gapYBot)
        end

        -- ── Empty-slot background ─────────────────────────────────────────────
        -- Unregister the template NormalTexture from the button's state machine
        -- entirely. Simply calling Hide() on the texture object is insufficient —
        -- WoW's C++ button code re-shows it on every state transition (OnShow,
        -- normal-state entry, etc.), covering btn.bg.  SetNormalTexture("") severs
        -- the reference so the state machine never touches it again.
        -- Equip slots use btn.qualityFrame for quality borders, not normTex.
        btn:SetNormalTexture("")

        -- ── Item icon — template's IconTexture, hidden until equipped ────────
        -- ClearAllPoints first: the template XML may have set its own anchors
        -- (e.g. a centered AbsDimension), which would conflict with SetAllPoints
        -- and cause the renderer to clamp to the smallest valid size.
        local icon = _G[btnName .. "IconTexture"]
        icon:ClearAllPoints()
        icon:SetAllPoints()
        icon:Hide()
        btn.icon = icon

        -- ── Interaction textures ──────────────────────────────
        btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")

        NS.CB_ApplyQualityBackdrop(btn)

        -- ── Tooltip ───────────────────────────────────────────
        btn.slotId   = eqdef.id
        btn.slotName = eqdef.name

        -- Template OnLoad already calls RegisterForClicks("LeftButtonUp", "RightButtonUp")

        btn:SetScript("OnClick", function(self, mouseBtn)
            if mouseBtn == "RightButton" and self.itemLink then
                CB_ShowEquipMenu(self)
            elseif mouseBtn == "LeftButton" and IsShiftKeyDown() and self.itemLink then
                ChatEdit_InsertLink(NS.CB_CleanItemLink(self.itemLink))
            end
        end)

        btn:SetScript("OnMouseDown", function(self, mouseBtn)
            if mouseBtn ~= "LeftButton" or not self.itemLink or IsShiftKeyDown() then return end
            local itemId   = strmatch(self.itemLink, "item:(%d+)")
            local iconPath = GetItemIcon(tonumber(itemId) or 0)
            NS.unequipDragging = { slot = slot, itemLink = self.itemLink, sourceBtn = self, overInventory = false }
            self.icon:SetDesaturated(true)
            GameTooltip:Hide()
            SetCursor(iconPath)
            CB_BeginUnequipDrag()
        end)

        btn:SetScript("OnMouseUp", function(self, mouseBtn)
            if mouseBtn == "LeftButton" then CB_StopUnequipDrag() end
        end)

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.itemLink then
                GameTooltip:SetHyperlink(self.itemLink)
            else
                GameTooltip:AddLine(self.slotName, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        NS.CB_SkinEquipSlot(btn)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        -- ── Empty-slot background ─────────────────────────────────────────────
        -- Wrapped in a child Frame rather than a direct child Texture. ElvUI's
        -- global ItemButtonTemplate hook calls StripTextures on the button itself
        -- (wiping all direct child textures) after our code runs. Child Frames are
        -- not regions — StripTextures never descends into them — so the slot art
        -- texture survives ElvUI's late global pass regardless of timing.
        local bgFrame = CreateFrame("Frame", nil, btn)
        bgFrame:SetAllPoints()
        bgFrame:SetFrameLevel(btn:GetFrameLevel() + 1)
        local bgTex = bgFrame:CreateTexture(nil, "BACKGROUND")
        bgTex:SetAllPoints()
        bgTex:SetTexture(eqdef.tex)
        NS.CB_ApplyElvCoords(bgTex)
        btn.bg     = bgFrame
        btn.bgTex  = bgTex
        btn.slotTex = eqdef.tex

        slot.equipSlots[eqdef.id] = btn
    end

    -- ── Bag icon — opens the inventory frame ──────────────────
    -- Plain Button (no ItemButtonTemplate) so it stays out of all the equip
    -- slot / normTex / quality border infrastructure entirely.
    local bagBtnName = "CleanBotBagBtn_" .. slot.index
    local bagBtn = CreateFrame("Button", bagBtnName, model)
    bagBtn:SetSize(slotSize, slotSize)
    bagBtn:SetPoint("LEFT", slot.equipSlots[9],  "LEFT", 0, 0)
    bagBtn:SetPoint("TOP",  slot.equipSlots[16], "TOP",  0, 0)
    bagBtn:RegisterForClicks("LeftButtonUp")

    if NS.ElvUI_S then
        NS.ElvUI_S:HandleButton(bagBtn)
        bagBtn:StyleButton()
    else
        bagBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        bagBtn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    end

    local bagIcon = bagBtn:CreateTexture(nil, "ARTWORK")
    bagIcon:SetTexture("Interface\\Buttons\\Button-Backpack-Up")
    bagIcon:SetAllPoints()
    NS.CB_ApplyElvCoords(bagIcon)
    bagIcon:Show()

    bagBtn:SetScript("OnClick", function()
        local key     = slot.key
        if not key then return end
        local entry   = CleanBot_PartyBots[key]
        local botName = entry and entry.name or slot.name or key
        if NS.botInventoryFrames[key] and NS.botInventoryFrames[key]:IsShown() then
            NS.botInventoryFrames[key]:Hide()
        else
            NS.CB_RequestInventory(key, botName)
        end
    end)
    bagBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Open Inventory", 1, 1, 1)
        GameTooltip:Show()
    end)
    bagBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- ── Equipment refresh via InspectUnit chain ───────────────────────────────
-- GetInventoryItemTexture only returns data the client has already cached.
-- InspectUnit forces the server to send full equipment data.
--
-- INSPECT_READY is unreliable on private servers — this server never fires it.
-- So the primary path is timer-based: call InspectUnit, wait INSPECT_WAIT
-- seconds for the data to load, then read and move on.
-- INSPECT_READY is kept as a fast-path: if it does fire we skip the wait early.
--
-- INSPECT_WAIT also acts as the cooldown gap between consecutive InspectUnit
-- calls, so no separate delay logic is needed.

local INSPECT_WAIT   = 0.25   -- seconds to wait after NotifyInspect before reading data
                              -- must be > throttle window (~1.5s per WoW 3.3.5 docs)

local inspectQueue   = {}    -- { key, unit } entries waiting to be inspected
NS.pendingInspects   = {}    -- { [guid] = { key, unit } } for INSPECT_READY fast-path
local waitFrame      = nil   -- active wait timer

local processNextInspect     -- forward declaration

local function cancelWait()
    if waitFrame then
        waitFrame:SetScript("OnUpdate", nil)
        waitFrame = nil
    end
end

local function doRefreshAndNext(key, unit)
    cancelWait()
    NS.CB_RefreshEquipSlots(key, unit)
    processNextInspect()
end

local function startWait(key, unit)
    local elapsed = 0
    waitFrame = CreateFrame("Frame")
    waitFrame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= INSPECT_WAIT then
            doRefreshAndNext(key, unit)
        end
    end)
end

processNextInspect = function()
    cancelWait()
    while #inspectQueue > 0 do
        local next = table.remove(inspectQueue, 1)
        if UnitExists(next.unit) then
            local guid = UnitGUID(next.unit)
            if guid then NS.pendingInspects[guid] = next end
            NotifyInspect(next.unit)
            startWait(next.key, next.unit)
            return
        end
        -- unit gone — skip to next
    end
    -- Queue empty — nothing to clean up (NotifyInspect doesn't open a frame)
    NS.pendingInspects = {}
end

-- Called from RefreshTabs after all bot tabs are built.
NS.CB_QueueEquipRefresh = function(botList)
    cancelWait()
    NS.pendingInspects = {}
    inspectQueue = {}
    for _, info in ipairs(botList) do
        table.insert(inspectQueue, { key = info.key, unit = info.unit })
    end
    processNextInspect()
end

-- Called from CleanBot.lua when INSPECT_READY fires.
-- Populates slots early if the server responds before INSPECT_WAIT expires,
-- but does NOT chain to the next NotifyInspect — the waitFrame timer does that,
-- ensuring we always respect the throttle window between requests.
NS.CB_OnInspectReady = function(guid)
    local info = NS.pendingInspects[guid]
    if info then
        NS.pendingInspects[guid] = nil
        NS.CB_RefreshEquipSlots(info.key, info.unit)
        -- waitFrame is still running and will call processNextInspect when done
    end
    -- guid not in our table = player opened inspect themselves; leave it alone
end

-- Refreshes slot icons and the DressUpModel for one bot from live inventory data.
NS.CB_RefreshEquipSlots = function(key, unit)
    local slots = NS.botEquipSlots and NS.botEquipSlots[key]
    if not slots then return end
    for slotId, btn in pairs(slots) do
        local itemTex  = GetInventoryItemTexture(unit, slotId)
        local itemLink = GetInventoryItemLink(unit, slotId)
        if itemTex then
            btn.icon:SetTexture(itemTex)
            btn.icon:Show()
            if btn.bg then btn.bg:Hide() end
            btn.itemLink = itemLink
            local _, _, quality = GetItemInfo(itemLink)
            if quality then NS.CB_SetQualityBorder(btn, quality) end
        else
            btn.icon:Hide()
            if btn.bg then btn.bg:Show() end
            btn.itemLink = nil
            NS.CB_ClearQualityBorder(btn)
        end
    end

    -- Refresh the model so it renders the updated equipment appearance
    for _, slot in ipairs(NS.tabList or {}) do
        if slot.key == key and slot.model and slot.model:IsShown() then
            slot.model:SetUnit(unit)
            break
        end
    end
end
