-- ============================================================
-- spec/layout_spec.lua  —  Skinning/Layout.lua live-relayout core:
-- CB_RestampAll (re-applies margins/padding from NS.MARGIN/NS.PADDING) and the
-- record/replay registry (CB_AnchorBelow/Ahead record; CB_ReplayAnchors re-applies
-- without re-recording). Frame geometry itself is in-game only.
-- ============================================================
if not CleanBotNS.CB_Emit then dofile("Events.lua") end
-- Layout's RestampAll reads these; seed before load (CleanBot.lua isn't loaded in specs).
CleanBotNS.MARGIN  = CleanBotNS.MARGIN  or {}
CleanBotNS.PADDING = CleanBotNS.PADDING or {}
if not CleanBotNS.CB_RestampAll then dofile("Skinning/Layout.lua") end
local NS = CleanBotNS

-- Minimal frame stub that counts SetPoint/ClearAllPoints calls.
local function stub()
    local f = { setpoints = 0, cleared = 0 }
    function f:GetParent()      return f._parent end
    function f:ClearAllPoints() f.cleared = f.cleared + 1 end
    function f:SetPoint()       f.setpoints = f.setpoints + 1 end
    return f
end

local function recordCount()
    local n = 0
    for _ in pairs(NS.CB_layoutRecords) do n = n + 1 end
    return n
end

describe("CB_RestampAll", function()
    it("re-applies margins from NS.MARGIN[_marginType]", function()
        NS.MARGIN.button = { top = 9, bottom = 8, left = 7, right = 6 }
        local w = { _marginType = "button" }
        NS.CB_RegisterStampable(w)
        NS.CB_RestampAll()
        assert.equals(9, w.marginTop)
        assert.equals(8, w.marginBottom)
        assert.equals(7, w.marginLeft)
        assert.equals(6, w.marginRight)
    end)

    it("honors the _marginTopType override (titled slider)", function()
        NS.MARGIN.slider = { top = 2, bottom = 4, left = 4, right = 4 }
        NS.MARGIN.label  = { top = 10, bottom = 2, left = 0, right = 0 }
        local w = { _marginType = "slider", _marginTopType = "label" }
        NS.CB_RegisterStampable(w)
        NS.CB_RestampAll()
        assert.equals(10, w.marginTop)     -- label top overrides
        assert.equals(4,  w.marginBottom)  -- slider bottom kept
    end)

    it("re-applies padding from NS.PADDING[_paddingRole]", function()
        NS.PADDING.panel = { top = 5, bottom = 5, left = 5, right = 5 }
        local f = { _paddingRole = "panel" }
        NS.CB_RegisterStampable(f)
        NS.CB_RestampAll()
        assert.equals(5, f.paddingLeft)
        assert.equals(5, f.paddingTop)
    end)

    it("registers a stampable only once", function()
        local w = { _marginType = "button" }
        NS.CB_RegisterStampable(w)
        NS.CB_RegisterStampable(w)  -- idempotent
        local seen = 0
        for _, x in ipairs(NS.CB_stampables) do if x == w then seen = seen + 1 end end
        assert.equals(1, seen)
    end)
end)

describe("anchor record + replay", function()
    it("records a widget and replays its anchor (re-invokes SetPoint)", function()
        local w = stub(); w._parent = stub()
        local above = stub()
        NS.CB_AnchorBelow(w, above)
        local before = w.setpoints
        NS.CB_ReplayAnchors()
        assert.is_true(w.setpoints > before)
    end)

    it("re-anchoring the same widget updates in place (no duplicate record)", function()
        local w = stub(); w._parent = stub()
        local a, b = stub(), stub()
        NS.CB_AnchorBelow(w, a)
        local c = recordCount()
        NS.CB_AnchorBelow(w, b)        -- same widget, different ref
        assert.equals(c, recordCount())
    end)

    it("replay does not grow the registry (gated re-record)", function()
        local w = stub(); w._parent = stub()
        NS.CB_AnchorAhead(w, stub())
        local c = recordCount()
        NS.CB_ReplayAnchors()
        assert.equals(c, recordCount())
    end)

    it("replay updates points without clearing (preserves extra inline anchors)", function()
        local w = stub(); w._parent = stub()
        NS.CB_AnchorBelow(w, stub())   -- build: clears once, sets TOP+LEFT
        assert.equals(1, w.cleared)
        -- caller adds an extra inline anchor (e.g. RIGHT for width) — modeled as a point that must survive
        NS.CB_ReplayAnchors()
        assert.equals(1, w.cleared)    -- replay must NOT ClearAllPoints (would wipe the inline RIGHT)
    end)

    it("CB_AnchorWall records additively and replays (flow + wall coexist on one widget)", function()
        local parent = stub()
        local w = stub(); w._parent = parent
        NS.CB_AnchorBelow(w, stub())          -- flow slot
        NS.CB_AnchorWall(w, parent, "RIGHT")  -- wall slot — must NOT clear the flow points
        assert.equals(1, w.cleared)           -- AnchorWall doesn't clear
        local sp = w.setpoints
        NS.CB_ReplayAnchors()
        assert.is_true(w.setpoints > sp)      -- both records replayed
        assert.equals(1, w.cleared)           -- replay still doesn't clear
    end)
end)

describe("CB_Anchor closure anchor", function()
    it("runs fn at build and again on replay", function()
        local n = 0
        NS.CB_Anchor(stub(), function() n = n + 1 end)
        assert.equals(1, n)            -- placed now
        NS.CB_ReplayAnchors()
        assert.is_true(n >= 2)         -- re-applied on replay
    end)

    it("dedups on re-anchor of the same widget (no registry growth)", function()
        local w = stub()
        NS.CB_Anchor(w, function() end)
        local c = recordCount()
        NS.CB_Anchor(w, function() end)
        assert.equals(c, recordCount())
    end)

    it("does not re-record during replay", function()
        NS.CB_Anchor(stub(), function() end)
        local c = recordCount()
        NS.CB_ReplayAnchors()
        assert.equals(c, recordCount())
    end)
end)

describe("relayout callbacks + LAYOUT_CHANGED ordering", function()
    it("runs registered relayouts in registration order", function()
        local log = {}
        NS.CB_RegisterRelayout(function() log[#log + 1] = "ra" end)
        NS.CB_RegisterRelayout(function() log[#log + 1] = "rb" end)
        NS.CB_RunRelayouts()
        local ia, ib
        for i, v in ipairs(log) do
            if v == "ra" then ia = i elseif v == "rb" then ib = i end
        end
        assert.is_true(ia ~= nil and ib ~= nil and ia < ib)
    end)

    it("LAYOUT_CHANGED replays + relayouts synchronously, defers GetBottom work", function()
        local log = {}
        NS.CB_Anchor(stub(), function() log[#log + 1] = "replay" end)
        NS.CB_RegisterRelayout(function() log[#log + 1] = "relayout" end)
        NS.CB_RegisterDeferredRelayout(function() log[#log + 1] = "deferred" end)

        NS.CB_Emit(NS.EV.LAYOUT_CHANGED)
        local has = {}
        for _, v in ipairs(log) do has[v] = true end
        assert.is_true(has.replay)           -- closure re-applied
        assert.is_true(has.relayout)         -- relayout ran synchronously
        assert.is_false(has.deferred == true) -- deferred scheduled via CB_After(0), not yet run

        Mock.tick(0)                          -- fire the CB_After(0) timer
        has = {}
        for _, v in ipairs(log) do has[v] = true end
        assert.is_true(has.deferred)
    end)
end)
