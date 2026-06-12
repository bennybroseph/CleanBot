# Playerbot Command Survey

Human-readable companion to the bridge allowlists in `Bridge.lua` (the addon-message
protocol itself is documented in [bridge-protocol.md](bridge-protocol.md)). The official
[Playerbot Commands wiki](https://github.com/mod-playerbots/mod-playerbots/wiki/Playerbot-Commands)
is sparse, so this captures what was learned by reading the mod-playerbots action
source directly (`src/Ai/Base/Actions/*.cpp` and `src/Ai/Base/ActionContext.h`).

**Status legend:** ✅ used by CleanBot · ⚠️ used but only partially · ⬜ available, unused.

This is a reference, not a roadmap — nothing here is committed work. When a command
is implemented, also update the relevant `Bridge.lua` allowlist if it routes through
an opcode.

---

## Commands CleanBot already sends

| Command | Status | Notes |
|---|---|---|
| `co +x` / `co -x` / `co ?` | ⚠️ | See "co/nc operators" below — `~` and `!` unused. |
| `nc +x` / `nc -x` / `nc ?` | ⚠️ | Same operator set as `co`. |
| `talents spec <name>` | ⚠️ | One of five `talents` sub-forms — see "talents" below. |
| `talents spec list` | ✅ | Populates the premade-spec dropdown; reply is one premade per line, `"1. arms pve (51-0-20)"` (parsed in `Bridge.lua`). |
| `sell gray` | ✅ | Inventory "Sell Trash" button. Whisper-only (not bridge-allowlisted); server only sells when a vendor NPC is in interaction range; "gray" = `ITEM_QUALITY_POOR` (quality 0). Aliases: `sell *`, short form `s`. |
| `e <link>` (equip) | ⚠️ | Resolves via `parseItems` — accepts far more than links. |
| `ue <link>` (unequip) | ✅ | |
| `u <link>` (use item) | ✅ | |
| `give <link>` | ⚠️ | `parseItems`; `give food`/`give water` are dedicated commands. |
| `items` | ⚠️ | Accepts filters (`items quest`, `items food`, by quality/name/slot). |
| `quests all` | ✅ | Whisper path sends `quests all` (bridge: `GET~QUESTS~ALL`); lists per-quest links under Incomplete/Complete headers. |
| `stats` | ⚠️ | Also carries repair cost and rest-XP we don't surface. |
| `drop <questname>` | ✅ | Abandon quest. |
| `emote <name>` | ✅ | Takes any emote token; CleanBot sends `emote wave` on bot selection (Settings-gated). |

### co / nc operators (`ChangeStrategyAction.cpp`)
Prefix operators on each strategy token:
- `+name` — add strategy
- `-name` — remove strategy
- `~name` — **toggle** (server decides on/off; avoids our read-then-set round-trip) — *unused*
- `!`     — **reset all** strategies for that state (`SelectiveResetStrategies`) — *unused; good "reset" button*
- `?`     — query active strategies (the reply CleanBot already parses)

Strategy *names* are hardcoded in `Individual/ClassData.lua`/`Individual/Strategies.lua`. The `help` command
returns the live list via `GetSupportedStrategies()` if dynamic discovery is ever wanted.
The full strategy reference — what each token does, per-class coverage, and known
conflicts — lives in [playerbot-strategies.md](playerbot-strategies.md).

### talents (`ChangeTalentsAction.cpp`)
Usage string from source:
`talents switch <1/2>, talents autopick, talents spec list, talents spec <specName>, talents apply <link>`
- `talents` (no args) — reports current spec — *unused*
- `talents switch 1` / `2` — dual-spec switch — *unused*
- `talents autopick` — auto-assign talents — *unused*
- `talents spec list` — query available spec names — ✅ used (premade-spec dropdown; fetched once per class per session, finalized on reply silence)
- `talents spec <name>` — set a named spec — ✅ used
- `talents apply <link>` — apply a full build from a talent-calculator link — *unused*

### parseItems (`InventoryAction.cpp`)
The `e` / `u` / `ue` / `give` / `items` commands all resolve targets through `parseItems`,
which accepts: item links, item IDs, item **names** (free-text), equipment **slot numbers**,
item **quality**, item class/subclass, saved **outfit names**, the count suffix `usage <n>`,
and the keywords `ammo`, `food`, `drink`, `mount`, `pet`, `recipe`, `quest`,
`healing potion`, `mana potion`, `conjured food/drink/water`.

### stats reply fields (`StatsAction.cpp`)
Order: gold (`formatMoney`), `free/total Bag`, `pct% (repairCost) Dur`, `xp%/rest% XP`.
Laced with `|c…|h|r` escape codes; bag is **free/total**. CleanBot parses gold/bag/dur/xp;
repair cost and rest-XP are present but unused.

---

## Available commands CleanBot does not use (ranked by fit)

1. **`rti <marker>`** (`RtiAction.cpp`) — sets the bot's auto-mark target
   (STAR/CIRCLE/DIAMOND/TRIANGLE/MOON/SQUARE/CROSS/SKULL, or `?` to query; `rti cc`
   for the crowd-control marker). **The `RTI` opcode is already allowlisted in
   `Bridge.lua` but no `rti` command is ever sent** — plumbing without a feature.
2. **`outfit`** (`OutfitAction.cpp`) — named gear sets. `outfit <name> +[item]` / `-[item]`
   to build, `outfit <name> equip` / `replace`, `outfit <name> update` (snapshot current
   gear), `outfit <name> reset`, `outfit ?` to list. Pairs with the equip/paperdoll panel.
3. **`reward <link>`** (`RewardAction.cpp`) — turn in a completed quest choosing that reward
   item (one link per call; no `reward all`). Pairs with the quest panel's reward display.
4. **`repair` / `repair all`** (`RepairAllAction`) — send a bot to repair. Companion to the
   durability `stats` already reports.
5. **`sell`** (`SellAction`) / **`buy`** (`BuyAction`) — vendor interactions. `sell gray` is
   now used (Sell Trash button); other `sell` forms and `buy` remain unused.
6. **`release` / `revive`** (`ReleaseSpiritAction` / `ReviveFromCorpseAction`) — death-state control.
7. **`reset`** (`ResetAiAction`) — reset the bot's AI/strategies (stronger than `co !`).
8. **Movement one-shots:** `follow`, `stay`, `guard`, `flee`, `sit`, `return`, `runaway`.

### Lower priority / situational
`mail` / `send mail` / `check mail`, `bank` / `guild bank`, `trainer` / `train`, `taxi`,
`glyphs` (`TellGlyphsAction` / `EquipGlyphsAction`), info queries `position` / `los` /
`reputation` / `emblems`, loot control `roll` + loot strategy, pet management
(`pet attack`, `set pet stance`, `toggle pet spell`), `summon` / teleport (`TeleportAction`),
and the dynamic `help` command (live command + strategy lists).

---

## Account / alt-account commands (`.playerbots account ...`)

These are **server chat dot-commands** (sent via `SendChatMessage(..., "SAY")`), not bot
action commands — they're registered in `src/Script/PlayerbotCommandScript.cpp` and handled
in `src/Bot/PlayerbotMgr.cpp`. CleanBot uses them for the Manage tab's Altbots section.

| Command | Notes |
|---|---|
| `.playerbots account setKey <key>` | Sets a security key **for the account you're logged into** (`HandleSetSecurityKeyCommand` — `accountId = session account`). Stored SHA-256-hashed in `playerbots_account_keys`. |
| `.playerbots account link <accountName> <key>` | Links another account to yours. **The key is mandatory** and is validated against the *target* account's stored key. |
| `.playerbots account linkedAccounts` | Lists linked accounts (reply header `Linked accounts:` then `- NAME` lines). |
| `.playerbots account unlink <accountName>` | Removes the link (both directions). |

**Linking requires a key — there is no keyless path** (`HandleLinkAccountCommand`):
1. The command parser rejects a missing key token → prints the `Usage:` line and aborts
   (`PlayerbotCommandScript.cpp`: `if (!accountName || !key)`).
2. The handler looks up the **target** account's row in `playerbots_account_keys`; if none
   exists (the account never ran `setKey`) it replies `Invalid security key.` and aborts.
   Otherwise it SHA-256-hashes the supplied key and compares to the stored hash.

So an alt with no security key **cannot be linked** until you log into that alt and run
`setKey`. Because `setKey` only targets the logged-in account, this is inherently a
cross-login workflow — CleanBot's link flow surfaces this as guidance when the user says they
have not set a key, showing the `setKey` command in a copyable popup (`ManageTab.lua`,
`NS.CB_ShowCopyPopup`).

---

## Source map
- Command → action registration: `src/Ai/Base/ActionContext.h`
- Strategy parsing: `src/Ai/Base/Actions/ChangeStrategyAction.cpp`
- Talents: `src/Ai/Base/Actions/ChangeTalentsAction.cpp`
- Item resolution / `items`: `src/Ai/Base/Actions/InventoryAction.cpp`
- `stats`: `src/Ai/Base/Actions/StatsAction.cpp`
- `rti`: `src/Ai/Base/Actions/RtiAction.cpp`
- `outfit`: `src/Ai/Base/Actions/OutfitAction.cpp`
- `reward`: `src/Ai/Base/Actions/RewardAction.cpp`
- `quests`: `src/Ai/Base/Actions/ListQuestsActions.cpp`
- `account` dot-commands: `src/Script/PlayerbotCommandScript.cpp` (parsing) +
  `src/Bot/PlayerbotMgr.cpp` (`HandleSetSecurityKeyCommand` / `HandleLinkAccountCommand` /
  `HandleViewLinkedAccountsCommand` / `HandleUnlinkAccountCommand`)
- Bridge allowlists / opcodes: `Bridge.lua` (mirrors `MultiBotBridge.cpp`)
