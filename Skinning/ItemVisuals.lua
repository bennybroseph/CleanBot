-- ============================================================
-- Skinning\ItemVisuals.lua  —  icon cropping, item-button skins,
--                              and item-quality border tinting.
-- ============================================================
local NS = CleanBotNS

-- The standard icon-border crop (~8% per side). A FIXED value on purpose: ElvUI-WotLK sets
-- E.TexCoords = {0,1,0,1} (it does not crop icons), so deferring to it would be a no-op.
local ICON_CROP = { 0.08, 0.92, 0.08, 0.92 }

-- Crops the rounded border baked into a WoW icon texture so it reads as a square. Always applies
-- a real crop, on BOTH paths. Use for any standalone icon button (e.g. the merchant cog).
---@param texture table?  The texture to crop.
NS.CB_CropIcon = function(texture)
    if not texture then return end
    texture:SetTexCoord(unpack(ICON_CROP))
end

-- Crops an icon to ElvUI's OWN coords, ElvUI path only, so paperdoll/inventory item buttons match
-- ElvUI's native treatment (which on the WotLK backport is {0,1,0,1} = uncropped). No-op without
-- ElvUI. Deliberately distinct from CB_CropIcon, which always applies a real crop.
---@param texture table  The texture to crop.
NS.CB_ApplyElvCoords = function(texture)
    if not NS.ElvUI_E then return end
    texture:SetTexCoord(unpack(NS.ElvUI_E.TexCoords))
end

-- Shared core for the two item-button skins: strip the default art, apply the
-- ElvUI dark template + hover/push styling, and crop the item icon. Callers add
-- any slot-background art themselves. No-op guarding is done by the callers.
---@param btn table  The item button (reads btn.icon).
local function CB_SkinItemButtonCore(btn)
    btn:StripTextures()
    btn:SetTemplate("Default")
    btn:StyleButton()
    if btn.icon then
        NS.CB_ApplyElvCoords(btn.icon)
        btn.icon:SetInside()
    end
end

-- Applies an ElvUI-style square skin to an inventory cell button.
-- Like CB_SkinEquipSlot but also crops and fills the bag-slot background texture
-- (btn.bg), which for inventory cells already exists when this is called.
-- No-op when ElvUI is not installed.
---@param cell table  The inventory cell button (reads cell.icon and cell.bg).
NS.CB_SkinInventoryCell = function(cell)
    if not NS.ElvUI_S then return end
    CB_SkinItemButtonCore(cell)
    if cell.bg then
        NS.CB_ApplyElvCoords(cell.bg)
        cell.bg:SetAllPoints()
    end
end

-- Applies an ElvUI-style square skin to an equipment slot button.
--
-- StripTextures nulls btn.bg and btn.icon. SetTemplate applies the dark backdrop +
-- border directly on btn (avoids backdrop child frame level issues). The item icon
-- (btn.icon) is restored with E.TexCoords cropping, which trims the rounded edges
-- off the circular paperdoll slot textures and makes them read as square.
-- No-op when ElvUI is not installed.
---@param btn table  The equipment slot button (reads btn.icon).
NS.CB_SkinEquipSlot = function(btn)
    if not NS.ElvUI_S then return end
    CB_SkinItemButtonCore(btn)
    -- btn.bg is created AFTER this function returns (in CB_CreateEquipSlots) so
    -- that it is always the last BACKGROUND texture on the button and renders
    -- above the dark fill that SetTemplate just stamped on.
end

-- Returns the r, g, b color for a given item quality level (0–6).
-- Wraps GetItemQualityColor with a white fallback so callers never receive nil.
---@param quality number?  Item quality 0–6 (default 1).
---@return number r  Red 0–1.
---@return number g  Green 0–1.
---@return number b  Blue 0–1.
NS.CB_GetQualityColor = function(quality)
    local r, g, b = GetItemQualityColor(quality or 1)
    return r or 1, g or 1, b or 1
end

-- Persistent rarity overlay (Blizz UI path only). Draws the action-button border art
-- over an item/equip button, tinted to the item's quality color, and shown at all
-- times (not just on hover) so the rarity reads at a glance. The art is grayscale
-- (Blizzard tints it green in code via SetVertexColor), so it recolors cleanly to any
-- quality. Created once and cached on btn.cbRarityOverlay; shown/colored per item and
-- hidden on empty slots. No-op on ElvUI, which shows quality via its own border.
local RARITY_OVERLAY_TEX = "Interface\\Buttons\\UI-ActionButton-Border"

-- Gold for quest items — they carry no quality color of their own, so we give them
-- the standard quest yellow for both their border and their glow to stand out.
local QUEST_BORDER_COLOR = { 1.0, 0.82, 0.0 }

-- Every button that has been given a rarity overlay, so the "Enable Item Glow" setting
-- can re-evaluate them all live when toggled. Buttons persist for the session, so this
-- registry never needs pruning.
local rarityOverlayBtns = {}

--- Shows/updates a persistent rarity-colored overlay on an item or equip button.
---@param btn     table    The item/equip button.
---@param quality number?  Item quality 0–6, or nil/empty to hide the overlay.
---@param colorOverride number[]? Explicit {r,g,b} that forces the glow on regardless of
---                       the quality threshold (used to give quest items a gold glow).
NS.CB_SetRarityOverlay = function(btn, quality, colorOverride)
    if NS.ElvUI_S then return end
    local ov = btn.cbRarityOverlay
    if not ov then
        ov = btn:CreateTexture(nil, "OVERLAY")
        ov:SetTexture(RARITY_OVERLAY_TEX)
        ov:SetBlendMode("ADD")
        -- The art has wide transparent margins and is meant to be drawn larger than its
        -- button so the glow ring lands at the button's edges. Blizzard sizes it 62px
        -- over a 36px action button (~1.72×); mirror that ratio off our button's size,
        -- centered, with full texcoords — anything smaller leaves the ring inset and tiny.
        local scale = 62 / 36
        local w, h  = btn:GetWidth(), btn:GetHeight()
        ov:SetSize(w * scale, h * scale)
        ov:SetPoint("CENTER", btn, "CENTER", 0, 0)
        btn.cbRarityOverlay = ov
        rarityOverlayBtns[#rarityOverlayBtns + 1] = btn
    end
    -- Gated by the "Enable Item Glow" setting (default on). A color override forces the
    -- glow on (quest items); otherwise only uncommon (green, quality 2) and above glow —
    -- poor/common/empty/disabled get no overlay.
    if NS.itemGlow ~= false and (colorOverride or (quality and quality >= 2)) then
        if colorOverride then
            ov:SetVertexColor(colorOverride[1], colorOverride[2], colorOverride[3])
        else
            ov:SetVertexColor(NS.CB_GetQualityColor(quality))
        end
        ov:Show()
    else
        ov:Hide()
    end
end

--- Re-evaluates every rarity overlay against the current NS.itemGlow setting, reading
--- each button's quality (and quest status) from its live itemLink. Called when the
--- setting is toggled.
NS.CB_RefreshRarityOverlays = function()
    for _, btn in ipairs(rarityOverlayBtns) do
        local quality, override
        if btn.itemLink then
            local _, _, q, _, _, itemType = GetItemInfo(btn.itemLink)
            quality = q
            if itemType == "Quest" then override = QUEST_BORDER_COLOR end
        end
        NS.CB_SetRarityOverlay(btn, quality, override)
    end
end

-- Creates a rounded quality-color border on an item button for the Blizz UI path
-- using a child frame with Interface\Tooltips\UI-Tooltip-Border as the edgeFile.
-- The child frame renders above the parent's texture layers so the border is visible
-- over the icon. Border is hidden (alpha 0) until colored by CB_SetQualityBorder.
-- Equip slots use this; inventory cells fall back to normTex which is always visible.
-- No-op on ElvUI — SetTemplate's iborder/oborder child frames handle this.
---@param btn table  The item button to add the quality border frame to (stores btn.qualityFrame).
NS.CB_ApplyQualityBackdrop = function(btn)
    if NS.ElvUI_S then return end
    local f = CreateFrame("Frame", nil, btn)
    f:SetAllPoints()
    f:SetFrameLevel(btn:GetFrameLevel() + 2)
    f:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropBorderColor(0, 0, 0, 0)
    btn.qualityFrame = f
end

-- Applies an explicit color to an item button's border, dispatching by path.
-- ElvUI: SetBackdropBorderColor (targets SetTemplate's iborder/oborder frames).
-- Blizz with qualityFrame (equip slots): SetBackdropBorderColor on the child frame.
-- Blizz with normTex only (inventory cells): vertex-colors normTex (already visible).
---@param btn table   The item button.
---@param r   number  Red 0–1.
---@param g   number  Green 0–1.
---@param b   number  Blue 0–1.
local function CB_ApplyBorderColor(btn, r, g, b)
    if NS.ElvUI_S then
        btn:SetBackdropBorderColor(r, g, b, 1)
    elseif btn.qualityFrame then
        btn.qualityFrame:SetBackdropBorderColor(r, g, b, 1)
    elseif btn.normTex then
        btn.normTex:SetVertexColor(r, g, b)
    end
end

-- Colors the border of an item button to match the item's quality.
---@param btn     table   The item button.
---@param quality number? Item quality 0–6 (default 1).
NS.CB_SetQualityBorder = function(btn, quality)
    CB_ApplyBorderColor(btn, GetItemQualityColor(quality or 1))
end

-- Sets both the quality border and the rarity overlay for an item from its link,
-- treating quest items specially (gold border, no overlay). The single entry point
-- for "this cell now holds this item" so quest detection lives in one place.
---@param btn  table    The item button.
---@param link string?  The item's link, or nil to clear the visuals.
NS.CB_ApplyItemVisuals = function(btn, link)
    if not link then
        NS.CB_ClearQualityBorder(btn)
        NS.CB_SetRarityOverlay(btn, nil)
        return
    end
    local _, _, quality, _, _, itemType = GetItemInfo(link)
    local glowOverride
    if itemType == "Quest" then
        CB_ApplyBorderColor(btn, unpack(QUEST_BORDER_COLOR))
        glowOverride = QUEST_BORDER_COLOR
    elseif quality then
        NS.CB_SetQualityBorder(btn, quality)
    else
        NS.CB_ClearQualityBorder(btn)
    end
    NS.CB_SetRarityOverlay(btn, quality, glowOverride)
end

-- Resets the border of an item button to its uncolored state.
-- ElvUI: restores db.general.bordercolor.
-- Blizz with qualityFrame: hides the border (alpha 0) on empty slots.
-- Blizz with normTex only: resets to white (no tint; normTex stays visible).
---@param btn table  The item button.
NS.CB_ClearQualityBorder = function(btn)
    if NS.ElvUI_S then
        local E  = NS.ElvUI_E
        local bc = (E and E.db and E.db.general and E.db.general.bordercolor) or {}
        btn:SetBackdropBorderColor(bc.r or 0.3, bc.g or 0.3, bc.b or 0.3, 1)
    elseif btn.qualityFrame then
        btn.qualityFrame:SetBackdropBorderColor(0, 0, 0, 0)
    elseif btn.normTex then
        btn.normTex:SetVertexColor(1, 1, 1)
    end
end
