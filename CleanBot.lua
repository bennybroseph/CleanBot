-- ============================================================
-- CleanBot.lua
-- ============================================================

-- ============================================================
-- ElvUI handles + fallback backdrop
-- Declared at the top so every function below can close over them.
-- ElvUI_S is populated at PLAYER_LOGIN once ElvUI is ready.
-- ============================================================
local ElvUI_E = nil
local ElvUI_S = nil

local PLAIN_BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- ============================================================
-- Debug: KnownBots popup window (created lazily, reused)
-- ============================================================
local debugKnownBotsFrame = nil
local lastRawStates  = nil   -- stores the most recent raw STATES payload for diagnosis
local lastHelloAck   = nil   -- stores the most recent HELLO_ACK for diagnosis
local bridgeReady    = false -- set true once HELLO_ACK is received

local function CB_FormatKnownBots()
    local lines = {
        "=== Handshake ===",
        "bridgeReady: " .. tostring(bridgeReady),
        "Last HELLO_ACK: " .. (lastHelloAck or "(none received yet)"),
        "",
        "=== Last raw STATES payload ===",
        lastRawStates or "(none received yet)",
        "",
        "=== Parsed KnownBots ===",
        "",
    }
    local count = 0
    for key, bot in pairs(CleanBot_KnownBots) do
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
            table.sort(active)
            table.sort(inactive)
            table.sort(unknown)
            if #active  > 0 then lines[#lines + 1] = "  |cff00ff00ON |r  " .. table.concat(active,   "  ") end
            if #inactive > 0 then lines[#lines + 1] = "  |cffff4444OFF|r  " .. table.concat(inactive, "  ") end
            if #unknown  > 0 then lines[#lines + 1] = "  |cffaaaaaa?  |r  " .. table.concat(unknown,  "  ") end
        else
            lines[#lines + 1] = "  (no combat data)"
        end
        lines[#lines + 1] = ""  -- blank separator between bots
    end
    if count == 0 then
        return "(CleanBot_KnownBots is empty)"
    end
    return table.concat(lines, "\n")
end

local function CB_ShowKnownBotsDebug()
    local screenH  = UIParent:GetHeight()
    local winW     = 520
    local winH     = math.floor(screenH / 2)
    local titleH   = 24
    local footerH  = 32
    local padH     = 8

    if not debugKnownBotsFrame then
        -- ── Outer window ────────────────────────────────────────
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

        if ElvUI_S then
            f:SetTemplate("Default")
        else
            f:SetBackdrop(PLAIN_BACKDROP)
            f:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
            f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        end

        -- Title
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", f, "TOP", 0, -8)
        title:SetText("CleanBot — KnownBots")

        -- Footer buttons
        local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        closeBtn:SetSize(80, 22)
        closeBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 6)
        closeBtn:SetText("Close")
        closeBtn:SetScript("OnClick", function() f:Hide() end)
        if ElvUI_S then ElvUI_S:HandleButton(closeBtn) end

        -- ScrollFrame
        local sf = CreateFrame("ScrollFrame", "CleanBotDebugScroll", f,
                               "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT",     f, "TOPLEFT",     8,  -(titleH + padH))
        sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, footerH + padH)

        -- Scroll child
        local child = CreateFrame("Frame", nil, sf)
        child:SetWidth(sf:GetWidth() or (winW - 36))
        sf:SetScrollChild(child)

        -- Text inside scroll child
        local txt = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        txt:SetPoint("TOPLEFT", child, "TOPLEFT", 4, -4)
        txt:SetWidth((sf:GetWidth() or (winW - 36)) - 8)
        txt:SetJustifyH("LEFT")
        txt:SetNonSpaceWrap(false)  -- don't wrap mid-word; let lines be wide

        f.scrollFrame = sf
        f.scrollChild = child
        f.textObj     = txt
        debugKnownBotsFrame = f
    end

    -- Refresh content every time the window is opened.
    local f   = debugKnownBotsFrame
    local txt = f.textObj
    txt:SetText(CB_FormatKnownBots())

    local textH = txt:GetStringHeight()
    f.scrollChild:SetHeight(math.max(textH + 8, 1))

    f:SetHeight(winH)  -- reset to half-screen in case UIParent was resized
    f:Show()
    f.scrollFrame:SetVerticalScroll(0)
end

-- ============================================================
-- Slash commands
-- ============================================================
local function CB_HandleSlash(msg)
    msg = msg:lower():match("^%s*(.-)%s*$")  -- trim + lowercase
    if msg == "debug knownbots" then
        CB_ShowKnownBotsDebug()
    elseif msg == "" then
        if CleanBotFrame:IsShown() then
            CleanBotFrame:Hide()
        else
            CleanBotFrame:Show()
            CleanBot_RequestRosterThenRefresh()
        end
    else
        print("|cffffcc00CleanBot|r: unknown command '" .. msg .. "'")
        print("  /cleanbot               — toggle window")
        print("  /cleanbot debug knownbots — show KnownBots popup")
    end
end

SLASH_CLEANBOT1 = "/cleanbot"
SLASH_CLEANBOT2 = "/cb"
SlashCmdList["CLEANBOT"] = CB_HandleSlash

SLASH_CBDEBUG1 = "/cbdebug"
SlashCmdList["CBDEBUG"] = function()
    local numMembers = GetNumPartyMembers()
    print("Party members:", numMembers)
    for i = 1, numMembers do
        local unit = "party" .. i
        local name = UnitName(unit)
        local exists = UnitExists(unit)
        local isPlayer = UnitIsPlayer(unit)
        local _, class = UnitClass(unit)
        local inCache = name and CleanBot_KnownBots[strlower(name)] ~= nil
        print(string.format("  [%d] name=%s exists=%s isPlayer=%s class=%s inCache=%s",
            i, tostring(name), tostring(exists),
            tostring(isPlayer), tostring(class), tostring(inCache)))
    end
    print("KnownBots cache:")
    local count = 0
    for k, v in pairs(CleanBot_KnownBots) do
        print("  " .. k .. " = " .. tostring(v.class))
        count = count + 1
    end
    if count == 0 then print("  (empty)") end
end

-- ============================================================
-- Config
-- ============================================================
local ASSUME_ALL_PARTY_ARE_BOTS = false

-- ============================================================
-- Bot detection cache
-- ============================================================
CleanBot_KnownBots = {}

-- ============================================================
-- Combat strategy definitions
--
-- Each entry maps the playerbot strategy name (as used by the
-- server's "co" command) to the field name stored in the bot's
-- combat table.  Field naming convention: verbAction, or isThing
-- for role identifiers (following the user's stated examples).
-- ============================================================
local STRATEGY_MAP = {
    -- Core role
    ["tank"]            = "isTank",        -- Use threat-generating abilities
    ["tank assist"]     = "assistTank",    -- Tank pulls mobs off others
    ["dps"]             = "useDps",        -- Use DPS abilities
    ["heal"]            = "doHeal",        -- Focus on party healing

    -- Target selection
    ["assist"]          = "focusTarget",   -- Target one mob at a time
    ["aoe"]             = "useAoe",        -- Target many mobs at a time

    -- CC & threat
    ["cc"]              = "useCC",         -- Use crowd-control abilities
    ["threat"]          = "avoidThreat",   -- DPS actively avoids grabbing threat

    -- Cooldowns & aggression
    ["boost"]           = "useCooldowns",  -- Use major cooldowns
    ["grind"]           = "doGrind",       -- Attack any visible target

    -- Positioning
    ["behind"]          = "moveBehind",    -- Move to target's back when not behind
    ["tank face"]       = "faceTarget",    -- Ensure target does not face ranged players

    -- Spell behaviour
    ["focus"]           = "castFocused",   -- Stop casting AoE or debuff spells
    ["avoid aoe"]       = "avoidAoe",      -- Automatically avoid harmful AoE spells

    -- Healing efficiency
    ["save mana"]       = "saveMana",      -- Healers prioritize high-efficiency spells
    ["healer dps"]      = "healerDps",     -- Healers cast damage spells when mana allows

    -- Pull behaviour
    ["pull"]            = "doPull",        -- Tank pulls mobs using a ranged skill
    ["pull back"]       = "pullBack",      -- Pull mob then return to starting position

    -- Timing & marking
    ["wait for attack"] = "waitAttack",    -- Wait a set time before attacking or healing
    ["mark rti"]        = "markTargets",   -- Automatically mark unmarked combat attackers
}

-- Returns a fresh combat table with every strategy as nil (unknown).
-- nil  = not yet received from server
-- true = confirmed active
-- false = confirmed inactive
local function CB_DefaultCombat()
    return {
        isTank       = nil,  -- Use threat-generating abilities
        assistTank   = nil,  -- Tank pulls mobs off others
        useDps       = nil,  -- Use DPS abilities
        doHeal       = nil,  -- Focus on party healing
        focusTarget  = nil,  -- Target one mob at a time (vs AoE)
        useAoe       = nil,  -- Target many mobs at a time
        useCC        = nil,  -- Use crowd-control abilities
        avoidThreat  = nil,  -- DPS actively avoids grabbing threat
        useCooldowns = nil,  -- Use major cooldowns (boost)
        doGrind      = nil,  -- Attack any visible target
        moveBehind   = nil,  -- Move to target's back when not positioned behind
        faceTarget   = nil,  -- Ensure target does not face ranged players
        castFocused  = nil,  -- Stop casting AoE or debuff spells
        avoidAoe     = nil,  -- Automatically avoid the majority of harmful AoE spells
        saveMana     = nil,  -- Healers prioritize high-efficiency spells
        healerDps    = nil,  -- Healers cast damage spells when mana is sufficient
        doPull       = nil,  -- Tank pulls mobs using a ranged skill
        pullBack     = nil,  -- Pull mob and return to starting position
        waitAttack   = nil,  -- Wait a set time before attacking or healing
        markTargets  = nil,  -- Automatically mark unmarked combat attackers (RTI)
    }
end

-- Split str on the first occurrence of sep; returns (before, after).
local function CB_SplitOnce(str, sep)
    local i = strfind(str, sep, 1, true)
    if i then return strsub(str, 1, i - 1), strsub(str, i + 1) end
    return str, ""
end

-- Parse a combat strategy string returned by the bot in response to "co ?".
-- Format: plain comma-separated active strategy names, e.g. "tank,dps aoe,heal,"
-- Receiving this string means the server gave us the complete picture, so every
-- strategy not present in the list is explicitly false.
local function CB_ParseCombatStr(combatStr)
    -- Start everything false (confirmed inactive) then flip found ones to true.
    local combat = {}
    for _, field in pairs(STRATEGY_MAP) do
        combat[field] = false
    end
    if not combatStr or combatStr == "" then return combat end

    for token in gmatch(combatStr, "[^,]+") do
        token = token:match("^%s*(.-)%s*$")
        local field = STRATEGY_MAP[token]
        if field then
            combat[field] = true
        end
    end
    return combat
end

local function CleanBot_IsBot(unit)
    local name = UnitName(unit)
    if not name then return false end
    if CleanBot_KnownBots[strlower(name)] then return true end
    if ASSUME_ALL_PARTY_ARE_BOTS then return true end
    return false
end

-- ============================================================
-- Class icon coords
-- ============================================================
local CLASS_ICON_COORDS = {
    WARRIOR     = {0,    0.25,  0,    0.25},
    MAGE        = {0.25, 0.5,   0,    0.25},
    ROGUE       = {0.5,  0.75,  0,    0.25},
    DRUID       = {0.75, 1.0,   0,    0.25},
    HUNTER      = {0,    0.25,  0.25, 0.5},
    SHAMAN      = {0.25, 0.5,   0.25, 0.5},
    PRIEST      = {0.5,  0.75,  0.25, 0.5},
    WARLOCK     = {0.75, 1.0,   0.25, 0.5},
    PALADIN     = {0,    0.25,  0.5,  0.75},
    DEATHKNIGHT = {0.25, 0.5,   0.5,  0.75},
}

-- ============================================================
-- ElvUI skinning helpers
-- ============================================================
local function CB_ApplyPanelSkin(frame)
    if ElvUI_S then
        frame:StripTextures()
        frame:SetTemplate("Default")
    else
        frame:SetBackdrop(PLAIN_BACKDROP)
        frame:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
        frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    end
end

local function CB_ApplyInnerSkin(frame)
    if ElvUI_S then
        frame:StripTextures()
        frame:SetTemplate("Transparent")
    else
        frame:SetBackdrop(PLAIN_BACKDROP)
        frame:SetBackdropColor(0, 0, 0, 0.4)
        frame:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.8)
    end
end

-- ============================================================
-- Layout constants
-- ============================================================
local FRAME_WIDTH  = 600
local FRAME_HEIGHT = 400
local TAB_HEIGHT   = 24
local TAB_WIDTH    = 88
local TITLE_H      = 28   -- space consumed by CleanBotFrame's title text
local FOOTER_H     = 36   -- space consumed by the Close button at the bottom
local TOP_BAR_H    = TAB_HEIGHT + 8   -- height of the Party/Settings tab bar frame
local BOT_BAR_H    = TAB_HEIGHT + 8   -- height of the character tab bar frame
local PAD          = 6    -- general inner padding

-- ============================================================
-- Persistent sub-frames (built once in CleanBot_BuildFrames)
-- ============================================================
-- Declared early so all functions below can close over them.
local topTabBar     = nil   -- holds Party / Settings buttons
local contentFrame  = nil   -- inner panel shown below topTabBar
local partyPanel    = nil   -- fills contentFrame when Party is active
local botTabBar     = nil   -- holds character tab buttons, child of partyPanel
local partyContent  = nil   -- model area, child of partyPanel
local settingsPanel = nil   -- fills contentFrame when Settings is active

-- ============================================================
-- Character tab state
-- Declared before CleanBot_SelectTopTab so closures capture them.
-- ============================================================
local activeBotTabs  = {}
local activeTabIndex = 0
local botModelFrames = {}

-- ============================================================
-- Top-level tab management (Party / Settings)
-- ============================================================
local activeTopTabIndex = 0
local topTabs           = {}

local function CleanBot_SelectTopTab(index)
    if activeTopTabIndex == index then return end
    activeTopTabIndex = index

    for i, tab in ipairs(topTabs) do
        if i == index then
            tab:SetNormalFontObject(GameFontHighlightSmall)
            tab:SetButtonState("PUSHED", true)
        else
            tab:SetNormalFontObject(GameFontNormalSmall)
            tab:SetButtonState("NORMAL")
        end
    end

    local showParty = (index == 1)

    if partyPanel then
        if showParty then partyPanel:Show() else partyPanel:Hide() end
    end
    if settingsPanel then
        if showParty then settingsPanel:Hide() else settingsPanel:Show() end
    end

    -- When returning to Party, restore only the active model.
    if showParty then
        for mi, model in ipairs(botModelFrames) do
            if mi == activeTabIndex then model:Show() else model:Hide() end
        end
    else
        for _, model in ipairs(botModelFrames) do model:Hide() end
    end
end

-- ============================================================
-- Frame construction (called once at PLAYER_LOGIN)
-- ============================================================
local function CleanBot_BuildSettingsContent()
    local cb = CreateFrame("CheckButton", "CleanBotAssumeBotsCheck",
                           settingsPanel, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", PAD, -PAD)
    cb:SetChecked(ASSUME_ALL_PARTY_ARE_BOTS)
    cb:SetScript("OnClick", function(self)
        ASSUME_ALL_PARTY_ARE_BOTS = self:GetChecked() and true or false
    end)

    local label = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText("Assume all party members are bots")

    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Assume All Party Are Bots", 1, 1, 1)
        GameTooltip:AddLine(
            "Treat every party member as a bot regardless of whether the " ..
            "MultiBot bridge has confirmed them. Enable this when the bridge " ..
            "module is not installed on the server.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)

    if ElvUI_S then ElvUI_S:HandleCheckBox(cb) end
end

function CleanBot_BuildFrames()
    -- ── Top tab bar ────────────────────────────────────────────
    -- Transparent organiser for the Party / Settings tab buttons.
    topTabBar = CreateFrame("Frame", "CleanBotTopTabBar", CleanBotFrame)
    topTabBar:SetPoint("TOPLEFT",  CleanBotFrame, "TOPLEFT",  0, -TITLE_H)
    topTabBar:SetPoint("TOPRIGHT", CleanBotFrame, "TOPRIGHT", 0, -TITLE_H)
    topTabBar:SetHeight(TOP_BAR_H)

    local tabLabels = { "Party", "Settings" }
    for i, label in ipairs(tabLabels) do
        local tab = CreateFrame("Button", "CleanBotTopTab" .. i,
                                topTabBar, "UIPanelButtonTemplate")
        tab:SetSize(TAB_WIDTH, TAB_HEIGHT)
        tab:SetPoint("LEFT", topTabBar, "LEFT", PAD + (i - 1) * (TAB_WIDTH + 2), 0)
        tab:SetText(label)
        tab:SetNormalFontObject(GameFontNormalSmall)
        local idx = i
        tab:SetScript("OnClick", function() CleanBot_SelectTopTab(idx) end)
        if ElvUI_S then ElvUI_S:HandleButton(tab) end
        topTabs[i] = tab
    end

    -- ── Content frame ──────────────────────────────────────────
    -- Inner panel that hosts either partyPanel or settingsPanel.
    contentFrame = CreateFrame("Frame", "CleanBotContentFrame", CleanBotFrame)
    contentFrame:SetPoint("TOPLEFT",     CleanBotFrame, "TOPLEFT",     4, -(TITLE_H + TOP_BAR_H))
    contentFrame:SetPoint("BOTTOMRIGHT", CleanBotFrame, "BOTTOMRIGHT", -4, FOOTER_H)
    CB_ApplyInnerSkin(contentFrame)

    -- ── Party panel ────────────────────────────────────────────
    -- Fills contentFrame; contains the character tab bar + model area.
    partyPanel = CreateFrame("Frame", "CleanBotPartyPanel", contentFrame)
    partyPanel:SetAllPoints(contentFrame)

    -- Character tab bar: top strip of partyPanel.
    botTabBar = CreateFrame("Frame", "CleanBotBotTabBar", partyPanel)
    botTabBar:SetPoint("TOPLEFT",  partyPanel, "TOPLEFT",  0, 0)
    botTabBar:SetPoint("TOPRIGHT", partyPanel, "TOPRIGHT", 0, 0)
    botTabBar:SetHeight(BOT_BAR_H)

    -- "No bots" status text lives inside the party panel content area.
    CleanBotFrameText:ClearAllPoints()
    CleanBotFrameText:SetPoint("TOP", partyPanel, "TOP", 0, -(BOT_BAR_H + 20))

    -- Model display area: fills partyPanel below the character tab bar.
    partyContent = CreateFrame("Frame", "CleanBotPartyContent", partyPanel)
    partyContent:SetPoint("TOPLEFT",     partyPanel, "TOPLEFT",     0, -BOT_BAR_H)
    partyContent:SetPoint("BOTTOMRIGHT", partyPanel, "BOTTOMRIGHT", 0, 0)

    -- ── Settings panel ─────────────────────────────────────────
    -- Fills contentFrame; hidden until Settings tab is selected.
    settingsPanel = CreateFrame("Frame", "CleanBotSettingsPanel", contentFrame)
    settingsPanel:SetAllPoints(contentFrame)
    settingsPanel:Hide()

    CleanBot_BuildSettingsContent()

    if ElvUI_S then
        -- Skin the outer frame and close button now that ElvUI_S is set.
        CleanBotFrame:StripTextures()
        ElvUI_S:HandleButton(CleanBotFrameCloseButton)
    end
    CB_ApplyPanelSkin(CleanBotFrame)

    CleanBot_SelectTopTab(1)
end

-- ============================================================
-- Character tab management
-- ============================================================
local tabCounter = 0   -- ever-increasing; avoids name collisions on refresh

local function CleanBot_ClearTabs()
    for _, tab in ipairs(activeBotTabs) do
        tab:Hide()
        tab:SetParent(nil)
    end
    activeBotTabs = {}
    for _, model in ipairs(botModelFrames) do
        model:Hide()
        model:SetParent(nil)
    end
    botModelFrames = {}
    activeTabIndex = 0
end

local function CleanBot_SelectTab(index)
    if activeTabIndex == index then return end
    activeTabIndex = index

    for i, tab in ipairs(activeBotTabs) do
        if i == index then
            tab:SetNormalFontObject(GameFontHighlightSmall)
            tab:SetButtonState("PUSHED", true)
        else
            tab:SetNormalFontObject(GameFontNormalSmall)
            tab:SetButtonState("NORMAL")
        end
    end
    for i, model in ipairs(botModelFrames) do
        if i == index then model:Show() else model:Hide() end
    end
end

function CleanBot_RefreshTabs()
    CleanBot_ClearTabs()

    local bots = {}
    local numMembers = GetNumPartyMembers and GetNumPartyMembers() or 0
    for i = 1, numMembers do
        local unit = "party" .. i
        if UnitExists(unit) and CleanBot_IsBot(unit) then
            local name = UnitName(unit)
            local _, class = UnitClass(unit)
            table.insert(bots, { unit = unit, name = name, class = class or "WARRIOR" })
        end
    end

    if #bots == 0 then
        CleanBotFrameText:SetText("No bots found in party.")
        return
    end
    CleanBotFrameText:SetText("")

    CleanBotFrame:SetHeight(FRAME_HEIGHT)
    CleanBotFrame:SetWidth(FRAME_WIDTH)

    -- Derive model dimensions from partyContent, which is already anchored correctly.
    local contentW = partyContent:GetWidth()
    local contentH = partyContent:GetHeight()
    -- Fall back to computed values on the first call before the frame has been laid out.
    if contentW == 0 then contentW = FRAME_WIDTH - 8 end
    if contentH == 0 then contentH = FRAME_HEIGHT - TITLE_H - TOP_BAR_H - BOT_BAR_H - FOOTER_H - PAD * 2 end

    for i, bot in ipairs(bots) do
        tabCounter = tabCounter + 1

        -- Character tab button, parented to botTabBar.
        local tab = CreateFrame("Button", "CleanBotCharTab" .. tabCounter,
                                botTabBar, "UIPanelButtonTemplate")
        tab:SetSize(TAB_WIDTH, TAB_HEIGHT)
        tab:SetPoint("LEFT", botTabBar, "LEFT", PAD + (i - 1) * (TAB_WIDTH + 2), 0)
        tab:SetText("  " .. bot.name)
        tab:SetNormalFontObject(GameFontNormalSmall)

        local icon = tab:CreateTexture(nil, "OVERLAY")
        icon:SetSize(14, 14)
        icon:SetPoint("LEFT", tab, "LEFT", 4, 0)
        icon:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
        local coords = CLASS_ICON_COORDS[bot.class] or CLASS_ICON_COORDS["WARRIOR"]
        icon:SetTexCoord(unpack(coords))

        local idx = i
        tab:SetScript("OnClick", function() CleanBot_SelectTab(idx) end)
        table.insert(activeBotTabs, tab)
        if ElvUI_S then ElvUI_S:HandleButton(tab) end

        -- Model frame, parented to partyContent.
        local model = CreateFrame("DressUpModel", "CleanBotModel" .. tabCounter, partyContent)
        model:SetSize(contentW / 3, contentH)
        model:SetPoint("TOPLEFT", partyContent, "TOPLEFT", 0, 0)
        model:SetUnit(bot.unit)
        model:Hide()
        table.insert(botModelFrames, model)
    end

    if activeTabIndex == 0 then
        CleanBot_SelectTab(1)
    end
end

-- ============================================================
-- Request roster from bridge then refresh
-- ============================================================
local rosterPending = false

function CleanBot_RequestRosterThenRefresh()
    if bridgeReady then
        SendAddonMessage("MBOT", "GET~ROSTER",  "PARTY")
        SendAddonMessage("MBOT", "GET~DETAILS", "PARTY")
    end
    if not rosterPending then
        rosterPending = true
        local ticker = CreateFrame("Frame")
        local elapsed = 0
        ticker:SetScript("OnUpdate", function(self, dt)
            elapsed = elapsed + dt
            if elapsed >= 0.5 then
                rosterPending = false
                ticker:SetScript("OnUpdate", nil)
                CleanBot_RefreshTabs()
            end
        end)
    end
end

-- ============================================================
-- Bridge handshake
-- The server ignores GET~ requests until it has seen HELLO~1
-- and responded HELLO_ACK.  PARTY addon messages only work once
-- the client has joined the party channel, which isn't guaranteed
-- at PLAYER_LOGIN — so we send on PLAYER_ENTERING_WORLD and
-- retry whenever party membership changes.
-- ============================================================
local function CB_BridgeRequest()
    -- Called once the handshake is confirmed.
    -- GET~DETAILS must be sent alongside GET~ROSTER to receive DETAIL~ messages
    -- (class, race, gender) which are needed before we can whisper "co ?" to each bot.
    SendAddonMessage("MBOT", "GET~ROSTER",  "PARTY")
    SendAddonMessage("MBOT", "GET~DETAILS", "PARTY")
end

local function CB_SendHello()
    -- Only send if we are actually in a party; otherwise the
    -- PARTY channel is closed and SendAddonMessage silently fails.
    if GetNumPartyMembers() > 0 then
        SendAddonMessage("MBOT", "HELLO~1", "PARTY")
    end
end

-- ============================================================
-- Initialise at login (ElvUI is ready by this point)
-- ============================================================
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        if IsAddOnLoaded("ElvUI") then
            ElvUI_E = unpack(ElvUI)
            if ElvUI_E then
                ElvUI_S = ElvUI_E:GetModule("Skins")
            end
        end
        CleanBot_BuildFrames()
        self:UnregisterEvent("PLAYER_LOGIN")

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Party channel is reliable from here onward.
        bridgeReady = false  -- reset in case of a reload/relog
        CB_SendHello()
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
end)

print("CleanBot loaded! Type /cleanbot to open.")

-- ============================================================
-- Bridge: listen for MBOT messages and party changes
-- ============================================================
local bridgeFrame = CreateFrame("Frame")
bridgeFrame:RegisterEvent("CHAT_MSG_ADDON")
bridgeFrame:RegisterEvent("CHAT_MSG_WHISPER")
bridgeFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
bridgeFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_WHISPER" then
        local msg, sender = ...
        -- "Strategies: tank,dps aoe,heal," — response to "co ?" whispered to a bot.
        -- "Strategies: " is 12 characters; everything after is the active strategy list.
        if strfind(msg, "Strategies: ", 1, true) then
            local key = strlower(sender)
            if CleanBot_KnownBots[key] then
                local combatStr = strsub(msg, 13)
                CleanBot_KnownBots[key].combat = CB_ParseCombatStr(combatStr)
            end
        end
        return

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg = ...
        if prefix ~= "MBOT" then return end

        if msg and strsub(msg, 1, 10) == "HELLO_ACK~" then
            lastHelloAck = msg
            if not bridgeReady then
                bridgeReady = true
                CB_BridgeRequest()
            end

        elseif msg and strsub(msg, 1, 7) == "ROSTER~" then
            local name = strmatch(msg, "^ROSTER~([^,]+),")
            if name then
                local key = strlower(name)
                if not CleanBot_KnownBots[key] then
                    CleanBot_KnownBots[key] = {
                        name   = name,
                        class  = "WARRIOR",
                        combat = CB_DefaultCombat(),
                    }
                    -- STATES will arrive proactively from the server
                    -- after the next RUN~COMBAT command; no pull needed.
                end
            end

        elseif msg and strsub(msg, 1, 7) == "DETAIL~" then
            local name, className = strmatch(msg, "^DETAIL~([^~]+)~[^~]+~[^~]+~([^~]+)~")
            if name and className then
                local classKey = strupper(className)
                classKey = gsub(classKey, "%s+", "")
                local key = strlower(name)
                local existingCombat = CleanBot_KnownBots[key] and
                                       CleanBot_KnownBots[key].combat
                CleanBot_KnownBots[key] = {
                    name   = name,
                    class  = classKey,
                    combat = existingCombat or CB_DefaultCombat(),
                }
                -- Query the bot's current combat strategies via whisper.
                -- The bot responds with "Strategies: tank,dps,..." which we
                -- catch in the CHAT_MSG_WHISPER handler below.
                SendChatMessage("co ?", "WHISPER", nil, name)
            end
            if CleanBotFrame:IsShown() then
                CleanBot_RefreshTabs()
            end

        elseif msg and strsub(msg, 1, 7) == "STATES~" then
            -- Payload: semicolon-separated entries, each "<name>~<combatStr>~<normalStr>".
            local payload = strsub(msg, 8)
            lastRawStates = payload  -- store for debug inspection
            for entry in gmatch(payload .. ";", "([^;]*);") do
                if entry ~= "" then
                    local name, rest    = CB_SplitOnce(entry, "~")
                    local combatStr, _  = CB_SplitOnce(rest,  "~")
                    name = name:match("^%s*(.-)%s*$")
                    if name and name ~= "" then
                        local key = strlower(name)
                        if CleanBot_KnownBots[key] then
                            CleanBot_KnownBots[key].combat =
                                CB_ParseCombatStr(combatStr,
                                    CleanBot_KnownBots[key].combat)
                        end
                    end
                end
            end
        end

    elseif event == "PARTY_MEMBERS_CHANGED" then
        if not bridgeReady then
            CB_SendHello()
        else
            SendAddonMessage("MBOT", "GET~ROSTER",  "PARTY")
            SendAddonMessage("MBOT", "GET~DETAILS", "PARTY")
        end
        if CleanBotFrame:IsShown() then
            CleanBot_RequestRosterThenRefresh()
        end
    end
end)
