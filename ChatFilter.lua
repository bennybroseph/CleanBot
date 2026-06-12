-- ============================================================
-- ChatFilter.lua  —  hides CleanBot's own whisper/command chatter from the chat
-- window to cut spam. Display-only: ChatFrame message filters intercept the chat-
-- frame display pipeline, NOT addon RegisterEvent handlers, so Bridge.lua keeps
-- parsing every line — we only stop the user-facing echo of the commands we send
-- and the replies we consume.
--
-- Gated on NS.hideBotChatter (Settings → "Hide Bot Chatter", default on; toggle off
-- to see raw traffic for testing). Read live on each call, so no /reload is needed.
-- ============================================================
local NS = CleanBotNS

local function enabled()
    return NS.hideBotChatter ~= false
end

-- A whisper is suppressible when the other party is a bot we manage OR a current
-- group member. The group-member case covers the no-bridge discovery handshake, where
-- a member isn't in CleanBot_PartyBots yet but is being probed (the "co ?" we send and
-- the "Strategies:" reply). CB_FindPartyUnit walks party AND raid.
---@param name string|nil  Whisper sender (incoming) or recipient (outgoing).
---@return boolean
local function suppressibleParty(name)
    if not name or name == "" then return false end
    if CleanBot_PartyBots[strlower(name)] then return true end
    return (NS.CB_FindPartyUnit and NS.CB_FindPartyUnit(name) ~= nil) or false
end

-- Outgoing: hide only the command whispers CleanBot itself sent, so a command you type by hand
-- to a bot stays visible. Bridge.lua tags each addon-sent whisper in NS.selfWhispers (keyed by
-- recipient+text); we consume one matching tag per INFORM. No tag → it's a manual whisper, show
-- it. Tags older than SELF_WHISPER_TTL are purged: a failed send fires no INFORM, so its tag
-- must not linger and wrongly hide a later identical manual command.
local SELF_WHISPER_TTL = 3
local function filterWhisperInform(_, _, msg, recipient)
    if not enabled() or not suppressibleParty(recipient) then return false end
    local store = NS.selfWhispers
    local list  = store and store[strlower(recipient or "") .. "\0" .. (msg or "")]
    if not list then return false end
    local now = GetTime()
    while list[1] and (now - list[1]) > SELF_WHISPER_TTL do
        table.remove(list, 1)   -- drop stale tags (sends that never produced an INFORM)
    end
    if list[1] then
        table.remove(list, 1)   -- consume this addon-sent whisper
        return true
    end
    return false
end

-- Incoming: hide a bot's reply while its command-reply window is open (see CB_MarkExpectReply
-- in Bridge.lua). The window opens when we whisper a command and is slid forward by one
-- WHISPER_SILENCE on each reply line, so it brackets the whole burst — one ack or a long
-- streamed dump — and closes once the bot goes quiet. Unsolicited bot greetings (a bot's
-- readiness whisper, with no command before it) are intentionally NOT hidden: their text
-- varies and isn't distinguishable from a human's, so they show once on join.
local function filterWhisper(_, _, _, sender)
    if not enabled() or not suppressibleParty(sender) then return false end
    local key = strlower(sender)
    local deadline = NS.botReplyWindow and NS.botReplyWindow[key]
    if deadline and GetTime() < deadline then
        NS.botReplyWindow[key] = GetTime() + NS.WHISPER_SILENCE   -- slide to keep bracketing the burst
        return true
    end
    return false
end

-- System: hide the server output CleanBot triggers and already parses — the self-bot
-- "player botAI" toggle line, the "Linked accounts:" dump, and the per-name bot-add
-- results. collectingLinked is tracked locally (not off Bridge's flag) so it stays
-- consistent regardless of filter-vs-handler ordering for the same line.
local collectingLinked = false

-- Result words that mark a line as ".playerbots bot add/addaccount/login/remove" output.
local BOT_CMD_RESULTS = {
    "player already logged in",
    "player is offline",
    "not your bot",
    " - ok",
    "logged in",
}

local function filterSystem(_, _, msg)
    if not enabled() or not msg then return false end
    local lower = strlower(msg)

    if lower:find("player botai", 1, true) then return true end

    if lower:find("linked accounts", 1, true) then
        collectingLinked = true
        return true
    end
    if collectingLinked then
        if msg:match("^%s*%-%s*%S+%s*$") then return true end   -- "- NAME" row
        collectingLinked = false                               -- non-row line ends the list
    end

    -- Per-name bot command results: "<cmd>: <Name> - <result>".
    if msg:match("^%a+:%s+%S+%s+%-%s+") then
        for _, word in ipairs(BOT_CMD_RESULTS) do
            if lower:find(word, 1, true) then return true end
        end
    end

    return false
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", filterWhisperInform)
ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER",        filterWhisper)
ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM",         filterSystem)
