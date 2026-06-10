-- ============================================================
-- Debug.lua  —  developer diagnostics: the debug-state setters (shared by
-- the /cbdebug subcommands and the Settings → Debug tab), the KnownBots
-- popup window, the /cbdebug chat dump, the /cbtiming whisper-latency
-- measurer, and the /cbinspect NotifyInspect trace.
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
-- Debug state setters — the single source of truth for changing debug
-- options. Both the /cbdebug subcommands and the Settings → Debug tab route
-- through these, so chat and UI always agree. Each setter persists to
-- SavedVars, prints the change, and refreshes the Debug tab if it's built
-- (NS.CB_RefreshDebugTab is defined by SettingsTab.lua at build time).
-- ============================================================

local function CB_RefreshDebugTabIfBuilt()
    if NS.CB_RefreshDebugTab then NS.CB_RefreshDebugTab() end
end

-- Sets/clears the bridge override and re-syncs so the new effective state
-- applies immediately (roster/inventory/quests re-fetch via the right path)
-- instead of waiting for the next window open.
---@param value string|nil  "present" | "absent" | nil (= auto, follow handshake).
NS.CB_SetBridgeOverride = function(value)
    NS.debugBridgeOverride = value
    if CleanBot_SavedVars then CleanBot_SavedVars.debugBridgeOverride = value end
    if value == "absent" then
        NS.CB_Print("Bridge override set to |cffff4444absent|r (whisper fallback).")
    elseif value == "present" then
        NS.CB_Print("Bridge override set to |cff00ff00present|r (bridge path).")
    else
        NS.CB_Print("Bridge override cleared — following real handshake (" .. NS.bridgeState .. ").")
    end
    NS.CB_RequestSync()
    CB_RefreshDebugTabIfBuilt()
end

---@param on boolean  Whether CB_SendBotCommand prints instead of sending.
NS.CB_SetDebugSimulate = function(on)
    NS.debugSimulate = on and true or false
    if CleanBot_SavedVars then CleanBot_SavedVars.debugSimulate = NS.debugSimulate end
    NS.CB_Print("Simulate mode: " .. (NS.debugSimulate and "|cff00ff00ON|r" or "|cffff4444OFF|r") .. ".")
    CB_RefreshDebugTabIfBuilt()
end

---@param on boolean  Whether strategy toggles log optimistic-vs-actual mismatches.
NS.CB_SetDebugVerify = function(on)
    NS.debugVerify = on and true or false
    if CleanBot_SavedVars then CleanBot_SavedVars.debugVerify = NS.debugVerify end
    NS.CB_Print("Strategy verify logging: " .. (NS.debugVerify and "|cff00ff00ON|r" or "|cffff4444OFF|r") .. ".")
    CB_RefreshDebugTabIfBuilt()
end

-- Shows/hides the Settings → Debug sub-tab (persisted). The tab widget itself
-- is managed by SettingsTab.lua via NS.CB_SetDebugTabVisible.
---@param on boolean  Whether the Debug sub-tab is available in Settings.
NS.CB_SetDebugTabEnabled = function(on)
    NS.debugTabEnabled = on and true or false
    if CleanBot_SavedVars then CleanBot_SavedVars.debugTabEnabled = NS.debugTabEnabled end
    if NS.CB_SetDebugTabVisible then NS.CB_SetDebugTabVisible(NS.debugTabEnabled) end
    NS.CB_Print("Debug tab " .. (NS.debugTabEnabled
        and "|cff00ff00enabled|r — see Settings."
        or  "|cffff4444disabled|r."))
end

-- ============================================================
-- /cbdebug  — quick party/cache dump + debug option subcommands
--
--   /cbdebug enable        — show the Debug sub-tab in Settings (persisted)
--   /cbdebug disable       — hide the Debug sub-tab
--   /cbdebug bridge off    — force bridge absent (uses whisper fallback)
--   /cbdebug bridge on     — force bridge present (uses bridge path)
--   /cbdebug bridge reset  — clear override; follow real handshake result
--   /cbdebug simulate      — toggle simulate mode (print commands instead of sending)
--   /cbdebug verify        — toggle strategy-toggle mismatch logging
-- ============================================================
SLASH_CBDEBUG1 = "/cbdebug"
SlashCmdList["CBDEBUG"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")

    if msg == "enable" then
        NS.CB_SetDebugTabEnabled(true)
        return
    elseif msg == "disable" then
        NS.CB_SetDebugTabEnabled(false)
        return
    elseif msg == "bridge off" then
        NS.CB_SetBridgeOverride("absent")
        return
    elseif msg == "bridge on" then
        NS.CB_SetBridgeOverride("present")
        return
    elseif msg == "bridge reset" then
        NS.CB_SetBridgeOverride(nil)
        return
    elseif msg == "simulate" then
        NS.CB_SetDebugSimulate(not NS.debugSimulate)
        return
    elseif msg == "verify" then
        NS.CB_SetDebugVerify(not NS.debugVerify)
        return
    end

    -- Default: quick group/cache/state dump.
    print(string.format("Bridge: real=%s override=%s simulate=%s verify=%s tabEnabled=%s loginPhase=%s",
        tostring(NS.bridgeState),
        tostring(NS.debugBridgeOverride or "none"),
        tostring(NS.debugSimulate),
        tostring(NS.debugVerify),
        tostring(NS.debugTabEnabled),
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

-- ============================================================
-- /cbtiming  — measures how fast bots whisper replies, to tune
-- NS.WHISPER_SILENCE (the collection silence timeout in Bridge.lua).
--
--   /cbtiming [runs] [botName]   — default 3 runs against the selected bot
--
-- Each run whispers "items" and records:
--   first  = time from send to the FIRST reply line
--   gaps   = time between consecutive reply lines within the burst
-- The silence timeout must cover max(first, maxGap) — it resets on every
-- line, so total reply length is irrelevant. Reports per-run and aggregate
-- stats plus a suggested timeout (2x the worst observation, for headroom).
-- ============================================================
---@class CB_TimingSession
---@field key      string
---@field name     string
---@field runsLeft number
---@field results  table
---@field run      table?  Per-query stats for the in-flight 'items' request.
local timing = nil   ---@type CB_TimingSession?  -- active session, or nil

local timingEvents = CreateFrame("Frame")
timingEvents:RegisterEvent("CHAT_MSG_WHISPER")
timingEvents:SetScript("OnEvent", function(_, _, msg, sender)
    if not timing then return end
    local run = timing.run
    if not run then return end
    if strlower(sender or "") ~= timing.key then return end
    local now = GetTime()
    if not run.firstAt then
        run.firstAt = now
        run.first   = now - run.sendTime
    else
        local gap = now - run.lastAt
        run.gapSum = run.gapSum + gap
        run.gapN   = run.gapN + 1
        if gap > run.maxGap then run.maxGap = gap end
    end
    run.lastAt = now
    run.lines  = run.lines + 1
end)

local timingTicker = CreateFrame("Frame")
timingTicker:Hide()

local function timingStartRun()
    if not timing then return end
    timing.run = {
        sendTime = GetTime(),
        lines    = 0,
        gapSum   = 0,
        gapN     = 0,
        maxGap   = 0,
    }
    NS.CB_SendBotCommand(timing.name, "items")
end

local function timingReport()
    timingTicker:Hide()
    if not timing then return end
    local rs = timing.results
    timing = nil
    if #rs == 0 then
        NS.CB_Print("[timing] No replies received — is the bot online and whispering?")
        return
    end
    local firstSum, firstMax, gapSum, gapN, gapMax = 0, 0, 0, 0, 0
    for i, r in ipairs(rs) do
        local avgGap = r.gapN > 0 and (r.gapSum / r.gapN) or 0
        print(string.format("  run %d: first %.0f ms, %d lines, avg gap %.0f ms, max gap %.0f ms",
            i, r.first * 1000, r.lines, avgGap * 1000, r.maxGap * 1000))
        firstSum = firstSum + r.first
        if r.first > firstMax then firstMax = r.first end
        gapSum = gapSum + r.gapSum
        gapN   = gapN + r.gapN
        if r.maxGap > gapMax then gapMax = r.maxGap end
    end
    local avgFirst = firstSum / #rs
    local avgGap   = gapN > 0 and (gapSum / gapN) or 0
    local worst    = math.max(firstMax, gapMax)
    NS.CB_Print(string.format(
        "[timing] avg first reply %.0f ms (max %.0f) | avg line gap %.0f ms (max %.0f) | suggested NS.WHISPER_SILENCE >= %.2f s (2x worst; currently %.2f s)",
        avgFirst * 1000, firstMax * 1000, avgGap * 1000, gapMax * 1000,
        worst * 2, NS.WHISPER_SILENCE or 0))
end

timingTicker:SetScript("OnUpdate", function()
    if not timing then timingTicker:Hide(); return end
    local run = timing.run
    if not run then timingTicker:Hide(); return end
    local now = GetTime()
    if run.firstAt then
        -- Run is complete after a generous fixed measurement window of silence
        -- (independent of NS.WHISPER_SILENCE, so the tool stays valid while tuning).
        if now - run.lastAt > 1.5 then
            timing.results[#timing.results + 1] = run
            timing.run = nil
            timing.runsLeft = timing.runsLeft - 1
            if timing.runsLeft > 0 then timingStartRun() else timingReport() end
        end
    elseif now - run.sendTime > 5 then
        -- No reply at all: count the run as failed and move on.
        NS.CB_Print("[timing] run got no reply within 5 s — skipping.")
        timing.run = nil
        timing.runsLeft = timing.runsLeft - 1
        if timing.runsLeft > 0 then timingStartRun() else timingReport() end
    end
end)

-- Starts a timing measurement session. Shared by /cbtiming and the Settings →
-- Debug tab's "Measure Reply Timing" button.
---@param runs    number?  How many "items" queries to run (default 3).
---@param botName string?  Target bot name; defaults to the selected bot, then any known bot.
NS.CB_RunTimingMeasure = function(runs, botName)
    if timing then NS.CB_Print("[timing] already measuring — wait for the report.") return end
    if NS.debugSimulate then
        NS.CB_Print("[timing] simulate mode is ON — commands aren't actually sent. Turn simulate off first.")
        return
    end
    local key, entry
    if botName and botName ~= "" then
        key   = strlower(botName)
        entry = CleanBot_PartyBots[key]
    else
        key   = NS.selectedBotKey
        entry = key and CleanBot_PartyBots[key]
        if not entry then
            for k, e in pairs(CleanBot_PartyBots) do key = k; entry = e; break end
        end
    end
    if not entry then
        NS.CB_Print("[timing] no known bot to measure (open the Individual tab or pass a name).")
        return
    end
    timing = {
        key      = key,
        name     = entry.name,
        runsLeft = runs or 3,
        results  = {},
    }
    NS.CB_Print(string.format("[timing] measuring %s with %d 'items' queries...", entry.name, timing.runsLeft))
    timingStartRun()
    timingTicker:Show()
end

SLASH_CBTIMING1 = "/cbtiming"
SlashCmdList["CBTIMING"] = function(msg)
    local runsArg, nameArg = msg:match("^%s*(%d*)%s*(%S*)")
    NS.CB_RunTimingMeasure(tonumber(runsArg), nameArg ~= "" and nameArg or nil)
end

-- ============================================================
-- /cbinspect — traces every NotifyInspect call (from ANY addon), to diagnose
-- something other than CleanBot inspecting in the background and evicting the
-- single-unit equipment-inspect cache (rich tooltips reverting to generic).
--   source=CleanBot   → our own inspect (Equip.lua / SelectBot / OnEnter reclaim)
--   source=EXTERNAL   → another addon is inspecting.
-- The printed stack line identifies the caller's file.
-- ============================================================
NS.debugInspectTrace = false   -- session-only; deliberately NOT persisted
local cbInspectHooked = false

-- Enables/disables the NotifyInspect trace. Shared by /cbinspect and the
-- Settings → Debug tab checkbox. The hooksecurefunc is installed once on
-- first enable (hooks can't be removed; the flag gates the output).
---@param on boolean  Whether to print every NotifyInspect call.
NS.CB_SetInspectTrace = function(on)
    NS.debugInspectTrace = on and true or false

    if NS.debugInspectTrace and not cbInspectHooked then
        cbInspectHooked = true
        hooksecurefunc("NotifyInspect", function(unit)
            if not NS.debugInspectTrace then return end
            local stack = debugstack(2, 8, 0) or ""
            -- CleanBot's files all live under the ...\CleanBot\ folder, so a stack
            -- containing "CleanBot" is our own call; anything else is external.
            local mine = stack:find("CleanBot", 1, true) ~= nil
            local name = (unit and UnitName(unit)) or "?"
            print(string.format("|cff%s[CBInspect]|r NotifyInspect(%s = %s)  source=%s",
                mine and "00ff00" or "ff4444",
                tostring(unit), tostring(name),
                mine and "CleanBot" or "EXTERNAL"))
            -- Print the first caller frame (skip the hook frame itself in Debug.lua)
            -- so an external addon's file/line is visible.
            for line in stack:gmatch("[^\r\n]+") do
                if not line:find("Debug.lua", 1, true) then
                    print("    " .. line)
                    break
                end
            end
        end)
    end

    if NS.debugInspectTrace then
        NS.CB_Print("NotifyInspect trace |cff00ff00ON|r — watch for |cffff4444source=EXTERNAL|r lines.")
    else
        NS.CB_Print("NotifyInspect trace |cffff4444OFF|r.")
    end
    if NS.CB_RefreshDebugTab then NS.CB_RefreshDebugTab() end
end

SLASH_CBINSPECT1 = "/cbinspect"
SlashCmdList["CBINSPECT"] = function()
    NS.CB_SetInspectTrace(not NS.debugInspectTrace)
end
