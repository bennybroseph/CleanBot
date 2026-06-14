-- ============================================================
-- Skinning\QuestWidgets.lua  —  quest-specific skinned factories:
--   the three quest text styles and the reward item button.
--
-- Each text factory creates a FontString styled for its role and
-- stamps uniform margins so CB_AnchorBelow produces consistent
-- spacing without any hardcoded offsets at the call site.
--
-- Skin priority: ElvUI (E.media.normFont) → WoW named font objects.
-- Color and size are set explicitly so the result is the same
-- regardless of which FontObject the named font currently inherits.
-- ============================================================
local NS = CleanBotNS

--- Creates a quest title FontString.
--- ElvUI: E.media.normFont at 22px, #ffcc1a.
--- Default: QuestTitleFont face at 22px, black with a #7d590d drop shadow.
---@param parent table  Parent frame to create the FontString inside.
---@return table        The created FontString with margins stamped.
NS.CB_CreateQuestHeader = function(parent)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    local E  = NS.ElvUI_E
    if E and E.media and E.media.normFont then
        fs:SetFont(E.media.normFont, 22)
        fs:SetTextColor(1, 0.8, 0.102)        -- #ffcc1a
    else
        local ref  = _G["QuestTitleFont"]
        local path = ref and ref:GetFont()
        fs:SetFont(path or "Fonts\\MORPHEUS.TTF", 22)
        fs:SetTextColor(0, 0, 0)              -- black
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0.490, 0.349, 0.051)  -- #7d590d
    end
    fs:SetJustifyH("LEFT")
    fs.marginTop    = 8
    fs.marginBottom = 8
    fs.marginLeft   = 0
    fs.marginRight  = 0
    return fs
end

--- Creates a quest body text FontString (description or objectives text).
--- ElvUI: E.media.normFont at 14px, white.
--- Default: QuestFont face at its native size, brown #2e1f0f.
---@param parent table  Parent frame to create the FontString inside.
---@return table        The created FontString with margins stamped.
NS.CB_CreateQuestParagraph = function(parent)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    local E  = NS.ElvUI_E
    if E and E.media and E.media.normFont then
        fs:SetFont(E.media.normFont, 14)
        fs:SetTextColor(1, 1, 1)              -- white
    else
        local ref        = _G["QuestFont"]
        local path, size
        if ref then path, size = ref:GetFont() end
        fs:SetFont(path or "Fonts\\FRIZQT__.TTF", size or 12)
        fs:SetTextColor(0.180, 0.122, 0.059)  -- #2e1f0f
    end
    fs:SetJustifyH("LEFT")
    fs.marginTop    = 0
    fs.marginBottom = 8
    fs.marginLeft   = 0
    fs.marginRight  = 0
    return fs
end

--- Creates a leaderboard objective entry FontString.
--- ElvUI: E.media.normFont at 14px; #ffcc1a when complete, #999999 when incomplete.
--- Default: GameFontHighlight face at its native size; #333333 when complete, #2e1f0f when incomplete.
---@param parent   table    Parent frame to create the FontString inside.
---@param finished boolean  Whether this objective has been completed.
---@return table            The created FontString with margins stamped.
NS.CB_CreateObjectiveText = function(parent, finished)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    local E  = NS.ElvUI_E
    if E and E.media and E.media.normFont then
        fs:SetFont(E.media.normFont, 14)
        if finished then
            fs:SetTextColor(1, 0.8, 0.102)    -- #ffcc1a
        else
            fs:SetTextColor(0.6, 0.6, 0.6)    -- #999999
        end
    else
        local ref        = _G["GameFontHighlight"]
        local path, size
        if ref then path, size = ref:GetFont() end
        fs:SetFont(path or "Fonts\\FRIZQT__.TTF", size or 12)
        if finished then
            fs:SetTextColor(0.2, 0.2, 0.2)        -- #333333 grayed out
        else
            fs:SetTextColor(0.180, 0.122, 0.059)  -- #2e1f0f same as paragraph
        end
    end
    fs:SetJustifyH("LEFT")
    fs.marginTop    = 0
    fs.marginBottom = 1
    fs.marginLeft   = 0
    fs.marginRight  = 0
    return fs
end

--- Creates a quest reward item button backed by LargeItemButtonTemplate (147×41).
--- The template provides $parentIconTexture (39×39 BACKGROUND), $parentNameFrame
--- (parchment backing texture), $parentName (GameFontHighlight FontString), and
--- $parentCount (NumberFontNormal FontString) — all accessed by CB_PopulateRewardSlot
--- via _G[name.."IconTexture/Name/Count"].
---
--- ElvUI: strips the parchment art, applies SetTemplate("Default"), re-layers the
---   icon to ARTWORK so it renders above the backdrop, re-anchors $parentName.
--- Default: template art is used as-is; the parchment NameFrame background matches
---   the Blizzard quest log reward style with no extra skinning needed.
---
---@param parent table   Parent frame.
---@param name   string  Globally unique frame name (required by $parent substitution).
---@return table         The created Button with margins stamped.
NS.CB_CreateQuestRewardItem = function(parent, name)
    local btn = CreateFrame("Button", name, parent, "LargeItemButtonTemplate")

    local bName   = btn:GetName()
    local iconTex = bName and _G[bName .. "IconTexture"]

    if NS.ElvUI_S then
        local nameFS = bName and _G[bName .. "Name"]

        btn:StripTextures()
        btn:SetTemplate("Default")
        btn:SetBackdropBorderColor(1, 1, 1, 1)
        btn:StyleButton()

        if iconTex then
            -- Move to ARTWORK so it renders above the BACKGROUND backdrop fill.
            iconTex:SetDrawLayer("ARTWORK")
            iconTex:ClearAllPoints()
            iconTex:SetPoint("TOPLEFT",    btn, "TOPLEFT",    2, -2)
            iconTex:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 2,  2)
            iconTex:SetWidth(btn:GetHeight() - 4)
            NS.CB_ApplyElvCoords(iconTex)
            iconTex:Show()
        end

        if nameFS and iconTex then
            -- Re-anchor away from the (now-hidden) parchment NameFrame texture.
            nameFS:ClearAllPoints()
            nameFS:SetPoint("LEFT",   iconTex, "RIGHT",  4,  0)
            nameFS:SetPoint("RIGHT",  btn,     "RIGHT", -4,  0)
            nameFS:SetPoint("TOP",    btn,     "TOP",    0, -2)
            nameFS:SetPoint("BOTTOM", btn,     "BOTTOM", 0,  2)
        end
    end

    -- Vanilla only: quality border scoped to the icon, not the full button.
    -- ElvUI uses SetBackdropBorderColor on the button itself via CB_SetQualityBorder.
    if not NS.ElvUI_S and iconTex then
        local qf = CreateFrame("Frame", nil, btn)
        qf:SetAllPoints(iconTex)
        qf:SetFrameLevel(btn:GetFrameLevel() + 2)
        qf:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 8,
            insets   = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        qf:SetBackdropBorderColor(0, 0, 0, 0)
        btn.qualityFrame = qf
    end

    NS.CB_AttachTooltip(btn, function(tt, self)
        if not self.itemLink then return false end
        tt:SetHyperlink(self.itemLink)
    end)

    btn.marginTop    = 4
    btn.marginBottom = 4
    btn.marginLeft   = 0
    btn.marginRight  = 4
    return btn
end
