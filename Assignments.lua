local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Assignment model for the main /wdw window -- the non-UI half of what used
-- to be one large MainAssignmentsView.lua: group-member helpers, marker /
-- spell / target text, the dynamic + static section definitions, whisper
-- collectors, the paladin buff-talent demand math, the auto-assigns, and the
-- saved-assignment storage. Everything is exported on WhoDoesWhat.Assign
-- (see the bottom); the view and UnitMenuExtensions.lua re-localize what
-- they use. Nothing here creates frames; repaints go through the views'
-- public Refresh methods, which no-op while their window is closed.

local CUSTOM_TARGET_ICON = 134400 -- INV_Misc_QuestionMark, our "custom" marker

-- Stable player key for a unit: "Name" same-realm, "Name-Realm" foreign.
-- Matches the keying used by db.profile.assignments (UnitMenuExtensions.lua).
local function GetUnitKey(unit)
    local name, realm = UnitName(unit)
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

-- Our Classes entry for a locale-independent english class token ("PALADIN").
local function GetClassInfoByToken(englishClass)
    for _, classInfo in ipairs(WhoDoesWhat.Classes) do
        if classInfo.name:upper() == englishClass then
            return classInfo
        end
    end
    return nil
end

-- Developer Mode is "let me build anything": it lifts the class filters on
-- both the player and CC spell lists, and opts out of the auto-clear that
-- would otherwise undo a deliberate mismatch. The warning icons still fire.
local function DevMode()
    return WhoDoesWhat.db.profile.settings.developerMode
end

-- Current group members as sorted { name, classInfo } entries. Raid uses raid
-- units; party includes the player; solo is just the player (handy for
-- testing). With onlyClassName set (e.g. "Paladin") only that class is
-- listed -- unless the Developer Mode setting is on, which lists everyone.
--
-- Non-raiders (the unit-menu pseudo-role) appear only in the unfiltered
-- (nil) roster view -- presence checks, name coloring, prune -- and are
-- dropped from every class-filtered query, which is what feeds the buff/
-- curse dropdowns and pools: someone sitting out isn't a buff option.
local function GetEligibleMembers(onlyClassName)
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

    local devMode = DevMode()
    local members = {}
    for _, unit in ipairs(units) do
        local name = GetUnitKey(unit)
        local _, englishClass = UnitClass(unit)
        local classInfo = englishClass and GetClassInfoByToken(englishClass)
        if name and classInfo
            and (devMode or not onlyClassName or classInfo.name == onlyClassName)
            and not (onlyClassName and WhoDoesWhat:IsNonRaider(name)) then
            members[#members + 1] = { name = name, classInfo = classInfo }
        end
    end

    -- Testing aid: fold in the fake raiders (FakeRaid.lua) when the toggle is
    -- on. Same class filter as the real members; their roles/talents live in
    -- the DB keyed by name, so everything downstream treats them like anyone.
    if WhoDoesWhat.FakeRaid and WhoDoesWhat:IsFakeRaidEnabled() then
        for _, fm in ipairs(WhoDoesWhat.FakeRaid.ROSTER) do
            local classInfo = GetClassInfoByToken(fm.class)
            if classInfo and (devMode or not onlyClassName or classInfo.name == onlyClassName)
                and not (onlyClassName and WhoDoesWhat:IsNonRaider(fm.name)) then
                members[#members + 1] = { name = fm.name, classInfo = classInfo }
            end
        end
    end

    table.sort(members, function(a, b) return a.name < b.name end)
    return members
end

-- The group member with this name, or nil once they've left.
local function FindMember(name)
    for _, m in ipairs(GetEligibleMembers(nil)) do
        if m.name == name then return m end
    end
    return nil
end

-- Member names strictly of a class: Developer Mode widens GetEligibleMembers
-- to everyone, but the demand math and the auto-assigns need real paladins /
-- warlocks, not whoever the lifted filter lets through.
local function MembersOfClass(className)
    local out = {}
    for _, m in ipairs(GetEligibleMembers(className)) do
        if m.classInfo.name == className then
            out[#out + 1] = m.name
        end
    end
    return out
end

-- One virtual pet per hunter in the group (a non-raider hunter's pet sits
-- out with them -- the class-filtered roster already drops both). Pets are
-- not assignable and never stored: they exist purely for the paladin-buff
-- math, each carrying the hunter_pets pseudo-role's wants so pet coverage
-- is derived automatically. Keyed/displayed as "<Hunter>'s Pet" (real
-- character names can't contain an apostrophe, so the keys can't collide
-- with a raider); entries carry owner + isPet for the buff grid view and
-- the PallyPower bridge.
local function GetPetMembers()
    local out = {}
    for _, m in ipairs(GetEligibleMembers("Hunter")) do
        if m.classInfo.name == "Hunter" then
            out[#out + 1] = {
                name = m.name .. "'s Pet",
                owner = m.name,
                classInfo = m.classInfo,
                isPet = true,
            }
        end
    end
    return out
end

-- What a pet wants and nothing more: the hunter_pets defaults, minus any
-- rule-ignored buff. Deliberately NOT backfilled to all six -- a pet whose
-- top-ups are covered shows an empty grid cell rather than collecting
-- Salvation from an otherwise-idle paladin.
local PET_WANTS = { "might", "kings" }
local function PetBuffOrder(ignored)
    local order = {}
    for _, key in ipairs(PET_WANTS) do
        if not ignored[key] then
            order[#order + 1] = key
        end
    end
    return order
end

-- Dropdown display text for an assignment: class-colored name while the
-- player is in the group, gray name once they've left, gray "Unassigned"
-- when nothing is saved.
local function PlayerText(name)
    if not name then
        return "|cff909090Unassigned|r"
    end
    local m = FindMember(name)
    if m then
        return "|cff" .. m.classInfo.colorHex .. name .. "|r"
    end
    return "|cff909090" .. name .. "|r"
end

-- Role-icon markup for a player's assigned spec, or "" when they're roleless
-- or the saved id no longer resolves. Trailing space so it prefixes cleanly.
local function RoleIconMarkup(name, size)
    if not name then return "" end
    local roleId = WhoDoesWhat:GetAssignedRole(name)
    if not roleId then return "" end
    local _, role = WhoDoesWhat:FindRoleById(roleId)
    if not role or not role.icon then return "" end
    size = size or 14
    return "|T" .. role.icon .. ":" .. size .. ":" .. size .. ":0:0|t "
end

-- PlayerText with the player's role icon in front (assignment dropdowns). Falls
-- back to plain PlayerText when there's no name or no resolvable role.
local function PlayerTextWithRole(name, size)
    return RoleIconMarkup(name, size) .. PlayerText(name)
end

local function GetAssignment(rowId)
    return WhoDoesWhat.db.profile.raidAssignments[rowId]
end

-- ---------------------------------------------------------------------------
-- Marker / target helpers (shared by every dynamic section)
-- ---------------------------------------------------------------------------

local function MarkerMarkup(index, size)
    return "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_" .. index
        .. ":" .. size .. ":" .. size .. ":0:0|t"
end

local function MarkerByIndex(index)
    for _, m in ipairs(WhoDoesWhat.RaidTargetMarkers) do
        if m.index == index then return m end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Marker VALUES: a tank row's `markers` array holds any mix of 1..8, "all"
-- ("Everything else") and "custom". CC rows keep a single `marker` field of
-- the same vocabulary. The three MarkerValue* renderers below are the
-- single-value forms the Target* functions build from.
-- ---------------------------------------------------------------------------

-- Canonical order for a tank row's marker list: skull-first markers, then
-- "Everything else", then Custom. Keeps FirstTankMarker the skull-most
-- marker and every client rendering the same row identically.
local MARKER_VALUE_RANK = {}
for i, m in ipairs(WhoDoesWhat.RaidTargetMarkers) do MARKER_VALUE_RANK[m.index] = i end
MARKER_VALUE_RANK["all"] = 9
MARKER_VALUE_RANK["custom"] = 10

local function NormalizeMarkers(markers)
    table.sort(markers, function(a, b)
        return (MARKER_VALUE_RANK[a] or 99) < (MARKER_VALUE_RANK[b] or 99)
    end)
    return markers
end

local function HasMarkerValue(entry, value)
    for _, v in ipairs(entry.markers or {}) do
        if v == value then return true end
    end
    return false
end

-- Icon-ish form: the bare marker icon (the "?" icon for Custom), words for
-- "Everything else", which has no icon to stand in for it.
local function MarkerValueText(v)
    if v == "custom" then
        return "|T" .. CUSTOM_TARGET_ICON .. ":14:14:0:0|t"
    elseif v == "all" then
        return "Everything else"
    end
    local m = MarkerByIndex(v)
    return m and MarkerMarkup(m.index, 14) or "?"
end

-- Plain words (marker names, the custom text spelled out).
local function MarkerValuePlain(v, customText)
    if v == "custom" then
        return (customText and customText ~= "") and customText or "Custom"
    elseif v == "all" then
        return "Everything else"
    end
    local m = MarkerByIndex(v)
    return m and m.name or "?"
end

-- Chat form: {skull}-style tokens the receiving client expands into icons;
-- Custom / Everything else have no token and stay words.
local function MarkerValueChat(v, customText)
    if type(v) == "number" then
        local m = MarkerByIndex(v)
        return m and ("{" .. m.name:lower() .. "}") or "?"
    end
    return MarkerValuePlain(v, customText)
end

-- Collapsed marker-dropdown text: the bare icon(s), since the box is only
-- wide enough for icons (the menu items themselves keep their names). A
-- multi-marker row concatenates all its values; an empty one shows a gray
-- placeholder. See MarkerDDWidth in the view for how the box grows.
local function TargetText(entry)
    if entry.markers then
        if #entry.markers == 0 then return "|cff909090--|r" end
        local parts = {}
        for _, v in ipairs(entry.markers) do
            parts[#parts + 1] = MarkerValueText(v)
        end
        return table.concat(parts, " ")
    end
    return MarkerValueText(entry.marker)
end

-- Read-only line form: icons where they exist, the custom text spelled out.
local function MarkersRichText(entry)
    if #(entry.markers or {}) == 0 then return "|cff909090--|r" end
    local parts = {}
    for _, v in ipairs(entry.markers) do
        if v == "custom" then
            parts[#parts + 1] = (entry.custom and entry.custom ~= "") and entry.custom
                or ("|T" .. CUSTOM_TARGET_ICON .. ":14:14:0:0|t Custom")
        else
            parts[#parts + 1] = MarkerValueText(v)
        end
    end
    return table.concat(parts, ", ")
end

-- Target text in plain words, for our own :Print() output and tooltips.
-- AddMessage doesn't expand chat's {skull} tokens, so those would show up
-- literally here; the words are what we want in our own chat anyway.
-- Player-target entries (Misdirects) name the player, with their optional
-- marker in words after it.
local function TargetPlainText(entry)
    if entry.target then
        local m = MarkerByIndex(entry.marker)
        return m and (entry.target .. " (" .. m.name .. ")") or entry.target
    end
    if entry.markers then
        if #entry.markers == 0 then return "no marker" end
        local parts = {}
        for _, v in ipairs(entry.markers) do
            parts[#parts + 1] = MarkerValuePlain(v, entry.custom)
        end
        return table.concat(parts, ", ")
    end
    return MarkerValuePlain(entry.marker, entry.custom)
end

-- Target text for whispers: chat's raid-marker tokens (see MarkerValueChat).
-- Player targets (Misdirects) lead with the name, marker token after when set.
local function TargetChatText(entry)
    if entry.target then
        local m = MarkerByIndex(entry.marker)
        local token = m and ("{" .. m.name:lower() .. "}")
        return token and (entry.target .. " " .. token) or entry.target
    end
    if entry.markers then
        if #entry.markers == 0 then return "no marker" end
        local parts = {}
        for _, v in ipairs(entry.markers) do
            parts[#parts + 1] = MarkerValueChat(v, entry.custom)
        end
        return table.concat(parts, " ")
    end
    return MarkerValueChat(entry.marker, entry.custom)
end

-- Collapsed spell-dropdown text: icon + class-colored name, or a prompt while
-- nothing is picked yet.
local function SpellText(spell)
    if not spell then
        return "|cff909090Choose...|r"
    end
    local classInfo = GetClassInfoByToken(spell.class:upper())
    return "|T" .. WhoDoesWhat:GetSpellIcon(spell.spellId) .. ":14:14:0:0|t |cff"
        .. (classInfo and classInfo.colorHex or "ffffff") .. spell.name .. "|r"
end

local function SpellById(id)
    return id and WhoDoesWhat.CCSpellsById[id] or nil
end

-- The spells a row can offer: what the assigned player's class can actually
-- cast. With nobody assigned there's no class to filter by, so the whole list
-- shows and the fight can be planned before the raid fills.
local function SpellsForEntry(section, entry)
    local m = entry.player and FindMember(entry.player)
    if not m or DevMode() then
        return section.spells
    end
    local out = {}
    for _, spell in ipairs(section.spells) do
        if spell.class == m.classInfo.name then
            out[#out + 1] = spell
        end
    end
    return out
end

-- Drop a spell the newly assigned player can't cast -- it's meaningless on
-- them, and it isn't in their dropdown to re-pick anyway. Leaving the player
-- unassigned keeps the spell: they're most likely swapping in someone else of
-- the same class.
local function ClearSpellIfUncastable(entry, newPlayer)
    if not (entry.spell and newPlayer) or DevMode() then return end
    local spell = SpellById(entry.spell)
    local m = FindMember(newPlayer)
    if spell and m and m.classInfo.name ~= spell.class then
        entry.spell = nil
    end
end

-- Names of every marked tank in the group (GetEligibleMembers is sorted, so
-- this is name-sorted too). Drives the tank section's auto rows and Reset.
local function MarkedTankNames()
    local out = {}
    for _, m in ipairs(GetEligibleMembers(nil)) do
        if WhoDoesWhat:IsMarkedTank(m.name) then out[#out + 1] = m.name end
    end
    return out
end

-- Tank Reset: rebuild the rows from the marked tanks with the stock marker
-- layout -- one marker each, skull-first (Skull, Cross, Square, ...) in row
-- order -- with two preferences: a feral (druid) tank leads and takes Skull,
-- and a paladin tank slots third holding "Everything else" (AoE threat keeps
-- the leftovers). Misdirect markers re-sync onto their tanks' fresh markers.
local function ResetTankAssignments()
    if not WhoDoesWhat:RequireEditPermission() then return end
    local ferals, rest, pally = {}, {}, nil
    for _, name in ipairs(MarkedTankNames()) do
        local m = FindMember(name)
        local cls = m and m.classInfo.name
        if cls == "Druid" then
            ferals[#ferals + 1] = name
        elseif cls == "Paladin" and not pally then
            pally = name
        else
            rest[#rest + 1] = name
        end
    end
    local ordered = {}
    for _, n in ipairs(ferals) do ordered[#ordered + 1] = n end
    for _, n in ipairs(rest) do ordered[#ordered + 1] = n end
    if pally then
        table.insert(ordered, math.min(3, #ordered + 1), pally)
    end

    local entries = WhoDoesWhat.db.profile.tankAssignments
    wipe(entries)
    local nextMarker = 1
    for _, name in ipairs(ordered) do
        local markers
        if name == pally then
            markers = { "all" }
        else
            local m = WhoDoesWhat.RaidTargetMarkers[nextMarker]
            nextMarker = nextMarker + 1
            markers = m and { m.index } or {}
        end
        entries[#entries + 1] = { player = name, markers = markers, custom = "" }
    end

    -- Every misdirect follows its tank onto the tank's new first marker.
    local seen = {}
    for _, e in ipairs(WhoDoesWhat.db.profile.mdAssignments) do
        if e.target and not seen[e.target] then
            seen[e.target] = true
            WhoDoesWhat:SyncMisdirectsForTank(e.target)
        end
    end

    if #entries == 0 then
        WhoDoesWhat:Print("Tank Assignments reset: no marked tanks in the group.")
    else
        local parts = {}
        for _, entry in ipairs(entries) do
            parts[#parts + 1] = entry.player .. " -> " .. TargetPlainText(entry)
        end
        WhoDoesWhat:Print("Tank Assignments reset: " .. table.concat(parts, ", ") .. ".")
    end
end

-- Misdirect Reset: wipe every row; the auto-row reconcile rebuilds one blank
-- row per hunter on the next repaint.
local function ResetMisdirectAssignments()
    if not WhoDoesWhat:RequireEditPermission() then return end
    wipe(WhoDoesWhat.db.profile.mdAssignments)
    WhoDoesWhat:Print("Misdirect Assignments reset: one empty row per hunter.")
end

-- ---------------------------------------------------------------------------
-- Dynamic section definitions -- the MODEL vocabulary for the three
-- user-facing row sections. The UI for each is hard-coded in its own file
-- (Views/Sections/TankSection.lua etc.); what lives here is only what the
-- model machinery and the non-window consumers (whispers, pruning, the unit
-- menu's read-only summaries, AssignmentsActions' setters) need:
--
--   key         stable id (SectionByKey) + prefix for global widget names
--   title       section box title, also used in Print lines
--   store       db.profile key holding this section's entry array
--   noun        used in Print lines and the view's popups/tooltips
--   whisperLead text leading the compiled list in the whisper
--   spells      optional spell list; entries get a .spell field (CCSpells id)
--   targetPlayer entries target a group member (entry.target, a player name)
--               instead of a raid marker (misdirects); a row needs its target
--               before it has a whisperable job (EntryHasJob)
--   autoRows    one row per roster member, auto-managed (EnsureAutoRows):
--               roster = autoRoster() when set, else MembersOfClass(autoRows);
--               KeepStray(entry) keeps rows whose player fell out of the
--               roster (so the assignment warns, not vanishes)
--   multiMarker entries hold a markers ARRAY (any mix of 1..8/"all"/"custom")
--               instead of the single .marker field
--   GetWarning(entry)  row warning text, or nil when all is well
-- ---------------------------------------------------------------------------

local DynamicSections = {
    {
        key = "tank",
        title = "Tank Assignments",
        store = "tankAssignments",
        noun = "tank assignment",
        whisperLead = "Tank ",
        -- One row per marked tank, auto-managed; the marker dropdown is a
        -- multi-select so one tank holds all their markers on a single row.
        autoRows = true,
        autoRoster = MarkedTankNames,
        multiMarker = true,
        -- A unit-menu marker put on someone who isn't a marked tank still
        -- deserves a (warning) row rather than being silently reconciled away.
        KeepStray = function(entry)
            return FindMember(entry.player) ~= nil and #(entry.markers or {}) > 0
        end,
        GetWarning = function(entry)
            if entry.player and not WhoDoesWhat:IsMarkedTank(entry.player) then
                return entry.player .. " is not marked as a tank. Assign them a"
                    .. " tank role from the unit right-click menu."
            end
            if #(entry.markers or {}) == 0 then
                return "No marker picked for this tank yet."
            end
        end,
    },
    {
        key = "cc",
        title = "CC Assignments",
        store = "ccAssignments",
        noun = "CC assignment",
        whisperLead = "CC ",
        spells = WhoDoesWhat.CCSpells,
        GetWarning = function(entry)
            local spell = SpellById(entry.spell)
            if not spell then
                return "No spell picked for this assignment yet."
            end
            local m = entry.player and FindMember(entry.player)
            if m and m.classInfo.name ~= spell.class then
                return entry.player .. " is a " .. m.classInfo.name .. " and can't cast "
                    .. spell.name .. ", which is a " .. spell.class .. " ability."
            end
        end,
    },
    {
        key = "md",
        enabled = WhoDoesWhat.ClientFeatures.misdirectAssignments,
        title = "Misdirect Assignments",
        store = "mdAssignments",
        noun = "misdirect assignment",
        whisperLead = "Misdirect to ",
        targetPlayer = true,
        -- One row per hunter, auto-managed from the roster (EnsureAutoRows):
        -- every hunter should have a misdirect every fight, so there's no
        -- manual Add/remove -- you just fill in each hunter's tank.
        autoRows = "Hunter",
        GetWarning = function(entry)
            if entry.player then
                local m = FindMember(entry.player)
                if m and m.classInfo.name ~= "Hunter" then
                    return entry.player .. " is a " .. m.classInfo.name
                        .. " and can't cast Misdirection."
                end
                local count = 0
                for _, e in ipairs(WhoDoesWhat.db.profile.mdAssignments) do
                    if e.player == entry.player then count = count + 1 end
                end
                if count > 1 then
                    return entry.player .. " holds more than one misdirect;"
                        .. " a hunter can only misdirect onto one tank."
                end
            end
            if not entry.target then
                return "No tank picked for this misdirect yet."
            end
            if not WhoDoesWhat:IsMarkedTank(entry.target) then
                return entry.target .. " is not marked as a tank. Assign them a"
                    .. " tank role from the unit right-click menu."
            end
            local markers = WhoDoesWhat:TankMarkers(entry.target)
            if #markers == 0 then
                return entry.target .. " has no marker assigned in Tank"
                    .. " Assignments, so there's nothing to misdirect on."
            end
            if entry.marker then
                local onTankMarker = false
                for _, mk in ipairs(markers) do
                    if mk == entry.marker then onTankMarker = true break end
                end
                if not onTankMarker then
                    local m = MarkerByIndex(entry.marker)
                    return "This misdirect is on " .. (m and m.name or "?")
                        .. ", but " .. entry.target .. " isn't tanking that marker."
                end
            end
        end,
    },
}

-- A dynamic section's definition by its stable key ("tank"/"cc"/"md") --
-- how the view files and AssignmentsActions reach their section's model.
local function SectionByKey(key)
    for _, section in ipairs(DynamicSections) do
        if section.key == key then return section end
    end
end

local function GetEntries(section)
    return WhoDoesWhat.db.profile[section.store]
end

-- One entry rendered for a message: "{skull}" for a tank row, "Polymorph
-- {skull}" for a CC row. TargetFmt picks chat tokens or plain words. A CC row
-- with no spell picked yet just names its target -- the row's warning icon is
-- what nags about the gap, no need to whisper someone a "?".
local function EntryText(section, entry, TargetFmt)
    local target = TargetFmt(entry)
    local spell = section.spells and SpellById(entry.spell)
    return spell and (spell.name .. " " .. target) or target
end

-- Every row this player holds in a section, joined into one list, so each of
-- their mail buttons whispers the whole job rather than one line of it.
local function PlayerEntriesText(section, playerName, TargetFmt)
    local out = {}
    for _, entry in ipairs(GetEntries(section)) do
        if entry.player == playerName then
            out[#out + 1] = EntryText(section, entry, TargetFmt)
        end
    end
    return table.concat(out, ", ")
end

-- ---------------------------------------------------------------------------
-- Section-header mass mail: one button per section box that whispers every
-- assigned player in it their job(s) in one click. Collectors return one
-- { name, msg } per distinct player -- a player holding several rows gets a
-- single whisper listing all of them, matching what their row buttons send.
-- ---------------------------------------------------------------------------

-- Gap between queued whispers: one click can be a dozen SendChatMessage
-- calls, and an instant burst that size risks the server chat throttle.
local MAIL_STAGGER = 0.25

-- Whether a dynamic row is complete enough to whisper: misdirects need their
-- tank picked, multi-marker (tank) rows need at least one marker. Also drives
-- each row's mail-button enabled state in the view.
local function EntryHasJob(section, entry)
    if not entry.player then return false end
    if section.targetPlayer then return entry.target ~= nil end
    if entry.markers then return #entry.markers > 0 end
    return true
end

-- Distinct assigned players in a dynamic section, whispers in chat-token form.
local function CollectDynamicWhispers(section)
    local seen, out = {}, {}
    for _, entry in ipairs(GetEntries(section)) do
        if EntryHasJob(section, entry)
            and not seen[entry.player] then
            seen[entry.player] = true
            out[#out + 1] = {
                name = entry.player,
                msg = section.whisperLead .. PlayerEntriesText(section, entry.player, TargetChatText),
            }
        end
    end
    return out
end

-- Distinct assigned players in a static section, each with their row labels
-- joined ("Salvation, Kings (Paladin Buffs)").
local function CollectStaticWhispers(section)
    local jobs, order = {}, {}
    for _, def in ipairs(section.rows) do
        local name = GetAssignment(def.id)
        if name then
            if not jobs[name] then
                jobs[name] = {}
                order[#order + 1] = name
            end
            local list = jobs[name]
            list[#list + 1] = def.label
        end
    end
    local out = {}
    for _, name in ipairs(order) do
        out[#out + 1] = {
            name = name,
            msg = table.concat(jobs[name], ", ") .. " (" .. section.title .. ")",
        }
    end
    return out
end

-- Send every collected whisper, staggered (see MAIL_STAGGER). Messages are
-- captured at click time; an assignment edited mid-stagger sends the
-- pre-click version.
local function MassWhisper(list)
    for i, w in ipairs(list) do
        local name, msg = w.name, w.msg
        C_Timer.After((i - 1) * MAIL_STAGGER, function()
            SendChatMessage("[WhoDoesWhat] Your assignment: " .. msg .. ".", "WHISPER", nil, name)
        end)
    end
    return #list
end

-- Default marker for a new row: the first (skull-first) marker no other row
-- in this section is using yet; skull again once all eight are taken.
local function FirstUnusedMarker(section)
    for _, m in ipairs(WhoDoesWhat.RaidTargetMarkers) do
        local used = false
        for _, entry in ipairs(GetEntries(section)) do
            if entry.marker == m.index then
                used = true
                break
            end
        end
        if not used then return m.index end
    end
    return 8
end

-- ---------------------------------------------------------------------------
-- Paladin buff talents (scanned by Talents.lua as inspections arrive)
-- ---------------------------------------------------------------------------

-- The talent behind each talent-affected buff. The 1-point talents *grant*
-- their blessing (an untalented paladin can't cast Kings or Sanctuary at
-- all); the multi-rank ones improve a baseline blessing. Salvation and Light
-- have no talent, so any paladin carries them equally well.
local BuffTalents = {
    kings     = { talent = "Blessing of Kings", maxRank = 1 },
    sanctuary = { talent = "Blessing of Sanctuary", maxRank = 1 },
    might     = { talent = "Improved Blessing of Might", maxRank = 5 },
    wisdom    = { talent = "Improved Blessing of Wisdom", maxRank = 2 },
}

-- A player's rank in a buff's talent: 0..max once their talents have been
-- scanned, nil while they haven't (no data is not the same as no talent).
local function BuffTalentRank(playerName, buffKey)
    local t = WhoDoesWhat:GetPaladinBuffTalents(playerName)
    return t and t[buffKey]
end

-- ---------------------------------------------------------------------------
-- Custom paladin-buff rules (db.profile.paladinBuffRules)
--
-- User strategy knobs for the computed blessing coverage, edited in the main
-- window's Paladin Buffs section ("+ Rule"). One rule per buff, six at most:
--
--   { buff, kind = "ignore" }                    the buff drops out of the
--                                                plan entirely (fights where
--                                                nobody wants Salvation)
--   { buff, kind = "prioritize", scope, value }  the buff jumps to the front
--       scope "everyone"                         of matching raiders' buff
--             "wowrole" (value "tank"/"healer"/  priorities -- which also
--                        "dps")                  moves their demand votes
--             "class"   (value "Mage")
--             "role"    (value a role id)
--   { buff, kind = "prefer", value = paladin }   that paladin owns the buff
--                                                as their primary, as a hard
--                                                lock that beats talent ranks
--
-- Local-only config like the role customizations: rules aren't synced and
-- survive group changes. A prefer rule naming an absent (or non-raider)
-- paladin is simply inert until they're back.
-- ---------------------------------------------------------------------------

local function GetBuffRules()
    return WhoDoesWhat.db.profile.paladinBuffRules
end

-- The rules split into the shapes the plan consumes: the ignored-buff set,
-- the prioritize rules in rule order, and the preferred buff per paladin
-- (first rule wins if one paladin is somehow named twice).
local function CompileBuffRules()
    local ignored, prioritized, preferred = {}, {}, {}
    for _, r in ipairs(GetBuffRules()) do
        if r.kind == "ignore" then
            ignored[r.buff] = true
        elseif r.kind == "prioritize" then
            prioritized[#prioritized + 1] = r
        elseif r.kind == "prefer" and r.value then
            if not preferred[r.value] then
                preferred[r.value] = r.buff
            end
        end
    end
    return ignored, prioritized, preferred
end

-- Does a prioritize rule cover this member?
local function RuleMatchesMember(rule, m)
    if rule.scope == "everyone" or not rule.scope then return true end
    if rule.scope == "class" then
        return m.classInfo.name == rule.value
    end
    local roleId = WhoDoesWhat:GetAssignedRole(m.name)
    if rule.scope == "role" then
        return roleId == rule.value
    end
    if rule.scope == "wowrole" then
        if not roleId then return false end
        local _, role = WhoDoesWhat:FindRoleById(roleId)
        return (role and role.wowRole) == rule.value
    end
    return false
end

-- A member's buff priority order with the rules applied: ignored buffs drop
-- out entirely, and prioritized buffs that cover this member move to the
-- front (several matching rules keep their rule order).
local function RuleAdjustedOrder(m, ignored, prioritized)
    local roleId = WhoDoesWhat:GetAssignedRole(m.name)
    local base = (roleId and WhoDoesWhat:GetEffectiveBuffOrder(roleId))
        or WhoDoesWhat.CanonicalBuffOrder
    local allowed
    if roleId then
        allowed = {}
        for _, key in ipairs(base) do allowed[key] = true end
    end

    local order, inOrder = {}, {}
    for _, rule in ipairs(prioritized) do
        if not ignored[rule.buff] and not inOrder[rule.buff]
            and (not allowed or allowed[rule.buff])
            and RuleMatchesMember(rule, m) then
            order[#order + 1] = rule.buff
            inOrder[rule.buff] = true
        end
    end
    for _, key in ipairs(base) do
        if not ignored[key] and not inOrder[key] then
            order[#order + 1] = key
            inOrder[key] = true
        end
    end
    return order
end

-- ---------------------------------------------------------------------------
-- Per-raider buff plan (the buff grid's cells + the main window's paladin
-- summary rows)
--
-- There is no stored per-buff assignment: coverage is derived, fresh on
-- every call, from the roster + roles + talents + the custom rules above,
-- so it can never go stale against them. Every (non-non-raider) paladin
-- takes part.
--
-- Each raider's paladins-to-buffs matching is solved as a whole (a tiny
-- assignment problem over at most 6x6, done exactly by DP over buff subsets)
-- rather than buff-by-buff greedily -- greedy could hand a commodity buff to
-- the Improved Wisdom paladin and leave wisdom, still in the raider's top
-- picks, to a 0-rank leftover. The score is maximal FOR THE RAIDER, in
-- strict tiers:
--
--   1. cover their highest-priority buffs (position value, steep + convex,
--      so it dwarfs everything below and prefers top-heavy coverage),
--   2. from the best-talented casters (rank * 10 -- this is what routes the
--      specialists to their Improved blessings),
--   3. preferring each paladin's computed PRIMARY blessing (+15,
--      ComputePrimaries below) -- the consolidation glue -- with a
--      rank-proof +100 when a prefer rule dictated the pairing.
--
-- A raider's wants are capped at their top-N priorities (N = paladin
-- count), so a paladin with nothing castable that the raider actually wants
-- keeps a nil cell -- visibly unassigned rather than handed the bottom of
-- the raider's list.
--
-- Returns plan[raiderName] = { [paladinName] = buff key }.

-- Each paladin's PRIMARY blessing: the raid-wide greater blessing they'd
-- naturally own, recomputed on the fly and invisible in the UI. It exists to
-- keep the per-raider matching grounded: without it, equal-rank ties resolve
-- per raider and let the same buff bounce between paladins -- Wisdom split
-- across two casters, every paladin juggling 3-4 different blessings. The
-- matcher's stickiness bonus consolidates coverage around one owner per
-- buff; raiders whose priorities skip a paladin's primary still get that
-- paladin's next-best cast, same as before.
--
-- The pick is an exact max-weight assignment of paladins to distinct buffs:
-- each pairing scores demand (which buffs the raid wants) + talentRank*10, so
-- the same solve jointly decides which buffs become primaries AND who owns
-- each. A specialist's talent weight pulls their Improved/granted blessing
-- onto them, which pushes the commodity blessings (Kings, Salvation) onto the
-- non-specialists -- so one paladin owns an entire buff instead of two
-- splitting it (the demand votes still decide which buffs make the cut when
-- there are more buffs than paladins). Gated blessings (Kings/Sanctuary) can
-- only be owned by a talented caster; a slot no free caster can fill is left
-- unmatched.
--
-- Returns primary[paladinName] = buff key, plus forced[paladinName] = buff
-- key for the pairs a prefer rule locked in (they score a bigger stickiness
-- bonus). A paladin misses out only when nothing castable remains for them.
local function ComputePrimaries(pool, ignored, prioritized, preferred)
    local canonical = WhoDoesWhat.CanonicalBuffOrder
    local primary, forced = {}, {}

    -- Rule-ignored buffs are out of the running entirely.
    local avail = {}
    for _, key in ipairs(canonical) do
        if not ignored[key] then avail[#avail + 1] = key end
    end
    local slots = math.min(#pool, #avail)
    if slots == 0 then return primary, forced end

    -- Prefer rules place their pairs first, as hard locks: the paladin's
    -- primary is decided, they leave the pool, the buff leaves the demand
    -- race. Walked in pool order for determinism; two rules can't name one
    -- buff (one rule per buff), and absent paladins never appear in pool.
    local used, lockedBuff = {}, {}
    for _, name in ipairs(pool) do
        local buff = preferred[name]
        if buff and not ignored[buff] and not lockedBuff[buff] then
            primary[name] = buff
            forced[name] = buff
            used[name] = true
            lockedBuff[buff] = true
        end
    end

    -- Demand votes: each raider's top `slots` wanted buffs, rule-adjusted.
    local votes = {}
    for _, key in ipairs(avail) do votes[key] = 0 end
    for _, m in ipairs(GetEligibleMembers(nil)) do
        if not WhoDoesWhat:IsNonRaider(m.name) then
            local order = RuleAdjustedOrder(m, ignored, prioritized)
            for i = 1, math.min(slots, #order) do
                votes[order[i]] = votes[order[i]] + 1
            end
        end
    end
    -- Every hunter's pet votes too (Might, Kings): pet demand shapes the
    -- primaries without anyone assigning anything.
    for _ in ipairs(GetPetMembers()) do
        local order = PetBuffOrder(ignored)
        for i = 1, math.min(slots, #order) do
            votes[order[i]] = votes[order[i]] + 1
        end
    end

    -- Free casters and still-available buffs after the prefer-rule locks.
    local freeCasters = {}
    for _, name in ipairs(pool) do
        if not used[name] then freeCasters[#freeCasters + 1] = name end
    end
    local freeBuffs = {}
    for _, key in ipairs(avail) do
        if not lockedBuff[key] then freeBuffs[#freeBuffs + 1] = key end
    end

    local function Gated(key)
        local meta = BuffTalents[key]
        return meta ~= nil and meta.maxRank == 1
    end

    -- Weight of pairing a paladin with a buff, or nil if infeasible. A small
    -- base (so filling a slot always beats leaving it empty) + demand (which
    -- buffs the raid wants) + talentRank*10 (routes each specialist onto their
    -- Improved/granted blessing). Gated blessings are only feasible for a
    -- talented caster.
    local function Weight(name, key)
        if Gated(key) and (BuffTalentRank(name, key) or 0) == 0 then
            return nil
        end
        return 1 + votes[key] + (BuffTalentRank(name, key) or 0) * 10
    end

    -- Exact max-weight assignment of the free paladins to distinct free buffs,
    -- solved by DP over the set of buff indices already handed out (bitmask).
    -- Maximizing total weight jointly chooses WHICH buffs become primaries and
    -- WHO owns each: the specialist's talent weight pulls their Improved buff
    -- into the set and onto them, so the commodity blessings consolidate onto
    -- the non-specialists (one pally owns every Kings while another runs the
    -- Wis/Might split). A slot no free caster can fill (a gated buff with no
    -- talented caster) is left unmatched -- the old forfeit-to-next backfill.
    -- Masks are walked numerically for a deterministic, refresh-stable pick.
    local nb = #freeBuffs
    local full = bit.lshift(1, nb)
    local dp = { [0] = { score = 0, picks = {} } }
    for c = 1, #freeCasters do
        local name = freeCasters[c]
        local ndp = {}
        for mask = 0, full - 1 do
            local st = dp[mask]
            if st then
                -- This caster owns no primary.
                local cur = ndp[mask]
                if not cur or st.score > cur.score then ndp[mask] = st end
                -- Or takes one still-free buff they can cast.
                for j = 1, nb do
                    local jbit = bit.lshift(1, j - 1)
                    if bit.band(mask, jbit) == 0 then
                        local w = Weight(name, freeBuffs[j])
                        if w then
                            local score = st.score + w
                            local nmask = mask + jbit
                            local prev = ndp[nmask]
                            if not prev or score > prev.score then
                                local picks = {}
                                for cc, jj in pairs(st.picks) do picks[cc] = jj end
                                picks[c] = j
                                ndp[nmask] = { score = score, picks = picks }
                            end
                        end
                    end
                end
            end
        end
        dp = ndp
    end

    local best
    for mask = 0, full - 1 do
        local st = dp[mask]
        if st and (not best or st.score > best.score) then best = st end
    end
    for c, j in pairs(best.picks) do
        primary[freeCasters[c]] = freeBuffs[j]
    end
    return primary, forced
end

-- Position values for a raider's 1st..6th buff priority: (7-i)^2 * 1000.
-- Squared so covering { 1st, 4th } beats { 2nd, 3rd } when feasibility forces
-- a choice; the *1000 keeps every rank/stickiness sum (< 1000) from ever
-- outvoting a position step.
local GRID_POS_VALUE = {}
for i = 1, 6 do GRID_POS_VALUE[i] = (7 - i) * (7 - i) * 1000 end

local function ComputeBuffGrid()
    local ignored, prioritized, preferred = CompileBuffRules()
    local pool = MembersOfClass("Paladin") -- sorted names
    local primary, forced = ComputePrimaries(pool, ignored, prioritized, preferred)

    -- Talent-granted blessings need the talent; unscanned counts as can't.
    local function CanCast(name, key)
        local meta = BuffTalents[key]
        if meta and meta.maxRank == 1 then
            return (BuffTalentRank(name, key) or 0) > 0
        end
        return true
    end

    -- One raider's cells, matched exactly by DP: process the pool paladin by
    -- paladin; a state is the set of order positions already given out
    -- (bitmask, order is always the full 6 buffs) with the best score
    -- reaching it and the picks that did. Each paladin either sits out (mask
    -- unchanged) or takes one free position they can cast. Masks are walked
    -- numerically so equal-score ties resolve the same way every refresh.
    local function SolveRaider(order)
        local dp = { [0] = { score = 0, picks = {} } }
        for p = 1, #pool do
            local name = pool[p]
            local ndp = {}
            for mask = 0, 63 do
                local st = dp[mask]
                if st then
                    -- This paladin gives this raider nothing.
                    local cur = ndp[mask]
                    if not cur or st.score > cur.score then
                        ndp[mask] = st
                    end
                    for i = 1, #order do
                        local ibit = bit.lshift(1, i - 1)
                        local key = order[i]
                        if bit.band(mask, ibit) == 0 and CanCast(name, key) then
                            -- The +15 primary stickiness outweighs one talent
                            -- rank but not two: near-ties consolidate on the
                            -- primary owner, real rank gaps still win. A
                            -- prefer-rule pair scores +100 instead -- past
                            -- any possible rank gap (max 50), so the user's
                            -- pick holds; position values still dominate, so
                            -- nobody is force-fed a buff they don't want.
                            local score = st.score + GRID_POS_VALUE[i]
                                + (BuffTalentRank(name, key) or 0) * 10
                                + (forced[name] == key and 100
                                    or primary[name] == key and 15 or 0)
                            local nmask = mask + ibit
                            local prev = ndp[nmask]
                            if not prev or score > prev.score then
                                local picks = {}
                                for pp, ii in pairs(st.picks) do picks[pp] = ii end
                                picks[p] = i
                                ndp[nmask] = { score = score, picks = picks }
                            end
                        end
                    end
                end
            end
            dp = ndp
        end

        local best
        for mask = 0, 63 do
            local st = dp[mask]
            if st and (not best or st.score > best.score) then
                best = st
            end
        end

        local cells = {}
        for p, i in pairs(best.picks) do
            cells[pool[p]] = order[i]
        end
        return cells
    end

    local plan = {}
    for _, m in ipairs(GetEligibleMembers(nil)) do
        -- Non-raiders get no plan entry at all (and no grid row).
        if not WhoDoesWhat:IsNonRaider(m.name) then
            local order = RuleAdjustedOrder(m, ignored, prioritized)
            -- A raider only wants as many buffs as there are paladins: trim
            -- to their top-N priorities. Without this, one uncastable want
            -- (Sanctuary with its only holder busy on Kings) made the
            -- matcher reach to the BOTTOM of the list -- Might on every
            -- caster. An empty cell beats a blessing their role ranked
            -- last; the deep slots only come into play with enough paladins
            -- to genuinely reach them.
            while #order > #pool do
                order[#order] = nil
            end
            plan[m.name] = SolveRaider(order)
        end
    end

    -- Each hunter's pet rides along as a virtual raider under the same exact
    -- matching, wanting only the pet order. A pet is its OWN blessing target
    -- (the owner's class-wide Greater Blessing never reaches it), so these
    -- cells show which paladin should single-buff each pet; the PallyPower
    -- bridge pushes them as per-pet Normal blessings.
    for _, pet in ipairs(GetPetMembers()) do
        local order = PetBuffOrder(ignored)
        while #order > #pool do
            order[#order] = nil
        end
        plan[pet.name] = SolveRaider(order)
    end
    return plan
end

-- The plan aggregated per paladin: how many raiders each paladin blesses
-- with each buff. Returns an array of
--   { name, total, buffs = { { key, count }, ... } }
-- with each paladin's buffs count-descending (ties in canonical order) and
-- the paladins themselves total-descending (ties by name). Drives the main
-- window's Paladin Buffs rows and that section's whispers.
local function ComputePaladinBuffSummary()
    local canonical = WhoDoesWhat.CanonicalBuffOrder
    local canonIndex = {}
    for i, key in ipairs(canonical) do canonIndex[key] = i end

    local counts, names = {}, {}
    for _, name in ipairs(MembersOfClass("Paladin")) do
        counts[name] = {}
        names[#names + 1] = name
    end
    for _, cells in pairs(ComputeBuffGrid()) do
        for paladin, key in pairs(cells) do
            local c = counts[paladin]
            if c then c[key] = (c[key] or 0) + 1 end
        end
    end

    local out = {}
    for _, name in ipairs(names) do
        local buffs, total = {}, 0
        for key, n in pairs(counts[name]) do
            buffs[#buffs + 1] = { key = key, count = n }
            total = total + n
        end
        table.sort(buffs, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return canonIndex[a.key] < canonIndex[b.key]
        end)
        out[#out + 1] = { name = name, total = total, buffs = buffs }
    end
    table.sort(out, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return a.name < b.name
    end)
    return out
end

-- Header-mail collector for the Paladin Buffs section: each paladin gets
-- their computed workload in one line ("Blessings: Might x12, Kings x3").
local function CollectPaladinBuffWhispers()
    local out = {}
    for _, p in ipairs(ComputePaladinBuffSummary()) do
        if #p.buffs > 0 then
            local parts = {}
            for _, b in ipairs(p.buffs) do
                parts[#parts + 1] = WhoDoesWhat.PaladinBuffs[b.key].name_long
                    .. " x" .. b.count
            end
            out[#out + 1] = {
                name = p.name,
                msg = "Blessings: " .. table.concat(parts, ", "),
            }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Static assignment definitions
--
--   Row definition fields:
--     id            key into db.profile.raidAssignments (-> player name)
--     icon/label    row visuals (icon may be a texture path or FileDataID)
--     spellId       ability hover tooltip over the icon
--     class         eligible class for the dropdown ("Paladin"); the
--                   Developer Mode setting lifts the filter to everyone
--     preferRoleId  members holding this WDW role (db.profile.assignments)
--                   float to the top of the dropdown above a divider
--     IsPreferred(m) same float, as a predicate (wins over preferRoleId)
--     Annotate(m)   optional gray note after a member's name in the menu
--     exclusiveWith row ids the picked player is bumped from (one warlock
--                   can't cover both curses)
--     pairWith      row id that auto-fills with the same player while it's
--                   still unassigned
--     GetWarning()  returns warning-tooltip text when the assignment needs
--                   attention, nil when all is well; drives the (!) icon
--
--   Section fields are just { title, rows }: the model's iteration surface
--   for whispers, pruning and the unit menu's read-only summaries. Each
--   section's window UI (header buttons, computed paladin rows, gray-out
--   rules) is hard-coded in its Views/Sections/*.lua file.
-- ---------------------------------------------------------------------------

local RowDefs = {} -- row id -> definition, for cross-row lookups
local Sections     -- ordered { title, rows } section list
local AutoAssignWarlockCurses -- defined below, exported for the view's Auto button

do
    local curses = WhoDoesWhat.WarlockCurses
    local reck = {
        id = "curse_reck",
        icon = curses.reck.icon,
        label = curses.reck.name_long,
        spellId = curses.reck.spellId,
        class = "Warlock",
        exclusiveWith = { "curse_elements" },
        GetWarning = function()
            if not GetAssignment("curse_reck") then
                return "No one is assigned to Curse of Recklessness."
            end
        end,
    }
    local elements = {
        id = "curse_elements",
        icon = curses.elements.icon,
        label = curses.elements.name_long,
        spellId = curses.elements.spellId,
        class = "Warlock",
        preferRoleId = "warlock_affl",
        exclusiveWith = { "curse_reck" },
        GetWarning = function()
            local name = GetAssignment("curse_elements")
            if not name then
                return "No one is assigned to Curse of the Elements."
            end
            if WhoDoesWhat:GetAssignedRole(name) ~= "warlock_affl" then
                return name .. " is not marked as Affliction. Without Malediction,"
                    .. " Curse of the Elements is less effective."
            end
        end,
    }
    RowDefs[reck.id] = reck
    RowDefs[elements.id] = elements

    -- Curses: Elements first (the bigger raid gain), ideally on an
    -- Affliction warlock for Malediction; Recklessness goes to any other
    -- warlock, and stays empty with only one warlock in the group. The two
    -- Settings toggles gate each curse independently -- Elements on the
    -- Affliction-to-Elements setting, Recklessness on its (it raises boss
    -- damage, so a leader may keep it off). An off toggle leaves that curse's
    -- current pick untouched rather than clearing it.
    function AutoAssignWarlockCurses() -- file-local, forward-declared above
        local settings = WhoDoesWhat.db.profile.settings
        local locks = MembersOfClass("Warlock")
        if #locks == 0 then
            WhoDoesWhat:Print("Warlock Curses: no warlocks in the group to auto-assign.")
            return
        end

        local store = WhoDoesWhat.db.profile.raidAssignments

        local elementsLock = store.curse_elements
        if settings.autoAssignAfflictionElements then
            elementsLock = nil
            for _, name in ipairs(locks) do
                if WhoDoesWhat:GetAssignedRole(name) == "warlock_affl" then
                    elementsLock = name
                    break
                end
            end
            elementsLock = elementsLock or locks[1]
            store.curse_elements = elementsLock
        end

        local reckLock
        if settings.allowRecklessnessAutoAssign then
            for _, name in ipairs(locks) do
                if name ~= elementsLock then
                    reckLock = name
                    break
                end
            end
            store.curse_reck = reckLock
        end

        local parts = {}
        if settings.autoAssignAfflictionElements then
            parts[#parts + 1] = elements.label .. " -> " .. (elementsLock or "nobody")
        end
        if settings.allowRecklessnessAutoAssign then
            parts[#parts + 1] = reck.label .. " -> " .. (reckLock or "nobody (no second warlock)")
        end
        if #parts == 0 then
            WhoDoesWhat:Print("Warlock Curses: both curse auto-assigns are disabled in Settings.")
        else
            WhoDoesWhat:Print("Warlock Curses auto-assigned: " .. table.concat(parts, ", ") .. ".")
        end
    end

    Sections = {
        -- Paladin blessings aren't assigned -- coverage is computed from the
        -- roster, roles and talents (ComputeBuffGrid), and the section view
        -- shows the result as read-only rows. rows stays empty here.
        { title = "Paladin Buffs", rows = {} },
        { title = "Warlocks", rows = { reck, elements } },
    }
end

-- Named whisper collectors, one per section, so the section views (and any
-- future section) mail through a self-documenting call instead of passing
-- defs around. All are thin wrappers over the two generic collectors above.
local function CollectTankWhispers() return CollectDynamicWhispers(SectionByKey("tank")) end
local function CollectCCWhispers() return CollectDynamicWhispers(SectionByKey("cc")) end
local function CollectMisdirectWhispers() return CollectDynamicWhispers(SectionByKey("md")) end
local function CollectCurseWhispers() return CollectStaticWhispers(Sections[2]) end

-- Drop assignments whose player is no longer in the group. Run when the
-- window opens, so a re-formed raid starts from an honest board. Dynamic rows
-- keep their marker and spell; only the departed player is cleared. Skipped
-- without edit permission: a read-only client shouldn't mutate the shared
-- board at all, even housekeeping -- the editors prune and sync it over.
local function PruneDepartedAssignments()
    if not WhoDoesWhat:CanEditAssignments() then return end
    local present = {}
    for _, m in ipairs(GetEligibleMembers(nil)) do
        present[m.name] = true
    end

    local store = WhoDoesWhat.db.profile.raidAssignments
    for id, name in pairs(store) do
        if not present[name] then
            store[id] = nil
            local label = RowDefs[id] and RowDefs[id].label or id
            WhoDoesWhat:Print(label .. " unassigned: " .. name .. " is no longer in the group.")
        end
    end

    for _, section in ipairs(DynamicSections) do
        for _, entry in ipairs(GetEntries(section)) do
            if entry.player and not present[entry.player] then
                WhoDoesWhat:Print(section.title .. " (" .. EntryText(section, entry, TargetPlainText)
                    .. ") unassigned: " .. entry.player .. " is no longer in the group.")
                entry.player = nil
            end
            -- Player targets (a misdirect's tank) leave the group too.
            if entry.target and not present[entry.target] then
                WhoDoesWhat:Print(section.title .. " target cleared: " .. entry.target
                    .. " is no longer in the group.")
                entry.target = nil
            end
        end
    end
end

-- Auto-row sections carry one row per roster member (misdirects: every
-- hunter; tanks: every marked tank), not rows the user adds by hand.
-- Reconcile the saved entries to the roster before rendering: retained rows
-- keep their current order (assignments preserved), new members append a
-- blank row in roster order, rows whose player left the roster drop -- unless
-- the section's KeepStray predicate holds onto them (a unit-menu marker on
-- someone not marked tank warns instead of silently vanishing). Skipped for
-- read-only clients -- they render the leader's synced rows as-is (matching
-- PruneDepartedAssignments).
local function EnsureAutoRows(section)
    if not WhoDoesWhat:CanEditAssignments() then return end
    local entries = GetEntries(section)
    local roster = section.autoRoster and section.autoRoster()
        or MembersOfClass(section.autoRows)
    local inRoster = {}
    for _, name in ipairs(roster) do inRoster[name] = true end

    local rebuilt, seen = {}, {}
    for _, e in ipairs(entries) do
        if e.player and inRoster[e.player] and not seen[e.player] then
            seen[e.player] = true
            rebuilt[#rebuilt + 1] = e
        elseif e.player and not inRoster[e.player]
            and section.KeepStray and section.KeepStray(e) then
            rebuilt[#rebuilt + 1] = e
        end
    end
    for _, name in ipairs(roster) do
        if not seen[name] then
            rebuilt[#rebuilt + 1] = section.multiMarker
                and { player = name, markers = {}, custom = "" }
                or { player = name }
        end
    end

    -- Only rewrite the store when the set/order actually changed, so an
    -- unchanged roster doesn't churn the sync fingerprint every refresh.
    local changed = (#rebuilt ~= #entries)
    for i = 1, #rebuilt do
        if rebuilt[i] ~= entries[i] then changed = true break end
    end
    if changed then
        wipe(entries)
        for _, e in ipairs(rebuilt) do entries[#entries + 1] = e end
    end
end

-- Persist a static assignment (nil clears it), enforce exclusivity (picking
-- a player bumps them off any exclusiveWith rows), and repaint. Permission-
-- gated like every board write (the read-only UI hides the way here, this
-- backstops anything that slips through).
local function SetAssignment(rowId, playerName)
    if not WhoDoesWhat:RequireEditPermission() then return end
    local store = WhoDoesWhat.db.profile.raidAssignments
    local def = RowDefs[rowId]
    store[rowId] = playerName

    if playerName then
        WhoDoesWhat:Print(def.label .. " assigned to " .. playerName .. ".")
        for _, otherId in ipairs(def.exclusiveWith or {}) do
            if store[otherId] == playerName then
                store[otherId] = nil
                WhoDoesWhat:Print(playerName .. " removed from " .. RowDefs[otherId].label .. ".")
            end
        end
        if def.pairWith and not store[def.pairWith] then
            store[def.pairWith] = playerName
            WhoDoesWhat:Print(RowDefs[def.pairWith].label .. " also assigned to " .. playerName .. ".")
        end
    else
        WhoDoesWhat:Print(def.label .. " assignment cleared.")
    end

    WhoDoesWhat:RefreshMainAssignmentsView()
    -- The info + grid window mirrors the paladin-buff picks; keep it live.
    WhoDoesWhat:RefreshPaladinBuffGridView()
end

-- When a warlock is detected (or respecs) into Affliction, hand them Curse of
-- the Elements so Malediction lands without anyone touching the board -- but
-- only when the setting is on, only with a second warlock present (so
-- Recklessness still has a caster), and only when Elements isn't already on an
-- Affliction warlock. Called from AutoAssignDetectedRole (TalentScanning.lua)
-- after the role is saved. Returns true if it moved the assignment.
local function AutoPlaceAfflictionElements(playerName)
    if not WhoDoesWhat.db.profile.settings.autoAssignAfflictionElements then return false end
    if #MembersOfClass("Warlock") < 2 then return false end

    local store = WhoDoesWhat.db.profile.raidAssignments
    local current = store.curse_elements
    if current and WhoDoesWhat:GetAssignedRole(current) == "warlock_affl" then
        return false -- an Affliction warlock already holds Elements
    end

    store.curse_elements = playerName
    -- Elements and Recklessness are exclusive; don't double-book this warlock.
    if store.curse_reck == playerName then
        store.curse_reck = nil
    end
    WhoDoesWhat:Print("Curse of the Elements auto-assigned to " .. playerName
        .. " (detected Affliction).")
    return true
end

-- ownerName -> { name = realPetName, unit = petUnit } for live hunter pets
-- (the same resolution the PallyPower bridge uses). Fake hunters have no real
-- pet unit and are absent here.
local function GetPetUnitInfo()
    local owners = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do owners[#owners + 1] = { "raid" .. i, "raidpet" .. i } end
    else
        owners[#owners + 1] = { "player", "pet" }
        for i = 1, GetNumSubgroupMembers() do owners[#owners + 1] = { "party" .. i, "partypet" .. i } end
    end
    local out = {}
    for _, u in ipairs(owners) do
        if UnitExists(u[2]) then
            local owner, pname = GetUnitName(u[1], true), GetUnitName(u[2], true)
            if owner and pname then out[owner] = { name = pname, unit = u[2] } end
        end
    end
    return out
end

-- One paladin's buffing jobs, grouped per CLASS -- the model behind the
-- Paladin Buffing Bar (Views/PaladinBuffingBarView.lua). Reads the same
-- per-raider grid as the PallyPower bridge and collapses it the same way, with
-- no dependency on PallyPower: within each class this paladin buffs, the
-- majority blessing is the class Greater (one cast buffs the whole class) and
-- the dissenters are per-player Normal exceptions.
--
-- Hunter pets bucket under WARRIORS to match the client, but every pet cell is
-- a separate 10-minute Normal blessing in the right-click cycle. The Warrior
-- button appears for pets even with no warriors present.
--
-- Returns an array of per-class jobs (class-name sorted). Each member (raider
-- or pet) carries display name, buff key, live state, and -- for pets -- the
-- pet unit token to cast on:
--   { classInfo, greaterKey, greaterBuff, hasPets, hasNonPets,
--     normals  = { { name, key, buff, isPet, petUnit }, ... },  -- right-click
--     raiders  = { { name, key, has, isPet, petUnit }, ... },   -- count/range/left
--     total, covered }
local function GetPaladinBuffJobs(paladinName)
    local canonical = WhoDoesWhat.CanonicalBuffOrder
    local canonIndex = {}
    for i, key in ipairs(canonical) do canonIndex[key] = i end

    local classOf = {}
    for _, m in ipairs(WhoDoesWhat:GetGroupMembers(nil)) do
        classOf[m.name] = m.classInfo
    end

    local plan = ComputeBuffGrid()
    -- className -> { classInfo, members = {...}, hasPets, hasNonPets }
    local byClass = {}
    local function bucket(ci)
        local c = byClass[ci.name]
        if not c then c = { classInfo = ci, members = {} }; byClass[ci.name] = c end
        return c
    end

    -- Real raiders in their own class.
    for raider, cells in pairs(plan) do
        local key, ci = cells[paladinName], classOf[raider]
        if key and ci then
            local c = bucket(ci)
            c.members[#c.members + 1] = { statusName = raider, display = raider, key = key }
            c.hasNonPets = true
        end
    end

    -- Hunter pets share PallyPower's Warrior bucket but remain individual
    -- Normal-blessing targets.
    local warriorCI = GetClassInfoByToken("WARRIOR")
    if warriorCI then
        local petInfo = GetPetUnitInfo()
        for _, pet in ipairs(GetPetMembers()) do
            local key = plan[pet.name] and plan[pet.name][paladinName]
            if key then
                local c = bucket(warriorCI)
                local info = petInfo[pet.owner]
                c.members[#c.members + 1] = {
                    statusName = pet.name, -- BuffTracking key: "<Owner>'s Pet"
                    display = (info and info.name) or pet.name,
                    key = key, isPet = true, owner = pet.owner,
                    petUnit = info and info.unit,
                }
                c.hasPets = true
            end
        end
    end

    local jobs = {}
    for _, c in pairs(byClass) do
        -- The class Greater = majority blessing; ties break canonical. Real
        -- members decide it (pets don't vote for the Warrior Greater), falling
        -- back to the pets for a pets-only bucket (no warriors present).
        local anyReal = false
        for _, m in ipairs(c.members) do
            if not m.isPet then anyReal = true; break end
        end
        local tally = {}
        for _, m in ipairs(c.members) do
            if (not m.isPet) or (not anyReal) then
                tally[m.key] = (tally[m.key] or 0) + 1
            end
        end
        local greaterKey, bestN
        for key, count in pairs(tally) do
            if not greaterKey or count > bestN
                or (count == bestN and (canonIndex[key] or 99) < (canonIndex[greaterKey] or 99)) then
                greaterKey, bestN = key, count
            end
        end

        local job = {
            classInfo = c.classInfo,
            greaterKey = greaterKey,
            greaterBuff = WhoDoesWhat.PaladinBuffs[greaterKey],
            normals = {},
            raiders = {},
            total = 0, covered = 0,
            hasPets = c.hasPets or false,
            hasNonPets = c.hasNonPets or false,
        }
        for _, m in ipairs(c.members) do
            local has = WhoDoesWhat:HasBuff(m.statusName, m.key)
            job.raiders[#job.raiders + 1] = {
                name = m.display, key = m.key, has = has,
                isPet = m.isPet, petUnit = m.petUnit,
            }
            job.total = job.total + 1
            if has == true then job.covered = job.covered + 1 end
            if m.isPet or m.key ~= greaterKey then
                job.normals[#job.normals + 1] = {
                    name = m.display, key = m.key, buff = WhoDoesWhat.PaladinBuffs[m.key],
                    isPet = m.isPet, petUnit = m.petUnit,
                }
            end
        end
        table.sort(job.normals, function(a, b)
            if a.key ~= b.key then
                return (canonIndex[a.key] or 99) < (canonIndex[b.key] or 99)
            end
            return a.name < b.name
        end)
        jobs[#jobs + 1] = job
    end

    table.sort(jobs, function(a, b) return a.classInfo.name < b.classInfo.name end)
    return jobs
end

-- ---------------------------------------------------------------------------
-- Exports: the shared vocabulary the view and the unit-menu API re-localize.
-- ---------------------------------------------------------------------------

WhoDoesWhat.Assign = {
    -- group members / text
    DevMode = DevMode,
    GetEligibleMembers = GetEligibleMembers,
    FindMember = FindMember,
    MembersOfClass = MembersOfClass,
    GetPetMembers = GetPetMembers,
    PlayerText = PlayerText,
    PlayerTextWithRole = PlayerTextWithRole,
    RoleIconMarkup = RoleIconMarkup,
    GetAssignment = GetAssignment,
    -- marker / spell / target
    MarkerMarkup = MarkerMarkup,
    MarkerByIndex = MarkerByIndex,
    NormalizeMarkers = NormalizeMarkers,
    HasMarkerValue = HasMarkerValue,
    MarkerValuePlain = MarkerValuePlain,
    MarkersRichText = MarkersRichText,
    TargetText = TargetText,
    TargetPlainText = TargetPlainText,
    TargetChatText = TargetChatText,
    SpellText = SpellText,
    SpellById = SpellById,
    SpellsForEntry = SpellsForEntry,
    ClearSpellIfUncastable = ClearSpellIfUncastable,
    -- sections + entries
    DynamicSections = DynamicSections,
    SectionByKey = SectionByKey,
    Sections = Sections,
    RowDefs = RowDefs,
    GetEntries = GetEntries,
    EntryText = EntryText,
    EntryHasJob = EntryHasJob,
    PlayerEntriesText = PlayerEntriesText,
    FirstUnusedMarker = FirstUnusedMarker,
    -- whispers (generic collectors kept for future sections)
    CollectDynamicWhispers = CollectDynamicWhispers,
    CollectStaticWhispers = CollectStaticWhispers,
    CollectTankWhispers = CollectTankWhispers,
    CollectCCWhispers = CollectCCWhispers,
    CollectMisdirectWhispers = CollectMisdirectWhispers,
    CollectCurseWhispers = CollectCurseWhispers,
    MassWhisper = MassWhisper,
    -- section resets / auto-assigns (the views' header buttons)
    ResetTankAssignments = ResetTankAssignments,
    ResetMisdirectAssignments = ResetMisdirectAssignments,
    AutoAssignWarlockCurses = AutoAssignWarlockCurses,
    -- per-raider buff plan + per-paladin summary + custom rules
    BuffTalents = BuffTalents,
    ComputeBuffGrid = ComputeBuffGrid,
    ComputePaladinBuffSummary = ComputePaladinBuffSummary,
    GetPaladinBuffJobs = GetPaladinBuffJobs,
    CollectPaladinBuffWhispers = CollectPaladinBuffWhispers,
    GetBuffRules = GetBuffRules,
    -- storage
    PruneDepartedAssignments = PruneDepartedAssignments,
    EnsureAutoRows = EnsureAutoRows,
    SetAssignment = SetAssignment,
    AutoPlaceAfflictionElements = AutoPlaceAfflictionElements,
}
