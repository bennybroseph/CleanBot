-- ============================================================
-- CleanBotQuest.lua  —  Per-bot quest log.
-- ============================================================

local NS = CleanBotNS

-- ── Blizz frame geometry ─────────────────────────────────────────────────
-- Mirrors QuestLogFrame exactly (682x447). Two DualPane textures tile the
-- full width: Left(512)+Right(170)=682px. Both content panes are 305px wide
-- with a 34px visual divider between them.
local BLIZZ_W      = 682
local BLIZZ_H      = 447
-- Shared Y insets for both scroll panes.
local BLIZZ_PANE_TOP    = 74   -- inset from frame top (chrome header band)
local BLIZZ_PANE_BOTTOM = 37   -- inset from frame bottom

-- Left pane X: offset from frame left / frame right.
local BLIZZ_LEFT_PANE_L  = 19
local BLIZZ_LEFT_PANE_R  = 342

-- Right pane X: offset from frame left / frame right.
local BLIZZ_RIGHT_PANE_L = 358
local BLIZZ_RIGHT_PANE_R = 12

-- ── Blizz button layout ──────────────────────────────────────────────────
-- Each bottom button has its own width and X; all share the same Y and height.
-- The X close button has its own offset from TOPRIGHT.
local BLIZZ_BTN_H        = 22   -- shared height for all bottom buttons
local BLIZZ_BTN_Y        = 14   -- shared distance from frame bottom edge

local BLIZZ_ABANDON_W    = 110  -- Abandon
local BLIZZ_ABANDON_X    = 18
local BLIZZ_SHARE_W      = 99   -- Share
local BLIZZ_SHARE_X      = 128
local BLIZZ_TRACK_W      = 97   -- Track
local BLIZZ_TRACK_X      = 225
local BLIZZ_CLOSE_BTN_W  = 80   -- Close (bottom-right)
local BLIZZ_CLOSE_BTN_X  = 7    -- inset from frame right edge

local BLIZZ_X_BTN_X = 2         -- X close button offset from TOPRIGHT
local BLIZZ_X_BTN_Y = -8

local BLIZZ_TITLE_X = 0         -- title label offset from frame TOP (CENTER anchor)
local BLIZZ_TITLE_Y = -23

-- ── Quest list rendering constants ──────────────────────────────────────
local QUEST_HEADER_H = 20   -- collapsible group header height (px)
local QUEST_ROW_H    = 16   -- quest entry row height (px)
local QUEST_INDENT   = 14   -- left indent for quest rows inside a group
local QUEST_GAP      = 1    -- vertical gap between rows (px)

-- Per-status display metadata: group label and header text color.
local QUEST_STATUS_INFO = {
    I = { label = "Incomplete", r = 1.0,  g = 0.82, b = 0.0 },  -- gold
    C = { label = "Complete",   r = 0.0,  g = 1.0,  b = 0.0 },  -- green
    F = { label = "Failed",     r = 1.0,  g = 0.2,  b = 0.2 },  -- red
}
-- Render order: most actionable (Incomplete) first.
local QUEST_STATUS_ORDER = { "I", "C", "F" }

-- Collapse state survives re-renders within the same session.
-- Key format: botKey .. "~" .. statusKey  (e.g. "kira~I")
local questGroupCollapsed = {}

-- ── Quest frames pool ────────────────────────────────────────────────────
NS.botQuestFrames = {}

-- ── Quest name cache (questID → title) ──────────────────────────────────
-- Built from the player's own quest log. Covers any quests the player shares
-- with their bots. Stored on NS so the detail pane can read it later.
-- GetQuestLogTitle returns: title, level, tag, group, isHeader, isCollapsed,
--                           isComplete, isDaily, questID  (positions 1 and 9)
NS.questNameCache = {}

local function CB_BuildQuestNameCache()
    local n = GetNumQuestLogEntries()
    for i = 1, n do
        local title, _, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
        if not isHeader and questID and questID > 0 and title then
            NS.questNameCache[questID] = title
        end
    end
end

-- ── Render one collapsible status group into the scroll child ────────────
-- Creates a header button (expand/collapse) and a row per quest when expanded.
-- Appends all created frames to framePool so CB_RenderQuests can hide them
-- on the next render pass. Returns the new yOffset after all rows.
local function CB_RenderQuestGroup(sc, framePool, key, statusKey, info, quests, yOffset)
    local collapseKey = key .. "~" .. statusKey
    local isCollapsed = questGroupCollapsed[collapseKey]

    -- ── Header button ─────────────────────────────────────────────────────
    local headerBtn = CreateFrame("Button", nil, sc)
    headerBtn:SetHeight(QUEST_HEADER_H)
    headerBtn:SetPoint("TOPLEFT",  sc, "TOPLEFT",  0, yOffset)
    headerBtn:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, yOffset)
    headerBtn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    local arrow = headerBtn:CreateTexture(nil, "OVERLAY")
    arrow:SetSize(16, 16)
    arrow:SetPoint("LEFT", headerBtn, "LEFT", 2, 0)
    arrow:SetTexture(isCollapsed
        and "Interface\\Buttons\\UI-PlusButton-Up"
        or  "Interface\\Buttons\\UI-MinusButton-Up")

    local headerLabel = headerBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    headerLabel:SetPoint("LEFT",  headerBtn, "LEFT",  20, 0)
    headerLabel:SetPoint("RIGHT", headerBtn, "RIGHT",  0, 0)
    headerLabel:SetJustifyH("LEFT")
    headerLabel:SetTextColor(info.r, info.g, info.b)
    headerLabel:SetText(info.label .. " (" .. #quests .. ")")

    -- Toggle collapse state and re-render the full list.
    headerBtn:SetScript("OnClick", function()
        questGroupCollapsed[collapseKey] = not questGroupCollapsed[collapseKey]
        NS.CB_RenderQuests(key)
    end)

    framePool[#framePool + 1] = headerBtn
    yOffset = yOffset - QUEST_HEADER_H - QUEST_GAP

    -- ── Quest rows (omitted when collapsed) ──────────────────────────────
    if not isCollapsed then
        for _, quest in ipairs(quests) do
            -- Prefer a name from the player's quest log cache; fall back to the
            -- numeric ID (which is all the server sends). The tooltip will show
            -- the full quest info from the client's data cache on hover.
            local displayName = (quest.id and NS.questNameCache[quest.id])
                             or tostring(quest.id or "?")

            local rowBtn = CreateFrame("Button", nil, sc)
            rowBtn:SetHeight(QUEST_ROW_H)
            rowBtn:SetPoint("TOPLEFT",  sc, "TOPLEFT",  QUEST_INDENT, yOffset)
            rowBtn:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, yOffset)
            rowBtn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

            local nameText = rowBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            nameText:SetPoint("LEFT",  rowBtn, "LEFT",  0, 0)
            nameText:SetPoint("RIGHT", rowBtn, "RIGHT", 0, 0)
            nameText:SetJustifyH("LEFT")
            nameText:SetTextColor(info.r, info.g, info.b)
            nameText:SetText(displayName)

            -- On hover, ask the WoW client to show the full quest tooltip.
            -- SetHyperlink pulls from the client's local quest data cache, so
            -- it works for any quest the player has encountered — which covers
            -- most quests a bot would be running alongside them.
            local questID = quest.id
            rowBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink("quest:" .. (questID or 0) .. ":60")
                GameTooltip:Show()
            end)
            rowBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            framePool[#framePool + 1] = rowBtn
            yOffset = yOffset - QUEST_ROW_H - QUEST_GAP
        end
    end

    return yOffset
end

-- ── Render the quest list for a bot (called by CleanBotBridge on QUESTS_END) ─
-- Clears the previous render pass, groups entry.quests by status, and stamps
-- one collapsible group per non-empty status into the left scroll pane.
-- entry.quests = { { id, name, status } ... }  (status "I"/"C"/"F")
NS.CB_RenderQuests = function(key)
    local f = NS.botQuestFrames and NS.botQuestFrames[key]
    if not f then return end
    local entry = CleanBot_PartyBots[key]
    local sc    = f.scrollChild

    -- Refresh the player's quest log name cache before building the list.
    -- This is cheap (single pass over ≤25 entries) and ensures names are
    -- current without needing a separate event subscription.
    CB_BuildQuestNameCache()

    -- Hide all frames created by the previous render pass.
    if f.questGroupFrames then
        for _, fr in ipairs(f.questGroupFrames) do fr:Hide() end
    end
    f.questGroupFrames = {}

    -- Group quests by status key.
    local groups = { I = {}, C = {}, F = {} }
    local quests = (entry and entry.quests) or {}
    for _, q in ipairs(quests) do
        local s = q.status or "I"
        local g = groups[s]
        if g then g[#g + 1] = q end
    end

    local yOffset = 0
    local hasAny  = false

    for _, statusKey in ipairs(QUEST_STATUS_ORDER) do
        local list = groups[statusKey]
        if list and #list > 0 then
            hasAny  = true
            yOffset = CB_RenderQuestGroup(sc, f.questGroupFrames, key, statusKey,
                QUEST_STATUS_INFO[statusKey], list, yOffset)
        end
    end

    -- Empty state: shown when the bot has no quests at all.
    if not hasAny then
        local emptyLabel = sc:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        emptyLabel:SetPoint("TOP", sc, "TOP", 0, -8)
        emptyLabel:SetText("No quests.")
        f.questGroupFrames[#f.questGroupFrames + 1] = emptyLabel
    end

    -- Expand scroll child to fit content (minimum = visible frame height).
    local contentH = math.abs(yOffset) + 8
    local frameH   = f.scrollFrame:GetHeight() or 1
    sc:SetHeight(math.max(contentH, frameH))
end

-- ── Apply QuestLogFrame dual-pane background (Blizz path) ────────────────
-- Replicates QuestLogFrame's texture layout exactly: two DualPane textures
-- in the BORDER layer tile perfectly across the 682px frame width.
local function CB_ApplyQuestFrameSkin(f)
    local left = f:CreateTexture(nil, "BORDER")
    left:SetTexture("Interface\\QuestFrame\\UI-QuestLogDualPane-Left")
    left:SetSize(512, 445)
    left:SetPoint("TOPLEFT", f, "TOPLEFT")
    left:SetTexCoord(0, 1.0, 0, 0.86914)

    local right = f:CreateTexture(nil, "BORDER")
    right:SetTexture("Interface\\QuestFrame\\UI-QuestLogDualPane-RIGHT")
    right:SetSize(170, 445)
    right:SetPoint("TOPRIGHT", f, "TOPRIGHT")
    right:SetTexCoord(0, 0.6640625, 0, 0.86914)

    local bookIcon = f:CreateTexture(nil, "BACKGROUND")
    bookIcon:SetTexture("Interface\\QuestFrame\\UI-QuestLog-BookIcon")
    bookIcon:SetSize(64, 64)
    bookIcon:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -4)
end

-- ── Build a zero-padding scroll container at explicit pixel bounds ────────
-- Used on the Blizz path where the two panes are manually positioned over
-- the parchment areas rather than derived from a panel's padding fields.
local function CB_MakeScrollContainer(parent, name, left, top, right, bottom)
    local c = CreateFrame("Frame", name, parent)
    c:SetPoint("TOPLEFT",     parent, "TOPLEFT",      left,  -top)
    c:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -right,  bottom)
    c.paddingTop = 0; c.paddingBottom = 0
    c.paddingLeft = 0; c.paddingRight = 0
    return c
end

-- ── Get or create quest frame for a bot ──────────────────────────────────
NS.CB_GetQuestFrame = function(key, botName)
    if NS.botQuestFrames[key] then return NS.botQuestFrames[key] end

    local f = CreateFrame("Frame", "CleanBotQuests_" .. key, UIParent)
    NS.CB_RegisterRootFrame(f)
    f:SetSize(BLIZZ_W, BLIZZ_H)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)

    local closeBtn = CreateFrame("Button", "CleanBotQuestsClose_" .. key, f, "UIPanelCloseButton")
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local listScrollParent, detailScrollParent

    if NS.ElvUI_S then
        f:StripTextures()
        NS.CB_ApplyFrameSkin(f, 0)
        NS.CB_ApplyTitleBar(f, botName .. "'s Quest Log")

        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
        NS.ElvUI_S:HandleCloseButton(closeBtn)

        local pad    = NS.PADDING.frame
        local btnMar = NS.MARGIN.button
        -- Panels stop above the button row: margin.top + BTN_H + margin.bottom.
        local btnRowH = btnMar.top + BLIZZ_BTN_H + btnMar.bottom
        local panelBottom = pad.bottom + btnRowH

        -- Two side-by-side panels mirroring ElvUI's QuestLogFrame layout.
        -- Left: TOPLEFT(19,-title) width 304. Right: TOPRIGHT(-30,-title) width 304.
        local leftPanel = NS.CB_CreatePanel(f, "CleanBotQuestsLeft_" .. key, 2, "panel")
        leftPanel:SetPoint("TOPLEFT",    f, "TOPLEFT",    19,  -NS.TITLE_H)
        leftPanel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 19,   panelBottom)
        leftPanel:SetWidth(304)

        local rightPanel = NS.CB_CreatePanel(f, "CleanBotQuestsRight_" .. key, 2, "panel")
        rightPanel:SetPoint("TOPRIGHT",    f, "TOPRIGHT",    -30, -NS.TITLE_H)
        rightPanel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30,  panelBottom)
        rightPanel:SetWidth(304)

        f.leftPanel  = leftPanel
        f.rightPanel = rightPanel
        listScrollParent   = leftPanel
        detailScrollParent = rightPanel
    else
        CB_ApplyQuestFrameSkin(f)

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetText(botName .. "'s Quest Log")
        title:SetPoint("CENTER", f, "TOP", BLIZZ_TITLE_X, BLIZZ_TITLE_Y)
        title:SetJustifyH("CENTER")

        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", BLIZZ_X_BTN_X, BLIZZ_X_BTN_Y)

        -- Two scroll containers manually placed over the left and right parchment panes.
        -- Tweak BLIZZ_LEFT/RIGHT_PANE_L/R at the top of this file to adjust X.
        -- Tweak BLIZZ_PANE_TOP/BOTTOM to adjust Y (shared by both panes).
        listScrollParent = CB_MakeScrollContainer(f,
            "CleanBotQuestsLeftPane_" .. key,
            BLIZZ_LEFT_PANE_L,  BLIZZ_PANE_TOP,
            BLIZZ_LEFT_PANE_R,  BLIZZ_PANE_BOTTOM)

        detailScrollParent = CB_MakeScrollContainer(f,
            "CleanBotQuestsRightPane_" .. key,
            BLIZZ_RIGHT_PANE_L, BLIZZ_PANE_TOP,
            BLIZZ_RIGHT_PANE_R, BLIZZ_PANE_BOTTOM)
    end

    local sf,  sc  = NS.CB_CreateScrollFrame(listScrollParent,   "CleanBotQuestScroll_"       .. key)
    local dsf, dsc = NS.CB_CreateScrollFrame(detailScrollParent, "CleanBotQuestDetailScroll_" .. key)

    f.scrollFrame       = sf
    f.scrollChild       = sc
    f.detailScrollFrame = dsf
    f.detailScrollChild = dsc

    -- ── Action buttons ────────────────────────────────────────────────────
    -- Blizz: UIPanelButtonTemplate, manually placed. Tweak BLIZZ_BTN_* at the
    --        top of this file to adjust positions.
    -- ElvUI: CB_CreateButton skinned; Abandon anchored BOTTOMLEFT then
    --        CB_AnchorAhead for the chain; Close independent at BOTTOMRIGHT.
    if NS.ElvUI_S then
        local pad = NS.PADDING.frame

        local abandonBtn = NS.CB_CreateButton(f, "CleanBotQuestAbandon_" .. key, "Abandon", 90, BLIZZ_BTN_H)
        abandonBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT",
            pad.left  + (abandonBtn.marginLeft   or 0),
            pad.bottom + (abandonBtn.marginBottom or 0))

        local shareBtn = NS.CB_CreateButton(f, "CleanBotQuestShare_" .. key, "Share", 90, BLIZZ_BTN_H)
        NS.CB_AnchorAhead(shareBtn, abandonBtn)

        local trackBtn = NS.CB_CreateButton(f, "CleanBotQuestTrack_" .. key, "Track", 90, BLIZZ_BTN_H)
        NS.CB_AnchorAhead(trackBtn, shareBtn)

        local closeActionBtn = NS.CB_CreateButton(f, "CleanBotQuestCloseAction_" .. key, "Close", 90, BLIZZ_BTN_H)
        closeActionBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",
            -((pad.right or 0) + (closeActionBtn.marginRight or 0)),
            pad.bottom + (closeActionBtn.marginBottom or 0))

        f.abandonBtn     = abandonBtn
        f.shareBtn       = shareBtn
        f.trackBtn       = trackBtn
        f.closeActionBtn = closeActionBtn
    else
        local function makeBtn(name, label, w)
            local btn = CreateFrame("Button", name, f, "UIPanelButtonTemplate")
            btn:SetSize(w, BLIZZ_BTN_H)
            btn:SetText(label)
            return btn
        end

        -- Blizz button anchors — adjust BLIZZ_BTN_* constants at top of file.
        local abandonBtn     = makeBtn("CleanBotQuestAbandon_"      .. key, "Abandon", BLIZZ_ABANDON_W)
        local shareBtn       = makeBtn("CleanBotQuestShare_"        .. key, "Share",   BLIZZ_SHARE_W)
        local trackBtn       = makeBtn("CleanBotQuestTrack_"        .. key, "Track",   BLIZZ_TRACK_W)
        local closeActionBtn = makeBtn("CleanBotQuestCloseAction_"  .. key, "Close",   BLIZZ_CLOSE_BTN_W)

        abandonBtn:SetPoint(    "BOTTOMLEFT",  f, "BOTTOMLEFT",  BLIZZ_ABANDON_X,    BLIZZ_BTN_Y)
        shareBtn:SetPoint(      "BOTTOMLEFT",  f, "BOTTOMLEFT",  BLIZZ_SHARE_X,      BLIZZ_BTN_Y)
        trackBtn:SetPoint(      "BOTTOMLEFT",  f, "BOTTOMLEFT",  BLIZZ_TRACK_X,      BLIZZ_BTN_Y)
        closeActionBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -BLIZZ_CLOSE_BTN_X, BLIZZ_BTN_Y)

        f.abandonBtn     = abandonBtn
        f.shareBtn       = shareBtn
        f.trackBtn       = trackBtn
        f.closeActionBtn = closeActionBtn
    end

    f.questList = {}
    f:Hide()
    NS.botQuestFrames[key] = f
    return f
end

-- ── Show / fetch quests ──────────────────────────────────────────────────
NS.CB_ShowQuests = function(key, botName)
    local f = NS.CB_GetQuestFrame(key, botName)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", CleanBotFrame, "TOPRIGHT", 4, 0)
    NS.CB_FetchQuests(key, botName)
    f:Show()
end

-- ── Toggle quests open/closed ────────────────────────────────────────────
NS.CB_ToggleQuests = function(key, botName)
    local f = NS.CB_GetQuestFrame(key, botName)
    if f:IsShown() then
        f:Hide()
    else
        NS.CB_ShowQuests(key, botName)
    end
end

-- ── Quest button for the model viewer ───────────────────────────────────
NS.CB_CreateQuestButton = function(slot, model, slotSize, gapX)
    local btnName = "CleanBotQuestBtn_" .. slot.index
    local btn = CreateFrame("Button", btnName, model)
    btn:SetSize(slotSize, slotSize)
    btn:SetPoint("RIGHT", slot.equipSlots[10], "LEFT", -gapX, 0)
    btn:RegisterForClicks("LeftButtonUp")

    if NS.ElvUI_S then
        NS.ElvUI_S:HandleButton(btn)
        btn:StyleButton()
    else
        btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    end

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\QUESTFRAME\\UI-QuestLog-BookIcon")
    icon:SetAllPoints()
    icon:Show()

    btn:SetScript("OnClick", function()
        local key = slot.key
        if not key then return end
        local entry = CleanBot_PartyBots[key]
        local botName = entry and entry.name or slot.name or key
        NS.CB_ToggleQuests(key, botName)
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Quest Log", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    slot.questBtn = btn
end
