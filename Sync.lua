local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Network sync for the assignments board: everyone running WhoDoesWhat in a
-- group converges on one board without anyone whispering screenshots around.
--
-- What syncs:
--   - roles            (db.profile.assignments: player name -> role id)
--   - tank / CC / misdirect rows (tankAssignments / ccAssignments / mdAssignments)
--   - static rows EXCEPT paladin buff keys (today that's the warlock
--     curses). Paladin blessings aren't assigned at all anymore -- coverage
--     is computed per client from roster + roles + talents (ComputeBuffGrid,
--     Assignments.lua) -- so there are no paladin rows to sync. The shared
--     paladinStrategy rules and talent facts below keep that computation in
--     agreement.
--     IsSyncedStaticRow still filters the keys as a safety.
--   - talent ranks: players broadcast their OWN class utility ranks: paladin
--     blessing talents, Improved Healthstone, Improved Fortitude, Improved
--     Mark of the Wild, and Improved Thorns/Brambles. All are read from the
--     sender's native
--     talent API -- the one source that is always in range and never hits the
--     shuffled-index bug (see TalentScanning.lua). Receivers drop the ranks
--     straight into the matching class-specific talent cache. The old NRC
--     talent-string reference code in this file existed for this; ranks read
--     on the
--     SENDER makes an order-proof wire encoding unnecessary, so small rank
--     tables replace the whole string format. The leader relays its cached
--     sender-supplied ranks inside the initial STATE peer directory. The
--     initial HELLO also carries
--     the sender's three talent-tree totals so every WDW client can infer the
--     same role immediately. A live inspection of someone else may broadcast
--     the same three totals and exact relevant ranks in OBSERVE; full talent
--     grids remain LibClassicInspector's job.
--
-- Conflict model:
--   - Leaving the group wipes assignment state (roles included): assignments
--     are group business, and a stale board from the last raid only misleads.
--     The talent caches (talentSpecs / paladinBuffTalents /
--     warlockHealthstoneTalents / coreBuffTalents) survive -- they're
--     character facts rather than the departed raid's assignments.
--   - Joining a group makes the LEADER the source of truth: the joiner says
--     HELLO, the leader whispers back a full snapshot, and the joiner's local
--     board is replaced outright (a popup says so when it overwrote anything).
--     No reply within JOIN_SYNC_TIMEOUT (leader without the addon) means the
--     joiner keeps what they have and normal syncing takes over.
--   - While grouped, any PERMITTED member's edit broadcasts the full board
--     (who is permitted is the leader-owned rule in Permissions.lua, itself
--     part of the snapshot). Unpermitted clients broadcast no BOARD edits
--     except their own role over ROLE; like everyone else, they may also report
--     firsthand talent evidence over OBSERVE. Everyone rejects board snapshots
--     from unpermitted senders.
--     Last write wins; a Lamport-style revision counter with a sender-name
--     tiebreak keeps simultaneous edits from ping-ponging and converges
--     everyone on the same version.
--
-- Change detection is a fingerprint poll rather than write-path hooks: board
-- writes are scattered (Set* APIs, unit-menu pop-outs, dropdowns mutating
-- entries in place, auto-assigns, pruning), so every POLL_INTERVAL we
-- fingerprint the synced slice of the db and broadcast when it changed.
-- Applying a remote snapshot updates the fingerprint first, so a received
-- board never echoes back out.

local Sync = WhoDoesWhat:NewModule("Sync", "AceComm-3.0", "AceEvent-3.0", "AceTimer-3.0")

local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")

-- Developer timing (Profiling.lua); both are no-ops unless /wdw perf on.
local PBegin, PEnd = WhoDoesWhat.Profiling.Begin, WhoDoesWhat.Profiling.End

local COMM_PREFIX = "WhoDoesWhat"
-- Bump on any wire-format change; mismatched clients warn once and ignore
-- each other. 2: tank rows went one-per-tank with a `markers` array (was
-- one-per-marker with a single `marker`). 3: RANKS/HELLO gained the warlock
-- Improved Healthstone rank. 4: the initial HELLO gained talent-tree totals.
-- 5: leader STATE replies gained the peer directory; peers stopped answering
-- ordinary HELLO broadcasts individually. 6: live third-party inspections
-- gained OBSERVE, and leader directories gained cached talent observations.
-- 7: STATE gained the shared paladinStrategy rules table. 8: STATE gained
-- the raid's permission-gated PallyBuffSource selection. 9: Druid coreRanks
-- gained the Improved Thorns/Brambles rank. 10: paladinStrategy rules changed
-- shape (ignore/prioritize/prefer -> Salvation ignore, guarantee, assign); the
-- table travels the same but an older client would read the new kinds as inert
-- and compute a different plan, so they stop syncing instead.
local PROTOCOL = 10
local POLL_INTERVAL = 2 -- seconds between local-change fingerprint checks
local JOIN_SYNC_TIMEOUT = 5 -- seconds a joiner waits for the leader's snapshot
local RANKS_DEBOUNCE = 2 -- seconds to let a talent-scan burst settle before broadcasting

-- Session-only by design: /reload turns traffic capture and verbose sync chat
-- back off. The Sync Log and Developer settings expose the same toggle.
WhoDoesWhat.LOG_SYNC = false

function WhoDoesWhat:SetSyncLoggingEnabled(enabled)
    enabled = enabled and true or false
    self.LOG_SYNC = enabled
    if self.db then self.db.profile.settings.logSyncTraffic = enabled end
    if self.RefreshSyncLogLoggingCheck then self:RefreshSyncLogLoggingCheck() end
    if self.RefreshAddonSettingsLoggingCheck then
        self:RefreshAddonSettingsLoggingCheck()
    end
end

local function LogSync(...)
    if WhoDoesWhat.LOG_SYNC then
        WhoDoesWhat:Print("|cff888888[sync]|r", ...)
    end
end

-- ---------------------------------------------------------------------------
-- Group helpers
-- ---------------------------------------------------------------------------

-- The active addon-message channel, or nil when solo (nothing to sync with).
-- Instance groups (battlegrounds) need INSTANCE_CHAT; RAID/PARTY don't reach
-- them.
local function GroupChannel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- A comm sender normalized to our db keying: "Name" for same-realm players,
-- "Name-Realm" for foreign ones. CHAT_MSG_ADDON senders can arrive
-- realm-qualified either way; Ambiguate("none") strips exactly the home realm.
local function SenderKey(sender)
    return Ambiguate(sender, "none")
end

local function UnitKey(unit)
    local name, realm = UnitName(unit)
    if name and realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

local function ClassForPlayer(name)
    local function FromUnit(unit)
        if UnitKey(unit) == name then return select(2, UnitClass(unit)) end
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local class = FromUnit("raid" .. i)
            if class then return class end
        end
    else
        local class = FromUnit("player")
        if class then return class end
        for i = 1, GetNumSubgroupMembers() do
            class = FromUnit("party" .. i)
            if class then return class end
        end
    end
end

-- The group leader under the same keying, or nil (leaderless moments happen
-- mid-roster-change). GetRaidRosterInfo names already follow our keying.
local function LeaderName()
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name, rank = GetRaidRosterInfo(i)
            if rank == 2 then return name end
        end
        return nil
    end
    if UnitIsGroupLeader("player") then return UnitName("player") end
    for i = 1, GetNumSubgroupMembers() do
        local unit = "party" .. i
        if UnitIsGroupLeader(unit) then
            local name, realm = UnitName(unit)
            if name and realm and realm ~= "" then return name .. "-" .. realm end
            return name
        end
    end
    return nil
end

-- Every view that renders synced state; repainted after any remote apply.
local function RefreshAllViews()
    WhoDoesWhat:RefreshMainAssignmentsView()
    -- The roster issues ride the Members repaint above: they are drawn on its
    -- rows and are deliberately NOT part of RefreshBoardViews, which the
    -- buff-tracking notify drives at up to 10Hz (see ViewRefresh.lua).
    WhoDoesWhat:RefreshMembersView()
    WhoDoesWhat:RefreshBoardViews()
end

-- ---------------------------------------------------------------------------
-- Snapshot: the synced slice of the profile
-- ---------------------------------------------------------------------------

-- Static rows sync unless they're paladin buff rows (see the header).
local function IsSyncedStaticRow(rowId)
    return not WhoDoesWhat.PaladinBuffs[rowId]
end

-- Every top-level board key THIS build produces. Anything else in a received
-- board belongs to a newer build than ours.
local KNOWN_STATE_KEYS = {
    roles = true, tank = true, cc = true, md = true, static = true,
    paladinStrategy = true, pallyBuffSource = true, perms = true,
    customRoles = true,
}

-- Board keys from the last applied remote state that this build doesn't
-- understand, carried through our own snapshots untouched.
--
-- Without this, one client on an older build silently deletes features it has
-- never heard of: it applies a newer board, keeps only the keys it knows, and
-- the next edit it makes broadcasts that truncated board back to everyone as
-- authoritative. Carrying the strangers through means an old client is a
-- faithful relay rather than a data shredder, which is what makes it safe to
-- widen the protocol check later -- additive changes stop being breaking.
--
-- Replaced wholesale on each apply rather than merged, so a key a newer client
-- legitimately REMOVES stays removed instead of being resurrected by us.
-- Session-only: it mirrors the current group's board, not ours to persist.
local carriedStateKeys = {}

-- A read-only view of the synced state, ready for immediate fingerprinting or
-- serialization. Those operations are synchronous, so copying the live tables
-- every two-second poll would only create garbage.
local function Snapshot()
    local p = WhoDoesWhat.db.profile
    local static = {}
    for id, name in pairs(p.raidAssignments) do
        if IsSyncedStaticRow(id) then static[id] = name end
    end
    local state = {
        roles = p.assignments,
        tank = p.tankAssignments,
        cc = p.ccAssignments,
        md = p.mdAssignments,
        static = static,
        paladinStrategy = p.paladinBuffRules,
        customRoles = p.raidCustomRoles,
        pallyBuffSource = p.settings.pallyBuffSource or "wdw",
        perms = { mode = p.permissions.mode, assistant = p.permissions.assistant },
    }
    -- Newer builds' keys ride along. They're part of the fingerprint too, which
    -- is correct: the snapshot has to equal what we'd actually send, or we'd
    -- broadcast a board that doesn't match the hash we compared against.
    for k, v in pairs(carriedStateKeys) do
        if state[k] == nil then state[k] = v end
    end
    return state
end

-- Overwrite the synced slice with a received snapshot. Tables are wiped and
-- refilled in place so nothing holding a reference goes stale. Unsynced
-- paladin-buff rows keep their local values.
local function ApplySnapshot(state)
    local p = WhoDoesWhat.db.profile

    -- Capture (not merge) whatever a newer build sent that we can't interpret,
    -- so our next broadcast relays it instead of dropping it. See
    -- carriedStateKeys.
    wipe(carriedStateKeys)
    for k, v in pairs(state) do
        if not KNOWN_STATE_KEYS[k] then
            carriedStateKeys[k] = type(v) == "table" and CopyTable(v) or v
        end
    end

    local function refill(dst, src)
        wipe(dst)
        for k, v in pairs(src or {}) do
            dst[k] = type(v) == "table" and CopyTable(v) or v
        end
    end

    refill(p.assignments, state.roles)
    refill(p.tankAssignments, state.tank)
    refill(p.ccAssignments, state.cc)
    refill(p.mdAssignments, state.md)
    refill(p.paladinBuffRules, state.paladinStrategy)
    refill(p.raidCustomRoles, state.customRoles)
    p.settings.pallyBuffSource = state.pallyBuffSource == "pallypower"
        and "pallypower" or "wdw"

    local perms = state.perms or WhoDoesWhat.DEFAULT_PERMISSIONS
    p.permissions.mode = perms.mode or WhoDoesWhat.DEFAULT_PERMISSIONS.mode
    p.permissions.assistant = perms.assistant or false

    for id in pairs(p.raidAssignments) do
        if IsSyncedStaticRow(id) then p.raidAssignments[id] = nil end
    end
    for id, name in pairs(state.static or {}) do
        p.raidAssignments[id] = name
    end

    -- The board's custom roles are role DEFINITIONS, so they have to be back
    -- in the id lookup before anything reads the roles map that points at them.
    WhoDoesWhat:PopulateRolesAndCategories()
end

-- True when the synced slice holds anything at all -- decides whether a
-- leader snapshot on join actually replaced something worth a popup.
local function BoardNonEmpty()
    local p = WhoDoesWhat.db.profile
    if next(p.assignments) then return true end
    if #p.paladinBuffRules > 0 then return true end
    if #p.raidCustomRoles > 0 then return true end
    for id in pairs(p.raidAssignments) do
        if IsSyncedStaticRow(id) then return true end
    end
    for _, store in ipairs({ p.tankAssignments, p.ccAssignments, p.mdAssignments }) do
        if #store > 0 then return true end
    end
    return false
end

-- Deterministic fingerprint of a snapshot: recursive dump with sorted keys
-- (pairs order isn't stable enough to compare serializations directly).
local function Canon(v)
    if type(v) ~= "table" then
        return type(v) .. ":" .. tostring(v)
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        if ta == "number" then return a < b end
        return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = tostring(k) .. "=" .. Canon(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function Fingerprint(state)
    return Canon(state or Snapshot())
end

-- ---------------------------------------------------------------------------
-- Traffic log
-- ---------------------------------------------------------------------------

local MAX_LOG = 500
local syncLog = {}
WhoDoesWhat.SyncLog = syncLog

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function DescribeMessage(msg)
    if msg.t == "STATE" then
        local s = msg.state or {}
        return string.format("board revision %s (%d roles, %d tanks, %d CC, %d misdirects, %d static, %d paladin rules, %d peers, %d observations)",
            tostring(msg.rev or "?"), Count(s.roles), #(s.tank or {}), #(s.cc or {}),
            #(s.md or {}), Count(s.static), #(s.paladinStrategy or {}),
            Count(msg.peers), Count(msg.observations))
    end
    if msg.t == "HELLO" then
        return msg.talents and "requests the leader's board and shares talent-tree totals"
            or "requests the leader's board"
    end
    if msg.t == "VERSION" then return "shares addon version" end
    if msg.t == "RANKS" then return "shares class utility-talent ranks" end
    if msg.t == "OBSERVE" then
        return "reports a direct talent inspection of " .. tostring(msg.player or "?")
    end
    if msg.t == "ROLE" then
        local _, role = WhoDoesWhat:FindRoleById(msg.role or "")
        return "sets own role to " .. (role and role.name or msg.role or "None")
    end
    return "unknown message type " .. tostring(msg.t)
end

local function AppendTraffic(dir, who, msg, channel, encoded)
    if not WhoDoesWhat.LOG_SYNC then return end
    local trimmed = false
    if #syncLog >= MAX_LOG then
        for _ = 1, 100 do table.remove(syncLog, 1) end
        trimmed = true
    end
    local entry = {
        t = date("%H:%M:%S"),
        dir = dir,
        who = who,
        channel = channel,
        msg = DescribeMessage(msg),
        encoded = encoded,
    }
    syncLog[#syncLog + 1] = entry
    if WhoDoesWhat.SyncLogAppended then
        WhoDoesWhat:SyncLogAppended(entry, trimmed)
    end
end

local function LogSyncStatus(...)
    if WhoDoesWhat.db.profile.settings.logSyncStatus then
        WhoDoesWhat:Print(...)
    end
end

-- ---------------------------------------------------------------------------
-- Wire encoding
-- ---------------------------------------------------------------------------

-- Serialize + deflate is the most expensive thing on the wire path, and it
-- scales with board size rather than with anything the caller can see, so it
-- gets its own section rather than hiding inside sync.poll / sync.recv.
local function Encode(msg)
    PBegin("sync.encode")
    local serialized = LibSerialize:Serialize(msg)
    local compressed = LibDeflate:CompressDeflate(serialized)
    local out = LibDeflate:EncodeForWoWAddonChannel(compressed)
    PEnd("sync.encode")
    return out
end

-- nil on anything malformed -- a garbled or foreign payload is dropped, never
-- an error in the receive path.
local function Decode(text)
    PBegin("sync.decode")
    local compressed = LibDeflate:DecodeForWoWAddonChannel(text)
    if not compressed then PEnd("sync.decode") return nil end
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then PEnd("sync.decode") return nil end
    local ok, msg = LibSerialize:Deserialize(serialized)
    PEnd("sync.decode")
    if not ok or type(msg) ~= "table" then return nil end
    return msg
end

-- The log only pays to decode and canonicalize an entry when its decoded view
-- is actually selected.
function WhoDoesWhat:DecodeSyncLogEntry(encoded)
    local msg = Decode(encoded)
    return msg and Canon(msg) or "<payload could not be decoded>"
end

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

-- Fingerprint of the board as last broadcast or applied; the poll broadcasts
-- when the live board drifts from it.
local lastSyncedFP = nil

-- Lamport-style revision: every broadcast is lastRev + 1, every applied
-- snapshot fast-forwards it. Ties (two members editing in the same beat)
-- break on sender name so the whole group converges on ONE of the two boards
-- instead of trading them forever.
local lastRev = 0
local lastRevSender = ""

-- True from sending HELLO until the leader's snapshot lands (or times out).
-- Suppresses the poll so a joiner never pushes their solo board at the raid.
local awaitingSync = false
local awaitTimer = nil

local ranksTimer = nil
local warnedProtocol = false
local peerVersions = {}
local peerProtocols = {}
-- Session consensus for directly useful talent facts. Unlike the saved talent
-- caches, this remembers the exact tree triplet that justified an inferred
-- role, so a later direct inspect can distinguish agreement from a respec.
local talentFacts = {}
local talentFactFP = {}
local needsPeerCollection = true

-- Our own role as last pushed over the ROLE message (unpermitted clients
-- only; see PollLocalChanges). Tracked so applying a remote board doesn't
-- echo the role right back out.
local lastOwnRoleSent = nil

local function IsNewerVersion(candidate, current)
    local a, b = {}, {}
    for n in tostring(candidate or ""):gmatch("%d+") do a[#a + 1] = tonumber(n) end
    for n in tostring(current or ""):gmatch("%d+") do b[#b + 1] = tonumber(n) end
    if #a == 0 or #b == 0 then return false end
    for i = 1, math.max(#a, #b) do
        local av, bv = a[i] or 0, b[i] or 0
        if av ~= bv then return av > bv end
    end
    return false
end

--@do-not-package@
local function NextPatchVersion(version)
    local major, minor, patch = tostring(version or ""):match("^(%d+)%.(%d+)%.(%d+)")
    if not major then return "999.0.0" end
    return string.format("%d.%d.%d", major, minor, tonumber(patch) + 1)
end
--@end-do-not-package@

function Sync:GetReportedAddonVersion()
--@do-not-package@
    -- The source-only test toggle makes this client behave like the next patch.
    if WhoDoesWhat.db.profile.settings.simulateNewerAddonVersion then
        return NextPatchVersion(WhoDoesWhat.VERSION)
    end
--@end-do-not-package@
    return WhoDoesWhat.VERSION
end

-- The current group leader under our name keying, or nil. Public because the
-- Blizzard-role writer election (Core.lua) needs to name the leader, not just
-- ask whether it is us.
function Sync:GroupLeaderName()
    return LeaderName()
end

-- Does `name` run a WDW build speaking our exact wire protocol? Presence alone
-- (syncPeers) is deliberately NOT enough for the role-flag writer election: a
-- sender is recorded as a peer BEFORE the protocol check, so a leader on an
-- out-of-date build still reads as "runs the addon" while ignoring every board
-- we send them. Electing that leader as sole flag writer means their stale
-- board wins forever and every other client fights it. Ourselves always count.
function Sync:RunsCompatibleProtocol(name)
    if not name then return false end
    if name == UnitKey("player") then return true end
    return peerProtocols[name] == PROTOCOL
end

local function RecordPeerVersion(name, version)
    if type(version) ~= "string" or version == "" then return end
    if peerVersions[name] == version then return end
    peerVersions[name] = version
    for _, peer in ipairs(Sync:GetNewerAddonVersions()) do
        if peer.name == name then
            WhoDoesWhat:Print("|cffff2020You are running WhoDoesWhat v"
                .. Sync:GetReportedAddonVersion() .. ", but " .. name
                .. " reports using version " .. version
                .. ". Update the addon to stay compatible.|r")
            break
        end
    end
    WhoDoesWhat:RefreshMainAssignmentsView()
end

-- Current group members running a newer addon build, sorted for the tooltip.
function Sync:GetNewerAddonVersions()
    local current = self:GetReportedAddonVersion()
    local members = {}
    local function AddMember(unit)
        local name = UnitKey(unit)
        if name then members[name] = true end
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do AddMember("raid" .. i) end
    else
        AddMember("player")
        for i = 1, GetNumSubgroupMembers() do AddMember("party" .. i) end
    end
    local newer = {}
    for name, version in pairs(peerVersions) do
        if members[name] and IsNewerVersion(version, current) then
            newer[#newer + 1] = { name = name, version = version }
        end
    end
    table.sort(newer, function(a, b) return a.name < b.name end)
    return newer
end

-- ---------------------------------------------------------------------------
-- Class utility-talent ranks
-- ---------------------------------------------------------------------------

-- Our own scanned ranks, or nil when we're not a paladin / not scanned yet.
local function OwnRanks()
    if select(2, UnitClass("player")) ~= "PALADIN" then return nil end
    local ranks = WhoDoesWhat.db.profile.paladinBuffTalents[UnitName("player")]
    return ranks and not ranks._source and ranks or nil
end

local function OwnHealthstoneRank()
    if select(2, UnitClass("player")) ~= "WARLOCK" then return nil end
    return WhoDoesWhat.db.profile.warlockHealthstoneTalents[UnitName("player")]
end

local function OwnCoreBuffRanks()
    local class = select(2, UnitClass("player"))
    if class ~= "DRUID" and class ~= "PRIEST" then return nil end
    return WhoDoesWhat.db.profile.coreBuffTalents[UnitName("player")]
end

local function StoreRanks(senderKey, ranks)
    if type(ranks) ~= "table" then return end
    local stored = {}
    for _, key in ipairs({ "might", "wisdom", "kings", "sanctuary" }) do
        stored[key] = tonumber(ranks[key]) or 0
    end
    WhoDoesWhat.db.profile.paladinBuffTalents[senderKey] = stored
    LogSync("buff-talent ranks stored for", senderKey)
    WhoDoesWhat:RefreshMainAssignmentsView()
    WhoDoesWhat:RefreshBoardViews()
end

local function StoreHealthstoneRank(senderKey, rank)
    rank = tonumber(rank)
    if not rank then return end
    rank = math.floor(math.max(0, math.min(WhoDoesWhat.WarlockHealthstone.maxRank, rank)))
    WhoDoesWhat.db.profile.warlockHealthstoneTalents[senderKey] = rank
    LogSync("healthstone talent rank stored for", senderKey)
    WhoDoesWhat:RefreshMainAssignmentsView()
    WhoDoesWhat:RefreshRaiderTooltip()
end

-- One transmitted core-buff rank, normalized. `false` -- the sender saying
-- that spec cannot cast the buff at all -- survives as itself, but only on a
-- gated buff where it means anything. Anything else is clamped into the
-- talent's range, and dropped outright when it isn't a number.
local function NormalizedCoreRank(value, buff)
    if value == false then
        if buff.requiredTalent then return false end
        return nil
    end
    local rank = tonumber(value)
    if rank == nil then return nil end
    return math.floor(math.max(0, math.min(buff.improvedTalent.maxRank, rank)))
end

local function StoreCoreBuffRanks(senderKey, ranks)
    if type(ranks) ~= "table" then return end
    -- The sender's other talent group, carried only for gated buffs (see
    -- ScanCoreBuffTalents) and validated the same way as the active spec.
    local sentOffspec = type(ranks.offspec) == "table" and ranks.offspec or nil
    local stored, offspec = {}, nil
    for key, buff in pairs(WhoDoesWhat.StatusBarChecks) do
        if buff.improvedTalent then
            if ranks[key] ~= nil then
                stored[key] = NormalizedCoreRank(ranks[key], buff)
            end
            if sentOffspec and sentOffspec[key] ~= nil then
                local value = NormalizedCoreRank(sentOffspec[key], buff)
                if value ~= nil then
                    offspec = offspec or {}
                    offspec[key] = value
                end
            end
        end
    end
    if not next(stored) then return end
    stored.offspec = offspec
    WhoDoesWhat.db.profile.coreBuffTalents[senderKey] = stored
    LogSync("core buff-talent ranks stored for", senderKey)
    WhoDoesWhat:RefreshBoardViews()
end

local PALADIN_RANK_MAX = { might = 5, wisdom = 2, kings = 1, sanctuary = 1 }

local function ClampedInteger(value, maximum)
    local n = tonumber(value)
    if not n then return nil end
    return math.floor(math.max(0, math.min(maximum, n)))
end

-- Normalize an observation before it can affect caches or role inference. The
-- roster supplies the target's class; callers never trust a transmitted role.
local function NormalizeTalentFact(class, talents, ranks, healthstone, coreRanks)
    if type(talents) ~= "table" then return nil end
    local points, total = {}, 0
    for i = 1, 3 do
        local n = tonumber(talents[i])
        if not n or n < 0 or n ~= math.floor(n) then return nil end
        points[i], total = n, total + n
    end
    -- 100 is intentionally future-proof across supported Classic variants,
    -- while still rejecting absurd or deliberately inflated payloads.
    if total == 0 or total > 100 then return nil end

    local fact = { class = class, talents = points }
    if class == "PALADIN" and type(ranks) == "table" then
        fact.ranks = {}
        for key, maximum in pairs(PALADIN_RANK_MAX) do
            fact.ranks[key] = ClampedInteger(ranks[key], maximum) or 0
        end
    elseif class == "WARLOCK" and healthstone ~= nil then
        fact.healthstone = ClampedInteger(healthstone,
            WhoDoesWhat.WarlockHealthstone.maxRank)
    elseif (class == "DRUID" or class == "PRIEST") and type(coreRanks) == "table" then
        local sentOffspec = type(coreRanks.offspec) == "table"
            and coreRanks.offspec or nil
        local offspec = nil
        fact.coreRanks = {}
        for key, buff in pairs(WhoDoesWhat.StatusBarChecks) do
            if buff.improvedTalent and string.upper(buff.className) == class then
                local rank = NormalizedCoreRank(coreRanks[key], buff)
                if rank ~= nil then fact.coreRanks[key] = rank end
                if sentOffspec then
                    local other = NormalizedCoreRank(sentOffspec[key], buff)
                    if other ~= nil then
                        offspec = offspec or {}
                        offspec[key] = other
                    end
                end
            end
        end
        if not next(fact.coreRanks) then
            fact.coreRanks = nil
        else
            fact.coreRanks.offspec = offspec
        end
    end
    return fact
end

-- Apply one sender's own HELLO or a direct third-party observation. Pinning a
-- previously clean board prevents the independently inferred role from
-- echoing back as STATE: every receiver already got the same evidence.
local function RememberTalentFact(playerName, class, talents, ranks, healthstone, coreRanks)
    local fact = NormalizeTalentFact(class, talents, ranks, healthstone, coreRanks)
    if not fact then return nil, false end
    local fingerprint = Canon(fact)
    local changed = talentFactFP[playerName] ~= fingerprint
    talentFacts[playerName] = fact
    talentFactFP[playerName] = fingerprint

    local wasClean = Fingerprint() == lastSyncedFP
    WhoDoesWhat:ApplySyncedTalentTreePoints(playerName, class, fact.talents)
    StoreRanks(playerName, fact.ranks)
    StoreHealthstoneRank(playerName, fact.healthstone)
    StoreCoreBuffRanks(playerName, fact.coreRanks)
    if wasClean then lastSyncedFP = Fingerprint() end
    return fact, changed
end

-- The leader's session directory lets one STATE replace one whisper reply per
-- peer. It contains only current roster members the leader has seen running
-- WDW (plus the leader itself); the saved, validated rank caches remain the
-- data source whether the fact came from that peer or a direct observation.
local function PeerDirectory()
    local p = WhoDoesWhat.db.profile
    local peers = {}
    local function Add(unit)
        local name = UnitKey(unit)
        if not name then return end
        local own = UnitIsUnit(unit, "player")
        if not own and peerProtocols[name] ~= PROTOCOL then return end
        local fact = talentFacts[name]
        peers[name] = {
            version = own and Sync:GetReportedAddonVersion() or peerVersions[name],
            talents = own and WhoDoesWhat:GetOwnTalentTreePoints()
                or (fact and fact.talents),
            ranks = own and OwnRanks() or (p.paladinBuffTalents[name]
                and not p.paladinBuffTalents[name]._source
                and p.paladinBuffTalents[name] or nil),
            healthstone = own and OwnHealthstoneRank() or p.warlockHealthstoneTalents[name],
            coreRanks = own and OwnCoreBuffRanks() or p.coreBuffTalents[name],
        }
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do Add("raid" .. i) end
    else
        Add("player")
        for i = 1, GetNumSubgroupMembers() do Add("party" .. i) end
    end
    return peers
end

-- Accept a directory only from the current leader (checked by the caller),
-- and only for players who are still in our roster. Individual rank writers
-- keep their existing validation and clamping.
local function ApplyPeerDirectory(peers)
    if type(peers) ~= "table" then return end
    local members = {}
    local ownName = UnitKey("player")
    local function Add(unit)
        local name = UnitKey(unit)
        if name then members[name] = true end
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do Add("raid" .. i) end
    else
        Add("player")
        for i = 1, GetNumSubgroupMembers() do Add("party" .. i) end
    end

    local newlySeen = false
    for name, peer in pairs(peers) do
        if type(name) == "string" and members[name] and type(peer) == "table"
            and name ~= ownName then
            if not WhoDoesWhat.syncPeers[name] then newlySeen = true end
            WhoDoesWhat.syncPeers[name] = true
            peerProtocols[name] = PROTOCOL
            RecordPeerVersion(name, peer.version)
            local class = ClassForPlayer(name)
            if not RememberTalentFact(name, class, peer.talents, peer.ranks,
                peer.healthstone, peer.coreRanks) then
                StoreRanks(name, peer.ranks)
                StoreHealthstoneRank(name, peer.healthstone)
                StoreCoreBuffRanks(name, peer.coreRanks)
            end
        end
    end
    if newlySeen then WhoDoesWhat:RefreshMembersView() end
end

-- Non-WDW players have no peer-directory entry of their own. The leader keeps
-- the latest direct observation for them beside the initial STATE so a later
-- joiner starts from the raid's accumulated view instead of rescanning all 39.
local function ObservationDirectory()
    local observations = {}
    local function Add(unit)
        local name = UnitKey(unit)
        local fact = name and talentFacts[name]
        if fact and peerProtocols[name] ~= PROTOCOL then observations[name] = fact end
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do Add("raid" .. i) end
    else
        Add("player")
        for i = 1, GetNumSubgroupMembers() do Add("party" .. i) end
    end
    return observations
end

local function ApplyObservationDirectory(observations)
    if type(observations) ~= "table" then return end
    for name, fact in pairs(observations) do
        local class = type(name) == "string" and ClassForPlayer(name)
        if class and type(fact) == "table" and fact.class == class then
            RememberTalentFact(name, class, fact.talents, fact.ranks,
                fact.healthstone, fact.coreRanks)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

function Sync:Send(msg, channel, target)
    msg.p = PROTOCOL
    msg.v = self:GetReportedAddonVersion()
    local encoded = Encode(msg)
    self:SendCommMessage(COMM_PREFIX, encoded, channel, target)
    AppendTraffic("out", target and SenderKey(target) or UnitName("player"), msg, channel,
        encoded)
    LogSync("sent", msg.t, "via", channel, target or "")
end

-- Broadcast the full board to the group (no-op solo).
function Sync:BroadcastState(state, fingerprint, collectPeers)
    local channel = GroupChannel()
    if not channel then return end
    state = state or Snapshot()
    -- Wall-clock-seeded Lamport rev: a plain counter resets to 0 on reload,
    -- and every broadcast from the fresh session would lose to the old
    -- session's higher revs sitting in everyone's lastRev -- silently
    -- rejected edits. Server time always moves past them; the +1 branch
    -- still orders multiple edits within the same second.
    lastRev = math.max(lastRev + 1, GetServerTime and GetServerTime() or time())
    lastRevSender = UnitName("player")
    lastSyncedFP = fingerprint or Fingerprint(state)
    self:Send({
        t = "STATE", rev = lastRev, state = state,
        peers = collectPeers and PeerDirectory() or nil,
        observations = collectPeers and ObservationDirectory() or nil,
        collectPeers = collectPeers or nil,
    }, channel)
end

-- Called only after LibClassicInspector says this client performed a live
-- inspect. Every raider may contribute evidence; assignment permissions are
-- irrelevant because OBSERVE describes talent facts, not a board edit.
function Sync:ReportTalentObservation(playerName, class, talents, ranks,
    healthstone, coreRanks, boardWasClean)
    local channel = GroupChannel()
    if not channel or playerName == UnitKey("player") then return end
    if ClassForPlayer(playerName) ~= class then return end

    local fact, changed = RememberTalentFact(playerName, class, talents, ranks,
        healthstone, coreRanks)
    if boardWasClean then lastSyncedFP = Fingerprint() end
    if not (fact and changed) then return end

    -- A normal WDW peer's HELLO already seeded the same fact, so in practice a
    -- first sighting is an unscanned non-WDW player. If HELLO lacked talents,
    -- the direct observation is still useful and costs only this one message.
    self:Send({
        t = "OBSERVE", player = playerName, class = class,
        talents = fact.talents, ranks = fact.ranks,
        healthstone = fact.healthstone, coreRanks = fact.coreRanks,
    }, channel)
end

function Sync:IsBoardClean()
    return Fingerprint() == lastSyncedFP
end

-- Rebuild session presence after the leader reloads. Unlike the old HELLO
-- response fanout this happens only for the leader's explicit collection and
-- uses group broadcasts, so every client learns the same facts at once.
local function BroadcastOwnPresence()
    local channel = GroupChannel()
    if not channel then return end
    local ranks = OwnRanks()
    local healthstone = OwnHealthstoneRank()
    local coreRanks = OwnCoreBuffRanks()
    if ranks or healthstone ~= nil or coreRanks then
        Sync:Send({
            t = "RANKS", ranks = ranks, healthstone = healthstone,
            coreRanks = coreRanks,
        }, channel)
    else
        Sync:Send({ t = "VERSION" }, channel)
    end
end

function Sync:BroadcastOwnRanksSoon()
    if ranksTimer or not GroupChannel() then return end
    ranksTimer = self:ScheduleTimer(function()
        ranksTimer = nil
        local ranks = OwnRanks()
        local healthstone = OwnHealthstoneRank()
        local coreRanks = OwnCoreBuffRanks()
        local channel = GroupChannel()
        if (ranks or healthstone ~= nil or coreRanks) and channel then
            self:Send({
                t = "RANKS", ranks = ranks, healthstone = healthstone,
                coreRanks = coreRanks,
            }, channel)
        end
    end, RANKS_DEBOUNCE)
end

-- ---------------------------------------------------------------------------
-- The local-change poll
-- ---------------------------------------------------------------------------

-- Run the change poll on a short debounce instead of waiting up to
-- POLL_INTERVAL. A role change is the one edit whose latency actually shows:
-- the picking client writes that player's Blizzard flag instantly, so everyone
-- else can see the flag move up to two seconds before the board explains why.
-- Nothing acts on that gap any more, but it still drives what Action Items
-- reports, so getting the board out promptly keeps the list honest.
--
-- Debounced rather than immediate so a burst of edits still coalesces into one
-- broadcast, which is the property the poll was built for.
local pushPending = false
function Sync:PushSoon()
    if pushPending then return end
    pushPending = true
    C_Timer.After(0.25, function()
        pushPending = false
        Sync:PollLocalChanges()
    end)
end

function Sync:PollLocalChanges()
    if not GroupChannel() or awaitingSync then return end

    if WhoDoesWhat:CanEditAssignments() then
        local state = Snapshot()
        local fingerprint = Fingerprint(state)
        if fingerprint ~= lastSyncedFP then
            self:BroadcastState(state, fingerprint)
            LogSync("local board changed; broadcast rev", lastRev)
        end
        return
    end

    -- Read-only client. The one edit still theirs is their own role; push
    -- that over ROLE when it changes. Everything else that drifts locally
    -- (talent detections of others, say) stays local -- pin the fingerprint
    -- so a later promotion to editor doesn't dump the accumulated drift at
    -- the group as if it were deliberate edits.
    lastSyncedFP = Fingerprint()
    local ownRole = WhoDoesWhat.db.profile.assignments[UnitName("player")]
    if ownRole ~= lastOwnRoleSent then
        lastOwnRoleSent = ownRole
        self:Send({ t = "ROLE", role = ownRole }, GroupChannel())
        LogSync("own role changed; broadcast ROLE", tostring(ownRole))
    end
end

-- ---------------------------------------------------------------------------
-- Join / leave
-- ---------------------------------------------------------------------------

StaticPopupDialogs["WHODOESWHAT_SYNC_REPLACED"] = {
    text = "%s",
    button1 = OKAY,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3, -- keep Blizzard's default dialog slots free (taint)
}

function Sync:OnGroupJoined(initialHello)
    initialHello = initialHello ~= false
    if initialHello then WhoDoesWhat:RequestPallyPowerPeers() end
    -- The leader IS the source of truth, so forming or leading a group means
    -- our board stands as-is; joiners will HELLO us for it.
    if UnitIsGroupLeader("player") then
        lastSyncedFP = Fingerprint()
        return
    end

    awaitingSync = true
    if awaitTimer then self:CancelTimer(awaitTimer) end
    awaitTimer = self:ScheduleTimer(function()
        awaitTimer = nil
        if awaitingSync then
            -- Leader never answered (no addon, or left mid-join): our board
            -- stands, and normal edit-broadcasts take over from here.
            awaitingSync = false
            lastSyncedFP = Fingerprint()
            LogSync("no leader snapshot within", JOIN_SYNC_TIMEOUT, "s; keeping local board")
        end
    end, JOIN_SYNC_TIMEOUT)

    self:RequestPeerPresence(initialHello)
end

-- Ask every WDW client in the group to answer. HELLO is deliberately reused:
-- released clients already answer it with STATE, RANKS, or VERSION depending
-- on their role/class, so the Members presence column works across
-- addon versions without another wire message.
function Sync:RequestPeerPresence(includeTalents)
    local channel = GroupChannel()
    if not channel then return end
    self:Send({
        t = "HELLO",
        talents = includeTalents and WhoDoesWhat:GetOwnTalentTreePoints() or nil,
        ranks = OwnRanks(),
        healthstone = OwnHealthstoneRank(),
        coreRanks = OwnCoreBuffRanks(),
    }, channel)
end

function Sync:OnGroupLeft()
    -- Party-to-raid conversion can fire GROUP_LEFT on some builds; only a
    -- real departure clears the board.
    if IsInGroup() then return end

    local hadAnything = BoardNonEmpty()
    local p = WhoDoesWhat.db.profile
    wipe(p.assignments)
    wipe(p.tankAssignments)
    wipe(p.ccAssignments)
    wipe(p.mdAssignments)
    wipe(p.raidAssignments)
    wipe(p.paladinBuffRules)
    -- Published custom roles were that raid's, not ours. The library entries
    -- they were copied from are untouched and can be added to the next one.
    wipe(p.raidCustomRoles)
    WhoDoesWhat:PopulateRolesAndCategories()
    p.settings.pallyBuffSource = "wdw"
    wipe(peerVersions)
    -- The editing rule was that raid's leader's; don't carry it into the next.
    WhoDoesWhat:ResetPermissions()
    lastOwnRoleSent = nil
    wipe(peerProtocols)
    wipe(talentFacts)
    wipe(talentFactFP)
    -- Carried keys described the departed group's board, not ours to relay on.
    wipe(carriedStateKeys)
    WhoDoesWhat:ClearRoleWriteLatch()

    -- The fake testing roster (FakeRaid.lua) isn't part of any real group;
    -- leaving one shouldn't eat it. Re-inject after the wipe.
    WhoDoesWhat:ReapplyFakeRaid()

    awaitingSync = false
    if awaitTimer then
        self:CancelTimer(awaitTimer)
        awaitTimer = nil
    end
    lastSyncedFP = Fingerprint()

    if hadAnything then
        LogSyncStatus("Left the group - all assignments cleared.")
    end
    RefreshAllViews()
end

-- Reloads and load screens (login, /reload, instance transitions) re-run the
-- handshake. A fresh session starts with an empty syncPeers, and GROUP_JOINED
-- doesn't fire on reload -- so without this a reloading member believes the
-- leader has no addon (the permission rule stands down) until the leader
-- happens to send something. Members redo the join pull (HELLO -> leader's
-- STATE whisper, which also marks the leader as a peer and adopts the group
-- rev); the leader instead announces with a full STATE broadcast, which does
-- all three jobs for everyone else in one message. Delayed a beat: the
-- roster isn't reliably filled right at PLAYER_ENTERING_WORLD.
function Sync:OnEnteringWorld()
    self:ScheduleTimer(function()
        if not GroupChannel() then return end
        if UnitIsGroupLeader("player") then
            WhoDoesWhat:RequestPallyPowerPeers()
            self:BroadcastState(nil, nil, needsPeerCollection)
            needsPeerCollection = false
        else
            self:OnGroupJoined()
        end
    end, 3)
end

-- GROUP_ROSTER_UPDATE fallback when the dedicated join/leave events aren't on
-- this build: detect the in-group edge ourselves.
local fallbackWasInGroup = nil
function Sync:OnRosterFallback()
    local inGroup = IsInGroup()
    if fallbackWasInGroup == nil then
        fallbackWasInGroup = inGroup
        return
    end
    if inGroup and not fallbackWasInGroup then
        self:OnGroupJoined()
    elseif fallbackWasInGroup and not inGroup then
        self:OnGroupLeft()
    end
    fallbackWasInGroup = inGroup
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------

-- Apply a received snapshot and converge the revision clock on it.
function Sync:ApplyState(msg, senderKey)
    local replacedSomething = awaitingSync and BoardNonEmpty()
        and Fingerprint() ~= Canon(msg.state)
    -- PallyPower rejects assignment changes from ordinary raiders. When the
    -- leader receives a board containing exactly one role change, relay that
    -- player's minimal blessing delta from the accepted authority instead.
    -- Capture the old roles before ApplySnapshot replaces the board.
    local oldRoles
    if UnitIsGroupLeader("player") then
        oldRoles = CopyTable(WhoDoesWhat.db.profile.assignments)
    end

    ApplySnapshot(msg.state)
    lastRev = math.max(lastRev, tonumber(msg.rev) or 0)
    lastRevSender = senderKey
    lastSyncedFP = Fingerprint()
    -- The applied board is now the shared truth, our own role included;
    -- without this a read-only client would "correct" it right back.
    lastOwnRoleSent = WhoDoesWhat.db.profile.assignments[UnitName("player")]

    if oldRoles then
        local changed, changedCount = nil, 0
        local newRoles = WhoDoesWhat.db.profile.assignments
        local seen = {}
        for name, oldRole in pairs(oldRoles) do
            seen[name] = true
            if newRoles[name] ~= oldRole then
                changed, changedCount = name, changedCount + 1
            end
        end
        for name in pairs(newRoles) do
            if not seen[name] then
                changed, changedCount = name, changedCount + 1
            end
        end
        if changedCount == 1 then
            WhoDoesWhat:PushPlayerBuffToPallyPower(changed)
        end
    end

    if awaitingSync then
        awaitingSync = false
        if awaitTimer then
            self:CancelTimer(awaitTimer)
            awaitTimer = nil
        end
        LogSyncStatus("Assignments synced from the group leader (" .. senderKey .. ").")
        if replacedSomething then
            StaticPopup_Show("WHODOESWHAT_SYNC_REPLACED",
                "The group leader's assignments have replaced your local"
                .. " WhoDoesWhat board (leader: " .. senderKey .. ").")
        end
    else
        LogSyncStatus("Assignments updated from " .. senderKey .. ".")
    end
    -- Deliberately does NOT push Blizzard role flags. The board and the flag
    -- travel by different routes at different speeds, so a client acting here
    -- acts on whichever arrived first -- which is how the leader ended up
    -- "correcting" a player who had just set their own role. Differences are
    -- surfaced in Action Items for a human to apply instead.
    RefreshAllViews()
end

function Sync:OnCommReceived(prefix, text, distribution, sender)
    if prefix ~= COMM_PREFIX then return end
    local senderKey = SenderKey(sender)
    if senderKey == UnitName("player") then return end -- our own broadcast echoing back

    local msg = Decode(text)
    if not msg then return end
    AppendTraffic("in", senderKey, msg, distribution, text)
    RecordPeerVersion(senderKey, msg.v)
    peerProtocols[senderKey] = msg.p

    -- Any WDW traffic proves the sender runs the addon -- even a mismatched
    -- version (below). Permissions.lua checks the current leader against
    -- this to stand the editing rule down when the leader can't own it.
    local newlySeen = WhoDoesWhat.syncPeers[senderKey] ~= true
    WhoDoesWhat.syncPeers[senderKey] = true
    if newlySeen then WhoDoesWhat:RefreshMembersView() end

    if msg.p ~= PROTOCOL then
        if not warnedProtocol then
            warnedProtocol = true
            WhoDoesWhat:Print(senderKey .. " runs a different WhoDoesWhat sync version;"
                .. " assignments won't sync with them until versions match.")
        end
        return
    end
    LogSync("received", msg.t, "from", senderKey, "via", distribution)

    if msg.t == "STATE" and type(msg.state) == "table" then
        local fromLeader = senderKey == LeaderName()
        if distribution == "WHISPER" then
            -- The join flow's leader answer. Anyone else whispering a board
            -- (or a stale leader answer after the timeout) is ignored.
            if awaitingSync and fromLeader then
                ApplyPeerDirectory(msg.peers)
                ApplyObservationDirectory(msg.observations)
                self:ApplyState(msg, senderKey)
            end
            return
        end
        -- Only editors get to move the shared board (judged by OUR current
        -- permission belief; the leader always passes). A stale-permission
        -- client broadcasting anyway is dropped here on every receiver.
        if not WhoDoesWhat:PlayerCanEditAssignments(senderKey) then
            LogSync("board from", senderKey, "rejected: no edit permission")
            return
        end
        if fromLeader then
            ApplyPeerDirectory(msg.peers)
            ApplyObservationDirectory(msg.observations)
            if msg.collectPeers then BroadcastOwnPresence() end
        end
        -- Group broadcast: last write wins, name as tiebreak (see lastRev).
        local rev = tonumber(msg.rev) or 0
        if rev > lastRev or (rev == lastRev and senderKey < lastRevSender) then
            self:ApplyState(msg, senderKey)
        else
            LogSync("stale rev", rev, "from", senderKey, "ignored (have", lastRev, ")")
        end

    elseif msg.t == "HELLO" then
        local class = ClassForPlayer(senderKey)
        if class and msg.talents then
            -- The group broadcast already delivered this fact to every client;
            -- do not echo the inferred assignment back as another board edit.
            RememberTalentFact(senderKey, class, msg.talents, msg.ranks,
                msg.healthstone, msg.coreRanks)
        end
        if not (class and msg.talents) then
            StoreRanks(senderKey, msg.ranks)
            StoreHealthstoneRank(senderKey, msg.healthstone)
            StoreCoreBuffRanks(senderKey, msg.coreRanks)
        end
        -- Everyone consumes the announcement. A compatible leader is the sole
        -- responder; its directory replaces the old one-whisper-per-peer
        -- fanout. Stable peers retain that fallback only without a compiler.
        if UnitIsGroupLeader("player") then
            self:Send({
                t = "STATE", rev = lastRev, state = Snapshot(),
                peers = PeerDirectory(),
                observations = ObservationDirectory(),
            }, "WHISPER", sender)
        elseif not awaitingSync and peerProtocols[LeaderName()] ~= PROTOCOL then
            -- Without a compatible WDW leader there is no compiler. Preserve
            -- the old presence/rank discovery fallback for stable peers only;
            -- reloading peers stay silent so simultaneous reloads do not fan
            -- out at each other.
            local ranks = OwnRanks()
            local healthstone = OwnHealthstoneRank()
            local coreRanks = OwnCoreBuffRanks()
            if ranks or healthstone ~= nil or coreRanks then
                self:Send({
                    t = "RANKS", ranks = ranks, healthstone = healthstone,
                    coreRanks = coreRanks,
                }, "WHISPER", sender)
            else
                self:Send({ t = "VERSION" }, "WHISPER", sender)
            end
        end

    elseif msg.t == "RANKS" then
        StoreRanks(senderKey, msg.ranks)
        StoreHealthstoneRank(senderKey, msg.healthstone)
        StoreCoreBuffRanks(senderKey, msg.coreRanks)

    elseif msg.t == "VERSION" then
        -- Version was recorded before message dispatch; no payload needed.

    elseif msg.t == "OBSERVE" then
        -- Observations are group evidence from a current member about another
        -- current member. Whispers are rejected so there is one shared view.
        if distribution == "WHISPER" or not ClassForPlayer(senderKey)
            or msg.player == senderKey then return end
        local class = type(msg.player) == "string" and ClassForPlayer(msg.player)
        if class and msg.class == class then
            RememberTalentFact(msg.player, class, msg.talents, msg.ranks,
                msg.healthstone, msg.coreRanks)
        end

    elseif msg.t == "ROLE" then
        -- A player's OWN role -- the one edit that never needs board rights.
        -- Only ever applies to the sender themselves, so it can't be used to
        -- move anyone else's assignment.
        if msg.role ~= nil and type(msg.role) ~= "string" then return end
        local p = WhoDoesWhat.db.profile
        if p.assignments[senderKey] ~= msg.role then
            -- Don't let this ride the poll back out as a full-board edit of
            -- ours -- unless we already had unbroadcast edits pending, in
            -- which case the poll's next snapshot carries it anyway.
            local wasClean = Fingerprint() == lastSyncedFP
            p.assignments[senderKey] = msg.role
            if wasClean then lastSyncedFP = Fingerprint() end
            if UnitIsGroupLeader("player") then
                WhoDoesWhat:PushPlayerBuffToPallyPower(senderKey)
            end
            local _, role = WhoDoesWhat:FindRoleById(msg.role or "")
            LogSyncStatus(senderKey .. " set their own role to "
                .. (role and role.name or msg.role or "None") .. ".")
            -- Their own broadcast carries no Blizzard flag, and we no longer
            -- set one for them: they already wrote their own when they picked
            -- the role, and us writing it again from a board that may or may
            -- not have caught up is exactly the fight this removed.
            WhoDoesWhat:RefreshMainAssignmentsView()
            WhoDoesWhat:RefreshMembersView()
            -- Their role reshapes the blessing plan, same as a local role
            -- change: repaint the grid/bars/diff window off the plan hook.
            WhoDoesWhat:RefreshBoardViews()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Manual resync (/wdw sync): joiner-style pull from the leader, or a push of
-- the current board when we ARE the leader.
-- ---------------------------------------------------------------------------

function Sync:ForceSync()
    if not GroupChannel() then
        WhoDoesWhat:Print("Sync: you are not in a group.")
        return
    end
    if UnitIsGroupLeader("player") then
        self:BroadcastState()
        WhoDoesWhat:LogOperation("Sync: broadcast your board to the group.")
    else
        self:OnGroupJoined(false)
        WhoDoesWhat:LogOperation("Sync: requested the board from the group leader.")
    end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function Sync:OnEnable()
    self:RegisterComm(COMM_PREFIX)

    -- Baseline so being grouped at login/reload doesn't broadcast the saved
    -- board at everyone; only changes from here on are pushed.
    lastSyncedFP = Fingerprint()
    lastOwnRoleSent = WhoDoesWhat.db.profile.assignments[UnitName("player")]

    -- GROUP_JOINED/GROUP_LEFT exist on the Anniversary client, but register
    -- defensively (the TalentScanning dual-spec events needed the same); any
    -- miss falls back to edge-detection on GROUP_ROSTER_UPDATE.
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEnteringWorld")
    local okJoined = pcall(self.RegisterEvent, self, "GROUP_JOINED", "OnGroupJoined")
    local okLeft = pcall(self.RegisterEvent, self, "GROUP_LEFT", "OnGroupLeft")
    if not (okJoined and okLeft) then
        fallbackWasInGroup = IsInGroup()
        self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnRosterFallback")
        LogSync("join/leave events unavailable; using roster fallback")
    end

    self:ScheduleRepeatingTimer("PollLocalChanges", POLL_INTERVAL)

    -- Whenever our OWN utility talents get (re)scanned -- login, respec,
    -- dual-spec swap (see the selfSync frame in TalentScanning.lua) -- share
    -- the fresh ranks. hooksecurefunc keeps sync concerns out of that file.
    hooksecurefunc(WhoDoesWhat, "ScanPaladinBuffTalents", function(_, guid)
        if guid == UnitGUID("player") then
            Sync:BroadcastOwnRanksSoon()
        end
    end)
    hooksecurefunc(WhoDoesWhat, "ScanWarlockHealthstoneTalent", function(_, guid)
        if guid == UnitGUID("player") then
            Sync:BroadcastOwnRanksSoon()
        end
    end)
    hooksecurefunc(WhoDoesWhat, "ScanCoreBuffTalents", function(_, guid)
        if guid == UnitGUID("player") then
            Sync:BroadcastOwnRanksSoon()
        end
    end)
end
