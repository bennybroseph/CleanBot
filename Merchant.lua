-- ============================================================
-- Merchant.lua  —  Vendor frame extension.
--
-- While a merchant is open AND the player has bots in the group, a vertical column
-- of 2D portrait tabs (the player + each bot) runs down the merchant frame's right edge:
--   • Selecting a BOT tab and right-clicking a vendor item makes that bot BUY it.
--   • The PLAYER tab (selected by default) is a passthrough — the default UI buys.
--   • Right-clicking a bot's portrait opens its inventory (Inventory.lua), where a
--     plain right-click on an item sells it (uncommon+ asks first — no buyback).
-- In a raid the portrait column becomes a top-center dropdown plus an "Inventory" button.
-- A cog at the top of the column (always shown while at a vendor with bots; its panel
-- fades in on hover) holds the "Enable" toggle so the feature can never lock you out.
--
-- Mirrors Trade.lua's overlay-interception pattern: invisible HIGH-strata right-click
-- Buttons over the Blizzard MerchantItem buttons, shown only while a bot is selected
-- (so the player's own purchase is never triggered). We never call BuyMerchantItem —
-- the bot is whispered "b <link>" — so there is no taint/secure concern.
-- ============================================================

local NS = CleanBotNS

-- ── State ────────────────────────────────────────────────────────────────────
local merchantOpen = false      -- between MERCHANT_SHOW and MERCHANT_CLOSED
local selectedKey  = "player"   -- "player" (don't interfere) | strlower(botName)
local built        = false      -- overlays + strip/cog created once at PLAYER_LOGIN

-- Widgets (assigned in the build step; referenced as upvalues by the helpers below).
local stripContainer, cogBtn, cogPanel, dropdown, invBtn
local tabPool       = {}         -- [key] = portrait tab Button (pooled across rebuilds)
local merchantOverlays = {}      -- [i]   = right-click overlay over MerchantItem{i}ItemButton
local openedInvKeys = {}         -- bot inventory windows we opened, hidden on MERCHANT_CLOSED

local PORTRAIT_SIZE   = 32
local MERCHANT_SLOTS  = MERCHANT_ITEMS_PER_PAGE or 10

--- Accessor for Inventory.lua's cell right-click: true while a vendor is open so a
--- plain right-click on a bot inventory item sells it (mirrors NS.CB_GetActiveTradeKey).
---@return boolean
NS.CB_IsMerchantOpen = function() return merchantOpen end

-- ── Roster helpers ───────────────────────────────────────────────────────────
--- True when the player has at least one tracked bot in the current party/raid.
---@return boolean
local function CB_HasBots()
    local found = false
    NS.CB_ForEachGroupMember(function(_, name)
        if not found and name and CleanBot_PartyBots[strlower(name)] then found = true end
    end)
    return found
end

--- True if the bot looks close enough to interact with the open vendor; otherwise warns the user
--- with Blizzard-style red error text and returns false. There's no direct bot↔vendor distance in
--- 3.3.5a, so we proxy off the PLAYER (who is necessarily at the vendor while it's open) via
--- CheckInteractDistance — index 2 = Trade range (~11yd). nil also covers out-of-visibility bots.
---@param botName string?
---@return boolean inRange
NS.CB_CheckBotVendorRange = function(botName)
    local unit = botName and NS.CB_FindPartyUnit(botName)
    if unit and CheckInteractDistance(unit, 2) then return true end
    UIErrorsFrame:AddMessage((botName or "Bot") .. " is too far from the vendor.", 1.0, 0.1, 0.1)
    return false
end

-- ── Buy overlays ─────────────────────────────────────────────────────────────
--- Shows each overlay only when the feature is enabled, a bot is selected, we're on the
--- buy tab (not buyback), and the merchant slot button is shown. One gate covers
--- player-selected, disabled, buyback tab, and empty/partial-page (hidden) slots.
local function CB_RefreshOverlays()
    local active = merchantOpen and NS.vendorEnabled
        and selectedKey ~= "player" and MerchantFrame.selectedTab == 1
    for _, overlay in ipairs(merchantOverlays) do
        -- Don't gate on a cached item link: it can be nil for a beat after the vendor opens,
        -- which left the overlay hidden exactly when a bot was first selected (so the first buy
        -- silently failed). The OnClick re-checks the link, so an unloaded slot is a harmless no-op.
        if active and overlay.iconBtn:IsShown() then overlay:Show() else overlay:Hide() end
    end
end

local function CB_HideOverlays()
    for _, overlay in ipairs(merchantOverlays) do overlay:Hide() end
end

--- Creates the invisible right-click overlays over MerchantItem{i}ItemButton. The
--- item button's GetID() is the LIVE merchant index (set every MerchantFrame_Update),
--- so paging is handled automatically. Called once at PLAYER_LOGIN. (Mirrors Trade.lua.)
local function CB_CreateMerchantOverlays()
    for i = 1, MERCHANT_SLOTS do
        local iconBtn = _G["MerchantItem" .. i .. "ItemButton"] or _G["MerchantItem" .. i]
        if iconBtn then
            local overlay = CreateFrame("Button", "CleanBotMerchantOverlay" .. i, UIParent)
            overlay:SetFrameStrata("HIGH")
            overlay:SetAllPoints(iconBtn)
            overlay:RegisterForClicks("RightButtonUp")
            overlay.iconBtn = iconBtn

            -- No highlight of our own: the tooltip's OnEnter LockHighlights the underlying
            -- MerchantItem button, so adding one here doubles up the merchant's native glow.
            NS.CB_AttachTooltip(overlay, function(tt)
                local link = GetMerchantItemLink(iconBtn:GetID())
                if not link then return false end
                if iconBtn.LockHighlight then iconBtn:LockHighlight() end
                tt:SetHyperlink(link)
            end, nil, function()
                if iconBtn.UnlockHighlight then iconBtn:UnlockHighlight() end
            end)

            overlay:SetScript("OnClick", function()
                if not merchantOpen or selectedKey == "player" then return end
                if MerchantFrame.selectedTab ~= 1 then return end       -- buy tab only
                local entry = CleanBot_PartyBots and CleanBot_PartyBots[selectedKey]
                if not entry then return end
                local link = GetMerchantItemLink(iconBtn:GetID())
                if not link then return end
                if not NS.CB_CheckBotVendorRange(entry.name) then return end   -- too far → warn, don't send
                local clean = NS.CB_CleanItemLink(link)
                NS.CB_SendBotCommand(entry.name, "b " .. clean)
                NS.CB_OptimisticBuy(selectedKey, entry.name, clean)            -- update an open bag window
            end)

            overlay:Hide()
            merchantOverlays[i] = overlay
        end
    end
end

-- ── Selection ────────────────────────────────────────────────────────────────
--- Enables/disables the raid "Inventory" button to match the current selection.
local function CB_UpdateInvBtn()
    if not invBtn then return end
    if selectedKey == "player" then invBtn:Disable() else invBtn:Enable() end
end

--- Marks a portrait tab selected (bright + glow) or not (dimmed, glow hidden) — a clear,
--- tab-like "which unit is active" indicator. Mirrors a CheckButton's checked state.
local function CB_MarkSelected(tab, active)
    tab:SetChecked(active)                             -- the template's checked-glow = "selected"
    if tab.portrait then
        tab.portrait:SetDesaturated(not active)        -- grayscale the unselected ones
        tab.portrait:SetAlpha(active and 1 or 0.7)
    end
end

--- Selects a tab/dropdown entry: "player" (passthrough) or a bot key. Updates the
--- active highlight on visible portrait tabs and refreshes the buy overlays.
local function CB_SelectKey(key)
    selectedKey = key
    for k, tab in pairs(tabPool) do
        if tab:IsShown() then CB_MarkSelected(tab, k == key) end
    end
    CB_UpdateInvBtn()
    CB_RefreshOverlays()
end

--- Opens a bot's inventory window beside the merchant (for selling). No-op for the player.
local function CB_OpenBotInventory(key)
    if key == "player" then return end
    local entry = CleanBot_PartyBots[key]
    if not entry then return end
    NS.CB_RequestInventory(key, entry.name, MerchantFrame)
    openedInvKeys[key] = true
end

-- ── Portrait tabs (party mode) ───────────────────────────────────────────────
--- Sets a tab's portrait: the live 2D portrait when the unit is resolvable, else the
--- bot's class icon, else a generic fallback.
local function CB_SetTabPortrait(tab, key, name)
    local p = tab.portrait
    if key == "player" then
        SetPortraitTexture(p, "player")
        p:SetTexCoord(0, 1, 0, 1)
        return
    end
    local unit = NS.CB_FindPartyUnit(name)
    if unit then
        SetPortraitTexture(p, unit)
        p:SetTexCoord(0, 1, 0, 1)
        return
    end
    -- Out of range / not resolvable → class icon (or a question mark if even class is unknown).
    local entry  = CleanBot_PartyBots[key]
    local coords = entry and entry.class and NS.CLASS_ICON_COORDS[entry.class]
    if coords then
        p:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
        p:SetTexCoord(unpack(coords))
    else
        p:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        p:SetTexCoord(0, 1, 0, 1)
    end
end

--- On ElvUI, restyles a spellbook-template tab to ElvUI's flat dark backdrop + border (the same
--- StripTextures + StyleButton + SetTemplate recipe ElvUI uses on the real skill-line tabs),
--- replacing the gold Blizzard frame so it matches the skinned merchant frame. No-op without ElvUI.
local function CB_SkinTab(button)
    if not NS.ElvUI_S then return end
    if button.StripTextures then button:StripTextures()       end
    if button.StyleButton  then button:StyleButton(nil, true) end
    if button.SetTemplate  then button:SetTemplate("Default", true) end
end

--- Returns the pooled portrait tab for a key, creating it on first use. Built from the
--- spellbook's side-tab template (the same one the What's Training addon reuses): on the Blizzard
--- path the tab-frame background, fitted hover highlight, and checked-glow "selected" state come
--- from SpellBookSkillLineTabTemplate; on ElvUI CB_SkinTab swaps that for the flat ElvUI look.
--- The unit portrait is the tab's icon (its NormalTexture).
local function CB_AcquireTab(key)
    local tab = tabPool[key]
    if not tab then
        tab = CreateFrame("CheckButton", "CleanBotMerchantTab_" .. key, stripContainer,
            "SpellBookSkillLineTabTemplate")
        tab:Show()   -- the template starts hidden
        tab:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        tab:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                CB_OpenBotInventory(key)
                self:SetChecked(selectedKey == key)    -- undo the CheckButton's auto-toggle
            else
                CB_SelectKey(key)
            end
        end)

        CB_SkinTab(tab)   -- ElvUI: gold frame → flat dark backdrop (no-op on Blizzard)

        -- The template's icon slot is its NormalTexture — use it for the unit portrait.
        tab.portrait = tab:GetNormalTexture()
        if not tab.portrait then
            tab:SetNormalTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            tab.portrait = tab:GetNormalTexture()
        end
        if NS.ElvUI_S and tab.portrait and tab.portrait.SetInside then tab.portrait:SetInside() end

        -- Tooltip: the character's name (class-colored) + the action-bar-style blue hint.
        NS.CB_AttachTooltip(tab, function(tt)
            local nm, classToken
            if key == "player" then
                nm, classToken = UnitName("player"), select(2, UnitClass("player"))
            else
                local e = CleanBot_PartyBots[key]
                if not e then return false end
                nm, classToken = e.name, e.class
            end
            if not nm then return false end
            local c = classToken and RAID_CLASS_COLORS[classToken]
            tt:AddLine(nm, c and c.r or 1, c and c.g or 1, c and c.b or 1)
            if key ~= "player" then
                tt:AddLine("|cFF80CCFFRight-Click to open Inventory|r")
            end
        end)

        tabPool[key] = tab
    end
    return tab
end

-- ── Dropdown (raid mode) ─────────────────────────────────────────────────────
-- Class-colored "[icon] name" label for the dropdown's CLOSED/selected text (open rows tint via
-- info.colorCode instead). Mirrors the Individual tab's bot dropdown (CB_ClassIconMarkup + RAID_CLASS_COLORS).
local function CB_DropLabel(class, name)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    local colored = c and string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, name) or name
    return NS.CB_ClassIconMarkup(class) .. " " .. colored
end

-- Stamps a menu entry with the class icon + class-colored name (open-list rows tint via colorCode).
local function CB_DropEntry(info, class, name)
    info.text         = NS.CB_ClassIconMarkup(class) .. " " .. name
    info.notCheckable = true
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then info.colorCode = string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
end

local function CB_BuildDropdown()
    if not dropdown then
        dropdown = NS.CB_CreateDropdown(stripContainer, "CleanBotMerchantDropdown", 120)
        -- Top-center of the vendor frame (the top-left corner holds the frame's portrait icon),
        -- nudged down like the cog. Anchored to MerchantFrame, not the narrow vertical column.
        dropdown:SetPoint("TOP", MerchantFrame, "TOP", -52, 12)
        invBtn = NS.CB_CreateButton(stripContainer, "CleanBotMerchantInvBtn", "Inventory", 80, 22,
            function() CB_OpenBotInventory(selectedKey) end)
        -- Gap from the dropdown uses the spacing model (element-to-element = before.marginRight +
        -- widget.marginLeft); LEFT↔RIGHT centers the button vertically on the dropdown.
        invBtn:SetPoint("LEFT", dropdown, "RIGHT",
            (dropdown.marginRight or 0) + (invBtn.marginLeft or 0), 0)
    end
    local _, playerClass = UnitClass("player")
    UIDropDownMenu_Initialize(dropdown, function()
        local info = UIDropDownMenu_CreateInfo()
        CB_DropEntry(info, playerClass, "Player")   -- the player's own class icon + color
        info.func = function()
            CB_SelectKey("player"); UIDropDownMenu_SetText(dropdown, CB_DropLabel(playerClass, "Player"))
        end
        UIDropDownMenu_AddButton(info)
        NS.CB_ForEachGroupMember(function(_, name)
            local k = name and strlower(name)
            local e = k and CleanBot_PartyBots[k]
            if e then
                local i2 = UIDropDownMenu_CreateInfo()
                CB_DropEntry(i2, e.class, e.name)
                i2.func = function()
                    CB_SelectKey(k); UIDropDownMenu_SetText(dropdown, CB_DropLabel(e.class, e.name))
                end
                UIDropDownMenu_AddButton(i2)
            end
        end)
    end)
    UIDropDownMenu_SetText(dropdown, CB_DropLabel(playerClass, "Player"))
    dropdown:Show()
    invBtn:Show()
end

-- ── Visibility ───────────────────────────────────────────────────────────────
--- The cog shows whenever a vendor is open and the player has bots (independent of
--- Enable, so the user can always re-enable). The tab/dropdown strip additionally
--- requires Enable. Hidden entirely with no bots.
local function CB_UpdateVisibility()
    if not (merchantOpen and CB_HasBots()) then
        if stripContainer then stripContainer:Hide() end
        if cogBtn then cogBtn:Hide() end
        CB_HideOverlays()
        return
    end
    cogBtn:Show()
    if NS.vendorEnabled then stripContainer:Show() else stripContainer:Hide() end
    CB_RefreshOverlays()
end

-- ── Strip rebuild (party tabs vs raid dropdown) ──────────────────────────────
local function CB_RebuildStrip()
    -- Reset to the passthrough default and clear last mode's widgets.
    selectedKey = "player"
    for _, tab in pairs(tabPool) do tab:Hide() end
    if dropdown then dropdown:Hide() end
    if invBtn  then invBtn:Hide()  end

    if not CB_HasBots() then
        CB_UpdateVisibility()
        return
    end

    if NS.CB_GroupInfo() == "raid" then
        CB_BuildDropdown()
        CB_UpdateInvBtn()
    else
        -- Party: player tab first, then each tracked bot, stacking top → bottom (a vertical
        -- column down the frame's left edge).
        local keys = { "player" }
        NS.CB_ForEachGroupMember(function(_, name)
            local k = name and strlower(name)
            if k and CleanBot_PartyBots[k] then keys[#keys + 1] = k end
        end)
        local prev
        for _, key in ipairs(keys) do
            local tab  = CB_AcquireTab(key)
            local name = (key == "player") and UnitName("player") or CleanBot_PartyBots[key].name
            CB_SetTabPortrait(tab, key, name)
            tab:ClearAllPoints()
            if prev then tab:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -17)   -- native side-tab pitch
            else         tab:SetPoint("TOPLEFT", stripContainer, "TOPLEFT", 0, 0) end
            CB_MarkSelected(tab, key == "player")
            tab:Show()
            prev = tab
        end
    end

    CB_UpdateVisibility()
end

-- ── Build (once, at PLAYER_LOGIN) ────────────────────────────────────────────
local function CB_BuildStrip()
    stripContainer = CreateFrame("Frame", "CleanBotMerchantStrip", UIParent)
    stripContainer:SetFrameStrata("HIGH")
    -- Vertical column down the frame's RIGHT outer edge, below the cog. (MerchantFrame opens at
    -- the screen's top-left by default, so a left-edge column would sit off-screen; the right is clear.)
    stripContainer:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", -33, -80)
    stripContainer:SetSize(PORTRAIT_SIZE, 400)
    stripContainer:Hide()

    -- Cog: a tab matching the portraits (same spellbook side-tab template), at the top of the
    -- column. Separate frame so Enable-off (which hides the strip) never hides it. Hover fades
    -- its settings panel in/out; it never enters the "selected" (checked) state.
    cogBtn = CreateFrame("CheckButton", "CleanBotMerchantCog", UIParent, "SpellBookSkillLineTabTemplate")
    cogBtn:SetFrameStrata("HIGH")
    cogBtn:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", -33, -28)
    CB_SkinTab(cogBtn)   -- ElvUI: gold frame → flat dark backdrop (no-op on Blizzard)
    -- Gear as a separate ARTWORK icon, mirroring the inventory-cell skin (CB_SkinItemButtonCore):
    -- the template's NormalTexture kept the icon's baked border under ElvUI, but a plain texture
    -- crops cleanly. It sits over the gold tab frame on Blizzard, inside the flat backdrop on ElvUI.
    local cogIcon = cogBtn:CreateTexture(nil, "ARTWORK")
    cogIcon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
    cogIcon:SetAllPoints()
    NS.CB_CropIcon(cogIcon)                                 -- trim the icon's baked border
    if NS.ElvUI_S and cogIcon.SetInside then cogIcon:SetInside() end
    cogBtn:SetScript("OnClick", function(self) self:SetChecked(false) end)   -- hover-only; never "selected"
    cogBtn:Hide()

    cogPanel = NS.CB_CreatePanel(UIParent, "CleanBotMerchantCogPanel", 1, "panel")
    cogPanel:SetFrameStrata("HIGH")
    cogPanel:SetSize(150, 44)
    cogPanel:SetPoint("BOTTOMLEFT", cogBtn, "TOPRIGHT", 2, 2)   -- opens up and to the right
    cogPanel:EnableMouse(true)
    cogPanel:SetAlpha(0)
    cogPanel:Hide()

    local enableCB = NS.CB_CreateLabeledCheckBox(cogPanel, "CleanBotVendorEnableCB", "Enable",
        "Show the bot vendor tabs and let bots buy/sell here. The cog stays even when off so you can turn it back on.")
    enableCB:SetChecked(NS.vendorEnabled)
    enableCB:SetPoint("TOPLEFT", cogPanel, "TOPLEFT",
        (cogPanel.paddingLeft or 8), -(cogPanel.paddingTop or 8))
    enableCB:SetScript("OnClick", function(self)
        local checked = self:GetChecked() and true or false
        self:SetChecked(checked)
        NS.vendorEnabled = checked
        if CleanBot_SavedVars then CleanBot_SavedVars.vendorEnabled = checked end
        if not checked then selectedKey = "player" end
        if merchantOpen then CB_UpdateVisibility() end
    end)
    cogPanel.enableCB = enableCB

    -- Hover fade: show + fade in on enter; on leave, after a short grace (to bridge the
    -- cog→panel cursor gap), fade out and HIDE (a shown alpha-0 frame still eats clicks).
    local function fadeIn()
        cogPanel:Show()
        UIFrameFadeIn(cogPanel, 0.08, cogPanel:GetAlpha(), 1)
    end
    local function fadeOut()
        if cogBtn:IsMouseOver() or cogPanel:IsMouseOver() then return end
        UIFrameFade(cogPanel, { mode = "OUT", timeToFade = 0.08,
            startAlpha = cogPanel:GetAlpha(), endAlpha = 0,
            finishedFunc = function()
                if not (cogBtn:IsMouseOver() or cogPanel:IsMouseOver()) then cogPanel:Hide() end
            end })
    end
    local function scheduleFadeOut() NS.CB_After(0.1, fadeOut) end
    cogBtn:SetScript("OnEnter", fadeIn)
    cogBtn:SetScript("OnLeave", scheduleFadeOut)
    cogPanel:SetScript("OnEnter", fadeIn)
    cogPanel:SetScript("OnLeave", scheduleFadeOut)
end

-- ── Event handler ────────────────────────────────────────────────────────────
local eventFrame = CreateFrame("Frame", "CleanBotMerchantEventFrame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:RegisterEvent("MERCHANT_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")

eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        if not built then
            built = true
            CB_BuildStrip()
            CB_CreateMerchantOverlays()
        end
        return
    end

    if not built then return end   -- nothing to drive until the login build ran

    if event == "MERCHANT_SHOW" then
        merchantOpen = true
        CB_RebuildStrip()

    elseif event == "MERCHANT_UPDATE" then
        if merchantOpen then CB_RefreshOverlays() end

    elseif event == "MERCHANT_CLOSED" then
        merchantOpen = false
        selectedKey  = "player"
        CB_HideOverlays()
        if stripContainer then stripContainer:Hide() end
        if cogBtn then cogBtn:Hide() end
        if cogPanel then cogPanel:Hide() end
        for key in pairs(openedInvKeys) do
            local f = NS.botInventoryFrames and NS.botInventoryFrames[key]
            if f and f:IsShown() then f:Hide() end
        end
        wipe(openedInvKeys)

    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        if merchantOpen then CB_RebuildStrip() end
    end
end)
