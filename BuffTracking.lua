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
-- casting without listing every rank's spellId. We register both the "Greater
-- Blessing of X" name and the single-target "Blessing of X", each from its
-- stored spellId, so a raider on either form reads as covered. The other
-- checks' `auraSpellIds` resolve the same way, one id per name, so every name
-- comes from the client in its own language.
--
-- The elixir checks (`elixirCategory`) match by spell id instead, as a list of
-- keys: elixir auras collide by name (Elixir of Agility's and every Scroll of
-- Agility's are all "Agility"), and one flask fills both the battle and the
-- guardian row. Each listed item's use-spell is its aura. An item the client
-- hasn't loaded yet has no spell to give, so it is asked for and the map is
-- rebuilt when it arrives (GET_ITEM_INFO_RECEIVED below). A check's
-- `itemSpells` does the same for things consumed instantly, whose buff is
-- their use-spell: Blessed Sunfruit and the drinks.
--
-- `flaskSpells` marks the flasks among them, for the grid: it draws a flask
-- once, in the battle column. `elixirItems` is the item each spell came from,
-- for the grid's tooltip.
local nameToKey, debuffNameToKey, spellIdToKeys
local pendingElixirItems, flaskSpells, elixirItems = {}, {}, {}
local function AddElixirSpells(key, ids, isFlask)
    for _, id in ipairs(ids or {}) do
        local _, spellId = GetItemSpell(id)
        if spellId then
            local keys = spellIdToKeys[spellId] or {}
            keys[#keys + 1] = key
            spellIdToKeys[spellId] = keys
            if isFlask then flaskSpells[spellId] = true end
            elixirItems[spellId] = id
            pendingElixirItems[id] = nil
        else
            pendingElixirItems[id] = true
            if C_Item and C_Item.RequestLoadItemDataByID then
                C_Item.RequestLoadItemDataByID(id)
            end
        end
    end
end

local function BuildNameMap()
    nameToKey = {}
    debuffNameToKey = {}
    spellIdToKeys = {}
    for key, check in pairs(WhoDoesWhat.StatusBarChecks) do
        if check.elixirCategory then
            AddElixirSpells(key, WhoDoesWhat.ElixirItems[check.elixirCategory])
            AddElixirSpells(key, WhoDoesWhat.ElixirItems.flask, true)
        end
        AddElixirSpells(key, check.itemSpells)
    end
    -- Nil when there is nothing to match, so the scan skips the lookup.
    if not next(spellIdToKeys) then spellIdToKeys = nil end
    for key, buff in pairs(WhoDoesWhat.PaladinBuffs) do
        for _, spellId in ipairs({ buff.spellId, buff.normalSpellId }) do
            local name = GetSpellInfo(spellId)
            if name then nameToKey[name] = key end
        end
    end
    for key, check in pairs(WhoDoesWhat.StatusBarChecks) do
        local map = check.harmful and debuffNameToKey or nameToKey
        for _, spellId in ipairs(check.auraSpellIds or {}) do
            local name = GetSpellInfo(spellId)
            if name then map[name] = key end
        end
    end
    -- Warrior shouts (Data.lua). Rank-independent like the blessings above --
    -- the name a shout carries is the same at every rank -- and tracked here
    -- rather than as StatusBarChecks because the Shout Bar is the only thing
    -- reading them; they are not raid-wide coverage rows.
    for _, shout in ipairs(WhoDoesWhat.WarriorShouts) do
        nameToKey[shout.name] = shout.key
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
    -- A restricted client hands back a secret name for a unit it will not let
    -- an addon see -- an aura's sourceUnit when the caster is an NPC outside
    -- the group, such as the druid in Wailing Caverns who hands out Mark of
    -- the Wild. A secret string cannot be compared or concatenated without
    -- erroring, so it is no key at all: callers already treat nil as "no
    -- name", and StoreAura files it as a caster the client would not expose.
    if not name or WhoDoesWhat:IsSecret(name) then return nil end
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
            -- A Steam Tonk is not one of them (Core.lua): scanning it would
            -- report the tonk's auras as the hunter pet's.
            if UnitExists(o[2])
                and not WhoDoesWhat:IsIgnoredPetName(GetUnitName(o[2], true)) then
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
--
-- `spellMap` (spell id -> keys) is the elixir checks' map, nil for debuffs;
-- `spellIds` records which spell each of those keys matched.
local function ScanAuraList(unit, harmful, map, spellMap, buffs, sources,
                            expirations, previous, spellIds)
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
                if key == "food" then spellIds.food = aura.spellId end
            end
            local keys = spellMap and aura.spellId and spellMap[aura.spellId]
            if keys then
                for _, spellKey in ipairs(keys) do
                    StoreAura(spellKey, aura.sourceUnit, aura.expirationTime,
                        buffs, sources, expirations, previous)
                    spellIds[spellKey] = aura.spellId
                end
            end
            i = i + 1
        end
    else
        local Indexed = harmful and UnitDebuff or UnitBuff
        while true do
            local auraName, _, _, _, _, expirationTime, sourceUnit, _, _, spellId =
                Indexed(unit, i)
            if not auraName then break end
            local key = map[auraName]
            if key then
                StoreAura(key, sourceUnit, expirationTime,
                    buffs, sources, expirations, previous)
                if key == "food" then spellIds.food = spellId end
            end
            local keys = spellMap and spellId and spellMap[spellId]
            if keys then
                for _, spellKey in ipairs(keys) do
                    StoreAura(spellKey, sourceUnit, expirationTime,
                        buffs, sources, expirations, previous)
                    spellIds[spellKey] = spellId
                end
            end
            i = i + 1
        end
    end
end

-- Did the freshly-scanned buff set differ from what we had stored?
local function Differs(prev, buffs, sources, expirations, spellIds, connected)
    if not prev or prev.connected ~= connected then return true end
    for key in pairs(buffs) do
        if not prev.buffs[key] then return true end
        if not prev.sources or prev.sources[key] ~= sources[key] then return true end
        if not prev.expirations
            or prev.expirations[key] ~= expirations[key] then return true end
        if (prev.spellIds and prev.spellIds[key]) ~= spellIds[key] then
            return true
        end
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
    local buffs, sources, expirations, spellIds = {}, {}, {}, {}
    ScanAuraList(unit, false, nameToKey, spellIdToKeys, buffs, sources,
        expirations, previous, spellIds)
    -- Skipped outright when no harmful check is configured: with an empty map
    -- the debuff walk can only ever read every debuff on the unit and discard
    -- all of them.
    if next(debuffNameToKey) then
        ScanAuraList(unit, true, debuffNameToKey, nil, buffs, sources,
            expirations, previous)
    end
    if UnitIsDeadOrGhost(unit) then buffs.dead = true end
    local connected = UnitIsConnected(unit) ~= false
    local changed = Differs(state[name], buffs, sources, expirations, spellIds,
        connected)
    state[name] = {
        buffs = buffs, sources = sources, expirations = expirations,
        spellIds = spellIds, connected = connected,
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
    if WhoDoesWhat:AurasSecret() then return end
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

-- The spell an elixir or food check matched on a raider, whether it is a
-- flask (which fills both elixir checks), and the elixir's item id; nil when
-- none is recorded.
function WhoDoesWhat:GetElixirSpell(name, key)
    local s = state[name]
    local spellId = s and s.spellIds and s.spellIds[key]
    return spellId, spellId ~= nil and flaskSpells[spellId] == true,
        spellId and elixirItems[spellId]
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
driver:RegisterEvent("GET_ITEM_INFO_RECEIVED")
-- Instrumented per EVENT rather than per scan: in a 40-man these fire
-- constantly (UNIT_HEALTH on every health tick of every raider), so the cost
-- that matters is count x cheap, not any single slow call. The two are
-- separate sections because they do very different amounts of work --
-- UNIT_AURA walks every aura on the unit, UNIT_HEALTH just checks death.
driver:SetScript("OnEvent", function(_, event, unit)
    if event == "GET_ITEM_INFO_RECEIVED" then
        -- `unit` is an item id here. One the elixir map was waiting on means
        -- a rebuild; the next scan picks it up.
        if pendingElixirItems[unit] then nameToKey = nil end
    elseif WhoDoesWhat:AurasSecret() then
        -- Hidden auras: hold the last readable state (see the sweep below).
        return
    elseif event == "UNIT_AURA" and unit == "pet" then
        -- Your own pet, scanned now rather than on the sweep: feeding it or
        -- buffing it is something you are watching for (the Buff Checklist's
        -- pet section), and waiting up to a full cycle read as the click not
        -- working. Other pets stay on the sweep, as UNIT_AURA is unreliable
        -- for them and they are nobody's immediate business.
        local owner = UnitToKey("player")
        if owner and not WhoDoesWhat:IsIgnoredPetName(GetUnitName("pet", true)) then
            if not nameToKey then BuildNameMap() end
            if ScanUnit("pet", owner .. "'s Pet") then NotifyChanged() end
        end
    elseif event == "UNIT_AURA" or event == "UNIT_HEALTH" then
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

-- While the client hides aura data (ClientFeatures' AurasSecret), every scan is
-- skipped and the last readable state stands. A scan would otherwise either
-- record every raider as missing everything (reads return nil) or error on
-- using a secret aura name as a key. The buffs tracked last minutes, so the
-- pre-pull state is the right answer for a fight; the first tick after the
-- data comes back rescans everyone at once.
local held = false

C_Timer.NewTicker(SWEEP_INTERVAL, function()
    if WhoDoesWhat:AurasSecret() then
        held = true
        return
    elseif held then
        held = false
        BuffTracking:RefreshAll()
        return
    end
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

-- ---------------------------------------------------------------------------
-- Casts taken at their word while auras are secret
-- ---------------------------------------------------------------------------

-- The held state above has one blind spot: a buff given mid-fight -- a drink,
-- an elixir, a scroll, a blessing, a shout -- reads as missing until the fight
-- ends, which invites a second one. So a spell you finish casting while auras
-- are hidden is assumed to have landed: whatever it puts on its targets is
-- filed as present, with no timer, until the first readable rescan (the `held`
-- handoff) replaces it with the truth.
--
-- UNIT_SPELLCAST_SENT names the target, matched against the group; a cast
-- naming nobody in it (an enemy) is left alone, and one whose SENT couldn't be
-- read counts as cast on you. Who else it reaches follows the game, minus
-- range, which a hidden-aura fight can't check:
--   * a Greater Blessing: everyone alive of the target's class, with hunter
--     pets riding the Warrior one; it replaces any other blessing of yours
--     on them, as a paladin's blessings do
--   * a shout: everyone alive in your party (your raid subgroup)
--   * anything else: the target
--
-- Listeners (BuffTracking:OnAssumedCast) hear (unit, spellId), unit "player"
-- or "pet", when the target was you or your pet -- for state that isn't kept
-- here, like the Buff Checklist's and Paladin Bar's own aura reads.

local sentTargets = {} -- castGUID -> GroupTargets entry, or false (not the group)
local assumedCastListeners = {}
local greaterNames, shoutNames -- spell name -> true, built on first use

function BuffTracking:OnAssumedCast(listener)
    assumedCastListeners[#assumedCastListeners + 1] = listener
end

-- Whether a tracked buff on this raider is one of these assumptions, rather
-- than something a scan saw.
function WhoDoesWhat:IsBuffAssumed(name, key)
    local s = state[name]
    return s and s.assumed and s.assumed[key] == true or false
end

local function NamesUnit(target, unit)
    local name, realm = UnitName(unit)
    if not name or WhoDoesWhat:IsSecret(name) then return false end
    return target == name or target == GetUnitName(unit, true)
        or (realm ~= nil and realm ~= "" and target == name .. "-" .. realm)
end

-- The GroupTargets entry a SENT target names; no name at all is you.
local function FindTarget(target)
    if not target or target == "" then target = UnitName("player") end
    for _, t in ipairs(GroupTargets()) do
        if NamesUnit(target, t.unit) then return t end
    end
    return nil
end

-- The class a Greater Blessing sorts a target into.
local function BlessingClass(t)
    if t.unit ~= t.ownerUnit then return "WARRIOR" end
    local _, class = UnitClass(t.unit)
    if WhoDoesWhat:IsSecret(class) then return nil end
    return class
end

-- Raid subgroup of an owner's unit; nil outside a raid, where the party is
-- everyone.
local function Subgroup(unit)
    local index = tonumber(unit:match("^raid(%d+)$"))
    if not index then return nil end
    local _, _, subgroup = GetRaidRosterInfo(index)
    return subgroup
end

local function AssumeCast(target, spellId)
    local owner = UnitToKey("player")
    local name = GetSpellInfo(spellId)
    if not owner or not name then return end
    if not nameToKey then BuildNameMap() end
    if not greaterNames then
        greaterNames, shoutNames = {}, {}
        for _, buff in pairs(WhoDoesWhat.PaladinBuffs) do
            local greater = GetSpellInfo(buff.spellId)
            if greater then greaterNames[greater] = true end
        end
        for _, shout in ipairs(WhoDoesWhat.WarriorShouts) do
            shoutNames[shout.name] = true
        end
    end

    local recipients = { target }
    if greaterNames[name] then
        local class = BlessingClass(target)
        recipients = {}
        for _, t in ipairs(class and GroupTargets() or {}) do
            if BlessingClass(t) == class then recipients[#recipients + 1] = t end
        end
    elseif shoutNames[name] then
        local subgroup = Subgroup(target.ownerUnit)
        recipients = {}
        for _, t in ipairs(GroupTargets()) do
            if Subgroup(t.ownerUnit) == subgroup then recipients[#recipients + 1] = t end
        end
    end

    local key = nameToKey[name]
    local spellKeys = spellIdToKeys and spellIdToKeys[spellId]
    local blessing = key and WhoDoesWhat.PaladinBuffs[key]
    local changed = false
    local function Assume(s, buffKey, matchedSpellId)
        s.buffs[buffKey] = true
        s.sources[buffKey] = owner
        s.expirations[buffKey] = nil
        if matchedSpellId then s.spellIds[buffKey] = matchedSpellId end
        s.assumed = s.assumed or {}
        s.assumed[buffKey] = true
        changed = true
    end
    for _, t in ipairs((key or spellKeys) and recipients or {}) do
        -- Only a raider already scanned: a fresh entry holding just this buff
        -- would turn every other buff from unknown into confirmed missing.
        local s = state[t.key]
        if s and not s.buffs.dead then
            if blessing then
                for other in pairs(WhoDoesWhat.PaladinBuffs) do
                    if other ~= key and s.sources[other] == owner then
                        s.buffs[other], s.sources[other], s.expirations[other] =
                            nil, nil, nil
                    end
                end
            end
            if key then Assume(s, key) end
            for _, spellKey in ipairs(spellKeys or {}) do
                Assume(s, spellKey, spellId)
            end
        end
    end

    local unit = target.key == owner and "player"
        or target.key == owner .. "'s Pet" and "pet" or nil
    if unit then
        for _, listener in ipairs(assumedCastListeners) do listener(unit, spellId) end
    end
    if changed then NotifyChanged() end
end

local castWatcher = CreateFrame("Frame")
castWatcher:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
castWatcher:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
castWatcher:SetScript("OnEvent", function(_, event, _, arg2, arg3)
    local IsSecret = WhoDoesWhat.IsSecret
    if not WhoDoesWhat:AurasSecret() then
        -- Casts that never finished leave their entry behind; out of combat
        -- is when to let them go.
        if next(sentTargets) then wipe(sentTargets) end
        return
    end
    if event == "UNIT_SPELLCAST_SENT" then
        -- (unit, target, castGUID, spellId)
        local target, castGUID = arg2, arg3
        if not castGUID or IsSecret(WhoDoesWhat, castGUID)
            or IsSecret(WhoDoesWhat, target) then
            return
        end
        sentTargets[castGUID] = FindTarget(target) or false
        return
    end
    -- UNIT_SPELLCAST_SUCCEEDED: (unit, castGUID, spellId)
    local castGUID, spellId = arg2, arg3
    if not spellId or IsSecret(WhoDoesWhat, spellId) then return end
    local target
    if castGUID and not IsSecret(WhoDoesWhat, castGUID) then
        target = sentTargets[castGUID]
        sentTargets[castGUID] = nil
    end
    if target == nil then target = FindTarget(nil) end
    if target then AssumeCast(target, spellId) end
end)
