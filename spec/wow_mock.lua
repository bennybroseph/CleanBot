-- ============================================================
-- spec/wow_mock.lua  —  Minimal WoW 3.3.5a client API mock.
--
-- Defines just enough global state for CleanBot's pure-logic files to LOAD under a
-- standalone Lua interpreter, and for the functions under test to run. This is NOT a
-- full emulation — extend it as new specs exercise more of the API. Anything that
-- genuinely needs the live client (real frame layout, rendering) is out of scope here.
-- ============================================================

-- The namespace each addon file binds via `local NS = CleanBotNS`.
_G.CleanBotNS = _G.CleanBotNS or {}

-- Chainable frame stub: every method returns the frame itself, so a file's load-time
-- frame setup (CreateFrame, dropdown menus, event frames) is a harmless no-op that
-- survives `dofile`. Indexing an unknown field yields a function that returns the frame.
local function makeFrame()
    local f = {}
    setmetatable(f, { __index = function() return function() return f end end })
    return f
end
_G.CreateFrame = function() return makeFrame() end
_G.UIParent    = makeFrame()

-- Globals referenced at file scope (not inside functions) by the addon.
_G.StaticPopupDialogs = _G.StaticPopupDialogs or {}
_G.OKAY               = _G.OKAY or "Okay"

-- WoW string helpers — aliases of the standard string library used throughout the addon.
_G.strmatch = string.match
_G.strfind  = string.find
_G.strsub   = string.sub
_G.strlower = string.lower
_G.strupper = string.upper
_G.strrep   = string.rep
_G.strtrim  = function(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
