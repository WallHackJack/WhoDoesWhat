# Changelog

The same releases the About window shows, for reading outside the game. The
list the window draws lives in [Releases.lua](Releases.lua); update both when
cutting a tag.

## 2.0.1 — 2026-09-16

- Buff Checklist: armor swappers for mages and warlocks, a warlock demon
  swapper, mana gems with cooldowns and self-buff reminders. Weapons show their
  actual enchant and suggest sharpening stones or weightstones to match.
- Buff Checklist: Roomy, Snug and Compact spacing, an optional "From Others"
  line, and Shift-Right-Click anywhere to open settings.
- Buffs are tracked by spell id rather than English names, so non-English
  clients work; food, Windfury and weapon enchants are matched by id, and Era
  gets an alcohol slot.
- Fixes: dropdown menus stay open while views refresh, scrolls are cast on you
  instead of your target, tooltips no longer cover pop-outs, and pickers fill in
  once item names load.

## 2.0.0 — 2026-09-15

- WhoDoesWhat is one tabbed window now: Members, Blessings, Assignments, Buff
  Grid, Calculator and Settings. The old separate windows and toolbar are gone.
- A new navy-and-gold look across the main window and every bar.
- Blizzard's Raid tab shows each member's role in place of level and class.
- Blessings get their own tab, with PallyPower differences in plain view.
- Added the Buff Checklist (Beta): every buff your character should have, from
  blessings to weapon enchants. Pick consumables from your bags even in combat,
  swap auras and aspects, and keep your hunter pet buffed.
- Battle Elixir and Guardian Elixir status rows on TBC; a flask fills both.
- The Curse Calculator has been updated and moved to its own tab.
- Settings are split into tabs, each with its own Reset Defaults. Roles moved in
  as a tab, and a buff's options open beside the table.
- Drag rows to reorder buff lists.
- The Paladin Bar and Warrior Shout Bar each get an icon size, glow style and
  glow colours.
- The Warrior Shout Bar keeps separate settings for non-warriors, who click a
  shout to ask for it in party chat. New: hide when I have it, hide coverage
  numbers, and a countdown timer.
- Raid frame role icons can be outlined in tank, healer and DPS colours.
- Food whispers say whether a hunter or their pet is unfed, and whispers and
  announces rescan first. Announces only name buffers when talents narrow it
  down.
- Healthstone tooltips name the warlocks who can make you one.
- Saving a raid role pushes its blessings to PallyPower right away.
- Shift-Right-Click the PallyPower status row to open its blessings window.
- No more popup when the leader's board replaces yours on joining. Thorns is off
  the Buff Grid by default.
- WoW Forever is treated as Classic Era without buff talents.

## 1.2.0 — 2026-09-08

- Added the Warrior Shout Bar: one clickable icon per shout, counts relevant
  party members. Added "melee" hunter role.
- The Paladin Bar can stand up as a vertical column, with per-class expiry
  countdowns, an aura picker that casts, and an alt-right-click switch that
  hands the raid over to PallyPower.
- WhoDoesWhat roles can be drawn on Blizzard's raid frames, in five styles from
  a round replacement icon to a faded band down the health bar.
- Shift-left-click a status bar to whisper whoever can fix it — the paladins,
  the priests, or everyone still needing to eat.
- Status bar announces and whispers now count forwards, name the stragglers only
  while there are few of them, and are signed like every other message the addon
  sends.
- Status bar rows glow in a highlight style of your choosing, in a color of your
  choosing, with a live preview in the settings.
- Divine Spirit is tracked on TBC, including who can cast it at all and who
  would have to respec first.
- Buffs cast by somebody outside the raid are counted as missing, and named
  separately in the tooltip.
- Hunter pets are matched for blessings across every paladin rather than the
  leftovers, and a Steam Tonk is no longer mistaken for one.
- Paladin Trash Tank is now Threat Tank, and the Arms and Enhancement icons were
  refreshed.

## 1.1.0 — 2026-08-20

- Shift-right-click a status bar to announce who is still missing that buff in
  raid chat; editing moved to alt-right-click.
- Action Items folded into the Members window: roles, talents, and what needs
  fixing in one place.
- Ignore a blessing for part of the raid — "Sanctuary except for Tanks" is now
  one rule.
- A paladin running without PallyPower announces themselves to it, so they can
  be given assignments.
- Raid assistants can set group roles by hand again.
- Large-raid performance pass; the biggest gains are in a 40-man with several
  paladins.

## 1.0.11 — 2026-08-11

- Reworked Action Items and gave it a WDW Status row, with a Talents column in
  place of the old fix buttons.
- Added "Hide when nothing is yours to fix" to the Action Items status row.
- Roles that disagree with the last talent scan are now flagged.
- Custom roles are shared with the raid, and default role overrides now apply to
  the raid instead of per profile.
- Gave the roles grid its own row of column headings.
- Paladin auras are picked from a hover grid instead of cycling.
- Sated glows when a lust leaves raiders behind.
- Hunter pets show their own name, with the owner behind it.
- The promote prompt now reaches every assistant, including after a late
  promotion.
- Rebuilt the buffing rules and consolidated blessing fallbacks; the
  best-available rule relaxes in combat.
- PallyPower fixes skip roleless raiders, and the "upsetting the raid" warning
  only appears without rights.
- Status bars are on by default, with clearer shortcuts.
- Fixed accented names rendering half a byte as their initials.
- Fixed roster repaints closing an open role dropdown, and a stale cache replay
  claiming a respec.

## 1.0.10 — 2026-08-06

- WhoDoesWhat no longer changes anyone's Blizzard group role on its own.
- Added the Action Items window: group roles that don't match, and tanks not
  promoted to Main Tank.
- Added an Actions button to the main window that glows when something needs
  fixing.
- Added a setting to stop WhoDoesWhat touching Blizzard group roles entirely.
- Main tanks are no longer demoted during a fight.
- Custom roles now require a name, a class, and a group role.
- Show WhoDoesWhat roles in Blizzard unit tooltips, with optional class details.
- Added a paladin blessing-spread overview to the PallyPower Differences window.
- Added aura and Righteous Fury helpers to the Paladin Bar.
- Added right-click shortcuts, tooltips, and per-row options to the status bars.
- Added a settings cog to the Buffing Grid, and retired its Rescan button.
- Fixed debuff bars hiding at full saturation.

## 1.0.9 — 2026-08-03

- Added support for improved thorns.
- Added Minimap Button with shortcuts.
- Improve Buff Tracking options for status bars + Grid.
- Respect PallyPower Free Assignment permissions.
- Improved PP buff-source mode, and diffs page.
- Added About section with Update Notes.
- Count only meaningful PallyPower blessing optimizations.
- Use PallyPower talent data for unknown paladins.

## 1.0.8 — 2026-08-01

- Added WDW and PallyPower assignment-source modes.
- Added PallyPower synchronization without requiring PallyPower locally.
- Improved the main board, read-only views, and live buff-status whispers.

## 1.0.7 — 2026-07-30

- Added the observed PallyPower mirror and Buffing Grid source comparison.
- Synchronized Paladin buff strategies and direct talent observations.
- Added configurable status checks and improved buffing priority.

## 1.0.6 — 2026-07-29

- Added live core raid-buff coverage and expanded status bars.
- Improved Paladin coverage controls, pet blessings, and buffing menus.
- Added clearer addon-presence and version information to raid roles.
