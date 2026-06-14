-- ============================================================
-- Model.lua  —  DressUpModel creation, right-click
--                        rotation drag, and favorite-star button.
-- NS.CB_CreateModel is called once per pool slot from CB_CreateSlot.
-- All event handlers resolve the bound bot live via `slot`, so the model
-- is rebound (SetUnit + star/equip refresh) rather than recreated.
-- ============================================================
local NS = CleanBotNS

--- Creates and fully wires up a DressUpModel for one slot.
--- Stores slot.updateStar (star refresh) and slot.equipSlots (paperdoll).
--- Rotation drag uses the shared capture frame (NS.CB_BeginCapture).
---@param slot   table   The pool slot table (bound bot resolved live via slot.key/unit).
---@param parent table   Parent frame the model is created inside.
---@param modelW number  Model width.
---@param modelH number  Model height.
---@return table         The created DressUpModel (caller positions it).
NS.CB_CreateModel = function(slot, parent, modelW, modelH)
    local model = CreateFrame("DressUpModel", "CleanBotModel" .. slot.index, parent)
    model:SetSize(modelW, modelH)
    model:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    model:Hide()

    -- ── Right-click drag to rotate ────────────────────────────
    local modelRotation = 0
    local dragLastX     = 0

    --- OnUpdate handler while dragging: rotates the model by the cursor's X delta.
    local function rotateOnUpdate()
        local x     = select(1, GetCursorPosition())
        local delta = x - dragLastX
        dragLastX   = x
        if delta ~= 0 then
            modelRotation = modelRotation + delta * 0.013
            model:SetRotation(modelRotation)
        end
    end

    --- Ends the rotation drag and restores the cursor.
    local function stopDrag()
        NS.CB_EndCapture()
        SetCursor(nil)
    end

    model:EnableMouse(true)
    model:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then
            dragLastX = select(1, GetCursorPosition())
            SetCursor("none")
            NS.CB_BeginCapture(rotateOnUpdate, function(btn)
                if btn == "RightButton" then stopDrag() end
            end)
        end
    end)
    model:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then stopDrag() end
    end)

    -- ── Favorite star button ─────────────────────────────────
    local starBtn = CreateFrame("Button", "CleanBotStar" .. slot.index, model)
    starBtn:SetSize(24, 24)
    starBtn:SetPoint("TOPLEFT", model, "TOPLEFT", 6, -6)

    local starTex = starBtn:CreateTexture(nil, "OVERLAY")
    starTex:SetAllPoints()
    starTex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")

    -- Favorites are stored as presets["Favorites"] — an array of display-name strings.
    -- These helpers keep the star button decoupled from the array internals.
    --- Returns whether the given bot key is in the Favorites preset.
    ---@param key string  Bot display-name key.
    ---@return boolean
    local function IsFavorite(key)
        if not key or not CleanBot_SavedVars then return false end
        local favs = CleanBot_SavedVars.presets and CleanBot_SavedVars.presets["Favorites"]
        if not favs then return false end
        local lkey = strlower(key)
        for _, v in ipairs(favs) do
            if strlower(v) == lkey then return true end
        end
        return false
    end

    --- Adds the given bot key to the Favorites preset (no-op if already present).
    ---@param key string  Bot display-name key.
    local function AddFavorite(key)
        if not CleanBot_SavedVars or not CleanBot_SavedVars.presets then return end
        if not CleanBot_SavedVars.presets["Favorites"] then
            CleanBot_SavedVars.presets["Favorites"] = {}
        end
        if IsFavorite(key) then return end
        local name = key:sub(1, 1):upper() .. key:sub(2)
        local favs = CleanBot_SavedVars.presets["Favorites"]
        favs[#favs + 1] = name
    end

    --- Removes the given bot key from the Favorites preset.
    ---@param key string  Bot display-name key.
    local function RemoveFavorite(key)
        if not CleanBot_SavedVars or not CleanBot_SavedVars.presets then return end
        local favs = CleanBot_SavedVars.presets["Favorites"]
        if not favs then return end
        local lkey = strlower(key)
        for i, v in ipairs(favs) do
            if strlower(v) == lkey then
                table.remove(favs, i)
                return
            end
        end
    end

    --- Tints the star gold when the bound bot is a favorite, gray otherwise.
    local function UpdateStar()
        if slot.key and IsFavorite(slot.key) then
            starTex:SetVertexColor(1, 0.82, 0)
        else
            starTex:SetVertexColor(0.4, 0.4, 0.4)
        end
    end
    slot.updateStar = UpdateStar
    UpdateStar()

    starBtn:SetScript("OnClick", function()
        if not slot.key or not CleanBot_SavedVars then return end
        if IsFavorite(slot.key) then
            RemoveFavorite(slot.key)
        else
            AddFavorite(slot.key)
        end
        UpdateStar()
    end)
    NS.CB_SetTooltip(starBtn,
        function() return IsFavorite(slot.key) and "Remove from Favorites" or "Add to Favorites" end)

    -- ── Refresh Equipment button ──────────────────────────────
    local refreshBtn = NS.CB_CreateButton(model, "CleanBotRefreshEquip" .. slot.index,
                                          "Refresh Equipment", 130, 22, function()
        if NS.CB_QueueEquipRefresh and slot.key then
            NS.CB_QueueEquipRefresh({{ key = slot.key, unit = slot.unit }})
        end
    end)
    refreshBtn:SetPoint("TOP", model, "TOP", 0, -6)

    -- ── Equipment slot buttons (paperdoll layout) ─────────────
    NS.CB_CreateEquipSlots(slot, model)

    return model
end
