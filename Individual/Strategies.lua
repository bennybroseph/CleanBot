-- ============================================================
-- Strategies.lua  —  the combat / non-combat strategy model:
--   definitions, derived lookup tables, default-state builders,
--   whisper-reply parsers, and per-bot storage helpers.
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- Combat strategy definitions  (single source of truth)
--
-- Format mirrors NS.CLASS_STRATEGIES:
--   { header, group, column, [type], strategies = { {cmd, field, name, desc} } }
--
-- column = "left" | "right"  — which panel column the group renders in.
-- type   = "roleDropdown"    — exclusive dropdown whose selection shows one
--   of the subGroups:  { field, header, strategies }
--
-- Derived flat tables (NS.ROLE_STRATEGIES, NS.TANK_STRATEGIES, …) are built
-- automatically below for any callers that still need them.
-- ============================================================
NS.STRATEGIES = {
    {
        header     = "Role",
        group      = "role",
        column     = "left",
        type       = "roleDropdown",
        strategies = {
            -- cmdByClass: classes that implement the role under a different token.
            -- Druid/DK have no literal "tank" rotation token — they tank via their
            -- form/spec strategy (bear / blood). Druid heals via "resto", not "heal".
            { cmd = "tank",       field = "isTank",   name = "Tank",   desc = "Use threat-generating abilities",
              cmdByClass = { DRUID = "bear", DEATHKNIGHT = "blood" } },
            { cmd = "dps assist", field = "isDPS",    name = "DPS",    desc = "Use DPS abilities" },
            { cmd = "heal",       field = "isHealer", name = "Healer", desc = "Focus on party healing",
              cmdByClass = { DRUID = "resto" } },
        },
        subGroups = {
            { field = "isTank",   header = "Tank",    strategies = {
                { cmd = "tank assist", field = "peelAggro",      name = "Peel Aggro",       desc = "Tank pulls mobs off other party members" },
                { cmd = "pull",        field = "pull",           name = "Pull",             desc = "Tank pulls mobs using a ranged skill" },
                { cmd = "pull back",   field = "pullBack",       name = "Pull Back",        desc = "Pull mob then return to starting position" },
                { cmd = "tank face",   field = "faceTargetAway", name = "Face Target Away", desc = "Ensure target does not face ranged players" },
            }},
            { field = "isDPS",    header = "DPS",     strategies = {
                { cmd = "aoe",    field = "aoeTarget",  name = "AoE",         desc = "Target many mobs at a time" },
                { cmd = "threat", field = "avoidAggro", name = "Avoid Aggro", desc = "DPS actively avoids grabbing threat" },
            }},
            { field = "isHealer", header = "Healing", strategies = {
                { cmd = "save mana",  field = "saveMana",  name = "Save Mana",  desc = "Healers prioritize high-efficiency spells" },
                { cmd = "healer dps", field = "healerDps", name = "Healer DPS", desc = "Healers cast damage spells when mana allows" },
            }},
        },
    },
    {
        header = "Combat Control",
        group  = "combat",
        column = "left",
        strategies = {
            { cmd = "cc",        field = "useCC",           name = "Crowd Control",         desc = "Use crowd-control abilities on Raid Target Icon (RTI) Moon" },
            { cmd = "boost",     field = "useCooldowns",    name = "Use Cooldowns",         desc = "Use major cooldowns" },
            { cmd = "focus",     field = "lowThreatCast",   name = "Low Threat Casting",    desc = "Stop casting AoE threat and debuff spells" },
            { cmd = "avoid aoe", field = "avoidAoe",        name = "Avoid AoE",             desc = "Automatically avoid harmful AoE spells" },
        },
    },
    {
        header = "Positioning",
        group  = "position",
        column = "right",
        strategies = {
            { cmd = "behind", field = "stayBehindTarget", name = "Stay Behind Target", desc = "Move to target's back when not behind" },
        },
    },
    {
        header = "Wait to Attack",
        group  = "timing",
        column = "right",
        strategies = {
            { cmd = "wait for attack",      field = "waitAttack",    name = "Enable Wait to Attack", desc = "Wait a set time before attacking or healing" },
            { cmd = "wait for attack time", field = "waitAttackTime", name = "Delay",
              type = "timerSlider", min = 1, max = 10, dependsOn = "waitAttack",
              desc = "Seconds to wait before attacking or healing" },
        },
    },
    {
        header = "Other",
        group  = "other",
        column = "right",
        strategies = {
            { cmd = "mark rti",        field = "markTargets", name = "Mark Targets",   desc = "Automatically mark unmarked combat attackers" },
            { cmd = "grind", field = "grindMobs", name = "Grind Mobs", desc = "Attack any visible target" },
        },
    },
}

-- ============================================================
-- Per-class registration of the gap-prone generic/role tokens.
-- Verified against each src/Ai/Class/<Class>/<Class>AiObjectContext.cpp strategy
-- factory (see docs/playerbot-strategies.md). A token absent from this table is
-- registered by every class (generic StrategyContext) and is always shown. A class
-- that implements a concept under a different token is covered by the strategy's
-- cmdByClass override instead (e.g. druid "heal" → "resto"), not listed here.
-- Sets keyed by class token for O(1) lookup.
-- ============================================================
NS.STRATEGY_CLASS_SUPPORT = {
    ["tank"]       = { WARRIOR=true, PALADIN=true, WARLOCK=true, DRUID=true, DEATHKNIGHT=true },
    ["heal"]       = { PALADIN=true, PRIEST=true, SHAMAN=true },
    ["pull"]       = { WARRIOR=true, PALADIN=true, ROGUE=true, PRIEST=true, MAGE=true, WARLOCK=true, DRUID=true, DEATHKNIGHT=true },
    ["aoe"]        = { WARRIOR=true, HUNTER=true, ROGUE=true, PRIEST=true, SHAMAN=true, MAGE=true, WARLOCK=true, DRUID=true },
    ["healer dps"] = { PALADIN=true, PRIEST=true, SHAMAN=true, DRUID=true },
    ["cc"]         = { PALADIN=true, HUNTER=true, ROGUE=true, PRIEST=true, MAGE=true, WARLOCK=true, DRUID=true },
    ["boost"]      = { PALADIN=true, ROGUE=true, PRIEST=true, SHAMAN=true, MAGE=true, WARLOCK=true, DRUID=true },
}

-- Effective send/parse token for a strategy on a given class: the cmdByClass
-- override when one exists for that class, else the base cmd.
---@param s     table    Strategy definition { cmd, field, [cmdByClass] }.
---@param class string?  Class token (e.g. "DRUID"); nil → base cmd.
---@return string        The token to send / expect in the reply.
NS.CB_EffStrategyCmd = function(s, class)
    return (class and s.cmdByClass and s.cmdByClass[class]) or s.cmd
end

-- Whether a strategy entry should be shown for a class. Shown when: the class has a
-- cmdByClass override (we know which token works), OR the token has no coverage gaps
-- (absent from STRATEGY_CLASS_SUPPORT), OR the class is in the token's support set.
---@param s     table    Strategy definition.
---@param class string?  Class token; nil → always shown.
---@return boolean
NS.CB_StrategyShown = function(s, class)
    if not class then return true end
    if s.cmdByClass and s.cmdByClass[class] then return true end
    local sup = NS.STRATEGY_CLASS_SUPPORT[s.cmd]
    if not sup then return true end
    return sup[class] == true
end

NS.STRATEGY_MAP        = {}
NS.ROLE_STRATEGIES     = {}
NS.TANK_STRATEGIES     = {}
NS.DPS_STRATEGIES      = {}
NS.HEAL_STRATEGIES     = {}
NS.COMBAT_STRATEGIES   = {}
NS.POSITION_STRATEGIES = {}
NS.TIMING_STRATEGIES   = {}
do
    local groupToTable = {
        role     = NS.ROLE_STRATEGIES,
        combat   = NS.COMBAT_STRATEGIES,
        position = NS.POSITION_STRATEGIES,
        timing   = NS.TIMING_STRATEGIES,
    }
    local subFieldToTable = {
        isTank   = NS.TANK_STRATEGIES,
        isDPS    = NS.DPS_STRATEGIES,
        isHealer = NS.HEAL_STRATEGIES,
    }
    -- Map a strategy's base cmd AND every per-class override token to its field, so
    -- the co? reply parser recognizes whichever token a class actually reports
    -- (e.g. a druid healer reports "resto", a DK tank reports "blood").
    local function mapTokens(s)
        NS.STRATEGY_MAP[s.cmd] = s.field
        if s.cmdByClass then
            for _, alt in pairs(s.cmdByClass) do NS.STRATEGY_MAP[alt] = s.field end
        end
    end
    for _, grp in ipairs(NS.STRATEGIES) do
        for _, s in ipairs(grp.strategies) do
            mapTokens(s)
            local t = groupToTable[grp.group]
            if t then t[#t + 1] = s end
        end
        if grp.subGroups then
            for _, sg in ipairs(grp.subGroups) do
                for _, s in ipairs(sg.strategies) do
                    mapTokens(s)
                    local t = subFieldToTable[sg.field]
                    if t then t[#t + 1] = s end
                end
            end
        end
    end
end

-- ============================================================
-- Non-combat strategy definitions
--
-- Same grouped format as NS.STRATEGIES and NS.CLASS_STRATEGIES.
-- NS.NC_GENERAL_STRATEGIES is derived below; the UI uses it directly.
-- ============================================================
NS.NC_STRATEGIES = {
    {
        header = "General",
        group  = "general",
        column = "left",
        strategies = {
            { cmd = "food", field = "useFood",   name = "Eat & Drink", desc = "Automatically eat and drink when low on health or mana" },
            { cmd = "pvp",  field = "enablePVP", name = "Enable PvP",  desc = "Enable PvP mode — bot will flag for PvP and engage enemy players" },
        },
    },
    {
        header = "Loot & Gather",
        group  = "lootGather",
        column = "right",
        strategies = {
            { cmd = "loot",   field = "autoLoot",   name = "Auto Loot",   desc = "Automatically loot nearby corpses after combat" },
            { cmd = "gather", field = "autoGather", name = "Auto Gather", desc = "Automatically gather nearby nodes after combat" },
        },
    },
}

NS.NC_STRATEGY_MAP      = {}
NS.NC_GENERAL_STRATEGIES = {}
do
    local groupToTable = {
        general      = NS.NC_GENERAL_STRATEGIES,
    }
    for _, grp in ipairs(NS.NC_STRATEGIES) do
        for _, s in ipairs(grp.strategies) do
            NS.NC_STRATEGY_MAP[s.cmd] = s.field
            local t = groupToTable[grp.group]
            if t then t[#t + 1] = s end
        end
    end
end

-- ============================================================
-- Default state constructors
-- ============================================================
---@return table  A fresh combat-strategy state table with all flags defaulted.
NS.CB_DefaultCombat = function()
    local t = {}
    for _, grp in ipairs(NS.STRATEGIES) do
        for _, s in ipairs(grp.strategies) do t[s.field] = nil end
        if grp.subGroups then
            for _, sg in ipairs(grp.subGroups) do
                for _, s in ipairs(sg.strategies) do t[s.field] = nil end
            end
        end
    end
    return t
end

---@return table  A fresh non-combat-strategy state table with all flags defaulted.
NS.CB_DefaultNonCombat = function()
    local t = {}
    for _, grp in ipairs(NS.NC_STRATEGIES) do
        for _, s in ipairs(grp.strategies) do t[s.field] = nil end
    end
    return t
end

-- Parse a comma-separated strategy reply into a { field = bool } table.
-- `map` is token(cmd) -> field. Every field present in `map` is seeded
-- false, then any token found in the message (after an optional "Label: "
-- prefix) flips its field true.
---@param msg string  Whisper reply text to scan for strategy tokens.
---@param map table   Token→field lookup; matched fields are set true/false in the result.
local function CB_ParseTokens(msg, map)
    local result = {}
    for _, field in pairs(map) do result[field] = false end
    if not msg or msg == "" then return result end
    local colon = strfind(msg, ":", 1, true)
    local list  = colon and strsub(msg, colon + 1) or msg
    for token in gmatch(list, "[^,]+") do
        token = token:match("^%s*(.-)%s*$")
        local field = map[token]
        if field then result[field] = true end
    end
    return result
end

-- Parse a bot whisper response to "co ?".
---@param msg string  The bot's "co ?" reply text.
---@return table       Combat-strategy state parsed from the reply.
NS.CB_ParseCombatStr = function(msg)
    return CB_ParseTokens(msg, NS.STRATEGY_MAP)
end

-- Parse a bot whisper response to "nc ?".
---@param msg string  The bot's "nc ?" reply text.
---@return table       Non-combat-strategy state parsed from the reply.
NS.CB_ParseNonCombatStr = function(msg)
    return CB_ParseTokens(msg, NS.NC_STRATEGY_MAP)
end

-- ============================================================
-- Class-specific data helpers
-- (NS.CLASS_STRATEGIES is defined in ClassData.lua, which loads after
--  this file. These helpers are only called at event time, so the forward
--  reference resolves before first use.)
-- ============================================================

-- Returns a fresh classData table for a given class.
---@param class string  Class token (e.g. "WARRIOR").
---@return table         Default class-strategy state for that class.
NS.CB_DefaultClassData = function(class)
    local result = { combat = {}, nonCombat = {} }
    local cs = NS.CLASS_STRATEGIES and NS.CLASS_STRATEGIES[class]
    if not cs then return result end
    if cs.combat then
        for _, group in ipairs(cs.combat) do
            for _, s in ipairs(group.strategies) do
                result.combat[s.field] = nil
            end
        end
    end
    if cs.nonCombat then
        for _, group in ipairs(cs.nonCombat) do
            for _, s in ipairs(group.strategies) do
                result.nonCombat[s.field] = nil
            end
        end
    end
    return result
end

-- Parse a co? or nc? response for class-specific strategy tokens.
-- section: "combat" or "nonCombat"
-- Returns { field = bool } for every strategy in that section.
---@param msg     string  The bot's class-strategy reply text.
---@param class   string  Class token (e.g. "WARRIOR").
---@param section string  Which class section the reply belongs to.
---@return table          Class-strategy state parsed from the reply.
NS.CB_ParseClassStr = function(msg, class, section)
    local cs = NS.CLASS_STRATEGIES and NS.CLASS_STRATEGIES[class]
    if not cs or not cs[section] then return {} end

    local map = {}
    for _, group in ipairs(cs[section]) do
        -- Skip whisper groups (talent-spec premades): their cmds are "talents spec"
        -- names that never appear in co?/nc? replies, so including them here would
        -- seed their fields false on every reconcile — stomping the talent dropdown.
        -- Those fields are owned by CB_SyncTalentSpec (inspect-derived) and user clicks.
        if not group.whisper then
            for _, s in ipairs(group.strategies) do
                map[s.cmd] = s.field
            end
        end
    end
    return CB_ParseTokens(msg, map)
end

-- ============================================================
-- Strategy storage helpers (shared by bridge GET~STATES and
-- the no-bridge co?/nc? whisper read paths)
-- ============================================================

-- Dev mismatch check: after an authoritative re-read reconciles the bot's real
-- state, compare the expectations recorded by CB_SendStrategyToggle (the optimistic
-- UI guess) against what actually parsed, and print any divergence. Only runs when
-- /cbdebug verify is on; pops entry.stratExpect[section] either way so it doesn't
-- carry over. Each field may live in the general (entry[section]) or class-specific
-- (entry.classData[section]) table, so check both.
---@param entry   table   The reconciled bot roster entry.
---@param section string  "combat" or "nonCombat".
local function CB_VerifyStrategyExpect(entry, section)
    local expect = entry.stratExpect and entry.stratExpect[section]
    if not expect then return end
    entry.stratExpect[section] = nil
    if not NS.debugVerify then return end

    local general  = entry[section]
    local classSec = entry.classData and entry.classData[section]
    for field, want in pairs(expect) do
        local got = general and general[field]
        if got == nil and classSec then got = classSec[field] end
        if got ~= want then
            NS.CB_Print(string.format("|cffff4444[verify]|r %s  %s.%s: expected %s, got %s",
                entry.name or "?", section, field, tostring(want), tostring(got)))
        end
    end
end

-- Parses a combat strategy string into entry.combat + entry.classData.combat.
---@param entry     table   The bot roster entry to store parsed flags on.
---@param combatStr string  The bot's "co ?" reply text.
NS.CB_StoreCombat = function(entry, combatStr)
    if not entry then return end
    entry.combat = NS.CB_ParseCombatStr(combatStr)
    if not entry.classData then entry.classData = NS.CB_DefaultClassData(entry.class) end
    entry.classData.combat = NS.CB_ParseClassStr(combatStr, entry.class, "combat")
    CB_VerifyStrategyExpect(entry, "combat")
end

-- Parses a non-combat strategy string into entry.nonCombat + entry.classData.nonCombat.
---@param entry table   The bot roster entry to store parsed flags on.
---@param ncStr string  The bot's "nc ?" reply text.
NS.CB_StoreNonCombat = function(entry, ncStr)
    if not entry then return end
    entry.nonCombat = NS.CB_ParseNonCombatStr(ncStr)
    if not entry.classData then entry.classData = NS.CB_DefaultClassData(entry.class) end
    entry.classData.nonCombat = NS.CB_ParseClassStr(ncStr, entry.class, "nonCombat")
    CB_VerifyStrategyExpect(entry, "nonCombat")
end
