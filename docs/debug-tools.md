# Debug Tools

Developer reference for CleanBot's diagnostics: slash commands, the Settings → Debug
sub-tab, and how debug state persists. Implementation lives in `Debug.lua`; the bridge
override it controls is specified in [bridge-protocol.md](bridge-protocol.md).

Both the slash commands and the Debug sub-tab route through the same setters
(`NS.CB_SetBridgeOverride`, `NS.CB_SetDebugSimulate`, `NS.CB_SetDebugVerify`,
`NS.CB_SetDebugTabEnabled`, `NS.CB_SetInspectTrace`), so chat and UI always agree.

---

## `/cbdebug`

| Subcommand | Effect |
|---|---|
| *(none)* | Quick state dump to chat: bridge real/override/simulate/verify/tab/login-phase flags, group type + per-member probe state, and the KnownBots cache. |
| `enable` / `disable` | Show/hide the Settings → Debug sub-tab (persisted). |
| `bridge off` | Force the bridge **absent** — all traffic uses the whisper fallback. |
| `bridge on` | Force the bridge **present** — allowlisted commands use the bridge path. |
| `bridge reset` | Clear the override; follow the real handshake result again. |
| `simulate` | Toggle simulate mode: `CB_SendBotCommand` prints commands to chat instead of sending them. |
| `verify` | Toggle strategy verify logging: after a toggle, the authoritative re-read is compared against the optimistic UI state and mismatches are logged. |

Changing the bridge override immediately re-syncs (roster/inventory/quests re-fetch via
the new effective path) rather than waiting for the next window open.

## `/cbtiming [runs] [botName]`

Measures whisper reply latency to tune `NS.WHISPER_SILENCE` (the silence timeout that
ends whisper-path collections in `Bridge.lua`). Defaults: 3 runs against the selected bot
(falling back to any known bot). Each run whispers `items` and records:

- **first** — time from send to the first reply line
- **gaps** — time between consecutive reply lines within the burst

The silence timeout must cover `max(first, maxGap)` — it resets on every line, so total
reply length is irrelevant. The report suggests a timeout of 2× the worst observation.
Refuses to run while simulate mode is on (commands wouldn't actually send). Also
available as the Debug sub-tab's "Measure Reply Timing" button (`NS.CB_RunTimingMeasure`).

## `/cbinspect`

Toggles a `hooksecurefunc("NotifyInspect", …)` trace that prints **every** inspect call
from any addon, with `source=CleanBot` (green) or `source=EXTERNAL` (red) plus the
caller's stack line. Used to diagnose another addon inspecting in the background and
evicting the single-unit equipment-inspect cache (rich tooltips reverting to generic).
Session-only — deliberately not persisted (the hook can't be removed; a flag gates output).

## `/cbframes`

Mouse-focus diagnostics: prints which frame is capturing the mouse (name, strata, level,
mouse-enabled) plus the state of the key Manage-tab frames. Hover the stuck widget first,
then run it. Useful for strata-inheritance bugs (see CLAUDE.md's note on BACKGROUND vs
MEDIUM strata).

## `/cbicons`

Toggles the Icon Browser: a scrollable grid of every usable icon (the macro-icon database,
via `GetMacroIconInfo` + `GetMacroItemIconInfo`). Type in the search box to filter by name,
hover an icon for its full path, and click to print a paste-ready `Interface\Icons\…` path
to chat. Also available as the Debug sub-tab's "Icon Browser" button (`NS.CB_ToggleIconBrowser`).

## `/cleanbot debug knownbots`

Opens the KnownBots popup window: handshake state, last `HELLO_ACK`, active overrides,
the last raw `STATE~` payload, and each bot's parsed combat strategy flags grouped
ON / OFF / unknown.

---

## Where state surfaces

- **Settings → Debug sub-tab** — revealed by `/cbdebug enable`; checkboxes/buttons mirror
  the setters above, and an "Auto (<state>)" label tracks the real handshake underneath
  any override (`NS.CB_RefreshDebugTab`).
- **Minimap button tooltip** — always shows the real bridge state; adds gray lines for an
  active bridge override, simulate mode, and verify logging.
- **Persistence** — `debugTabEnabled`, `debugBridgeOverride`, `debugSimulate`, and
  `debugVerify` persist in `CleanBot_SavedVars` and are restored at `PLAYER_LOGIN`
  (`CleanBot.lua`). The inspect trace is the exception (session-only).
