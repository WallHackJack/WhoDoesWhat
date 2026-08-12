local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- LibClassicInspector caches other players' talents from two sources, and only
-- these two: inspecting people who are in range, and broadcasts from players
-- who run the library themselves. It never relays what it knows about a third
-- party, and there is no way to request data, so anyone out of range who isn't
-- running the library stays unknown. The library decides on its own when to
-- inspect and when to broadcast. WDW consumes what arrives, feeding group
-- members' detected specs into the role auto-assignment below; when this
-- particular client performed the live inspect, WDW also shares the compact
-- conclusion with the group (see Sync:ReportTalentObservation).
--
-- The library refuses to load on clients outside Classic/TBC/Wotlk, so
-- LibStub returns nil there rather than erroring.
local Inspector = LibStub("LibClassicInspector", true)

-- The library's addon-message prefix, needed only by the raw logging below.
local INSPECTOR_PREFIX = "LCIV1"

-- WDW role id per talent tab, indexed by the library's specIndex (the tab
-- with the most points), keyed by the uppercase english class token. Tab
-- order is the TBC talent-frame order.
--
-- Inherently undetectable from a spec: warlock_firetank, druid_dreamstate
-- and custom roles -- those only ever arrive by hand, and
-- AutoAssignDetectedRole is built to leave them alone. Feral tanks and cat
-- DPS share one tree, so the guess here is always cat DPS; OnTalentsReady
-- recovers the tank from tank cues (WDW feral-tank role / TANK flag / MAINTANK)
-- before auto-assigning, and a manual correction to Feral Tank sticks anyway.
local SPEC_ROLES = {
    WARRIOR = { "warrior_arms", "warrior_fury", "warrior_prot" },
    PALADIN = { "paladin_holy", "paladin_prot", "paladin_ret" },
    HUNTER  = { "hunter_bm", "hunter_mm", "hunter_surv" },
    ROGUE   = { "rogue_assassin", "rogue_combat", "rogue_sub" },
    PRIEST  = { "priest_disc", "priest_holy", "priest_shadow" },
    SHAMAN  = { "shaman_ele", "shaman_enh", "shaman_resto" },
    MAGE    = { "mage_arcane", "mage_fire", "mage_frost" },
    WARLOCK = { "warlock_affl", "warlock_demo", "warlock_destro" },
    DRUID   = { "druid_balance", "druid_feral_dps", "druid_resto" },
}

local function DetectedRoleFor(playerKey, class, specIndex)
    local detected = class and specIndex and SPEC_ROLES[class] and SPEC_ROLES[class][specIndex]

    -- Feral druids (cat DPS and bear tank) share the Feral Combat tree. Keep
    -- the tank interpretation when the board or Blizzard already says tank.
    if detected == "druid_feral_dps" then
        if WhoDoesWhat.db.profile.assignments[playerKey] == "druid_feral_tank"
            or (UnitGroupRolesAssigned and UnitGroupRolesAssigned(playerKey) == "TANK")
            or GetPartyAssignment("MAINTANK", playerKey, true) then
            detected = "druid_feral_tank"
        end
    end

    return detected
end

-- Which WDW roles a talent spread reads as -- normally one, but a feral druid
-- gets both: cat and bear share the Feral Combat tree, so the points genuinely
-- cannot tell them apart and showing one icon would be picking a side.
local function RolesForSpec(class, specIndex)
    local id = class and specIndex and SPEC_ROLES[class] and SPEC_ROLES[class][specIndex]
    if not id then return nil end
    if id == "druid_feral_dps" then return { id, "druid_feral_tank" } end
    return { id }
end

-- What the Action Items window shows in its Talents column: the per-tab point
-- spread the library has cached for this unit, and the role(s) that spread
-- reads as. nil while nothing has been seen -- an out-of-range player who
-- doesn't run the library themselves stays unknown until someone gets close.
function WhoDoesWhat:GetTalentSnapshot(unit)
    local guid = Inspector and unit and UnitExists(unit) and UnitGUID(unit)
    if not guid then return nil end
    local t1, t2, t3 = Inspector:GetTalentPoints(guid)
    if not (t1 and t2 and t3) or t1 + t2 + t3 <= 0 then return nil end
    local specIndex = Inspector:GetSpecialization(guid)
    local _, class = UnitClass(unit)
    return { points = { t1, t2, t3 }, roleIds = RolesForSpec(class, specIndex) }
end

-- The roles a talent spread can actually name. Anything outside this set --
-- warlock_firetank, druid_dreamstate, custom roles -- is a hand-made call the
-- points can neither confirm nor contradict, so it must never be reported as
-- disagreeing with the scan; there is no rescan that would ever settle it.
local DETECTABLE_ROLES = { druid_feral_tank = true }
for _, ids in pairs(SPEC_ROLES) do
    for _, id in ipairs(ids) do DETECTABLE_ROLES[id] = true end
end

-- Does the last scan disagree with the role on the board? Only ever true when
-- we have actually seen their points AND their role is one talents can judge.
-- An unscanned player disagrees with nothing, and a feral druid matches either
-- feral role because the tree cannot tell cat from bear.
--
-- This is a stale board, not a bug: AutoAssignDetectedRole deliberately lets a
-- first sighting lose to an existing assignment, so a role picked before anyone
-- could inspect them stays put even once the talents say otherwise.
function WhoDoesWhat:TalentsContradictRole(unit, roleId)
    if not (roleId and DETECTABLE_ROLES[roleId]) then return false end
    local snapshot = self:GetTalentSnapshot(unit)
    if not (snapshot and snapshot.roleIds) then return false end
    for _, id in ipairs(snapshot.roleIds) do
        if id == roleId then return false end
    end
    return true
end

-- Players we've asked the library to re-inspect and not yet heard back on, as
-- playerKey -> the time the request goes stale. An inspect can simply never
-- answer (they walked out of range, we're in combat, they logged), so entries
-- expire rather than leaving a Rescan button dead for the rest of the raid.
local rescanPending = {}
local RESCAN_TIMEOUT = 10

function WhoDoesWhat:IsTalentRescanPending(playerKey)
    local expiry = rescanPending[playerKey]
    if not expiry then return false end
    if GetTime() >= expiry then
        rescanPending[playerKey] = nil
        return false
    end
    return true
end

-- One player's RescanUtilityTalents: replay whatever is cached right now, then
-- ask for a fresh inspect. The inspect lands async through TALENTS_READY, which
-- clears the pending mark and repaints; the timer covers the case where it
-- never lands at all.
function WhoDoesWhat:RescanPlayerTalents(unit, playerKey)
    if not (Inspector and self.db and unit and UnitExists(unit)) then return end
    local guid = UnitGUID(unit)
    if not guid then return end

    local isSelf = guid == UnitGUID("player")
    if isSelf or (Inspector:GetLastCacheTime(guid) or 0) ~= 0 then
        self:OnTalentsReady("TALENTS_READY", guid, false, not isSelf)
    end
    -- Our own talents come from the client directly; there is nothing to
    -- inspect and so nothing to wait for.
    if not isSelf then
        rescanPending[playerKey] = GetTime() + RESCAN_TIMEOUT
        Inspector:DoInspect(unit)
        C_Timer.After(RESCAN_TIMEOUT + 0.1, function()
            self:RefreshBoardViews()
        end)
    end
    self:RefreshBoardViews()
end

-- The four talents that decide which paladin should carry which blessing,
-- located by their fixed grid position: tab (1 Holy, 2 Protection,
-- 3 Retribution), tier (row, top = 1) and column (left = 1). ClientFeatures
-- selects the Classic Era or TBC layout.
--
-- We read ranks by (tier, column) rather than a talent index because the
-- native GetTalentInfo(tab, i) index order is NOT stable on this client
-- (NovaRaidCompanion sorts by row/column for the same reason). LibClassicInspector
-- assumes native order == its static-table order and reads ranks positionally,
-- so on the Anniversary client its cached ranks land under the wrong talent (a
-- paladin's Kings point surfaced under a neighbour). Coordinates are order-proof.
--
-- The 1-point talents (Kings, Sanctuary) *grant* their blessing outright (no
-- talent = can't cast it); the multi-rank ones improve a baseline blessing.
-- Salvation and Light have no talent.
local PALADIN_BUFF_TALENTS = WhoDoesWhat.ClientFeatures.paladinBuffTalents
-- Improved Healthstone (0-2): Demonology, first row, first column.
local WARLOCK_HEALTHSTONE_TALENT = { tab = 2, tier = 1, column = 1 }

-- Read one talent's rank straight from the client's native talent API, found
-- by its (tier, column) so the unstable index order doesn't matter. isInspect
-- selects the inspected unit's data (the inspection LibClassicInspector just
-- performed is still current when it fires TALENTS_READY) vs the local
-- player's own. Returns 0 if the talent isn't found.
local function NativeRankAt(t, isInspect, group)
    -- +10 headroom: the native list can have nil gaps with a real talent past
    -- the reported count (NRC guards the same way); nil entries are skipped.
    for i = 1, (GetNumTalents(t.tab, isInspect) or 0) + 10 do
        local name, _, row, column, rank = GetTalentInfo(t.tab, i, isInspect, nil, group)
        if name and row == t.tier and column == t.column then
            return rank or 0
        end
    end
    return 0
end

-- Save a paladin's buff-talent ranks under their name key. Ranks are read from
-- the client's native talent API by (tier, column) -- see PALADIN_BUFF_TALENTS
-- for why the library's positional cache can't be trusted on this client.
--
-- Only a fresh inspect (isInspect) or the local player exposes correct native
-- data; a cache replay (roster sweep, broadcast) has nothing live to read, so
-- we skip rather than overwrite good data with zeros. Runs on every inspect of
-- a paladin, so a respec's re-scan overwrites the old numbers.
function WhoDoesWhat:ScanPaladinBuffTalents(guid, playerKey, isInspect)
    if not (isInspect or guid == UnitGUID("player")) then return end

    local group = GetActiveTalentGroup(isInspect) or 1
    local ranks = {}
    for _, t in ipairs(PALADIN_BUFF_TALENTS) do
        ranks[t.key] = NativeRankAt(t, isInspect, group)
    end
    self.db.profile.paladinBuffTalents[playerKey] = ranks
end

-- A paladin's buff-talent ranks ({ might, wisdom, kings, sanctuary }), or nil
-- while their talents haven't been seen yet. A provisional PallyPower import
-- also has _source="pallypower"; this native scan replaces the whole table,
-- removing that tag and solidifying the result.
function WhoDoesWhat:GetPaladinBuffTalents(playerName)
    return self.db and self.db.profile.paladinBuffTalents[playerName] or nil
end

function WhoDoesWhat:ScanWarlockHealthstoneTalent(guid, playerKey, isInspect)
    if not (isInspect or guid == UnitGUID("player")) then return end

    local group = GetActiveTalentGroup(isInspect) or 1
    self.db.profile.warlockHealthstoneTalents[playerKey] =
        NativeRankAt(WARLOCK_HEALTHSTONE_TALENT, isInspect, group)
end

function WhoDoesWhat:GetWarlockHealthstoneTalent(playerName)
    return self.db and self.db.profile.warlockHealthstoneTalents[playerName] or nil
end

-- Save the improvement rank for any raid-wide buff supplied by this class.
-- As with paladin ranks, only the local player or a fresh inspect has native
-- talent data in the right order; WDW sync carries each provider's own rank
-- to the rest of the group.
function WhoDoesWhat:ScanCoreBuffTalents(guid, playerKey, class, isInspect)
    if not (isInspect or guid == UnitGUID("player")) then return end

    local group = GetActiveTalentGroup(isInspect) or 1
    local ranks = {}
    for key, buff in pairs(self.StatusBarChecks) do
        local talent = buff.improvedTalent
        if talent and string.upper(buff.className) == class then
            ranks[key] = NativeRankAt(talent, isInspect, group)
        end
    end
    self.db.profile.coreBuffTalents[playerKey] = ranks
end

function WhoDoesWhat:GetCoreBuffTalent(playerName, buffKey)
    local ranks = self.db and self.db.profile.coreBuffTalents[playerName]
    return ranks and ranks[buffKey] or nil
end

-- Manual "/wdw rescan". Talent data only becomes current when
-- the library inspects a provider in range or receives their broadcast, so this
-- forces a fresh inspect of reachable providers and replays cached data at once.
-- Out-of-range providers keep their last-known ranks until they come closer.
local function RescanUtilityTalents(self, wantedClasses, label)
    if not (Inspector and self.db) then return end

    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    else
        units[1] = "player"
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end

    local playerGUID = UnitGUID("player")
    local total, inRange = 0, 0
    for _, unit in ipairs(units) do
        local class = UnitExists(unit) and select(2, UnitClass(unit))
        if class and wantedClasses[class] then
            total = total + 1
            local guid = UnitGUID(unit)

            -- Re-run the pipeline from cache first: this resyncs role
            -- detection (which reads fine from the library's spec totals) and,
            -- for the local player, re-reads buff talents from the client
            -- directly. Other players' buff talents can't be read without a
            -- live inspect, so those refresh via the DoInspect below instead.
            -- Gated on a real cache time so an uncached provider isn't touched.
            if guid == playerGUID or (Inspector:GetLastCacheTime(guid) or 0) ~= 0 then
                self:OnTalentsReady("TALENTS_READY", guid, false, guid ~= playerGUID)
            end

            -- Force a fresh inspect where the provider is reachable; the result
            -- lands async and repaints through the normal TALENTS_READY path.
            if guid ~= playerGUID and Inspector:DoInspect(unit) ~= 0 then
                inRange = inRange + 1
            end
        end
    end

    if total == 0 then
        self:Print("Rescan: no " .. label .. "s in the group.")
    else
        self:LogOperation(string.format(
            "Rescanning %d %s%s (%d in range, refreshing now).",
            total, label, total == 1 and "" or "s", inRange))
    end
end

function WhoDoesWhat:RescanBuffingTalents()
    RescanUtilityTalents(self,
        { PALADIN = true, DRUID = true, PRIEST = true }, "buff provider")
    self:RefreshBoardViews()
end

-- Both flags are test scaffolding for the talent sync and are off during normal
-- play: the library keeps caching either way, these only control chat spam. In a
-- raid each would print a line per player per inspect, and again on every 60s
-- rebroadcast, so neither is usable with a group of any size.
--
-- LOG_TALENTS   - a line whenever talent data lands for a player.
-- LOG_TALENT_COMMS - a line for raw library traffic, kept or discarded. Useful
--                    only when telling "nobody broadcast" apart from "it
--                    arrived and the library rejected it".
WhoDoesWhat.LOG_TALENTS = false
WhoDoesWhat.LOG_TALENT_COMMS = false

-- Keep a player's assigned role in step with their detected talents:
--   - no assignment yet -> fill it with the detection
--   - the detected spec *changed* since a previous detection (a respec) ->
--     follow it
--   - anything else -> hands off; in particular this client's FIRST
--     detection never overrides an assignment that already exists (it may be
--     a manual pick, or synced from a client that inspected them in range)
-- The change test is against our own previous detection (db.profile
-- .talentSpecs), not against the assignment, so a manual pick that disagrees
-- with the talents (Feral Tank over the feral-DPS guess, a custom role) is
-- repeated broadcasts of an unchanged spec never touch it.
-- The flip side: an actual respec overrides even a manual pick -- the board
-- follows reality, and the leader can re-override if they mean it.
--
-- Quieter than SetAssignedRole -- no group-chat announcement, because talent
-- data for a whole raid lands in a burst and 25 auto-assignments must not
-- spam the raid. The blizzard side does follow along though (role flag,
-- main-tank demote, promote-tank arrow via SyncBlizzardRoleState): it only
-- fires on a first detection or an actual respec, never on the repeated
-- broadcasts of an unchanged spec, so it stays rare. Gated on having the
-- rights to touch Blizzard group state -- in a raid that means assist, in a
-- party the lead (your own flag is always yours); without it the assignment
-- still saves, just without touching group state.
function WhoDoesWhat:AutoAssignDetectedRole(playerName, detectedRoleId, isReplay)
    local profile = self.db.profile
    local lastDetected = profile.talentSpecs[playerName]
    -- A replay re-reads what the library already had; it is not new evidence.
    -- Disagreeing with our last recorded detection means our cache is behind
    -- someone else's firsthand report of a respec -- believing it would read as
    -- "they respecced back", flip the board to the old role and broadcast it,
    -- which is how a respecced raider got dragged back and stuck there.
    -- A replay with nothing recorded yet still counts (the rejoin catch).
    if isReplay and lastDetected ~= nil and detectedRoleId ~= lastDetected then
        return
    end
    profile.talentSpecs[playerName] = detectedRoleId

    local current = profile.assignments[playerName]
    if current == detectedRoleId then return end
    -- An existing assignment only yields to an observed RESPEC: this client
    -- saw one spec before and now sees a different one. A FIRST detection
    -- (lastDetected == nil) must not override -- the assignment may have come
    -- from the synced master copy (a client that could actually inspect them
    -- in range) or a manual pick, and "I finally saw their talents" is no
    -- evidence anything changed. Without this, two clients with different
    -- cache states tug the player between two roles, each rebroadcasting its
    -- own guess.
    if current ~= nil and (lastDetected == nil or detectedRoleId == lastDetected) then return end

    profile.assignments[playerName] = detectedRoleId
    local _, role = self:FindRoleById(detectedRoleId)
    -- Always go through the Blizzard-side sync: it decides internally whether
    -- this client is the elected writer (write now), or merely permitted
    -- (record an issue row to click), or neither (do nothing). Detecting a
    -- respec is exactly when we want the flag corrected immediately, so no
    -- caller-side gate -- two clients scanning the same newcomer still can't
    -- fight, because only one of them is elected. See BlizzardRoleWriter.
    self:SyncBlizzardRoleState(playerName, role)
    self:LogOperation(playerName .. (current and " respecced: now " or " detected: ")
        .. (role and role.name or detectedRoleId) .. ".")
    -- On TBC, a fresh Affliction warlock gets Curse of the Elements handed to
    -- them (setting-gated). The assignment helper is a no-op on Classic Era.
    if detectedRoleId == "warlock_affl" then
        self.Assign.AutoPlaceAfflictionElements(playerName)
    end
    self:PushPlayerBuffToPallyPower(playerName)
    -- Covers the sync path too: talent points arriving from another client
    -- never touch the inspect cache the Talents column reads, but they do
    -- settle a role, which can take the row off the list entirely. Requested
    -- rather than forced because the roster sweep can auto-assign many players
    -- in one loop.
    self:RequestFullRefresh()
end

-- The initial WDW HELLO carries only these three derived totals, not a role or
-- the full talent grid. Receivers run the same class/tab mapping as the normal
-- LibClassicInspector path and feed it through the same override-safe updater.
function WhoDoesWhat:GetOwnTalentTreePoints()
    local guid = UnitGUID("player")
    if not (Inspector and guid) then return nil end
    local t1, t2, t3 = Inspector:GetTalentPoints(guid)
    if not (t1 and t2 and t3) or t1 + t2 + t3 <= 0 then return nil end
    return { t1, t2, t3 }
end

function WhoDoesWhat:ApplySyncedTalentTreePoints(playerName, class, points)
    if type(playerName) ~= "string" or not SPEC_ROLES[class] or type(points) ~= "table" then
        return
    end

    local specIndex, mostPoints = nil, 0
    for i = 1, 3 do
        local n = tonumber(points[i])
        if not n or n < 0 or n ~= math.floor(n) then return end
        if n > mostPoints then
            specIndex, mostPoints = i, n
        end
    end

    local detected = DetectedRoleFor(playerName, class, specIndex)
    if detected and mostPoints > 0 then
        self:AutoAssignDetectedRole(playerName, detected)
        self.Assign.EnsureAutoRows(self.Assign.SectionByKey("tank"))
    end
end

-- Fired for anyone the library has cached, which includes strangers we happen
-- to mouse over. Optionally logs the data, then feeds group members into the
-- role auto-detection above.
-- isReplay marks our own re-reads of the library's cache (roster sweep, rescan
-- buttons) as opposed to the library telling us something new. The library's
-- own callback never passes it: an inspect and a player's self-broadcast are
-- both firsthand, only isInspect tells those two apart. See
-- AutoAssignDetectedRole for why a replay must not claim a respec.
function WhoDoesWhat:OnTalentsReady(event, guid, isInspect, isReplay)
    local _, class, _, _, _, name, realm = GetPlayerInfoByGUID(guid)
    local sync = isInspect and self:GetModule("Sync", true)
    local boardWasClean = sync and sync:IsBoardClean()

    -- Points land in tab order (1-3); specIndex is whichever tab has the most.
    local specIndex, pointsSpent = Inspector:GetSpecialization(guid)

    if self.LOG_TALENTS then
        local t1, t2, t3 = Inspector:GetTalentPoints(guid)
        local specName = class and specIndex and Inspector:GetSpecializationName(class, specIndex)
        self:Print(string.format(
            "Talents received: %s - %s (%d/%d/%d) [%s, %s]",
            name or guid,
            specName or "unknown",
            t1 or 0, t2 or 0, t3 or 0,
            isInspect and "inspected" or "synced from another player",
            IsGUIDInGroup(guid) and "in group" or "not in group"
        ))
    end

    -- Auto-assignment is for group members only (assignments are group
    -- business; the cache also covers strangers). Ourselves included, so solo
    -- testing works. pointsSpent == 0 means a fresh respec that hasn't
    -- re-spent yet, or a low-level character -- no spec to read either way.
    if not (name and self.db) then return end
    if not (IsGUIDInGroup(guid) or guid == UnitGUID("player")) then return end

    local key = (realm and realm ~= "") and (name .. "-" .. realm) or name

    -- Their data arrived, so a hand-pressed Rescan on this player is answered
    -- and the Talents column has something new to say. The repaint for this --
    -- and for whatever the class branches below scan -- is one pass at the end
    -- of the function. It used to happen here AND again per class branch, so an
    -- inspect of a paladin, druid or priest repainted WDW Status twice, which
    -- is most of what made this function the most expensive thing profiled.
    rescanPending[key] = nil

    local detected = DetectedRoleFor(key, class, specIndex)

    if detected and (pointsSpent or 0) > 0 then
        self:AutoAssignDetectedRole(key, detected, isReplay)
        self.Assign.EnsureAutoRows(self.Assign.SectionByKey("tank"))
    end

    -- First-scan main-tank sweep: a player whose WDW role is a tank but who
    -- isn't MAINTANK yet gets the promote arrow. Anyone who could actually
    -- promote them drives it (CanPromoteMainTank -- leader or assistant, NOT
    -- the single flag-writer), only in a raid; StartPromoteWatch is idempotent
    -- per player, so the 60s talent rebroadcast that re-runs this won't re-nag
    -- once they're pending or promoted.
    if self:CanPromoteMainTank() and self:IsMarkedTank(key)
        and not GetPartyAssignment("MAINTANK", key, true) then
        self:StartPromoteWatch(key)
    end

    -- Paladins additionally get their buff talents read out, feeding the
    -- paladin-buff dropdown preferences and auto-assign in the main view, plus
    -- the shared raider tooltip that spells the ranks out.
    if class == "PALADIN" then
        self:ScanPaladinBuffTalents(guid, key, isInspect)
    elseif class == "WARLOCK" then
        self:ScanWarlockHealthstoneTalent(guid, key, isInspect)
    elseif class == "DRUID" or class == "PRIEST" then
        self:ScanCoreBuffTalents(guid, key, class, isInspect)
    end

    -- Requested, not forced: this runs once PER PLAYER. SyncRosterTalents calls
    -- it for all 40 in one loop, and an inspect fires it for every stranger who
    -- walks into range, so repainting here directly stalled zone-in and made
    -- crowds stutter.
    self:RequestFullRefresh()

    -- LibClassicInspector's true flag means this client just inspected the
    -- player in range. Share only that firsthand evidence; cache replays and
    -- the library's own messages use false and must never become hearsay.
    if sync and guid ~= UnitGUID("player") then
        local t1, t2, t3 = Inspector:GetTalentPoints(guid)
        if t1 and t2 and t3 then
            local profile = self.db.profile
            sync:ReportTalentObservation(
                key, class, { t1, t2, t3 },
                class == "PALADIN" and profile.paladinBuffTalents[key] or nil,
                class == "WARLOCK" and profile.warlockHealthstoneTalents[key] or nil,
                (class == "DRUID" or class == "PRIEST")
                    and profile.coreBuffTalents[key] or nil,
                boardWasClean)
        end
    end
end

-- Registered at load rather than in OnInitialize so the callback is live
-- before the first sweep the library runs on entering the world.
if Inspector then
    Inspector.RegisterCallback("WhoDoesWhat", "TALENTS_READY", function(...)
        WhoDoesWhat:OnTalentsReady(...)
    end)
else
    WhoDoesWhat:Print("LibClassicInspector did not load - talent syncing is unavailable on this client.")
end

-- Stable player key for a unit: "Name" same-realm, "Name-Realm" foreign.
-- Matches the keying used by db.profile.assignments (UnitMenuExtensions.lua).
local function GetUnitKey(unit)
    local name, realm = UnitName(unit)
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

-- Rejoin catch. TALENTS_READY only fires when talent data *arrives*, so a
-- kicked-and-reinvited player -- whose talents the library still has cached
-- -- would sit unscanned and unflagged until their next rebroadcast. On
-- roster changes, sweep the group and replay the OnTalentsReady pipeline for
-- everyone the cache already covers (running it for an *uncached* member
-- would honestly-but-wrongly record a paladin as rank 0 across the board,
-- hence the cache-time gate; the local player's talents come from the client
-- itself, so no gate). Also re-applies the blizzard role flag when the group
-- state lost it: a kick resets the flag, and AutoAssignDetectedRole won't
-- restore it because the detection hasn't changed.
function WhoDoesWhat:SyncRosterTalents()
    if not (Inspector and self.db) then return end

    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            units[#units + 1] = "raid" .. i
        end
    else
        units[1] = "player"
        for i = 1, GetNumSubgroupMembers() do
            units[#units + 1] = "party" .. i
        end
    end

    for _, unit in ipairs(units) do
        local guid = UnitGUID(unit)
        if guid then
            local cachedAt = Inspector:GetLastCacheTime(guid)
            if guid == UnitGUID("player") or (cachedAt and cachedAt ~= 0) then
                self:OnTalentsReady("TALENTS_READY", guid, false,
                    guid ~= UnitGUID("player"))
            end
        end
    end

    -- No Blizzard-flag reconcile here any more. Replaying the cache is about
    -- WDW's own board; pushing everyone's flag on every roster event is the
    -- automation that kept overwriting players from a board that hadn't caught
    -- up. A kick still resets the flag, and that now shows up in Action Items
    -- rather than being repaired behind your back.
end

-- Joins fire GROUP_ROSTER_UPDATE in bursts, so the sweep runs once, a beat
-- after the burst settles.
local rosterSync = CreateFrame("Frame")
rosterSync:RegisterEvent("GROUP_ROSTER_UPDATE")
local rosterSyncPending = false
rosterSync:SetScript("OnEvent", function()
    if rosterSyncPending then return end
    rosterSyncPending = true
    C_Timer.After(1, function()
        rosterSyncPending = false
        WhoDoesWhat:SyncRosterTalents()
    end)
end)

-- There used to be a PLAYER_REGEN_ENABLED sweep here re-applying flags that
-- combat had blocked. It was another automatic board -> flag push, so it went
-- with the rest: a write blocked by combat is now simply not made, and the
-- difference waits in Action Items.

-- The library never fires TALENTS_READY for the local player (INSPECT_READY
-- skips "player", and their own talent events only set an internal flag), so
-- nothing above ever scans us. Cover it directly: on login, a respec, or a
-- dual-spec swap, replay the pipeline for our own GUID -- important on the
-- Anniversary client where swapping spec changes which blessings we can cast.
-- pcall-guarded RegisterEvent because the dual-spec events don't exist on
-- every build (the library guards them the same way).
local selfSync = CreateFrame("Frame")
selfSync:RegisterEvent("PLAYER_ENTERING_WORLD")
selfSync:RegisterEvent("CHARACTER_POINTS_CHANGED")
pcall(selfSync.RegisterEvent, selfSync, "PLAYER_TALENT_UPDATE")
pcall(selfSync.RegisterEvent, selfSync, "ACTIVE_TALENT_GROUP_CHANGED")
selfSync:SetScript("OnEvent", function()
    local guid = UnitGUID("player")
    -- OnTalentsReady uses the library unguarded, and every other caller checks
    -- it loaded first; keep that invariant here too.
    if Inspector and guid then
        WhoDoesWhat:OnTalentsReady("TALENTS_READY", guid, false)
    end
end)

-- OnTalentsReady alone can't tell us whether a broadcast arrived, because the
-- library drops a message silently on any of several checks before it fires
-- TALENTS_READY - most easily hit being an unresolvable sender or a class the
-- client hasn't cached yet.
--
-- The library registers the prefix itself, so this only observes. A plain
-- frame keeps the diagnostic self-contained; the addon doesn't embed AceEvent.
local commLogger = CreateFrame("Frame")
commLogger:RegisterEvent("CHAT_MSG_ADDON")
commLogger:SetScript("OnEvent", function(_, _, prefix, text, channel, sender)
    if prefix ~= INSPECTOR_PREFIX or not WhoDoesWhat.LOG_TALENT_COMMS then
        return
    end
    WhoDoesWhat:Print(string.format(
        "|cff888888Talent broadcast from %s over %s (%d bytes)|r",
        tostring(sender), tostring(channel), #(text or "")
    ))
end)
