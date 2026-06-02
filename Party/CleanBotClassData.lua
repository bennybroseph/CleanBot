-- ============================================================
-- CleanBotClassData.lua  —  class display names and class-specific
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

NS.CLASS_STRATEGIES = {

    -- ──────────────────────────────────────────────────────────
    WARRIOR = {
        combat = {
            {
                header  = "Spec",
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
                header  = "Spec",
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
                header = "Blessings",
                type   = "dropdown",
                strategies = {
                    { cmd = "bdps",    field = "bdps",    name = "Blessing of Might",
                      desc = "Apply Blessing of Might to party members" },
                    { cmd = "bmana",   field = "bmana",   name = "Blessing of Wisdom",
                      desc = "Apply Blessing of Wisdom to party members" },
                    { cmd = "bstats",  field = "bstats",  name = "Blessing of Kings",
                      desc = "Apply Blessing of Kings to party members" },
                    { cmd = "bhealth", field = "bhealth", name = "Blessing of Sanctuary",
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
        },
    },

    -- ──────────────────────────────────────────────────────────
    HUNTER = {
        combat = {
            {
                header  = "Spec",
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
                    { cmd = "bmana",   field = "bmana",   name = "Aspect of the Viper",
                      desc = "Maintain Aspect of the Viper for mana regeneration" },
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
                header  = "Spec",
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
                header  = "Spec",
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
                header  = "Spec",
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
                header  = "Spec",
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
                header = "Totems (Combat)",
                type   = "dropdown",
                strategies = {
                    { cmd = "bdps",  field = "coStrength",  name = "Strength Totem",
                      desc = "Drop Strength of Earth / Windfury Totem during combat" },
                    { cmd = "bmana", field = "coManaSpring", name = "Mana Spring Totem",
                      desc = "Drop Mana Spring Totem during combat" },
                },
            },
        },
        nonCombat = {
            {
                header = "Totems (Out of Combat)",
                type   = "dropdown",
                strategies = {
                    { cmd = "bdps",  field = "ncStrength",  name = "Strength Totem",
                      desc = "Drop Strength of Earth / Windfury Totem out of combat" },
                    { cmd = "bmana", field = "ncManaSpring", name = "Mana Spring Totem",
                      desc = "Drop Mana Spring Totem out of combat" },
                },
            },
        },
    },

    -- ──────────────────────────────────────────────────────────
    MAGE = {
        combat = {
            {
                header  = "Spec",
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
                header  = "Spec",
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
                header  = "Spec",
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
                    { cmd = "melee",  field = "isMelee",    name = "Melee",
                      desc = "Active strategy set by the bot's talents — Feral melee" },
                    { cmd = "caster", field = "isCaster",   name = "Caster",
                      desc = "Active strategy set by the bot's talents — Balance caster" },
                    { cmd = "heal",   field = "isHealer", name = "Healer",
                      desc = "Active strategy set by the bot's talents — Restoration healer" },
                },
            },
            {
                header = "Support",
                strategies = {
                    { cmd = "offheal", field = "offheal", name = "Off-Heal",
                      desc = "Provide supplemental healing while in a DPS role" },
                },
            },
        },
    },

}
