# Bot Behavior

You decide how your bots fight, move, and look after themselves. Set it for **one bot** on the
**Individual** tab, or for **everyone at once** on the **Group** tab. Both lay the options out the
same way, across a few inner tabs.

Changes are sent to the bot immediately, and the controls reflect each bot's real, current state.

## Commands

Quick one-shot actions and settings: **Summon**, **Passive** (stand down), **Formation** (how the
group arranges itself), talent **spec**, and the gear buttons (**Auto Gear**, **Auto-Equip**,
**Roll**). Several of these are also on the [Action Bar](action-bar.md) and the
[Manage](managing-bots.md) tab.

## Combat

How a bot behaves in a fight:

- **Role** — *Tank*, *Healer*, or *DPS* (some classes also offer *Off-Heal*). This picks the
  bot's rotation; CleanBot only shows the roles a class can actually fill.
- **Assist Target** — who the bot focuses: *Single Target*, *AoE*, or *Tank / Peel*.
- **Distance** — *Close* (melee) or *Ranged* (caster) engagement.
- **Rotation** — *AoE* (cleave) vs. *Focus Fire* (single target) vs. *Standard*.
- **Kite**, **Aggressive**, **Avoid Aggro** — movement and threat behavior.
- **Combat Movement** — Follow / Stay / Guard / Runaway while fighting.
- Upkeep toggles — **Use Cooldowns**, **Use Potions**, **Use Racials**, **Smart Cast Time** — and
  a **wait-for-attack** timer (hold fire for N seconds after combat starts).

## Non-Combat

How a bot behaves out of combat:

- **Movement** — Follow you, Stay put, Guard a spot, and so on.
- **Eat & Drink**, **Auto Loot**, **Auto Gather**, **Enable PvP**.
- **Loot Quality** — how picky the bot is about what it loots.
- Class buffs and other self-maintenance.

## Class tab

A fourth tab named after the bot's class holds class-specific options — totems, blessings and
auras, curses, pet control, stealth, traps, and the like.

## Want the full list?

These tabs cover the common controls in plain language. For the exhaustive, source-verified
reference — every strategy token, what it does, per-class coverage, and conflicts — see
[Playerbot Strategies](playerbot-strategies.md) and [Playerbot Commands](playerbot-commands.md).
