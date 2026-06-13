-- ============================================================
-- UnitMenu.lua
-- Adds CleanBot entries to Blizzard's default party/raid unit right-click
-- menu (the UnitPopup system). The entries are shown only when the
-- right-clicked unit is a CleanBot-managed bot.
--
-- Loaded after Bridge.lua / Individual\* so every handler below exists:
--   CB_SendBotCommand, CB_RequestInventory, CB_ToggleQuests, CB_ManageBot.
-- ============================================================
local NS = CleanBotNS

-- Our custom button keys → the action each runs. `key` is strlower(name)
-- (the addon's bot key); `name` is the bot's display name. Inventory/Quest open
-- centered on screen ("CENTER") since this menu fires away from CleanBotFrame;
-- inventory routes through CB_RequestInventory so it fetches on open (the in-window
-- bag button does the same — CB_ToggleInventory alone only renders cached data).
local CB_HANDLERS = {
    CB_SUMMON    = function(_,   name) NS.CB_SendBotCommand(name, "summon") end,
    CB_INVENTORY = function(key, name) NS.CB_RequestInventory(key, name, "CENTER") end,
    CB_MANAGE    = function(key)       NS.CB_ManageBot(key) end,
    CB_QUESTLOG  = function(key, name) NS.CB_ToggleQuests(key, name, "CENTER") end,
}

-- ── 1. Register the menu buttons ────────────────────────────────────────────
-- `dist = 0` means no distance requirement (the actions route over the bridge /
-- whisper, not a proximity interaction).
UnitPopupButtons["CB_SUMMON"]    = { text = "Summon",    dist = 0 }
UnitPopupButtons["CB_INVENTORY"] = { text = "Inventory", dist = 0 }
UnitPopupButtons["CB_MANAGE"]    = { text = "Manage",    dist = 0 }
UnitPopupButtons["CB_QUESTLOG"]  = { text = "Quest Log", dist = 0 }

-- ── 2. Splice the buttons into the party/raid menus in the requested order ──
-- Inserts are by anchor-key lookup (recomputed each call) so they survive both
-- Blizzard list drift and the index shifts each prior insert causes.

--- Inserts `key` immediately after `anchor`; if `anchor` is absent, just before
--- "CANCEL"; if neither exists, appends.
local function insertAfter(menu, anchor, key)
    for i, v in ipairs(menu) do
        if v == anchor then table.insert(menu, i + 1, key); return end
    end
    for i, v in ipairs(menu) do
        if v == "CANCEL" then table.insert(menu, i, key); return end
    end
    menu[#menu + 1] = key
end

--- Inserts `key` just before "CANCEL" (or appends if there is none).
local function insertBeforeCancel(menu, key)
    for i, v in ipairs(menu) do
        if v == "CANCEL" then table.insert(menu, i, key); return end
    end
    menu[#menu + 1] = key
end

for _, which in ipairs({ "PARTY", "RAID_PLAYER" }) do
    local menu = UnitPopupMenus[which]
    if menu then
        table.insert(menu, 1, "CB_SUMMON")          -- first item
        insertAfter(menu, "INSPECT", "CB_MANAGE")   -- right after Inspect
        insertAfter(menu, "TRADE",   "CB_INVENTORY")-- right after Trade
        insertBeforeCancel(menu, "CB_QUESTLOG")     -- last, above Cancel
    end
end

--- Resolves the bot name behind the open unit menu. Party frames often pass
--- unit="partyN" with name=nil, so fall back to UnitName(unit).
---@return string? name
local function CB_MenuTargetName()
    local dropdownMenu = UIDROPDOWNMENU_INIT_MENU
    if not dropdownMenu then return nil end
    return dropdownMenu.name or (dropdownMenu.unit and UnitName(dropdownMenu.unit))
end

-- ── 3. Gate visibility to bots ──────────────────────────────────────────────
-- UnitPopup_HideButtons defaults every button to shown (1); our custom keys
-- match none of its hide conditions, so they would show for everyone. Hook it to
-- hide them whenever the target is not a CleanBot bot.
hooksecurefunc("UnitPopup_HideButtons", function()
    local dropdownMenu = UIDROPDOWNMENU_INIT_MENU
    if not dropdownMenu then return end
    local menu = UnitPopupMenus[dropdownMenu.which]
    if not menu then return end
    local name  = CB_MenuTargetName()
    local isBot = name and CleanBot_PartyBots[strlower(name)] ~= nil
    for index, value in ipairs(menu) do
        if CB_HANDLERS[value] then
            UnitPopupShown[UIDROPDOWNMENU_MENU_LEVEL][index] = isBot and 1 or 0
        end
    end
end)

-- ── 4. Dispatch clicks ──────────────────────────────────────────────────────
hooksecurefunc("UnitPopup_OnClick", function(self)
    local handler = CB_HANDLERS[self.value]
    if not handler then return end
    local name = CB_MenuTargetName()
    if not name then return end
    local key = strlower(name)
    if not CleanBot_PartyBots[key] then return end
    handler(key, name)
end)
