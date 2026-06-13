-- ============================================================
-- spec/strategies_spec.lua  —  Strategies.lua pure-logic: the derived token map
-- and default-state builder, including the inline DPS "Rotation" dropdown bundle
-- (its nested aoe/focus options must still map and seed like ordinary strategies).
-- ============================================================
if not CleanBotNS.STRATEGY_MAP then dofile("Individual/Strategies.lua") end
local NS = CleanBotNS

describe("Strategy token map", function()
    it("maps the bundled DPS rotation tokens to their fields", function()
        assert.equals("aoeTarget", NS.STRATEGY_MAP["aoe"])    -- AoE Rotation
        assert.equals("focusFire", NS.STRATEGY_MAP["focus"])  -- Focus Fire (renamed from lowThreatCast)
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
end)
