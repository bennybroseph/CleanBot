-- ============================================================
-- ClassData.lua  —  class display names and class-specific
--                            strategy definitions
--
-- NS.CLASS_STRATEGIES[CLASS] = {
--     combat    = { { header, strategies = { {cmd, field, name, desc} } } },
--     nonCombat = { { header, strategies = { ... } } },
-- }
--
-- Groups with type="dropdown" and whisper="talents spec" send
-- "talents spec {cmd}" on selection instead of co +/-.
-- All other groups send "co +/-cmd" or "nc +/-cmd" whispers.
-- ============================================================
local NS = CleanBotNS

NS.CLASS_DISPLAY = {
    WARRIOR     = "Warrior",
    MAGE        = "Mage",
    ROGUE       = "Rogue",
    DRUID       = "Druid",
    HUNTER      = "Hunter",
    SHAMAN      = "Shaman",
    PRIEST      = "Priest",
    WARLOCK     = "Warlock",
    PALADIN     = "Paladin",
    DEATHKNIGHT = "Death Knight",
}

-- Class icon texture coordinates {left, right, top, bottom} into the standard
-- class-icon atlas. Used to set per-class tab/button icons.
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

-- "|T...|t" markup for a class icon, sized to sit inline with dropdown/menu text
-- (the closed-button value and each open entry). Reuses NS.CB_InlineIcon, defined
-- in Widgets.lua which loads first; called only at event time so order is fine.
---@param class string   Class token (e.g. "WARRIOR").
---@param size  number?  Icon size in pixels (default 14).
---@return string        The inline-icon string, or "" for an unknown class.
NS.CB_ClassIconMarkup = function(class, size)
    local c = NS.CLASS_ICON_COORDS[class]
    if not c then return "" end
    return NS.CB_InlineIcon("Interface\\WorldStateFrame\\Icons-Classes", size or 14, c, 256)
end

NS.CLASS_STRATEGIES = {

    -- ──────────────────────────────────────────────────────────
    WARRIOR = {
        combat = {
            {
                header  = "Talent Spec",
                type    = "dropdown",
                whisper = "talents spec",
                strategies = {
                    { cmd = "arms pve", field = "armsPvE", name = "Arms (PvE)",
                      desc = "Arms spec — two-handed weapon mastery and Mortal Strike (PvE)" },
                    { cmd = "fury pve", field = "fury",    name = "Fury (PvE)",
                      desc = "Fury spec — dual-wield berserker DPS with Whirlwind (PvE)" },
                    { cmd = "prot pve", field = "protPvE", name = "Protection (PvE)",
                      desc = "Protection spec — Shield Slam / Devastate tanking" },
                    { cmd = "arms pvp", field = "armsPvP", name = "Arms (PvP)",
                      desc = "Arms spec — Mortal Strike / Hamstring pressure for PvP" },
                    { cmd = "fury pvp", field = "furyPvP", name = "Fury (PvP)",
                      desc = "Fury spec — dual-wield burst rotation for PvP" },
                    { cmd = "prot pvp", field = "protPvP", name = "Protection (PvP)",
                      desc = "Protection spec — defensive PvP with Shield Slam and spell reflect" },
                },
            },
        },
    },

    -- ──────────────────────────────────────────────────────────
    PALADIN = {
        combat = {
            {
                header  = "Talent Spec",
                type    = "dropdown",
                whisper = "talents spec",
                strategies = {
                    { cmd = "holy pve", field = "holyPve", name = "Holy (PvE)",
                      desc = "Holy healing spec — Flash Heal, Holy Light, Beacon of Light" },
                    { cmd = "prot pve", field = "protPve", name = "Protection (PvE)",
                      desc = "Protection tank spec — Consecration, Shield of Righteousness" },
                    { cmd = "ret pve",  field = "retPve",  name = "Retribution (PvE)",
                      desc = "Retribution DPS spec — Crusader Strike, Divine Storm" },
                    { cmd = "holy pvp", field = "holyPvp", name = "Holy (PvP)",
                      desc = "Holy PvP — Aura Mastery and emergency heals" },
                    { cmd = "prot pvp", field = "protPvp", name = "Protection (PvP)",
                      desc = "Protection PvP — defensive pressure with Avenger's Shield" },
                    { cmd = "ret pvp",  field = "retPvp",  name = "Retribution (PvP)",
                      desc = "Retribution PvP — burst with Hammer of Justice and Divine Storm" },
                },
            },
            {
                header = "Auras (Combat)",
                type   = "dropdown",
                strategies = {
                    { cmd = "barmor",  field = "barmor",  name = "Devotion Aura",
                      desc = "Emit Devotion Aura — increases armor of nearby party members" },
                    { cmd = "baoe",    field = "baoe",    name = "Retribution Aura",
                      desc = "Emit Retribution Aura — deals Holy damage to attackers" },
                    { cmd = "bcast",   field = "bcast",   name = "Concentration Aura",
                      desc = "Emit Concentration Aura — reduces spell pushback for casters" },
                    { cmd = "bspeed",  field = "bspeed",  name = "Crusader Aura",
                      desc = "Emit Crusader Aura — increases mounted speed" },
                    { cmd = "rfire",   field = "rfire",   name = "Fire Resist Aura",
                      desc = "Emit Fire Resistance Aura" },
                    { cmd = "rfrost",  field = "rfrost",  name = "Frost Resist Aura",
                      desc = "Emit Frost Resistance Aura" },
                    { cmd = "rshadow", field = "rshadow", name = "Shadow Resist Aura",
                      desc = "Emit Shadow Resistance Aura" },
                },
            },
            {
                header    = "Blessings (Combat)",
                type      = "dropdown",
                noneLabel = "None",   -- clears all blessings (no upkeep — saves mana)
                noneDesc  = "Maintain no blessing — saves mana",
                strategies = {
                    { cmd = "bmight",  field = "bmight",  name = "Blessing of Might",
                      desc = "Apply Blessing of Might to party members" },
                    { cmd = "bwisdom", field = "bwisdom", name = "Blessing of Wisdom",
                      desc = "Apply Blessing of Wisdom to party members" },
                    { cmd = "bkings",  field = "bkings",  name = "Blessing of Kings",
                      desc = "Apply Blessing of Kings to party members" },
                    { cmd = "bsanc",   field = "bsanc",   name = "Blessing of Sanctuary",
                      desc = "Apply Blessing of Sanctuary to party members" },
                },
            },
        },
        nonCombat = {
            {
                header = "Auras (Out of Combat)",
                type   = "dropdown",
                strategies = {
                    { cmd = "barmor",  field = "barmor",  name = "Devotion Aura",
                      desc = "Emit Devotion Aura — increases armor of nearby party members" },
                    { cmd = "baoe",    field = "baoe",    name = "Retribution Aura",
                      desc = "Emit Retribution Aura — deals Holy damage to attackers" },
                    { cmd = "bcast",   field = "bcast",   name = "Concentration Aura",
                      desc = "Emit Concentration Aura — reduces spell pushback for casters" },
                    { cmd = "bspeed",  field = "bspeed",  name = "Crusader Aura",
                      desc = "Emit Crusader Aura — increases mounted speed" },
                    { cmd = "rfire",   field = "rfire",   name = "Fire Resist Aura",
                      desc = "Emit Fire Resistance Aura" },
                    { cmd = "rfrost",  field = "rfrost",  name = "Frost Resist Aura",
                      desc = "Emit Frost Resistance Aura" },
                    { cmd = "rshadow", field = "rshadow", name = "Shadow Resist Aura",
                      desc = "Emit Shadow Resistance Aura" },
                },
            },
            {
                -- Paladins maintain blessings in BOTH states (the nc list is where the
                -- default blessing lives — AiFactory::AddDefaultNonCombatStrategies).
                -- "None" clears all blessings so the bot stops spending mana on upkeep.
                header    = "Blessings (Out of Combat)",
                type      = "dropdown",
                noneLabel = "None",
                noneDesc  = "Maintain no blessing — saves mana",
                strategies = {
                    { cmd = "bmight",  field = "bmight",  name = "Blessing of Might",
                      desc = "Apply Blessing of Might to party members" },
                    { cmd = "bwisdom", field = "bwisdom", name = "Blessing of Wisdom",
                      desc = "Apply Blessing of Wisdom to party members" },
                    { cmd = "bkings",  field = "bkings",  name = "Blessing of Kings",
                      desc = "Apply Blessing of Kings to party members" },
                    { cmd = "bsanc",   field = "bsanc",   name = "Blessing of Sanctuary",
                      desc = "Apply Blessing of Sanctuary to party members" },
                },
            },
        },
    },

    -- ──────────────────────────────────────────────────────────
    HUNTER = {
        combat = {
            {
                header  = "Talent Spec",
                type    = "dropdown",
                whisper = "talents spec",
                strategies = {
                    { cmd = "bm pve",   field = "bmPve",   name = "Beast Mastery (PvE)",
                      desc = "Beast Mastery spec — pet-focused DPS (PvE)" },
                    { cmd = "mm pve",   field = "mmPve",   name = "Marksmanship (PvE)",
                      desc = "Marksmanship spec — ranged weapon DPS (PvE)" },
                    { cmd = "surv pve", field = "survPve", name = "Survival (PvE)",
                      desc = "Survival spec — trap and shot combo DPS (PvE)" },
                    { cmd = "bm pvp",   field = "bmPvp",   name = "Beast Mastery (PvP)",
                      desc = "Beast Mastery spec — pet pressure for PvP" },
                    { cmd = "mm pvp",   field = "mmPvp",   name = "Marksmanship (PvP)",
                      desc = "Marksmanship spec — burst shots for PvP" },
                    { cmd = "surv pvp", field = "survPvp", name = "Survival (PvP)",
                      desc = "Survival spec — traps and kiting for PvP" },
                },
            },
            {
                header = "Other",
                strategies = {
                    { cmd = "trap weave", field = "trapWeave", name = "Trap Weaving",
                      desc = "Weave Explosive Trap into the rotation by kiting mobs" },
                },
            },
        },
        nonCombat = {
            {
                header = "Aspects",
                strategies = {
                    { cmd = "bdps",    field = "bdps",    name = "Aspect of the Hawk",
                      desc = "Maintain Aspect of the Hawk for maximum ranged attack power" },
                    -- Aspect of the Viper omitted: mod-playerbots' Hunter registers no
                    -- strategy token for it (only bdps/bspeed/rnature) — Viper swapping is
                    -- handled automatically by the bot's mana logic, not toggleable here.
                    { cmd = "bspeed",  field = "bspeed",  name = "Aspect of the Pack",
                      desc = "Maintain Aspect of the Pack/Cheetah for movement speed" },
                    { cmd = "rnature", field = "rnature", name = "Aspect of the Wild",
                      desc = "Maintain Aspect of the Wild for nature resistance" },
                },
            },
        },
    },

    -- ──────────────────────────────────────────────────────────
    ROGUE = {
        combat = {
            {
                header  = "Talent Spec",
                type    = "dropdown",
                whisper = "talents spec",
                strategies = {
                    { cmd = "as pve",        field = "asPve",        name = "Assassination (PvE)",
                      desc = "Assassination spec — Mutilate and poison finishers (PvE)" },
                    { cmd = "combat pve",    field = "combatPve",    name = "Combat (PvE)",
                      desc = "Combat spec — Sinister Strike and Killing Spree (PvE)" },
                    { cmd = "subtlety pve",  field = "subtletyPve",  name = "Subtlety (PvE)",
                      desc = "Subtlety spec — Hemorrhage and Premeditation (PvE)" },
                    { cmd = "as pvp",        field = "asPvp",        name = "Assassination (PvP)",
                      desc = "Assassination spec — Mutilate opener burst for PvP" },
                    { cmd = "combat pvp",    field = "combatPvp",    name = "Combat (PvP)",
                      desc = "Combat spec — sustained pressure for PvP" },
                    { cmd = "subtlety pvp",  field = "subtletyPvp",  name = "Subtlety (PvP)",
                      desc = "Subtlety spec — Shadowstep ambush for PvP" },
                },
            },
            {
                header = "Stealth",
                strategies = {
                    { cmd = "stealth",   field = "stealth",   name = "Maintain Stealth",
                      desc = "Attempt to stay in stealth and use stealth openers" },
                    { cmd = "stealthed", field = "stealthed", name = "Stealth Rotation",
                      desc = "Use abilities that require or benefit from stealth (Ambush, Garrote)" },
                },
            },
        },
    },

    -- ──────────────────────────────────────────────────────────
    PRIEST = {
        combat = {
            {
                header  = "Talent Spec",
                type    = "dropdown",
                whisper = "talents spec",
                strategies = {
                    { cmd = "disc pve",   field = "discPve",   name = "Discipline (PvE)",
                      desc = "Discipline healing spec — Power Word: Shield and Penance (PvE)" },
                    { cmd = "holy pve",   field = "holyPve",   name = "Holy (PvE)",
                      desc = "Holy healing spec — Circle of Healing and Prayer of Healing (PvE)" },
                    { cmd = "shadow pve", field = "shadowPve", name = "Shadow (PvE)",
                      desc = "Shadow DPS spec — Mind Blast, Mind Flay, SW: Pain (PvE)" },
                    { cmd = "disc pvp",   field = "discPvp",   name = "Discipline (PvP)",
                      desc = "Discipline PvP — Penance burst and Psychic Scream" },
                    { cmd = "holy pvp",   field = "holyPvp",   name = "Holy (PvP)",
                      desc = "Holy PvP — Surge of Light and Holy Nova pressure" },
                    { cmd = "shadow pvp", field = "shadowPvp", name = "Shadow (PvP)",
                      desc = "Shadow PvP — Silence and Dispersion burst windows" },
                },
            },
        },
        nonCombat = {
            {
                header = "Other",
                strategies = {
                    { cmd = "rshadow", field = "rshadow", name = "Shadow Protection",
                      desc = "Apply Prayer of Shadow Protection to all party members" },
                },
            },
        },
    },

    -- ──────────────────────────────────────────────────────────
    DEATHKNIGHT = {
        combat = {
            {
                header  = "Talent Spec",
                type    = "dropdown",
                whisper = "talents spec",
                strategies = {
                    { cmd = "blood pve",            field = "bloodPve",           name = "Blood (PvE)",
                      desc = "Blood DPS spec — Death Strike and Heart Strike (PvE)" },
                    { cmd = "frost pve",            field = "frostPve",           name = "Frost (PvE)",
                      desc = "Frost DPS spec — Obliterate and Howling Blast (PvE)" },
                    { cmd = "unholy pve",           field = "unholyPve",          name = "Unholy (PvE)",
                      desc = "Unholy DPS spec — Scourge Strike and Army of the Dead (PvE)" },
                    { cmd = "double aura blood pve", field = "doubleAuraBloodPve", name = "Dbl Aura Blood (PvE)",
                      desc = "Blood tank with both Improved Icy Talons and Abomination's Might auras" },
                    { cmd = "blood pvp",            field = "bloodPvp",           name = "Blood (PvP)",
                      desc = "Blood PvP — self-healing pressure via Death Strike" },
                    { cmd = "frost pvp",            field = "frostPvp",           name = "Frost (PvP)",
                      desc = "Frost PvP — Hungering Cold and burst with Obliterate" },
                    { cmd = "unholy pvp",           field = "unholyPvp",          name = "Unholy (PvP)",
                      desc = "Unholy PvP — Ghoul synergy and Desecration snare" },
                },
            },
            {
                header = "Specialization",
                type = "dropdown",
                strategies = {
                    { cmd = "blood",  field = "blood",  name = "Blood",
                      desc = "Blood Specialization — improved damage and life-steal" },
                    { cmd = "frost",  field = "frost",  name = "Frost",
                      desc = "Frost Specialization — improved threat and damage reduction (tanking)" },
                    { cmd = "unholy", field = "unholy", name = "Unholy",
                      desc = "Unholy Specialization — increased attack speed and movement" },
                },
            },
            {
                header = "AoE Rotation",
                type = "dropdown",
                strategies = {
                    { cmd = "frost aoe",  field = "frostAoe",  name = "Frost AoE",
                      desc = "Frost AoE rotation using Howling Blast and Frost Strike" },
                    { cmd = "unholy aoe", field = "unholyAoe", name = "Unholy AoE",
                      desc = "Unholy AoE rotation using Death and Decay and Pestilence" },
                },
            },
        },
    },

    -- ──────────────────────────────────────────────────────────
    SHAMAN = {
        combat = {
             {
                header  = "Talent Spec",
                type    = "dropdown",
                whisper = "talents spec",
                strategies = {
                    { cmd = "ele pve",   field = "elePve",   name = "Elemental (PvE)",
                      desc = "Elemental spec — Lightning Bolt and Chain Lightning (PvE)" },
                    { cmd = "enh pve",   field = "enhPve",   name = "Enhancement (PvE)",
                      desc = "Enhancement spec — Stormstrike and windfury procs (PvE)" },
                    { cmd = "resto pve", field = "restoPve", name = "Restoration (PvE)",
                      desc = "Restoration spec — Chain Heal and Earth Shield (PvE)" },
                    { cmd = "ele pvp",   field = "elePvp",   name = "Elemental (PvP)",
                      desc = "Elemental PvP — Thunderstorm and burst Lightning" },
                    { cmd = "enh pvp",   field = "enhPvp",   name = "Enhancement (PvP)",
                      desc = "Enhancement PvP — Feral Spirit and Lava Lash burst" },
                    { cmd = "resto pvp", field = "restoPvp", name = "Restoration (PvP)",
                      desc = "Restoration PvP — Earth Shield and Hex support" },
                },
            },
            {
                header   = "Strategy",
                type     = "dropdown",
                readonly = true,
                strategies = {
                    { cmd = "ele",   field = "ele",   name = "Elemental",
                      desc = "Elemental spec — Lightning Bolt and Chain Lightning" },
                    { cmd = "enh",   field = "enh",   name = "Enhancement",
                      desc = "Enhancement spec — Stormstrike and Windfury procs" },
                    { cmd = "resto", field = "resto", name = "Restoration",
                      desc = "Restoration spec — Chain Heal and Earth Shield" },
                },
            },
            {
                header = "Earth Totem",
                type   = "dropdown",
                strategies = {
                    { cmd = "strength of earth", field = "strengthOfEarth", name = "Strength of Earth",
                      desc = "Drop Strength of Earth Totem — increases Strength and Agility" },
                    { cmd = "stoneskin",         field = "stoneskin",        name = "Stoneskin",
                      desc = "Drop Stoneskin Totem — reduces melee damage taken by party" },
                    { cmd = "tremor",            field = "tremor",           name = "Tremor",
                      desc = "Drop Tremor Totem — pulses to remove Fear, Charm, Sleep" },
                    { cmd = "earthbind",         field = "earthbind",        name = "Earthbind",
                      desc = "Drop Earthbind Totem — slows nearby enemies" },
                },
            },
            {
                header = "Fire Totem",
                type   = "dropdown",
                strategies = {
                    { cmd = "searing",     field = "searing",     name = "Searing",
                      desc = "Drop Searing Totem — attacks a nearby enemy" },
                    { cmd = "magma",       field = "magma",       name = "Magma",
                      desc = "Drop Magma Totem — deals AoE fire damage around itself" },
                    { cmd = "flametongue", field = "flametongue", name = "Flametongue",
                      desc = "Drop Flametongue Totem — increases spell damage for the party" },
                    { cmd = "wrath",       field = "wrath",       name = "Totem of Wrath",
                      desc = "Drop Totem of Wrath — increases spell hit and crit for the party" },
                },
            },
            {
                header = "Water Totem",
                type   = "dropdown",
                strategies = {
                    { cmd = "healing stream", field = "healingStream", name = "Healing Stream",
                      desc = "Drop Healing Stream Totem — periodically heals party members" },
                    { cmd = "mana spring",    field = "manaSpring",    name = "Mana Spring",
                      desc = "Drop Mana Spring Totem — restores mana to party members" },
                    { cmd = "cleansing",      field = "cleansing",     name = "Cleansing",
                      desc = "Drop Cleansing Totem — pulses to remove poison and disease" },
                },
            },
            {
                header = "Air Totem",
                type   = "dropdown",
                strategies = {
                    { cmd = "wrath of air", field = "wrathOfAir", name = "Wrath of Air",
                      desc = "Drop Wrath of Air Totem — increases spell haste for the party" },
                    { cmd = "windfury",     field = "windfury",   name = "Windfury",
                      desc = "Drop Windfury Totem — grants melee party members extra attacks" },
                    { cmd = "grounding",    field = "grounding",  name = "Grounding",
                      desc = "Drop Grounding Totem — absorbs the next hostile spell" },
                },
            },
        },
    },

    -- ──────────────────────────────────────────────────────────
    MAGE = {
        combat = {
            {
                header  = "Talent Spec",
                type    = "dropdown",
                whisper = "talents spec",
                strategies = {
                    { cmd = "arcane pve",   field = "arcanePve",   name = "Arcane (PvE)",
                      desc = "Arcane spec — Arcane Blast and Arcane Missiles (PvE)" },
                    { cmd = "fire pve",     field = "firePve",     name = "Fire (PvE)",
                      desc = "Fire spec — Fireball and Pyroblast (PvE)" },
                    { cmd = "frost pve",    field = "frostPve",    name = "Frost (PvE)",
                      desc = "Frost spec — Frostbolt and Ice Lance (PvE)" },
                    { cmd = "frostfire pve", field = "frostfirePve", name = "Frostfire (PvE)",
                      desc = "Frostfire spec — Frostfire Bolt rotation (PvE)" },
                    { cmd = "arcane pvp",   field = "arcanePvp",   name = "Arcane (PvP)",
                      desc = "Arcane PvP — Slow and Arcane Barrage burst" },
                    { cmd = "fire pvp",     field = "firePvp",     name = "Fire (PvP)",
                      desc = "Fire PvP — Combustion and Pyroblast burst" },
                    { cmd = "frost pvp",    field = "frostPvp",    name = "Frost (PvP)",
                      desc = "Frost PvP — Deep Freeze and Shatter combos" },
                },
            },
            {
                header = "Spell School",
                type = "dropdown",
                strategies = {
                    { cmd = "frost",         field = "frost",       name = "Frost",
                      desc = "Frost single-target rotation (Frostbolt, Ice Lance)" },
                    { cmd = "fire",          field = "fire",        name = "Fire",
                      desc = "Fire single-target rotation (Fireball, Pyroblast)" },
                },
            },
            {
                header = "Other",
                strategies = {
                    { cmd = "firestarter",   field = "firestarter", name = "Firestarter",
                      desc = "Melee-range strategy which utilizes the instant cast Flamestrike from the Firestarter talent" },
                },
            },
        },
    },

    -- ──────────────────────────────────────────────────────────
    WARLOCK = {
        combat = {
            {
                header  = "Talent Spec",
                type    = "dropdown",
                whisper = "talents spec",
                strategies = {
                    { cmd = "affli pve",  field = "affliPve",  name = "Affliction (PvE)",
                      desc = "Affliction spec — DoT-focused damage (Corruption, Curse of Agony, UA) (PvE)" },
                    { cmd = "demo pve",   field = "demoPve",   name = "Demonology (PvE)",
                      desc = "Demonology spec — pet-empowered DPS with Immolate and Shadowbolt (PvE)" },
                    { cmd = "destro pve", field = "destroPve", name = "Destruction (PvE)",
                      desc = "Destruction spec — burst DPS with Shadowbolt and Conflagrate (PvE)" },
                    { cmd = "affli pvp",  field = "affliPvp",  name = "Affliction (PvP)",
                      desc = "Affliction PvP — DoT pressure and Fear into Haunt" },
                    { cmd = "demo pvp",   field = "demoPvp",   name = "Demonology (PvP)",
                      desc = "Demonology PvP — Metamorphosis burst windows" },
                    { cmd = "destro pvp", field = "destroPvp", name = "Destruction (PvP)",
                      desc = "Destruction PvP — Chaos Bolt and Conflagrate burst" },
                },
            },
            {
                header = "Other",
                strategies = {
                    { cmd = "meta melee", field = "metaMelee", name = "Metamorphosis Melee",
                      desc = "Metamorphosis melee mode — DPS in Demon Form at close range" },
                },
            },
        },
        nonCombat = {
            {
                header = "Active Pet",
                type   = "dropdown",
                strategies = {
                    { cmd = "imp",        field = "imp",        name = "Imp",
                      desc = "Keep Imp summoned (Fire Bolt, Blood Pact)" },
                    { cmd = "voidwalker", field = "voidwalker", name = "Voidwalker",
                      desc = "Keep Voidwalker summoned (tanking/absorb pet)" },
                    { cmd = "succubus",   field = "succubus",   name = "Succubus",
                      desc = "Keep Succubus summoned (Seduction CC, melee DPS)" },
                    { cmd = "felhunter",  field = "felhunter",  name = "Felhunter",
                      desc = "Keep Felhunter summoned (spell interrupt, magic dispel)" },
                    { cmd = "felguard",   field = "felguard",   name = "Felguard",
                      desc = "Keep Felguard summoned (Demonology mastery pet)" },
                },
            },
            {
                header = "Soulstone",
                type   = "dropdown",
                strategies = {
                    { cmd = "ss self",   field = "ssSelf",   name = "Use on Self",
                      desc = "Keep a Soulstone on self for self-resurrection" },
                    { cmd = "ss master", field = "ssMaster", name = "Use on Master",
                      desc = "Keep a Soulstone on the party leader" },
                    { cmd = "ss tank",   field = "ssTank",   name = "Use on Tank",
                      desc = "Keep a Soulstone on the party tank" },
                    { cmd = "ss healer", field = "ssHealer", name = "Use on Healer",
                      desc = "Keep a Soulstone on the party healer" },
                },
            },
            {
                header = "Weapon Stone",
                type   = "dropdown",
                strategies = {
                    { cmd = "spellstone", field = "spellstone", name = "Spellstone",
                      desc = "Equip a Spellstone for increased spell critical strike chance" },
                    { cmd = "firestone",  field = "firestone",  name = "Firestone",
                      desc = "Equip a Firestone for increased fire spell damage" },
                },
            },
        },
    },

    -- ──────────────────────────────────────────────────────────
    DRUID = {
        combat = {
            {
                header  = "Talent Spec",
                type    = "dropdown",
                whisper = "talents spec",
                strategies = {
                    { cmd = "balance pve", field = "balancePve", name = "Balance (PvE)",
                      desc = "Balance spec — Wrath and Starfire in Moonkin form (PvE)" },
                    { cmd = "bear pve",    field = "bearPve",    name = "Guardian (PvE)",
                      desc = "Feral tank spec — Swipe, Mangle, and Lacerate in Bear form (PvE)" },
                    { cmd = "resto pve",   field = "restoPve",   name = "Restoration (PvE)",
                      desc = "Restoration spec — Rejuvenation and Lifebloom (PvE)" },
                    { cmd = "cat pve",     field = "catPve",     name = "Feral (PvE)",
                      desc = "Feral DPS spec — combo-point finishers in Cat form (PvE)" },
                    { cmd = "balance pvp", field = "balancePvp", name = "Balance (PvP)",
                      desc = "Balance PvP — Typhoon and Force of Nature burst" },
                    { cmd = "cat pvp",     field = "catPvp",     name = "Feral (PvP)",
                      desc = "Feral PvP — Pounce opener and Savage Roar pressure" },
                    { cmd = "resto pvp",   field = "restoPvp",   name = "Restoration (PvP)",
                      desc = "Restoration PvP — Cyclone and Entangling Roots support" },
                },
            },
            {
                header   = "Strategy",
                type     = "dropdown",
                readonly = true,
                strategies = {
                    -- These are the bot's actual reported combat-strategy tokens
                    -- (BearDruidStrategy:getName() == "bear", etc.), not the generic
                    -- melee/caster/heal roles — druid never registers those, so the
                    -- read-only display could never match the co? reply.
                    { cmd = "bear",    field = "bear",    name = "Guardian (Bear)",
                      desc = "Active strategy set by the bot's talents — Feral tank in Bear Form" },
                    { cmd = "cat",     field = "cat",     name = "Feral (Cat)",
                      desc = "Active strategy set by the bot's talents — Feral DPS in Cat Form" },
                    { cmd = "balance", field = "balance", name = "Balance (Moonkin)",
                      desc = "Active strategy set by the bot's talents — Balance caster" },
                    { cmd = "resto",   field = "resto",   name = "Restoration",
                      desc = "Active strategy set by the bot's talents — Restoration healer" },
                },
            },
            -- Off-Heal (independent add-on; Druid registers it in the non-sibling general
            -- context) is exposed in the generic Role group's DPS sub-section instead — it
            -- reads more naturally next to Avoid Aggro than alone in a class group.
        },
    },

}

-- ============================================================
-- Detected-spec DPS rotation tokens
--
-- When the user picks the "DPS" Role, the engine has already dropped the spec's damage
-- rotation (a sibling of tank/heal), so clearing tank/heal alone leaves the bot with no
-- rotation. We re-add the rotation that matches the bot's DETECTED talent spec — preserving
-- intent (a Fury warrior gets Fury back, a Balance druid gets Balance back) — by mapping the
-- spec field CB_SyncTalentSpec wrote into classData.combat to the rotation token to send.
--
-- Only classes whose Role dropdown offers Tank or Heal appear here: only they can leave DPS
-- and lose the rotation (pure-DPS classes never set a non-DPS role). Tank/heal spec fields are
-- intentionally absent — picking DPS on them falls back to the Role group's dpsCmdByClass.
-- ============================================================
NS.SPEC_DPS_TOKEN = {
    WARRIOR     = { armsPvE = "arms", armsPvP = "arms", fury = "fury", furyPvP = "fury" },
    PALADIN     = { retPve = "dps", retPvp = "dps" },
    PRIEST      = { shadowPve = "dps", shadowPvp = "dps" },
    SHAMAN      = { elePve = "ele", elePvp = "ele", enhPve = "enh", enhPvp = "enh" },
    WARLOCK     = { affliPve = "affli", affliPvp = "affli", demoPve = "demo", demoPvp = "demo",
                    destroPve = "destro", destroPvp = "destro" },
    DRUID       = { balancePve = "balance", balancePvp = "balance", catPve = "cat", catPvp = "cat" },
    DEATHKNIGHT = { frostPve = "frost", frostPvp = "frost", unholyPve = "unholy", unholyPvp = "unholy" },
}

-- The DPS rotation token for a bot's detected talent spec, or nil if its spec isn't a
-- damage spec / isn't known yet (no inspect). Reads the spec field CB_SyncTalentSpec stamped
-- into entry.classData.combat (stable across role toggles, unlike the live co? rotation).
---@param entry table?  CleanBot_PartyBots[key].
---@return string?       Rotation token to re-add (e.g. "fury", "balance", "dps"), or nil.
NS.CB_DetectedDpsToken = function(entry)
    if not (entry and entry.class) then return nil end
    local map = NS.SPEC_DPS_TOKEN[entry.class]
    local src = entry.classData and entry.classData.combat
    if not (map and src) then return nil end
    for field, token in pairs(map) do
        if src[field] == true then return token end
    end
    return nil
end
