-- ============================================================
-- CleanBotTarget.lua  —  Target tab: dynamic party tab for the
--                         currently targeted bot.
-- Depends on NS.CB_BuildBotContent and NS.CB_SelectTab
-- being exposed by CleanBotParty.lua (loaded before this file).
-- ============================================================
local NS = CleanBotNS

NS.targetTabBtn         = nil
NS.targetTabModel       = nil
NS.targetTabCtrl        = nil
NS.targetTabCurrentKey  = nil
NS.targetTabChildFrames = {}

-- ── Internal helpers ──────────────────────────────────────────

local function CleanBot_ClearTargetContent()
    for _, f in ipairs(NS.targetTabChildFrames) do
        f:Hide(); f:SetParent(nil)
    end
    NS.targetTabChildFrames = {}
    NS.targetTabCurrentKey  = nil
    -- Clear model scripts so they don't fire for the old target
    if NS.targetTabModel then
        NS.targetTabModel:SetScript("OnMouseDown", nil)
        NS.targetTabModel:SetScript("OnMouseUp",   nil)
        NS.targetTabModel:EnableMouse(false)
    end
end

local function CleanBot_SelectTargetTab()
    for _, tab in ipairs(NS.activeBotTabs) do
        tab:SetNormalFontObject(GameFontNormalSmall)
        tab:SetButtonState("NORMAL")
    end
    for _, model in ipairs(NS.botModelFrames)   do model:Hide() end
    for _, ctrl  in ipairs(NS.botControlFrames) do ctrl:Hide()  end
    NS.activeTabIndex = -1

    if NS.targetTabBtn   then
        NS.targetTabBtn:SetNormalFontObject(GameFontHighlightSmall)
        NS.targetTabBtn:SetButtonState("PUSHED", true)
    end
    if NS.targetTabModel then NS.targetTabModel:Show() end
    if NS.targetTabCtrl  then NS.targetTabCtrl:Show()  end

    -- Whisper the bot to wave (only if it's a different bot than last time)
    if NS.targetTabCurrentKey then
        local entry = CleanBot_KnownBots[NS.targetTabCurrentKey]
        if entry and entry.name ~= NS.lastWavedAt then
            NS.lastWavedAt = entry.name
            SendChatMessage("emote wave", "WHISPER", nil, entry.name)
        end
    end
end

local function CleanBot_BuildTargetContent(key, botName, botClass)
    NS.tabCounter = NS.tabCounter + 1
    local entry   = CleanBot_KnownBots[key]
    NS.targetTabChildFrames = NS.CB_BuildBotContent(
        NS.targetTabCtrl, NS.targetTabModel, key, botName, botClass, entry, NS.tabCounter)
end

-- ── Public API ────────────────────────────────────────────────

-- Called on PLAYER_TARGET_CHANGED and after RefreshTabs.
NS.CleanBot_UpdateTargetTab = function()
    if not NS.targetTabBtn then return end

    local targetName = UnitExists("target") and UnitIsPlayer("target") and UnitName("target")
    local key        = targetName and strlower(targetName)
    local entry      = key and CleanBot_KnownBots[key]

    if not entry then
        -- Target is not a known bot — hide the tab
        NS.targetTabBtn:Hide()
        if NS.activeTabIndex == -1 then
            NS.activeTabIndex = 0
            if #NS.activeBotTabs > 0 then
                NS.CB_SelectTab(1)
            else
                if NS.targetTabModel then NS.targetTabModel:Hide() end
                if NS.targetTabCtrl  then NS.targetTabCtrl:Hide()  end
            end
        end
        CleanBot_ClearTargetContent()
        return
    end

    -- Known bot is targeted — ensure tab is visible
    NS.targetTabBtn:Show()
    NS.targetTabModel:SetUnit("target")

    -- Rebuild content only when the target changes to a different bot
    if NS.targetTabCurrentKey ~= key then
        CleanBot_ClearTargetContent()
        NS.targetTabCurrentKey = key

        -- If no combat data yet, kick off a query
        if not entry.queried then
            entry.queried    = true
            entry.awaitingCo = true
            entry.awaitingNc = false
            SendChatMessage("co ?", "WHISPER", nil, targetName)
        end

        CleanBot_BuildTargetContent(key, targetName, entry.class or "WARRIOR")
    end

    -- Re-assert visual state if target tab was already selected
    -- (e.g. after RefreshTabs cleared and rebuilt bot tabs)
    if NS.activeTabIndex == -1 then
        for _, m in ipairs(NS.botModelFrames)   do m:Hide() end
        for _, c in ipairs(NS.botControlFrames) do c:Hide() end
        NS.targetTabModel:Show()
        NS.targetTabCtrl:Show()
        NS.targetTabBtn:SetNormalFontObject(GameFontHighlightSmall)
        NS.targetTabBtn:SetButtonState("PUSHED", true)
    end
end

-- Called once from CleanBot_BuildFrames after partyPanel/botTabBar are ready.
NS.CleanBot_InitTargetTab = function()
    local contentW = NS.FRAME_WIDTH - 8
    local contentH = NS.FRAME_HEIGHT - NS.TITLE_H - NS.TOP_BAR_H - NS.BOT_BAR_H - NS.FOOTER_H - NS.PAD * 2

    NS.targetTabBtn = CreateFrame("Button", "CleanBotTargetTabBtn", NS.botTabBar, "UIPanelButtonTemplate")
    NS.targetTabBtn:SetSize(NS.TAB_WIDTH, NS.TAB_HEIGHT)
    NS.targetTabBtn:SetText("Target")
    NS.targetTabBtn:SetNormalFontObject(GameFontNormalSmall)
    NS.targetTabBtn:SetScript("OnClick", CleanBot_SelectTargetTab)
    NS.targetTabBtn:Hide()
    if NS.ElvUI_S then NS.ElvUI_S:HandleButton(NS.targetTabBtn) end

    NS.targetTabModel = CreateFrame("DressUpModel", "CleanBotTargetTabModel", NS.partyContent)
    NS.targetTabModel:SetSize(contentW / 3, contentH)
    NS.targetTabModel:SetPoint("TOPLEFT", NS.partyContent, "TOPLEFT", 0, 0)
    NS.targetTabModel:Hide()

    NS.targetTabCtrl = CreateFrame("Frame", "CleanBotTargetTabCtrl", NS.partyContent)
    NS.targetTabCtrl:SetPoint("TOPLEFT",     NS.partyContent, "TOPLEFT",     contentW / 3 + NS.PAD, -NS.PAD)
    NS.targetTabCtrl:SetPoint("BOTTOMRIGHT", NS.partyContent, "BOTTOMRIGHT", -NS.PAD, NS.PAD)
    NS.targetTabCtrl:Hide()
end
