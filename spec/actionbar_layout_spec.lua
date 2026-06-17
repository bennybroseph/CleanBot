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

describe("ActionBar CB_MoveToVisibleIndex", function()
    local none = function() return false end
    it("moves among all-enabled entries by visible position", function()
        assert.same({ "a", "b", "c", "d" }, NS.CB_MoveToVisibleIndex({ "a", "b", "c", "d" }, none, "a", 1))
        assert.same({ "b", "a", "c", "d" }, NS.CB_MoveToVisibleIndex({ "a", "b", "c", "d" }, none, "a", 2))
        assert.same({ "b", "c", "a", "d" }, NS.CB_MoveToVisibleIndex({ "a", "b", "c", "d" }, none, "a", 3))
        assert.same({ "b", "c", "d", "a" }, NS.CB_MoveToVisibleIndex({ "a", "b", "c", "d" }, none, "a", 4))
    end)

    it("clamps past the end to last", function()
        assert.same({ "b", "c", "d", "a" }, NS.CB_MoveToVisibleIndex({ "a", "b", "c", "d" }, none, "a", 99))
    end)

    it("counts only ENABLED entries for the visible position (disabled keep their spot)", function()
        local cOff = function(x) return x == "c" end   -- c hidden; visible order is a, b, d
        -- move "a" to visible position 2 → lands before the 2nd enabled (d), i.e. after the hidden c
        assert.same({ "b", "c", "a", "d" }, NS.CB_MoveToVisibleIndex({ "a", "b", "c", "d" }, cOff, "a", 2))
        -- move "d" to visible position 1 → before the 1st enabled (a)
        assert.same({ "d", "a", "b", "c" }, NS.CB_MoveToVisibleIndex({ "a", "b", "c", "d" }, cOff, "d", 1))
    end)
end)

describe("ActionBar CB_ScoreFlyoutDir (flyout direction priority)", function()
    local SW, SH = 1000, 800

    it("prefers an on-screen rect over one that hangs off the edge", function()
        local onScreen = NS.CB_ScoreFlyoutDir(100, 100, 200, 200, {}, SW, SH)
        local offRight = NS.CB_ScoreFlyoutDir(950, 100, 1100, 200, {}, SW, SH)  -- 100px past the right edge
        assert.is_true(onScreen > offRight)
    end)

    it("prefers a rect that doesn't overlap an avoid rect (the bar / parent flyout)", function()
        local avoid   = { { 100, 100, 300, 300 } }
        local clear   = NS.CB_ScoreFlyoutDir(500, 100, 600, 200, avoid, SW, SH)  -- no overlap
        local covered = NS.CB_ScoreFlyoutDir(150, 150, 250, 250, avoid, SW, SH)  -- inside the avoid rect
        assert.is_true(clear > covered)
    end)

    it("breaks ties toward the screen center", function()
        -- Both on-screen and non-overlapping; the one centered on the screen wins.
        local nearCenter = NS.CB_ScoreFlyoutDir(450, 350, 550, 450, {}, SW, SH)  -- center ≈ (500,400)
        local nearEdge   = NS.CB_ScoreFlyoutDir(10, 10, 110, 110, {}, SW, SH)
        assert.is_true(nearCenter > nearEdge)
    end)

    it("ranks off-screen worse than overlap worse than center (full ordering)", function()
        local centered  = NS.CB_ScoreFlyoutDir(450, 350, 550, 450, { { 0, 0, 10, 10 } }, SW, SH)  -- clear, centered
        local overlapped = NS.CB_ScoreFlyoutDir(450, 350, 550, 450, { { 400, 300, 600, 500 } }, SW, SH) -- big overlap
        local offscreen  = NS.CB_ScoreFlyoutDir(-200, 350, -100, 450, {}, SW, SH)                  -- fully off-screen
        assert.is_true(centered > overlapped)
        assert.is_true(overlapped > offscreen)
    end)
end)
