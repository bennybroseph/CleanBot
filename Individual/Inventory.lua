-- ============================================================
-- Inventory.lua  —  Per-bot inventory bag frame.
-- ============================================================
local NS = CleanBotNS

NS.botInventoryFrames = NS.botInventoryFrames or {}
NS.botBankFrames      = NS.botBankFrames or {}

local CELL_SIZE = 37
local COLS      = 10
local CELL_PAD  = 3
local FOOTER_H  = 24

-- The bank reply has no slot-count, so the bank grid would collapse to the item
-- count alone. Reserve a minimum grid (a standard character bank = 28 slots) so a
-- sparse/empty bank still renders a proper grid and the loading overlay has room.
local BANK_MIN_CELLS = 28

-- Per-kind config for the shared item grid. The inventory and bank frames share
-- their build/render/patch/cell code; this table is the single branch point.
-- `dataField` selects the entry sub-table (entry.inventory / entry.bank); the
-- await/overlay/staging field names address the matching in-flight flags;
-- `menu` is filled in after the menu builders are defined below.
---@class CB_GridKind
---@field frames       table   The NS.botXFrames registry for this kind.
---@field dataField    string  entry sub-table holding { items, ... }.
---@field awaitField   string  entry boolean: a fetch is in flight.
---@field overlayField string  entry boolean: show the loading overlay.
---@field framePrefix  string  Global frame-name prefix.
---@field cellPrefix   string  Cell global-name prefix.
---@field titleNoun    string  Title-bar noun ("Inventory" / "Bank").
---@field showFooter   boolean Slot/money footer (inventory only).
---@field menu         fun(cell:table, key:string)  Right-click menu builder.
local KINDS = {
    inventory = {
        frames = NS.botInventoryFrames, dataField = "inventory",
        awaitField = "awaitingInventory", overlayField = "invOverlay",
        framePrefix = "CleanBotInventory_", cellPrefix = "CleanBotInvCell_",
        titleNoun = "Inventory", showFooter = true, minCells = 0,
    },
    bank = {
        frames = NS.botBankFrames, dataField = "bank",
        awaitField = "awaitingBank", overlayField = "bankOverlay",
        framePrefix = "CleanBotBank_", cellPrefix = "CleanBotBankCell_",
        titleNoun = "Bank", showFooter = false, minCells = BANK_MIN_CELLS,
    },
}

-- A grid is "locked" while its list fetch is in flight (the bot is streaming the items/bank
-- reply). Cell drag/menu/move actions are blocked then so the user can't act on a list
-- that's mid-refresh — the serial whisper queue keeps requests from interleaving, and the
-- lock keeps the user from piling new moves onto an in-flight reply.
---@param kind string  "inventory" or "bank".
---@param key  string  Bot name-key.
---@return boolean      Whether the grid's list fetch is in flight.
local function CB_GridLocked(kind, key)
    local entry = CleanBot_PartyBots[key]
    return entry ~= nil and entry[KINDS[kind].awaitField] == true
end

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

---@param gold   number  Gold amount.
---@param silver number  Silver amount (0–99).
---@param copper number  Copper amount (0–99).
---@return string         Money string with inline coin-icon texture codes.
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
---@param s string  Percent-encoded string.
---@return string   The decoded string.
local function UrlDecode(s)
    return (s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

-- ── Parse a single INV_ITEM / whisper line into {link, count} ────────────
-- The server appends " (soulbound)" and/or " xN" after the closing |r.
---@param raw string  One raw item line from the bot's "items" whisper reply.
---@return table|nil   Parsed item fields, or nil if the line could not be parsed.
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
---@param key     string  Bot name-key.
---@param botName string  Bot's display name (command target).
---@param link    string  Item link to equip.
local function CB_EquipItem(key, botName, link)
    NS.CB_SendBotCommand(botName, "e " .. NS.CB_CleanItemLink(link))
    NS.CB_After(1.5, function()
        NS.CB_FetchInventory(key, botName)
        -- Delayed equip-slot re-inspect: the immediate UNIT_INVENTORY_CHANGED read
        -- has a stale item link (texture fresh, link lagging), so the staleness
        -- guard in CB_RefreshEquipSlots skips it. By now the link has caught up, so
        -- this fresh read lands the correct icon + border — and covers the
        -- context-menu Equip path, which has no optimistic paint to hold in the gap.
        if NS.CB_QueueEquipRefresh then
            for _, slot in ipairs(NS.tabList or {}) do
                if slot.key == key and slot.unit and UnitExists(slot.unit) then
                    NS.CB_QueueEquipRefresh({{ key = key, unit = slot.unit }})
                    break
                end
            end
        end
    end)
end

-- ── Inventory cell right-click context menu ──────────────────────────────
local invMenu = CreateFrame("Frame", "CleanBotInvMenu", UIParent, "UIDropDownMenuTemplate")

---@param cell table   The inventory cell button the context menu opens from.
---@param key  string  Bot name-key the cell belongs to.
local function CB_ShowInvMenu(cell, key)
    if not cell.itemLink then return end
    local _, _, _, _, _, itemType, _, _, equipLoc = GetItemInfo(cell.itemLink)
    equipLoc = equipLoc or ""
    local isEquipment  = equipLoc ~= ""
    local isConsumable = itemType == "Consumable"
    local isQuest      = itemType == "Quest"

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
                    NS.CB_SetRarityOverlay(cell, nil)
                end
                NS.CB_ScheduleReconcile(key, entry.name)
            end
            UIDropDownMenu_AddButton(info)
        end

        -- Trade / Sell apply to everything except quest items (which can't be traded
        -- or vendored). Triggers are "t" and "s" — not "trade"/"sell" (see
        -- docs/playerbot-commands.md, "Chat commands are TRIGGERS, not action names").
        if not isQuest then
            local function addItemCmd(label, trigger, refetch)
                info.text = label
                info.func = function()
                    local entry = CleanBot_PartyBots[key]
                    if not entry then return end
                    NS.CB_SendBotCommand(entry.name, trigger .. " " .. NS.CB_CleanItemLink(cell.itemLink))
                    if refetch then NS.CB_ScheduleReconcile(key, entry.name) end
                end
                UIDropDownMenu_AddButton(info)
            end
            addItemCmd("Trade", "t", false)
            addItemCmd("Sell",  "s", true)
        end

        -- Deposit is on plain right-click while the bank is open (see the cell OnClick),
        -- so it is intentionally not a menu entry here.

        NS.CB_AddWowheadMenuButton(info, cell.itemLink)

        info.text = "Cancel"
        info.func = function() CloseDropDownMenus() end
        UIDropDownMenu_AddButton(info)
    end, "MENU")
    ToggleDropDownMenu(1, nil, invMenu, cell, 0, 0)
end

-- ── Bank cell context menu (shift+right-click; plain right-click withdraws) ──
-- Bank items can't be equipped/used/traded/sold, and Withdraw is plain right-click,
-- so the menu is just the Wowhead lookup and Cancel.
local bankMenu = CreateFrame("Frame", "CleanBotBankMenu", UIParent, "UIDropDownMenuTemplate")

---@param cell table   The bank cell button the context menu opens from.
---@param key  string  Bot name-key the cell belongs to.
local function CB_ShowBankMenu(cell, key)
    if not cell.itemLink then return end
    UIDropDownMenu_Initialize(bankMenu, function()
        local info = UIDropDownMenu_CreateInfo()
        info.notCheckable = true

        local function addBtn(label, fn)
            info.text = label
            info.func = fn
            UIDropDownMenu_AddButton(info)
        end

        -- Withdraw is on plain right-click (see the cell OnClick), so it is not a menu entry.
        NS.CB_AddWowheadMenuButton(info, cell.itemLink)

        addBtn("Cancel", function() CloseDropDownMenus() end)
    end, "MENU")
    ToggleDropDownMenu(1, nil, bankMenu, cell, 0, 0)
end

-- Resolve each kind's right-click menu now that both builders exist.
KINDS.inventory.menu = CB_ShowInvMenu
KINDS.bank.menu      = CB_ShowBankMenu

-- Optimistically moves an item from a grid cell to the first empty cell of the
-- destination frame, mirroring the server-side deposit/withdraw before the refetch
-- confirms (same eager-update spirit as the right-click "Use"). srcCell is blanked
-- and the item appears in destFrame immediately. No-op (no visual change) when the
-- destination is full or hidden, so the refetch is left to reflect reality.
---@param srcCell   table   The cell being moved out of.
---@param destFrame table?  The grid frame to move the item into.
---@param destCell  table?  The exact cell to drop into (a drag target); used when empty,
---                         otherwise the first empty cell is chosen (e.g. menu commands).
local function CB_OptimisticMove(srcCell, destFrame, destCell)
    if not (srcCell and srcCell.itemLink and destFrame and destFrame.cells) then return end

    local dest
    if destCell and destCell:IsShown() and not destCell.itemLink then
        dest = destCell  -- drop into the slot the user dragged to
    else
        for _, c in ipairs(destFrame.cells) do
            if c:IsShown() and not c.itemLink then dest = c; break end
        end
    end
    if not dest then return end  -- destination full/hidden; let the refetch reflect reality

    local link  = srcCell.itemLink
    local count = srcCell.countText:IsShown() and srcCell.countText:GetText() or nil

    -- Blank the source cell in place.
    srcCell.icon:Hide()
    srcCell.itemLink = nil
    srcCell.countText:Hide()
    NS.CB_ApplyItemVisuals(srcCell, nil)

    -- Fill the destination cell.
    dest.icon:SetTexture(GetItemIcon(strmatch(link, "item:(%d+)") or 0))
    dest.icon:Show()
    dest.itemLink = link
    NS.CB_ApplyItemVisuals(dest, link)
    if count then dest.countText:SetText(count); dest.countText:Show()
    else dest.countText:Hide() end
end

-- ── Deposit / withdraw between a bot's bags and bank ─────────────────────
-- Both directions share the "bank" trigger ("bank <link>" deposits from bags,
-- "bank -<link>" withdraws); both need a banker NPC near the bot (handled by the
-- no-banker popup in Bridge.lua). The command is ENQUEUED on the bot's serial whisper
-- queue (awaitingBankOp is its busy flag) so it can't interleave with a list reply;
-- the move is reflected eagerly right away, and a debounced reconcile (also enqueued)
-- confirms/corrects once the queue drains.
---@param key     string  Bot name-key.
---@param botName string  Bot's display name (command target).
---@param link    string  Item link to move.
---@param dir     string  "deposit" (bags→bank) or "withdraw" (bank→bags).
---@param srcCell  table?  The cell the item is moving out of (for the eager update).
---@param destCell table?  The exact destination cell (a drag target), if any.
NS.CB_BankMove = function(key, botName, link, dir, srcCell, destCell)
    local prefix = (dir == "withdraw") and "bank -" or "bank "
    local cmd    = prefix .. NS.CB_CleanItemLink(link)
    NS.CB_EnqueueRequest(key, function()
        local e = CleanBot_PartyBots[key]
        if e then e.awaitingBankOp = true; e.bankOpTimeout = 0 end
        NS.CB_SendBotCommandRaw(botName, cmd)  -- already running from the queue
    end)

    -- Eager move (immediate, regardless of queue position): withdraw lands in the
    -- inventory grid, deposit in the bank grid.
    local destFrame = (dir == "withdraw") and NS.botInventoryFrames[key] or NS.botBankFrames[key]
    CB_OptimisticMove(srcCell, destFrame, destCell)

    NS.CB_ScheduleReconcile(key, botName)
end

-- Shown when a bank list/deposit/withdraw runs without a banker NPC near the bot
-- (raised from the no-banker whisper handler in Bridge.lua). %s = bot name.
StaticPopupDialogs["CLEANBOT_NO_BANKER"] = {
    text         = "%s has no banker nearby. Move the bot next to a banker NPC, then try again.",
    button1      = OKAY,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
}

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

---@param link   string  Item link to test.
---@param slotId number  Equipment slot ID to test against.
---@return boolean        Whether the item can be equipped in that slot.
local function CB_ItemFitsSlot(link, slotId)
    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
    if not equipLoc or equipLoc == "" then return false end
    local valid = EQUIP_LOC_SLOTS[equipLoc]
    return valid ~= nil and valid[slotId] == true
end

---@param btn table   The equip slot button to tint.
---@param r   number  Red 0–1.
---@param g   number  Green 0–1.
---@param b   number  Blue 0–1.
local function CB_SetSlotTint(btn, r, g, b)
    local bgTex = btn.bgTex or btn.bg  -- bgTex = equip slot (bg is a Frame); bg = inv cell (bg is a Texture)
    if bgTex then bgTex:SetVertexColor(r, g, b) end
    if btn.icon and btn.icon:IsShown() then btn.icon:SetVertexColor(r, g, b) end
end

---@param btn table  The equip slot button whose drag-tint is reset.
local function CB_ResetSlotTint(btn)
    local bgTex = btn.bgTex or btn.bg
    if bgTex then bgTex:SetVertexColor(1, 1, 1) end
    if btn.icon then btn.icon:SetVertexColor(1, 1, 1) end
end

-- ── Drag stop (shared by cell OnMouseUp and capture frame OnMouseUp) ─────
--- Ends an inventory item drag, clearing slot tints and releasing the capture frame.
local function CB_StopDrag()
    if not NS.dragging then return end
    if NS.dragging.hoverBtn         then NS.dragging.hoverBtn:UnlockHighlight(); CB_ResetSlotTint(NS.dragging.hoverBtn) end
    if NS.dragging.hoverInvCell     then NS.dragging.hoverInvCell:UnlockHighlight() end
    if NS.dragging.hoverInvGridCell  then NS.dragging.hoverInvGridCell:UnlockHighlight() end
    if NS.dragging.hoverBankGridCell then NS.dragging.hoverBankGridCell:UnlockHighlight() end
    if NS.dragging.hoverTradeSlot and NS.tradeSlotOverlays then
        local ov = NS.tradeSlotOverlays[NS.dragging.hoverTradeSlot]
        if ov then ov:UnlockHighlight() end
    end

    local dropBtn      = NS.dragging.dropBtn
    local invDropCell  = NS.dragging.invDropCell
    local dropTradeSlot = NS.dragging.dropTradeSlot
    local src          = NS.dragging.sourceCell

    -- ── Cross-frame bank moves (server-authoritative; both frames re-fetch) ──
    -- A reconcile can lock either grid mid-drag; cancel the move if so (the dropped item
    -- snaps back and the in-flight refresh wins) rather than acting on stale state.
    local bankBusy = CB_GridLocked("inventory", NS.dragging.key) or CB_GridLocked("bank", NS.dragging.key)
    if NS.dragging.sourceKind == "bank" then
        -- Bank item dropped onto the inventory grid → withdraw (into the dropped-on slot).
        if NS.dragging.dropInvGridCell and not bankBusy then
            local entry = CleanBot_PartyBots[NS.dragging.key]
            if entry then NS.CB_BankMove(NS.dragging.key, entry.name, NS.dragging.link, "withdraw", src, NS.dragging.dropInvGridCell) end
        end
        if src then src.icon:SetDesaturated(false) end
        NS.dragging = nil; NS.CB_EndCapture(); ResetCursor(); return
    elseif NS.dragging.dropBankGridCell and not bankBusy then
        -- Inventory item dropped onto the bank grid → deposit (into the dropped-on slot).
        local entry = CleanBot_PartyBots[NS.dragging.key]
        if entry then NS.CB_BankMove(NS.dragging.key, entry.name, NS.dragging.link, "deposit", src, NS.dragging.dropBankGridCell) end
        if src then src.icon:SetDesaturated(false) end
        NS.dragging = nil; NS.CB_EndCapture(); ResetCursor(); return
    end

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
            NS.CB_SetRarityOverlay(src, nil)
        end
        -- Optimistic slot update (mirrors the unequip drag's inventory-cell
        -- update): show the dragged item's icon + rarity border immediately;
        -- the inspect-driven refresh confirms/corrects once the server applies.
        local link   = NS.dragging.link
        local itemId = strmatch(link, "item:(%d+)")
        dropBtn.icon:SetTexture(GetItemIcon(tonumber(itemId) or 0))
        dropBtn.icon:Show()
        if dropBtn.bg then dropBtn.bg:Hide() end
        dropBtn.itemLink = link
        local q = select(3, GetItemInfo(link))
        if q then NS.CB_SetQualityBorder(dropBtn, q) else NS.CB_ClearQualityBorder(dropBtn) end
        NS.CB_SetRarityOverlay(dropBtn, q)
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
        NS.CB_ApplyItemVisuals(src, src.itemLink)
        NS.CB_ApplyItemVisuals(invDropCell, invDropCell.itemLink)

        src.icon:SetDesaturated(false)
    elseif dropTradeSlot then
        -- ── Drop onto trade slot → tell bot to offer the item ─────────────
        -- "t" is the trade command; it toggles the item in the bot's trade window.
        local entry = CleanBot_PartyBots[NS.dragging.key]
        if entry then
            NS.CB_SendBotCommand(entry.name, "t " .. NS.CB_CleanItemLink(NS.dragging.link))
        end
        if src then src.icon:SetDesaturated(false) end
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
-- Hit-tests the cells of one grid frame against the cursor, returning the cell
-- under it (excluding `exclude`, e.g. the drag's own source cell). Used for the
-- inventory-swap, withdraw, and deposit drop targets.
---@param framesTbl table   NS.botInventoryFrames or NS.botBankFrames.
---@param key       string  Bot name-key.
---@param mx        number  Cursor X (UI-scaled).
---@param my        number  Cursor Y (UI-scaled).
---@param exclude   table?  A cell to ignore (the source cell).
---@return table|nil        The hovered cell, or nil.
local function CB_HitTestGrid(framesTbl, key, mx, my, exclude)
    local f = framesTbl and framesTbl[key]
    if not (f and f:IsShown()) then return nil end
    for _, cell in ipairs(f.cells) do
        if cell:IsShown() and cell ~= exclude then
            local l, r, b, t = cell:GetLeft(), cell:GetRight(), cell:GetBottom(), cell:GetTop()
            if l and r and b and t and mx >= l and mx <= r and my >= b and my <= t then
                return cell
            end
        end
    end
    return nil
end

-- Swaps the LockHighlight between the previously-hovered and newly-hovered cell,
-- writing the new cell back to NS.dragging[field].
---@param field string  The NS.dragging key tracking this hover target.
---@param cell  table?  The newly-hovered cell (or nil).
local function CB_UpdateHover(field, cell)
    if cell ~= NS.dragging[field] then
        if NS.dragging[field] then NS.dragging[field]:UnlockHighlight() end
        if cell then cell:LockHighlight() end
        NS.dragging[field] = cell
    end
end

-- Runs while the shared capture frame (NS.CB_BeginCapture) is active during an
-- item drag: highlights the equip slot / inventory cell / trade slot / bank cell
-- the cursor is over and records it as the drop target. Routing depends on where
-- the drag started (NS.dragging.sourceKind): a bank-sourced drag can only land on
-- the inventory grid (withdraw); an inventory-sourced drag keeps the equip/swap/
-- trade targets and can additionally land on the bank grid (deposit).
--- OnUpdate handler during an item drag: hit-tests targets and tints them.
local function CB_DragOnUpdate()
    if not NS.dragging then return end
    local scale = UIParent:GetEffectiveScale()
    local mx, my = GetCursorPosition()
    mx, my = mx / scale, my / scale

    -- ── Bank-sourced drag: inventory grid is the only valid target (withdraw) ──
    if NS.dragging.sourceKind == "bank" then
        local cell = CB_HitTestGrid(NS.botInventoryFrames, NS.dragging.key, mx, my, nil)
        CB_UpdateHover("hoverInvGridCell", cell)
        NS.dragging.dropInvGridCell = cell
        return
    end

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

    -- ── Inventory cell hit-test (swap; only when not over an equip slot) ──
    local foundCell = nil
    if not foundBtn then
        foundCell = CB_HitTestGrid(NS.botInventoryFrames, NS.dragging.key, mx, my, NS.dragging.sourceCell)
    end
    CB_UpdateHover("hoverInvCell", foundCell)
    NS.dragging.invDropCell = foundCell

    -- ── Trade slot hit-test (bot's side; only when trading this bot) ─────────
    -- TradeRecipientItem frames are not Buttons so we use a texture highlight
    -- rather than LockHighlight/UnlockHighlight.
    local foundTradeSlot = nil
    if not foundBtn and not foundCell then
        local activeKey = NS.CB_GetActiveTradeKey and NS.CB_GetActiveTradeKey()
        if activeKey and activeKey == NS.dragging.key and TradeFrame and TradeFrame:IsShown() then
            for i = 1, 6 do
                local slot = _G["TradeRecipientItem" .. i]
                if slot and slot:IsVisible() then
                    local l, r, b, t = slot:GetLeft(), slot:GetRight(), slot:GetBottom(), slot:GetTop()
                    if l and r and b and t and mx >= l and mx <= r and my >= b and my <= t then
                        foundTradeSlot = slot; break
                    end
                end
            end
        end
    end

    if foundTradeSlot ~= NS.dragging.hoverTradeSlot then
        local overlays = NS.tradeSlotOverlays
        if NS.dragging.hoverTradeSlot and overlays then
            local prev = overlays[NS.dragging.hoverTradeSlot]
            if prev then prev:UnlockHighlight() end
        end
        if foundTradeSlot and overlays then
            local next = overlays[foundTradeSlot]
            if next then next:LockHighlight() end
        end
        NS.dragging.hoverTradeSlot = foundTradeSlot
    end
    NS.dragging.dropTradeSlot = foundTradeSlot

    -- ── Bank grid hit-test (deposit; only when over nothing else) ──
    local foundBankCell = nil
    if not foundBtn and not foundCell and not foundTradeSlot then
        foundBankCell = CB_HitTestGrid(NS.botBankFrames, NS.dragging.key, mx, my, nil)
    end
    CB_UpdateHover("hoverBankGridCell", foundBankCell)
    NS.dragging.dropBankGridCell = foundBankCell
end

-- Begins an item drag: shows the shared capture frame wired to track the
-- drop target and finish on left-button release.
--- Begins an inventory item drag using the shared mouse-capture frame.
local function CB_BeginItemDrag()
    NS.CB_BeginCapture(CB_DragOnUpdate, function(btn)
        if btn == "LeftButton" then CB_StopDrag() end
    end)
end

-- ── Build or fetch the item-grid frame for one bot (inventory or bank) ────
---@param kind    string  "inventory" or "bank" (selects the KINDS config).
---@param key     string  Bot name-key.
---@param botName string  Bot's display name (used in the title bar).
---@return table           The bot's grid frame, created lazily on first call.
local function CB_GetGridFrame(kind, key, botName)
    local cfg = KINDS[kind]
    if cfg.frames[key] then return cfg.frames[key] end

    local padL   = NS.ElvUI_S and NS.PADDING.frame.left  or BLIZZ_INV_PAD.left
    local padR   = NS.ElvUI_S and NS.PADDING.frame.right or BLIZZ_INV_PAD.right
    local frameW = padL + padR + COLS * CELL_SIZE + (COLS - 1) * CELL_PAD
    local f = CreateFrame("Frame", cfg.framePrefix .. key, UIParent)
    f.kind = kind
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
    NS.CB_ApplyInventoryTitleBar(f, botName, class, cfg.titleNoun)
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

    -- ── Action buttons (just above the frame, top-right) ─────────────────────
    -- Small icon buttons mirroring the paperdoll bag-button pattern, sitting above the frame
    -- with their bottoms flush to its top edge, left of the close button. Laid out leftward.
    local ACTION_SIZE = 24
    --- Creates one icon action button above the inventory frame via CB_CreateIconButton
    --- (plain icon button — no panel background — handling naming, skin, icon + tooltip).
    ---@param name    string  Global frame name.
    ---@param iconTex string  Texture path for the button icon.
    ---@param tip     string  Tooltip line.
    ---@param onClick fun()   Click handler.
    ---@return table          The created Button.
    local function makeActionButton(name, iconTex, tip, onClick)
        local b = NS.CB_CreateIconButton(f, name, iconTex, ACTION_SIZE, onClick)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(tip, 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return b
    end

    -- Sort (rightmost): re-sorts the displayed grid via a forced full render.
    -- Both inventory and bank get a Sort button.
    local sortBtn = makeActionButton(cfg.framePrefix .. "SortBtn_" .. key, "Interface\\Icons\\Spell_Frost_Stun", "Sort", function()
        if kind == "bank" then NS.CB_RenderBank(key, true) else NS.CB_RenderInventory(key, true) end
    end)
    -- Right edge flush to the close button's left edge; the button sits just ABOVE the frame
    -- with its bottom edge flush to the frame's top edge (no padding). The Y nudge cancels the
    -- close button's own offset from the frame top so the bottom lands exactly on the edge.
    local closeYoff = NS.ElvUI_S and 2 or BLIZZ_CLOSE_Y
    sortBtn:SetPoint("BOTTOMRIGHT", closeBtn, "TOPLEFT", 0, -closeYoff)

    -- Refresh (left of Sort): force an immediate server re-fetch — the escape hatch when a
    -- whisper reply was lost and the list looks stale. Both kinds get it.
    local refreshBtn = makeActionButton(cfg.framePrefix .. "RefreshBtn_" .. key, "Interface\\Icons\\Ability_Hunter_Readiness", "Refresh", function()
        if kind == "bank" then NS.CB_FetchBank(key, botName) else NS.CB_FetchInventory(key, botName) end
    end)
    refreshBtn:SetPoint("RIGHT", sortBtn, "LEFT", 0, 0)

    -- Sell / Trade / Bank are inventory-only (the bank frame can't sell/trade/re-open itself).
    if kind == "inventory" then
        -- Sell Trash: vendor-sell the bot's grey items, then re-fetch. The command is "s gray" —
        -- the trigger is "s", not "sell" (see docs/playerbot-commands.md, "Chat commands are
        -- TRIGGERS, not action names").
        local sellBtn = makeActionButton("CleanBotInvSellBtn_" .. key, "Interface\\Icons\\INV_Misc_Coin_03",
            "Sell All Grey Items (Requires a Nearby Vendor)", function()
                local e       = CleanBot_PartyBots[key]
                local bn      = (e and e.name) or key
                NS.CB_SendBotCommand(bn, "s gray")
                NS.CB_ScheduleReconcile(key, bn)
            end)
        sellBtn:SetPoint("RIGHT", refreshBtn, "LEFT", 0, 0)

        -- Trade: open a trade window with the bot. InitiateTrade accepts a nearby party/raid
        -- member's name; TRADE_SHOW then drives the rest of the flow in Trade.lua.
        local tradeBtn = makeActionButton("CleanBotInvTradeBtn_" .. key, "Interface\\Icons\\INV_Misc_GroupLooking",
            "Trade", function()
                local e  = CleanBot_PartyBots[key]
                local bn = (e and e.name) or botName
                InitiateTrade(bn)
            end)
        tradeBtn:SetPoint("RIGHT", sellBtn, "LEFT", 0, 0)

        -- Bank: toggle the bot's bank frame (anchored to the left of this inventory frame).
        local bankBtn = makeActionButton("CleanBotInvBankBtn_" .. key, "Interface\\Icons\\INV_Box_01",
            "Bank", function() NS.CB_ToggleBank(key, botName) end)
        bankBtn:SetPoint("RIGHT", tradeBtn, "LEFT", 0, 0)
    end

    -- Footer (slot count + money) is inventory-only — the bank reply carries neither.
    if cfg.showFooter then
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
    end

    -- Container for item cells (re-used across renders)
    f.cells = {}

    cfg.frames[key] = f
    return f
end

NS.CB_GetInventoryFrame = function(key, botName) return CB_GetGridFrame("inventory", key, botName) end
NS.CB_GetBankFrame      = function(key, botName) return CB_GetGridFrame("bank",      key, botName) end

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

---@param items table  Array of parsed item entries; sorted in place by quality/slot.
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
---@param f        table   The inventory frame to populate.
---@param rawItems table   Array of raw item lines from the bot's reply.
---@param bagTotal number  Total bag slots.
---@param bagUsed  number  Used bag slots.
---@param entry    table   The bot roster entry (for money/header data).
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
                NS.CB_SetRarityOverlay(cell, nil)
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
            NS.CB_ApplyItemVisuals(cell, item.link)
            if item.count > 1 then
                cell.countText:SetText(item.count)
                cell.countText:Show()
            else
                cell.countText:Hide()
            end
        end
    end

    -- Update footer labels (inventory only — bank frame has no footer)
    if f.slotLabel then
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
end

-- ── Loading overlay (B+C) ────────────────────────────────────────────────
-- A semi-transparent dim + centred text drawn above the grid while an
-- inventory fetch is in flight (entry.awaitingInventory). Useful on both
-- paths but especially the whisper path, where replies trickle in over ~3s.
-- The overlay frame sits above the cells (higher frame level) but leaves mouse
-- input passing through (EnableMouse false) so the close button still works
-- and stale-but-correct data stays visible-yet-dimmed underneath.
---@param f table  An inventory frame from NS.botInventoryFrames.
---@return table   The frame's loading overlay (created lazily).
local function CB_EnsureLoadingOverlay(f)
    if f.loadingOverlay then return f.loadingOverlay end
    local ov = CreateFrame("Frame", nil, f)
    ov:SetAllPoints(f)
    ov:SetFrameLevel(f:GetFrameLevel() + 20)
    ov:EnableMouse(false)
    local dim = ov:CreateTexture(nil, "BACKGROUND")
    dim:SetAllPoints(ov)
    dim:SetTexture(0, 0, 0, 0.55)
    local txt = ov:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    txt:SetPoint("CENTER", ov, "CENTER", 0, 0)
    txt:SetTextColor(1, 0.82, 0)
    ov.text = txt
    ov:Hide()
    f.loadingOverlay = ov
    return ov
end

-- Show/hide the loading overlay. Text is "Refreshing..." when the grid already
-- holds rendered data (a re-fetch over existing items), else "Loading...".
---@param f  table    An inventory frame from NS.botInventoryFrames.
---@param on boolean  Whether a fetch is in flight.
NS.CB_SetInventoryLoading = function(f, on)
    if not f then return end
    if on then
        local ov = CB_EnsureLoadingOverlay(f)
        ov.text:SetText(f.rendered and "Refreshing..." or "Loading...")
        ov:Show()
    elseif f.loadingOverlay then
        f.loadingOverlay:Hide()
    end
end

-- ── Render / re-render an item grid from its entry sub-table ─────────────
---@param kind      string   "inventory" or "bank" (selects the KINDS config).
---@param key       string   Bot name-key whose grid frame should be (re)rendered.
---@param forceFull  boolean? Force a full re-sort + redraw (e.g. the Sort button) instead of
---                           the order-preserving patch path.
local function CB_RenderGrid(kind, key, forceFull)
    local cfg   = KINDS[kind]
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    -- Reflect (don't clear) the in-flight flag: the overlay shows while a fetch
    -- is pending and hides once it lands. This is deliberately not a clear point,
    -- so showing stale data mid-fetch keeps the overlay up. The flag is cleared at
    -- true data-landing points (whisper tick finalize, bridge INV_END, money reply).
    -- The overlay field (set by the fetch) suppresses the overlay for bridge-path
    -- refreshes of already-rendered grids.
    local lf = cfg.frames[key]
    if lf then
        NS.CB_SetInventoryLoading(lf,
            (entry[cfg.awaitField] and entry[cfg.overlayField]) and true or false)
    end

    local forceFullRender = forceFull or false
    -- pendingValidation is the equip optimistic-update check — inventory only.
    local validation = (kind == "inventory") and entry.pendingValidation or nil
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

    local inv = entry[cfg.dataField] or { items = {} }
    local f   = cfg.frames[key]
    if not f then return end

    local rawItems  = inv.items    or {}
    local bagTotal  = inv.bagTotal
    local bagUsed   = inv.bagUsed
    local cellCount = bagTotal or #rawItems
    -- Reserve a minimum grid (bank only) so a sparse/empty grid still renders rows.
    if cfg.minCells and cellCount < cfg.minCells then cellCount = cfg.minCells end

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
    -- FOOTER_H is kept for both kinds: on the Blizz path it is the bottom-border art
    -- region (the frame height must be 76 + rows*40 for the border to align with the
    -- last row), not just space for the inventory's slot/money labels.
    local frameH = padTop + gridH + padBottom + FOOTER_H
    f:SetHeight(frameH)
    if not NS.ElvUI_S then NS.CB_UpdateContainerTiles(f, rows) end

    -- ── Hide surplus cells from a previous render ─────────────
    for _, cell in ipairs(f.cells) do cell:Hide() end

    -- ── Draw cells ────────────────────────────────────────────
    for i = 1, cellCount do
        local cell = f.cells[i]
        if not cell then
            local cellName = cfg.cellPrefix .. key .. "_" .. i
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
            -- Persistent rarity overlay (Blizz path; no-op on ElvUI). Created hidden;
            -- shown and tinted to the item's quality on render. Leaves the template's
            -- own mouse-over highlight untouched.
            NS.CB_SetRarityOverlay(cell, nil)
            cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            -- No CB_ApplyQualityBackdrop — normTex vertex colour is used instead.
            cell:SetScript("OnClick", function(self, btn)
                if btn == "RightButton" then
                    if not self.itemLink then return end
                    -- With the bank open we mirror the default WoW bank: plain right-click
                    -- moves the item (bank cell → withdraw, inventory cell → deposit), and
                    -- the context menu is on shift+right-click. With the bank closed,
                    -- plain right-click opens the menu as usual.
                    local bankF    = NS.botBankFrames[key]
                    local bankOpen = bankF and bankF:IsShown()
                    local canMove  = (kind == "bank") or (kind == "inventory" and bankOpen)
                    if canMove and not IsShiftKeyDown() then
                        -- A move touches both grids — block while either is mid-refresh.
                        if CB_GridLocked("inventory", key) or CB_GridLocked("bank", key) then return end
                        local entry = CleanBot_PartyBots[key]
                        if entry then
                            local dir = (kind == "bank") and "withdraw" or "deposit"
                            NS.CB_BankMove(key, entry.name, self.itemLink, dir, self)
                        end
                    else
                        if CB_GridLocked(kind, key) then return end  -- mid whisper refresh
                        cfg.menu(self, key)
                    end
                elseif btn == "LeftButton" and IsShiftKeyDown() and self.itemLink then
                    ChatEdit_InsertLink(NS.CB_CleanItemLink(self.itemLink))
                end
            end)

            cell:SetScript("OnMouseDown", function(self, btn)
                if btn ~= "LeftButton" or not self.itemLink or IsShiftKeyDown() then return end
                if CB_GridLocked(kind, key) then return end  -- mid whisper refresh
                local itemId   = strmatch(self.itemLink, "item:(%d+)")
                local iconPath = GetItemIcon(tonumber(itemId) or 0)
                NS.dragging = { link = self.itemLink, key = key, hoverBtn = nil, sourceCell = self, sourceKind = kind }
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
            NS.CB_ApplyItemVisuals(cell, item.link)
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
            NS.CB_ApplyItemVisuals(cell, nil)
        end

        cell:Show()
    end

    f.rendered = true

    -- ── Footer (inventory only — bank carries no money/slot data) ──────────
    if cfg.showFooter then
        -- Slot counter (bridge path only)
        if bagTotal then
            f.slotLabel:SetText((bagUsed or #items) .. "/" .. bagTotal)
            f.slotLabel:Show()
        else
            f.slotLabel:Hide()
        end

        -- Money display
        local money = entry.money
        if money then
            f.moneyLabel:SetText(FormatMoney(money.gold or 0, money.silver or 0, money.copper or 0))
            f.moneyLabel:Show()
        else
            f.moneyLabel:Hide()
        end
    end
end

NS.CB_RenderInventory = function(key, forceFull) CB_RenderGrid("inventory", key, forceFull) end
NS.CB_RenderBank      = function(key, forceFull) CB_RenderGrid("bank",      key, forceFull) end

-- ── Open the inventory frame (always shows, never toggles) ───────────────
-- anchor is an optional frame to position relative to. When provided the
-- inventory is placed to its right; otherwise it defaults to CleanBotFrame's left.
---@param key     string  Bot name-key.
---@param botName string  Bot's display name.
---@param anchor  table?  Optional frame to anchor the window beside (e.g. TradeFrame).
NS.CB_ShowInventory = function(key, botName, anchor)
    local f = NS.CB_GetInventoryFrame(key, botName)
    f:ClearAllPoints()
    if anchor then
        f:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
    else
        f:SetPoint("TOPRIGHT", CleanBotFrame, "TOPLEFT", -4, 0)
    end
    NS.CB_RenderInventory(key)
    f:Show()
end

-- ── Toggle the inventory frame open/closed ────────────────────────────────
-- anchor is forwarded to CB_ShowInventory when opening.
---@param key     string  Bot name-key.
---@param botName string  Bot's display name.
---@param anchor  table?  Optional frame to anchor the window beside.
NS.CB_ToggleInventory = function(key, botName, anchor)
    local f = NS.CB_GetInventoryFrame(key, botName)
    if f:IsShown() then
        f:Hide()
    else
        NS.CB_ShowInventory(key, botName, anchor)
    end
end

-- ── Open the bank frame (anchored to the LEFT of the inventory frame) ────
-- Opening triggers the whisper-only bank fetch; the bank button lives on the
-- inventory frame, so that frame always exists to anchor against.
---@param key     string  Bot name-key.
---@param botName string  Bot's display name.
NS.CB_ShowBank = function(key, botName)
    local invF = NS.CB_GetInventoryFrame(key, botName)
    local f    = NS.CB_GetBankFrame(key, botName)
    f:ClearAllPoints()
    f:SetPoint("TOPRIGHT", invF, "TOPLEFT", -4, 0)
    NS.CB_FetchBank(key, botName)
    NS.CB_RenderBank(key)
    f:Show()
end

-- ── Toggle the bank frame open/closed ─────────────────────────────────────
---@param key     string  Bot name-key.
---@param botName string  Bot's display name.
NS.CB_ToggleBank = function(key, botName)
    local f = NS.CB_GetBankFrame(key, botName)
    if f:IsShown() then
        f:Hide()
    else
        NS.CB_ShowBank(key, botName)
    end
end
