-- ============================================================
-- spec/inventory_spec.lua  —  Tests for Individual/Inventory.lua pure parsers.
-- ============================================================

-- Load the addon file under the mock. Its load-time frame/menu/popup setup is absorbed
-- by the stubs in wow_mock.lua; the functions under test touch no live client API.
dofile("Individual/Inventory.lua")
local NS = CleanBotNS

describe("CB_ParseItemLine", function()
    it("parses a basic item link with default count 1", function()
        local link = "|cffffffff|Hitem:6948:0:0:0:0:0:0:0|h[Hearthstone]|h|r"
        local r = NS.CB_ParseItemLine(link)
        assert.is_not_nil(r)
        assert.equals(link, r.link)
        assert.equals(1, r.count)
    end)

    it("reads a stack count appended after the link", function()
        local r = NS.CB_ParseItemLine("|cffffffff|Hitem:2589|h[Linen Cloth]|h|r x20")
        assert.is_not_nil(r)
        assert.equals(20, r.count)
    end)

    it("percent-decodes encoded characters in the line", function()
        local r = NS.CB_ParseItemLine("|cffffffff|Hitem:1234|h[Big%20Bag]|h|r")
        assert.is_not_nil(r)
        assert.equals("|cffffffff|Hitem:1234|h[Big Bag]|h|r", r.link)
    end)

    it("returns nil for a line with no item link", function()
        assert.is_nil(NS.CB_ParseItemLine("Strategies: tank pve"))
    end)
end)
