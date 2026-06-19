-- ============================================================
-- spec/overhear_appliers_spec.lua  —  Overhear.lua appliers, driven through the
-- NS.CB_DispatchOverheard seam. Verifies the cached-entry mutations + the events
-- they fire (BOT_STATE_CHANGED via a stubbed CB_UpdateTabData; BOT_INVENTORY_DIRTY
-- via a real subscription). The OnEvent listener + group iteration are in-game only.
-- ============================================================
if not CleanBotNS.CB_Emit          then dofile("Events.lua") end
if not CleanBotNS.STRATEGY_MAP     then dofile("Individual/Strategies.lua") end
if not CleanBotNS.SPEC_DPS_TOKEN   then dofile("Individual/ClassData.lua") end
CleanBotNS.FORMATIONS = CleanBotNS.FORMATIONS or { { token = "arrow" }, { token = "chaos" } }
if not CleanBotNS.CB_DispatchOverheard then dofile("Overhear.lua") end
local NS = CleanBotNS

-- Capture BOT_INVENTORY_DIRTY emits. Same upvalue is reassigned in before_each (the handler
-- reads it live), so each test sees only its own emits.
local dirty = {}
NS.CB_On(NS.EV.BOT_INVENTORY_DIRTY, function(key) dirty[#dirty + 1] = key end)

describe("Overhear appliers", function()
    local updateCalls

    before_each(function()
        _G.CleanBot_PartyBots = {}
        updateCalls = {}
        dirty = {}
        -- Stub the per-bot emit point (real one lives in the UI-only Individual.lua).
        NS.CB_UpdateTabData = function(key, changed)
            updateCalls[#updateCalls + 1] = { key = key, changed = changed }
        end
    end)

    -- Stages an entry under key "bot" and returns it.
    local function mkBot(combat, nonCombat)
        local e = { name = "Bot", class = "MAGE", combat = combat or {}, nonCombat = nonCombat or {} }
        CleanBot_PartyBots["bot"] = e
        return e
    end

    describe("combat / non-combat deltas", function()
        it("'+passive' sets passive without clobbering a sibling", function()
            local e = mkBot({ focusFire = true })
            NS.CB_DispatchOverheard("bot", "combat", "co", "+passive")
            assert.is_true(e.combat.passive)
            assert.is_true(e.combat.focusFire)        -- sibling untouched
            assert.equals(1, #updateCalls)
            assert.equals("bot", updateCalls[1].key)
            assert.is_true(updateCalls[1].changed.combat)
        end)

        it("'-passive' clears the field", function()
            local e = mkBot({ passive = true })
            NS.CB_DispatchOverheard("bot", "combat", "co", "-passive")
            assert.is_false(e.combat.passive)
        end)

        it("'~passive' toggles both directions against the cache", function()
            local e = mkBot({ passive = false })
            NS.CB_DispatchOverheard("bot", "combat", "co", "~passive")
            assert.is_true(e.combat.passive)
            NS.CB_DispatchOverheard("bot", "combat", "co", "~passive")
            assert.is_false(e.combat.passive)
        end)

        it("'!' resets the combat section to defaults", function()
            local e = mkBot({ passive = true })
            NS.CB_DispatchOverheard("bot", "combat", "co", "!")
            assert.is_true(not e.combat.passive)      -- pre-set field cleared by the reset
            assert.equals(1, #updateCalls)
        end)

        it("nc deltas touch nonCombat only", function()
            local e = mkBot({ passive = true }, {})
            NS.CB_DispatchOverheard("bot", "noncombat", "nc", "+loot")
            assert.is_true(e.nonCombat.autoLoot)      -- NC_STRATEGY_MAP loot -> autoLoot
            assert.is_true(e.combat.passive)          -- combat untouched
        end)

        it("an unknown token is a no-op (no mutation, no emit)", function()
            local e = mkBot({})
            NS.CB_DispatchOverheard("bot", "combat", "co", "+bogustoken")
            assert.is_nil(e.combat.bogustoken)
            assert.equals(0, #updateCalls)
        end)

        it("a missing entry is a safe no-op", function()
            NS.CB_DispatchOverheard("ghost", "combat", "co", "+passive")
            assert.equals(0, #updateCalls)
        end)
    end)

    describe("formation / loot", function()
        it("sets a valid formation and emits", function()
            local e = mkBot({})
            NS.CB_DispatchOverheard("bot", "formation", "formation", "arrow")
            assert.equals("arrow", e.formation)
            assert.is_true(updateCalls[1].changed.formation)
        end)

        it("ignores an invalid formation (no mutation, no emit)", function()
            local e = mkBot({}); e.formation = "chaos"
            NS.CB_DispatchOverheard("bot", "formation", "formation", "bogus")
            assert.equals("chaos", e.formation)
            assert.equals(0, #updateCalls)
        end)

        it("sets a valid loot value and emits", function()
            local e = mkBot({})
            NS.CB_DispatchOverheard("bot", "loot", "ll", "gray")
            assert.equals("gray", e.lootStrategy)
            assert.is_true(updateCalls[1].changed.loot)
        end)

        it("ignores an invalid loot value", function()
            local e = mkBot({})
            NS.CB_DispatchOverheard("bot", "loot", "ll", "bogus")
            assert.is_nil(e.lootStrategy)
            assert.equals(0, #updateCalls)
        end)
    end)

    describe("reset", function()
        it("resets combat/non-combat to defaults and formation/loot to their defaults", function()
            local e = mkBot({ passive = true, focusFire = true }, { loot = false })
            e.formation = "arrow"; e.lootStrategy = "gray"
            NS.CB_DispatchOverheard("bot", "reset", "reset", "botAI")
            assert.same(NS.CB_DefaultCombat(),    e.combat)
            assert.same(NS.CB_DefaultNonCombat(), e.nonCombat)
            assert.equals("chaos",  e.formation)
            assert.equals("normal", e.lootStrategy)
            assert.is_true(updateCalls[1].changed.combat)
            assert.is_true(updateCalls[1].changed.formation)
        end)
    end)

    describe("inventory", function()
        it("fires BOT_INVENTORY_DIRTY once for the bot", function()
            mkBot({})
            NS.CB_DispatchOverheard("bot", "inventory", "s", "gray")
            assert.equals(1, #dirty)
            assert.equals("bot", dirty[1])
        end)

        it("does not fire for a missing entry", function()
            NS.CB_DispatchOverheard("ghost", "inventory", "s", "gray")
            assert.equals(0, #dirty)
        end)
    end)
end)
