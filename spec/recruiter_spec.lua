-- ============================================================
-- spec/recruiter_spec.lua  —  Recruiter.lua pure logic: role→valid-classes derivation,
-- (class,role)→spec lookup, the addclass command arguments, and the roster-diff that
-- identifies the newly-joined bot. UI/attach behavior is verified in-game, not here.
-- ============================================================
if not CleanBotNS.CB_RecruiterSpec then dofile("Recruiter.lua") end
local NS = CleanBotNS

describe("Recruiter role → classes", function()
    it("tank classes are warrior/paladin/dk/druid in canonical order", function()
        assert.same({ "WARRIOR", "PALADIN", "DEATHKNIGHT", "DRUID" },
            NS.CB_RecruiterClassesForRole("TANK"))
    end)

    it("healer classes are paladin/priest/shaman/druid", function()
        assert.same({ "PALADIN", "PRIEST", "SHAMAN", "DRUID" },
            NS.CB_RecruiterClassesForRole("HEAL"))
    end)

    it("dps includes all ten classes", function()
        assert.equals(10, #NS.CB_RecruiterClassesForRole("DPS"))
    end)
end)

describe("Recruiter class → roles (action-bar flyout)", function()
    it("lists a class's fillable roles in TANK/HEAL/DPS order", function()
        assert.same({ "TANK", "DPS" },          NS.CB_RecruiterRolesForClass("WARRIOR"))
        assert.same({ "TANK", "HEAL", "DPS" },   NS.CB_RecruiterRolesForClass("PALADIN"))
        assert.same({ "TANK", "HEAL", "DPS" },   NS.CB_RecruiterRolesForClass("DRUID"))
        assert.same({ "DPS" },                   NS.CB_RecruiterRolesForClass("MAGE"))
        assert.same({ "HEAL", "DPS" },           NS.CB_RecruiterRolesForClass("PRIEST"))
    end)

    it("returns all ten classes for the random pick / class level", function()
        assert.equals(10, #NS.CB_RecruiterAllClasses())
    end)
end)

describe("Recruiter spec lookup", function()
    it("returns the role's PvE spec token", function()
        assert.equals("prot pve",  NS.CB_RecruiterSpec("WARRIOR", "TANK"))
        assert.equals("holy pve",  NS.CB_RecruiterSpec("PALADIN", "HEAL"))
        assert.equals("resto pve", NS.CB_RecruiterSpec("DRUID",   "HEAL"))
        assert.equals("double aura blood pve", NS.CB_RecruiterSpec("DEATHKNIGHT", "TANK"))
    end)

    it("returns nil for an impossible class/role combo", function()
        assert.is_nil(NS.CB_RecruiterSpec("MAGE",  "TANK"))
        assert.is_nil(NS.CB_RecruiterSpec("ROGUE", "HEAL"))
    end)
end)

describe("Recruiter addclass arguments", function()
    it("maps Death Knight to the server's 'dk' token, others lowercased", function()
        assert.equals("dk",      NS.CB_RecruiterAddClassArg("DEATHKNIGHT"))
        assert.equals("warrior", NS.CB_RecruiterAddClassArg("WARRIOR"))
        assert.equals("druid",   NS.CB_RecruiterAddClassArg("DRUID"))
    end)

    it("appends the gender arg only for a specific gender", function()
        assert.equals("",        NS.CB_RecruiterGenderArg("ANY"))
        assert.equals(" male",   NS.CB_RecruiterGenderArg("MALE"))
        assert.equals(" female", NS.CB_RecruiterGenderArg("FEMALE"))
    end)
end)

describe("Recruiter roster diff", function()
    local members = {
        { name = "Oldtank", class = "WARRIOR" },
        { name = "Newmage", class = "MAGE" },
    }

    it("finds a new member of the wanted class", function()
        local prev = { oldtank = true }
        assert.equals("Newmage", NS.CB_RecruiterFindNewMember(prev, members, "MAGE"))
    end)

    it("ignores a member that was already present", function()
        local prev = { oldtank = true, newmage = true }
        assert.is_nil(NS.CB_RecruiterFindNewMember(prev, members, "MAGE"))
    end)

    it("ignores a new member whose class doesn't match", function()
        local prev = { oldtank = true }
        assert.is_nil(NS.CB_RecruiterFindNewMember(prev, members, "PRIEST"))
    end)
end)
