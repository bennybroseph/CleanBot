-- ============================================================
-- CleanBotCommands.lua
-- Slash command registration and dispatch.
-- Loaded after CleanBot.lua; relies on globals set there.
-- ============================================================

-- ============================================================
-- /cleanbot  |  /cb
-- ============================================================
local function CB_HandleSlash(msg)
    msg = msg:lower():match("^%s*(.-)%s*$")

    if msg == "debug knownbots" then
        CleanBot_ShowDebugKnownBots()

    elseif msg == "" then
        if CleanBotFrame:IsShown() then
            CleanBotFrame:Hide()
        else
            CleanBotFrame:Show()
            CleanBot_RequestRosterThenRefresh()
        end

    else
        print("|cffffcc00CleanBot|r: unknown command '" .. msg .. "'")
        print("  /cleanbot                 — toggle window")
        print("  /cleanbot debug knownbots — show KnownBots debug popup")
    end
end

SLASH_CLEANBOT1 = "/cleanbot"
SLASH_CLEANBOT2 = "/cb"
SlashCmdList["CLEANBOT"] = CB_HandleSlash

-- ============================================================
-- /cbdebug  — quick party/cache dump to chat
-- ============================================================
SLASH_CBDEBUG1 = "/cbdebug"
SlashCmdList["CBDEBUG"] = function()
    local numMembers = GetNumPartyMembers()
    print("Party members:", numMembers)
    for i = 1, numMembers do
        local unit = "party" .. i
        local name = UnitName(unit)
        local _, class = UnitClass(unit)
        local inCache = name and CleanBot_KnownBots[strlower(name)] ~= nil
        print(string.format("  [%d] name=%s exists=%s isPlayer=%s class=%s inCache=%s",
            i,
            tostring(name),
            tostring(UnitExists(unit)),
            tostring(UnitIsPlayer(unit)),
            tostring(class),
            tostring(inCache)))
    end
    print("KnownBots cache:")
    local count = 0
    for k, v in pairs(CleanBot_KnownBots) do
        print("  " .. k .. " = " .. tostring(v.class))
        count = count + 1
    end
    if count == 0 then print("  (empty)") end
end
