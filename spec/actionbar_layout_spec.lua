-- ============================================================
-- spec/actionbar_layout_spec.lua  —  ActionBar.lua pure layout helpers:
-- order reconciliation (CB_MergeOrder) and reorder (CB_MoveInOrder). The bar itself is built only on
-- PLAYER_ENTERING_WORLD (in-game), so loading the file just defines these helpers.
-- ============================================================
local _onEventN = #Mock.onEvent
if not CleanBotNS.CB_MergeOrder then dofile("ActionBar.lua") end
-- ActionBar's loader registers a PLAYER_ENTERING_WORLD handler; Mock.fireEvent fans out to ALL captured
-- handlers regardless of event name, so drop whatever ActionBar registered to keep it inert here and in
-- any spec that fires events later.
while #Mock.onEvent > _onEventN do table.remove(Mock.onEvent) end
local NS = CleanBotNS

describe("ActionBar CB_MergeOrder", function()
    it("returns the defaults when nothing is saved", function()
        assert.same({ "a", "b", "c" }, NS.CB_MergeOrder({ "a", "b", "c" }, nil))
        assert.same({ "a", "b", "c" }, NS.CB_MergeOrder({ "a", "b", "c" }, {}))
    end)

    it("respects a full saved order", function()
        assert.same({ "c", "a", "b" }, NS.CB_MergeOrder({ "a", "b", "c" }, { "c", "a", "b" }))
    end)

    it("drops unknown saved ids and appends new defaults (in default order)", function()
        -- "x" is unknown (dropped); "c" is a new default not in the save (appended).
        assert.same({ "b", "a", "c" }, NS.CB_MergeOrder({ "a", "b", "c" }, { "b", "x", "a" }))
    end)

    it("appends defaults missing from a partial saved order", function()
        assert.same({ "a", "b", "c", "d" }, NS.CB_MergeOrder({ "a", "b", "c", "d" }, { "a", "b" }))
    end)

    it("ignores duplicate saved ids", function()
        assert.same({ "a", "b", "c" }, NS.CB_MergeOrder({ "a", "b", "c" }, { "a", "a", "b" }))
    end)
end)

describe("ActionBar CB_MoveInOrder", function()
    it("moves an id to the front", function()
        assert.same({ "c", "a", "b" }, NS.CB_MoveInOrder({ "a", "b", "c" }, "c", 1))
    end)

    it("moves an id to the middle", function()
        assert.same({ "a", "c", "b" }, NS.CB_MoveInOrder({ "a", "b", "c" }, "c", 2))
    end)

    it("moves an id to the end", function()
        assert.same({ "b", "c", "a" }, NS.CB_MoveInOrder({ "a", "b", "c" }, "a", 3))
    end)

    it("clamps an out-of-range index to the ends", function()
        assert.same({ "b", "c", "a" }, NS.CB_MoveInOrder({ "a", "b", "c" }, "a", 99))
        assert.same({ "a", "b", "c" }, NS.CB_MoveInOrder({ "a", "b", "c" }, "a", 1))
    end)
end)
