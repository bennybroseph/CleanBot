-- ============================================================
-- CleanBotModel.lua  —  DressUpModel creation, right-click
--                        rotation drag, and favourite-star button.
-- NS.CB_CreateModel is called once per bot tab from RefreshTabs.
-- ============================================================
local NS = CleanBotNS

-- Creates and fully wires up a DressUpModel for one bot.
-- Registers NS.botStarUpdaters[key] for star refresh.
-- Stores model._dragCapture so CleanBot_ClearTabs can dispose it.
-- Returns the model frame.
NS.CB_CreateModel = function(parent, contentW, contentH, unit, key, counter)
    local model = CreateFrame("DressUpModel", "CleanBotModel" .. counter, parent)
    model:SetSize(contentW / 3, contentH)
    model:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    model:SetUnit(unit)
    model:Hide()

    -- ── Right-click drag to rotate ────────────────────────────
    local modelRotation = 0
    local dragLastX     = 0

    -- Full-screen capture frame absorbs mouse events during drag.
    -- Parented to UIParent (not model) so it can cover the whole screen;
    -- stored on the model so ClearTabs can clean it up.
    local dragCapture = CreateFrame("Frame", "CleanBotDragCapture" .. counter, UIParent)
    dragCapture:SetAllPoints(UIParent)
    dragCapture:SetFrameStrata("FULLSCREEN_DIALOG")
    dragCapture:EnableMouse(true)
    dragCapture:Hide()
    model._dragCapture = dragCapture

    local function stopDrag()
        dragCapture:Hide()
        SetCursor(nil)
    end
    dragCapture:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then stopDrag() end
    end)
    dragCapture:SetScript("OnUpdate", function()
        local x     = select(1, GetCursorPosition())
        local delta = x - dragLastX
        dragLastX   = x
        if delta ~= 0 then
            modelRotation = modelRotation + delta * 0.013
            model:SetRotation(modelRotation)
        end
    end)

    model:EnableMouse(true)
    model:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then
            dragLastX = select(1, GetCursorPosition())
            SetCursor("none")
            dragCapture:Show()
        end
    end)
    model:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then stopDrag() end
    end)

    -- ── Favourite star button ─────────────────────────────────
    local starBtn = CreateFrame("Button", "CleanBotStar" .. counter, model)
    starBtn:SetSize(24, 24)
    starBtn:SetPoint("TOPLEFT", model, "TOPLEFT", 6, -6)

    local starTex = starBtn:CreateTexture(nil, "OVERLAY")
    starTex:SetAllPoints()
    starTex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")

    local function UpdateStar()
        if CleanBot_SavedVars and CleanBot_SavedVars.favoriteBots
                               and CleanBot_SavedVars.favoriteBots[key] then
            starTex:SetVertexColor(1, 0.82, 0)
        else
            starTex:SetVertexColor(0.4, 0.4, 0.4)
        end
    end
    NS.botStarUpdaters[key] = UpdateStar
    UpdateStar()

    starBtn:SetScript("OnClick", function()
        if not CleanBot_SavedVars then return end
        if not CleanBot_SavedVars.favoriteBots then CleanBot_SavedVars.favoriteBots = {} end
        if CleanBot_SavedVars.favoriteBots[key] then
            CleanBot_SavedVars.favoriteBots[key] = nil
        else
            CleanBot_SavedVars.favoriteBots[key] = true
        end
        UpdateStar()
    end)
    starBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local isFav = CleanBot_SavedVars and CleanBot_SavedVars.favoriteBots
                                         and CleanBot_SavedVars.favoriteBots[key]
        GameTooltip:AddLine(isFav and "Remove from Favorites" or "Add to Favorites", 1, 1, 1)
        GameTooltip:Show()
    end)
    starBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ── Refresh Equipment button ──────────────────────────────
    local refreshBtn = CreateFrame("Button", "CleanBotRefreshEquip" .. counter, model, "UIPanelButtonTemplate")
    refreshBtn:SetSize(110, 22)
    refreshBtn:SetPoint("TOP", model, "TOP", 0, -6)
    refreshBtn:SetText("Refresh Equipment")
    refreshBtn:SetScript("OnClick", function()
        if NS.CB_QueueEquipRefresh then
            NS.CB_QueueEquipRefresh({{ key = key, unit = unit }})
        end
    end)
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(refreshBtn) end

    -- ── Equipment slot buttons (paperdoll layout) ─────────────
    NS.CB_CreateEquipSlots(model, key, counter, unit)

    return model
end
