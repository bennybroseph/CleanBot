-- ============================================================
-- Debug.lua  —  developer diagnostics: the KnownBots
-- popup window and the /cbdebug chat dump.
-- Reached via "/cleanbot debug knownbots" and "/cbdebug".
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- KnownBots popup window (created lazily, reused)
-- ============================================================
local debugKnownBotsFrame = nil

--- Builds the multi-line diagnostic text dump: handshake state, the last raw
--- STATES payload, and per-bot parsed combat strategy flags.
---@return string  The formatted report, or a placeholder when no bots are known.
local function CB_FormatKnownBots()
    local lines = {
        "=== Handshake ===",
        "bridgeReady: " .. tostring(NS.bridgeReady),
        "Last HELLO_ACK: " .. (NS.lastHelloAck or "(none received yet)"),
        "",
        "=== Debug Overrides ===",
        "Bridge override : " .. (NS.debugBridgeOverride or "none (auto)"),
        "Simulate mode   : " .. (NS.debugSimulate and "ON" or "OFF"),
        "",
        "=== Last raw STATES payload ===",
        NS.lastRawStates or "(none received yet)",
        "",
        "=== Parsed KnownBots ===",
        "",
    }
    local count = 0
    for key, bot in pairs(CleanBot_PartyBots) do
        count = count + 1
        lines[#lines + 1] = string.format("[%d]  %s  (%s)", count, bot.name or key, bot.class or "?")
        if bot.combat then
            local active, inactive, unknown = {}, {}, {}
            for field, val in pairs(bot.combat) do
                if val == true then
                    active[#active + 1] = field
                elseif val == false then
                    inactive[#inactive + 1] = field
                else
                    unknown[#unknown + 1] = field
                end
            end
            table.sort(active); table.sort(inactive); table.sort(unknown)
            if #active   > 0 then lines[#lines + 1] = "  |cff00ff00ON |r  " .. table.concat(active,   "  ") end
            if #inactive > 0 then lines[#lines + 1] = "  |cffff4444OFF|r  " .. table.concat(inactive, "  ") end
            if #unknown  > 0 then lines[#lines + 1] = "  |cffaaaaaa?  |r  " .. table.concat(unknown,  "  ") end
        else
            lines[#lines + 1] = "  (no combat data)"
        end
        lines[#lines + 1] = ""
    end
    if count == 0 then return "(CleanBot_PartyBots is empty)" end
    return table.concat(lines, "\n")
end

--- Opens (creating once, then reusing) the KnownBots diagnostic popup window
--- and fills it with the CB_FormatKnownBots report.
NS.CB_ShowDebugKnownBots = function()
    local screenH = UIParent:GetHeight()
    local winW    = 520
    local winH    = math.floor(screenH / 2)
    local titleH  = 24
    local footerH = 32
    local padH    = 8

    if not debugKnownBotsFrame then
        local f = CreateFrame("Frame", "CleanBotDebugKnownBots", UIParent)
        f:SetSize(winW, winH)
        f:SetPoint("CENTER")
        f:SetMovable(true)
        f:SetToplevel(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")

        NS.CB_ApplyFrameSkin(f, 1)

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", f, "TOP", 0, -8)
        title:SetText("CleanBot — KnownBots")

        local closeBtn = NS.CB_CreateButton(f, nil, "Close", 80, 22, function() f:Hide() end)
        closeBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 6)

        local sf = CreateFrame("ScrollFrame", "CleanBotDebugScroll", f,
                               "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT",     f, "TOPLEFT",     8,  -(titleH + padH))
        sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, footerH + padH)

        local child = CreateFrame("Frame", nil, sf)
        child:SetWidth(sf:GetWidth() or (winW - 36))
        sf:SetScrollChild(child)

        local txt = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        txt:SetPoint("TOPLEFT", child, "TOPLEFT", 4, -4)
        txt:SetWidth((sf:GetWidth() or (winW - 36)) - 8)
        txt:SetJustifyH("LEFT")
        txt:SetNonSpaceWrap(false)

        f.scrollFrame = sf
        f.scrollChild = child
        f.textObj     = txt
        debugKnownBotsFrame = f
    end

    local f   = debugKnownBotsFrame
    local txt = f.textObj
    txt:SetText(CB_FormatKnownBots())
    f.scrollChild:SetHeight(math.max(txt:GetStringHeight() + 8, 1))
    f:SetHeight(winH)
    f:Show()
    f.scrollFrame:SetVerticalScroll(0)
end

-- ============================================================
-- /cbframes  — hover over a stuck widget then run this to see
--              which frame is capturing the mouse and why.
-- ============================================================
SLASH_CBFRAMES1 = "/cbframes"
SlashCmdList["CBFRAMES"] = function()
    local focus = GetMouseFocus and GetMouseFocus()
    if focus then
        print(string.format("MouseFocus: %s  strata=%s  level=%d  mouseEnabled=%s",
            tostring(focus:GetName() or "(unnamed)"),
            tostring(focus:GetFrameStrata()),
            focus:GetFrameLevel(),
            tostring(focus:IsMouseEnabled())))
    else
        print("MouseFocus: nil (mouse not over any mouse-enabled frame)")
    end

    -- Report key manage-tab frame states.
    local function fr(label, f)
        if not f then print(label .. ": nil"); return end
        print(string.format("  %s: strata=%s level=%d mouseEnabled=%s visible=%s",
            label, tostring(f:GetFrameStrata()), f:GetFrameLevel(),
            tostring(f:IsMouseEnabled()), tostring(f:IsVisible())))
    end
    print("-- Manage tab frames --")
    fr("managePanel",          NS.managePanel)
    fr("managePanel.iborder",  NS.managePanel and NS.managePanel.iborder)
    fr("managePanel.oborder",  NS.managePanel and NS.managePanel.oborder)
    fr("manageScrollFrame",    NS.manageScrollFrame)
    fr("manageScrollChild",    NS.manageScrollChild)
    local sf = NS.manageScrollFrame
    if sf then
        local bar = _G["CleanBotManageScrollFrameScrollBar"]
        fr("ScrollBar",        bar)
    end

end

-- ============================================================
-- /cbdebug  — quick party/cache dump + debug overrides
--
--   /cbdebug bridge off    — force bridge absent (uses whisper fallback)
--   /cbdebug bridge on     — force bridge present (uses bridge path)
--   /cbdebug bridge reset  — clear override; follow real handshake result
--   /cbdebug simulate      — toggle simulate mode (print commands instead of sending)
-- ============================================================
SLASH_CBDEBUG1 = "/cbdebug"
SlashCmdList["CBDEBUG"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")

    -- Bridge override sub-commands. Each re-syncs so the new effective state
    -- applies immediately (roster/inventory/quests re-fetch via the right path)
    -- instead of waiting for the next window open.
    if msg == "bridge off" then
        NS.debugBridgeOverride = "absent"
        if CleanBot_SavedVars then CleanBot_SavedVars.debugBridgeOverride = "absent" end
        NS.CB_Print("Bridge override set to |cffff4444absent|r (whisper fallback).")
        NS.CB_RequestSync()
        return
    elseif msg == "bridge on" then
        NS.debugBridgeOverride = "present"
        if CleanBot_SavedVars then CleanBot_SavedVars.debugBridgeOverride = "present" end
        NS.CB_Print("Bridge override set to |cff00ff00present|r (bridge path).")
        NS.CB_RequestSync()
        return
    elseif msg == "bridge reset" then
        NS.debugBridgeOverride = nil
        if CleanBot_SavedVars then CleanBot_SavedVars.debugBridgeOverride = nil end
        NS.CB_Print("Bridge override cleared — following real handshake (" .. NS.bridgeState .. ").")
        NS.CB_RequestSync()
        return
    -- Simulate mode toggle.
    elseif msg == "simulate" then
        NS.debugSimulate = not NS.debugSimulate
        if CleanBot_SavedVars then CleanBot_SavedVars.debugSimulate = NS.debugSimulate end
        NS.CB_Print("Simulate mode: " .. (NS.debugSimulate and "|cff00ff00ON|r" or "|cffff4444OFF|r") .. ".")
        return
    end

    -- Default: quick group/cache/state dump.
    print(string.format("Bridge: real=%s override=%s simulate=%s loginPhase=%s",
        tostring(NS.bridgeState),
        tostring(NS.debugBridgeOverride or "none"),
        tostring(NS.debugSimulate),
        tostring(NS.loginPhaseActive)))

    local prefix, n = NS.CB_GroupInfo()
    print(string.format("Group: type=%s count=%d  (party=%d raid=%d)",
        prefix, n, GetNumPartyMembers(), GetNumRaidMembers()))

    -- Walk the resolved group (skips the player), reporting per-member state.
    NS.CB_ForEachGroupMember(function(unit, name)
        local _, class = UnitClass(unit)
        local key      = name and strlower(name)
        print(string.format("  %s name=%s exists=%s isPlayer=%s class=%s inCache=%s probed=%s awaiting=%s",
            unit,
            tostring(name),
            tostring(UnitExists(unit)),
            tostring(UnitIsPlayer(unit)),
            tostring(class),
            tostring(key and CleanBot_PartyBots[key] ~= nil),
            tostring(key and NS.probed[key] == true),
            tostring(key and NS.awaitingProbe[key] == true)))
    end)

    print("KnownBots cache:")
    local count = 0
    for k, v in pairs(CleanBot_PartyBots) do
        print("  " .. k .. " = " .. tostring(v.class))
        count = count + 1
    end
    if count == 0 then print("  (empty)") end
end
