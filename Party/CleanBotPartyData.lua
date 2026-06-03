-- ============================================================
-- CleanBotPartyData.lua  —  strategy definitions, parsers,
--                            bot detection, class icon coords
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
            { cmd = "tank",       field = "isTank",   name = "Tank",   desc = "Use threat-generating abilities" },
            { cmd = "dps assist", field = "isDPS",    name = "DPS",    desc = "Use DPS abilities" },
            { cmd = "heal",       field = "isHealer", name = "Healer", desc = "Focus on party healing" },
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
            { cmd = "wait for attack time", field = "waitAttackTime", name = "Attack Delay",
              type = "timerDropdown", values = {1, 3, 5, 10}, dependsOn = "waitAttack",
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
    for _, grp in ipairs(NS.STRATEGIES) do
        for _, s in ipairs(grp.strategies) do
            NS.STRATEGY_MAP[s.cmd] = s.field
            local t = groupToTable[grp.group]
            if t then t[#t + 1] = s end
        end
        if grp.subGroups then
            for _, sg in ipairs(grp.subGroups) do
                for _, s in ipairs(sg.strategies) do
                    NS.STRATEGY_MAP[s.cmd] = s.field
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

NS.CB_DefaultNonCombat = function()
    local t = {}
    for _, grp in ipairs(NS.NC_STRATEGIES) do
        for _, s in ipairs(grp.strategies) do t[s.field] = nil end
    end
    return t
end

-- ============================================================
-- String helpers
-- ============================================================
NS.CB_SplitOnce = function(str, sep)
    local i = strfind(str, sep, 1, true)
    if i then return strsub(str, 1, i - 1), strsub(str, i + 1) end
    return str, ""
end

-- Parse a comma-separated strategy reply into a { field = bool } table.
-- `map` is token(cmd) -> field. Every field present in `map` is seeded
-- false, then any token found in the message (after an optional "Label: "
-- prefix) flips its field true.
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
NS.CB_ParseCombatStr = function(msg)
    return CB_ParseTokens(msg, NS.STRATEGY_MAP)
end

-- Parse a bot whisper response to "nc ?".
NS.CB_ParseNonCombatStr = function(msg)
    return CB_ParseTokens(msg, NS.NC_STRATEGY_MAP)
end

-- ============================================================
-- Class-specific data helpers
-- (NS.CLASS_STRATEGIES is defined in CleanBotClassData.lua, which loads after
--  this file. These helpers are only called at event time, so the forward
--  reference resolves before first use.)
-- ============================================================

-- Returns a fresh classData table for a given class.
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
NS.CB_ParseClassStr = function(msg, class, section)
    local cs = NS.CLASS_STRATEGIES and NS.CLASS_STRATEGIES[class]
    if not cs or not cs[section] then return {} end

    local map = {}
    for _, group in ipairs(cs[section]) do
        for _, s in ipairs(group.strategies) do
            map[s.cmd] = s.field
        end
    end
    return CB_ParseTokens(msg, map)
end

-- ============================================================
-- Bot detection
-- ============================================================
NS.CleanBot_IsBot = function(unit)
    local name = UnitName(unit)
    if not name then return false end
    if CleanBot_PartyBots[strlower(name)] then return true end
    return false
end

-- ============================================================
-- Strategy storage helpers (shared by bridge GET~STATES and
-- the no-bridge co?/nc? whisper read paths)
-- ============================================================

-- Returns the party unit id ("partyN") whose name matches, or nil.
NS.CB_FindPartyUnit = function(name)
    for i = 1, GetNumPartyMembers() do
        local unit = "party" .. i
        if UnitName(unit) == name then return unit end
    end
    return nil
end

-- Resolves a bot's class token from the live party roster (authoritative),
-- falling back to the supplied value (or WARRIOR) when the unit isn't found.
NS.CB_ResolveClass = function(name, fallback)
    local unit = NS.CB_FindPartyUnit(name)
    if unit then
        local _, class = UnitClass(unit)
        if class then return class end
    end
    return fallback or "WARRIOR"
end

-- Parses a combat strategy string into entry.combat + entry.classData.combat.
NS.CB_StoreCombat = function(entry, combatStr)
    if not entry then return end
    entry.combat = NS.CB_ParseCombatStr(combatStr)
    if not entry.classData then entry.classData = NS.CB_DefaultClassData(entry.class) end
    entry.classData.combat = NS.CB_ParseClassStr(combatStr, entry.class, "combat")
end

-- Parses a non-combat strategy string into entry.nonCombat + entry.classData.nonCombat.
NS.CB_StoreNonCombat = function(entry, ncStr)
    if not entry then return end
    entry.nonCombat = NS.CB_ParseNonCombatStr(ncStr)
    if not entry.classData then entry.classData = NS.CB_DefaultClassData(entry.class) end
    entry.classData.nonCombat = NS.CB_ParseClassStr(ncStr, entry.class, "nonCombat")
end

-- ============================================================
-- Class icon texture coordinates
-- ============================================================
NS.CLASS_ICON_COORDS = {
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
