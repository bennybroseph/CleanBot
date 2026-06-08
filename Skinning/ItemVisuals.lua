-- ============================================================
-- Skinning\ItemVisuals.lua  —  icon cropping, item-button skins,
--                              and item-quality border tinting.
-- ============================================================
local NS = CleanBotNS

-- Applies ElvUI's standard icon crop to a texture. Trims the rounded edges that
-- are baked into WoW's icon and paperdoll slot textures, giving them a square look.
-- No-op when ElvUI is not installed.
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

-- Creates a rounded quality-colour border on an item button for the Blizz UI path
-- using a child frame with Interface\Tooltips\UI-Tooltip-Border as the edgeFile.
-- The child frame renders above the parent's texture layers so the border is visible
-- over the icon. Border is hidden (alpha 0) until coloured by CB_SetQualityBorder.
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

-- Colors the border of an item button to match the item's quality.
-- ElvUI: SetBackdropBorderColor (targets SetTemplate's iborder/oborder frames).
-- Blizz with qualityFrame (equip slots): SetBackdropBorderColor on the child frame.
-- Blizz with normTex only (inventory cells): vertex-colours normTex (already visible).
---@param btn     table   The item button.
---@param quality number? Item quality 0–6 (default 1).
NS.CB_SetQualityBorder = function(btn, quality)
    local r, g, b = GetItemQualityColor(quality or 1)
    if NS.ElvUI_S then
        btn:SetBackdropBorderColor(r, g, b, 1)
    elseif btn.qualityFrame then
        btn.qualityFrame:SetBackdropBorderColor(r, g, b, 1)
    elseif btn.normTex then
        btn.normTex:SetVertexColor(r, g, b)
    end
end

-- Resets the border of an item button to its uncoloured state.
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
