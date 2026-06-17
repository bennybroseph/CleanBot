# Settings

The **Settings** tab has four sub-tabs: **Theme**, **Layout**, **Other**, and **Debug**.

## Theme

Appearance of the CleanBot window:

- **Scale** — overall size.
- **Transparency** — background opacity.
- **Accent Color** — the highlight color used throughout.

If you have **ElvUI** installed, CleanBot automatically matches its skin — no setting needed.

## Layout

Fine-grained spacing controls (the padding and margins around panels, headers, buttons, and
other widgets), with a **Show Sample Layout** preview. Changes apply live. This is purely
cosmetic — leave it alone unless you want to tweak the spacing.

## Other

### Behavior

- **Enable Bot Emotes** — a bot waves when you switch to its tab.
- **Auto-Enable Self as Bot** — run your own character as a bot each time you log in.
- **Enable Item Glow** — rarity-colored glow on uncommon-or-better items (shown only without
  ElvUI, which has its own quality borders).
- **Hide Bot Chatter** — keeps CleanBot's own command whispers, the bot replies it requests, and
  the server output it triggers out of your chat window. Turn it **off** if you want to see the
  raw traffic.

### Dungeon Finder

- **Show Recruiter Tab** — attaches a bot-recruiter tab to the Dungeon Finder window for summoning
  a level-matched bot by role and class. See
  [Managing Bots](managing-bots.md#recruit-from-the-dungeon-finder).

### Action Bar

- **Show Action Bar** and **Action Bar Edit Mode** — same toggles as the minimap right-click.
- **Customize** — show/hide individual bar buttons and flyout options. See
  [Action Bar](action-bar.md).

## Debug

Hidden by default. Type `/cbdebug enable` to reveal it. These are developer diagnostics
(bridge override, simulate mode, timing, the icon browser) — see [Debug Tools](debug-tools.md).
