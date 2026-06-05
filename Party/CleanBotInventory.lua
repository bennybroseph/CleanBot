-- ============================================================
-- CleanBotInventory.lua  —  Per-bot inventory bag frame.
-- ============================================================
local NS = CleanBotNS

NS.botInventoryFrames = NS.botInventoryFrames or {}

local CELL_SIZE        = 37
local COLS             = 10
local CELL_PAD         = 3
local FOOTER_H         = 24
local BLIZZ_CELL_PAD = { top = 16, bottom = 0, left = 3, right = 0 }   -- extra cell padding on the Blizz path

local GOLD_ICON   = "|TInterface\\MoneyFrame\\UI-GoldIcon:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0|t"

local function FormatMoney(gold, silver, copper)
    if gold == 0 and silver == 0 and copper == 0 then return "0" .. COPPER_ICON end
    local parts = {}
    if gold   > 0 then parts[#parts + 1] = gold   .. GOLD_ICON   end
    if silver > 0 then parts[#parts + 1] = silver .. SILVER_ICON end
    if copper > 0 then parts[#parts + 1] = copper .. COPPER_ICON end
    local result = ""
    for i, p in ipairs(parts) do
        result = result .. (i > 1 and " " or "") .. p
    end
    return result
end

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

-- ── Equip an item, then refetch the bot's inventory ──────────────────────
-- Whispers the equip command and, after a short delay so the server can
-- apply the change, re-queries inventory. Shared by the right-click menu
-- and drag-and-drop paths.
local function CB_EquipItem(key, botName, link)
    local itemId     = strmatch(link, "item:(%d+)")
    local _, apiLink = GetItemInfo(tonumber(itemId) or 0)
    NS.CB_SendBotCommand(botName, "e " .. (apiLink or link))
    NS.CB_After(1.5, function() NS.CB_FetchInventory(key, botName) end)
end

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
            CB_EquipItem(key, entry.name, cell.itemLink)
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
        local entry = CleanBot_PartyBots[NS.dragging.key]
        if entry then
            CB_EquipItem(NS.dragging.key, entry.name, NS.dragging.link)
        end
    end
    if NS.dragging.sourceCell and NS.dragging.sourceCell.icon then
        NS.dragging.sourceCell.icon:SetDesaturated(false)
    end
    NS.dragging = nil
    NS.CB_EndCapture()
    ResetCursor()
end
NS.CB_StopDrag = CB_StopDrag

-- ── Drag tracking ────────────────────────────────────────────────────────
-- Runs while the shared capture frame (NS.CB_BeginCapture) is active during
-- an item drag: highlights whichever equip slot the cursor is over and
-- records it as the drop target.
local function CB_DragOnUpdate()
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
end

-- Begins an item drag: shows the shared capture frame wired to track the
-- drop target and finish on left-button release.
local function CB_BeginItemDrag()
    NS.CB_BeginCapture(CB_DragOnUpdate, function(btn)
        if btn == "LeftButton" then CB_StopDrag() end
    end)
end

-- ── Build or fetch the inventory frame for one bot ───────────────────────
NS.CB_GetInventoryFrame = function(key, botName)
    if NS.botInventoryFrames[key] then return NS.botInventoryFrames[key] end

    local frameW = NS.PADDING.frame.left + NS.PADDING.frame.right + COLS * CELL_SIZE + (COLS - 1) * CELL_PAD
    local f = CreateFrame("Frame", "CleanBotInventory_" .. key, UIParent)
    NS.CB_RegisterRootFrame(f)
    f:SetWidth(frameW)
    f:SetHeight(NS.FRAME_HEIGHT)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    if NS.ElvUI_S then
        f:StripTextures()
        NS.CB_ApplyOuterFrameSkin(f)
    else
        NS.CB_ApplyContainerFrameSkin(f)
    end
    local class = (CleanBot_PartyBots[key] and CleanBot_PartyBots[key].class) or "WARRIOR"
    NS.CB_ApplyInventoryTitleBar(f, botName, class)
    f:Hide()

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)
    if NS.ElvUI_S then NS.ElvUI_S:HandleCloseButton(closeBtn) end

    local FOOTER_Y       = NS.ElvUI_S and 8  or 13
    local FOOTER_LEFT_X  = NS.ElvUI_S and NS.PADDING.frame.left or (NS.PADDING.frame.left + 5)
    local FOOTER_RIGHT_X = NS.ElvUI_S and NS.PADDING.frame.right or (NS.PADDING.frame.right + 5)

    -- Slot counter label (bridge path only)
    local slotLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slotLabel:SetTextColor(1, 1, 1)
    slotLabel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", FOOTER_LEFT_X, FOOTER_Y)
    slotLabel:Hide()
    f.slotLabel = slotLabel

    -- Money label
    local moneyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moneyLabel:SetTextColor(1, 1, 1)
    moneyLabel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -FOOTER_RIGHT_X, FOOTER_Y)
    moneyLabel:Hide()
    f.moneyLabel = moneyLabel

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
    local blizzPad = NS.ElvUI_S and { top = 0, bottom = 0, left = 0, right = 0 } or BLIZZ_CELL_PAD
    local rows    = math.max(1, math.ceil(cellCount / COLS))
    local gridH   = rows * CELL_SIZE + (rows - 1) * CELL_PAD
    local frameH  = NS.PADDING.frame.top + blizzPad.top + gridH + NS.PADDING.frame.bottom + FOOTER_H
    f:SetHeight(frameH)
    if not NS.ElvUI_S then NS.CB_UpdateContainerTiles(f, rows) end

    -- ── Hide surplus cells from a previous render ─────────────
    for _, cell in ipairs(f.cells) do cell:Hide() end

    -- ── Draw cells ────────────────────────────────────────────
    for i = 1, cellCount do
        local cell = f.cells[i]
        if not cell then
            cell = CreateFrame("Button", nil, f)
            cell:SetSize(CELL_SIZE, CELL_SIZE)

            if NS.ElvUI_S then
                local bg = cell:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints()
                bg:SetTexture("Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag")
                bg:SetVertexColor(0.3, 0.3, 0.3, 0.8)
                cell.bg = bg
            end

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
                CB_BeginItemDrag()
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
        local xOff = NS.PADDING.frame.left + blizzPad.left + col * (CELL_SIZE + CELL_PAD)
        local yOff = -(NS.PADDING.frame.top + blizzPad.top + row * (CELL_SIZE + CELL_PAD))
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

    -- ── Money display ─────────────────────────────────────────
    local money = entry.money
    if money then
        f.moneyLabel:SetText(FormatMoney(money.gold or 0, money.silver or 0, money.copper or 0))
        f.moneyLabel:Show()
    else
        f.moneyLabel:Hide()
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
