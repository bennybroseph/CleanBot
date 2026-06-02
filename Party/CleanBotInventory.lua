-- ============================================================
-- CleanBotInventory.lua  —  Per-bot inventory bag frame.
-- ============================================================
local NS = CleanBotNS

NS.botInventoryFrames = NS.botInventoryFrames or {}

local CELL_SIZE   = 37
local COLS        = 10
local CELL_PAD    = 3
local FRAME_PAD   = 14
local HEADER_H    = 28
local FOOTER_H    = 24

-- ── URL decode (bridge sends UrlEncodeField output) ───────────────────────
local function UrlDecode(s)
    return (s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

-- ── Parse a single INV_ITEM / whisper line into {link, count} ────────────
-- The server appends " (soulbound)" and/or " xN" after the closing |r.
local function ParseItemLine(raw)
    local decoded = UrlDecode(raw)
    local link    = decoded:match("(|c%x+|Hitem:[^|]+|h%[.-%]|h|r)")
    if not link then return nil end
    local count   = tonumber(decoded:match("|r%s*x(%d+)")) or 1
    return { link = link, count = count }
end
NS.CB_ParseItemLine = ParseItemLine   -- exposed for CleanBot.lua whisper handler

-- ── Inventory cell right-click context menu ──────────────────────────────
local invMenu = CreateFrame("Frame", "CleanBotInvMenu", UIParent, "UIDropDownMenuTemplate")

local function CB_ShowInvMenu(cell, key)
    if not cell.itemLink then return end
    UIDropDownMenu_Initialize(invMenu, function()
        local info = UIDropDownMenu_CreateInfo()

        info.text         = "Equip"
        info.notCheckable = true
        info.func         = function()
            local entry = CleanBot_PartyBots[key]
            if not entry then return end
            local itemId = strmatch(cell.itemLink, "item:(%d+)")
            local _, apiLink = GetItemInfo(tonumber(itemId) or 0)
            SendChatMessage("e " .. (apiLink or cell.itemLink), "WHISPER", nil, entry.name)
            local dragKey  = key
            local botName  = entry.name
            local elapsed  = 0
            local t = CreateFrame("Frame")
            t:SetScript("OnUpdate", function(self, dt)
                elapsed = elapsed + dt
                if elapsed >= 1.5 then
                    self:SetScript("OnUpdate", nil)
                    NS.CB_FetchInventory(dragKey, botName)
                end
            end)
        end
        UIDropDownMenu_AddButton(info)

        info.text         = "Cancel"
        info.notCheckable = true
        info.func         = function() CloseDropDownMenus() end
        UIDropDownMenu_AddButton(info)
    end, "MENU")
    ToggleDropDownMenu(1, nil, invMenu, cell, 0, 0)
end

-- ── Drag stop (shared by cell OnMouseUp and capture frame OnMouseUp) ─────
local function CB_StopDrag()
    if not NS.dragging then return end
    if NS.dragging.hoverBtn then NS.dragging.hoverBtn:UnlockHighlight() end
    local dropBtn = NS.dragging.dropBtn
    if dropBtn then
        local dragKey  = NS.dragging.key
        local dragLink = NS.dragging.link
        local entry    = CleanBot_PartyBots[dragKey]
        if entry then
            local itemId = strmatch(dragLink, "item:(%d+)")
            local _, apiLink = GetItemInfo(tonumber(itemId) or 0)
            SendChatMessage("e " .. (apiLink or dragLink), "WHISPER", nil, entry.name)
            -- Delay so the server has time to process the equip before we re-query.
            local elapsed = 0
            local t = CreateFrame("Frame")
            t:SetScript("OnUpdate", function(self, dt)
                elapsed = elapsed + dt
                if elapsed >= 1.5 then
                    self:SetScript("OnUpdate", nil)
                    NS.CB_FetchInventory(dragKey, entry.name)
                end
            end)
        end
    end
    if NS.dragging.sourceCell and NS.dragging.sourceCell.icon then
        NS.dragging.sourceCell.icon:SetDesaturated(false)
    end
    NS.dragging = nil
    if NS.dragCapture then NS.dragCapture:Hide() end
    ResetCursor()
end
NS.CB_StopDrag = CB_StopDrag

-- ── Drag capture frame ───────────────────────────────────────────────────
-- Full-screen FULLSCREEN_DIALOG frame shown for the duration of a drag.
-- Absorbs all mouse events so no other frame receives OnEnter/OnLeave,
-- preventing WoW from resetting the cursor.  SetCursor is called once on
-- drag start; the capture frame keeps it alive by starving the reset path.
local function CB_GetDragCapture()
    if NS.dragCapture then return NS.dragCapture end

    local cap = CreateFrame("Frame", "CleanBotDragCapture", UIParent)
    cap:SetAllPoints(UIParent)
    cap:SetFrameStrata("FULLSCREEN_DIALOG")
    cap:EnableMouse(true)
    cap:Hide()

    cap:SetScript("OnUpdate", function()
        if not NS.dragging then return end
        local scale = UIParent:GetEffectiveScale()
        local mx, my = GetCursorPosition()
        mx, my = mx / scale, my / scale

        local slots = NS.botEquipSlots and NS.botEquipSlots[NS.dragging.key]
        local foundBtn = nil
        if slots then
            for _, btn in pairs(slots) do
                if btn:IsVisible() then
                    local l, r, b, t = btn:GetLeft(), btn:GetRight(), btn:GetBottom(), btn:GetTop()
                    if l and r and b and t and mx >= l and mx <= r and my >= b and my <= t then
                        foundBtn = btn; break
                    end
                end
            end
        end

        if foundBtn ~= NS.dragging.hoverBtn then
            if NS.dragging.hoverBtn then NS.dragging.hoverBtn:UnlockHighlight() end
            if foundBtn then foundBtn:LockHighlight() end
            NS.dragging.hoverBtn = foundBtn
        end
        NS.dragging.dropBtn = foundBtn
    end)

    cap:SetScript("OnMouseUp", function(self, btn)
        if btn == "LeftButton" then CB_StopDrag() end
    end)

    NS.dragCapture = cap
    return cap
end

-- ── Build or fetch the inventory frame for one bot ───────────────────────
NS.CB_GetInventoryFrame = function(key, botName)
    if NS.botInventoryFrames[key] then return NS.botInventoryFrames[key] end

    local frameW = FRAME_PAD * 2 + COLS * CELL_SIZE + (COLS - 1) * CELL_PAD
    local f = CreateFrame("Frame", "CleanBotInventory_" .. key, UIParent)
    f:SetWidth(frameW)
    f:SetHeight(300)   -- dynamic; resized in CB_RenderInventory
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    NS.CB_ApplyPanelSkin(f)
    f:Hide()

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText(botName .. "'s Inventory")
    f.title = title

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)
    if NS.ElvUI_S then NS.ElvUI_S:HandleCloseButton(closeBtn) end

    -- Slot counter label (bridge path only)
    local slotLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slotLabel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", FRAME_PAD, 8)
    slotLabel:Hide()
    f.slotLabel = slotLabel

    -- Container for item cells (re-used across renders)
    f.cells = {}

    NS.botInventoryFrames[key] = f
    return f
end

-- ── Render / re-render the grid from entry.inventory ─────────────────────
NS.CB_RenderInventory = function(key)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    local inv = entry.inventory or { items = {} }
    local f   = NS.botInventoryFrames[key]
    if not f then return end

    local items    = inv.items    or {}
    local bagTotal = inv.bagTotal             -- nil when whisper path
    local bagUsed  = inv.bagUsed

    local cellCount = bagTotal or #items      -- how many cells to draw

    -- ── Resize frame to fit grid ──────────────────────────────
    local rows    = math.max(1, math.ceil(cellCount / COLS))
    local gridH   = rows * CELL_SIZE + (rows - 1) * CELL_PAD
    local frameH  = HEADER_H + FRAME_PAD + gridH + FRAME_PAD + FOOTER_H
    f:SetHeight(frameH)

    -- ── Hide surplus cells from a previous render ─────────────
    for _, cell in ipairs(f.cells) do cell:Hide() end

    -- ── Draw cells ────────────────────────────────────────────
    for i = 1, cellCount do
        local cell = f.cells[i]
        if not cell then
            cell = CreateFrame("Button", nil, f)
            cell:SetSize(CELL_SIZE, CELL_SIZE)

            local bg = cell:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetTexture("Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag")
            bg:SetVertexColor(0.3, 0.3, 0.3, 0.8)
            cell.bg = bg

            local icon = cell:CreateTexture(nil, "ARTWORK")
            icon:SetAllPoints()
            icon:Hide()
            cell.icon = icon

            local countText = cell:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
            countText:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -2, 2)
            countText:Hide()
            cell.countText = countText

            cell:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

            cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            cell:SetScript("OnClick", function(self, btn)
                if btn == "RightButton" then CB_ShowInvMenu(self, key) end
            end)

            cell:SetScript("OnMouseDown", function(self, btn)
                if btn ~= "LeftButton" or not self.itemLink then return end
                local itemId   = strmatch(self.itemLink, "item:(%d+)")
                local iconPath = GetItemIcon(tonumber(itemId) or 0)
                NS.dragging = { link = self.itemLink, key = key, hoverBtn = nil, sourceCell = self }
                self.icon:SetDesaturated(true)
                GameTooltip:Hide()
                SetCursor(iconPath)
                CB_GetDragCapture():Show()
            end)

            cell:SetScript("OnMouseUp", function(self, btn)
                if btn == "LeftButton" then CB_StopDrag() end
            end)

            cell:SetScript("OnEnter", function(self)
                if self.itemLink then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetHyperlink(self.itemLink)
                end
            end)
            cell:SetScript("OnLeave", function() GameTooltip:Hide() end)

            f.cells[i] = cell
        end

        -- Position
        local col = (i - 1) % COLS
        local row = math.floor((i - 1) / COLS)
        local xOff = FRAME_PAD + col * (CELL_SIZE + CELL_PAD)
        local yOff = -(HEADER_H + FRAME_PAD + row * (CELL_SIZE + CELL_PAD))
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", f, "TOPLEFT", xOff, yOff)

        -- Fill or empty
        local item = items[i]
        if item then
            local tex = GetItemIcon(strmatch(item.link, "item:(%d+)") or 0)
            cell.icon:SetTexture(tex)
            cell.icon:Show()
            cell.itemLink = item.link
            if item.count > 1 then
                cell.countText:SetText(item.count)
                cell.countText:Show()
            else
                cell.countText:Hide()
            end
        else
            cell.icon:Hide()
            cell.countText:Hide()
            cell.itemLink = nil
        end

        cell:Show()
    end

    -- ── Slot counter (bridge path only) ──────────────────────
    if bagTotal then
        f.slotLabel:SetText((bagUsed or #items) .. "/" .. bagTotal)
        f.slotLabel:Show()
    else
        f.slotLabel:Hide()
    end
end

-- ── Open / toggle the inventory frame ────────────────────────────────────
NS.CB_ShowInventory = function(key, botName)
    local f = NS.CB_GetInventoryFrame(key, botName)
    if f:IsShown() then
        f:Hide()
    else
        f:ClearAllPoints()
        f:SetPoint("TOPRIGHT", CleanBotFrame, "TOPLEFT", -4, 0)
        NS.CB_RenderInventory(key)
        f:Show()
    end
end
