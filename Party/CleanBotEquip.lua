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
-- Slot buttons are stored in NS.botEquipSlots[key][slotId] for
-- later use (refresh, click actions, etc.).
-- ============================================================
local NS = CleanBotNS

-- ── Shared Wowhead URL popup ──────────────────────────────────────────────
-- Plain-text URL in a selectable EditBox — Ctrl+C works fine on regular text.
local function CB_GetWowheadPopup()
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
    NS.CB_ApplyPanelSkin(popup)
    popup:Hide()

    local label = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", popup, "TOPLEFT", 18, -16)
    label:SetText("Wowhead  (Ctrl+C to copy, then open in browser)")

    local box = CreateFrame("EditBox", nil, popup, "InputBoxTemplate")
    box:SetSize(344, 20)
    box:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 4, -6)
    box:SetAutoFocus(true)
    box:SetScript("OnEscapePressed", function(self) self:GetParent():Hide() end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    popup.box = box

    if NS.ElvUI_S then NS.ElvUI_S:HandleEditBox(box) end

    local closeBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    closeBtn:SetSize(80, 22)
    closeBtn:SetPoint("BOTTOM", popup, "BOTTOM", 0, 12)
    closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function() popup:Hide() end)
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(closeBtn) end

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
            local botName = UnitName(btn.unit)
            if not botName then return end
            SendChatMessage("ue " .. btn.itemLink, "WHISPER", nil, botName)
        end
        UIDropDownMenu_AddButton(info)

        info.text         = "Open on Wowhead"
        info.notCheckable = true
        info.func         = function()
            local itemId = strmatch(btn.itemLink, "item:(%d+)")
            if not itemId then return end
            local url    = "https://www.wowhead.com/wotlk/item=" .. itemId
            local popup  = CB_GetWowheadPopup()
            popup.box:SetText(url)
            popup:Show()
            popup.box:SetFocus()
            popup.box:HighlightText()
        end
        UIDropDownMenu_AddButton(info)

        info.text         = "Close"
        info.notCheckable = true
        info.func         = function() CloseDropDownMenus() end
        UIDropDownMenu_AddButton(info)
    end, "MENU")
    ToggleDropDownMenu(1, nil, equipMenu, btn, 0, 0)
end

NS.CB_CreateEquipSlots = function(model, key, counter, unit)
    NS.botEquipSlots[key] = {}

    local modelW = model:GetWidth()
    local modelH = model:GetHeight()

    -- ── Proportional geometry ─────────────────────────────────
    local step     = math.floor(modelH / 8)
    local slotSize = math.floor(step * 0.88)
    local gapX     = math.max(2, math.floor(modelW * 0.03))
    local gapYBot  = math.max(2, math.floor(modelH * 0.02))

    for _, slot in ipairs(NS.EQUIP_SLOTS) do
        local btn = CreateFrame("Button", "CleanBotEquip_" .. counter .. "_" .. slot.id, model)
        btn:SetSize(slotSize, slotSize)

        -- ── Position ──────────────────────────────────────────
        local yOff = -((slot.order - 1) * step)

        if slot.side == "left" then
            btn:SetPoint("TOPRIGHT", model, "TOPLEFT", -gapX, yOff)
        elseif slot.side == "right" then
            btn:SetPoint("TOPLEFT", model, "TOPRIGHT", gapX, yOff)
        else  -- "bottom" — three weapon slots centred below the model
            local totalW = 3 * slotSize + 2 * gapX
            local xOff   = math.floor((modelW - totalW) / 2)
                         + (slot.order - 1) * (slotSize + gapX)
            btn:SetPoint("TOPLEFT", model, "BOTTOMLEFT", xOff, -gapYBot)
        end

        -- ── Empty-slot background (shown when nothing equipped) ──
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(slot.tex)
        btn.bg = bg

        -- ── Item icon (shown when something is equipped) ──────
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:Hide()
        btn.icon = icon

        -- ── Populate icon from equipped item ──────────────────
        local itemTex = GetInventoryItemTexture(unit, slot.id)
        if itemTex then
            icon:SetTexture(itemTex)
            icon:Show()
        end

        -- ── Interaction textures ──────────────────────────────
        btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")

        -- ── Tooltip ───────────────────────────────────────────
        -- Store on button so the tooltip script can close over them cleanly
        btn.unit   = unit
        btn.slotId = slot.id
        btn.slotName = slot.name

        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnClick", function(self, mouseBtn)
            if mouseBtn == "RightButton" and self.itemLink then
                CB_ShowEquipMenu(self)
            end
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

        NS.botEquipSlots[key][slot.id] = btn
    end
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

-- Refreshes slot icons for one bot from live inventory data.
NS.CB_RefreshEquipSlots = function(key, unit)
    local slots = NS.botEquipSlots and NS.botEquipSlots[key]
    if not slots then return end
    for slotId, btn in pairs(slots) do
        local itemTex = GetInventoryItemTexture(unit, slotId)
        if itemTex then
            btn.icon:SetTexture(itemTex)
            btn.icon:Show()
            btn.itemLink = GetInventoryItemLink(unit, slotId)
        else
            btn.icon:Hide()
            btn.itemLink = nil
        end
    end
end
