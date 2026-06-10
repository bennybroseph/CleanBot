-- ============================================================
-- Equip.lua  —  Paperdoll equipment slot buttons.
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
---@param info     table   UIDropDownMenu button info table to populate and add.
---@param itemLink string  The item link the Wowhead entry should point to.
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

---@param btn table  The equipment slot button the context menu is opened from.
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

---@param slot  table  The pool slot table (bound bot resolved live via slot.key/unit).
---@param model table  The DressUpModel the paperdoll slots anchor around.
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
            local unit = self.slot and self.slot.unit

            -- Unit-aware tooltip (gems / enchants / set-bonus highlighting). On a HIT
            -- the bot is still the current inspect target — done.
            if unit and UnitExists(unit) and self.slotId
               and GameTooltip:SetInventoryItem(unit, self.slotId) then
                return
            end

            -- MISS: the global single-unit inspect slot was likely stolen by another
            -- addon inspecting party members in the background. Show the generic link
            -- now (no worse than before), reclaim the bot via NotifyInspect, then
            -- upgrade the tooltip in place once the data lands — if still hovering this
            -- same slot. Empty slots just show the slot-name label.
            if self.itemLink then
                GameTooltip:SetHyperlink(self.itemLink)
            else
                GameTooltip:AddLine(self.slotName, 1, 1, 1)
                GameTooltip:Show()
            end

            if unit and UnitExists(unit) and self.slotId and self.itemLink then
                NotifyInspect(unit)   -- reclaim: make this bot the current inspect target
                local btn = self
                NS.CB_After(0.35, function()
                    -- Only upgrade if the mouse is still over this exact slot/bot.
                    if GameTooltip:IsShown() and GameTooltip:GetOwner() == btn
                       and btn.slot and btn.slot.unit == unit and btn.itemLink then
                        -- Re-fill; if data still hasn't arrived (throttled), restore the
                        -- generic link so the tooltip never goes blank.
                        if not GameTooltip:SetInventoryItem(unit, btn.slotId) then
                            GameTooltip:SetHyperlink(btn.itemLink)
                        end
                    end
                end)
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

    NS.CB_CreateQuestButton(slot, model, slotSize)
end

-- ── Equipment refresh via NotifyInspect ───────────────────────────────────
-- GetInventoryItemTexture/Link only return data the client has cached.
-- NotifyInspect asks the server for a unit's inspect packet (talents + gear).
--
-- In WoW 3.3.5a the relevant event is INSPECT_TALENT_READY (NOT "INSPECT_READY",
-- which does not exist in this client). Per the NotifyInspect docs, equipment is
-- readable immediately via the Inventory APIs once the inspect packet arrives, and
-- that packet's arrival is signalled by INSPECT_TALENT_READY — so the event is the
-- PRIMARY, event-driven completion path: gear shows as soon as the data lands,
-- with no fixed delay. (Bridge.lua routes the event here via CB_OnInspectReady.)
--
-- INSPECT_TIMEOUT is only a safety net: if the event never fires (e.g. the client
-- throttle of ~6 NotifyInspect/10s silently drops the request), we advance the
-- queue so it can't stall. The timeout path deliberately does NOT refresh: no
-- event means no inspect packet, so the cache cannot hold anything newer than
-- the opportunistic read already painted — re-reading it would only stomp
-- optimistic equip/unequip visuals with stale data.
local INSPECT_TIMEOUT = 1.0

local inspectQueue   = {}    -- { key, unit } entries waiting to be inspected
local waitFrame      = nil   -- active fallback timer
local current        = nil   -- the in-flight entry { key, unit }, or nil when idle

local processNextInspect     -- forward declaration

local function cancelWait()
    if waitFrame then
        waitFrame:SetScript("OnUpdate", nil)
        waitFrame = nil
    end
end

-- Clears the in-flight entry.
local function clearCurrent()
    current = nil
end

-- Clears the in-flight entry and advances to the next queued inspect, refreshing
-- the bot's slots first only when fresh data actually arrived (the event path).
---@param refresh boolean  Whether to repaint slots before advancing.
local function finishCurrent(refresh)
    cancelWait()
    if refresh and current then NS.CB_RefreshEquipSlots(current.key, current.unit) end
    clearCurrent()
    processNextInspect()
end

-- Fallback-only timer: advance (without repainting — see INSPECT_TIMEOUT note)
-- if INSPECT_TALENT_READY never arrives for this unit.
local function startWait()
    cancelWait()
    local elapsed = 0
    waitFrame = CreateFrame("Frame")
    waitFrame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= INSPECT_TIMEOUT then
            finishCurrent(false)
        end
    end)
end

processNextInspect = function()
    cancelWait()
    while #inspectQueue > 0 do
        local entry = table.remove(inspectQueue, 1)
        if UnitExists(entry.unit) then
            current = entry
            NotifyInspect(entry.unit)
            -- Opportunistic immediate read: instant for an already-cached unit
            -- (re-selecting a bot viewed earlier); harmless on a freshly-bound
            -- empty slot. INSPECT_TALENT_READY (or the fallback) fills fresh data.
            NS.CB_RefreshEquipSlots(entry.key, entry.unit)
            startWait()
            return
        end
        -- unit gone — skip to next
    end
    current = nil   -- queue drained; idle
end

-- Queues bots for an equipment inspect. ADDITIVE: appends entries (deduped by key
-- against the in-flight and already-queued ones) and only starts processing when
-- idle. It never resets an in-flight inspect — so selecting/loading another bot
-- mid-queue no longer drops the bot currently being inspected (the "quits early"
-- bug). The future Group tab can bulk-enqueue without clobbering, too.
---@param botList table  Array of { key = string, unit = string } bots to inspect in turn.
NS.CB_QueueEquipRefresh = function(botList)
    for _, info in ipairs(botList) do
        local dup = (current ~= nil and current.key == info.key)
        if not dup then
            for _, q in ipairs(inspectQueue) do
                if q.key == info.key then dup = true; break end
            end
        end
        if not dup then
            inspectQueue[#inspectQueue + 1] = { key = info.key, unit = info.unit }
        end
    end
    if not current then processNextInspect() end
end

-- Called from Bridge.lua when INSPECT_TALENT_READY fires — the primary completion
-- path. The event carries no unit id, but inspects are serialised, so it always
-- refers to the in-flight `current`. Refreshes it and advances. When `current` is
-- nil the event is the player's own inspect (Blizzard UI) — ignore it.
NS.CB_OnInspectReady = function()
    if current then
        -- Talent data is readable right now (that's what this event means) —
        -- sync the talent-spec dropdown before finishCurrent clears `current`.
        -- Deliberately not done on the fallback-timer path: without the event,
        -- talent data likely never arrived; the next successful inspect catches it.
        if NS.CB_SyncTalentSpec then NS.CB_SyncTalentSpec(current.key) end
        finishCurrent(true)
    end
end

-- Refreshes slot icons and the DressUpModel for one bot from live inventory data.
---@param key  string  Bot name-key whose equip slots are being refreshed.
---@param unit string  Unit token to read equipped items from (e.g. "party1").
NS.CB_RefreshEquipSlots = function(key, unit)
    local slots = NS.botEquipSlots and NS.botEquipSlots[key]
    if not slots then return end
    for slotId, btn in pairs(slots) do
        local itemTex  = GetInventoryItemTexture(unit, slotId)
        local itemLink = GetInventoryItemLink(unit, slotId)
        if itemTex then
            -- Staleness guard: right after an equip the inspect data's TEXTURE
            -- updates immediately but the LINK lags a few seconds, so a link-derived
            -- border (GetItemInfo) would be the OLD item's rarity (right icon, wrong
            -- border). Apply icon+link+border only when the link is consistent with
            -- the fresh texture (same icon path); otherwise skip this slot, leaving
            -- the current display (the correct optimistic paint, or the prior item)
            -- until a later refresh reads a caught-up link. GetItemIcon resolves even
            -- for uncached items, so the comparison is reliable.
            local linkFresh = itemLink and (GetItemIcon(itemLink) == itemTex)
            if linkFresh then
                btn.icon:SetTexture(itemTex)
                btn.icon:Show()
                if btn.bg then btn.bg:Hide() end
                btn.itemLink = itemLink
                -- Clear on unknown quality rather than skipping, so a GetItemInfo
                -- cache miss can't leave the previous item's border colour behind.
                local quality = select(3, GetItemInfo(itemLink))
                if quality then
                    NS.CB_SetQualityBorder(btn, quality)
                else
                    NS.CB_ClearQualityBorder(btn)
                end
            elseif not itemLink then
                -- Texture present but no link at all (link not yet populated): show
                -- the fresh icon now; the border lands on the next consistent read.
                btn.icon:SetTexture(itemTex)
                btn.icon:Show()
                if btn.bg then btn.bg:Hide() end
            end
            -- else: link lags the texture — leave the slot untouched (no stale border).
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
