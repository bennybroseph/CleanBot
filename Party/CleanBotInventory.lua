-- ============================================================
-- CleanBotInventory.lua  —  Per-bot inventory bag frame.
-- ============================================================
local NS = CleanBotNS

NS.botInventoryFrames = NS.botInventoryFrames or {}

local CELL_SIZE = 37
local COLS      = 10
local CELL_PAD  = 3
local FOOTER_H  = 24

-- These replace NS.PADDING.frame.* entirely on the Blizz path — the art has
-- its own fixed spacing that doesn't respond to the user-tunable padding values.
local BLIZZ_INV_PAD = { top = 49, bottom = 6, left = 17, right = 12 }

-- Manual pixel positions for the slot-count and money footer labels (Blizz path only).
-- Relative to the frame's BOTTOMLEFT / BOTTOMRIGHT corners respectively.
-- Adjust these two constants to reposition the labels without touching layout logic.
local BLIZZ_LABEL_X = 20   -- inset from left (slot label) / right (money label) edge
local BLIZZ_LABEL_Y = 14   -- distance above the bottom edge
local BLIZZ_CLOSE_X = 0   -- X offset from TOPRIGHT for the close button (negative = left)
local BLIZZ_CLOSE_Y = -1   -- Y offset from TOPRIGHT for the close button (negative = down)

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
    NS.CB_SendBotCommand(botName, "e " .. NS.CB_CleanItemLink(link))
    NS.CB_After(1.5, function() NS.CB_FetchInventory(key, botName) end)
end

-- ── Inventory cell right-click context menu ──────────────────────────────
local invMenu = CreateFrame("Frame", "CleanBotInvMenu", UIParent, "UIDropDownMenuTemplate")

local function CB_ShowInvMenu(cell, key)
    if not cell.itemLink then return end
    local _, _, _, _, _, itemType, _, _, equipLoc = GetItemInfo(cell.itemLink)
    equipLoc = equipLoc or ""
    local isEquipment  = equipLoc ~= ""
    local isConsumable = itemType == "Consumable"

    UIDropDownMenu_Initialize(invMenu, function()
        local info = UIDropDownMenu_CreateInfo()
        info.notCheckable = true

        if isEquipment then
            info.text = "Equip"
            info.func = function()
                local entry = CleanBot_PartyBots[key]
                if not entry then return end
                CB_EquipItem(key, entry.name, cell.itemLink)
            end
            UIDropDownMenu_AddButton(info)
        end

        if isConsumable then
            info.text = "Use"
            info.func = function()
                local entry = CleanBot_PartyBots[key]
                if not entry then return end
                NS.CB_SendBotCommand(entry.name, "u " .. NS.CB_CleanItemLink(cell.itemLink))
                -- Optimistic update: decrement stack or clear cell immediately.
                local curCount = tonumber(cell.countText:GetText()) or 1
                if curCount > 1 then
                    cell.countText:SetText(curCount - 1)
                else
                    cell.icon:Hide()
                    cell.countText:Hide()
                    cell.itemLink = nil
                    NS.CB_ClearQualityBorder(cell)
                end
                NS.CB_After(1.5, function() NS.CB_FetchInventory(key, entry.name) end)
            end
            UIDropDownMenu_AddButton(info)
        end

        NS.CB_AddWowheadMenuButton(info, cell.itemLink)

        info.text = "Cancel"
        info.func = function() CloseDropDownMenus() end
        UIDropDownMenu_AddButton(info)
    end, "MENU")
    ToggleDropDownMenu(1, nil, invMenu, cell, 0, 0)
end

-- ── Equip slot compatibility ─────────────────────────────────────────────
local EQUIP_LOC_SLOTS = {
    INVTYPE_HEAD           = { [1]  = true },
    INVTYPE_NECK           = { [2]  = true },
    INVTYPE_SHOULDER       = { [3]  = true },
    INVTYPE_CLOAK          = { [15] = true },
    INVTYPE_CHEST          = { [5]  = true },
    INVTYPE_ROBE           = { [5]  = true },
    INVTYPE_SHIRT          = { [4]  = true },
    INVTYPE_TABARD         = { [19] = true },
    INVTYPE_WRIST          = { [9]  = true },
    INVTYPE_HAND           = { [10] = true },
    INVTYPE_WAIST          = { [6]  = true },
    INVTYPE_LEGS           = { [7]  = true },
    INVTYPE_FEET           = { [8]  = true },
    INVTYPE_FINGER         = { [11] = true, [12] = true },
    INVTYPE_TRINKET        = { [13] = true, [14] = true },
    INVTYPE_WEAPON         = { [16] = true, [17] = true },
    INVTYPE_WEAPONMAINHAND = { [16] = true },
    INVTYPE_2HWEAPON       = { [16] = true },
    INVTYPE_WEAPONOFFHAND  = { [17] = true },
    INVTYPE_HOLDABLE       = { [17] = true },
    INVTYPE_SHIELD         = { [17] = true },
    INVTYPE_RANGED         = { [18] = true },
    INVTYPE_THROWN         = { [18] = true },
    INVTYPE_RANGEDRIGHT    = { [18] = true },
    INVTYPE_RELIC          = { [18] = true },
}

local function CB_ItemFitsSlot(link, slotId)
    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
    if not equipLoc or equipLoc == "" then return false end
    local valid = EQUIP_LOC_SLOTS[equipLoc]
    return valid ~= nil and valid[slotId] == true
end

local function CB_SetSlotTint(btn, r, g, b)
    local bgTex = btn.bgTex or btn.bg  -- bgTex = equip slot (bg is a Frame); bg = inv cell (bg is a Texture)
    if bgTex then bgTex:SetVertexColor(r, g, b) end
    if btn.icon and btn.icon:IsShown() then btn.icon:SetVertexColor(r, g, b) end
end

local function CB_ResetSlotTint(btn)
    local bgTex = btn.bgTex or btn.bg
    if bgTex then bgTex:SetVertexColor(1, 1, 1) end
    if btn.icon then btn.icon:SetVertexColor(1, 1, 1) end
end

-- ── Drag stop (shared by cell OnMouseUp and capture frame OnMouseUp) ─────
local function CB_StopDrag()
    if not NS.dragging then return end
    if NS.dragging.hoverBtn     then NS.dragging.hoverBtn:UnlockHighlight(); CB_ResetSlotTint(NS.dragging.hoverBtn) end
    if NS.dragging.hoverInvCell then NS.dragging.hoverInvCell:UnlockHighlight() end

    local dropBtn    = NS.dragging.dropBtn
    local invDropCell = NS.dragging.invDropCell
    local src        = NS.dragging.sourceCell

    if dropBtn then
        -- ── Drop onto equip slot → equip item ─────────────────
        local entry = CleanBot_PartyBots[NS.dragging.key]
        if entry then
            entry.pendingValidation = { link = NS.dragging.link, expectPresent = false }
            CB_EquipItem(NS.dragging.key, entry.name, NS.dragging.link)
        end
        if src then
            src.icon:SetDesaturated(false)
            src.icon:Hide()
            src.itemLink = nil
            if src.countText then src.countText:Hide() end
            NS.CB_ClearQualityBorder(src)
        end
    elseif invDropCell and src then
        -- ── Drop onto inventory cell → visual swap ─────────────
        local tmpTex   = src.icon:GetTexture()
        local tmpLink  = src.itemLink
        local tmpCount = src.countText:IsShown() and src.countText:GetText() or nil

        if invDropCell.itemLink then
            src.icon:SetTexture(invDropCell.icon:GetTexture())
            src.icon:Show()
            src.itemLink = invDropCell.itemLink
            local tgt = invDropCell.countText:IsShown() and invDropCell.countText:GetText() or nil
            if tgt then src.countText:SetText(tgt); src.countText:Show()
            else src.countText:Hide() end
        else
            src.icon:Hide()
            src.itemLink = nil
            src.countText:Hide()
        end

        invDropCell.icon:SetTexture(tmpTex)
        invDropCell.icon:Show()
        invDropCell.itemLink = tmpLink
        if tmpCount then invDropCell.countText:SetText(tmpCount); invDropCell.countText:Show()
        else invDropCell.countText:Hide() end

        -- Sync quality borders to match swapped item links.
        if src.itemLink then
            local _, _, q = GetItemInfo(src.itemLink)
            if q then NS.CB_SetQualityBorder(src, q) else NS.CB_ClearQualityBorder(src) end
        else
            NS.CB_ClearQualityBorder(src)
        end
        if invDropCell.itemLink then
            local _, _, q = GetItemInfo(invDropCell.itemLink)
            if q then NS.CB_SetQualityBorder(invDropCell, q) else NS.CB_ClearQualityBorder(invDropCell) end
        else
            NS.CB_ClearQualityBorder(invDropCell)
        end

        src.icon:SetDesaturated(false)
    else
        -- ── Cancelled ─────────────────────────────────────────
        if src then src.icon:SetDesaturated(false) end
    end

    NS.dragging = nil
    NS.CB_EndCapture()
    ResetCursor()
end
NS.CB_StopDrag = CB_StopDrag

-- ── Drag tracking ────────────────────────────────────────────────────────
-- Runs while the shared capture frame (NS.CB_BeginCapture) is active during
-- an item drag: highlights whichever equip slot or empty inventory cell the
-- cursor is over and records it as the drop target.
local function CB_DragOnUpdate()
    if not NS.dragging then return end
    local scale = UIParent:GetEffectiveScale()
    local mx, my = GetCursorPosition()
    mx, my = mx / scale, my / scale

    -- ── Equip slot hit-test ───────────────────────────────────
    local slots    = NS.botEquipSlots and NS.botEquipSlots[NS.dragging.key]
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
        if NS.dragging.hoverBtn then
            NS.dragging.hoverBtn:UnlockHighlight()
            CB_ResetSlotTint(NS.dragging.hoverBtn)
        end
        if foundBtn then
            local isValid = CB_ItemFitsSlot(NS.dragging.link, foundBtn.slotId)
            NS.dragging.hoverBtnValid = isValid
            if isValid then
                foundBtn:LockHighlight()
            else
                CB_SetSlotTint(foundBtn, 1, 0.2, 0.2)
            end
        end
        NS.dragging.hoverBtn = foundBtn
    end
    -- Only allow drop on a compatible slot
    NS.dragging.dropBtn = (foundBtn and NS.dragging.hoverBtnValid) and foundBtn or nil

    -- ── Empty inventory cell hit-test (only when not over an equip slot) ──
    local foundCell = nil
    if not foundBtn then
        local invFrame = NS.botInventoryFrames and NS.botInventoryFrames[NS.dragging.key]
        if invFrame and invFrame:IsShown() then
            for _, cell in ipairs(invFrame.cells) do
                if cell:IsShown() and cell ~= NS.dragging.sourceCell then
                    local l, r, b, t = cell:GetLeft(), cell:GetRight(), cell:GetBottom(), cell:GetTop()
                    if l and r and b and t and mx >= l and mx <= r and my >= b and my <= t then
                        foundCell = cell; break
                    end
                end
            end
        end
    end

    if foundCell ~= NS.dragging.hoverInvCell then
        if NS.dragging.hoverInvCell then NS.dragging.hoverInvCell:UnlockHighlight() end
        if foundCell then foundCell:LockHighlight() end
        NS.dragging.hoverInvCell = foundCell
    end
    NS.dragging.invDropCell = foundCell
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

    local padL   = NS.ElvUI_S and NS.PADDING.frame.left  or BLIZZ_INV_PAD.left
    local padR   = NS.ElvUI_S and NS.PADDING.frame.right or BLIZZ_INV_PAD.right
    local frameW = padL + padR + COLS * CELL_SIZE + (COLS - 1) * CELL_PAD
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
        NS.CB_ApplyFrameSkin(f, 0)
    else
        NS.CB_ApplyContainerFrameSkin(f)
    end
    local class = (CleanBot_PartyBots[key] and CleanBot_PartyBots[key].class) or "WARRIOR"
    NS.CB_ApplyInventoryTitleBar(f, botName, class)
    f:Hide()

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    if NS.ElvUI_S then
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
        NS.ElvUI_S:HandleCloseButton(closeBtn)
    else
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", BLIZZ_CLOSE_X, BLIZZ_CLOSE_Y)
    end
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local FOOTER_Y       = NS.ElvUI_S and 8             or BLIZZ_LABEL_Y
    local FOOTER_LEFT_X  = NS.ElvUI_S and NS.PADDING.frame.left  or BLIZZ_LABEL_X
    local FOOTER_RIGHT_X = NS.ElvUI_S and NS.PADDING.frame.right or BLIZZ_LABEL_X

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

-- ── Inventory sort ───────────────────────────────────────────────────────
-- Equipment (by iLevel desc → quality desc → slot) → Consumables → Other → Grey
local SLOT_ORDER = {
    INVTYPE_HEAD            = 1,
    INVTYPE_NECK            = 2,
    INVTYPE_SHOULDER        = 3,
    INVTYPE_CLOAK           = 4,
    INVTYPE_CHEST           = 5,  INVTYPE_ROBE = 5,
    INVTYPE_SHIRT           = 6,
    INVTYPE_TABARD          = 7,
    INVTYPE_WRIST           = 8,
    INVTYPE_HAND            = 9,
    INVTYPE_WAIST           = 10,
    INVTYPE_LEGS            = 11,
    INVTYPE_FEET            = 12,
    INVTYPE_FINGER          = 13,
    INVTYPE_TRINKET         = 14,
    INVTYPE_WEAPON          = 15,  INVTYPE_WEAPONMAINHAND = 15,  INVTYPE_2HWEAPON = 15,
    INVTYPE_WEAPONOFFHAND   = 16,  INVTYPE_HOLDABLE = 16,        INVTYPE_SHIELD = 16,
    INVTYPE_RANGED          = 17,  INVTYPE_THROWN = 17,          INVTYPE_RANGEDRIGHT = 17,
    INVTYPE_RELIC           = 18,
}

local function CB_SortInventory(items)
    local enriched = {}
    for i, item in ipairs(items) do
        local _, _, quality, iLevel, _, itemType, _, _, equipLoc = GetItemInfo(item.link)
        quality  = quality  or 0
        equipLoc = equipLoc or ""
        local cat
        if quality == 0 then
            cat = 4
        elseif equipLoc ~= "" then
            cat = 1
        elseif itemType == "Consumable" then
            cat = 2
        else
            cat = 3
        end
        enriched[#enriched + 1] = {
            item      = item,
            cat       = cat,
            quality   = quality,
            iLevel    = iLevel or 0,
            slotOrder = SLOT_ORDER[equipLoc] or 99,
            origIdx   = i,
        }
    end

    table.sort(enriched, function(a, b)
        if a.cat ~= b.cat then return a.cat < b.cat end
        if a.cat == 1 then
            if a.iLevel   ~= b.iLevel   then return a.iLevel   > b.iLevel   end
            if a.quality  ~= b.quality  then return a.quality  > b.quality  end
            if a.slotOrder ~= b.slotOrder then return a.slotOrder < b.slotOrder end
        end
        return a.origIdx < b.origIdx
    end)

    local sorted = {}
    for _, e in ipairs(enriched) do sorted[#sorted + 1] = e.item end
    return sorted
end

-- ── Patch an already-rendered inventory grid without re-sorting ───────────
-- Diffs current visual cell state against fresh raw items by item ID.
-- Blanks cells whose item was removed, fills new items into empty cells,
-- updates stack counts for items that remain.
local function CB_PatchInventory(f, rawItems, bagTotal, bagUsed, entry)
    -- Build visual map: itemId → { cell, ... }
    -- Use cell.itemLink directly — IsShown() is unreliable when the parent frame is hidden.
    local visualById = {}
    for _, cell in ipairs(f.cells) do
        if cell.itemLink then
            local id = strmatch(cell.itemLink, "item:(%d+)")
            if id then
                if not visualById[id] then visualById[id] = {} end
                visualById[id][#visualById[id] + 1] = cell
            end
        end
    end

    -- Build new map: itemId → { item, ... }
    local newById = {}
    for _, item in ipairs(rawItems) do
        local id = strmatch(item.link, "item:(%d+)")
        if id then
            if not newById[id] then newById[id] = {} end
            newById[id][#newById[id] + 1] = item
        end
    end

    -- Update stack counts and blank excess cells for each item ID
    for id, cells in pairs(visualById) do
        local newItems = newById[id] or {}
        for i, cell in ipairs(cells) do
            if newItems[i] then
                if newItems[i].count > 1 then
                    cell.countText:SetText(newItems[i].count)
                    cell.countText:Show()
                else
                    cell.countText:Hide()
                end
            else
                cell.icon:Hide()
                cell.itemLink = nil
                cell.countText:Hide()
                NS.CB_ClearQualityBorder(cell)
            end
        end
    end

    -- Fill newly arrived items into the first available empty cells
    local emptyIdx = 1
    local function nextEmptyCell()
        while emptyIdx <= #f.cells do
            local cell = f.cells[emptyIdx]
            emptyIdx = emptyIdx + 1
            if not cell.itemLink then
                cell:Show()  -- may be hidden if frame was closed; parent show makes it visible
                return cell
            end
        end
    end

    for id, items in pairs(newById) do
        local visualCount = visualById[id] and #visualById[id] or 0
        for i = visualCount + 1, #items do
            local cell = nextEmptyCell()
            if not cell then break end
            local item = items[i]
            cell.icon:SetTexture(GetItemIcon(strmatch(item.link, "item:(%d+)") or 0))
            cell.icon:Show()
            cell.itemLink = item.link
            local _, _, quality = GetItemInfo(item.link)
            if quality then NS.CB_SetQualityBorder(cell, quality) end
            if item.count > 1 then
                cell.countText:SetText(item.count)
                cell.countText:Show()
            else
                cell.countText:Hide()
            end
        end
    end

    -- Update footer labels
    if bagTotal then
        f.slotLabel:SetText((bagUsed or #rawItems) .. "/" .. bagTotal)
        f.slotLabel:Show()
    else
        f.slotLabel:Hide()
    end
    local money = entry.money
    if money then
        f.moneyLabel:SetText(FormatMoney(money.gold or 0, money.silver or 0, money.copper or 0))
        f.moneyLabel:Show()
    else
        f.moneyLabel:Hide()
    end
end

-- ── Render / re-render the grid from entry.inventory ─────────────────────
NS.CB_RenderInventory = function(key)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    local forceFullRender = false
    local validation = entry.pendingValidation
    if validation then
        entry.pendingValidation = nil
        local expectId = strmatch(validation.link, "item:(%d+)")
        local items    = (entry.inventory and entry.inventory.items) or {}
        local found    = false
        for _, item in ipairs(items) do
            if strmatch(item.link, "item:(%d+)") == expectId then found = true; break end
        end
        if found ~= validation.expectPresent then
            -- Server disagreed with optimistic update — force full re-render to correct state
            forceFullRender = true
        end
        -- Do not return early on success: fall through to the patch path so any
        -- server-side side effects (e.g. a displaced item entering inventory when
        -- equipping over an existing item) are reflected visually.
    end

    local inv = entry.inventory or { items = {} }
    local f   = NS.botInventoryFrames[key]
    if not f then return end

    local rawItems  = inv.items    or {}
    local bagTotal  = inv.bagTotal
    local bagUsed   = inv.bagUsed
    local cellCount = bagTotal or #rawItems

    -- ── Patch path: frame already rendered with the same cell count ───────
    if not forceFullRender and f.rendered and #f.cells == cellCount then
        CB_PatchInventory(f, rawItems, bagTotal, bagUsed, entry)
        return
    end

    local items = CB_SortInventory(rawItems)

    -- ── Resize frame to fit grid ──────────────────────────────
    local padTop    = NS.ElvUI_S and NS.PADDING.frame.top    or BLIZZ_INV_PAD.top
    local padBottom = NS.ElvUI_S and NS.PADDING.frame.bottom or BLIZZ_INV_PAD.bottom
    local padLeft   = NS.ElvUI_S and NS.PADDING.frame.left   or BLIZZ_INV_PAD.left
    local rows   = math.max(1, math.ceil(cellCount / COLS))
    local gridH  = rows * CELL_SIZE + (rows - 1) * CELL_PAD
    local frameH = padTop + gridH + padBottom + FOOTER_H
    f:SetHeight(frameH)
    if not NS.ElvUI_S then NS.CB_UpdateContainerTiles(f, rows) end

    -- ── Hide surplus cells from a previous render ─────────────
    for _, cell in ipairs(f.cells) do cell:Hide() end

    -- ── Draw cells ────────────────────────────────────────────
    for i = 1, cellCount do
        local cell = f.cells[i]
        if not cell then
            local cellName = "CleanBotInvCell_" .. key .. "_" .. i
            cell = CreateFrame("Button", cellName, f, "ItemButtonTemplate")
            cell:SetSize(CELL_SIZE, CELL_SIZE)

            -- NormalTexture (UI-Quickslot2) provides the rounded slot look.
            -- Kept visible on Blizz path as an empty-slot indicator (standard WoW
            -- bag behaviour). CB_SkinInventoryCell's StripTextures hides it on ElvUI.
            -- CB_SetQualityBorder tints it with the item quality colour when equipped.
            cell.normTex = _G[cellName .. "NormalTexture"]

            local icon = _G[cellName .. "IconTexture"]
            icon:SetAllPoints()
            icon:Hide()
            cell.icon = icon

            -- $parentCount is the template's stack-count FontString (BOTTOMRIGHT corner).
            cell.countText = _G[cellName .. "Count"]

            NS.CB_SkinInventoryCell(cell)
            cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            -- No CB_ApplyQualityBackdrop — normTex vertex colour is used instead.
            cell:SetScript("OnClick", function(self, btn)
                if btn == "RightButton" then
                    CB_ShowInvMenu(self, key)
                elseif btn == "LeftButton" and IsShiftKeyDown() and self.itemLink then
                    ChatEdit_InsertLink(NS.CB_CleanItemLink(self.itemLink))
                end
            end)

            cell:SetScript("OnMouseDown", function(self, btn)
                if btn ~= "LeftButton" or not self.itemLink or IsShiftKeyDown() then return end
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
        local col  = (i - 1) % COLS
        local row  = math.floor((i - 1) / COLS)
        local xOff = padLeft + col * (CELL_SIZE + CELL_PAD)
        local yOff = -(padTop + row * (CELL_SIZE + CELL_PAD))
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", f, "TOPLEFT", xOff, yOff)

        -- Fill or empty
        local item = items[i]
        if item then
            local tex = GetItemIcon(strmatch(item.link, "item:(%d+)") or 0)
            cell.icon:SetTexture(tex)
            cell.icon:Show()
            cell.itemLink = item.link
            local _, _, quality = GetItemInfo(item.link)
            if quality then NS.CB_SetQualityBorder(cell, quality) end
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
            NS.CB_ClearQualityBorder(cell)
        end

        cell:Show()
    end

    f.rendered = true

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
