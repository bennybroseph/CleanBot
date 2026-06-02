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
