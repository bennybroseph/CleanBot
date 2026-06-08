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
local BLIZZ_TOP    = 75   -- parchment top inset (chrome header band)
local BLIZZ_BOTTOM = 37   -- parchment bottom inset
local BLIZZ_SIDE   = 19   -- left and right inset
local BLIZZ_PANE_W = 305  -- width of each content pane

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

-- ── Quest frames pool ────────────────────────────────────────────────────
NS.botQuestFrames = {}

-- ── Fetch quests for a bot ───────────────────────────────────────────────
NS.CB_FetchQuests = function(key, botName)
    if not CleanBot_PartyBots[key] then return end
    local entry = CleanBot_PartyBots[key]
    entry.quests = {}
    NS.CB_SendBotCommand(botName, "quests")
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
        title:SetPoint("CENTER", f, "TOP", 0, -36)
        title:SetJustifyH("CENTER")

        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", BLIZZ_X_BTN_X, BLIZZ_X_BTN_Y)

        -- Two scroll containers manually placed over the left and right parchment panes.
        -- Left pane: SIDE → SIDE+PANE_W. Right pane: mirrored from the right edge.
        local rightOffset = BLIZZ_W - BLIZZ_SIDE - BLIZZ_PANE_W
        listScrollParent = CB_MakeScrollContainer(f,
            "CleanBotQuestsLeftPane_" .. key,
            BLIZZ_SIDE, BLIZZ_TOP,
            rightOffset, BLIZZ_BOTTOM)

        detailScrollParent = CB_MakeScrollContainer(f,
            "CleanBotQuestsRightPane_" .. key,
            rightOffset, BLIZZ_TOP,
            BLIZZ_SIDE, BLIZZ_BOTTOM)
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
