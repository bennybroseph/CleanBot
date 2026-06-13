-- ============================================================
-- spec/bridge_spec.lua  —  Tests for Bridge.lua command routing + the serial whisper queue.
--
-- Loads Bridge.lua under the mock and drives its real code paths: the bridge/whisper routing
-- decision (CB_GetBridgeOpcode allowlist + the debug override), and the per-bot serial queue
-- (one request at a time, advancing only after reply-silence). Sends are captured by the mock;
-- the OnUpdate tick is driven via Mock.tick.
-- ============================================================

-- Load once: re-dofile'ing would re-register the OnUpdate/OnEvent handlers with the mock.
if not CleanBotNS.CB_EnqueueRequest then dofile("Bridge.lua") end
local NS = CleanBotNS

-- Item line as the bot streams it (the "items"/"bank" reply format).
local function itemLine(id, name, count)
    local s = "|cffffffff|Hitem:" .. id .. "|h[" .. name .. "]|h|r"
    return count and (s .. " x" .. count) or s
end

describe("Bridge command routing", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots     = { bot = { name = "Bot" } }
        NS.bridgeState         = "present"
        NS.debugBridgeOverride = nil
        Mock.party             = 1   -- so CB_SendBridge picks the PARTY channel
    end)

    it("routes an allowlisted combat toggle through the bridge (no whisper)", function()
        NS.CB_SendBotCommand("Bot", "co +focus")
        assert.equals(1, #Mock.addon)
        assert.equals(0, #Mock.whispers)
        assert.equals("RUN~COMBAT~BOT~Bot~~co +focus", Mock.addon[1].text)
        assert.equals("PARTY", Mock.addon[1].channel)
    end)

    it("whispers a query (co ?) instead of bridging it", function()
        NS.CB_SendBotCommand("Bot", "co ?")
        assert.equals(0, #Mock.addon)
        assert.equals(1, #Mock.whispers)
        assert.equals("co ?", Mock.whispers[1].text)
        assert.equals("Bot", Mock.whispers[1].target)
    end)

    it("whispers a list query (items) rather than bridging it", function()
        NS.CB_SendBotCommand("Bot", "items")
        assert.equals(0, #Mock.addon)
        assert.equals(1, #Mock.whispers)
        assert.equals("items", Mock.whispers[1].text)
    end)
end)

describe("Bridge override gating", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots     = { bot = { name = "Bot" } }
        NS.bridgeState         = "present"
        NS.debugBridgeOverride = nil
        Mock.party             = 1
    end)

    it("forces a whisper when the override is 'absent', even for an allowlisted command", function()
        NS.debugBridgeOverride = "absent"
        NS.CB_SendBotCommand("Bot", "co +focus")
        assert.equals(0, #Mock.addon)
        assert.equals(1, #Mock.whispers)
        assert.equals("co +focus", Mock.whispers[1].text)
    end)
end)

describe("Serial whisper queue", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = { bot = { name = "Bot" } }
    end)

    -- Recorder request: appends its tag to `order` when actually sent. No busy flag of its own —
    -- the queue's pump sets wqBusy, so the next won't run until a tick clears it on silence.
    local function recorder(order, tag)
        return function() order[#order + 1] = tag end
    end

    it("runs one request at a time, advancing on reply silence", function()
        local order = {}
        NS.CB_EnqueueRequest("bot", recorder(order, "a"))
        NS.CB_EnqueueRequest("bot", recorder(order, "b"))
        NS.CB_EnqueueRequest("bot", recorder(order, "c"))
        assert.are.same({ "a" }, order)                 -- only the first sent immediately

        Mock.tick(0.6); assert.are.same({ "a", "b" }, order)
        Mock.tick(0.6); assert.are.same({ "a", "b", "c" }, order)
        Mock.tick(0.6); assert.are.same({ "a", "b", "c" }, order)  -- queue drained, no-op
    end)

    it("does not advance before the silence threshold (WHISPER_SILENCE)", function()
        local order = {}
        NS.CB_EnqueueRequest("bot", recorder(order, "a"))
        NS.CB_EnqueueRequest("bot", recorder(order, "b"))
        assert.are.same({ "a" }, order)

        Mock.tick(0.3); assert.are.same({ "a" }, order)        -- 0.3 < 0.5: still busy
        Mock.tick(0.3); assert.are.same({ "a", "b" }, order)   -- cumulative 0.6 ≥ 0.5: advances
    end)
end)

describe("Whisper reply routing", function()
    before_each(function()
        Mock.reset()
    end)

    it("routes item lines to the section named by the last header (no cross-contamination)", function()
        local e = { name = "Bot", inventory = { items = {} }, bank = { items = {} },
                    awaitingInventory = true, invStaging = {},
                    awaitingBank = true, bankStaging = {} }
        CleanBot_PartyBots = { bot = e }

        Mock.fireEvent("CHAT_MSG_WHISPER", "=== Inventory ===", "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", itemLine(111, "Inv One"), "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", "=== Bank ===", "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", itemLine(222, "Bank One"), "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", itemLine(333, "Bank Two", 3), "Bot")

        assert.equals(1, #e.invStaging)
        assert.equals(2, #e.bankStaging)
        assert.is_true(e.invReplyArrived)
        assert.is_true(e.bankReplyArrived)
        assert.equals(3, e.bankStaging[2].count)
    end)

    it("finalizes a bank reply into bank.items on silence", function()
        local e = { name = "Bot", bank = { items = {} }, awaitingBank = true, bankStaging = {} }
        CleanBot_PartyBots = { bot = e }

        Mock.fireEvent("CHAT_MSG_WHISPER", "=== Bank ===", "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", itemLine(222, "Bank One"), "Bot")
        Mock.tick(0.6)

        assert.equals(1, #e.bank.items)
        assert.is_false(e.awaitingBank)
        assert.is_nil(e.bankStaging)
    end)

    it("keeps the stale list when a reply never arrives (wipe guard)", function()
        local e = { name = "Bot", bank = { items = { { link = "KEEP", count = 1 } } },
                    awaitingBank = true, bankStaging = {}, bankReplyArrived = false }
        CleanBot_PartyBots = { bot = e }

        Mock.tick(0.6)   -- silence, but no reply ever arrived

        assert.equals(1, #e.bank.items)
        assert.equals("KEEP", e.bank.items[1].link)
        assert.is_false(e.awaitingBank)
    end)
end)

describe("Stats reply parsing", function()
    before_each(function() Mock.reset() end)

    it("parses money, bag totals (free→used), and clears awaitingMoney", function()
        local e = { name = "Bot", inventory = { items = {} }, awaitingMoney = true }
        CleanBot_PartyBots = { bot = e }

        Mock.fireEvent("CHAT_MSG_WHISPER", "5g 30s 10c, 12/16 Bag, 87% (5g 24s) Dur, 45/67% XP", "Bot")

        assert.equals(5,  e.money.gold)
        assert.equals(30, e.money.silver)
        assert.equals(10, e.money.copper)
        assert.equals(16, e.inventory.bagTotal)
        assert.equals(4,  e.inventory.bagUsed)   -- 16 total - 12 free
        assert.is_false(e.awaitingMoney)
    end)
end)
