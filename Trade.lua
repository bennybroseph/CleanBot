-- ============================================================
-- Trade.lua  —  Automatic inventory on trade.
--
-- When the player initiates a trade with a tracked bot:
--   • Their inventory frame opens automatically.
--   • Dragging an item from the inventory onto a trade slot
--     whispers "give <itemlink>" to offer it for trade.
--   • Right-clicking a filled trade slot whispers "give <itemlink>"
--     to remove it (give toggles the item on/off).
--   • The inventory frame closes when the trade window closes.
-- ============================================================

local NS = CleanBotNS

-- ── Active trade state ───────────────────────────────────────────────────
-- The bot key resolved when TRADE_SHOW fires; held so TRADE_CLOSED and
-- the drag/right-click paths can reference the same bot without re-resolving.
local activeTradeKey = nil  ---@type string|nil

-- Accessor used by Inventory.lua's drag hit-test to check whether
-- a trade with a specific bot is currently active.
---@return string|nil  The active trade partner's key, or nil when no bot trade is open.
NS.CB_GetActiveTradeKey = function()
    return activeTradeKey
end

-- ── Right-click overlays on the bot's trade slots ────────────────────────
-- TradeRecipientItem frames are plain Frames (not Buttons) so HookScript
-- "OnClick" is unavailable. Instead we lay invisible Buttons on top of each
-- slot that capture right-clicks and forward give commands to the bot.
-- Left-clicks are intentionally not consumed so normal trade UI behaviour
-- (tooltip on hover, etc.) is unaffected.
-- Slots to cover: 6 regular trade slots + the no-trade enchant slot (index 7).
-- GetTradeTargetItemLink(7) corresponds to the enchant/no-trade slot.
local TRADE_SLOTS = {
    { frame = "TradeRecipientItem1", index = 1 },
    { frame = "TradeRecipientItem2", index = 2 },
    { frame = "TradeRecipientItem3", index = 3 },
    { frame = "TradeRecipientItem4", index = 4 },
    { frame = "TradeRecipientItem5", index = 5 },
    { frame = "TradeRecipientItem6", index = 6 },
    { frame = "TradeRecipientItem7", index = 7 },
}

-- Keyed by slot frame reference so CB_DragOnUpdate can LockHighlight/UnlockHighlight
-- the correct overlay during a drag without touching native mouse events.
NS.tradeSlotOverlays = {}

--- Creates the invisible right-click Button overlays over the partner's trade slots.
--- Called once at PLAYER_LOGIN; overlays start hidden and are shown during bot trades.
local function CB_CreateTradeSlotOverlays()
    for _, entry in ipairs(TRADE_SLOTS) do
        local slot = _G[entry.frame]
        if slot then
            local slotIndex = entry.index
            -- The slot frame is 153x37 (icon + name text). The 37x37 icon child is
            -- named TradeRecipientItem{i}ItemButton — anchor the overlay to that so
            -- the highlight covers only the icon, matching native hover behaviour.
            local iconBtn = _G[entry.frame .. "ItemButton"] or slot
            local overlay = CreateFrame("Button", "CleanBotTradeOverlay" .. slotIndex, UIParent)
            overlay:SetFrameStrata("HIGH")
            overlay:SetAllPoints(iconBtn)
            overlay:RegisterForClicks("RightButtonUp")
            NS.tradeSlotOverlays[slot] = overlay

            -- Highlight texture — mirrors the native slot hover since our overlay
            -- blocks mouse events from reaching the underlying frame.
            -- ElvUI uses its flat normTex at low alpha; Blizz uses ButtonHilight-Square.
            local hl = overlay:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            if NS.ElvUI_E and NS.ElvUI_E.media and NS.ElvUI_E.media.normTex then
                hl:SetTexture(NS.ElvUI_E.media.normTex)
                hl:SetVertexColor(1, 1, 1, 0.3)
            else
                hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
                hl:SetBlendMode("ADD")
            end

            overlay:SetScript("OnEnter", function(self)
                local link = GetTradeTargetItemLink(slotIndex)
                if not link then return end
                if slot.LockHighlight then slot:LockHighlight() end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(link)
                GameTooltip:Show()
            end)
            overlay:SetScript("OnLeave", function(self)
                if slot.UnlockHighlight then slot:UnlockHighlight() end
                GameTooltip:Hide()
            end)

            overlay:SetScript("OnClick", function(self, button)
                if not activeTradeKey then return end

                -- GetTradeTargetItemLink is the correct 3.3.5a API for the partner's slots.
                local link = GetTradeTargetItemLink(slotIndex)
                if not link then return end

                local botEntry = CleanBot_PartyBots and CleanBot_PartyBots[activeTradeKey]
                if botEntry then
                    NS.CB_SendBotCommand(botEntry.name, "give " .. NS.CB_CleanItemLink(link))
                end
            end)

            -- Hidden by default; shown only while an active bot trade is open.
            overlay:Hide()
        end
    end
end

-- Shows or hides all trade slot overlays. Called on TRADE_SHOW (bot trade
-- confirmed) and TRADE_CLOSED so overlays never intercept outside of a trade.
---@param visible boolean  true to show overlays, false to hide them.
local function CB_SetTradeOverlaysVisible(visible)
    for _, overlay in pairs(NS.tradeSlotOverlays) do
        if visible then overlay:Show() else overlay:Hide() end
    end
end

-- ── Event handler ────────────────────────────────────────────────────────
local eventFrame = CreateFrame("Frame", "CleanBotTradeFrame")

eventFrame:RegisterEvent("TRADE_SHOW")
eventFrame:RegisterEvent("TRADE_CLOSED")

eventFrame:SetScript("OnEvent", function(self, event)
    if event == "TRADE_SHOW" then
        -- TradeFrameRecipientNameText holds the name of the trade partner.
        local recipientName = TradeFrameRecipientNameText and
            TradeFrameRecipientNameText:GetText()
        if not recipientName or recipientName == "" then return end

        local key   = strlower(recipientName)
        local entry = CleanBot_PartyBots and CleanBot_PartyBots[key]
        if not entry then return end  -- not one of our bots, do nothing

        activeTradeKey = key
        CB_SetTradeOverlaysVisible(true)
        NS.CB_FetchInventory(key, entry.name)
        NS.CB_ShowInventory(key, entry.name, TradeFrame)

    elseif event == "TRADE_CLOSED" then
        CB_SetTradeOverlaysVisible(false)
        if not activeTradeKey then return end

        local f = NS.botInventoryFrames and NS.botInventoryFrames[activeTradeKey]
        if f and f:IsShown() then f:Hide() end

        activeTradeKey = nil
    end
end)

-- Hook trade slots once the UI is fully loaded.
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:HookScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        CB_CreateTradeSlotOverlays()
    end
end)
