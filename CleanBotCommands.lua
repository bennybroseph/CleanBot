-- ============================================================
-- CleanBotCommands.lua
-- Slash command registration and dispatch.
-- Loaded after CleanBot.lua; relies on globals set there.
-- ============================================================

-- ============================================================
-- /cleanbot  |  /cb
-- ============================================================
local NS = CleanBotNS

NS.CleanBot_Toggle = function()
    if CleanBotFrame:IsShown() then
        CleanBotFrame:Hide()
    else
        CleanBotFrame:Show()
        CleanBot_RequestRosterThenRefresh()
    end
end

local function CB_HandleSlash(msg)
    msg = msg:lower():match("^%s*(.-)%s*$")

    if msg == "debug knownbots" then
        CleanBot_ShowDebugKnownBots()

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
