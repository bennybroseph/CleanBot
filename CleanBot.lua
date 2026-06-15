-- ============================================================
-- CleanBot.lua  —  core: namespace, shared utilities, layout
--                  constants, frame shell, top-tab management,
--                  and login init.
--
-- ElvUI/skinning lives in the Skinning\ folder, the bridge/protocol
-- layer in Bridge.lua, and the debug popup in
-- Debug.lua.
-- ============================================================

CleanBotNS = {}
local NS = CleanBotNS

-- ============================================================
-- Shared utilities
-- ============================================================

-- Chat output with the standard CleanBot tag.
---@param msg string  Message to print to the default chat frame.
NS.CB_Print = function(msg)
    print("|cffffcc00CleanBot|r: " .. msg)
end

-- One-shot timer: run fn() once, `delay` seconds from now.
-- Backed by a single shared ticker so repeated calls don't each
-- leak a throwaway frame. Due callbacks run after the scan finishes,
-- so a callback may safely schedule further timers.
local timerFrame = CreateFrame("Frame")
local timers     = {}
timerFrame:SetScript("OnUpdate", function(self, dt)
    local due
    for t in pairs(timers) do
        t.elapsed = t.elapsed + dt
        if t.elapsed >= t.delay then
            due = due or {}
            due[#due + 1] = t
        end
    end
    if due then
        for _, t in ipairs(due) do
            timers[t] = nil
            t.fn()
        end
    end
end)

--- Runs `fn` once after `delay` seconds via a shared one-shot OnUpdate timer.
---@param delay number  Seconds to wait before firing.
---@param fn    fun()   Callback to run when the delay elapses.
NS.CB_After = function(delay, fn)
    timers[{ elapsed = 0, delay = delay, fn = fn }] = true
end

-- Shared full-screen mouse-capture frame. Only one drag can be active at a
-- time (model rotation or an inventory item drag), so a single reusable frame
-- absorbs mouse events for the duration. The caller supplies the OnUpdate and
-- an onStop(button) handler; CB_EndCapture tears them down and hides the frame.
---@param onUpdate fun()              Called every frame while the capture is active.
---@param onStop   fun(button:string) Called on mouse-up with the button name.
---@return table                      The reusable capture frame.
NS.CB_BeginCapture = function(onUpdate, onStop)
    local cap = NS.dragCapture
    if not cap then
        cap = CreateFrame("Frame", "CleanBotDragCapture", UIParent)
        cap:SetAllPoints(UIParent)
        cap:SetFrameStrata("FULLSCREEN_DIALOG")
        cap:EnableMouse(true)
        cap:Hide()
        NS.dragCapture = cap
    end
    cap:SetScript("OnUpdate", onUpdate)
    cap:SetScript("OnMouseUp", onStop and function(self, button) onStop(button) end or nil)
    cap:Show()
    return cap
end

--- Tears down the shared mouse-capture frame started by CB_BeginCapture.
NS.CB_EndCapture = function()
    local cap = NS.dragCapture
    if cap then
        cap:SetScript("OnUpdate", nil)
        cap:SetScript("OnMouseUp", nil)
        cap:Hide()
    end
end

-- ============================================================
-- Tooltips — one place that owns the GameTooltip OnEnter/OnLeave boilerplate
-- (SetOwner + anchor, Show, and Hide), so call sites only describe content.
-- ============================================================

-- Runs fn(frame) for a single frame or each frame in an array. Lets the tooltip
-- helpers attach the same tooltip to, e.g., a checkbox and its label hit-area.
---@param frameOrList table  A frame (has :SetScript) or an array of frames.
---@param fn          fun(frame:table)
local function CB_ForEachFrame(frameOrList, fn)
    if frameOrList.SetScript then
        fn(frameOrList)
    else
        for _, f in ipairs(frameOrList) do fn(f) end
    end
end

-- Attaches a GameTooltip to a frame (or list of frames). `populate(GameTooltip, self)` fills the
-- tooltip's content on hover; the helper owns SetOwner/Show and the OnLeave Hide. Return false
-- from `populate` to suppress the tooltip (e.g. an item slot with nothing in it). `onLeave(self)`
-- is an optional cleanup run on mouse-out (after Hide) for sites that also drive a hover highlight.
---@param frame    table                              A frame, or an array of frames sharing the tip.
---@param populate fun(tt:table, self:table):boolean? Fills the tooltip; return false to suppress.
---@param anchor   string?                            GameTooltip anchor point (default "ANCHOR_RIGHT").
---@param onLeave  fun(self:table)?                   Optional mouse-out cleanup (e.g. clear a highlight).
NS.CB_AttachTooltip = function(frame, populate, anchor, onLeave)
    CB_ForEachFrame(frame, function(f)
        f:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
            if populate(GameTooltip, self) == false then
                GameTooltip:Hide()
            else
                GameTooltip:Show()
            end
        end)
        f:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            if onLeave then onLeave(self) end
        end)
    end)
end

-- Convenience over CB_AttachTooltip for text tooltips, in the standard WoW style: a gold `title`
-- header and a white wrapped `desc` body. Each may be a string, a fn()->string (for state-
-- dependent text), or nil — pass a short header as `title` and explanatory/status text as `desc`.
---@param frame  table              A frame, or an array of frames sharing the tip.
---@param title  string|fun():string|nil  Gold header line (short).
---@param desc   string|fun():string|nil  White wrapped body line.
---@param anchor string?           GameTooltip anchor point (default "ANCHOR_RIGHT").
NS.CB_SetTooltip = function(frame, title, desc, anchor)
    NS.CB_AttachTooltip(frame, function(tt)
        local t = type(title) == "function" and title() or title
        local d = type(desc)  == "function" and desc()  or desc
        if not t and not d then return false end
        if t then tt:AddLine(t, NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b) end          -- gold header
        if d then tt:AddLine(d, HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b, true) end  -- white body
    end, anchor)
end

-- ============================================================
-- Group iteration (party OR raid)
-- ============================================================
-- WoW addresses group members differently depending on group type: "partyN"
-- (1..GetNumPartyMembers, excludes the player) when in a party, but "raidN"
-- (1..GetNumRaidMembers, INCLUDES the player) when in a raid — and party APIs
-- return 0 while in a raid. These helpers paper over that so callers work for
-- both. Use them instead of hardcoding GetNumPartyMembers / "party"..i.

--- Returns the unit-id prefix and member count for the player's current group.
--- Raid takes precedence over party; both 0 when solo. In a raid the count
--- INCLUDES the player, so member iteration must skip the player's own unit.
---@return string prefix  "raid" or "party".
---@return number count   Number of group members (raid count includes the player).
NS.CB_GroupInfo = function()
    local nRaid = GetNumRaidMembers()
    if nRaid > 0 then return "raid", nRaid end
    return "party", GetNumPartyMembers()
end

--- True when the player is in any group (party or raid).
---@return boolean
NS.CB_InGroup = function()
    return GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0
end

--- Calls fn(unit, name) for each OTHER group member (the player is skipped).
--- Works for both party and raid. name may be nil if the unit is not yet known.
---@param fn fun(unit:string, name:string|nil)
NS.CB_ForEachGroupMember = function(fn)
    local prefix, n = NS.CB_GroupInfo()
    for i = 1, n do
        local unit = prefix .. i
        if not UnitIsUnit(unit, "player") then
            fn(unit, UnitName(unit))
        end
    end
end

-- Splits a string on the first occurrence of a (plain, non-pattern) separator.
-- Used heavily by Bridge.lua to parse "~"-delimited MBOT packets.
---@param str string  The string to split.
---@param sep string  The separator to split on (matched literally, not as a pattern).
---@return string      The part before the separator.
---@return string|nil  The part after the separator, or "" if sep was not found.
NS.CB_SplitOnce = function(str, sep)
    local i = strfind(str, sep, 1, true)
    if i then return strsub(str, 1, i - 1), strsub(str, i + 1) end
    return str, ""
end

-- ============================================================
-- Config + bot detection cache
-- ============================================================
CleanBot_PartyBots = {}  -- global so other modules and XML scripts can reach it

-- ============================================================
-- Layout constants
-- ============================================================
NS.EXPANDED_WIDTH    = 850
NS.FRAME_HEIGHT      = 600
NS.TAB_WIDTH         = 88
NS.TAB_HEIGHT        = 24
NS.TITLE_H           = 28
NS.PAD               = 6
NS.COLUMN_GAP        = 4   -- horizontal space between side-by-side column pairs
NS.MODEL_GAP         = 25  -- gap between the model panel and the strategy panel in the Individual tab
-- Fixed model render width. Pinned to a constant (the value the old modelH*0.7 formula produced
-- at the original 560-tall frame) so the model column — and thus the strategy-panel width — stays
-- static regardless of FRAME_HEIGHT. Adjust here if the model looks too wide/narrow.
NS.MODEL_WIDTH       = 270
NS.TOP_BAR_H         = NS.TAB_HEIGHT + 8
NS.BOT_BAR_H         = NS.TAB_HEIGHT + 8
-- Individual-tab bot selector: ≤ threshold bots show the tab row; more swap to a
-- dropdown. MAX_LIVE_SLOTS caps how many bots keep heavy content (3D model + equip
-- paperdoll) bound at once — an LRU evicts beyond it so large raids never build
-- dozens of models. Must be ≥ TAB_DROPDOWN_THRESHOLD so tab mode is always fully warm.
NS.TAB_DROPDOWN_THRESHOLD = 4
NS.MAX_LIVE_SLOTS         = 6
-- Per-frame padding — space between a frame's border and the content inside it (CSS padding).
-- frame:   outermost window (CleanBotFrame)
-- panel:   main panels and column containers (managePanel, individualPanel, ctrl, left/right columns)
-- section: strategy section frames (the bordered checkbox groups in the Individual tab)
NS.PADDING_DEFAULTS = {
    frame   = { top = 32, bottom = 16, left = 16, right = 16 },
    panel   = { top = 6,  bottom = 6,  left = 6,  right = 6  },
    section = { top = 4,  bottom = 4,  left = 4,  right = 4  },
}
-- Working copy — mutated at login from SavedVars, and by the Settings Apply button.
NS.PADDING = {}
for k, v in pairs(NS.PADDING_DEFAULTS) do
    NS.PADDING[k] = { top = v.top, bottom = v.bottom, left = v.left, right = v.right }
end
-- Per-element margins — each widget declares the space it needs above and below.
-- Gap between two elements = above.marginBottom + below.marginTop (additive, like CSS margins).
NS.MARGIN_DEFAULTS = {
    -- Widget types — space a widget reserves around itself within a flow.
    header   = { top = 10, bottom = 4, left = 0,   right = 0 },
    label    = { top = 6,  bottom = 2, left = 0,   right = 0 },
    button   = { top = 2,  bottom = 2, left = 0,   right = 2 },
    tab      = { top = 2,  bottom = 2, left = 0,   right = 4 },
    slider   = { top = 2,  bottom = 4, left = 4,   right = 4 },
    dropdown = { top = 2,  bottom = 2, left = -16, right = 2 },
    checkbox = { top = 2,  bottom = 2, left = 0,   right = 2 },
    swatch   = { top = 2,  bottom = 2, left = 4,   right = 2 },
    editBox  = { top = 2,  bottom = 2, left = 4,   right = 2 },
    -- Frame types — extra breathing room a child frame adds on top of its
    -- parent's padding when placed via CB_CreateInnerFrame.
    panel    = { top = 0, bottom = 0, left = 0, right = 0 },
    section  = { top = 0, bottom = 0, left = 0, right = 0 },
}
-- Canonical defaults for theme settings — read by the Defaults button.
-- accentColor.a is set to the skin-appropriate value at PLAYER_LOGIN (after ElvUI detection):
--   0 (fully transparent) for plain Blizzard UI — no visible border tint by default.
--   1 (fully opaque)      for ElvUI             — matches ElvUI's solid border style.
NS.THEME_DEFAULTS = {
    scale        = 100,
    transparency = 90,
    accentColor  = { r = 0.0, g = 0.0, b = 0.0, a = 0 },
}

-- Feature flags and theme values — mutated at login from SavedVars, and by the Settings Apply button.
NS.botEmotes    = true
NS.itemGlow     = true   -- Blizz-path rarity overlay on items/equipment (uncommon+); see ItemVisuals
NS.hideBotChatter = true -- hide CleanBot's own whisper/command spam from chat; see ChatFilter.lua
NS.manageSelf   = false  -- preference: auto-enable self-bot on fresh login; see Bridge self-bot section
NS.selfBotActive = false -- live state: is the player currently a self-bot (driven by server botAI messages)
NS.scale        = NS.THEME_DEFAULTS.scale
NS.transparency = NS.THEME_DEFAULTS.transparency
NS.accentColor  = { r = NS.THEME_DEFAULTS.accentColor.r, g = NS.THEME_DEFAULTS.accentColor.g, b = NS.THEME_DEFAULTS.accentColor.b, a = NS.THEME_DEFAULTS.accentColor.a }

-- Working copy — mutated at login from SavedVars, and by the Settings Apply button.
NS.MARGIN = {}
for k, v in pairs(NS.MARGIN_DEFAULTS) do
    NS.MARGIN[k] = { top = v.top, bottom = v.bottom, left = v.left, right = v.right }
end
-- Vertical space reserved below the model for the weapon-slot row.
-- The model height = contentH - EQUIP_WEAPON_PAD, weapon slots sit in that gap.
NS.EQUIP_WEAPON_PAD  = 60

-- ============================================================
-- Persistent sub-frame references (assigned in NS.CB_BuildFrames)
-- ============================================================
NS.topTabBar     = nil
NS.contentFrame  = nil
NS.individualPanel        = nil
NS.botTabBar         = nil
NS.individualContent      = nil
NS.individualModelPanel   = nil
NS.individualStratPanel   = nil
NS.individualExpandBtn    = nil
NS.individualEmptyLabel   = nil
NS.individualExpanded     = false
NS.COLLAPSED_WIDTH   = nil  -- computed in CleanBot_BuildIndividualTab after geometry is known
NS.managePanel      = nil
NS.manageScrollFrame = nil
NS.manageScrollChild = nil
NS.groupPanel    = nil
NS.settingsPanel = nil

-- ============================================================
-- Top-level tab management  (Manage = 1, Individual = 2, Group = 3, Settings = 4)
-- ============================================================
NS.activeTopTabIndex = 0
NS.topTabs           = {}

-- Resizes CleanBotFrame to `width`, re-anchoring from TOPLEFT first so the
-- frame grows/shrinks from its right edge rather than from its center.
-- Falls back to SetWidth-only if GetLeft/GetTop return nil (frame never shown).
---@param width number  New frame width in pixels.
NS.CB_ResizeFrame = function(width)
    local left = CleanBotFrame:GetLeft()
    local top  = CleanBotFrame:GetTop()
    if left and top then
        CleanBotFrame:ClearAllPoints()
        CleanBotFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
    CleanBotFrame:SetWidth(width)
end

-- Target width for the CURRENT top tab: Individual restores the saved expand state; Group is always
-- expanded while bots are present (no collapse affordance) and follows the saved state only in the
-- empty-roster case; other tabs use collapsed width. Returns nil before COLLAPSED_WIDTH is computed.
---@return number?  Target frame width, or nil if geometry isn't ready yet.
NS.CB_CurrentTargetWidth = function()
    if not NS.COLLAPSED_WIDTH then return nil end
    local savedW = NS.individualExpanded and NS.EXPANDED_WIDTH or NS.COLLAPSED_WIDTH
    local index  = NS.activeTopTabIndex
    if index == 2 then
        return savedW
    elseif index == 3 then
        local haveBots = NS.desiredBots and #NS.desiredBots > 0
        return haveBots and NS.EXPANDED_WIDTH or savedW
    end
    return NS.COLLAPSED_WIDTH
end

--- Selects the top-level tab at `index`, showing its panel and deactivating the rest.
---@param index number  1-based index of the tab to activate.
NS.CleanBot_SelectTopTab = function(index)
    if NS.activeTopTabIndex == index then return end
    NS.activeTopTabIndex = index

    for i, tab in ipairs(NS.topTabs) do
        tab:SetActive(i == index)
    end

    if NS.managePanel     then if index == 1 then NS.managePanel:Show()     else NS.managePanel:Hide()     end end
    if NS.individualPanel    then if index == 2 then NS.individualPanel:Show()    else NS.individualPanel:Hide()    end end
    if NS.groupPanel    then if index == 3 then NS.groupPanel:Show()    else NS.groupPanel:Hide()    end end
    if NS.settingsPanel then if index == 4 then NS.settingsPanel:Show() else NS.settingsPanel:Hide() end end
    if NS.individualExpandBtn then if index == 2 then NS.individualExpandBtn:Show() else NS.individualExpandBtn:Hide() end end

    -- Resize the frame: Individual restores the saved expand state; Group is always
    -- expanded while bots are present (no collapse affordance) and follows the saved
    -- state only in the empty roster case; other tabs use collapsed width.
    local targetW = NS.CB_CurrentTargetWidth()
    if targetW then NS.CB_ResizeFrame(targetW) end

    if index == 2 then
        for i, info in ipairs(NS.tabList or {}) do
            if info.model then
                if i == NS.selectedTabIndex then info.model:Show() else info.model:Hide() end
            end
        end
    else
        for _, info in ipairs(NS.tabList or {}) do
            if info.model then info.model:Hide() end
        end
    end
end

-- ============================================================
-- Frame construction (called once at PLAYER_LOGIN)
-- NS.CleanBot_BuildIndividualTab / NS.CleanBot_BuildManageTab /
-- NS.CleanBot_BuildSettingsTab /
-- NS.CleanBot_RefreshTabs are all defined in the files that load after this one.
-- They are only ever called at event time (never at load time), so the forward
-- references are fine.
-- ============================================================
--- Builds the main CleanBot window and all its tab panels. Called once at PLAYER_LOGIN.
NS.CB_BuildFrames = function()
    -- Static frame size — shrunk to collapsed width after BuildFrames if needed
    CleanBotFrame:SetWidth(NS.EXPANDED_WIDTH)
    CleanBotFrame:SetHeight(NS.FRAME_HEIGHT)

    -- Stamp padding fields so child anchors can read CleanBotFrame.paddingXxx
    -- directly rather than going through the raw NS.PADDING.frame globals.
    -- CleanBotFrame is XML-defined so CB_CreatePanel never runs on it.
    local framePad = NS.PADDING.frame
    CleanBotFrame.paddingTop    = framePad.top
    CleanBotFrame.paddingBottom = framePad.bottom
    CleanBotFrame.paddingLeft   = framePad.left
    CleanBotFrame.paddingRight  = framePad.right
    CleanBotFrame._paddingRole  = "frame"        -- re-stamped from NS.PADDING.frame on layout change
    NS.CB_RegisterStampable(CleanBotFrame)

    -- ── Top tab bar ────────────────────────────────────────────
    NS.topTabBar = CreateFrame("Frame", "CleanBotTopTabBar", CleanBotFrame)
    NS.topTabBar:SetPoint("TOPLEFT",  CleanBotFrame, "TOPLEFT",  0, -NS.TITLE_H)
    NS.topTabBar:SetPoint("TOPRIGHT", CleanBotFrame, "TOPRIGHT", 0, -NS.TITLE_H)
    NS.topTabBar:SetHeight(NS.TOP_BAR_H)

    local tabLabels = { "Manage", "Individual", "Group", "Settings" }
    local prevTopTab = nil
    for i, label in ipairs(tabLabels) do
        local idx = i
        local tab = NS.CB_CreateTab(NS.topTabBar, "CleanBotTopTab" .. i, label,
                                    function() NS.CleanBot_SelectTopTab(idx) end)
        tab:SetWidth(NS.TAB_WIDTH)
        if prevTopTab then
            NS.CB_AnchorAhead(tab, prevTopTab)
        else
            NS.CB_Anchor(tab, function()
                tab:ClearAllPoints()
                tab:SetPoint("LEFT", NS.topTabBar, "LEFT", CleanBotFrame.paddingLeft + (tab.marginLeft or 0), 0)
            end)
        end
        prevTopTab  = tab
        NS.topTabs[i] = tab
    end

    -- ── Content frame ──────────────────────────────────────────
    NS.contentFrame = CreateFrame("Frame", "CleanBotContentFrame", CleanBotFrame)
    NS.CB_Anchor(NS.contentFrame, function()
        NS.contentFrame:ClearAllPoints()
        NS.contentFrame:SetPoint("TOPLEFT",     CleanBotFrame, "TOPLEFT",      CleanBotFrame.paddingLeft,   -(NS.TITLE_H + NS.TOP_BAR_H))
        NS.contentFrame:SetPoint("BOTTOMRIGHT", CleanBotFrame, "BOTTOMRIGHT", -CleanBotFrame.paddingRight,    CleanBotFrame.paddingBottom)
    end)
    NS.CB_ApplyFrameSkin(NS.contentFrame, 1)

    -- ── Individual panel ───────────────────────────────────────
    -- Defined in Individual/Individual.lua (loads after this file).
    NS.CleanBot_BuildIndividualTab()

    -- ── Manage panel ───────────────────────────────────────────
    -- Defined in ManageTab.lua (loads after this file).
    NS.CleanBot_BuildManageTab()

    -- ── Group panel ────────────────────────────────────────────
    -- Defined in GroupTab.lua (loads after this file). Must run after
    -- CleanBot_BuildIndividualTab: it reads NS.individualModelPanel's width so
    -- the mirrored strategy panel lines up with the Individual tab's.
    NS.CleanBot_BuildGroupTab()

    -- ── Settings panel ─────────────────────────────────────────
    -- Defined in SettingsTab.lua (loads after this file).
    NS.CleanBot_BuildSettingsTab()

    if NS.ElvUI_S then
        CleanBotFrame:StripTextures()
        NS.ElvUI_S:HandleCloseButton(CleanBotFrameCloseButton)
    end
    NS.CB_ApplyFrameSkin(CleanBotFrame, 0)
    -- Hide the XML-defined ARTWORK FontString — CB_ApplyTitleBar creates its own
    -- OVERLAY replacement so it renders above the ornament texture.
    CleanBotFrameTitle:Hide()
    NS.CB_ApplyTitleBar(CleanBotFrame, "CleanBot")

    NS.CleanBot_SelectTopTab(1)
end

-- ============================================================
-- Initialize at login (ElvUI is ready by PLAYER_LOGIN)
-- ============================================================
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        NS.CB_InitElvUI()

        -- Set the skin-appropriate default accent alpha now that ElvUI detection has run.
        -- This must happen before SavedVars are applied so that the Defaults button in
        -- Settings shows the correct value, and so that NS.accentColor starts at the
        -- right value when no saved data exists yet.
        local defaultAccentColor  = NS.ElvUI_S and { r = 0.0, g = 0.0, b = 0.0, a = 1 } or { r = 1.0, g = 1.0, b = 1.0, a = 1 }
        local defaultTransparency = NS.ElvUI_S and 75 or 90
        NS.THEME_DEFAULTS.accentColor   = defaultAccentColor
        NS.THEME_DEFAULTS.transparency  = defaultTransparency
        NS.transparency                 = defaultTransparency

        -- Initialize saved variables, preserving any existing data
        if type(CleanBot_SavedVars) ~= "table" then CleanBot_SavedVars = {} end
        if type(CleanBot_SavedVars.collapsedSections)   ~= "table" then CleanBot_SavedVars.collapsedSections   = {} end
        if type(CleanBot_SavedVars.presets)             ~= "table" then CleanBot_SavedVars.presets             = {} end
        if type(CleanBot_SavedVars.botGroups)           ~= "table" then CleanBot_SavedVars.botGroups           = {} end

        -- Seed the protected "Favorites" preset, migrating the old favoriteBots set
        -- (format: { [lowercaseName] = true }) into the preset array format on first run.
        if type(CleanBot_SavedVars.presets["Favorites"]) ~= "table" then
            local migrated = {}
            if type(CleanBot_SavedVars.favoriteBots) == "table" then
                for key in pairs(CleanBot_SavedVars.favoriteBots) do
                    migrated[#migrated + 1] = key:sub(1, 1):upper() .. key:sub(2)
                end
                table.sort(migrated)
            end
            CleanBot_SavedVars.presets["Favorites"] = migrated
        end
        CleanBot_SavedVars.favoriteBots = nil  -- drop old storage key after migration

        -- Restore feature flags.
        if type(CleanBot_SavedVars.botEmotes) == "boolean" then
            NS.botEmotes = CleanBot_SavedVars.botEmotes
        end
        if type(CleanBot_SavedVars.itemGlow) == "boolean" then
            NS.itemGlow = CleanBot_SavedVars.itemGlow
        end
        if type(CleanBot_SavedVars.hideBotChatter) == "boolean" then
            NS.hideBotChatter = CleanBot_SavedVars.hideBotChatter
        end
        if type(CleanBot_SavedVars.manageSelf) == "boolean" then
            NS.manageSelf = CleanBot_SavedVars.manageSelf
        end
        -- Live self-bot state is only trusted on a /reload; PLAYER_ENTERING_WORLD forces
        -- it false on a fresh login (the character always spawns with self-bot off).
        if type(CleanBot_SavedVars.selfBotActive) == "boolean" then
            NS.selfBotActive = CleanBot_SavedVars.selfBotActive
        end
        NS.individualExpanded = CleanBot_SavedVars.individualExpanded == true

        -- Restore debug overrides (persist across logout so start-to-finish
        -- flows can be tested). Only the two valid override values are accepted.
        if CleanBot_SavedVars.debugBridgeOverride == "present"
        or CleanBot_SavedVars.debugBridgeOverride == "absent" then
            NS.debugBridgeOverride = CleanBot_SavedVars.debugBridgeOverride
        end
        if type(CleanBot_SavedVars.debugSimulate) == "boolean" then
            NS.debugSimulate = CleanBot_SavedVars.debugSimulate
        end
        if type(CleanBot_SavedVars.debugVerify) == "boolean" then
            NS.debugVerify = CleanBot_SavedVars.debugVerify
        end
        if type(CleanBot_SavedVars.debugTabEnabled) == "boolean" then
            NS.debugTabEnabled = CleanBot_SavedVars.debugTabEnabled
        end

        -- Restore theme values.
        if type(CleanBot_SavedVars.scale) == "number" then
            NS.scale = CleanBot_SavedVars.scale
        end
        if type(CleanBot_SavedVars.transparency) == "number" then
            NS.transparency = CleanBot_SavedVars.transparency
        end
        if type(CleanBot_SavedVars.accentColor) == "table" then
            local ac = CleanBot_SavedVars.accentColor
            if type(ac.r) == "number" then NS.accentColor.r = ac.r end
            if type(ac.g) == "number" then NS.accentColor.g = ac.g end
            if type(ac.b) == "number" then NS.accentColor.b = ac.b end
            if type(ac.a) == "number" then NS.accentColor.a = ac.a end
        end

        -- Restore saved margin values, filling in any missing keys with defaults.
        if type(CleanBot_SavedVars.margins) ~= "table" then CleanBot_SavedVars.margins = {} end
        for k, defaults in pairs(NS.MARGIN) do
            local saved = CleanBot_SavedVars.margins[k]
            if type(saved) == "table" then
                if type(saved.top)    == "number" then NS.MARGIN[k].top    = saved.top    end
                if type(saved.bottom) == "number" then NS.MARGIN[k].bottom = saved.bottom end
                if type(saved.left)   == "number" then NS.MARGIN[k].left   = saved.left   end
                if type(saved.right)  == "number" then NS.MARGIN[k].right  = saved.right  end
            end
        end

        -- Restore saved padding values, filling in any missing keys with defaults.
        if type(CleanBot_SavedVars.padding) ~= "table" then CleanBot_SavedVars.padding = {} end
        for k, defaults in pairs(NS.PADDING) do
            local saved = CleanBot_SavedVars.padding[k]
            if type(saved) == "table" then
                if type(saved.top)    == "number" then NS.PADDING[k].top    = saved.top    end
                if type(saved.bottom) == "number" then NS.PADDING[k].bottom = saved.bottom end
                if type(saved.left)   == "number" then NS.PADDING[k].left   = saved.left   end
                if type(saved.right)  == "number" then NS.PADDING[k].right  = saved.right  end
            end
        end

        NS.CB_RegisterRootFrame(CleanBotFrame)
        NS.CB_BuildFrames()
        -- SelectTopTab(1) inside BuildFrames already sized the frame to COLLAPSED_WIDTH.
        -- Apply saved expand state visibility: hide the strategy panel unless expanded.
        if NS.individualStratPanel and not NS.individualExpanded then
            NS.individualStratPanel:Hide()
        end
        if NS.individualExpandBtn then
            NS.individualExpandBtn:SetText(NS.individualExpanded and "<" or ">")
        end
        -- One apply path shared with Settings Apply: emit the display-setting events so the
        -- theme subscribers re-apply scale/transparency/accent. (Accent is also baked in during
        -- the CB_ApplyFrameSkin calls inside CB_BuildFrames; emitting it again is harmless.)
        NS.CB_EmitDisplaySettings()
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

print("CleanBot loaded! Type /cleanbot to open.")
