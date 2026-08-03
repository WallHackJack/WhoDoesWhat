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

local POLL_INTERVAL = 3     -- seconds between full-group backstop scans
local NOTIFY_DEBOUNCE = 0.1 -- coalesce repaint requests from bursts of events

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
-- off-raid), plus each hunter's pet keyed "<Owner>'s Pet" to match the plan /
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
            targets[#targets + 1] = { unit = o[1], key = key }
            -- Only hunter pets take blessings we plan for (warlock pets aren't
            -- covered); match GetPetMembers, which is hunters-only.
            if UnitExists(o[2]) and select(2, UnitClass(o[1])) == "HUNTER" then
                targets[#targets + 1] = { unit = o[2], key = key .. "'s Pet" }
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

-- Walk a unit's buffs, newest API first (C_UnitAuras), indexed UnitBuff as the
-- fallback. Calls fn(auraName, sourceUnit, expirationTime) for each.
local function ForEachBuff(unit, fn)
    local i = 1
    if GetBuffDataByIndex then
        while true do
            local aura = GetBuffDataByIndex(unit, i)
            if not aura then break end
            if aura.name then
                fn(aura.name, aura.sourceUnit, aura.expirationTime)
            end
            i = i + 1
        end
    else
        while true do
            local auraName, _, _, _, _, expirationTime, sourceUnit = UnitBuff(unit, i)
            if not auraName then break end
            fn(auraName, sourceUnit, expirationTime)
            i = i + 1
        end
    end
end

local function ForEachDebuff(unit, fn)
    local i = 1
    if GetDebuffDataByIndex then
        while true do
            local aura = GetDebuffDataByIndex(unit, i)
            if not aura then break end
            if aura.name then
                fn(aura.name, aura.sourceUnit, aura.expirationTime)
            end
            i = i + 1
        end
    else
        while true do
            local auraName, _, _, _, _, expirationTime, sourceUnit = UnitDebuff(unit, i)
            if not auraName then break end
            fn(auraName, sourceUnit, expirationTime)
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
    local function StoreAura(map, auraName, sourceUnit, expirationTime)
        local key = map[auraName]
        if not key then return end
        buffs[key] = true
        sources[key] = (sourceUnit and UnitToKey(sourceUnit)) or false
        expirations[key] = expirationTime and expirationTime > 0
            and expirationTime
            or previous and previous.expirations and previous.expirations[key]
    end
    ForEachBuff(unit, function(auraName, sourceUnit, expirationTime)
        StoreAura(nameToKey, auraName, sourceUnit, expirationTime)
    end)
    ForEachDebuff(unit, function(auraName, sourceUnit, expirationTime)
        StoreAura(debuffNameToKey, auraName, sourceUnit, expirationTime)
    end)
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

-- Bursts of UNIT_AURA (a raid-wide rebuff) collapse into one repaint a tick
-- later. Consumers that need the live buff state hook in here.
local notifyPending
local function NotifyChanged()
    if notifyPending then return end
    notifyPending = true
    C_Timer.After(NOTIFY_DEBOUNCE, function()
        notifyPending = false
        WhoDoesWhat:RefreshMainAssignmentsView()
        -- RefreshBuffingGridView also nudges both compact status views.
        WhoDoesWhat:RefreshBuffingGridView()
    end)
end

-- ---------------------------------------------------------------------------
-- Public state refresh + query API
-- ---------------------------------------------------------------------------

-- Re-scan the whole group and drop anyone who left. The backstop poll and
-- roster changes both land here.
function BuffTracking:RefreshAll()
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
driver:SetScript("OnEvent", function(_, event, unit)
    if event == "UNIT_AURA" or event == "UNIT_HEALTH" then
        if IsGroupUnit(unit) then
            if not nameToKey then BuildNameMap() end
            local name = UnitToKey(unit)
            local changed
            if name then
                changed = event == "UNIT_HEALTH" and ScanDead(unit, name)
                    or event == "UNIT_AURA" and ScanUnit(unit, name)
            end
            if changed then NotifyChanged() end
        end
    else
        BuffTracking:RefreshAll()
    end
end)

-- Backstop: catches out-of-range expiries, death/rez, and anything UNIT_AURA
-- didn't deliver -- UNIT_AURA fires unreliably for distant units.
C_Timer.NewTicker(POLL_INTERVAL, function() BuffTracking:RefreshAll() end)
