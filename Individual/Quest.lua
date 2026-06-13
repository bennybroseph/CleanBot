-- ============================================================
-- Quest.lua  —  Per-bot quest log.
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

-- Quest objectives are rendered generically and bot-accurately by default (the
-- requirement count is quest-static; completion follows the BOT's quest status —
-- see CB_FormatGenericObjective). This flag switches the detail pane back to the
-- raw player leaderboard progress ("cur/req" from GetQuestLogLeaderBoard):
--   false = generic, bot-accurate view (default)
--   true  = raw player progress (kept for if a real per-bot progress source appears)
local SHOW_OBJECTIVE_PROGRESS = false

-- ── Quest list rendering constants ──────────────────────────────────────
local QUEST_HEADER_H = 20   -- collapsible group header height (px)
local QUEST_ROW_H    = 16   -- quest entry row height (px)
local QUEST_INDENT   = 14   -- left indent for quest rows inside a group
local QUEST_GAP      = 1    -- vertical gap between rows (px)

-- Per-status display metadata: group label and header text color.
local QUEST_STATUS_INFO = {
    I = { label = "Incomplete", r = 1.0,   g = 1.0,   b = 0.0   },  -- #ffff00
    C = { label = "Complete",   r = 0.251, g = 0.749, b = 0.251 },  -- #40bf40
    F = { label = "Failed",     r = 1.0,  g = 0.2,  b = 0.2 },  -- red
}
-- Render order: most actionable (Incomplete) first.
local QUEST_STATUS_ORDER = { "I", "C", "F" }

-- ── Money formatting ────────────────────────────────────────────────────
-- |T path:h:w|t inline texture codes render coin icons inside FontStrings.
local GOLD_ICON   = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12|t"

---@param copper number  Amount of money in copper.
---@return string         Money string with inline g/s/c coin-icon texture codes.
local function CB_FormatMoney(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. " " .. GOLD_ICON   end
    if s > 0 then parts[#parts + 1] = s .. " " .. SILVER_ICON end
    if c > 0 then parts[#parts + 1] = c .. " " .. COPPER_ICON end
    if #parts == 0 then return "0 " .. COPPER_ICON end
    return table.concat(parts, "  ")
end

-- Rewrites a player-log objective string into a generic, bot-accurate form.
-- The leaderboard text ("Name: cur/req") reports the PLAYER's current count, so we
-- rebuild it from the quest-static requirement (req) and the BOT's quest completion:
--   incomplete → "Name x req"  (counted)  /  "Name"            (boolean)
--   complete   → "Name: req/req (Complete)" / "Name (Complete)"
---@param text     string   Raw GetQuestLogLeaderBoard text.
---@param complete boolean  Whether the BOT's quest is complete.
---@return string           The generic objective label.
local function CB_FormatGenericObjective(text, complete)
    -- Counted objective "Name: cur/req" → rebuild from the static requirement.
    local name, _, req = text:match("^(.-):%s*(%d+)%s*/%s*(%d+)%s*$")
    if name then
        if complete then return string.format("%s: %s/%s (Complete)", name, req, req) end
        return string.format("%s x %s", name, req)
    end
    -- Boolean / location objective (no counts).
    if complete then return text .. " (Complete)" end
    return text
end

-- Populates a pre-created LargeItemButtonTemplate reward button with item data.
-- Accesses children by name ($parentIconTexture, $parentName, $parentCount).
---@param slot     table    The reward slot button (from CB_CreateQuestRewardItem).
---@param tex      string   Item icon texture path.
---@param itemName string   Item name to display.
---@param count    number   Stack count (count > 1 shows the count text).
---@param link     string   Item link for the hover tooltip.
---@param quality  number   Item quality 0–6 (drives name/border colour).
local function CB_PopulateRewardSlot(slot, tex, itemName, count, link, quality)
    local bName   = slot:GetName()
    local iconTex = bName and _G[bName .. "IconTexture"]
    local nameFS  = bName and _G[bName .. "Name"]
    local countFS = bName and _G[bName .. "Count"]
    if iconTex then iconTex:SetTexture(tex or "") end
    if nameFS  then
        nameFS:SetText(itemName or "")
        local r, g, b = NS.CB_GetQualityColor(quality)
        nameFS:SetTextColor(r, g, b)
    end
    if countFS then
        if count and count > 1 then
            countFS:SetText(tostring(count))
            countFS:Show()
        else
            countFS:SetText("")
            countFS:Hide()
        end
    end
    slot.itemLink = link  -- used by OnEnter tooltip in CB_CreateQuestRewardItem
end

-- Lays out items from `items` (array of {tex,name,count,link}) into a 2-column grid.
-- Each slot is sized to itemSlotW. Rows of 2; odd remainders get a lone slot on the
-- last row. Returns the updated prevFS (first slot of the last row) and slotIdx.
---@param items       table   Array of { tex, name, count, link, quality } reward items.
---@param count       number  Number of items to lay out.
---@param rewardSlots table   Pre-created reward slot pool to populate.
---@param slotIdx     number  Next free index into rewardSlots.
---@param itemSlotW   number  Width to size each slot to.
---@param prevFS      table   Widget the first row anchors below.
---@param detailFrames table  Frame list the shown slots are appended to.
---@return table              prevFS — first slot of the last row.
---@return number             slotIdx — next free slot index.
local function CB_LayoutRewardGrid(items, count, rewardSlots, slotIdx, itemSlotW, prevFS, detailFrames)
    local prevSlot = nil
    for i = 1, count do
        local item = items[i]
        if item and slotIdx <= #rewardSlots then
            local slot = rewardSlots[slotIdx]
            slotIdx = slotIdx + 1
            CB_PopulateRewardSlot(slot, item.tex, item.name, item.count, item.link, item.quality)
            NS.CB_SetQualityBorder(slot, item.quality)
            slot:SetWidth(itemSlotW)
            if (i - 1) % 2 == 0 then
                -- Left column — start of a new row.
                NS.CB_AnchorBelow(slot, prevFS)
                prevFS = slot
            else
                -- Right column — same row as previous slot.
                NS.CB_AnchorAhead(slot, prevSlot)
            end
            slot:Show()
            detailFrames[#detailFrames + 1] = slot
            prevSlot = slot
        end
    end
    return prevFS, slotIdx
end

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
---@param sc        table   Scroll child the group is rendered into.
---@param framePool table   Frame pool the created header/rows are appended to.
---@param key       string  Bot name-key (for the collapse-state key).
---@param statusKey string  Status group key ("I"/"C"/"F").
---@param info      table   Status display metadata (label, colour).
---@param quests    table   Array of quests in this status group.
---@param yOffset   number  Current vertical offset within the scroll child.
---@return number           The new yOffset after the group's rows.
local function CB_RenderQuestGroup(sc, framePool, key, statusKey, info, quests, yOffset)
    local collapseKey = key .. "~" .. statusKey
    local isCollapsed = questGroupCollapsed[collapseKey]

    -- ── Header button ─────────────────────────────────────────────────────
    local headerBtn = CreateFrame("Button", nil, sc)
    headerBtn:SetHeight(QUEST_HEADER_H)
    headerBtn:SetPoint("TOPLEFT",  sc, "TOPLEFT",  0, yOffset)
    headerBtn:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, yOffset)

    local arrow = NS.CB_CreateCollapseButton(headerBtn, isCollapsed)
    arrow:SetPoint("LEFT", headerBtn, "LEFT", 2, 0)

    local headerLabel = headerBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    headerLabel:SetPoint("LEFT",  headerBtn, "LEFT",  20, 0)
    headerLabel:SetPoint("RIGHT", headerBtn, "RIGHT",  0, 0)
    headerLabel:SetJustifyH("LEFT")
    headerLabel:SetTextColor(info.r, info.g, info.b)
    headerLabel:SetText(info.label .. " (" .. #quests .. ")")

    -- Toggle collapse state and re-render the full list.
    -- Hover brightens the label to white; leave restores the status colour.
    headerBtn:SetScript("OnClick", function()
        questGroupCollapsed[collapseKey] = not questGroupCollapsed[collapseKey]
        NS.CB_RenderQuests(key)
    end)
    headerBtn:SetScript("OnEnter", function()
        headerLabel:SetTextColor(1, 1, 1)
    end)
    headerBtn:SetScript("OnLeave", function()
        headerLabel:SetTextColor(info.r, info.g, info.b)
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
            -- Selection highlight: persistent texture shown on the active row.
            -- Tinted to the quest's status colour so the selection reads as
            -- part of the status group rather than a neutral highlight.
            -- Hidden by default; shown and re-tinted on click.
            local selTex = rowBtn:CreateTexture(nil, "BACKGROUND")
            selTex:SetAllPoints()
            selTex:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
            selTex:SetBlendMode("ADD")
            selTex:SetVertexColor(info.r, info.g, info.b)
            selTex:Hide()

            local nameText = rowBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            nameText:SetPoint("LEFT",  rowBtn, "LEFT",  0, 0)
            nameText:SetPoint("RIGHT", rowBtn, "RIGHT", 0, 0)
            nameText:SetJustifyH("LEFT")
            nameText:SetTextColor(info.r, info.g, info.b)
            nameText:SetText(displayName)

            -- Capture these for the closures below.
            local questID   = quest.id
            local statusR   = info.r
            local statusG   = info.g
            local statusB   = info.b

            -- Click selects this quest and renders its details in the right pane.
            -- Deselects the previous row by hiding its selection texture and
            -- restoring its status colour. Hover brightens the label to white.
            rowBtn:SetScript("OnClick", function()
                local f = NS.botQuestFrames and NS.botQuestFrames[key]
                if f and f.selectedRowText and f.selectedRowText ~= nameText then
                    local sr, sg, sb = f.selectedRowColor.r, f.selectedRowColor.g, f.selectedRowColor.b
                    f.selectedRowText:SetTextColor(sr, sg, sb)
                    if f.selectedRowTex then f.selectedRowTex:Hide() end
                end
                if f then
                    f.selectedRowText  = nameText
                    f.selectedRowTex   = selTex
                    f.selectedRowColor = { r = statusR, g = statusG, b = statusB }
                end
                selTex:Show()
                nameText:SetTextColor(1, 1, 1)  -- white when selected
                NS.CB_RenderQuestDetail(key, questID)
            end)
            rowBtn:SetScript("OnEnter", function(self)
                local f = NS.botQuestFrames and NS.botQuestFrames[key]
                if not (f and f.selectedRowText == nameText) then
                    nameText:SetTextColor(1, 1, 1)  -- white on hover
                end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink("quest:" .. (questID or 0) .. ":60")
                GameTooltip:Show()
            end)
            rowBtn:SetScript("OnLeave", function()
                local f = NS.botQuestFrames and NS.botQuestFrames[key]
                if not (f and f.selectedRowText == nameText) then
                    nameText:SetTextColor(statusR, statusG, statusB)  -- restore status colour
                end
                GameTooltip:Hide()
            end)

            framePool[#framePool + 1] = rowBtn
            yOffset = yOffset - QUEST_ROW_H - QUEST_GAP
        end
    end

    return yOffset
end

-- ── Render quest details into the right scroll pane ─────────────────────
-- Called when the player clicks a quest row in the left pane.
-- Looks the quest up in the player's own log for description and objective
-- data. If the quest isn't in the player's log (bot-only quest), renders
-- the name and a "details unavailable" note instead.
---@param key     string  Bot name-key whose quest detail pane is shown.
---@param questID number  Quest ID to render the detail for.
NS.CB_RenderQuestDetail = function(key, questID)
    local f = NS.botQuestFrames and NS.botQuestFrames[key]
    if not f then return end
    local dsc = f.detailScrollChild

    -- Cancel any pending deferred height pass from a prior selection.
    dsc:SetScript("OnUpdate", nil)

    -- Hide frames from the previous detail render.
    if f.detailFrames then
        for _, fr in ipairs(f.detailFrames) do fr:Hide() end
    end
    f.detailFrames    = {}
    f.selectedQuestID = questID

    local DPAD = 8  -- inner padding from scroll child edges

    -- ── Gather data ────────────────────────────────────────────────────────
    -- GetQuestLogIndexByID does not exist in 3.3.5a — scan the log manually.
    -- GetQuestLogTitle returns questID at position 9 (added in WotLK).
    local logIndex = nil
    if questID then
        local n = GetNumQuestLogEntries()
        for i = 1, n do
            local _, _, _, _, isHeader, _, _, _, id = GetQuestLogTitle(i)
            if not isHeader and id == questID then
                logIndex = i
                break
            end
        end
    end
    local hasData = logIndex ~= nil

    local titleText   = ""
    local questDesc   = ""   -- NPC flavor text (1st return of GetQuestLogQuestText)
    local questObj    = ""   -- "Bring X to Y" instructions (2nd return)
    local leaderboard = {}   -- { text, finished } per GetQuestLogLeaderBoard entry
    local numChoices  = 0    -- pick-one reward items
    local numRewards  = 0    -- guaranteed reward items
    local rewardMoney = 0    -- copper
    local rewardXP    = 0
    local choiceItems = {}   -- { name, tex, count, quality }
    local rewardItems = {}   -- { name, tex, count, quality }

    if hasData then
        -- Briefly select the quest so the text / leaderboard APIs return its data.
        -- Restore the previous selection immediately after to avoid disturbing
        -- what the player has open in their own quest log UI.
        local prevSel    = GetQuestLogSelection()
        SelectQuestLogEntry(logIndex)
        titleText        = GetQuestLogTitle(logIndex) or ""
        local d, o       = GetQuestLogQuestText()
        questDesc        = d or ""
        questObj         = o or ""
        local numEntries = GetNumQuestLeaderBoards()
        for i = 1, numEntries do
            local text, _, finished = GetQuestLogLeaderBoard(i)
            leaderboard[#leaderboard + 1] = { text = text or "", finished = finished }
        end
        -- Reward data is gathered inside the same SelectQuestLogEntry block so all
        -- reward APIs see the correct quest without a second selection call.
        numChoices  = GetNumQuestLogChoices() or 0
        numRewards  = GetNumQuestLogRewards() or 0
        rewardMoney = GetQuestLogRewardMoney() or 0
        rewardXP    = (GetQuestLogRewardXP and GetQuestLogRewardXP()) or 0
        for i = 1, numChoices do
            local rName, tex, count, quality = GetQuestLogChoiceInfo(i)
            local link = GetQuestLogItemLink and GetQuestLogItemLink("choice", i)
            choiceItems[i] = { name = rName, tex = tex, count = count, quality = quality, link = link }
        end
        for i = 1, numRewards do
            local rName, tex, count, quality = GetQuestLogRewardInfo(i)
            local link = GetQuestLogItemLink and GetQuestLogItemLink("reward", i)
            rewardItems[i] = { name = rName, tex = tex, count = count, quality = quality, link = link }
        end
        SelectQuestLogEntry(prevSel or 0)
    else
        titleText = (questID and NS.questNameCache[questID]) or tostring(questID or "?")
    end

    -- ── Wire the Abandon button to this quest ──────────────────────────────
    -- Resolve the quest name from the bridge packet (most reliable — present
    -- even for quests the player doesn't have). Fall back to the name cache.
    local entry = CleanBot_PartyBots and CleanBot_PartyBots[key]
    local abandonName = (questID and NS.questNameCache[questID]) or tostring(questID or "?")

    if f.abandonBtn then
        f.abandonBtn:Enable()
        f.abandonBtn:SetScript("OnClick", function()
            if not entry then return end
            NS.CB_SendBotCommand(entry.name, "drop " .. abandonName)
            -- Disable the button and wait 2 seconds before re-fetching.
            -- The bot processes the command server-side; there is no structured
            -- response packet, so a fixed timeout is the reliable refresh trigger.
            f.abandonBtn:Disable()
            local elapsed = 0
            f:SetScript("OnUpdate", function(self, dt)
                elapsed = elapsed + dt
                if elapsed >= 2 then
                    self:SetScript("OnUpdate", nil)
                    NS.CB_FetchQuests(key, entry.name)
                end
            end)
        end)
    end

    local contentW = dsc:GetWidth() - DPAD * 2

    -- ── Title ──────────────────────────────────────────────────────────────
    -- Intentionally anchored flush to the top-left with no padding or margin.
    -- The quest title acts as a full-bleed header; content below it provides
    -- its own visual separation via CB_AnchorBelow spacing.
    local titleFS = NS.CB_CreateQuestHeader(dsc)
    titleFS:SetPoint("TOPLEFT", dsc, "TOPLEFT", 0, -DPAD)
    titleFS:SetWidth(dsc:GetWidth())
    titleFS:SetText(titleText)
    f.detailFrames[#f.detailFrames + 1] = titleFS

    local prevFS = titleFS

    -- ── No-data fallback ───────────────────────────────────────────────────
    if not hasData then
        local noDataFS = NS.CB_CreateQuestParagraph(dsc)
        NS.CB_AnchorBelow(noDataFS, prevFS)
        noDataFS:SetText("Details unavailable.\nYou do not have this quest.")
        f.detailFrames[#f.detailFrames + 1] = noDataFS

        dsc:SetHeight(math.max(80, f.detailScrollFrame:GetHeight() or 1))
        return
    end

    -- ── Quest objectives text ───────────────────────────────────────────────
    -- The instructional line(s) from the quest giver: "Bring X to Y."
    -- Distinct from the leaderboard progress counters below.
    if questObj ~= "" then
        local objTextFS = NS.CB_CreateQuestParagraph(dsc)
        NS.CB_AnchorBelow(objTextFS, prevFS)
        objTextFS:SetWidth(contentW)
        objTextFS:SetText(questObj)
        f.detailFrames[#f.detailFrames + 1] = objTextFS
        prevFS = objTextFS
    end

    -- ── Objective requirements ──────────────────────────────────────────────
    -- GetQuestLogLeaderBoard reports the PLAYER's progress ("Wolves slain: 3/10"),
    -- which is misleading for a bot. By default we render generically and drive
    -- completion off the BOT's quest status (botComplete): incomplete shows just the
    -- requirement ("Name x N"), complete shows "Name: N/N (Complete)". The existing
    -- gold/gray colours are unchanged — botComplete just selects between them.
    -- SHOW_OBJECTIVE_PROGRESS restores the raw player progress for the future case
    -- where a real per-bot objective-progress source exists.
    local botComplete = false
    if entry and entry.quests then
        for _, q in ipairs(entry.quests) do
            if q.id == questID then botComplete = (q.status == "C"); break end
        end
    end

    for _, lbEntry in ipairs(leaderboard) do
        local label, finishedColor
        if SHOW_OBJECTIVE_PROGRESS then
            finishedColor = lbEntry.finished
            label = lbEntry.finished and (lbEntry.text .. " (Complete)") or lbEntry.text
        else
            finishedColor = botComplete
            label = CB_FormatGenericObjective(lbEntry.text, botComplete)
        end
        local entryFS = NS.CB_CreateObjectiveText(dsc, finishedColor)
        NS.CB_AnchorBelow(entryFS, prevFS)
        entryFS:SetWidth(contentW)
        entryFS:SetText(label)
        f.detailFrames[#f.detailFrames + 1] = entryFS
        prevFS = entryFS
    end

    -- ── Description header + body ───────────────────────────────────────────
    -- The NPC flavor text that introduces the quest's story context.
    if questDesc ~= "" then
        local descLabelFS = NS.CB_CreateQuestHeader(dsc)
        NS.CB_AnchorBelow(descLabelFS, prevFS)
        descLabelFS:SetText("Description")
        f.detailFrames[#f.detailFrames + 1] = descLabelFS
        prevFS = descLabelFS

        local descFS = NS.CB_CreateQuestParagraph(dsc)
        NS.CB_AnchorBelow(descFS, prevFS)
        descFS:SetWidth(contentW)
        descFS:SetText(questDesc)
        f.detailFrames[#f.detailFrames + 1] = descFS
        prevFS = descFS
    end

    -- ── Rewards ─────────────────────────────────────────────────────────────
    local hasChoices  = numChoices > 0
    local hasRequired = numRewards > 0
    local hasMoney    = rewardMoney > 0
    local hasXP       = rewardXP > 0

    if hasChoices or hasRequired or hasMoney or hasXP then
        local rewardsHdrFS = NS.CB_CreateQuestHeader(dsc)
        NS.CB_AnchorBelow(rewardsHdrFS, prevFS)
        rewardsHdrFS:SetText("Rewards")
        f.detailFrames[#f.detailFrames + 1] = rewardsHdrFS
        prevFS = rewardsHdrFS

        local slotIdx    = 1
        local itemSlotW  = math.floor(contentW / 2)

        -- Choice items
        if hasChoices then
            local choiceLblFS = NS.CB_CreateQuestParagraph(dsc)
            NS.CB_AnchorBelow(choiceLblFS, prevFS)
            choiceLblFS:SetWidth(contentW)
            choiceLblFS:SetText("You will be able to choose one of these rewards:")
            f.detailFrames[#f.detailFrames + 1] = choiceLblFS
            prevFS = choiceLblFS

            prevFS, slotIdx = CB_LayoutRewardGrid(
                choiceItems, numChoices, f.rewardSlots, slotIdx,
                itemSlotW, prevFS, f.detailFrames)
        end

        -- "You will [also] receive:" label — shown whenever there are items, money, or XP
        if hasRequired or hasMoney or hasXP then
            local recvText = hasChoices and "You will also receive:" or "You will receive:"
            local recvLblFS = NS.CB_CreateQuestParagraph(dsc)
            NS.CB_AnchorBelow(recvLblFS, prevFS)
            recvLblFS:SetText(recvText)
            f.detailFrames[#f.detailFrames + 1] = recvLblFS
            prevFS = recvLblFS

            -- Money sits on the same line as the label via AnchorAhead.
            -- prevFS stays on recvLblFS so XP and items anchor below the row correctly.
            if hasMoney then
                local moneyFS = NS.CB_CreateQuestParagraph(dsc)
                NS.CB_AnchorAhead(moneyFS, recvLblFS)
                moneyFS:SetText(CB_FormatMoney(rewardMoney))
                f.detailFrames[#f.detailFrames + 1] = moneyFS
            end

            -- XP line
            if hasXP then
                local xpFS = NS.CB_CreateQuestParagraph(dsc)
                NS.CB_AnchorBelow(xpFS, prevFS)
                xpFS:SetWidth(contentW)
                xpFS:SetText("Experience: " .. tostring(rewardXP))
                f.detailFrames[#f.detailFrames + 1] = xpFS
                prevFS = xpFS
            end

            -- Required (non-choice) item grid
            if hasRequired then
                prevFS, slotIdx = CB_LayoutRewardGrid(
                    rewardItems, numRewards, f.rewardSlots, slotIdx,
                    itemSlotW, prevFS, f.detailFrames)
            end
        end
    end

    -- ── Deferred height: measure after layout resolves ─────────────────────
    -- GetBottom() on FontStrings needs one rendered frame to return valid values.
    dsc:SetScript("OnUpdate", function(self)
        self:SetScript("OnUpdate", nil)
        local dsTop   = dsc:GetTop()
        local lowestY = dsTop
        for _, fr in ipairs(f.detailFrames) do
            local b = fr:GetBottom()
            if b and b < lowestY then lowestY = b end
        end
        local contentH = (dsTop - lowestY) + DPAD
        local frameH   = f.detailScrollFrame:GetHeight() or 1
        dsc:SetHeight(math.max(contentH, frameH))
    end)
end

-- ── Render the quest list for a bot (called by Bridge.lua on QUESTS_END) ─
-- Clears the previous render pass, groups entry.quests by status, and stamps
-- one collapsible group per non-empty status into the left scroll pane.
-- entry.quests = { { id, name, status } ... }  (status "I"/"C"/"F")
---@param key string  Bot name-key whose quest list should be (re)rendered.
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
---@param f table  The quest frame to skin (mirrors QuestLogFrame chrome).
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
---@param parent table   Parent frame the scroll container is inset within.
---@param name   string  Global name; the scroll bar derives from it.
---@param left   number  Left inset from the parent.
---@param top    number  Top inset from the parent.
---@param right  number  Right inset from the parent.
---@param bottom number  Bottom inset from the parent.
---@return table  The created container Frame.
local function CB_MakeScrollContainer(parent, name, left, top, right, bottom)
    local c = CreateFrame("Frame", name, parent)
    c:SetPoint("TOPLEFT",     parent, "TOPLEFT",      left,  -top)
    c:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -right,  bottom)
    c.paddingTop = 0; c.paddingBottom = 0
    c.paddingLeft = 0; c.paddingRight = 0
    return c
end

-- ── Get or create quest frame for a bot ──────────────────────────────────
---@param key     string  Bot name-key.
---@param botName string  Bot's display name (used in the title bar).
---@return table           The bot's quest frame, created lazily on first call.
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

    -- Pre-create a fixed pool of QuestInfoItemTemplate reward buttons parented to the
    -- detail scroll child. 12 covers the maximum possible rewards (6 choice + 6 required).
    -- CB_RenderQuestDetail populates and shows them as needed; all start hidden.
    f.rewardSlots = {}
    for i = 1, 12 do
        local slotName = "CleanBotRewardSlot_" .. key .. "_" .. i
        local slot = NS.CB_CreateQuestRewardItem(dsc, slotName)
        slot:Hide()
        f.rewardSlots[i] = slot
    end

    -- ── Action buttons ────────────────────────────────────────────────────
    -- Creation and positioning differ per skin; behaviour is shared after.
    -- ElvUI: CB_CreateButton; Abandon at BOTTOMLEFT, chain via CB_AnchorAhead,
    --        Close independent at BOTTOMRIGHT.
    -- Blizz: UIPanelButtonTemplate, fixed BLIZZ_BTN_* positions.
    local abandonBtn, shareBtn, trackBtn, closeActionBtn

    if NS.ElvUI_S then
        local pad = NS.PADDING.frame

        abandonBtn = NS.CB_CreateButton(f, "CleanBotQuestAbandon_" .. key, "Abandon", 90, BLIZZ_BTN_H)
        abandonBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT",
            pad.left   + (abandonBtn.marginLeft   or 0),
            pad.bottom + (abandonBtn.marginBottom or 0))

        shareBtn = NS.CB_CreateButton(f, "CleanBotQuestShare_" .. key, "Share", 90, BLIZZ_BTN_H)
        NS.CB_AnchorAhead(shareBtn, abandonBtn)

        trackBtn = NS.CB_CreateButton(f, "CleanBotQuestTrack_" .. key, "Track", 90, BLIZZ_BTN_H)
        NS.CB_AnchorAhead(trackBtn, shareBtn)

        closeActionBtn = NS.CB_CreateButton(f, "CleanBotQuestCloseAction_" .. key, "Close", 90, BLIZZ_BTN_H)
        closeActionBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",
            -((pad.right or 0) + (closeActionBtn.marginRight or 0)),
            pad.bottom + (closeActionBtn.marginBottom or 0))
    else
        local function makeBtn(name, label, w)
            local btn = CreateFrame("Button", name, f, "UIPanelButtonTemplate")
            btn:SetSize(w, BLIZZ_BTN_H)
            btn:SetText(label)
            return btn
        end

        abandonBtn     = makeBtn("CleanBotQuestAbandon_"     .. key, "Abandon", BLIZZ_ABANDON_W)
        shareBtn       = makeBtn("CleanBotQuestShare_"       .. key, "Share",   BLIZZ_SHARE_W)
        trackBtn       = makeBtn("CleanBotQuestTrack_"       .. key, "Track",   BLIZZ_TRACK_W)
        closeActionBtn = makeBtn("CleanBotQuestCloseAction_" .. key, "Close",   BLIZZ_CLOSE_BTN_W)

        abandonBtn:SetPoint(    "BOTTOMLEFT",  f, "BOTTOMLEFT",  BLIZZ_ABANDON_X,    BLIZZ_BTN_Y)
        shareBtn:SetPoint(      "BOTTOMLEFT",  f, "BOTTOMLEFT",  BLIZZ_SHARE_X,      BLIZZ_BTN_Y)
        trackBtn:SetPoint(      "BOTTOMLEFT",  f, "BOTTOMLEFT",  BLIZZ_TRACK_X,      BLIZZ_BTN_Y)
        closeActionBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -BLIZZ_CLOSE_BTN_X, BLIZZ_BTN_Y)
    end

    abandonBtn:Disable()
    shareBtn:Disable()
    trackBtn:Disable()
    closeActionBtn:SetScript("OnClick", function() f:Hide() end)

    f.abandonBtn     = abandonBtn
    f.shareBtn       = shareBtn
    f.trackBtn       = trackBtn
    f.closeActionBtn = closeActionBtn

    f.questList = {}
    f:Hide()
    NS.botQuestFrames[key] = f
    return f
end

-- ── Show / fetch quests ──────────────────────────────────────────────────
-- anchor "CENTER" centers the frame on screen (used by the unit right-click menu,
-- which opens away from CleanBotFrame); nil defaults beside CleanBotFrame.
---@param key     string   Bot name-key.
---@param botName string   Bot's display name.
---@param anchor  string?  "CENTER" or nil.
NS.CB_ShowQuests = function(key, botName, anchor)
    local f = NS.CB_GetQuestFrame(key, botName)
    f:ClearAllPoints()
    if anchor == "CENTER" then
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    else
        f:SetPoint("TOPLEFT", CleanBotFrame, "TOPRIGHT", 4, 0)
    end
    NS.CB_FetchQuests(key, botName)
    f:Show()
end

-- ── Toggle quests open/closed ────────────────────────────────────────────
---@param key     string   Bot name-key.
---@param botName string   Bot's display name.
---@param anchor  string?  Placement forwarded to CB_ShowQuests ("CENTER" or nil).
NS.CB_ToggleQuests = function(key, botName, anchor)
    local f = NS.CB_GetQuestFrame(key, botName)
    if f:IsShown() then
        f:Hide()
    else
        NS.CB_ShowQuests(key, botName, anchor)
    end
end

-- ── Quest button for the model viewer ───────────────────────────────────
-- Mirrors the inventory (bag) button on the opposite side: same slot size, same
-- weapon-row band, but anchored to the bottom of the RIGHT equip column (slot 14)
-- instead of the left column. Bag uses LEFT(slot 9)/TOP(slot 16); this uses
-- RIGHT(slot 14)/TOP(slot 16).
---@param slot     table   The pool slot the button belongs to (resolves the live bot).
---@param model    table   The model frame the button anchors against.
---@param slotSize number  Equip-slot size (matches the bag button's size).
NS.CB_CreateQuestButton = function(slot, model, slotSize)
    local btn = NS.CB_CreateIconButton(model, "CleanBotQuestBtn_" .. slot.index,
        "Interface\\QUESTFRAME\\UI-QuestLog-BookIcon", slotSize)
    btn:SetPoint("RIGHT", slot.equipSlots[14], "RIGHT", 0, 0)
    btn:SetPoint("TOP",   slot.equipSlots[16], "TOP",   0, 0)

    -- Blizzard-style slot border. The book icon has no border baked in (unlike the bag's
    -- backpack art), so add the standard UI-Quickslot2 border on top, sized like
    -- ItemButtonTemplate's normal texture (64px art over a 37px button, centred with a -1 y
    -- offset) so it overhangs the icon as a beveled frame. Blizz path only — ElvUI's skin
    -- already frames the button.
    if not NS.ElvUI_S then
        local border = btn:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
        border:SetPoint("CENTER", btn, "CENTER", 0, -1)
        border:SetSize(slotSize * (64 / 37), slotSize * (64 / 37))
    end

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
