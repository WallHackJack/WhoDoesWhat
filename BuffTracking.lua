local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Live tracking of which supported raid buffs are ACTUALLY active on each
-- raider. This is a shared data layer: the paladin grid consumes blessings to
-- red-flag missing assignments, while WDW Status consumes the core raid buffs.
--
-- The approach mirrors NovaConsumesHelper / NovaRaidCompanion, which track raid
-- buffs the same way and work well on this client:
--   * Read auras through the modern C_UnitAuras API (GetBuffDataByIndex),
--     falling back to indexed UnitBuff on an older client that lacks it.
--   * Event-driven: UNIT_AURA re-scans just the unit whose auras changed, so a
--     nearby (re)buff shows instantly; a slow full-group poll backstops it for
--     anything UNIT_AURA doesn't deliver (it fires unreliably for distant
--     units). These buffs last minutes, so a few seconds of lag is fine.
--
-- Range (TBC 2.5.5): unlike retail, the aura LIST for a group member is
-- available regardless of range. Duration/expiration may be stale out of
-- range, but presence and the last observed expiry still support the grid.
--
-- Per-raider states:
--   * present -- the aura is on them
--   * missing -- the aura isn't there (this red-flags). A dead or offline
--                raider still reads as missing, so a corpse shows red and you
--                can rebuff the instant they're back up.
--   * unknown -- not yet scanned, or no real unit (fake raiders); never flags

local BuffTracking = {}
WhoDoesWhat.BuffTracking = BuffTracking

-- Developer timing (Profiling.lua); both are no-ops unless /wdw perf on.
local PBegin, PEnd = WhoDoesWhat.Profiling.Begin, WhoDoesWhat.Profiling.End

local POLL_INTERVAL = 3     -- seconds between full-group backstop scans
local NOTIFY_INTERVAL = 1 -- minimum seconds between board repaints

-- Modern aura API (present on the Anniversary client); nil on anything older,
-- where ScanUnit falls back to indexed UnitBuff.
local GetBuffDataByIndex = C_UnitAuras and C_UnitAuras.GetBuffDataByIndex
local GetDebuffDataByIndex = C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex

-- name -> { buffs = { [buffKey] = true }, sources = { [buffKey] = name|false },
-- expirations = { [buffKey] = timestamp }, connected = bool }. false means
-- the aura is present but its caster was not exposed by the client. Absence of an
-- entry means "not yet scanned" (unknown); an entry with an empty buffs table
-- means scanned and confirmed to have none of the buffs we track.
local state = {}

-- Rolling backstop sweep (see the ticker at the bottom): the target list for
-- the cycle in progress, how far through it we are, and which keys the cycle
-- has seen so far -- the last of which is what lets a cycle prune departed
-- raiders on its boundary the way the old all-at-once poll did every pass.
local sweepTargets, sweepCursor, sweepSeen = nil, 0, nil

-- ---------------------------------------------------------------------------
-- Aura name -> tracked buff key
-- ---------------------------------------------------------------------------

-- Built lazily from GetSpellInfo: the localized name of a blessing is
-- rank-independent, so matching by name catches every rank a paladin might be
-- casting without listing spellIds. We register both the "Greater Blessing of
-- X" name (from our stored greater spellId) and the single-target "Blessing of
-- X" (the same name minus the "Greater " prefix), so a raider on either form
-- reads as covered. The prefix strip is English -- fine for the Anniversary
-- client; a localized build would need the normal-rank ids instead.
local nameToKey, debuffNameToKey
local function BuildNameMap()
    nameToKey = {}
    debuffNameToKey = {}
    for key, buff in pairs(WhoDoesWhat.PaladinBuffs) do
        local greaterName = GetSpellInfo(buff.spellId)
        if greaterName then
            nameToKey[greaterName] = key
            nameToKey[(greaterName:gsub("^Greater ", ""))] = key
        end
    end
    for key, check in pairs(WhoDoesWhat.StatusBarChecks) do
        local map = check.harmful and debuffNameToKey or nameToKey
        for _, auraName in ipairs(check.auraNames or {}) do
            map[auraName] = key
        end
    end
end

-- ---------------------------------------------------------------------------
-- Roster / unit helpers
-- ---------------------------------------------------------------------------

-- Stable player key for a unit, matching Assignments.lua's GetUnitKey so the
-- names line up with the grid's plan keys: "Name" same-realm, "Name-Realm"
-- foreign. (Names are already realm-disambiguated here, so keying by name is
-- collision-safe -- no need for the GUID indirection NCH uses.)
local function UnitToKey(unit)
    local name, realm = UnitName(unit)
    if not name then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

-- The units to scan as { unit, key } pairs: every group member (self included
-- off-raid), plus each summoned pet keyed "<Owner>'s Pet" to match the plan /
-- GetPetMembers, so HasBuff("<Owner>'s Pet") resolves. Fake raiders have no
-- real unit and are simply never tracked -- their buffs stay unknown.
local function GroupTargets()
    local owners = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            owners[#owners + 1] = { "raid" .. i, "raidpet" .. i }
        end
    else
        owners[1] = { "player", "pet" }
        for i = 1, GetNumSubgroupMembers() do
            owners[#owners + 1] = { "party" .. i, "partypet" .. i }
        end
    end

    local targets = {}
    for _, o in ipairs(owners) do
        local key = UnitToKey(o[1])
        if key then
            -- ownerUnit/ownerKey ride along so the rolling sweep can tell
            -- whether a slot still belongs to the same player it did when the
            -- list was built. It cannot check a pet directly: a pet's key is
            -- its OWNER's name plus "'s Pet", which never equals the pet's own
            -- UnitToKey, so both rows are validated against the owner.
            targets[#targets + 1] = {
                unit = o[1], key = key, ownerUnit = o[1], ownerKey = key,
            }
            -- Every summoned pet, not just the hunters': blessings are only
            -- planned for hunter pets, but a raid-wide effect lands on any pet
            -- in range, so Sated has to be readable on a shadowfiend too. The
            -- consumers pick which pets they care about; an entry here only
            -- means the pet exists and has been scanned.
            if UnitExists(o[2]) then
                targets[#targets + 1] = {
                    unit = o[2], key = key .. "'s Pet",
                    ownerUnit = o[1], ownerKey = key,
                }
            end
        end
    end
    return targets
end

-- True for the unit tokens GroupUnits produces, so UNIT_AURA can ignore
-- targets, nameplates, pets and everything else it also fires for.
local function IsGroupUnit(unit)
    return unit == "player"
        or (unit and (unit:match("^raid%d+$") or unit:match("^party%d+$"))) ~= nil
end

-- ---------------------------------------------------------------------------
-- Scanning
-- ---------------------------------------------------------------------------

-- Record one matched aura into the scan tables. Everything it touches is
-- passed in rather than closed over -- see ScanAuraList.
local function StoreAura(key, sourceUnit, expirationTime, buffs, sources,
                         expirations, previous)
    buffs[key] = true
    sources[key] = (sourceUnit and UnitToKey(sourceUnit)) or false
    expirations[key] = expirationTime and expirationTime > 0
        and expirationTime
        or previous and previous.expirations and previous.expirations[key]
end

-- Walk one of a unit's aura lists, newest API first (C_UnitAuras), indexed
-- UnitBuff/UnitDebuff as the fallback.
--
-- Deliberately not the callback form this replaced. This runs for every unit
-- on every poll and again on every UNIT_AURA, and the callback form paid for
-- that twice over: three closures allocated per unit before a single aura was
-- read, then two function calls for EVERY aura on the unit. Most auras in a
-- 40-man match nothing we track, so the lookup now happens inline and only a
-- match costs a call.
local function ScanAuraList(unit, harmful, map, buffs, sources, expirations,
                            previous)
    if not map then return end
    local GetByIndex = harmful and GetDebuffDataByIndex or GetBuffDataByIndex
    local i = 1
    if GetByIndex then
        while true do
            local aura = GetByIndex(unit, i)
            if not aura then break end
            local key = aura.name and map[aura.name]
            if key then
                StoreAura(key, aura.sourceUnit, aura.expirationTime,
                    buffs, sources, expirations, previous)
            end
            i = i + 1
        end
    else
        local Indexed = harmful and UnitDebuff or UnitBuff
        while true do
            local auraName, _, _, _, _, expirationTime, sourceUnit = Indexed(unit, i)
            if not auraName then break end
            local key = map[auraName]
            if key then
                StoreAura(key, sourceUnit, expirationTime,
                    buffs, sources, expirations, previous)
            end
            i = i + 1
        end
    end
end

-- Did the freshly-scanned buff set differ from what we had stored?
local function Differs(prev, buffs, sources, expirations, connected)
    if not prev or prev.connected ~= connected then return true end
    for key in pairs(buffs) do
        if not prev.buffs[key] then return true end
        if not prev.sources or prev.sources[key] ~= sources[key] then return true end
        if not prev.expirations
            or prev.expirations[key] ~= expirations[key] then return true end
    end
    for key in pairs(prev.buffs) do
        if not buffs[key] then return true end
    end
    return false
end

-- Scan one unit's tracked status auras into state[name]; returns whether
-- anything changed. Aura presence is available at any group-member range.
local function ScanUnit(unit, name)
    local previous = state[name]
    local buffs, sources, expirations = {}, {}, {}
    ScanAuraList(unit, false, nameToKey, buffs, sources, expirations, previous)
    -- Skipped outright when no harmful check is configured: with an empty map
    -- the debuff walk can only ever read every debuff on the unit and discard
    -- all of them.
    if next(debuffNameToKey) then
        ScanAuraList(unit, true, debuffNameToKey, buffs, sources, expirations,
            previous)
    end
    if UnitIsDeadOrGhost(unit) then buffs.dead = true end
    local connected = UnitIsConnected(unit) ~= false
    local changed = Differs(state[name], buffs, sources, expirations, connected)
    state[name] = {
        buffs = buffs, sources = sources, expirations = expirations,
        connected = connected,
    }
    return changed
end

local function ScanDead(unit, name)
    local current = state[name]
    if not current then return ScanUnit(unit, name) end
    local dead = UnitIsDeadOrGhost(unit)
    if (current.buffs.dead == true) == dead then return false end
    current.buffs.dead = dead and true or nil
    return true
end

-- ---------------------------------------------------------------------------
-- Change notification (debounced)
-- ---------------------------------------------------------------------------

-- Rate-limit board repaints. Consumers that need the live buff state hook in
-- here.
--
-- This was a 0.1s trailing debounce, sized to collapse one burst of UNIT_AURA
-- (a raid-wide rebuff) into a single repaint. That works, but a debounce only
-- collapses a BURST -- against a steady stream it just becomes a clock. In a
-- 40-man battleground the changes never stop (deaths and rezzes flip a raider's
-- state as much as buffs do), so the gap between them stays under 0.1s and it
-- settled into repainting the whole board 10 times a second. The buffs it
-- reports last tens of minutes, so that was about a hundred times faster than
-- the data justifies.
--
-- Throttled rather than simply slowed, because a plain 1s debounce would make
-- the FIRST change after a quiet spell wait the full second -- the case where
-- promptness actually matters, like watching a blessing you just cast land. A
-- change arriving after the interval has elapsed repaints immediately; one
-- arriving inside it schedules a single catch-up repaint for the remainder, so
-- the last change in a burst is never dropped.
local notifyPending, lastNotify = false, 0

local function Notify()
    lastNotify = GetTime()
    -- Not profiled as its own section: it is exactly these two calls, so it
    -- only ever restated repaint.board plus a main-window repaint that is ~0
    -- while that window is closed.
    WhoDoesWhat:RefreshMainAssignmentsView()
    WhoDoesWhat:RefreshBoardViews()
end

local function NotifyChanged()
    if notifyPending then return end
    local elapsed = GetTime() - lastNotify
    if elapsed >= NOTIFY_INTERVAL then
        Notify()
        return
    end
    notifyPending = true
    C_Timer.After(NOTIFY_INTERVAL - elapsed, function()
        notifyPending = false
        Notify()
    end)
end

-- ---------------------------------------------------------------------------
-- Public state refresh + query API
-- ---------------------------------------------------------------------------

-- Re-scan the whole group at once and drop anyone who left. Roster changes
-- land here, where the immediacy is worth the cost; the backstop sweep below
-- spreads the same work out instead.
function BuffTracking:RefreshAll()
    PBegin("bufftracking.poll")
    if not nameToKey then BuildNameMap() end
    local changed = false
    local seen = {}
    for _, t in ipairs(GroupTargets()) do
        seen[t.key] = true
        if ScanUnit(t.unit, t.key) then changed = true end
    end
    for name in pairs(state) do
        if not seen[name] then
            state[name] = nil
            changed = true
        end
    end
    -- Restart the rolling sweep: its cursor is meaningless against a list this
    -- just replaced, and everyone was scanned a moment ago regardless.
    -- sweepSeen MUST be cleared with it -- left set, the next tick would treat
    -- a half-finished cycle's partial seen-set as complete and prune every
    -- raider that cycle had not reached yet.
    sweepTargets, sweepCursor, sweepSeen = nil, 0, nil
    PEnd("bufftracking.poll")
    if changed then NotifyChanged() end
end

-- The set of tracked aura/status keys currently active on a raider, or nil for anyone
-- not yet scanned (just joined, or no real unit).
function WhoDoesWhat:GetActiveBuffs(name)
    local s = state[name]
    return s and s.buffs or nil
end

-- Tri-state: true = has it, false = confirmed missing (dead/offline raiders
-- included), nil = unknown -- not yet scanned or no real unit. Only false
-- red-flags.
function WhoDoesWhat:HasBuff(name, key)
    local s = state[name]
    if not s then return nil end
    return s.buffs[key] == true
end

-- The group-member name that applied a tracked aura, or nil when the aura is
-- missing/unknown or the client did not expose its source.
function WhoDoesWhat:GetBuffSource(name, key)
    local s = state[name]
    local source = s and s.sources and s.sources[key]
    return source or nil
end

-- Whether a tracked buff on this raider came from outside the raid. Pulling a
-- boss strips buffs the raid did not cast, so a Gift of the Wild picked up
-- from a passing druid in the city is one that vanishes at the exact moment it
-- was wanted. Party and dungeon groups are not stripped, so nothing is flagged
-- unless we are in a raid.
--
-- A caster the client could not name (`false`) counts as outside: it only
-- names a caster it currently holds a unit for, and in a raid it holds one for
-- every member. Ordered so the common answer -- cast by a raider -- costs one
-- UnitInRaid and returns before the group check.
function WhoDoesWhat:IsBuffFromOutsideRaid(name, key)
    local s = state[name]
    local source = s and s.sources and s.sources[key]
    -- nil is "no aura recorded", which is not the same as "no caster".
    if source == nil then return false end
    if source ~= false and UnitInRaid(source) ~= nil then return false end
    return IsInRaid() and true or false
end

-- Seconds left on the last observed timed aura, or nil for permanent,
-- expired, missing, unknown, or never-observed duration data.
function WhoDoesWhat:GetBuffTimeRemaining(name, key)
    local s = state[name]
    local expiration = s and s.expirations and s.expirations[key]
    if not expiration or expiration <= 0 then return nil end
    local remaining = expiration - GetTime()
    return remaining > 0 and remaining or nil
end

-- Status of a talent-improved core buff on one target. The aura itself has no
-- separate "improved" spell id, so max/partial/base is inferred from its
-- source player and that player's scanned talent rank.
function WhoDoesWhat:GetImprovedBuffState(name, key)
    local has = self:HasBuff(name, key)
    if has ~= true then return has == false and "missing" or "unknown" end

    local buff = self.StatusBarChecks[key]
    local talent = buff and buff.improvedTalent
    if not talent then return "present" end

    local source = self:GetBuffSource(name, key)
    if not source then return "unknown" end
    local rank = self:GetCoreBuffTalent(source, key)
    if rank == nil then return "unknown", source end
    if rank >= talent.maxRank then
        return "max", source, rank, talent.maxRank
    elseif rank > 0 then
        return "partial", source, rank, talent.maxRank
    end
    return "base", source, rank, talent.maxRank
end

-- ---------------------------------------------------------------------------
-- Event driver + backstop poll
-- ---------------------------------------------------------------------------

local driver = CreateFrame("Frame")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("GROUP_ROSTER_UPDATE")
driver:RegisterEvent("UNIT_PET")
driver:RegisterEvent("UNIT_AURA")
driver:RegisterEvent("UNIT_HEALTH")
-- Instrumented per EVENT rather than per scan: in a 40-man these fire
-- constantly (UNIT_HEALTH on every health tick of every raider), so the cost
-- that matters is count x cheap, not any single slow call. The two are
-- separate sections because they do very different amounts of work --
-- UNIT_AURA walks every aura on the unit, UNIT_HEALTH just checks death.
driver:SetScript("OnEvent", function(_, event, unit)
    if event == "UNIT_AURA" or event == "UNIT_HEALTH" then
        local section = event == "UNIT_AURA"
            and "bufftracking.aura" or "bufftracking.health"
        PBegin(section)
        if IsGroupUnit(unit) then
            if not nameToKey then BuildNameMap() end
            local name = UnitToKey(unit)
            local changed
            if name then
                changed = event == "UNIT_HEALTH" and ScanDead(unit, name)
                    or event == "UNIT_AURA" and ScanUnit(unit, name)
            end
            PEnd(section)
            if changed then NotifyChanged() end
        else
            PEnd(section)
        end
    else
        BuffTracking:RefreshAll()
    end
end)

-- Backstop: catches out-of-range expiries, death/rez, and anything UNIT_AURA
-- didn't deliver -- UNIT_AURA fires unreliably for distant units.
--
-- Rolled across frames rather than swept in one go. Scanning all ~48 targets
-- in a single frame measured up to 9ms in a 40-man AV -- over half a 60fps
-- frame, landing as a visible hitch every few seconds. A slice covers the same
-- ground on the same POLL_INTERVAL period, so no unit waits any longer than it
-- did before; the cost is just spread over SWEEP_SLICES frames instead of
-- falling on one.
local SWEEP_SLICES = 12
local SWEEP_INTERVAL = POLL_INTERVAL / SWEEP_SLICES

C_Timer.NewTicker(SWEEP_INTERVAL, function()
    if not nameToKey then BuildNameMap() end
    PBegin("bufftracking.sweep")
    local changed = false

    if not sweepTargets or sweepCursor >= #sweepTargets then
        -- Cycle boundary. Everything the cycle just finished never saw has
        -- left the group, so prune it here -- one cycle covers exactly the
        -- ground the old all-at-once poll covered in a single pass, so this
        -- keeps its guarantee rather than leaning on GROUP_ROSTER_UPDATE.
        if sweepSeen then
            for name in pairs(state) do
                if not sweepSeen[name] then
                    state[name] = nil
                    changed = true
                end
            end
        end
        sweepTargets = GroupTargets()
        sweepCursor = 0
        sweepSeen = {}
    end

    local total = #sweepTargets
    local slice = math.ceil(total / SWEEP_SLICES)
    local last = math.min(sweepCursor + slice, total)
    for i = sweepCursor + 1, last do
        local t = sweepTargets[i]
        sweepSeen[t.key] = true
        -- A unit token is only a position in the raid, so someone leaving
        -- shifts everyone after them onto different tokens. Re-check identity
        -- before scanning, so a slot that moved mid-cycle scans nobody rather
        -- than filing one raider's auras under another's name.
        if UnitExists(t.unit) and UnitToKey(t.ownerUnit) == t.ownerKey then
            if ScanUnit(t.unit, t.key) then changed = true end
        end
    end
    sweepCursor = last

    PEnd("bufftracking.sweep")
    if changed then NotifyChanged() end
end)
