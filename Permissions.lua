local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Who may edit the shared assignments board. Raid-only: parties and solo play
-- are always open (a 5-man doesn't need bureaucracy). The RAID LEADER owns the
-- setting -- it lives in db.profile.permissions, rides the sync snapshot like
-- the rest of the board, and every client enforces the same rule: the UI
-- renders read-only for the unpermitted (MainAssignmentsView / unit menu /
-- RaiderRolesView), the Set* APIs refuse, and Sync.lua both suppresses their
-- broadcasts and rejects board snapshots from unpermitted senders.
--
-- Modes (db.profile.permissions.mode):
--   "leader"    only the raid leader
--   "assistant" the leader plus ONE named player (permissions.assistant)
--   "assists"   the leader plus every raid assistant  <- default: matches the
--               assist-gating the unit menu had before permissions existed
--   "everyone"  any raid member
--
-- The one universal exception: everyone may always set their OWN role
-- (CanEditRoleOf), and Sync.lua carries those own-role changes for
-- unpermitted players over a dedicated ROLE message.
--
-- Leaving the group resets the setting to default (Sync.lua's board wipe),
-- so a mode synced in from last raid's leader never haunts the next one.

-- The rule stands down entirely (everyone edits, "free-assign") when there is
-- no leader to own it: battleground groups, and raids whose current leader
-- isn't known to run WhoDoesWhat -- see PermissionsOpenReason. Leadership can
-- change mid-raid, so this is checked live, never cached.

WhoDoesWhat.DEFAULT_PERMISSIONS = { mode = "assists", assistant = false }

-- Players known to run WhoDoesWhat: Sync.lua records every player it receives
-- any addon message from. Session-only knowledge, and deliberately never
-- wiped -- that someone runs the addon stays true across regroups.
WhoDoesWhat.syncPeers = {}

function WhoDoesWhat:GetPermissions()
    return self.db.profile.permissions
end

function WhoDoesWhat:ResetPermissions()
    local perms = self.db.profile.permissions
    perms.mode = WhoDoesWhat.DEFAULT_PERMISSIONS.mode
    perms.assistant = WhoDoesWhat.DEFAULT_PERMISSIONS.assistant
end

-- A raid member's rank (2 leader, 1 assist, 0 raider) under our name keying,
-- or nil when they're not in the raid.
local function RaidRankOf(name)
    for i = 1, GetNumGroupMembers() do
        local n, rank = GetRaidRosterInfo(i)
        if n == name then return rank end
    end
    return nil
end

-- Does the current raid leader run WhoDoesWhat? Without it they can't own
-- the rule (they can't see it, set it, or answer a join sync), so enforcing
-- their "permissions" would just lock everyone out of a board nobody leads.
-- A leaderless moment (mid-roster-change) reads as "no", which errs open.
function WhoDoesWhat:LeaderRunsAddon()
    if UnitIsGroupLeader("player") then return true end -- that's us
    for i = 1, GetNumGroupMembers() do
        local name, rank = GetRaidRosterInfo(i)
        if rank == 2 then
            return self.syncPeers[name] == true
        end
    end
    return false
end

-- Why the permission rule is currently bypassed wholesale (everyone edits),
-- or nil when it's in force. Shown in the main view's note so a raider knows
-- why the board is suddenly open.
function WhoDoesWhat:PermissionsOpenReason()
    if not IsInRaid() then return nil end
    local _, instanceType = IsInInstance()
    if instanceType == "pvp" then return "battleground" end
    if not self:LeaderRunsAddon() then return "leader has no WhoDoesWhat" end
    return nil
end

-- May `name` edit the shared board right now? Used both for the local player
-- (all the UI gating) and by Sync.lua to decide whether a received board
-- broadcast comes from someone entitled to make it.
function WhoDoesWhat:PlayerCanEditAssignments(name)
    if not IsInRaid() then return true end -- parties and solo are always open
    local rank = RaidRankOf(name)
    if not rank then return false end -- not in the raid at all
    if rank == 2 then return true end -- the leader always may
    if self:PermissionsOpenReason() then return true end -- BG / addonless leader
    local perms = self.db.profile.permissions
    if perms.mode == "everyone" then return true end
    if perms.mode == "assists" then return rank >= 1 end
    if perms.mode == "assistant" then return perms.assistant == name end
    return false -- "leader"
end

function WhoDoesWhat:CanEditAssignments()
    return self:PlayerCanEditAssignments(UnitName("player"))
end

-- Your own role is always yours to set; everyone else's takes board rights.
function WhoDoesWhat:CanEditRoleOf(name)
    return name == UnitName("player") or self:CanEditAssignments()
end

-- Human-readable current rule, for the picker button, the read-only note and
-- the denial print. Plain text (no escapes) so it can go to group chat too.
function WhoDoesWhat:PermissionModeLabel()
    local perms = self.db.profile.permissions
    if perms.mode == "leader" then return "leader only" end
    if perms.mode == "assistant" then
        return "leader + " .. (perms.assistant or "?")
    end
    if perms.mode == "everyone" then return "everyone" end
    return "leader + assistants"
end

-- Gate for the Set* APIs: true when the local player may edit, otherwise
-- explains why not in chat and returns false.
function WhoDoesWhat:RequireEditPermission()
    if self:CanEditAssignments() then return true end
    self:Print("You can't edit assignments: the raid leader has editing set to "
        .. self:PermissionModeLabel() .. ".")
    return false
end

-- Change the rule (leader only; anyone may call solo/in a party, where it
-- only pre-sets what their next raid will use). `assistant` names the single
-- editor for "assistant" mode. The sync poll picks the change up like any
-- other board edit and every client's UI follows.
function WhoDoesWhat:SetPermissionMode(mode, assistant)
    if IsInRaid() and not UnitIsGroupLeader("player") then
        self:Print("Only the raid leader can change editing permissions.")
        return
    end
    local perms = self.db.profile.permissions
    if perms.mode == mode and (perms.assistant or false) == (assistant or false) then
        return
    end
    perms.mode = mode
    perms.assistant = assistant or false
    self:Print("Editing permissions: " .. self:PermissionModeLabel() .. ".")
    self:SendGroupMessage("[WhoDoesWhat] Assignment editing is now: "
        .. self:PermissionModeLabel() .. ".")
    self:RefreshMainAssignmentsView()
    self:RefreshRaiderRolesView()
end
