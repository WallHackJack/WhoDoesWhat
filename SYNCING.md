# WhoDoesWhat synchronization reference

This document describes the addon-message traffic used or observed by
WhoDoesWhat (WDW). It is written for humans debugging the addon rather than as
a stable external API. The current code is authoritative.

## Systems at a glance

| Prefix | Owner | Encoding | Purpose |
| --- | --- | --- | --- |
| `WhoDoesWhat` | WDW | LibSerialize, Deflate, WoW-channel encoding, AceComm | Shared assignment board, roles, utility-talent ranks, versions, and presence |
| `LCIV1` | LibClassicInspector | Library-owned compact text | Full talent-rank distribution and inspection cache |
| `PLPWR` | PallyPower | PallyPower plaintext commands | Blessing assignments, per-player exceptions, auras, and peer discovery |

WDW chooses `INSTANCE_CHAT`, `RAID`, or `PARTY` for group messages, in that
order. Whispers are used where noted below.

## WDW wire envelope

Every WDW message is a Lua table. `Sync:Send` adds these fields to every
message:

```lua
{
    t = "HELLO", -- message type
    p = 9,       -- WDW wire-protocol version
    v = "1.0.6",-- addon version reported by this client
    -- type-specific fields follow
}
```

The table then passes through these layers:

```text
Lua table
  -> LibSerialize binary serialization
  -> LibDeflate compression
  -> LibDeflate WoW-addon-channel encoding
  -> AceComm chunking and throttling
```

Protocol mismatches are reported once and their type-specific payloads are
ignored. The sender is still recorded as a WDW peer, and its addon version is
recorded before the protocol check.

Top-level `state` keys a receiving client does not recognize are preserved
rather than discarded: they are captured when a board is applied and reattached
to that client's own snapshots, so an older build relays a newer board's
features instead of silently deleting them the next time it edits anything. The
carried set is replaced wholesale on each apply, so a key a newer client removes
stays removed. Carried keys participate in the fingerprint, because the
snapshot must equal what would actually be sent. This is what makes purely
additive protocol changes safe to accept across versions.

The Sync Log's views correspond to different layers:

- Summary is WDW's human description of the decoded message.
- Decoded is a deterministic debug rendering of the Lua table. Text such as
  `string:` and `boolean:` is added by the renderer and is not transmitted.
- Raw Hex is the final channel-safe WDW payload represented as hexadecimal. It
  is the payload given to AceComm on send, or returned by AceComm after
  reassembly on receive; it does not show AceComm's individual chunk headers.

Hex uses two display characters per byte, so it looks larger than the actual
payload. Small compressed messages may also be larger than their uncompressed
form because compression and channel encoding have fixed overhead.

## WDW message catalog

Fields whose values are unavailable or irrelevant are omitted by Lua rather
than sent as explicit `nil` values.

### `HELLO`

Purpose: announce the sender and ask the leader for the authoritative board.

Channel: group broadcast.

Initial join/reload shape:

```lua
{
    t = "HELLO",
    p = 9,
    v = "1.0.6",
    talents = { 41, 20, 0 },
    ranks = {                 -- paladin only, once locally known
        might = 5,
        wisdom = 2,
        kings = 1,
        sanctuary = 0,
    },
    healthstone = 2,          -- warlock only
    coreRanks = {
        fortitude = 2,        -- priest only
        gift = 5,             -- druid only
        thorns = 3,           -- druid only
    },
}
```

Only one class-specific utility payload normally appears. `talents` contains
the sender's three talent-tree totals in the client's normal tab order. It is
included only by the automatic join/reload handshake, not by UI navigation or
`/wdw sync`. Receivers obtain the sender's class from the group
roster, choose the tree with the most points, and run the existing WDW role
inference. No role id is trusted from the message. The result goes through the
existing `talentSpecs` and assignment logic, while a session-only fact keeps
the exact triplet available for later mismatch detection.

Every compatible receiver records the sender's version, WDW presence, talent
totals, and utility ranks. When the Blizzard leader runs the compatible WDW
protocol, ordinary peers remain silent. Only the leader whispers one `STATE`,
whose peer directory supplies the joiner with the already-known presence,
versions, talent totals, and utility ranks for the rest of the raid.

An ordinary join therefore produces two WDW messages regardless of raid size:
the group `HELLO` and the leader's whispered `STATE`. UI navigation never
sends `HELLO`; automatic join/reload and explicit `/wdw sync` are its current
entry points.

If the Blizzard leader has no compatible WDW, there is no client authorized to
compile an initial board. Stable peers retain the old `RANKS`/`VERSION`
whisper replies so the joiner still discovers them while it waits five seconds
and keeps its local board. Peers which are themselves reloading do not answer,
preventing a simultaneous reload group from fanning out at itself.

### `STATE`

Purpose: transfer the complete shared assignment board.

Shape:

```lua
{
    t = "STATE",
    p = 9,
    v = "1.0.6",
    rev = 1785432100,
    state = {
        roles = {
            ["Player-Realm"] = "paladin_holy",
        },
        tank = {
            {
                player = "Tank-Realm",
                markers = { 8, 7, "custom" },
                custom = "First add",
            },
        },
        cc = {
            {
                player = "Mage-Realm",
                marker = 6,
                custom = nil,
                spell = "polymorph",
            },
        },
        md = {
            {
                player = "Hunter-Realm",
                target = "Tank-Realm",
                marker = 8,
            },
        },
        static = {
            curse_reck = "Warlock-Realm",
        },
        paladinStrategy = {
            { buff = "kings", kind = "prefer", value = "Player-Realm" },
            { buff = "wisdom", kind = "prioritize", scope = "wowrole", value = "healer" },
        },
        perms = {
            mode = "assists",
            assistant = false,
        },
    },
    peers = { -- included in the leader's initial whisper
        ["Player-Realm"] = {
            version = "1.0.6",
            talents = { 41, 20, 0 },
            ranks = { might = 5, wisdom = 2, kings = 1, sanctuary = 0 },
            healthstone = nil,
            coreRanks = nil,
        },
    },
    observations = { -- directly inspected non-WDW roster members
        ["Other-Realm"] = {
            class = "WARLOCK",
            talents = { 40, 0, 21 },
            healthstone = 2,
        },
    },
}
```

The example values are illustrative; role, row, spell, and permission ids are
defined by the current model and data tables.

Paladin blessing rows are deliberately absent. Each client computes blessing
coverage from roster, roles, the shared `paladinStrategy`, and the separately
synchronized talent ranks. The strategy is the ordered
`db.profile.paladinBuffRules` array; its `ignore`, `prioritize`, and `prefer`
shapes are described in `Assignments.lua`. Its order is significant when
several prioritization rules match. Role customizations and UI settings remain
local and are absent.

`peers` is outside the shared board and therefore outside its fingerprint. The
leader includes it in an initial whispered snapshot, using only current roster
members it has observed running WDW plus itself. Each entry may contain the
peer's addon version, talent totals, and last validated utility ranks. The
receiver accepts this directory only from its current group leader and only
for names still in its own roster.

`observations` is the leader's session-only directory for current roster
members who have not announced a compatible WDW client. Its entries are facts
previously supplied by a live `OBSERVE`, not scans invented by the leader. It
lets a later joiner reuse talent information already gathered by the raid.

`STATE` has two delivery modes:

- The leader whispers it, with `peers`, to a joining/reloading member in
  response to `HELLO`. The receiver accepts that whisper only while waiting
  for initial sync and only from the current leader.
- A permitted editor broadcasts it after the board fingerprint changes. Every
  receiver independently checks that the sender may edit assignments.

`rev` is a wall-clock-seeded Lamport-style revision. A greater revision wins;
equal revisions use sender name as a deterministic tie-break. Applying a
remote state updates the local fingerprint before polling resumes, preventing
an apply-and-echo loop.

### `RANKS`

Purpose: distribute exact, self-observed utility-talent ranks.

Channel: group broadcast after a local utility scan or while rebuilding a
reloaded leader's empty session directory; whisper only for the addonless or
protocol-incompatible leader fallback.

```lua
{
    t = "RANKS",
    p = 9,
    v = "1.0.6",
    ranks = { might = 5, wisdom = 2, kings = 1, sanctuary = 0 },
    healthstone = 2,
    coreRanks = { fortitude = 2, gift = 5, thorns = 3 },
}
```

As with `HELLO`, only fields appropriate to the sender's class normally exist.
Values are associated with the sender; a player cannot use this message to
write another player's ranks. Receivers normalize the numeric values;
healthstone and core-buff ranks are also clamped to their legal ranges.
The leader may later relay those cached values in an initial `STATE` peer
directory; it does not manufacture a second talent scan.

Local utility scans schedule this message after a two-second debounce. The
timer is not reset by every subsequent talent event: another message can be
scheduled after the first timer fires if more events continue. This behavior
is acceptable because spending talent points while grouped is not a design
target.

### `OBSERVE`

Purpose: share a fresh, direct in-range inspection of another roster member.

Channel: group broadcast only. Whispers are rejected.

```lua
{
    t = "OBSERVE",
    p = 9,
    v = "1.0.6",
    player = "Other-Realm",
    class = "PALADIN",
    talents = { 41, 20, 0 },
    ranks = { might = 5, wisdom = 2, kings = 1, sanctuary = 0 },
}
```

Any WDW raider may send this message, regardless of assignment permission,
because it reports evidence rather than editing the board. WDW emits it only
from LibClassicInspector's live-inspection callback (`isInspect = true`), never
from a library broadcast or cache replay. The target and reporter must both be
current group members, the target cannot be the reporter, and the transmitted
class must match the receiver's own roster. Tree totals must be three
non-negative integers with a plausible total. Class-specific utility ranks are
clamped to their legal ranges.

The first direct scan is broadcast when the raid has no session observation.
Normally a compatible WDW target's `HELLO` already supplied that fact, making
this the unscanned non-WDW case; if a WDW `HELLO` lacked talents, the direct
scan usefully fills that gap too. Identical later scans are silent. A changed
tree triplet or exact utility rank is broadcast as a mismatch, normally
indicating a respec. Near-simultaneous first scans can still produce harmless
duplicates before clients hear one another.

Receivers do not trust a transmitted role. Every client runs its normal
class/tree role inference from `talents`, updates its local talent caches, and
pins an otherwise-clean board fingerprint so the observation does not echo as
a redundant full `STATE`. The compatible leader retains non-WDW observations
in its session directory for later joiners. Nothing is written as permanent
third-party provenance; leaving the group clears this comparison directory.

### `ROLE`

Purpose: let a read-only player change their own role without assignment-board
editing permission.

Channel: group broadcast.

```lua
{
    t = "ROLE",
    p = 9,
    v = "1.0.6",
    role = "druid_feral_tank",
}
```

`role` is a role id, or absent to clear the sender's role. The receiver always
applies it to the message sender and never accepts a target player field. The
local board poll sends it when a read-only player's own role changes.

If the player may edit the board, the same role change is part of a full
`STATE` broadcast instead.

### `VERSION`

Purpose: announce presence when rebuilding a reloaded leader's empty session
directory and the sender has no utility ranks to return.

Channel: group broadcast during that bounded rebuild; whisper only for the
addonless or protocol-incompatible leader fallback.

```lua
{
    t = "VERSION",
    p = 9,
    v = "1.0.6",
}
```

There is no type-specific payload; every WDW message already carries `v`.

## Common WDW sequences

### Non-leader joins or reloads

1. A normal join starts from the group event; after a reload, WDW first waits
   three seconds for the roster to become usable.
2. The member marks itself as waiting for initial state.
3. It sends one PallyPower `REQ` for this join/reload handshake, subject to
   the PallyPower requester's 10-second duplicate guard.
4. It group-broadcasts an initial `HELLO`, including its talent-tree totals
   and any available utility ranks.
5. Every WDW client immediately records its presence/version and can infer its
   role from the totals.
6. A compatible leader whispers one `STATE` containing the board and its peer
   directory; every other client remains silent. Without one, stable peers
   reply only with their own `RANKS` or `VERSION`.
7. The member replaces its local board with the leader snapshot.
8. If no leader snapshot arrives within five seconds, the member keeps its
   local board and normal synchronization resumes.

### Leader reloads

After the three-second entering-world delay, the leader sends one PallyPower
`REQ` and broadcasts one `STATE`. Because a reload erased its session-only
peer directory, that state requests one group `RANKS` or `VERSION`
announcement from each peer. All clients hear those announcements and rebuild
the same presence/version/rank cache. This is linear in raid size and occurs
only when the leader's cache is empty; the leader does not run the member
`HELLO` pull.

### UI navigation

Opening Main Assignments, Raider Roles, Buffing Grid, the logs, settings, role
customizers, or PallyPower Differences sends nothing. Switching the Buffing
Grid between its cached sources also sends nothing. Views render the current
local/session caches and refresh as normal lifecycle traffic arrives.

Explicit action buttons retain their named behavior: Buffing Grid Rescan asks
the native inspector to inspect reachable providers, `/wdw sync` exchanges WDW
state, and PallyPower Send/Fix broadcasts assignments.

Roster-derived tank/misdirect rows and departed-player cleanup run in a
three-second debounced model lifecycle handler rather than section refreshes.
The group leader is the sole automatic housekeeping writer; if its stored
board actually changes, the ordinary board poll sends one `STATE`.

### Player respecs or swaps talent groups

The player's client receives WoW talent events and immediately runs the local
WDW talent pipeline against native data.

- If the inferred role changes, the next two-second board poll sends `ROLE`
  for a read-only player or full `STATE` for a permitted editor.
- Paladins, warlocks, druids, and priests schedule `RANKS` after two seconds.
- LibClassicInspector marks its data dirty and broadcasts `LCIV1` on its next
  five-second information tick.
- The respeccing player's own client sends no `HELLO` or WDW talent-tree
  triplet for the respec.
- A later live inspection which disagrees with the raid's last observation
  sends one `OBSERVE`, allowing even a read-only raider to distribute the new
  tree totals and exact utility ranks.
- A narrowly safe role-driven blessing exception may additionally cause a
  PallyPower `NASSIGN` when PallyPower is installed and already aligned.

The role message usually updates Raider Roles before LibClassicInspector's
follow-up message independently confirms the talent-tree calculation.

### Assignment edit

A permitted editor's next two-second fingerprint poll broadcasts one complete
`STATE`. An unpermitted client's changes to other players remain local and are
not later dumped into the group if that client gains permission.

### Leaving the group

WDW clears the group board, permissions, and session-only peer/version and
observation state.
Talent/spec and exact utility-rank caches survive because they describe
characters rather than decisions belonging to the departed group.
`paladinBuffRules` are group strategy, so they are cleared too.

## Talent data: totals versus exact ranks

LibClassicInspector supplies broad talent data from live inspections and from
players broadcasting their own talent strings. WDW uses that cache for totals
and spec/role inference.

Exact utility talents use a separate path. On the Anniversary client, native
`GetTalentInfo(tab, index)` order can differ from LibClassicInspector's static
talent-table order. The library message contains positional rank digits, not a
row and column next to each digit. Once a received rank has been paired with
the wrong static index, row/column metadata cannot reconstruct the original
association.

WDW therefore reads exact ranks by native `(tab, row, column)` only when the
data is authoritative:

- the local player; or
- a fresh live inspection while WoW's inspected talent data is still active.

The local provider sends those exact conclusions in WDW `RANKS`; a direct
third-party inspection may carry them in `OBSERVE`. This division is
intentional:

| Information | Source used by WDW |
| --- | --- |
| Three tree totals and primary tree | LibClassicInspector cache, initial WDW `HELLO` for immediate join inference |
| General role inference | WDW's class-to-tree role table |
| Third-party tree totals | Fresh live inspection, then deduplicated WDW `OBSERVE` |
| Exact utility-talent ranks | Native row/column scan, then own `RANKS` or third-party `OBSERVE`; leader cache relayed in initial `STATE`; non-relayed PallyPower fallback for otherwise-unknown paladins |
| Manual/final board role | WDW `ROLE` or `STATE` |

## LibClassicInspector traffic

Prefix: `LCIV1`.

Logical TBC payload:

```text
02-<active talent group><one rank digit per native talent index...>
```

The library may append data for additional talent groups or client features on
clients which support them. WDW treats this format as library-owned and does
not parse it itself; it consumes the library's `TALENTS_READY` callback.

The local library marks data changed on entering the world, roster changes,
resurrection, talent-point changes, talent updates, and active talent-group
changes. A five-second ticker broadcasts changed information; unchanged data
is refreshed roughly once per minute. It sends to the home group, instance
group, and guild channels that currently apply, so a grouped and guilded
player may produce both group and guild traffic.

On receipt, the library validates and caches the rank array, then fires
`TALENTS_READY(guid, false)`. A live inspect caches data and fires
`TALENTS_READY(guid, true)`. WDW uses the `true` form to perform its native
row/column utility scan before the inspected data disappears.

## PallyPower traffic

Prefix: `PLPWR`. PallyPower messages are plaintext commands owned by
PallyPower. WDW observes them to maintain a session-only mirror and originates
only the messages required for discovery and explicit synchronization.

| Message | Meaning | WDW behavior |
| --- | --- | --- |
| `REQ` | Ask PallyPower clients to identify themselves | WDW sends on group join/reload, at most once per channel per 10 seconds |
| `SELF <rank/talent pairs>@<row>` | Sender's blessing capabilities and own class row | Observed; fills otherwise-unknown paladin buff talents as provisional external data, marks sender as a PallyPower peer, and resets their mirrored exceptions before replay |
| `ASELF ...@<aura>` | Sender's own aura state | Logged, not part of the blessing-grid mirror |
| `PPLEADER <name>` | Announce PallyPower leader | Logged |
| `PASSIGN <paladin>@<row>` | Replace one paladin's full class blessing row | Observed; WDW sends during an explicit full push |
| `ASSIGN <paladin> <class> <blessing>` | Change one class cell | Observed |
| `MASSIGN <paladin> <blessing>` | Give all classes one blessing | Observed |
| `NASSIGN <paladin> <class> <target> <blessing>[@...]` | Set or clear per-player normal-blessing exceptions | Observed; WDW sends in batches of five entries during full or safe per-player pushes |
| `AASSIGN <paladin> <aura>` | Assign one aura | Logged |
| `CLEAR [SKIP]` | Clear assignments; `SKIP` retains auras | Observed; WDW sends `CLEAR SKIP` at the start of an explicit full push |
| `FREEASSIGN ...` | Free-assignment, reagent, and cooldown information | Logged |

PallyPower clients enforce their own sender authority. WDW's mirror similarly
accepts another paladin's assignments only from that paladin or from a sender
believed able to assign others.

An explicit WDW-to-PallyPower full push sends:

1. `CLEAR SKIP`.
2. After 0.25 seconds, one `PASSIGN` per paladin.
3. `NASSIGN` entries in batches of at most five.

The smaller automatic role-change path sends only the affected `NASSIGN`
entries and only when the previous PallyPower board was aligned and the change
does not alter broader class demand.

## Current traffic characteristics

- WDW board mutations send complete snapshots rather than diffs.
- The ordered `paladinStrategy` rules table is part of that snapshot and its
  fingerprint; changing one rule produces the same single debounced `STATE` as
  any other board edit.
- The board snapshot built by the poll is reused for its fingerprint and send,
  and sync logging performs expensive decoding only when its decoded view is
  selected.
- With a compatible WDW leader, an ordinary member join/reload is fixed-size
  WDW traffic: one group `HELLO` and one leader `STATE` whisper. The leader's
  compiled peer directory replaces the former per-peer whisper replies.
- A cold leader reload performs one bounded, group-wide directory rebuild:
  one leader `STATE`, then one `RANKS` or `VERSION` announcement per peer.
  Simultaneous reload traffic is linear rather than quadratic.
- Without a compatible WDW leader, stable peers still answer `HELLO` so
  presence and utility ranks remain discoverable; no compiled board exists in
  that fallback.
- Window opening and source selection are passive; they do not initiate WDW,
  LibClassicInspector, or PallyPower traffic.
- LibClassicInspector independently distributes full talent strings. WDW does
  not duplicate those strings; it sends immediate tree totals on initial
  `HELLO`, exact utility-rank conclusions in `RANKS`, and only three totals plus
  relevant utility ranks for a new or changed direct `OBSERVE`.
- PallyPower and WDW have independent prefixes, state models, throttling, and
  cooldowns. A WDW action can legitimately cause traffic under both prefixes.

When changing any WDW message shape, increment `PROTOCOL` in `Sync.lua`, update
this document, and test with at least two clients. Protocol-mismatched clients
will see each other's presence/version but will not exchange assignments.
