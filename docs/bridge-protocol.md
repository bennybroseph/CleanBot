# MultiBot Bridge Protocol

Developer reference for the `MBOT` addon-message protocol between CleanBot and the
server-side [mod-multibot-bridge](https://github.com/Wishmaster117/mod-multibot-bridge/blob/main/src/MultiBotBridge.cpp)
module. The client side lives in `Bridge.lua`; the bot-command survey is in
[playerbot-commands.md](playerbot-commands.md).

---

## Transport

All packets travel as addon messages with prefix `MBOT`:

```lua
SendAddonMessage("MBOT", msg, channel)
```

`CB_SendBridge(msg)` in `Bridge.lua` picks the channel:

| Situation | Channel |
|---|---|
| In a raid (`GetNumRaidMembers() > 0`) | `"RAID"` — `"PARTY"` does **not** reach raid members |
| In a party | `"PARTY"` |
| Solo with self-bot active (`NS.selfBotActive`) | `"WHISPER"` to the player's own name |
| Solo, no self-bot | no-op (nothing to talk to) |

The self-whisper works because the server bridge replies directly to the sender
(`player->SendDirectMessage`) and its chat hook fires on the whisper overload regardless
of recipient — so a solo player can complete the handshake and carry all traffic.

Server-side, `RUN~` commands route through `ExecuteSilentBotCommand()`, which calls
`botAI->HandleCommand(CHAT_MSG_WHISPER, command, requester)` — identical to a whisper,
but with no whisper log spam.

---

## Handshake & state machine

`NS.bridgeState` is `"unknown"` until detection resolves, then `"present"` or `"absent"`.

1. **Trigger** — `CB_StartBridgeDetection()` runs at `PLAYER_ENTERING_WORLD` (with retries
   at +1/+3/+6 s for late-loading rosters), on `PARTY_MEMBERS_CHANGED` /
   `RAID_ROSTER_UPDATE` while state is still `unknown`, and when self-bot is enabled.
   It needs either a group or an active self-bot, and is idempotent.
2. **Probe** — client sends `HELLO~1`.
3. **Resolve** — a reply starting `HELLO_ACK~` ⇒ `bridgeState = "present"`, followed by an
   immediate roster sync (`GET~ROSTER` / `GET~DETAILS` / `GET~STATES`) and a linked-accounts
   fetch. No ack within **3 s** ⇒ `bridgeState = "absent"`, and discovery falls back to
   whisper probing (`co ?` to each group member; only bots reply with a `Strategies:` line).
4. **Reset** — state returns to `unknown` at the first `PLAYER_ENTERING_WORLD` of a session;
   `PLAYER_LOGOUT` clears the session flag so the next login is treated as fresh.

On a **fresh login** (not `/reload`), `loginPhaseActive` blocks whisper probing until
detection resolves — bots may not be in-world yet. Once detection resolves absent, the probe
sweep runs and records each probed-but-unconfirmed member as a `joinCandidate`. A bot that
wasn't in-world for its probe announces itself once loaded by whispering the player; that
unsolicited whisper (any text — greetings vary by playerbots version) re-sends `co ?`, and the
`Strategies:` reply confirms it. This replaces the old exact-`Hello!` match.

---

## Outbound packets

### Commands — `RUN~`

```
RUN~<OPCODE>~BOT~<botName>~~<command>
```

Sent by `NS.CB_SendBotCommand` **only** when the effective bridge state is `present` AND
the command matches an opcode allowlist (`CB_GetBridgeOpcode`); everything else whispers.
Allowlists mirror the server's `IsAllowed*()` checks — keep `Bridge.lua` in sync with
`MultiBotBridge.cpp` when the bridge updates.

| Opcode | Allowed commands | Notes |
|---|---|---|
| `COMBAT` | `co +/-` for: focus, dps assist, aoe, dps aoe, tank assist, avoid aoe, save mana, threat, behind, wait for attack — plus `wait for attack time <N>` (N = 0–60, no `co` prefix) | Matched case-insensitively |
| `POSITION` | `disperse disable`, `disperse set <N>` (0 < N ≤ 100) | Allowlisted plumbing — no CleanBot UI sends these yet |
| `LOOT` | `nc +loot`, `nc -loot`, `ll all/normal/gray/quest/skill` | Case-sensitive on the server |
| `RTI` | `rti <icon>`, `rti cc <icon>` (STAR/CIRCLE/DIAMOND/TRIANGLE/MOON/SQUARE/CROSS/SKULL), `attack rti target`, `pull rti target` | Allowlisted plumbing — no CleanBot UI sends these yet |

Queries (`co ?`, `nc ?`, `items`, `quests all`, `stats`, `talents spec list`) are never
allowlisted, so they always whisper and their replies arrive via `CHAT_MSG_WHISPER` as usual.

### Queries — `GET~`

| Packet | Purpose | Reply packets |
|---|---|---|
| `GET~ROSTER` | Bot names in the group | `ROSTER~` |
| `GET~DETAILS` | Per-bot identity/class | `DETAIL~` |
| `GET~STATES` | Per-bot strategy snapshot | `STATE~` |
| `GET~INVENTORY~<botName>~inv` | Bot's bag contents + money | `INV_BEGIN~` / `INV_SUMMARY~` / `INV_ITEM~` / `INV_END~` |
| `GET~QUESTS~ALL~<botName>~quests` | Bot's quest log | `QUESTS_BEGIN~` / `QUESTS_ITEM~` / `QUESTS_END~` |

`GET~ROSTER/DETAILS/STATES` are debounced: `CB_RequestSync` (0.5 s, all three) and
`CB_RequestStates` (0.4 s, states only — silent strategy reconciliation after a toggle).

---

## Inbound packets (`CHAT_MSG_ADDON`, prefix `MBOT`)

Parsed in `Bridge.lua`'s event handler. Fields are `~`-separated; `NS.CB_SplitOnce` walks
them. `<token>` fields are request-correlation echoes and are skipped on parse.

| Packet | Layout | Handling |
|---|---|---|
| `HELLO_ACK~…` | — | Drives the real state machine (see below) |
| `ROSTER~<name>,…` | name up to first comma | Seeds a minimal bot entry if unknown |
| `DETAIL~<name>~?~?~<class>~…` | name + class | Establishes identity/class; preserves strategy data already parsed from `STATE~` |
| `STATE~<name>~<combat>~<nonCombat>` | comma-separated strategy lists | Stored via `CB_StoreCombat` / `CB_StoreNonCombat`; creates a minimal entry if `STATE~` beats `ROSTER~` |
| `INV_BEGIN~<name>~…` | — | Resets `entry.inventory = { items = {} }` |
| `INV_SUMMARY~<name>~<token>~<gold>~<silver>~<copper>~<bagUsed>~<bagTotal>` | money + bag counts | Bag is **used/total** (the whisper-path `stats` reply is free/total — converted on parse) |
| `INV_ITEM~<name>~<token>~<encodedItem>` | one item per packet | Decoded by `NS.CB_ParseItemLine` |
| `INV_END~<name>` | — | Clears the in-flight flag; renders if the inventory frame is open |
| `QUESTS_BEGIN~<name>~<token>~<mode>` | — | Resets `entry.quests` |
| `QUESTS_ITEM~<name>~<token>~<mode>~<status>~<questID>~<questName>` | status `C`/`I`; name URL-encoded | Appended as `{ id, status }` |
| `QUESTS_END~<name>~<token>~<mode>` | — | Renders if the quest frame is open |

---

## Debug override contract

`CB_EffectiveBridgeState()` (`return NS.debugBridgeOverride or NS.bridgeState`) is the
single decision point that makes `/cbdebug bridge on|off|reset` work (see
[debug-tools.md](debug-tools.md)). When adding bridge traffic:

1. **Bot commands** → send via `NS.CB_SendBotCommand` (already honors simulate mode and
   the override). Never call `SendChatMessage`/`SendAddonMessage` directly for these.
2. **Raw `GET~`/protocol traffic** → gate the present branch on
   `CB_EffectiveBridgeState() == "present"`, not raw `NS.bridgeState`, and provide a
   whisper fallback where one exists (mirror `CB_FetchInventory` / `CB_FetchQuests`).
3. **New inbound handlers** → add them *below* the
   `elseif CB_EffectiveBridgeState() ~= "present" then return` guard so data packets are
   dropped when the override forces no-bridge. Only `HELLO_ACK~` runs above the guard,
   because it drives the *real* state machine so `bridge reset` can restore the truth.

Lifecycle reads (detection guard/timeout, `HELLO_ACK` → present, roster-event trigger,
login/logout resets) intentionally stay on raw `NS.bridgeState` so the true state is
always tracked underneath the override.
