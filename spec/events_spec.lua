-- ============================================================
-- spec/events_spec.lua  —  Events.lua pure-logic: the pub/sub bus.
-- Each test uses a unique ad-hoc event name; subscriptions persist for the
-- process (the bus has no global reset), so distinct names keep tests isolated.
-- ============================================================
if not CleanBotNS.CB_Emit then dofile("Events.lua") end
local NS = CleanBotNS

describe("Event bus", function()
    it("delivers the emit args to a subscriber", function()
        local got
        NS.CB_On("ev_args", function(a, b) got = { a, b } end)
        NS.CB_Emit("ev_args", 1, "x")
        assert.same({ 1, "x" }, got)
    end)

    it("delivers to every subscriber", function()
        local n = 0
        NS.CB_On("ev_multi", function() n = n + 1 end)
        NS.CB_On("ev_multi", function() n = n + 1 end)
        NS.CB_Emit("ev_multi")
        assert.equals(2, n)
    end)

    it("emit with no subscribers is a no-op", function()
        NS.CB_Emit("ev_unsubscribed", 1, 2, 3)  -- must not error
        assert.is_true(true)
    end)

    it("CB_Off(token) removes exactly one subscription", function()
        local n = 0
        local tok = NS.CB_On("ev_offtok", function() n = n + 1 end)
        NS.CB_On("ev_offtok", function() n = n + 1 end)
        NS.CB_Off(tok)
        NS.CB_Emit("ev_offtok")
        assert.equals(1, n)
    end)

    it("CB_Off(event, fn) removes by pair", function()
        local n = 0
        local fn = function() n = n + 1 end
        NS.CB_On("ev_offpair", fn)
        NS.CB_On("ev_offpair", function() n = n + 1 end)
        NS.CB_Off("ev_offpair", fn)
        NS.CB_Emit("ev_offpair")
        assert.equals(1, n)
    end)

    it("a subscriber that Offs another mid-dispatch doesn't corrupt the loop", function()
        local calls = 0
        local tokB
        NS.CB_On("ev_mut", function() calls = calls + 1; NS.CB_Off(tokB) end)
        tokB = NS.CB_On("ev_mut", function() calls = calls + 1 end)
        NS.CB_On("ev_mut", function() calls = calls + 1 end)
        NS.CB_Emit("ev_mut")          -- snapshot → all 3 fire this round, no error
        assert.equals(3, calls)
        calls = 0
        NS.CB_Emit("ev_mut")          -- B was removed → 2 remain
        assert.equals(2, calls)
    end)

    it("a throwing subscriber doesn't block the others", function()
        local ran = false
        NS.CB_On("ev_throw", function() error("boom") end)
        NS.CB_On("ev_throw", function() ran = true end)
        NS.CB_Emit("ev_throw")
        assert.is_true(ran)
    end)

    it("exposes canonical event names via NS.EV", function()
        assert.equals("BOT_STATE_CHANGED", NS.EV.BOT_STATE_CHANGED)
        assert.is_not_nil(NS.EV.BOT_INVENTORY_DIRTY)
        assert.is_not_nil(NS.EV.LAYOUT_CHANGED)
    end)
end)
