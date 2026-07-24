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
--     Assignments.lua) -- so there are no paladin rows to sync; the talent
--     facts below are what keep every client's computation in agreement.
--     IsSyncedStaticRow still filters the keys as a safety.
--   - paladin buff-talent ranks: each paladin broadcasts their OWN four ranks
--     (might/wisdom/kings/sanctuary), read from their own client's native
--     talent API -- the one source that is always in range and never hits the
--     shuffled-index bug (see TalentScanning.lua). Receivers drop the ranks
--     straight into db.profile.paladinBuffTalents. This is what the old NRC
--     talent-string reference code in this file was for; reading ranks on the
--     SENDER makes an order-proof wire encoding unnecessary, so four small
--     numbers replace the whole string format. Spec/role detection for
--     out-of-range users already syncs via LibClassicInspector's own
--     broadcasts, so it isn't duplicated here.
--
-- Conflict model:
--   - Leaving the group wipes the whole board (roles included): assignments
--     are group business, and a stale board from the last raid only misleads.
--     The talent caches (talentSpecs / paladinBuffTalents) survive -- they're
--     facts about characters, not group decisions, and they let roles refill
--     instantly when a group reforms.
--   - Joining a group makes the LEADER the source of truth: the joiner says
--     HELLO, the leader whispers back a full snapshot, and the joiner's local
--     board is replaced outright (a popup says so when it overwrote anything).
--     No reply within JOIN_SYNC_TIMEOUT (leader without the addon) means the
--     joiner keeps what they have and normal syncing takes over.
--   - While grouped, any PERMITTED member's edit broadcasts the full board
--     (who is permitted is the leader-owned rule in Permissions.lua, itself
--     part of the snapshot). Unpermitted clients broadcast nothing except
--     their own role over the dedicated ROLE message (the one edit everyone
--     keeps), and everyone rejects board snapshots from unpermitted senders.
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

local COMM_PREFIX = "WhoDoesWhat"
-- Bump on any wire-format change; mismatched clients warn once and ignore
-- each other. 2: tank rows went one-per-tank with a `markers` array (was
-- one-per-marker with a single `marker`).
local PROTOCOL = 2
local POLL_INTERVAL = 2 -- seconds between local-change fingerprint checks
local JOIN_SYNC_TIMEOUT = 5 -- seconds a joiner waits for the leader's snapshot
local RANKS_DEBOUNCE = 2 -- seconds to let a talent-scan burst settle before broadcasting

-- Chat-spam toggle in the LOG_TALENTS mold. Traffic is always retained for
-- the Sync Log view; this only controls whether it is also printed to chat.
WhoDoesWhat.LOG_SYNC = false

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
    WhoDoesWhat:RefreshRaiderRolesView()
    WhoDoesWhat:RefreshPaladinBuffGridView()
end

-- ---------------------------------------------------------------------------
-- Snapshot: the synced slice of the profile
-- ---------------------------------------------------------------------------

-- Static rows sync unless they're paladin buff rows (see the header).
local function IsSyncedStaticRow(rowId)
    return not WhoDoesWhat.PaladinBuffs[rowId]
end

-- Deep-copy the synced state into one plain table, ready to serialize.
local function Snapshot()
    local p = WhoDoesWhat.db.profile
    local static = {}
    for id, name in pairs(p.raidAssignments) do
        if IsSyncedStaticRow(id) then static[id] = name end
    end
    return {
        roles = CopyTable(p.assignments),
        tank = CopyTable(p.tankAssignments),
        cc = CopyTable(p.ccAssignments),
        md = CopyTable(p.mdAssignments),
        static = static,
        perms = { mode = p.permissions.mode, assistant = p.permissions.assistant },
    }
end

-- Overwrite the synced slice with a received snapshot. Tables are wiped and
-- refilled in place so nothing holding a reference goes stale. Unsynced
-- paladin-buff rows keep their local values.
local function ApplySnapshot(state)
    local p = WhoDoesWhat.db.profile

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

    local perms = state.perms or WhoDoesWhat.DEFAULT_PERMISSIONS
    p.permissions.mode = perms.mode or WhoDoesWhat.DEFAULT_PERMISSIONS.mode
    p.permissions.assistant = perms.assistant or false

    for id in pairs(p.raidAssignments) do
        if IsSyncedStaticRow(id) then p.raidAssignments[id] = nil end
    end
    for id, name in pairs(state.static or {}) do
        p.raidAssignments[id] = name
    end
end

-- True when the synced slice holds anything at all -- decides whether a
-- leader snapshot on join actually replaced something worth a popup.
local function BoardNonEmpty()
    local p = WhoDoesWhat.db.profile
    if next(p.assignments) then return true end
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

local function Fingerprint()
    return Canon(Snapshot())
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
        return string.format("board revision %s (%d roles, %d tanks, %d CC, %d misdirects, %d static)",
            tostring(msg.rev or "?"), Count(s.roles), #(s.tank or {}), #(s.cc or {}),
            #(s.md or {}), Count(s.static))
    end
    if msg.t == "HELLO" then return "requests the leader's board" end
    if msg.t == "RANKS" then return "shares paladin buff-talent ranks" end
    if msg.t == "ROLE" then
        local _, role = WhoDoesWhat:FindRoleById(msg.role or "")
        return "sets own role to " .. (role and role.name or msg.role or "None")
    end
    return "unknown message type " .. tostring(msg.t)
end

local function AppendTraffic(dir, who, msg, channel)
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
        raw = Canon(msg),
    }
    syncLog[#syncLog + 1] = entry
    if WhoDoesWhat.SyncLogAppended then
        WhoDoesWhat:SyncLogAppended(entry, trimmed)
    end
end

-- ---------------------------------------------------------------------------
-- Wire encoding
-- ---------------------------------------------------------------------------

local function Encode(msg)
    local serialized = LibSerialize:Serialize(msg)
    local compressed = LibDeflate:CompressDeflate(serialized)
    return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

-- nil on anything malformed -- a garbled or foreign payload is dropped, never
-- an error in the receive path.
local function Decode(text)
    local compressed = LibDeflate:DecodeForWoWAddonChannel(text)
    if not compressed then return nil end
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then return nil end
    local ok, msg = LibSerialize:Deserialize(serialized)
    if not ok or type(msg) ~= "table" then return nil end
    return msg
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

-- Our own role as last pushed over the ROLE message (unpermitted clients
-- only; see PollLocalChanges). Tracked so applying a remote board doesn't
-- echo the role right back out.
local lastOwnRoleSent = nil

-- ---------------------------------------------------------------------------
-- Paladin buff-talent ranks
-- ---------------------------------------------------------------------------

-- Our own scanned ranks, or nil when we're not a paladin / not scanned yet.
local function OwnRanks()
    if select(2, UnitClass("player")) ~= "PALADIN" then return nil end
    return WhoDoesWhat.db.profile.paladinBuffTalents[UnitName("player")]
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
    WhoDoesWhat:RefreshPaladinBuffGridView()
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

function Sync:Send(msg, channel, target)
    msg.p = PROTOCOL
    self:SendCommMessage(COMM_PREFIX, Encode(msg), channel, target)
    AppendTraffic("out", target and SenderKey(target) or UnitName("player"), msg, channel)
    LogSync("sent", msg.t, "via", channel, target or "")
end

-- Broadcast the full board to the group (no-op solo).
function Sync:BroadcastState()
    local channel = GroupChannel()
    if not channel then return end
    -- Wall-clock-seeded Lamport rev: a plain counter resets to 0 on reload,
    -- and every broadcast from the fresh session would lose to the old
    -- session's higher revs sitting in everyone's lastRev -- silently
    -- rejected edits. Server time always moves past them; the +1 branch
    -- still orders multiple edits within the same second.
    lastRev = math.max(lastRev + 1, GetServerTime and GetServerTime() or time())
    lastRevSender = UnitName("player")
    lastSyncedFP = Fingerprint()
    self:Send({ t = "STATE", rev = lastRev, state = Snapshot() }, channel)
end

function Sync:BroadcastOwnRanksSoon()
    if ranksTimer or not GroupChannel() then return end
    ranksTimer = self:ScheduleTimer(function()
        ranksTimer = nil
        local ranks = OwnRanks()
        local channel = GroupChannel()
        if ranks and channel then
            self:Send({ t = "RANKS", ranks = ranks }, channel)
        end
    end, RANKS_DEBOUNCE)
end

-- ---------------------------------------------------------------------------
-- The local-change poll
-- ---------------------------------------------------------------------------

function Sync:PollLocalChanges()
    if not GroupChannel() or awaitingSync then return end

    if WhoDoesWhat:CanEditAssignments() then
        if Fingerprint() ~= lastSyncedFP then
            self:BroadcastState()
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

function Sync:OnGroupJoined()
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

    local channel = GroupChannel()
    if channel then
        self:Send({ t = "HELLO", ranks = OwnRanks() }, channel)
    end
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
    -- The editing rule was that raid's leader's; don't carry it into the next.
    WhoDoesWhat:ResetPermissions()
    lastOwnRoleSent = nil

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
        WhoDoesWhat:Print("Left the group - all assignments cleared.")
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
            self:BroadcastState()
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
    -- Capture both the old roles and old PallyPower drift before ApplySnapshot
    -- replaces the board.
    local oldRoles, priorPallyPowerDiffs
    if UnitIsGroupLeader("player") then
        oldRoles = CopyTable(WhoDoesWhat.db.profile.assignments)
        priorPallyPowerDiffs = WhoDoesWhat:CheckPallyPowerSync()
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
            WhoDoesWhat:PushPlayerBuffToPallyPower(changed, priorPallyPowerDiffs)
        end
    end

    if awaitingSync then
        awaitingSync = false
        if awaitTimer then
            self:CancelTimer(awaitTimer)
            awaitTimer = nil
        end
        WhoDoesWhat:Print("Assignments synced from the group leader (" .. senderKey .. ").")
        if replacedSomething then
            StaticPopup_Show("WHODOESWHAT_SYNC_REPLACED",
                "The group leader's assignments have replaced your local"
                .. " WhoDoesWhat board (leader: " .. senderKey .. ").")
        end
    else
        WhoDoesWhat:Print("Assignments updated from " .. senderKey .. ".")
    end
    -- The board just moved over the wire, which never touches Blizzard flags on
    -- its own. If we're the flag-authority (leader), push the flags now so a
    -- role an assist edited lands as one UnitSetRole from us -- not a race
    -- between every assist. No-ops for non-leaders past their own flag.
    WhoDoesWhat:ReconcileBlizzardRoles()
    RefreshAllViews()
end

function Sync:OnCommReceived(prefix, text, distribution, sender)
    if prefix ~= COMM_PREFIX then return end
    local senderKey = SenderKey(sender)
    if senderKey == UnitName("player") then return end -- our own broadcast echoing back

    local msg = Decode(text)
    if not msg then return end
    AppendTraffic("in", senderKey, msg, distribution)

    -- Any WDW traffic proves the sender runs the addon -- even a mismatched
    -- version (below). Permissions.lua checks the current leader against
    -- this to stand the editing rule down when the leader can't own it.
    WhoDoesWhat.syncPeers[senderKey] = true

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
        if distribution == "WHISPER" then
            -- The join flow's leader answer. Anyone else whispering a board
            -- (or a stale leader answer after the timeout) is ignored.
            if awaitingSync and senderKey == LeaderName() then
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
        -- Group broadcast: last write wins, name as tiebreak (see lastRev).
        local rev = tonumber(msg.rev) or 0
        if rev > lastRev or (rev == lastRev and senderKey < lastRevSender) then
            self:ApplyState(msg, senderKey)
        else
            LogSync("stale rev", rev, "from", senderKey, "ignored (have", lastRev, ")")
        end

    elseif msg.t == "HELLO" then
        StoreRanks(senderKey, msg.ranks)
        -- The leader answers with the authoritative board; every paladin
        -- answers with their ranks so the joiner's paladin views fill in.
        if UnitIsGroupLeader("player") then
            self:Send({ t = "STATE", rev = lastRev, state = Snapshot() }, "WHISPER", sender)
        end
        local ranks = OwnRanks()
        if ranks then
            self:Send({ t = "RANKS", ranks = ranks }, "WHISPER", sender)
        end

    elseif msg.t == "RANKS" then
        StoreRanks(senderKey, msg.ranks)

    elseif msg.t == "ROLE" then
        -- A player's OWN role -- the one edit that never needs board rights.
        -- Only ever applies to the sender themselves, so it can't be used to
        -- move anyone else's assignment.
        if msg.role ~= nil and type(msg.role) ~= "string" then return end
        local p = WhoDoesWhat.db.profile
        if p.assignments[senderKey] ~= msg.role then
            local priorPallyPowerDiffs = UnitIsGroupLeader("player")
                and WhoDoesWhat:CheckPallyPowerSync() or nil
            -- Don't let this ride the poll back out as a full-board edit of
            -- ours -- unless we already had unbroadcast edits pending, in
            -- which case the poll's next snapshot carries it anyway.
            local wasClean = Fingerprint() == lastSyncedFP
            p.assignments[senderKey] = msg.role
            if wasClean then lastSyncedFP = Fingerprint() end
            if UnitIsGroupLeader("player") then
                WhoDoesWhat:PushPlayerBuffToPallyPower(senderKey, priorPallyPowerDiffs)
            end
            local _, role = WhoDoesWhat:FindRoleById(msg.role or "")
            WhoDoesWhat:Print(senderKey .. " set their own role to "
                .. (role and role.name or msg.role or "None") .. ".")
            -- Their own broadcast carries no Blizzard flag; if we're the
            -- flag-authority (leader), apply it for them so exactly one client
            -- does the UnitSetRole.
            WhoDoesWhat:ReconcileBlizzardRoles()
            WhoDoesWhat:RefreshMainAssignmentsView()
            WhoDoesWhat:RefreshRaiderRolesView()
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
        WhoDoesWhat:Print("Sync: broadcast your board to the group.")
    else
        self:OnGroupJoined()
        WhoDoesWhat:Print("Sync: requested the board from the group leader.")
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

    -- Whenever our OWN buff talents get (re)scanned -- login, respec,
    -- dual-spec swap (see the selfSync frame in TalentScanning.lua) -- share
    -- the fresh ranks. hooksecurefunc keeps sync concerns out of that file.
    hooksecurefunc(WhoDoesWhat, "ScanPaladinBuffTalents", function(_, guid)
        if guid == UnitGUID("player") then
            Sync:BroadcastOwnRanksSoon()
        end
    end)
end
