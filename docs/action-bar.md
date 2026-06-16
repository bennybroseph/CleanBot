# Action Bar

The Action Bar is a small floating bar of one-click bot commands you can keep on screen during
play — no need to open the main window. Every button commands your **whole party/raid** at once.

## Showing & moving it

- **Show/hide:** right-click the minimap button, or toggle *Show Action Bar* in
  [Settings](settings.md) → Action Bar. Its visibility is remembered between sessions.
- **Move it:** enter **edit mode** (shift + right-click the minimap, or *Action Bar Edit Mode*
  in Settings), then drag the bar. Edit mode always turns off again when you log out.

## The buttons

| Button | What it does |
|---|---|
| **Summon** | Summons your bots to you. |
| **Attack** | Orders bots to attack your current target. |
| **Pull** | Orders your **tank** bots to pull your target. |
| **Passive** | Toggles bots between fighting and standing down. |
| **Movement** | Sets how bots move: **Follow**, **Stay**, or **Runaway**. |
| **Release** | **Release** a dead bot's spirit, or **Revive** it at the spirit healer. |

Some buttons are **flyouts** (Attack, Movement, Release). A flyout button does its main action
on **left-click**, and reveals more options when you **hover** it — or **right-click** to pin it
open. For example, Attack expands to target only your **Tanks**, **Healers**, **DPS**, **Melee**,
or **Ranged**.

The Movement buttons light up to show the current mode (combat vs. non-combat is chosen
automatically based on whether *you* are in combat). **Runaway** is temporary — your bots return
to their previous combat movement when the fight ends.

## Editing the bar (edit mode)

In edit mode the buttons stop working and a small config panel appears next to the bar:

- **Drag the bar** anywhere. It **snaps** to nearby UI frames and shows the frame it will anchor
  to, so the bar stays put relative to that frame even if you move it later. (Snapping can be
  turned off with the checkbox in the config panel.)
- **Anchor From** — which corner of the bar stays pinned.
- **Grow Direction** — which way the bar extends as buttons are added (right, left, up, down).
- **X / Y** boxes and the four **nudge** arrows fine-tune the position one pixel at a time.
- **Done** leaves edit mode.

## Rearranging & customizing buttons

- **Reorder:** hold **Shift** and drag a button along the bar to move it. You can even drag an
  item **out of a flyout** to make it the main button (and the old main drops into the flyout).
- **Show/hide buttons:** open [Settings](settings.md) → Action Bar → **Customize**. Each button
  has a checkbox; flyouts also list a checkbox per option. The list always matches your current
  bar order.
