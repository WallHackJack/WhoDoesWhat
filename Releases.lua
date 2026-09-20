local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- The release notes the About window shows, and nothing else: one line per
-- change, because that panel is glanced at in a window rather than read.
-- CHANGELOG.md, in the addon folder, carries the same releases in markdown for
-- anyone reading them outside the game -- update both when cutting a tag.
--
-- Newest first. The first entry is presented as the latest release.
WhoDoesWhat.Releases = {
    {
        version = "2.0.4",
        date = "2026-09-19",
        notes = {
            "Raid frame icons and bands are drawn on a layer of WhoDoesWhat's own instead of onto Blizzard's raid frames. On WoW Forever that stops the client erroring on its own raid frame code every frame, thousands of times over with Edit Mode open. Everywhere else it fixes a band that could sit behind the health bar instead of over it.",
            "Buff Checklist: the whole Classic cooking book is offered on WoW Forever. That client puts a Well Fed buff on food that buffed nothing on Era, so the checklist sees anything you cooked and not just Peace Tea.",
            "Buff Checklist: pop-out pickers close when a pull starts on WoW Forever. Left open they were stuck on screen for the whole fight, and that client will not let the addon hide them once combat has begun.",
            "The minimap button starts in the upper right on WoW Forever, where the client's queue eye sits on the spot it used to take. A button you have dragged somewhere stays where you put it.",
            "Fixes on WoW Forever, where the client refuses to tell an addon about certain units: unit tooltips no longer error on things hovered in a dungeon, a buff from a friendly NPC no longer breaks buff tracking, and the inspect library stopped throwing errors blamed on WhoDoesWhat while loot is rolling.",
        },
    },
    {
        version = "2.0.3",
        date = "2026-09-17",
        notes = {
            "Paladins are no longer assigned blessings they have not trained yet: their level says what they can cast, so it works for a paladin running no addon at all. WoW Forever for now; Classic and TBC still go by talents alone.",
            "Role change announcements are off by default. Setting up a board meant a burst of them in party chat, which is a poor introduction to an addon nobody else is running.",
            "New setting: spell and item ids on tooltips, for reporting a consumable the checklist doesn't know yet. On by default on Forever, off elsewhere.",
            "Buff Checklist: Peace Tea, and Forever's own Well Fed buff is recognised.",
            "A welcome notice on Forever, once per character, saying where the addon lives and what the client's restrictions cost.",
            "Fixes: the Paladin Bar failed to build on Forever, and its range checks errored on values that client will not let an addon read.",
        },
    },
    {
        version = "2.0.2",
        date = "2026-09-17",
        notes = {
            "World of Warcraft: Forever support. The client is recognised on its own, and the spell, item and talent functions it removed are bridged, so every feature loads as it does on Era.",
            "Where Forever hides combat data mid-fight, buff tracking holds its last reading rather than flagging the raid unbuffed, the bars keep their colours, and the status bars step aside until the fight ends.",
            "On the Forever beta, where no addon can compile a secure snippet, the checklist pop-outs, the paladin bar's hover menus and its cast rotation fall back to plain handlers that work out of combat.",
            "Unit tooltips show their role line again on clients without the old tooltip hooks.",
        },
    },
    {
        version = "2.0.1",
        date = "2026-09-16",
        notes = {
            "Buff Checklist: armor swappers for mages and warlocks, a warlock demon swapper, mana gems with cooldowns and self-buff reminders. Weapons show their actual enchant and suggest sharpening stones or weightstones to match.",
            "Buff Checklist: Roomy, Snug and Compact spacing, an optional \"From Others\" line, and Shift-Right-Click anywhere to open settings.",
            "Buffs are tracked by spell id rather than English names, so non-English clients work; food, Windfury and weapon enchants are matched by id, and Era gets an alcohol slot.",
            "Fixes: dropdown menus stay open while views refresh, scrolls are cast on you instead of your target, tooltips no longer cover pop-outs, and pickers fill in once item names load.",
        },
    },
    {
        version = "2.0.0",
        date = "2026-09-15",
        notes = {
            "WhoDoesWhat is one tabbed window now: Members, Blessings, Assignments, Buff Grid, Calculator and Settings. The old separate windows and toolbar are gone.",
            "A new navy-and-gold look across the main window and every bar.",
            "Blizzard's Raid tab shows each member's role in place of level and class.",
            "Blessings get their own tab, with PallyPower differences in plain view.",
            "Added the Buff Checklist (Beta): every buff your character should have, from blessings to weapon enchants. Pick consumables from your bags even in combat, swap auras and aspects, and keep your hunter pet buffed.",
            "Battle Elixir and Guardian Elixir status rows on TBC; a flask fills both.",
            "The Curse Calculator has been updated and moved to its own tab.",
            "Settings are split into tabs, each with its own Reset Defaults. Roles moved in as a tab, and a buff's options open beside the table.",
            "Drag rows to reorder buff lists.",
            "The Paladin Bar and Warrior Shout Bar each get an icon size, glow style and glow colours.",
            "The Warrior Shout Bar keeps separate settings for non-warriors, who click a shout to ask for it in party chat. New: hide when I have it, hide coverage numbers, and a countdown timer.",
            "Raid frame role icons can be outlined in tank, healer and DPS colours.",
            "Food whispers say whether a hunter or their pet is unfed, and whispers and announces rescan first. Announces only name buffers when talents narrow it down.",
            "Healthstone tooltips name the warlocks who can make you one.",
            "Saving a raid role pushes its blessings to PallyPower right away.",
            "Shift-Right-Click the PallyPower status row to open its blessings window.",
            "No more popup when the leader's board replaces yours on joining. Thorns is off the Buff Grid by default.",
            "WoW Forever is treated as Classic Era without buff talents.",
        },
    },
    {
        version = "1.2.0",
        date = "2026-09-08",
        notes = {
            "Added the Warrior Shout Bar: one clickable icon per shout, counts relevant party members. Added \"melee\" hunter role.",
            "The Paladin Bar can stand up as a vertical column, with per-class expiry countdowns, an aura picker that casts, and an alt-right-click switch that hands the raid over to PallyPower.",
            "WhoDoesWhat roles can be drawn on Blizzard's raid frames, in five styles from a round replacement icon to a faded band down the health bar.",
            "Shift-left-click a status bar to whisper whoever can fix it -- the paladins, the priests, or everyone still needing to eat.",
            "Status bar announces and whispers now count forwards, name the stragglers only while there are few of them, and are signed like every other message the addon sends.",
            "Status bar rows glow in a highlight style of your choosing, in a color of your choosing, with a live preview in the settings.",
            "Divine Spirit is tracked on TBC, including who can cast it at all and who would have to respec first.",
            "Buffs cast by somebody outside the raid are counted as missing, and named separately in the tooltip.",
            "Hunter pets are matched for blessings across every paladin rather than the leftovers, and a Steam Tonk is no longer mistaken for one.",
            "Paladin Trash Tank is now Threat Tank, and the Arms and Enhancement icons were refreshed.",
        },
    },
    {
        version = "1.1.0",
        date = "2026-08-20",
        notes = {
            "Shift-right-click a status bar to announce who is still missing that buff in raid chat; editing moved to alt-right-click.",
            "Action Items folded into the Members window: roles, talents, and what needs fixing in one place.",
            "Ignore a blessing for part of the raid -- \"Sanctuary except for Tanks\" is now one rule.",
            "A paladin running without PallyPower announces themselves to it, so they can be given assignments.",
            "Raid assistants can set group roles by hand again.",
            "Large-raid performance pass; the biggest gains are in a 40-man with several paladins.",
        },
    },
    {
        version = "1.0.11",
        date = "2026-08-11",
        notes = {
            "Reworked Action Items and gave it a WDW Status row, with a Talents column in place of the old fix buttons.",
            "Added \"Hide when nothing is yours to fix\" to the Action Items status row.",
            "Roles that disagree with the last talent scan are now flagged.",
            "Custom roles are shared with the raid, and default role overrides now apply to the raid instead of per profile.",
            "Gave the roles grid its own row of column headings.",
            "Paladin auras are picked from a hover grid instead of cycling.",
            "Sated glows when a lust leaves raiders behind.",
            "Hunter pets show their own name, with the owner behind it.",
            "The promote prompt now reaches every assistant, including after a late promotion.",
            "Rebuilt the buffing rules and consolidated blessing fallbacks; the best-available rule relaxes in combat.",
            "PallyPower fixes skip roleless raiders, and the \"upsetting the raid\" warning only appears without rights.",
            "Status bars are on by default, with clearer shortcuts.",
            "Fixed accented names rendering half a byte as their initials.",
            "Fixed roster repaints closing an open role dropdown, and a stale cache replay claiming a respec.",
        },
    },
    {
        version = "1.0.10",
        date = "2026-08-06",
        notes = {
            "WhoDoesWhat no longer changes anyone's Blizzard group role on its own.",
            "Added the Action Items window: group roles that don't match, and tanks not promoted to Main Tank.",
            "Added an Actions button to the main window that glows when something needs fixing.",
            "Added a setting to stop WhoDoesWhat touching Blizzard group roles entirely.",
            "Main tanks are no longer demoted during a fight.",
            "Custom roles now require a name, a class, and a group role.",
            "Show WhoDoesWhat roles in Blizzard unit tooltips, with optional class details.",
            "Added a paladin blessing-spread overview to the PallyPower Differences window.",
            "Added aura and Righteous Fury helpers to the Paladin Bar.",
            "Added right-click shortcuts, tooltips, and per-row options to the status bars.",
            "Added a settings cog to the Buffing Grid, and retired its Rescan button.",
            "Fixed debuff bars hiding at full saturation.",
        },
    },
    {
        version = "1.0.9",
        date = "2026-08-03",
        notes = {
            "Added support for improved thorns.",
            "Added Minimap Button with shortcuts.",
            "Improve Buff Tracking options for status bars + Grid.",
            "Respect PallyPower Free Assignment permissions.",
            "Improved PP buff-source mode, and diffs page.",
            "Added About section with Update Notes.",
            "Count only meaningful PallyPower blessing optimizations.",
            "Use PallyPower talent data for unknown paladins.",
        },
    },
    {
        version = "1.0.8",
        date = "2026-08-01",
        notes = {
            "Added WDW and PallyPower assignment-source modes.",
            "Added PallyPower synchronization without requiring PallyPower locally.",
            "Improved the main board, read-only views, and live buff-status whispers.",
        },
    },
    {
        version = "1.0.7",
        date = "2026-07-30",
        notes = {
            "Added the observed PallyPower mirror and Buffing Grid source comparison.",
            "Synchronized Paladin buff strategies and direct talent observations.",
            "Added configurable status checks and improved buffing priority.",
        },
    },
    {
        version = "1.0.6",
        date = "2026-07-29",
        notes = {
            "Added live core raid-buff coverage and expanded status bars.",
            "Improved Paladin coverage controls, pet blessings, and buffing menus.",
            "Added clearer addon-presence and version information to raid roles.",
        },
    },
}
