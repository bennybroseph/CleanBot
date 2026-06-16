# Managing Bots

The **Manage** tab is where you build and run your group — bringing bots online, inviting them,
summoning them, and saving them into reusable presets. Commands here apply to your whole
party/raid.

## Bringing bots in and out

- **Invite by Name** — type a bot's name to invite it to your group.
- **Target** section — act on your current target or the whole group:
  - **Invite / Uninvite Target**, **Uninvite All** — group membership.
  - **Login / Logout Target**, **Logout All** — spawn or despawn bot characters in the world
    (uses the server's `.playerbots bot add/remove`).

## Party/Raid commands

The **Party/Raid** section has buttons that broadcast to every bot at once — Summon, Eat &
Drink, Revive, Release, Maintenance, set **Formation**, toggle **Passive**, and the gear actions
(**Auto Gear**, **Auto-Equip**, **Roll**). The same command set appears on the
[Individual and Group](bot-behavior.md) tabs when you want to target one bot or all of them
deliberately.

> **Auto Gear** re-gears a bot from scratch and asks for confirmation first, since it replaces
> everything. **Auto-Equip** only swaps in upgrades it finds in the bot's bags.

## Favorites & Presets

Save named groups of bots and invite them in one click:

- The **Favorites** preset is filled by the ★ star buttons on the [Individual](bot-behavior.md)
  tab and can't be renamed or removed.
- Create your own presets, add/remove bots, then **Invite Preset** to pull the whole roster in.

## Altbots (linking other accounts)

The **Altbots** section lets you use characters on your *other* accounts as bots. Linking
requires a security key:

1. Log into the alt account and set a key (CleanBot shows you the exact command in a copyable
   popup).
2. Back on your main, link the account with that key.

Once linked, those characters are available to invite and command like any other bot.

## The right-click menu

Right-click any bot in your **party/raid frames** for quick actions without opening the window:

- **Summon** — bring it to you.
- **Manage** — jump to that bot on the Individual tab.
- **Inventory** — open its [bags](gear-and-bags.md).
- **Quest Log** — open its [quests](gear-and-bags.md).
