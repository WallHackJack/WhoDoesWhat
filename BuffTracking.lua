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
-- available regardless of range -- what goes stale out of range is the
-- duration/expiration, not the presence of the buff. Since we only track
-- present-vs-absent and never read durations, missing-buff detection works
-- across the whole raid, not just nearby.
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

-- name -> { buffs = { [buffKey] = true }, sources = { [buffKey] = name|false },
-- connected = bool }. false means the aura is present but its caster was not
-- exposed by the client. Absence of an
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
local nameToKey
local function BuildNameMap()
    nameToKey = {}
    for key, buff in pairs(WhoDoesWhat.PaladinBuffs) do
        local greaterName = GetSpellInfo(buff.spellId)
        if greaterName then
            nameToKey[greaterName] = key
            nameToKey[(greaterName:gsub("^Greater ", ""))] = key
        end
    end
    for key, buff in pairs(WhoDoesWhat.CoreRaidBuffs) do
        for _, auraName in ipairs(buff.auraNames) do
            nameToKey[auraName] = key
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
-- fallback. Calls fn(auraName, sourceUnit) for each.
local function ForEachBuff(unit, fn)
    local i = 1
    if GetBuffDataByIndex then
        while true do
            local aura = GetBuffDataByIndex(unit, i)
            if not aura then break end
            if aura.name then fn(aura.name, aura.sourceUnit) end
            i = i + 1
        end
    else
        while true do
            local auraName, _, _, _, _, _, sourceUnit = UnitBuff(unit, i)
            if not auraName then break end
            fn(auraName, sourceUnit)
            i = i + 1
        end
    end
end

-- Did the freshly-scanned buff set differ from what we had stored?
local function Differs(prev, buffs, sources, connected)
    if not prev or prev.connected ~= connected then return true end
    for key in pairs(buffs) do
        if not prev.buffs[key] then return true end
        if not prev.sources or prev.sources[key] ~= sources[key] then return true end
    end
    for key in pairs(prev.buffs) do
        if not buffs[key] then return true end
    end
    return false
end

-- Scan one unit's active blessings into state[name]; returns whether anything
-- changed. The aura list is available for group members at any range, so a
-- blessing simply not appearing here is a genuine "missing", not a range gap.
local function ScanUnit(unit, name)
    local buffs, sources = {}, {}
    ForEachBuff(unit, function(auraName, sourceUnit)
        local key = nameToKey[auraName]
        if key then
            buffs[key] = true
            sources[key] = (sourceUnit and UnitToKey(sourceUnit)) or false
        end
    end)
    local connected = UnitIsConnected(unit) ~= false
    local changed = Differs(state[name], buffs, sources, connected)
    state[name] = { buffs = buffs, sources = sources, connected = connected }
    return changed
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
        WhoDoesWhat:RefreshImprovedBuffGridView()
        -- RefreshPaladinBuffGridView also nudges both compact status views.
        WhoDoesWhat:RefreshPaladinBuffGridView()
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

-- The set of blessing keys currently active on a raider, or nil for anyone
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

-- Status of a talent-improved core buff on one target. The aura itself has no
-- separate "improved" spell id, so max/partial/base is inferred from its
-- source player and that player's scanned talent rank.
function WhoDoesWhat:GetImprovedBuffState(name, key)
    local has = self:HasBuff(name, key)
    if has ~= true then return has == false and "missing" or "unknown" end

    local buff = self.CoreRaidBuffs[key]
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
driver:SetScript("OnEvent", function(_, event, unit)
    if event == "UNIT_AURA" then
        if IsGroupUnit(unit) then
            if not nameToKey then BuildNameMap() end
            local name = UnitToKey(unit)
            if name and ScanUnit(unit, name) then NotifyChanged() end
        end
    else
        BuffTracking:RefreshAll()
    end
end)

-- Backstop: catches out-of-range expiries, death/rez, and anything UNIT_AURA
-- didn't deliver -- UNIT_AURA fires unreliably for distant units.
C_Timer.NewTicker(POLL_INTERVAL, function() BuffTracking:RefreshAll() end)
