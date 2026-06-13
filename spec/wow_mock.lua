-- ============================================================
-- spec/wow_mock.lua  —  Minimal WoW 3.3.5a client API mock.
--
-- Defines just enough global state for CleanBot's logic files to LOAD under a standalone
-- Lua interpreter and for the functions under test to run. NOT a full emulation — extend it
-- as new specs exercise more of the API. Anything needing the live client (real frame
-- layout, rendering) is out of scope.
--
-- The `Mock` table is the test-facing control surface: it records outgoing sends, lets a
-- spec drive the OnUpdate tick and the clock, and resets between tests.
-- ============================================================

-- The namespace each addon file binds via `local NS = CleanBotNS`.
_G.CleanBotNS = _G.CleanBotNS or {}

_G.Mock = {
    whispers = {},   -- recorded SendChatMessage(..., "WHISPER", ...)  → { text=, target= }
    chat     = {},   -- recorded SendChatMessage on any other channel  → { text=, channel= }
    addon    = {},   -- recorded SendAddonMessage                      → { prefix=, text=, channel= }
    onUpdate = {},   -- captured OnUpdate handlers → { frame=, fn= }
    onEvent  = {},   -- captured OnEvent handlers  → { frame=, fn= }
    now      = 0,    -- value returned by GetTime()
    raid     = 0,    -- GetNumRaidMembers()
    party    = 0,    -- GetNumPartyMembers()
}

--- Clears recorded sends + the clock. Call from before_each. Leaves captured frame handlers
--- intact (frames are created once at file load, not per test).
function Mock.reset()
    Mock.whispers = {}
    Mock.chat     = {}
    Mock.addon    = {}
    Mock.now      = 0
    Mock.raid     = 0
    Mock.party    = 0
end

--- Advances the clock by dt and fires every captured OnUpdate handler with (frame, dt) —
--- mirrors one client frame for the addon's timers/queue.
function Mock.tick(dt)
    Mock.now = Mock.now + dt
    for _, h in ipairs(Mock.onUpdate) do h.fn(h.frame, dt) end
end

--- Fires a WoW event into every captured OnEvent handler as (frame, event, ...).
--- e.g. Mock.fireEvent("CHAT_MSG_WHISPER", "=== Bank ===", "Bot").
function Mock.fireEvent(event, ...)
    for _, h in ipairs(Mock.onEvent) do h.fn(h.frame, event, ...) end
end

-- Chainable frame stub. SetScript captures OnUpdate/OnEvent so specs can drive them; every
-- other method is a no-op returning the frame so load-time frame setup survives `dofile`.
local function makeFrame()
    local f = {}
    f.SetScript = function(self, event, fn)
        if event == "OnUpdate" then Mock.onUpdate[#Mock.onUpdate + 1] = { frame = self, fn = fn } end
        if event == "OnEvent"  then Mock.onEvent[#Mock.onEvent + 1]   = { frame = self, fn = fn } end
        return self
    end
    f.HookScript    = function(self) return self end
    f.RegisterEvent = function(self) return self end
    setmetatable(f, { __index = function() return function() return f end end })
    return f
end
_G.CreateFrame = function() return makeFrame() end
_G.UIParent    = makeFrame()

-- Globals referenced at file scope by the addon.
_G.StaticPopupDialogs = _G.StaticPopupDialogs or {}
_G.OKAY               = _G.OKAY or "Okay"

-- Client API used by the code under test.
_G.GetTime            = function() return Mock.now end
_G.GetNumRaidMembers  = function() return Mock.raid end
_G.GetNumPartyMembers = function() return Mock.party end
_G.UnitName           = function() return "TestPlayer" end

_G.SendChatMessage = function(text, channel, _, target)
    if channel == "WHISPER" then
        Mock.whispers[#Mock.whispers + 1] = { text = text, target = target }
    else
        Mock.chat[#Mock.chat + 1] = { text = text, channel = channel }
    end
end
_G.SendAddonMessage = function(prefix, text, channel)
    Mock.addon[#Mock.addon + 1] = { prefix = prefix, text = text, channel = channel }
end

-- WoW string helpers — aliases of the standard string library used throughout the addon.
_G.strmatch = string.match
_G.strfind  = string.find
_G.strsub   = string.sub
_G.strlower = string.lower
_G.strupper = string.upper
_G.strrep   = string.rep
_G.strtrim  = function(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

-- NS helpers normally provided by CleanBot.lua (which we don't load in unit specs). Stubbed so
-- Bridge.lua's runtime paths don't nil-error; CB_After records its callback rather than firing.
_G.CleanBotNS.CB_Print = _G.CleanBotNS.CB_Print or function() end
_G.CleanBotNS.CB_After = _G.CleanBotNS.CB_After or function() end
