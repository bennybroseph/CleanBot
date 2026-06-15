-- ============================================================
-- Events.lua  —  lightweight in-addon event bus (pub/sub)
--
-- Producers call NS.CB_Emit(event, ...); consumers subscribe ONCE via
-- NS.CB_On(event, fn) and react in the callback. This decouples a state change
-- from the UI that reflects it — no hard links, no manual refresh wiring.
--
-- Subscriptions are STABLE: the whole UI is built once at PLAYER_LOGIN and never
-- torn down, so subscribe at build time and re-read live state inside the handler.
-- Do not subscribe inside a per-bot/per-tab rebuild (there are none) — that would
-- accumulate dead handlers.
-- ============================================================
local NS = CleanBotNS

-- Canonical event names. Always reference NS.EV.* at call sites so a typo is a nil
-- index (caught immediately) rather than a silently-mismatched string literal.
NS.EV = {
    BOT_STATE_CHANGED    = "BOT_STATE_CHANGED",     -- (key, changed?) a bot's strategy/formation/loot changed
    BOT_INVENTORY_DIRTY  = "BOT_INVENTORY_DIRTY",   -- (key) a bot's bags/bank/equipment may have changed
    SCALE_CHANGED        = "SCALE_CHANGED",         -- (scalePct)
    TRANSPARENCY_CHANGED = "TRANSPARENCY_CHANGED",  -- (pct)
    ACCENT_CHANGED       = "ACCENT_CHANGED",        -- (r, g, b, a)
    LAYOUT_CHANGED       = "LAYOUT_CHANGED",         -- () margin/padding changed; re-flow the UI
}

-- handlers[event] = { [token] = fn }. Token-keyed (not an array) so CB_Off is O(1)
-- and removal never reindexes. The sub-table is therefore sparse — iterate it with
-- pairs/snapshot and never measure it with `#`.
local handlers  = {}
local nextToken = 0

--- Subscribes fn to an event. Returns an opaque token for CB_Off.
---@param event string   An NS.EV.* name.
---@param fn    fun(...)  Called with the emit args each time the event fires.
---@return number        Token identifying this subscription.
NS.CB_On = function(event, fn)
    local subs = handlers[event]
    if not subs then subs = {}; handlers[event] = subs end
    nextToken = nextToken + 1
    subs[nextToken] = fn
    return nextToken
end

--- Unsubscribes. Pass either the token returned by CB_On, or (event, fn) to remove by pair.
---@param tokenOrEvent number|string  The CB_On token, or an event name (with fn).
---@param fn           fun(...)?       Required only when removing by (event, fn).
NS.CB_Off = function(tokenOrEvent, fn)
    if type(tokenOrEvent) == "string" then
        local subs = handlers[tokenOrEvent]
        if not subs then return end
        for tok, f in pairs(subs) do
            if f == fn then subs[tok] = nil end
        end
    else
        for _, subs in pairs(handlers) do
            if subs[tokenOrEvent] ~= nil then subs[tokenOrEvent] = nil; return end
        end
    end
end

--- Fires an event: calls every subscriber with the given args. Subscribers are
--- snapshotted before the loop so a handler may On/Off mid-dispatch without
--- corrupting iteration; each call is pcall-guarded so one bad subscriber can't
--- abort the rest (this is the one true error boundary for reactive UI updates).
---@param event string  An NS.EV.* name.
---@param ...   any      Forwarded to every subscriber.
NS.CB_Emit = function(event, ...)
    local subs = handlers[event]
    if not subs then return end
    local snapshot, n = {}, 0
    for _, fn in pairs(subs) do n = n + 1; snapshot[n] = fn end
    for i = 1, n do
        local ok, err = pcall(snapshot[i], ...)
        if not ok then
            (NS.CB_Print or print)("|cffff4444event error|r (" .. tostring(event) .. "): " .. tostring(err))
        end
    end
end
