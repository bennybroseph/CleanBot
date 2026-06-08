-- ============================================================
-- Commands.lua
-- Slash command registration and dispatch.
-- Loaded after CleanBot.lua; relies on globals set there.
-- ============================================================

-- ============================================================
-- /cleanbot  |  /cb
-- ============================================================
local NS = CleanBotNS

--- Toggles the main CleanBot window; requests a roster refresh when opening.
NS.CleanBot_Toggle = function()
    if CleanBotFrame:IsShown() then
        CleanBotFrame:Hide()
    else
        CleanBotFrame:Show()
        NS.CB_RequestRosterThenRefresh()
    end
end

--- Parses and dispatches the /cleanbot (/cb) slash command.
---@param msg string  The raw slash argument text.
local function CB_HandleSlash(msg)
    msg = msg:lower():match("^%s*(.-)%s*$")

    if msg == "debug knownbots" then
        NS.CB_ShowDebugKnownBots()

    elseif msg == "" then
        NS.CleanBot_Toggle()

    else
        NS.CB_Print("unknown command '" .. msg .. "'")
        print("  /cleanbot                 — toggle window")
        print("  /cleanbot debug knownbots — show KnownBots debug popup")
    end
end

SLASH_CLEANBOT1 = "/cleanbot"
SLASH_CLEANBOT2 = "/cb"
SlashCmdList["CLEANBOT"] = CB_HandleSlash
