-- ============================================================
-- CleanBotPartyData.lua  —  strategy definitions, parsers,
--                            bot detection, class icon coords
-- ============================================================
local NS = CleanBotNS

-- ============================================================
-- Combat strategy definitions  (single source of truth)
-- ============================================================
NS.STRATEGIES = {
    -- Role
    { cmd = "tank",       field = "isTank",         name = "Tank",              group = "role",     desc = "Use threat-generating abilities" },
    { cmd = "dps assist", field = "isDPS",           name = "DPS",               group = "role",     desc = "Use DPS abilities" },
    { cmd = "heal",       field = "isHealer",        name = "Healer",            group = "role",     desc = "Focus on party healing" },
    -- Tank
    { cmd = "tank assist",    field = "peelAggro",      name = "Tank Assist",       group = "tank",     desc = "Tank pulls mobs off others" },
    { cmd = "pull",           field = "pull",            name = "Pull",              group = "tank",     desc = "Tank pulls mobs using a ranged skill" },
    { cmd = "pull back",      field = "pullBack",        name = "Pull Back",         group = "tank",     desc = "Pull mob then return to starting position" },
    { cmd = "tank face",      field = "faceTargetAway",  name = "Face Target Away",  group = "tank",     desc = "Ensure target does not face ranged players" },
    -- DPS
    { cmd = "aoe",        field = "aoeTarget",       name = "AoE",               group = "dps",      desc = "Target many mobs at a time" },
    { cmd = "threat",     field = "avoidAggro",      name = "Avoid Aggro",       group = "dps",      desc = "DPS actively avoids grabbing threat" },
    -- Healing
    { cmd = "save mana",  field = "saveMana",        name = "Save Mana",         group = "heal",     desc = "Healers prioritize high-efficiency spells" },
    { cmd = "healer dps", field = "healerDps",       name = "Healer DPS",        group = "heal",     desc = "Healers cast damage spells when mana allows" },
    -- Combat Control
    { cmd = "cc",         field = "useCC",           name = "Crowd Control",     group = "combat",   desc = "Use crowd-control abilities on Raid Target Icon (RTI) Moon" },
    { cmd = "boost",      field = "useCooldowns",    name = "Use Cooldowns",     group = "combat",   desc = "Use major cooldowns" },
    { cmd = "focus",      field = "calmCast",        name = "Calm Cast",         group = "combat",   desc = "Stop casting AoE threat and debuff spells" },
    { cmd = "avoid aoe",  field = "avoidAoe",        name = "Avoid AoE",         group = "combat",   desc = "Automatically avoid harmful AoE spells" },
    -- Positioning
    { cmd = "behind",         field = "stayBehindTarget", name = "Stay Behind",   group = "position", desc = "Move to target's back when not behind" },
    -- Timing & Marking
    { cmd = "wait for attack", field = "waitAttack",  name = "Wait to Attack",   group = "timing",   desc = "Wait a set time before attacking or healing" },
    { cmd = "mark rti",        field = "markTargets", name = "Mark Targets",     group = "timing",   desc = "Automatically mark unmarked combat attackers" },
    -- Other
    { cmd = "grind",      field = "grindMobs",       name = "Grind Mobs",        desc = "Attack any visible target" },
}

NS.STRATEGY_MAP = {}
for _, s in ipairs(NS.STRATEGIES) do NS.STRATEGY_MAP[s.cmd] = s.field end

NS.ROLE_STRATEGIES     = {}
NS.TANK_STRATEGIES     = {}
NS.DPS_STRATEGIES      = {}
NS.HEAL_STRATEGIES     = {}
NS.COMBAT_STRATEGIES   = {}
NS.POSITION_STRATEGIES = {}
NS.TIMING_STRATEGIES   = {}
for _, s in ipairs(NS.STRATEGIES) do
    if s.group == "role"     then NS.ROLE_STRATEGIES[#NS.ROLE_STRATEGIES         + 1] = s end
    if s.group == "tank"     then NS.TANK_STRATEGIES[#NS.TANK_STRATEGIES         + 1] = s end
    if s.group == "dps"      then NS.DPS_STRATEGIES[#NS.DPS_STRATEGIES           + 1] = s end
    if s.group == "heal"     then NS.HEAL_STRATEGIES[#NS.HEAL_STRATEGIES         + 1] = s end
    if s.group == "combat"   then NS.COMBAT_STRATEGIES[#NS.COMBAT_STRATEGIES     + 1] = s end
    if s.group == "position" then NS.POSITION_STRATEGIES[#NS.POSITION_STRATEGIES + 1] = s end
    if s.group == "timing"   then NS.TIMING_STRATEGIES[#NS.TIMING_STRATEGIES     + 1] = s end
end

-- ============================================================
-- Non-combat strategy definitions
-- ============================================================
NS.NC_STRATEGIES = {
    { cmd = "food", field = "useFood",  name = "Eat & Drink", group = "general", desc = "Automatically eat and drink when low on health or mana" },
    { cmd = "pvp",  field = "pvpMode",  name = "PvP Mode",    group = "general", desc = "Enable PvP mode — bot will flag for PvP and engage enemy players" },
    { cmd = "loot", field = "autoLoot", name = "Auto Loot",   group = "general", desc = "Automatically loot nearby corpses after combat" },
}
NS.NC_STRATEGY_MAP = {}
for _, s in ipairs(NS.NC_STRATEGIES) do NS.NC_STRATEGY_MAP[s.cmd] = s.field end
NS.NC_GENERAL_STRATEGIES = NS.NC_STRATEGIES

-- ============================================================
-- Default state constructors
-- ============================================================
NS.CB_DefaultCombat = function()
    local t = {}
    for _, s in ipairs(NS.STRATEGIES) do t[s.field] = nil end
    return t
end

NS.CB_DefaultNonCombat = function()
    local t = {}
    for _, s in ipairs(NS.NC_STRATEGIES) do t[s.field] = nil end
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

-- Parse a bot whisper response to "co ?".
-- Skips any "Label: " prefix, then reads comma-separated strategy names.
NS.CB_ParseCombatStr = function(msg)
    local combat = {}
    for _, field in pairs(NS.STRATEGY_MAP) do combat[field] = false end
    if not msg or msg == "" then return combat end
    local colon = strfind(msg, ":", 1, true)
    local list  = colon and strsub(msg, colon + 1) or msg
    for token in gmatch(list, "[^,]+") do
        token = token:match("^%s*(.-)%s*$")
        local field = NS.STRATEGY_MAP[token]
        if field then combat[field] = true end
    end
    return combat
end

-- Parse a bot whisper response to "nc ?".
NS.CB_ParseNonCombatStr = function(msg)
    local nc = {}
    for _, field in pairs(NS.NC_STRATEGY_MAP) do nc[field] = false end
    if not msg or msg == "" then return nc end
    local colon = strfind(msg, ":", 1, true)
    local list  = colon and strsub(msg, colon + 1) or msg
    for token in gmatch(list, "[^,]+") do
        token = token:match("^%s*(.-)%s*$")
        local field = NS.NC_STRATEGY_MAP[token]
        if field then nc[field] = true end
    end
    return nc
end

-- ============================================================
-- Bot detection
-- ============================================================
NS.CleanBot_IsBot = function(unit)
    local name = UnitName(unit)
    if not name then return false end
    if CleanBot_KnownBots[strlower(name)] then return true end
    if NS.ASSUME_ALL_PARTY_ARE_BOTS then return true end
    return false
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
