-- ============================================================
-- spec/overhear_spec.lua  —  Overhear.lua pure logic: operator-aware strategy
-- delta parsing, command classification, token validation, and self-sender match.
-- (The appliers/listener touch live frames + entries and are verified in-game.)
-- ============================================================
if not CleanBotNS.STRATEGY_MAP  then dofile("Individual/Strategies.lua") end
if not CleanBotNS.SPEC_DPS_TOKEN then dofile("Individual/ClassData.lua") end
-- FORMATIONS lives in CommandControls.lua (UI-heavy); stub just the tokens the validator reads.
CleanBotNS.FORMATIONS = CleanBotNS.FORMATIONS or { { token = "arrow" }, { token = "chaos" }, { token = "circle" } }
if not CleanBotNS.CB_ClassifyChatCommand then dofile("Overhear.lua") end
local NS = CleanBotNS

describe("Overhear strategy delta parser", function()
    it("parses a single add as a delta, not a replacement", function()
        local ops, reset = NS.CB_ParseStrategyDelta("+passive")
        assert.same({ passive = "on" }, ops)   -- only the mentioned token; others untouched
        assert.is_false(reset)
    end)

    it("parses mixed +/-/~ operators", function()
        local ops = NS.CB_ParseStrategyDelta("+a,-b,~c")
        assert.same({ a = "on", b = "off", c = "toggle" }, ops)
    end)

    it("flags '!' as a section reset with no token ops", function()
        local ops, reset = NS.CB_ParseStrategyDelta("!")
        assert.same({}, ops)
        assert.is_true(reset)
    end)

    it("ignores a bare '?' query", function()
        local ops, reset = NS.CB_ParseStrategyDelta("?")
        assert.same({}, ops)
        assert.is_false(reset)
    end)

    it("applies ops but ignores a trailing '?' (no-bridge apply+read form)", function()
        local ops = NS.CB_ParseStrategyDelta("+x,?")
        assert.same({ x = "on" }, ops)
    end)

    it("ignores bare/unknown tokens (never guesses a value)", function()
        local ops = NS.CB_ParseStrategyDelta("passive")
        assert.same({}, ops)
    end)
end)

describe("Overhear command classification", function()
    local function k(msg) return (NS.CB_ClassifyChatCommand(msg)) end  -- first return only

    it("classifies co/nc strategy toggles", function()
        local kind, verb, rest = NS.CB_ClassifyChatCommand("co +passive")
        assert.equals("combat", kind); assert.equals("co", verb); assert.equals("+passive", rest)
        assert.equals("noncombat", k("nc -loot"))
    end)

    it("classifies formation and loot commands", function()
        local _, _, frest = NS.CB_ClassifyChatCommand("formation arrow")
        assert.equals("formation", k("formation arrow")); assert.equals("arrow", frest)
        assert.equals("loot", k("ll gray"))
    end)

    it("classifies inventory/vendor/trade verbs with an argument", function()
        assert.equals("inventory", k("e 12345"))
        assert.equals("inventory", k("s gray"))
        assert.equals("inventory", k("bank 12345"))      -- deposit/withdraw form
        assert.equals("inventory", k("outfit raid equip"))
    end)

    it("ignores pure queries and bare item verbs", function()
        assert.is_nil(k("items"))
        assert.is_nil(k("stats"))
        assert.is_nil(k("bank"))            -- bare bank = list query
        assert.is_nil(k("t"))               -- bare item verb = chatter
        assert.is_nil(k("outfit raid"))     -- outfit without equip/replace
        assert.is_nil(k("hello there"))
    end)
end)

describe("Overhear token validation", function()
    it("accepts known formation tokens and rejects others", function()
        assert.is_true(NS.CB_IsFormationToken("arrow"))
        assert.is_false(NS.CB_IsFormationToken("bogus"))
    end)

    it("accepts known loot values and rejects others", function()
        assert.is_true(NS.CB_IsLootValue("gray"))
        assert.is_true(NS.CB_IsLootValue("normal"))
        assert.is_false(NS.CB_IsLootValue("bogus"))
    end)
end)

describe("Overhear self-sender match", function()
    it("matches the player on the same realm", function()
        assert.is_true(NS.CB_IsSelfSender("TestPlayer", "TestPlayer"))
    end)
    it("matches the player cross-realm (realm stripped)", function()
        assert.is_true(NS.CB_IsSelfSender("TestPlayer-Some Realm", "TestPlayer"))
    end)
    it("rejects another sender and nil", function()
        assert.is_false(NS.CB_IsSelfSender("Someone", "TestPlayer"))
        assert.is_false(NS.CB_IsSelfSender(nil, "TestPlayer"))
    end)

    it("matches case-insensitively", function()
        assert.is_true(NS.CB_IsSelfSender("testplayer", "TestPlayer"))
        assert.is_true(NS.CB_IsSelfSender("TESTPLAYER-Some Realm", "testplayer"))
    end)
end)

describe("Overhear edge cases", function()
    local function entry(class, combat) return { class = class, combat = combat } end
    local M = NS.CB_EntryMatchesQualifiers
    local function q(msg) return (NS.CB_ParseQualifiers(msg)) end

    it("EntryMatchesQualifiers fails safe on nil/unknown inputs", function()
        assert.is_false(M(q("@tank x"), nil))                              -- nil entry
        assert.is_false(M(q("@melee x"), entry(nil, {})))                  -- unknown class → ranged nil
        assert.is_false(M(q("@mage x"),  entry(nil, {})))                  -- class mismatch
        assert.is_false(M(q("@70-80 x"), entry("MAGE", {}), nil, 1))       -- nil level
        assert.is_false(M(q("@group2 x"), entry("MAGE", {}), 80, nil))     -- nil subgroup
        assert.is_false(M(q("@tank x"),  entry("MAGE", nil)))             -- nil combat, no error
    end)

    it("ParseQualifiers rejects malformed qualifiers (skip the command)", function()
        assert.is_false((select(3, NS.CB_ParseQualifiers("@group co +passive"))))     -- empty body
        assert.is_false((select(3, NS.CB_ParseQualifiers("@group1-2-3 co +passive")))) -- multi-dash
        assert.is_false((select(3, NS.CB_ParseQualifiers("@70- s gray"))))             -- half range
    end)

    it("ClassifyChatCommand trims whitespace and is verb-case-insensitive", function()
        local kind, _, rest = NS.CB_ClassifyChatCommand("  co +passive  ")
        assert.equals("combat", kind); assert.equals("+passive", rest)
        assert.equals("combat", (NS.CB_ClassifyChatCommand("CO +passive")))
    end)
end)

describe("Overhear qualifier parsing", function()
    local function q(msg) return (NS.CB_ParseQualifiers(msg)) end  -- descriptors only

    it("strips a single qualifier and keeps the remainder", function()
        local d, rest, ok = NS.CB_ParseQualifiers("@tank co +passive")
        assert.is_true(ok); assert.equals("co +passive", rest)
        assert.equals(1, #d); assert.equals("role", d[1].kind); assert.equals("tank", d[1].role)
    end)

    it("chains multiple qualifiers (AND)", function()
        local d, rest = NS.CB_ParseQualifiers("@tank @melee co +passive")
        assert.equals(2, #d); assert.equals("co +passive", rest)
    end)

    it("passes through a message with no qualifier", function()
        local d, rest, ok = NS.CB_ParseQualifiers("co +passive")
        assert.is_true(ok); assert.equals(0, #d); assert.equals("co +passive", rest)
    end)

    it("preserves item-link spaces in the remainder", function()
        local _, rest = NS.CB_ParseQualifiers("@tank t [Some Item]")
        assert.equals("t [Some Item]", rest)
    end)

    it("rejects unsupported/unknown qualifiers (skip the command)", function()
        assert.is_false((select(3, NS.CB_ParseQualifiers("@aura123 co +passive"))))  -- server-only
        assert.is_false((select(3, NS.CB_ParseQualifiers("@arms co +aoe"))))         -- spec
        assert.is_false((select(3, NS.CB_ParseQualifiers("@bogus s gray"))))         -- unknown
    end)

    it("parses level single + range", function()
        local d = q("@70-80 s gray")
        assert.equals("level", d[1].kind); assert.equals(70, d[1].from); assert.equals(80, d[1].to)
        local d2 = q("@80 s gray"); assert.equals(80, d2[1].from); assert.equals(80, d2[1].to)
    end)

    it("parses subgroup lists and ranges", function()
        local d = q("@group1,3 co +passive")
        assert.equals("group", d[1].kind)
        assert.is_true(d[1].set[1]); assert.is_true(d[1].set[3]); assert.is_nil(d[1].set[2])
        local d2 = q("@group2-4 co +passive")
        assert.is_true(d2[1].set[2]); assert.is_true(d2[1].set[4]); assert.is_nil(d2[1].set[1])
    end)
end)

describe("Overhear qualifier matching", function()
    local function q(msg) return (NS.CB_ParseQualifiers(msg)) end
    local function entry(class, combat) return { class = class, combat = combat or {} } end
    local M = NS.CB_EntryMatchesQualifiers

    it("matches role from cached tank/heal flags", function()
        assert.is_true(M(q("@tank x"),  entry("WARRIOR", { isTank = true })))
        assert.is_false(M(q("@dps x"),  entry("WARRIOR", { isTank = true })))
        assert.is_true(M(q("@dps x"),   entry("MAGE")))
        assert.is_true(M(q("@heal x"),  entry("PRIEST", { isHealer = true })))
    end)

    it("matches class", function()
        assert.is_true(M(q("@mage x"),     entry("MAGE")))
        assert.is_false(M(q("@warrior x"), entry("MAGE")))
    end)

    it("matches melee/ranged via the class+role rule", function()
        assert.is_true(M(q("@melee x"),      entry("WARRIOR")))
        assert.is_true(M(q("@ranged x"),     entry("MAGE")))
        assert.is_true(M(q("@melee x"),      entry("DRUID",  { isTank = true })))    -- tank druid = melee
        assert.is_true(M(q("@ranged x"),     entry("DRUID")))                        -- non-tank druid = ranged
        assert.is_true(M(q("@ranged x"),     entry("SHAMAN", { isHealer = true })))  -- heal shaman = ranged
        assert.is_true(M(q("@melee x"),      entry("SHAMAN")))                       -- non-heal shaman = melee
        assert.is_true(M(q("@meleedps x"),   entry("ROGUE")))
        assert.is_false(M(q("@rangeddps x"), entry("WARRIOR")))
    end)

    it("matches level range + subgroup from resolved values", function()
        assert.is_true(M(q("@70-80 x"),  entry("MAGE"), 75, 1))
        assert.is_false(M(q("@70-80 x"), entry("MAGE"), 85, 1))
        assert.is_true(M(q("@group2 x"),  entry("MAGE"), 80, 2))
        assert.is_false(M(q("@group2 x"), entry("MAGE"), 80, 1))
    end)

    it("ANDs multiple descriptors", function()
        assert.is_true(M(q("@dps @mage x"),  entry("MAGE")))
        assert.is_false(M(q("@dps @mage x"), entry("WARRIOR")))  -- class fails
    end)

    it("an empty descriptor list matches everyone", function()
        assert.is_true(M(q("co +passive"), entry("MAGE")))
    end)
end)
