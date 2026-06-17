-- ============================================================
-- Recruiter.lua  —  Dungeon Finder bot recruiter.
--
-- A tab attached to the right edge of the default Dungeon Finder window (LFDParentFrame).
-- Clicking it opens a small panel where you pick a ROLE and a CLASS (and optional gender),
-- then click Recruit to summon a level-matched bot of that class into your party.
--
-- Mechanism (mod-playerbots, player-usable when AiPlayerbot.AddClassCommand = 1, the default):
--   .playerbots bot addclass <class> [male|female]
-- The server pulls a bot of that class from the addclass pool, auto-levels it to match you,
-- and adds it to your group. The command takes class only — no role — so the chosen role is
-- applied AFTER the bot joins by whispering "talents spec <rolespec>" (the same spec tokens the
-- Individual tab uses, see NS.CLASS_STRATEGIES). The newly-joined bot is found by diffing the
-- group roster on PARTY_MEMBERS_CHANGED / RAID_ROSTER_UPDATE and matching its class.
--
-- Attach pattern mirrors Merchant.lua: a UIParent-parented HIGH-strata tab + panel cross-anchored
-- to the Blizzard window, shown/hidden with it (here via OnShow/OnHide — LFD has no show event).
-- ============================================================

local NS = CleanBotNS

-- ── Recruiter data (single source of truth) ──────────────────────────────────
-- A class is valid for a role iff it has a spec for that role here, so CB_RecruiterClassesForRole
-- derives the valid-class list directly from this table (no separate role→class map to keep in sync).
-- Spec tokens mirror the PvE specs in NS.CLASS_STRATEGIES (Individual/ClassData.lua); the whisper is
-- "talents spec <token>".
local ROLE_SPEC = {
    WARRIOR     = { TANK = "prot pve",              DPS = "arms pve"   },
    PALADIN     = { TANK = "prot pve", HEAL = "holy pve",  DPS = "ret pve" },
    HUNTER      = {                                  DPS = "bm pve"     },
    ROGUE       = {                                  DPS = "combat pve" },
    PRIEST      = {                  HEAL = "holy pve",  DPS = "shadow pve" },
    DEATHKNIGHT = { TANK = "double aura blood pve",  DPS = "frost pve"  },
    SHAMAN      = {                  HEAL = "resto pve", DPS = "ele pve" },
    MAGE        = {                                  DPS = "frost pve"  },
    WARLOCK     = {                                  DPS = "affli pve"  },
    DRUID       = { TANK = "bear pve", HEAL = "resto pve", DPS = "balance pve" },
}

-- Canonical class order for the icon grid (DPS shows all ten in this order).
local CLASS_ORDER = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
    "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID",
}

-- Roles shown left-to-right, with display labels.
local ROLE_ORDER  = { "TANK", "HEAL", "DPS" }
local ROLE_LABEL  = { TANK = "Tank", HEAL = "Healer", DPS = "DPS" }

-- Genders (Any omits the command arg → server picks randomly).
local GENDER_ORDER = { "ANY", "MALE", "FEMALE" }
local GENDER_LABEL = { ANY = "Any", MALE = "Male", FEMALE = "Female" }

local RECRUIT_TIMEOUT = 30   -- seconds to wait for the summoned bot to join before giving up

-- ── Pure helpers (exposed for spec/recruiter_spec.lua) ───────────────────────
--- Class tokens valid for a role, in CLASS_ORDER. Derived from ROLE_SPEC.
---@param role string  "TANK" | "HEAL" | "DPS"
---@return table       ordered list of class tokens
NS.CB_RecruiterClassesForRole = function(role)
    local out = {}
    for _, c in ipairs(CLASS_ORDER) do
        if ROLE_SPEC[c] and ROLE_SPEC[c][role] then out[#out + 1] = c end
    end
    return out
end

--- Roles (TANK/HEAL/DPS, in that order) a class can fill. Inverse of CB_RecruiterClassesForRole;
--- derived from ROLE_SPEC[class]. Used by the action-bar recruit flyout's per-class role level.
---@param class string
---@return table  ordered list of role tokens
NS.CB_RecruiterRolesForClass = function(class)
    local out = {}
    for _, role in ipairs({ "TANK", "HEAL", "DPS" }) do
        if ROLE_SPEC[class] and ROLE_SPEC[class][role] then out[#out + 1] = role end
    end
    return out
end

--- A copy of the canonical class order (for the recruit flyout's class level + the random pick).
---@return table  ordered list of class tokens
NS.CB_RecruiterAllClasses = function()
    local out = {}
    for i, c in ipairs(CLASS_ORDER) do out[i] = c end
    return out
end

--- The "talents spec" token for a class+role, or nil if that class can't fill the role.
---@param class string
---@param role  string
---@return string|nil
NS.CB_RecruiterSpec = function(class, role)
    return ROLE_SPEC[class] and ROLE_SPEC[class][role]
end

--- The server class argument for addclass ("dk" for Death Knight, else the lowercased token).
---@param class string
---@return string
NS.CB_RecruiterAddClassArg = function(class)
    if class == "DEATHKNIGHT" then return "dk" end
    return strlower(class)
end

--- The trailing gender argument for addclass ("" for Any).
---@param gender string  "ANY" | "MALE" | "FEMALE"
---@return string
NS.CB_RecruiterGenderArg = function(gender)
    if gender == "MALE"   then return " male"   end
    if gender == "FEMALE" then return " female" end
    return ""
end

--- Finds the first group member that is new (its lowercased name not in prevSet) and whose class
--- token matches wantClass. Pure so the roster-diff is unit-testable.
---@param prevSet   table  { [lowerName] = true } snapshot taken before recruiting
---@param members   table  list of { name = string, class = classToken }
---@param wantClass string class token to match
---@return string|nil      the matching member's name, or nil
NS.CB_RecruiterFindNewMember = function(prevSet, members, wantClass)
    for _, m in ipairs(members) do
        if m.name and not prevSet[strlower(m.name)] and m.class == wantClass then
            return m.name
        end
    end
    return nil
end

-- ── State ────────────────────────────────────────────────────────────────────
local built = false
local recruiterTab, panel, recruitBtn, statusFS
local roleBtns   = {}   -- [role]  = button
local classBtns  = {}   -- [class] = class-icon button
local genderBtns = {}   -- [gender]= button

local selectedRole   = nil
local selectedClass  = nil
local selectedGender = "ANY"
local pending        = {}   -- list of { class, role, spec, prev = {lowerName=true}, done = bool }

-- ── Layout constants (tweak to move the UI around) ───────────────────────────
-- Tab offset from LFDParentFrame's TOPRIGHT, hand-tuned to sit on the Dungeon Finder window's
-- visible right edge. These deliberately do NOT match Merchant.lua's STRIP_X/COG_Y: the Merchant
-- art fills its logical frame, but the LFD frame's art doesn't line up with its logical TOPRIGHT,
-- so the offsets differ. Re-tune in-game if the window art ever changes.
local TAB_X        = -3
local TAB_Y        = -47
local PANEL_W      = 196
local PANEL_H      = 272
local PANEL_X      = 2      -- panel offset from the tab's TOPRIGHT (flies out to the right)
local PANEL_Y      = 0
local ROW_GAP      = 8      -- vertical gap between layout rows
local ROLE_BTN_H   = 22     -- row button heights (widths fill the row, computed from panel width)
local GEN_BTN_H    = 20
local RECRUIT_H    = 24
local ICON         = 28     -- class-icon button size
local ICON_GAP     = 4
local GRID_COLS    = 5

-- ── Selection visuals ────────────────────────────────────────────────────────
--- Locks a text button into a pressed ("active") look, or releases it.
local function CB_SetBtnActive(btn, active)
    if active then btn:SetButtonState("PUSHED", true)
    else           btn:SetButtonState("NORMAL", false) end
end

--- Shows/hides a class-icon button's selection glow.
local function CB_SetClassActive(btn, active)
    if btn.sel then btn.sel:SetShown(active) end
end

-- ── Recruit enable + status ──────────────────────────────────────────────────
local function CB_UpdateRecruitEnabled()
    if not recruitBtn then return end
    if selectedRole and selectedClass then recruitBtn:Enable() else recruitBtn:Disable() end
end

local function CB_SetStatus(text)
    if statusFS then statusFS:SetText(text or "") end
end

-- ── Class grid (re-laid out when the role changes) ───────────────────────────
--- Hides every class button, then lays the role-valid ones into rows that span the full inner width:
--- each row's icons are justified (first on the left wall, last on the right wall, even gaps); a lone
--- icon is centered. classAnchor sits at the left wall, so x is measured across the inner content span.
local function CB_LayoutClassButtons()
    for _, b in pairs(classBtns) do b:Hide() end
    if not selectedRole then return end
    local valid  = NS.CB_RecruiterClassesForRole(selectedRole)
    local total  = #valid
    local innerW = PANEL_W - (panel.paddingLeft or 0) - (panel.paddingRight or 0)
    for i, class in ipairs(valid) do
        local b = classBtns[class]
        if b then
            local row      = math.floor((i - 1) / GRID_COLS)
            local rowStart = row * GRID_COLS
            local rowCount = math.min(GRID_COLS, total - rowStart)
            local col      = (i - 1) - rowStart
            local x
            if rowCount <= 1 then
                x = (innerW - ICON) / 2
            else
                x = col * (ICON + (innerW - rowCount * ICON) / (rowCount - 1))
            end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", panel.classAnchor, "TOPLEFT", x, -(row * (ICON + ICON_GAP)))
            CB_SetClassActive(b, class == selectedClass)
            b:Show()
        end
    end
end

-- ── Selection setters ────────────────────────────────────────────────────────
local function CB_SetClass(class)
    selectedClass = class
    for c, b in pairs(classBtns) do CB_SetClassActive(b, c == class) end
    CB_UpdateRecruitEnabled()
end

local function CB_SetRole(role)
    selectedRole = role
    for r, b in pairs(roleBtns) do CB_SetBtnActive(b, r == role) end
    -- Drop a class pick that the new role can't fill.
    if selectedClass and not NS.CB_RecruiterSpec(selectedClass, role) then
        selectedClass = nil
    end
    CB_LayoutClassButtons()
    CB_UpdateRecruitEnabled()
end

local function CB_SetGender(gender)
    selectedGender = gender
    for g, b in pairs(genderBtns) do CB_SetBtnActive(b, g == gender) end
end

-- ── Recruit ──────────────────────────────────────────────────────────────────
--- Drops resolved/expired pending recruits so the list (and the per-roster-change scan) stays small.
local function CB_PrunePending()
    local keep = {}
    for _, e in ipairs(pending) do if not e.done then keep[#keep + 1] = e end end
    pending = keep
end

--- Snapshots the current roster (so the joined bot can be told apart), sends the addclass
--- command, and queues a pending entry that the roster handler resolves by setting the spec.
--- Recruits a bot: sends the addclass command, and (when `spec` is given) queues a pending entry the
--- roster handler resolves by whispering "talents spec <spec>" to the just-joined bot. Public so both
--- the panel and the action-bar recruit flyout drive recruiting through one path.
---@param class  string   class token (e.g. "WARRIOR")
---@param spec   string|nil "talents spec" token to apply on join, or nil for no specific spec
---@param gender string|nil "MALE" | "FEMALE" | nil/"ANY" (random)
---@param report fun(text:string)|nil  status sink (panel status line / chat print); optional
---@param label  string|nil descriptive label for the status messages (e.g. "Tank Warrior")
NS.CB_Recruit = function(class, spec, gender, report, label)
    if not class then return end
    report = report or function() end
    label  = label or (NS.CLASS_DISPLAY and NS.CLASS_DISPLAY[class]) or class

    local prev = {}
    NS.CB_ForEachGroupMember(function(_, name)
        if name then prev[strlower(name)] = true end
    end)

    local cmd = ".playerbots bot addclass " .. NS.CB_RecruiterAddClassArg(class)
        .. NS.CB_RecruiterGenderArg(gender or "ANY")
    SendChatMessage(cmd, "SAY")

    local entry = { class = class, spec = spec, prev = prev, done = false, report = report, label = label }
    pending[#pending + 1] = entry
    report("Recruiting a " .. label .. "…")

    -- Give up (and clear the status) if no matching bot joins in time.
    NS.CB_After(RECRUIT_TIMEOUT, function()
        if entry.done then return end
        entry.done = true
        CB_PrunePending()
        report("No bot joined — check the server allows addclass and the pool isn't empty.")
    end)
end

--- Panel Recruit button: recruit the selected class with the selected role's spec + gender.
local function CB_DoRecruit()
    if not (selectedRole and selectedClass) then return end
    local label = (ROLE_LABEL[selectedRole] or selectedRole) .. " "
        .. (NS.CLASS_DISPLAY and NS.CLASS_DISPLAY[selectedClass] or selectedClass)
    NS.CB_Recruit(selectedClass, NS.CB_RecruiterSpec(selectedClass, selectedRole),
        selectedGender, CB_SetStatus, label)
end

--- On a roster change, resolve any pending recruit whose class now appears as a new member:
--- apply its role spec and report it. Builds the {name,class} member list once and reuses it.
--- A matched member is removed from the list as it's claimed, so two same-class recruits resolve
--- to two distinct new bots rather than both grabbing the first one. Resolved entries are pruned.
local function CB_OnRosterChanged()
    local active = false
    for _, e in ipairs(pending) do if not e.done then active = true break end end
    if not active then return end

    local members = {}
    NS.CB_ForEachGroupMember(function(unit, name)
        if name then members[#members + 1] = { name = name, class = select(2, UnitClass(unit)) } end
    end)

    for _, e in ipairs(pending) do
        if not e.done then
            local name = NS.CB_RecruiterFindNewMember(e.prev, members, e.class)
            if name then
                e.done = true
                -- Claim this member so a later same-class entry picks a different new bot.
                for i, m in ipairs(members) do
                    if m.name == name then table.remove(members, i); break end
                end
                if e.spec then NS.CB_SendBotCommand(name, "talents spec " .. e.spec) end
                e.report("Recruited " .. name .. " as " .. e.label .. ".")
            end
        end
    end
    CB_PrunePending()
end

-- ── Panel build (once, at PLAYER_LOGIN) ──────────────────────────────────────
--- A class-icon button: the class atlas icon as its face, a selection glow overlay, a tooltip,
--- and a click that selects the class.
local function CB_MakeClassButton(class)
    local b = CreateFrame("Button", "CleanBotRecruitClass_" .. class, panel)
    b:SetSize(ICON, ICON)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    local coords = NS.CLASS_ICON_COORDS and NS.CLASS_ICON_COORDS[class]
    if coords then
        icon:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
        icon:SetTexCoord(unpack(coords))
    else
        icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    end

    -- Selection glow (additive checkbutton highlight), shown when this class is picked.
    local sel = b:CreateTexture(nil, "OVERLAY")
    sel:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    sel:SetBlendMode("ADD")
    sel:SetAllPoints()
    sel:Hide()
    b.sel = sel

    b:SetScript("OnClick", function() CB_SetClass(class) end)
    NS.CB_SetTooltip(b, NS.CLASS_DISPLAY and NS.CLASS_DISPLAY[class] or class)
    b:Hide()   -- shown only once a role is picked (CB_LayoutClassButtons)
    classBtns[class] = b
    return b
end

local function CB_BuildPanel()
    -- The toggle tab on the Dungeon Finder's right edge (spellbook side-tab template, like the
    -- merchant cog), with a cropped LFG icon. Clicking it toggles the panel.
    recruiterTab = CreateFrame("CheckButton", "CleanBotRecruiterTab", UIParent, "SpellBookSkillLineTabTemplate")
    recruiterTab:SetFrameStrata("HIGH")
    recruiterTab:SetPoint("TOPLEFT", LFDParentFrame, "TOPRIGHT", TAB_X, TAB_Y)
    NS.CB_SkinSideTab(recruiterTab)
    local tabIcon = recruiterTab:CreateTexture(nil, "ARTWORK")
    tabIcon:SetTexture("Interface\\Icons\\INV_Misc_GroupLooking")
    tabIcon:SetAllPoints()
    NS.CB_CropIcon(tabIcon)
    if NS.ElvUI_S and tabIcon.SetInside then tabIcon:SetInside() end
    -- Replaces the template's default OnEnter, which does GameTooltip:SetText(self.tooltip) and
    -- errors when self.tooltip is unset (the template expects the spellbook to assign it).
    NS.CB_SetTooltip(recruiterTab, "Recruit a Bot",
        "Pick a role and class to summon a level-matched bot into your party.")
    recruiterTab:Hide()

    panel = NS.CB_CreatePanel(UIParent, "CleanBotRecruiterPanel", 1, "panel")
    panel:SetFrameStrata("HIGH")
    panel:SetSize(PANEL_W, PANEL_H)
    panel:SetPoint("TOPLEFT", recruiterTab, "TOPRIGHT", PANEL_X, PANEL_Y)
    panel:EnableMouse(true)
    panel:Hide()

    -- Inner content width (wall to wall) and the equal button width that fills a row of n buttons.
    -- The CSS spacing model means a row of n equal buttons fills the inner span exactly when each is
    -- innerW/n minus its own left+right margins (the margins become the wall insets + inter-button
    -- gaps). So CB_AnchorBelow (first, anchors to the left wall) + CB_AnchorAhead (rest) spans the row.
    local innerW = PANEL_W - (panel.paddingLeft or 0) - (panel.paddingRight or 0)
    local bm     = NS.MARGIN.button
    local function rowBtnW(n) return math.floor(innerW / n - ((bm.left or 0) + (bm.right or 0))) end

    -- Header.
    local header = NS.CB_CreateHeader(panel, "Recruit a Bot")
    NS.CB_AnchorWall(header, panel, "TOPLEFT")

    -- Role row (three buttons filling the width).
    local roleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    roleLabel:SetText("Role")
    NS.CB_AnchorBelow(roleLabel, header)
    local prevRole
    for _, role in ipairs(ROLE_ORDER) do
        local b = NS.CB_CreateButton(panel, "CleanBotRecruitRole_" .. role, ROLE_LABEL[role],
            rowBtnW(3), ROLE_BTN_H, function() CB_SetRole(role) end)
        roleBtns[role] = b
        if prevRole then NS.CB_AnchorAhead(b, prevRole)
        else             NS.CB_AnchorBelow(b, roleLabel) end
        prevRole = b
    end

    -- Class grid anchor (an invisible marker the grid packs under).
    local classLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    classLabel:SetText("Class")
    NS.CB_AnchorBelow(classLabel, roleBtns[ROLE_ORDER[1]])
    panel.classAnchor = CreateFrame("Frame", "CleanBotRecruiterClassAnchor", panel)
    panel.classAnchor:SetSize(1, 1)
    panel.classAnchor:SetPoint("TOPLEFT", classLabel, "BOTTOMLEFT", 0, -ROW_GAP)
    for _, class in ipairs(CLASS_ORDER) do CB_MakeClassButton(class) end

    -- Gender row — anchored a fixed two icon-rows below the class anchor (the grid is at most 2 rows).
    local genderLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    genderLabel:SetText("Gender")
    genderLabel:SetPoint("TOPLEFT", panel.classAnchor, "TOPLEFT",
        0, -(2 * (ICON + ICON_GAP) + ROW_GAP))
    local prevGen
    for _, gender in ipairs(GENDER_ORDER) do
        local b = NS.CB_CreateButton(panel, "CleanBotRecruitGender_" .. gender, GENDER_LABEL[gender],
            rowBtnW(3), GEN_BTN_H, function() CB_SetGender(gender) end)
        genderBtns[gender] = b
        if prevGen then NS.CB_AnchorAhead(b, prevGen)
        else            NS.CB_AnchorBelow(b, genderLabel) end
        prevGen = b
    end

    -- Recruit button (full width) + status line.
    recruitBtn = NS.CB_CreateButton(panel, "CleanBotRecruitBtn", "Recruit", rowBtnW(1), RECRUIT_H, CB_DoRecruit)
    NS.CB_AnchorBelow(recruitBtn, genderBtns[GENDER_ORDER[1]])
    recruitBtn:Disable()

    statusFS = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    NS.CB_AnchorBelow(statusFS, recruitBtn)
    statusFS:SetPoint("RIGHT", panel, "RIGHT", -(panel.paddingRight or 8), 0)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetText("")

    -- Default selections: DPS role + Any gender (a sensible starting state).
    CB_SetGender("ANY")

    -- Tab toggles the panel.
    recruiterTab:SetScript("OnClick", function(self)
        if panel:IsShown() then panel:Hide() else panel:Show() end
        self:SetChecked(panel:IsShown())
    end)

    -- Show/hide the tab with the Dungeon Finder window (LFD has no show/close event).
    LFDParentFrame:HookScript("OnShow", function()
        if NS.recruiterEnabled then recruiterTab:Show() end
    end)
    LFDParentFrame:HookScript("OnHide", function()
        recruiterTab:Hide()
        panel:Hide()
        recruiterTab:SetChecked(false)
    end)
end

--- Shows/hides the tab to match the current enabled state (called from the Settings toggle).
--- When disabled, the tab and panel are hidden; when enabled, the tab reappears if the
--- Dungeon Finder is open.
NS.CB_RefreshRecruiter = function()
    if not built then return end
    if NS.recruiterEnabled and LFDParentFrame and LFDParentFrame:IsShown() then
        recruiterTab:Show()
    else
        recruiterTab:Hide()
        panel:Hide()
        recruiterTab:SetChecked(false)
    end
end

-- ── Event handler ────────────────────────────────────────────────────────────
local eventFrame = CreateFrame("Frame", "CleanBotRecruiterEventFrame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")

eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        if not built then
            built = true
            CB_BuildPanel()
        end
        return
    end
    if not built then return end
    -- PARTY_MEMBERS_CHANGED / RAID_ROSTER_UPDATE: a recruited bot may have just joined.
    CB_OnRosterChanged()
end)
