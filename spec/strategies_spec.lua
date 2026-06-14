-- ============================================================
-- spec/strategies_spec.lua  —  Strategies.lua pure-logic: the derived token map
-- and default-state builder, including the inline DPS "Rotation" dropdown bundle
-- (its nested aoe/focus options must still map and seed like ordinary strategies).
-- ============================================================
if not CleanBotNS.STRATEGY_MAP then dofile("Individual/Strategies.lua") end
if not CleanBotNS.SPEC_DPS_TOKEN then dofile("Individual/ClassData.lua") end
local NS = CleanBotNS

describe("Strategy token map", function()
    it("maps the bundled DPS rotation tokens to their fields", function()
        assert.equals("aoeTarget", NS.STRATEGY_MAP["aoe"])    -- AoE Rotation
        assert.equals("focusFire", NS.STRATEGY_MAP["focus"])  -- Focus Fire (renamed from lowThreatCast)
    end)

    it("maps the rotation Role tokens (assist split out)", function()
        assert.equals("isTank",   NS.STRATEGY_MAP["tank"])
        assert.equals("isHealer", NS.STRATEGY_MAP["heal"])
        assert.equals("offheal",  NS.STRATEGY_MAP["offheal"])  -- Paladin role + Druid checkbox share the field
        -- spec-alias rotation tokens (cmdByClass) resolve to the same role field
        assert.equals("isTank",   NS.STRATEGY_MAP["bear"])
        assert.equals("isTank",   NS.STRATEGY_MAP["blood"])
        assert.equals("isHealer", NS.STRATEGY_MAP["resto"])
    end)

    it("maps the Assist Target tokens to their own (renamed) fields", function()
        assert.equals("assistSingle", NS.STRATEGY_MAP["dps assist"])
        assert.equals("assistAoe",    NS.STRATEGY_MAP["dps aoe"])
        assert.equals("assistTank",   NS.STRATEGY_MAP["tank assist"])
    end)

    it("still maps a plain top-level Combat Control token", function()
        assert.equals("useCooldowns", NS.STRATEGY_MAP["boost"])
    end)

    it("maps the multi-word 'cast time' token (Smart Cast Time)", function()
        assert.equals("castTime", NS.STRATEGY_MAP["cast time"])
    end)

    it("maps the combat positioning + aggression tokens", function()
        assert.equals("posClose",   NS.STRATEGY_MAP["close"])    -- Positioning Mode dropdown
        assert.equals("posRanged",  NS.STRATEGY_MAP["ranged"])
        assert.equals("kite",       NS.STRATEGY_MAP["kite"])
        assert.equals("aggressive", NS.STRATEGY_MAP["aggressive"])
        assert.equals("passive",    NS.STRATEGY_MAP["passive"])
    end)
end)

describe("Non-combat strategy map", function()
    it("maps real nc tokens but skips a settingDropdown group's command options", function()
        assert.equals("autoLoot",   NS.NC_STRATEGY_MAP["loot"])   -- normal nc strategy
        assert.equals("autoGather", NS.NC_STRATEGY_MAP["gather"])
        -- The Loot Quality settingDropdown carries `options` (ll command values), not nc tokens,
        -- so none of its values leak into the map (and the build doesn't choke on a nil cmd).
        assert.is_nil(NS.NC_STRATEGY_MAP["normal"])
        assert.is_nil(NS.NC_STRATEGY_MAP["disenchant"])
    end)
end)

describe("Combat strategy defaults", function()
    it("seeds unconditional defaults and skips the dropdown bundle", function()
        local t = NS.CB_DefaultCombat()
        assert.is_true(t.usePotions)
        assert.is_true(t.useRacials)
        assert.is_true(t.useCooldowns)
        assert.is_true(t.castTime)
        -- aoe/focus are spec-gated, not unconditional → off until the co? reply.
        assert.is_nil(t.aoeTarget)
        assert.is_nil(t.focusFire)
    end)

    it("leaves role + assist + offheal off (spec/reply-driven, no unconditional default)", function()
        local t = NS.CB_DefaultCombat()
        assert.is_nil(t.isTank)
        assert.is_nil(t.isHealer)
        assert.is_nil(t.offheal)
        assert.is_nil(t.assistSingle)
        assert.is_nil(t.assistAoe)
        assert.is_nil(t.assistTank)
        assert.is_nil(t.avoidAggro)  -- none/DPS sub-section leaf still maps but seeds off
    end)
end)

describe("Detected-spec DPS rotation (Role 'DPS' restore)", function()
    it("returns the matching rotation token for a damage spec", function()
        assert.equals("fury", NS.CB_DetectedDpsToken({ class = "WARRIOR",  classData = { combat = { fury       = true } } }))
        assert.equals("dps",  NS.CB_DetectedDpsToken({ class = "PALADIN",  classData = { combat = { retPve     = true } } }))
        assert.equals("balance", NS.CB_DetectedDpsToken({ class = "DRUID", classData = { combat = { balancePve = true } } }))
        assert.equals("unholy", NS.CB_DetectedDpsToken({ class = "DEATHKNIGHT", classData = { combat = { unholyPvp = true } } }))
    end)

    it("returns nil for a tank/heal spec, an unmapped class, or missing data", function()
        assert.is_nil(NS.CB_DetectedDpsToken({ class = "PALADIN", classData = { combat = { protPve = true } } }))  -- tank spec
        assert.is_nil(NS.CB_DetectedDpsToken({ class = "DRUID",   classData = { combat = { restoPve = true } } })) -- heal spec
        assert.is_nil(NS.CB_DetectedDpsToken({ class = "MAGE",    classData = { combat = { firePve  = true } } })) -- pure DPS, never loses rotation
        assert.is_nil(NS.CB_DetectedDpsToken({ class = "WARRIOR", classData = { combat = {} } }))                  -- no spec detected yet
        assert.is_nil(NS.CB_DetectedDpsToken(nil))
    end)
end)
