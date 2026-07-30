<img src="Icon.png" align="right" width="96" alt="WhoDoesWhat icon">

# WhoDoesWhat

**A raid-assignment panel for WoW TBC (Anniversary realms) with hassle-free paladin assignments and instant sync to PallyPower and raid members.**

Open one window (`/wdw`), lay out your tanks, crowd control, misdirects, curses, and blessings, and everyone in the raid running the addon sees the same board instantly. No macros, no typing names into chat, no "wait, who has the moon?"

## The Board

- **Tank assignments** — assign tanks to raid markers, with an "everything else" catch-all and warnings for unmarked targets.
- **Crowd control** — assign CC by marker, with spell dropdowns filtered to what the assignee can actually cast.
- **Misdirects** — pair hunters with their tanks (and optionally a marker), with sanity warnings for double-misdirects and unmarked tanks.
- **Warlock curses** — TBC assigns Elements/Recklessness (preferring an Affliction lock); Classic assigns Elements/Shadow/Recklessness to separate warlocks.
- Every dropdown shows role icons and class colors, and every row has a **mail button** that whispers the player their full job list — or mass-whisper the entire board at once.

## Paladin Blessings — hassle-free

You don't assign blessings at all. WhoDoesWhat **scans every paladin's talents** (Improved Might/Wisdom ranks, Kings, Sanctuary) and every raider's role, then computes optimal blessing coverage automatically — specialists land on their improved blessing, tanks get what tanks want, and nobody is asked to cast a blessing they didn't talent. A full **raiders × paladins grid** shows exactly who buffs whom, and a summary row per paladin shows their workload at a glance.

Want control anyway? Add **buff rules**: ignore a blessing entirely, prioritize one for tanks/healers/DPS or a specific class, or lock a blessing to a specific paladin.

## PallyPower Sync

One click pushes the computed grid straight into **PallyPower** — over PallyPower's own sync protocol, so every paladin in the raid gets their assignments even if they've never heard of WhoDoesWhat.

## Instant Raid Sync

Any permitted edit broadcasts the whole board to every WhoDoesWhat user in the group. Joiners automatically pull the leader's board, simultaneous edits converge cleanly, and paladins share their own talent scans so the blessing math works even for out-of-range players.

## Built for Raid Leading

- **Editing permissions** — the raid leader decides who may edit: leader only, one named assistant, all assists (default), or everyone. Everyone else gets a clean read-only view.
- **Role management** — roles auto-detect from talents (and follow respecs), with a role overview window and right-click "Set Role" on any unit frame. Custom roles and per-spec buff priorities are fully customizable.
- **Right-click everything** — assign tank markers, CC targets, and misdirects straight from unit frames.
- **Curse value calculator** — pulls a fight from Details! and estimates flavor-correct CoE/CoS/CoR value, including optional Classic Ignite double-dipping.

## Usage

| Command | Effect |
| --- | --- |
| `/wdw` | Toggle the main assignments window |
| `/wdw r` | Toggle the buffing grid window |
| `/wdw sync` | Manual resync — leaders push their board, members pull the leader's |
| `/wdw ppsync` | Push the computed blessing grid into PallyPower and broadcast it |
| `/wdw pplog` | Toggle the PallyPower traffic log window |

## Installation

Download from CurseForge (or your addon manager), or clone this repository into `Interface\AddOns\WhoDoesWhat`. Built for TBC Anniversary (`20505`) and Classic Era (`11509`).

## Tech Stack

- **Lua 5.1** on the WoW Classic API, UI built with **AceGUI-3.0** plus custom frame chrome and the modern `Menu` API for right-click integration.
- **Ace3** (AceAddon, AceDB, AceComm, AceEvent, and friends) for addon structure, saved variables, and comms.
- **LibClassicInspector** (+LibDetours) for talent inspection — with native `GetTalentInfo` cross-checks to work around talent-order quirks on the Anniversary client.
- **LibSerialize + LibDeflate** over AceComm for the compressed whole-board sync protocol (last-write-wins with Lamport revisions, leader-as-source-of-truth on join).
- Speaks **PallyPower's wire protocol** (`PLPWR`) directly for the blessing push, throttled through PallyPower's own channel handling.

Development notes for contributors live in [DEVELOPMENT.md](DEVELOPMENT.md). Coding-agent instructions live in [AGENTS.md](AGENTS.md).

## License

MIT — see [LICENSE](LICENSE). Bundled libraries in `Libs/` retain their own licenses.
