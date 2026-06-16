# Playerbot Command Survey

Human-readable companion to the bridge allowlists in `Bridge.lua` (the addon-message
protocol itself is documented in [bridge-protocol.md](bridge-protocol.md)). The official
[Playerbot Commands wiki](https://github.com/mod-playerbots/mod-playerbots/wiki/Playerbot-Commands)
is sparse, so this captures what was learned by reading the mod-playerbots action
source directly (`src/Ai/Base/Actions/*.cpp`, `src/Ai/Base/ChatActionContext.h`, and
`src/Ai/Base/Strategy/ChatCommandHandlerStrategy.cpp`).

**Status legend:** ✅ used by CleanBot · ⚠️ used but only partially · ⬜ available, unused.

This is a reference, not a roadmap — nothing here is committed work. When a command
is implemented, also update the relevant `Bridge.lua` allowlist if it routes through
an opcode.

---

## ⚠️ Chat commands are TRIGGERS, not action names (read this first)

A bot command you whisper is matched by **trigger name**, which is NOT always the same as
the **action name** in the source. Getting this wrong silently misfires (see the `sell` story
below). There are two registries:

- **Action name** — `ChatActionContext.h`: `creators["sell"] = … SellAction`. This only *names*
  the action `sell` internally. It does **not** make `sell` a thing you can type.
- **Chat trigger** — `ChatCommandHandlerStrategy.cpp`, two sources:
  1. `InitTriggers()` `TriggerNode("<trigger>", { NextAction("<action>") })` — trigger ≠ action
     (e.g. `s`→sell, `e`→equip, `ue`→unequip, `u`→use, `t`→trade, `b`→buy, `r`→reward,
     `c`/`items`/`inv`→item count, `q`→query quest).
  2. The `supported` vector — entries where **trigger name == action name** (e.g. `co`, `nc`,
     `talents`, `quests`, `stats`, `drop`, `emote`, `wait for attack time`, `ll`, `repair`, …).

A whisper that matches **no** trigger falls through to an item-mention auto-trade
(`AiPlayerbot.EnableAutoTradeOnItemMention`, default **1**): the text is fed to the `c` and `t`
(trade) actions, so any item link or quality keyword in it makes the bot **open a trade**. That
is exactly why `sell gray` (no `sell` trigger) opened a trade on the `gray` keyword instead of
vendor-selling — and it's also the *only* reason our `give <link>` works (there is no `give`
command; the item link triggers the auto-trade).

**Rule: before using/adding a bot command, confirm the exact TRIGGER in
`ChatCommandHandlerStrategy.cpp` (a `TriggerNode` name or a `supported` entry) — not just the
action name in `ChatActionContext.h`.**

### Audit — every command CleanBot sends, verified against the trigger registry

| What CleanBot sends | Trigger | Where registered | OK? |
|---|---|---|---|
| `co …` / `nc …` | `co` / `nc` | `supported` | ✅ |
| `talents spec list` / `talents spec <name>` | `talents` | `supported` | ✅ |
| `items` | `items` | `TriggerNode("items")` → item count | ✅ |
| `quests all` | `quests` | `supported` | ✅ |
| `stats` | `stats` | `supported` | ✅ |
| `drop <quest>` | `drop` | `supported` | ✅ |
| `emote wave` | `emote` | `supported` | ✅ |
| `wait for attack time <N>` | `wait for attack time` | `supported` | ✅ |
| `e <link>` / `ue <link>` / `u <link>` | `e` / `ue` / `u` | `TriggerNode(...)` | ✅ |
| `s gray` | `s` | `TriggerNode("s")` → sell | ✅ (was `sell gray` — wrong, fixed) |
| `t <link>` (drag-to-trade) | `t` | `TriggerNode("t")` → trade | ✅ (was `give <link>` — relied on the auto-trade fallback; now the real `t` command) |
| `bank` / `bank <link>` / `bank -<link>` | `bank` | `ChatTriggerContext` `creators["bank"]` | ✅ (list / deposit / withdraw — see Bank below) |
| `formation <name>` | `formation` | `supported` | ✅ (Commands tab + Manage Party/Raid — see "Commands already sends") |
| `autogear` | `autogear` | `supported` | ✅ ("Auto Gear" button — see "Commands already sends") |
| `ll <mode>` / `ll ?` | `ll` | `supported` | ✅ ("Loot Quality" dropdown, Non-Combat tab — see "Commands already sends") |
| `equip upgrade` | `equip upgrade` | `supported` | ✅ ("Auto-Equip" button — see "Commands already sends") |
| `roll` | `roll` | `supported` | ✅ ("Roll" button — see "Commands already sends") |
| `summon` | `summon` | `supported` | ✅ (Action Bar "Summon" button + unit right-click menu) |
| `do attack my target` (+`@tank`/`@heal`/`@dps`/`@melee`/`@ranged`) | `do` | `PlayerbotAI::HandleCommand` — `do <action>` → `DoSpecificAction` | ✅ (Action Bar "Attack" flyout) |
| `pull my target` | `pull` | `TriggerNode("pull")` → `pull my target` action | ✅ (Action Bar "Pull" button) |
| `release` | `release` | `supported` | ✅ (Action Bar "Release" flyout) |
| `revive` | `revive` | `TriggerNode("revive")` → `spirit healer` action | ✅ (Action Bar "Release" flyout) |

---

## Commands CleanBot already sends

| Command | Status | Notes |
|---|---|---|
| `co +x` / `co -x` / `co ?` | ⚠️ | See "co/nc operators" below — `~` and `!` unused. |
| `nc +x` / `nc -x` / `nc ?` | ⚠️ | Same operator set as `co`. |
| `talents spec <name>` | ⚠️ | One of five `talents` sub-forms — see "talents" below. |
| `talents spec list` | ✅ | Populates the premade-spec dropdown; reply is one premade per line, `"1. arms pve (51-0-20)"` (parsed in `Bridge.lua`). |
| `s gray` | ✅ | Inventory "Sell Trash" button. **The trigger is `s`, not `sell`** — `ChatCommandHandlerStrategy` registers `TriggerNode("s") → SellAction`; there is NO `sell` trigger. Whispering `sell gray` matches no command and (with `enableAutoTradeOnItemMention`) makes the bot open a *trade* on the "gray" keyword instead of vendor-selling. Whisper-only (not bridge-allowlisted); sells only when a vendor NPC is in interaction range; "gray" = `ITEM_QUALITY_POOR` (quality 0). Params: `s gray` / `s *` / `s vendor` / `s <itemlink>`. |
| `e <link>` (equip) | ⚠️ | Resolves via `parseItems` — accepts far more than links. |
| `ue <link>` (unequip) | ✅ | |
| `u <link>` (use item) | ✅ | |
| `t <link>` | ✅ | Trade command (`TriggerNode("t")` → `TradeAction`); toggles the item in the bot's trade window. Used by the drag-to-trade / right-click-remove flow. (We previously sent `give <link>`, which is **not** a real command and only worked via the item-mention auto-trade fallback — switched to `t` for robustness.) |
| `items` | ⚠️ | Accepts filters (`items quest`, `items food`, by quality/name/slot). |
| `bank` | ✅ | Bank window. **Whisper-only — there is NO bridge `GET~BANK` packet** (unlike `items`). `bank` (or `bank ?`) lists the bot's bank: reply opens with `=== Bank ===` then item lines in the **same `TellItems` format** as `items` (parsed by the same header-routed staging branch in `Bridge.lua`). The reply carries **no money/slot-count summary**. `bank <itemlink>` deposits (bags→bank), `bank -<itemlink>` withdraws (bank→bags). All three forms share trigger `bank` (`BankAction`) and **require a banker NPC in interaction range** — otherwise the bot whispers `"Cannot find banker nearby"` and does nothing (CleanBot surfaces this as the `CLEANBOT_NO_BANKER` popup). |
| `quests all` | ✅ | Whisper path sends `quests all` (bridge: `GET~QUESTS~ALL`); lists per-quest links under Incomplete/Complete headers. |
| `stats` | ⚠️ | Also carries repair cost and rest-XP we don't surface. |
| `drop <questname>` | ✅ | Abandon quest. |
| `emote <name>` | ✅ | Takes any emote token; CleanBot sends `emote wave` on bot selection (Settings-gated). |
| `autogear` | ✅ | "Auto Gear" button in the "Commands" inner tab (Individual + Group) and Manage → Party/Raid, **gated behind a Yes/No confirmation popup** (destructive: replaces all equipment). Auto-equips a fresh gear set for the bot. **Arguments — the `supported` vector registers exactly two forms** (each a distinct action class), so these are the *only* recognized forms: `autogear` (no args → `AutoGearAction`, what the button sends) and `autogear bis` (→ `BisGearAction`, best-in-slot). `autogear` takes no further arguments. (Related but separate: `equip upgrade` equips inventory upgrades only.) Whisper-only (not bridge-allowlisted); reply hidden by the reply window. Per-host scope matches the rest of the set: Individual → open bot; Group → selected members (fan-out); Manage → whole party/raid broadcast. NOTE: `AutoGearAction`/`BisGearAction` are bundled in an unpinned header, so the precise gear source/level of plain `autogear` vs `bis` is unverified from source — confirm in-game. |
| `formation <name>` | ✅ | "Commands" inner tab (Individual + Group) and Manage → Party/Raid. Sets the bot's movement formation (`SetFormationAction`, `src/Ai/Base/Value/Formations.cpp`; trigger `formation` in the `supported` vector). Whisper-only (not bridge-allowlisted). Per-host scope mirrors the rest of that command set: Individual → the open bot; Group → the selected group's members (fan-out); Manage → broadcast to the whole party/raid. Valid tokens (lowercase): `chaos` (default), `near`, `queue`, `circle`, `line`, `shield`, `arrow`, `melee`, `far` — the dropdown shows them title-cased and sends the lowercase token. **Query:** `formation ?` (or no arg) whispers back `Formation: <name>` (the current formation), parsed in `Bridge.lua` into `entry.formation` and reflected in the dropdown on bot/group selection. Replies go via `TellMaster` (whisper), so they're hidden by the reply-window filter on the per-bot paths; the Manage broadcast opens a reply window per bot to hide them too. |
| `ll <mode>` / `ll ?` | ✅ | "Loot Quality" dropdown (Non-Combat tab, Individual + Group). `LootStrategyAction` (modes in `src/Ai/Base/Value/LootStrategyValue.h`); trigger `ll` in `supported`. The bot's loot-quality policy — exclusive, one strategy at a time. **Default: `normal`** (`LootStrategyValue` is a `ManualSetValue<LootStrategy*>` seeded with `normal`). Modes (verified from each strategy's `CanLoot()` in `LootStrategyValue.cpp` + `ItemUsageValue::Calculate`): **`normal`** = items with a non-`NONE` `ItemUsage` — note a gray item with a sell price resolves to `ITEM_USAGE_VENDOR`, so **`normal` DOES loot gray vendor-trash**; it skips only truly no-value items; **`gray`** = `normal` **+** all poor-quality items (incl. zero-sell-value grays `normal` skips); **`all`** = everything (`CanLoot` returns true); **`disenchant`** = `normal` **+** uncommon-or-better, non-bind-on-pickup weapons/armor (disenchantable). **Query:** `ll ?` whispers back `Loot strategy: <mode>` (plus an `Always loot items: …` list), parsed in `Bridge.lua` into `entry.lootStrategy` and reflected in the dropdown (Group shows "Mixed" when members differ). Modeled like `formation` (a `?`-queried command **setting**, not an `nc` strategy) — a `type="settingDropdown"` group in `NS.NC_STRATEGIES`. Whisper-only (not bridge-allowlisted); per-host scope: Individual → open bot, Group → selected members (fan-out). `ll <itemlink>` / `ll -<itemlink>` manage a per-item **always-loot list** — *not surfaced*. (`loot`, the auto-loot on/off strategy, is the separate "Auto Loot" `nc` checkbox.) |
| `equip upgrade` | ✅ | "Auto-Equip" button (Commands inner tab + Manage → Party/Raid). `EquipUpgradeAction`; trigger `equip upgrade` in `supported`. Scans the bot's bags and equips stat **upgrades** — non-destructive (only swaps in improvements), so **no confirmation**, unlike `autogear` (which re-gears wholesale). Whisper-only; per-host scope matches the rest of the command set. |
| `roll` | ✅ | "Roll" button (Commands inner tab + Manage → Party/Raid). `LootRollAction`; trigger `roll` in `supported`. **Bare `roll` → `bot->DoRandomRoll(0,100)`** — the bot does a `/random 0-100` (e.g. for manual loot distribution). `roll <itemlink>` instead makes an item-usage need/greed decision on that item — *not surfaced* (the button sends bare `roll`). Whisper-only. |
| `summon` | ✅ | **Action Bar "Summon" button** (+ the unit right-click menu's "Summon", `UnitMenu.lua`). `summon` is in `supported` (`SummonAction`) — teleports the bot to you. The Action Bar path broadcasts via `CB_SendGroupCommand` (whole group); the unit-menu path whispers a single bot. Whisper-only (not bridge-allowlisted). |
| `do attack my target` | ✅ | **Action Bar "Attack" flyout.** Uses the `do <action>` command (`PlayerbotAI::HandleCommand` strips `do `/`d ` and calls `DoSpecificAction`), which force-runs a named action directly, bypassing trigger relevance — here the `attack my target` action (the same action the bare `attack` and tank-only `tank attack` triggers map to). The flyout's role variants prepend an `@` qualifier: the base = **no `@`** (whole group), then `@tank` / `@heal` / `@dps` / `@melee` / `@ranged`. Broadcast to the group (`CB_SendGroupCommand` → PARTY/RAID), so one message reaches every bot and the `@` filter (see "Command targeting") selects who reacts. Whisper-only path is never taken (group broadcast). |
| `pull my target` | ✅ | **Action Bar "Pull" button.** `TriggerNode("pull")` → `pull my target` action. The bot's class `pull` strategy + PullMultiplier drive the actual pull (auto-selects the equipped ranged-weapon shot; PullMultiplier vetoes everything else mid-pull) — see playerbot-strategies.md. `pull` is **class-gated** (no Hunter/Shaman `pull` token — see the class matrix), so only bots that registered it react. Broadcast via `CB_SendGroupCommand`. (`pull back` and `pull rti` triggers also map to pull actions — unused; the `RTI` opcode's `pull rti target` is allowlist plumbing only.) |
| `release` / `revive` | ✅ | **Action Bar "Release" flyout** — death-state control. `release` (`supported`; `ReleaseSpiritAction`) releases a dead bot's spirit (it becomes a ghost). `revive` (`TriggerNode("revive")` → the **`spirit healer`** action — *not* `ReviveFromCorpseAction`) brings a released bot back at the nearest spirit healer. Both broadcast via `CB_SendGroupCommand`. |

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

### Command targeting — `@` qualifiers (`src/Bot/Cmd/ChatFilter.cpp`)

A command may lead with one or more `@…` qualifiers that restrict **which** of your bots react,
e.g. `@tank co +passive`, `@melee @warrior s gray`. Source: `CompositeChatFilter` runs each filter
in turn — a filter returns `""` (this bot ignores the command) or strips its leading `@token ` and
passes the rest on. So qualifiers **chain (logical AND)**, and they apply to **whispers and
party/raid chat alike** (the filter runs in `PlayerbotAI::HandleCommand` for every channel).

The role checks `IsTank`/`IsHeal`/`IsDps` default to `bySpec=false`, which reads
`ContainsStrategy(STRATEGY_TYPE_*)` — the bot's **active strategy**, not its talent spec.

| Qualifier | Matches bots where… | Filter class |
|-----------|---------------------|--------------|
| `@tank` | tank strategy active | StrategyChatFilter |
| `@heal` | heal strategy active | StrategyChatFilter |
| `@dps` | not tank and not heal | StrategyChatFilter |
| `@ranged` / `@melee` | `IsRanged` (strategy) **and** class allows ranged/melee | Strategy + CombatType |
| `@rangeddps` / `@meleedps` | ranged/melee **and** not tank/heal | StrategyChatFilter |
| `@<class>` | `@dk @druid @hunter @mage @paladin @priest @rogue @shaman @warlock @warrior` | ClassChatFilter |
| `@<n>` / `@<from>-<to>` | bot level == n / within range | LevelChatFilter |
| `@group<list>` | bot's raid subgroup ∈ list (`@group1`, `@group1,3`, `@group1-2`) | SubGroupChatFilter |
| `@<spec>` | `@arms @fury @frost @bear @cat @bdkt @bdkd …` (spec-tab, druid/DK by role) | SpecChatFilter |
| `@star`…`@skull` | bot **is** that raid-target-icon, or its current target is | RtiChatFilter |
| `@aura<id>` / `@noaura<id>` | bot has / lacks that aura | AuraChatFilter |
| `@aggroby<id\|"name">` | bot is currently aggroed by that creature | AggroByChatFilter |

CombatType's class rule (used for `@melee`/`@ranged`): war/pal/rogue/dk = melee; hunter/priest/
mage/warlock = ranged; druid = melee if tank else ranged; shaman = ranged if heal else melee.

**CleanBot overhearing** (`Overhear.lua`) mirrors the families it can evaluate from cached state +
live unit info — **role, class, melee/ranged, level, subgroup**. The server-only families
(`@<spec>`, `@aura`/`@noaura`, `@aggroby`, RTI `@star…@skull`) and any unrecognized `@token` cause
the overheard command to be **skipped** (not applied to anyone) rather than mis-targeted; the next
authoritative sync reconciles. `@melee`/`@ranged` use the deterministic class+role rule above as a
close approximation of the server's strategy-based `IsRanged`.

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
5. **`s`** (`SellAction`) / **`b`** (`BuyAction`) — vendor interactions (triggers are the short
   forms `s`/`b`, not `sell`/`buy`). `s gray` is used (Sell Trash button); other `s` forms and
   `b` remain unused.
6. **`reset`** (`ResetAiAction`) — reset the bot's AI/strategies (stronger than `co !`).
7. **`go <arg>`** (`GoAction.cpp`) — parameterized movement (see the `go` subsection below).
   Most relevant form: **`go <unit name>` walks the bot to a nearby matching NPC/player by
   name** — e.g. stepping a bot onto a **banker** so the `bank` commands pass their proximity
   check. (Bounded by the bot's search range — it's the last-leg positioner, not a long-haul
   travel; pair with `summon`/`follow` to get the bot into the area first.)
8. **Movement one-shot triggers:** `follow`, `stay`, `guard`, `flee`, `sit`, `return`, `runaway`
   (TriggerNodes → `"<name> chat shortcut"`). **Unused by CleanBot** — the Action Bar's Movement
   flyout (Follow / Stay / Runaway) instead drives the *persistent* **movement strategies** via
   `co`/`nc` (the exclusive movement group), not these one-shot shortcuts. Note `flee` ≠ `runaway`:
   `flee` (`FleeAction`) is a single `MoveAway` straight from the current target and only fires when
   that target is in **melee range**; `runaway` (`RunAwayAction` → `Flee`) repositions near a friendly
   or to `FleeManager`'s optimal max-distance point. Both are one `MoveTo` per call (no loop) — see
   `playerbot-strategies.md` → "Movement modes" for the source-verified breakdown.

### Lower priority / situational
`mail` / `send mail` / `check mail`, `bank` / `guild bank`, `trainer` / `train`, `taxi`,
`glyphs` (`TellGlyphsAction` / `EquipGlyphsAction`), info queries `position` / `los` /
`reputation` / `emblems`, pet management
(`pet attack`, `set pet stance`, `toggle pet spell`), `teleport` (`TeleportAction`),
and the dynamic `help` command (live command + strategy lists). (`summon` is **used** — see
"Commands CleanBot already sends".)

### go — move to a unit / object / coordinates (`GoAction.cpp`)
Trigger `go` — confirmed in the `supported` vector (trigger == action; action name is `"Go"`).
Whisper-only; **not** bridge-allowlisted. Forms parsed by `GoAction::Execute`:
- **`go <unit name>`** — matches the **nearest NPC or friendly player** by case-insensitive
  name substring (`strstri`) and walks to it. Bounded by the bot's search range (roughly its
  visibility radius) — the unit must already be reasonably near, so this positions a bot the
  *last leg*, not across a zone. **Bank use:** get the bot to the bank vicinity first
  (`summon` / `follow`), then `go <bankerName>` to step it onto the banker so the `bank`
  commands satisfy their "banker NPC in range" check.
- `go x,y` — zone coordinates (validates terrain/water/height, then pathfinds).
- `go x;y;z` — raw map coordinates.
- `go [game object]` — move to a spawned game object (by link/GUID) within reaction distance.
- `go position` — move to a saved named position from context.
- `go travel <destination>` — hands off to the travel-target system (`ChooseTravelTargetAction`).
- `go ?` — reply with the bot's current coordinates.
- (no recognized arg) — help reply: *"Whisper 'go x,y', 'go [game object]', 'go unit' or 'go position' and I will go there"*.

Other movement triggers seen in the registry, for reference: one-shots `follow` / `stay` /
`flee` / `move from group` (TriggerNodes → `"<name> chat shortcut"`), and `supported` entries
`summon`, `teleport`, `taxi`, `position`, `leave`, `formation`. None are verified beyond their
presence in the trigger registry.

---

## Item transfer between bots / to the player

How items actually move out of a bot, and the constraints — relevant if a bot-to-bot
inventory-trading feature is ever added.

| Mechanism | Source | Direction | Immediate? | Notes |
|---|---|---|---|---|
| **Trade** — `t <link>` / `nt <link>` | `TradeAction.cpp` | bot ↔ player, bot ↔ bot | No (UI + accept) | Trigger is `t` (`nt` = non-traded slot). `TradeAction` opens a trade with the master/group member if one isn't open, then toggles the item in the bot's trade slots (re-send removes). This is what CleanBot's drag-to-trade uses. |
| **Auto-accept** | `TradeStatusAction.cpp` | — | — | When the *other* side clicks Accept, the bot runs `CheckTrade()` and auto-accepts (`HandleAcceptTradeOpcode`). **Your own bots give for free** (the non-random-account path returns `true` regardless of money); **random/server bots want money or a discount** (`CheckTrade` cost logic). So a player receiving from their own bot is effectively a single Accept click. |
| **Direct give** — `GiveItemAction` | `GiveItemAction.cpp` | **bot → bot only** | **Yes** (no trade window) | `MoveItemFromInventory` → `MoveItemToInventory`, instant. **Hard constraint:** the receiver must be a playerbot (`GET_PLAYERBOT_AI(receiver)` must be non-null) — a real player can never receive this way. **Not whisper-invokable:** it's an autonomous action whose target is the AI value `"party member without item"` (also `GiveFoodAction` / `GiveWaterAction` for `"party member without food/water"`). It fires from RPG/idle triggers, not a chat command. |
| **Mail** — `mail` / `sendmail` | mail actions | bot → anyone | No (mailbox + delay) | Goes through the mail system; not immediate. |

**Takeaways for a future bot-to-bot trade feature:**
- There is **no command to instantly give an item to the *player*** — player-bound transfers go
  through trade (auto-accepted by your own bots) or mail. An instant move into a real player's
  bags would be a GM-level action the module only does bot→bot.
- The instant bot→bot path (`GiveItemAction`) exists but is **autonomous and not commandable**,
  and only targets a bot lacking the item. To drive bot→bot transfers on demand you'd most
  likely orchestrate the **trade** flow between two bots (both sides are playerbots, so
  `TradeStatusAction` auto-accepts), rather than rely on `GiveItemAction`.
- As always, the command word is the **trigger** (`t`), not the action name — see the triggers
  vs. actions note above.

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
- Chat **triggers** (trigger ≠ action; `attack`/`pull`/`release`/`revive`/`follow`/… + the
  `supported` vector): `src/Ai/Base/Strategy/ChatCommandHandlerStrategy.cpp`
- Command dispatch + the `do <action>` / `d <action>` force-run (`DoSpecificAction`):
  `src/Bot/PlayerbotAI.cpp` (`PlayerbotAI::HandleCommand`)
- Strategy parsing: `src/Ai/Base/Actions/ChangeStrategyAction.cpp`
- Talents: `src/Ai/Base/Actions/ChangeTalentsAction.cpp`
- Item resolution / `items`: `src/Ai/Base/Actions/InventoryAction.cpp`
- `stats`: `src/Ai/Base/Actions/StatsAction.cpp`
- `rti`: `src/Ai/Base/Actions/RtiAction.cpp`
- `go` / movement-to-target: `src/Ai/Base/Actions/GoAction.cpp`
- `outfit`: `src/Ai/Base/Actions/OutfitAction.cpp`
- `reward`: `src/Ai/Base/Actions/RewardAction.cpp`
- `quests`: `src/Ai/Base/Actions/ListQuestsActions.cpp`
- `account` dot-commands: `src/Script/PlayerbotCommandScript.cpp` (parsing) +
  `src/Bot/PlayerbotMgr.cpp` (`HandleSetSecurityKeyCommand` / `HandleLinkAccountCommand` /
  `HandleViewLinkedAccountsCommand` / `HandleUnlinkAccountCommand`)
- Bridge allowlists / opcodes: `Bridge.lua` (mirrors `MultiBotBridge.cpp`)
