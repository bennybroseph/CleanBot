-- ============================================================
-- CleanBot.lua
-- ============================================================

SLASH_CLEANBOT1 = "/cleanbot"
SlashCmdList["CLEANBOT"] = function(msg)
    if CleanBotFrame:IsShown() then
        CleanBotFrame:Hide()
    else
        CleanBotFrame:Show()
        CleanBot_RequestRosterThenRefresh()
    end
end

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
            i,
            tostring(name),
            tostring(exists),
            tostring(isPlayer),
            tostring(class),
            tostring(inCache)
        ))
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
-- If MultiBot bridge is not installed, treat all party members
-- as bots. Set to false if you have real players in your party.
-- ============================================================
local ASSUME_ALL_PARTY_ARE_BOTS = false

-- ============================================================
-- Bot detection cache
-- ============================================================
CleanBot_KnownBots = {}  -- keyed by lowercase name, value = { class, name }

local function CleanBot_IsBot(unit)
    local name = UnitName(unit)
    if not name then return false end
    -- Bridge cache hit
    if CleanBot_KnownBots[strlower(name)] then return true end
    -- Fallback: if bridge isn't available, optionally treat all party members as bots
    if ASSUME_ALL_PARTY_ARE_BOTS then return true end
    return false
end

-- ============================================================
-- Class icon coords (WoW standard class icon atlas)
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
-- Tab management
-- ============================================================
local activeBotTabs  = {}
local activeTabIndex = 0
local botModelFrames = {}

local FRAME_WIDTH  = 600
local FRAME_HEIGHT = 400
local TAB_HEIGHT   = 24
local TAB_WIDTH    = 88
local CONTENT_Y    = -TAB_HEIGHT - 8

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
        if i == index then
            model:Show()
        else
            model:Hide()
        end
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

    local contentHeight = FRAME_HEIGHT - TAB_HEIGHT + 10

    for i, bot in ipairs(bots) do
        local tab = CreateFrame("Button", "CleanBotTab" .. i, CleanBotFrame, "UIPanelButtonTemplate")
        tab:SetSize(TAB_WIDTH, TAB_HEIGHT)
        tab:SetPoint("TOPLEFT", CleanBotFrame, "TOPLEFT", 8 + (i - 1) * (TAB_WIDTH + 2), -8)
        tab:SetText("  " .. bot.name)
        tab:SetNormalFontObject(GameFontNormalSmall)

        local icon = tab:CreateTexture(nil, "OVERLAY")
        icon:SetSize(14, 14)
        icon:SetPoint("LEFT", tab, "LEFT", 4, 0)
        icon:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
        local coords = CLASS_ICON_COORDS[bot.class] or CLASS_ICON_COORDS["WARRIOR"]
        icon:SetTexCoord(unpack(coords))

        tab:SetScript("OnClick", function() CleanBot_SelectTab(i) end)
        table.insert(activeBotTabs, tab)

        -- Skin the tab if ElvUI is available
        if ElvUI_S then
            ElvUI_S:HandleButton(tab)
        end

        local model = CreateFrame("DressUpModel", "CleanBotModel" .. i, CleanBotFrame)
        model:SetSize(FRAME_WIDTH / 3, contentHeight)
        model:SetPoint("BOTTOMLEFT", CleanBotFrame, "BOTTOMLEFT", 8, CONTENT_Y)
        model:SetUnit(bot.unit)
        model:Hide()
        table.insert(botModelFrames, model)
    end

    CleanBot_SelectTab(1)
end

-- ============================================================
-- Request roster from bridge then refresh, with a small delay
-- to give the server time to respond before we build tabs.
-- ============================================================
local rosterPending = false

function CleanBot_RequestRosterThenRefresh()
    if IsAddOnLoaded("MultiBot") then
        SendAddonMessage("MBOT", "GET~ROSTER", "PARTY")
        -- Give the server ~0.5s to respond before refreshing
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
    else
        -- No bridge — refresh immediately using fallback detection
        CleanBot_RefreshTabs()
    end
end

-- ============================================================
-- Bridge: listen for MBOT ROSTER and party changes
-- ============================================================
local bridgeFrame = CreateFrame("Frame")
bridgeFrame:RegisterEvent("CHAT_MSG_ADDON")
bridgeFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
bridgeFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, msg = ...
        if prefix ~= "MBOT" then return end

        -- ROSTER~Name,level,...  — one message per bot, confirms it's a bot
        if msg and strsub(msg, 1, 7) == "ROSTER~" then
            local name = strmatch(msg, "^ROSTER~([^,]+),")
            if name then
                -- Class not in ROSTER payload; seed the cache entry without class for now.
                -- DETAIL~ arrives right after and will fill in the class.
                local key = strlower(name)
                if not CleanBot_KnownBots[key] then
                    CleanBot_KnownBots[key] = { name = name, class = "WARRIOR" }
                end
            end

        -- DETAIL~Name~Race~Gender~ClassName~level~...  — fills in the class
        elseif msg and strsub(msg, 1, 7) == "DETAIL~" then
            local name, className = strmatch(msg, "^DETAIL~([^~]+)~[^~]+~[^~]+~([^~]+)~")
            if name and className then
                -- Normalise "Paladin" -> "PALADIN" to match CLASS_ICON_COORDS keys
                local classKey = strupper(className)
                -- Strip spaces for Death Knight -> DEATHKNIGHT
                classKey = gsub(classKey, "%s+", "")
                local key = strlower(name)
                CleanBot_KnownBots[key] = { name = name, class = classKey }
            end
            -- If the frame is open, re-render now that we have accurate class data
            if CleanBotFrame:IsShown() then
                CleanBot_RefreshTabs()
            end

        end

    elseif event == "PARTY_MEMBERS_CHANGED" then
        if IsAddOnLoaded("MultiBot") then
            SendAddonMessage("MBOT", "GET~ROSTER", "PARTY")
        end
        if CleanBotFrame:IsShown() then
            CleanBot_RequestRosterThenRefresh()
        end
    end
end)

-- ============================================================
-- ElvUI Skinning
-- ============================================================
ElvUI_E = nil
ElvUI_S = nil  -- stored at login, reused when tabs are built

local function ApplyElvUISkin()
    if not IsAddOnLoaded("ElvUI") then return end
    local E = unpack(ElvUI)
    if not E then return end
    local S = E:GetModule("Skins")
    if not S then return end

    ElvUI_E = E
    ElvUI_S = S

    CleanBotFrame:StripTextures()
    CleanBotFrame:SetTemplate("Default")
    S:HandleButton(CleanBotFrameCloseButton)
end

local skinFrame = CreateFrame("Frame")
skinFrame:RegisterEvent("PLAYER_LOGIN")
skinFrame:SetScript("OnEvent", function(self, event)
    ApplyElvUISkin()
    if IsAddOnLoaded("MultiBot") then
        SendAddonMessage("MBOT", "GET~ROSTER", "PARTY")
    end
    self:UnregisterEvent("PLAYER_LOGIN")
end)

print("CleanBot loaded! Type /cleanbot to open.")