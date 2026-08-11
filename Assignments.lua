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
                members[#members + 1] = { name = fm.name, classInfo = classInfo, isFake = true }
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
-- is derived automatically. Keyed as "<Hunter>'s Pet" (real character names
-- can't contain an apostrophe, so the keys can't collide with a raider). The
-- key is never shown as-is: WhoDoesWhat:DisplayName turns it into the pet's
-- real name with its owner behind it (Core.lua). Entries
-- carry owner + isPet for the buff grid view and the PallyPower bridge.
--
-- `allClasses` widens it to every class's pet, for the checks that are about
-- what an effect landed on rather than what a paladin was asked to cast: a
-- shadowfiend or a felhunter takes Bloodlust like anyone else. Only pets that
-- actually exist survive -- the callers drop the ones BuffTracking has never
-- seen -- so a priest with no fiend out contributes nothing.
local function GetPetMembers(allClasses)
    local out = {}
    for _, m in ipairs(GetEligibleMembers(allClasses and nil or "Hunter")) do
        if (allClasses or m.classInfo.name == "Hunter")
            and not WhoDoesWhat:IsNonRaider(m.name) then
            out[#out + 1] = {
                name = m.name .. "'s Pet",
                owner = m.name,
                classInfo = m.classInfo,
                isPet = true,
                isFake = m.isFake,
            }
        end
    end
    return out
end

-- What a pet wants and nothing more: the Data.lua pet order, minus any
-- rule-ignored buff. Deliberately NOT backfilled to all six -- a pet whose
-- top-ups are covered shows an empty grid cell rather than collecting
-- Salvation from an otherwise-idle paladin.
local function PetBuffOrder(ignored)
    local order = {}
    for _, key in ipairs(WhoDoesWhat.HunterPetBuffOrder) do
        if not ignored[key] then
            order[#order + 1] = key
        end
    end
    return order
end

-- Dropdown display text for an assignment: class-colored name while the
-- player is in the group, gray name once they've left, gray "Unassigned"
-- when nothing is saved.
-- `label` overrides the shown text while the color still comes from `name`'s
-- class -- for the rows that want a realm-tag-free name without losing the
-- lookup key.
local function PlayerText(name, label)
    if not name then
        return "|cff909090Unassigned|r"
    end
    label = label or name
    local m = FindMember(name)
    if m then
        return "|cff" .. m.classInfo.colorHex .. label .. "|r"
    end
    return "|cff909090" .. label .. "|r"
end

-- Role-icon markup for a player's assigned spec, or "" when they're roleless
-- or the saved id no longer resolves. Trailing space so it prefixes cleanly.
local function RoleIconMarkup(name, size)
    if not name then return "" end
    local roleId = WhoDoesWhat:GetAssignedRole(name)
    if not roleId then return "" end
    local _, role = WhoDoesWhat:FindRoleById(roleId)
    if not role or not role.icon then return "" end
    return WhoDoesWhat:RoleIconMarkup(role.icon, size or 14) .. " "
end

-- PlayerText with the player's role icon in front (assignment dropdowns). Falls
-- back to plain PlayerText when there's no name or no resolvable role.
local function PlayerTextWithRole(name, size, label)
    return RoleIconMarkup(name, size) .. PlayerText(name, label)
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
local function MarkersRichText(entry, iconSize)
    if #(entry.markers or {}) == 0 then return "|cff909090--|r" end
    iconSize = iconSize or 14
    local parts = {}
    for _, v in ipairs(entry.markers) do
        if v == "custom" then
            parts[#parts + 1] = (entry.custom and entry.custom ~= "") and entry.custom
                or ("|T" .. CUSTOM_TARGET_ICON .. ":" .. iconSize .. ":" .. iconSize
                    .. ":0:0|t Custom")
        elseif type(v) == "number" then
            parts[#parts + 1] = MarkerMarkup(v, iconSize)
        else
            parts[#parts + 1] = MarkerValueText(v)
        end
    end
    return table.concat(parts, ", ")
end

-- Target text in plain words, for our own operation-log output and tooltips.
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
-- this is name-sorted too). Drives the tank section's auto rows.
local function MarkedTankNames()
    local out = {}
    for _, m in ipairs(GetEligibleMembers(nil)) do
        if WhoDoesWhat:IsMarkedTank(m.name) then out[#out + 1] = m.name end
    end
    return out
end

-- Clear every tank assignment. The caller's model reconciliation repopulates
-- marked tanks with empty marker dropdowns; misdirects keep their tanks but
-- lose the now-invalid inherited markers.
local function ClearTankAssignments()
    if not WhoDoesWhat:RequireEditPermission() then return end
    wipe(WhoDoesWhat.db.profile.tankAssignments)
    for _, e in ipairs(WhoDoesWhat.db.profile.mdAssignments) do
        e.marker = nil
    end
    WhoDoesWhat:LogOperation("Tank Assignments cleared.")
end

-- Misdirect clear: wipe every row. The caller's model reconciliation rebuilds
-- one blank row per hunter.
local function ClearMisdirectAssignments()
    if not WhoDoesWhat:RequireEditPermission() then return end
    wipe(WhoDoesWhat.db.profile.mdAssignments)
    WhoDoesWhat:LogOperation("Misdirect Assignments cleared.")
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
        local text = "[WhoDoesWhat] "
            .. (w.bare and "" or "Your assignment: ") .. msg .. "."
        C_Timer.After((i - 1) * MAIL_STAGGER, function()
            SendChatMessage(text, "WHISPER", nil, name)
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
-- User strategy knobs for the computed blessing coverage. Rules are WRITTEN
-- WHOLE from the main window's Buffing Rules > "Add (+)" pop-out and are
-- immutable afterwards -- to change one, delete it and add it again -- so
-- every rule in the table is fully specified and no half-configured rule can
-- sit in the plan:
--
--   { buff = "salv", kind = "ignore" }           Salvation drops out of the
--                                                plan entirely (fights where
--                                                nobody wants it). Salvation
--                                                only: the other five are
--                                                always worth casting, and a
--                                                buff nobody wants is already
--                                                handled by role buff orders.
--
--   { buff, kind = "assign", value = paladin,    that paladin owns the buff as
--     only }                                     their primary, as a hard lock
--                                                that beats talent ranks. With
--                                                only = true they cast THAT
--                                                BLESSING AND NOTHING ELSE and
--                                                sit out the per-raider
--                                                matching -- the shape for a
--                                                paladin running neither WDW
--                                                nor PallyPower, who can't see
--                                                a per-class board and just
--                                                needs one job. Empty grid
--                                                cells are the correct result.
--
--   { buff, kind = "guarantee", scope, value }   the buff is pulled into
--       scope "everyone"                         matching raiders' top N buff
--             "wowrole" (value "tank"/"healer"/  priorities, where N is how
--                        "dps")                  many paladins are handing out
--             "class"   (value "Mage")           blessings -- i.e. into the
--             "role"    (value a role id)        range they'll actually
--                                                receive. It does NOT jump the
--                                                queue: a buff already inside
--                                                the top N is left where it is,
--                                                so guaranteeing Salvation for
--                                                healers buys them Salvation
--                                                without costing them Wisdom.
--
-- One implicit rule rides along: Salvation is ignored inside a battleground or
-- arena unless the user wrote the Salvation ignore rule themselves -- see
-- PvpSalvationIgnored below.
--
-- "only" is baked into the rule at creation time rather than re-derived from
-- who this client has seen running WDW/PallyPower. That detection
-- (IsPaladinDisabled) is local knowledge and differs between clients; the plan
-- has to come out identical on all of them, so detection drives the warnings
-- and what the menu writes, never the math.
--
-- Shared as STATE.paladinStrategy so identical roster/role/talent inputs yield
-- the same plan on every client. Rules are group-scoped; the leader prunes an
-- assign rule when its named paladin leaves, and group leave clears them all.
-- ---------------------------------------------------------------------------

local function GetBuffRules()
    return WhoDoesWhat.db.profile.paladinBuffRules
end

-- Salvation is threat reduction, which buys nothing in a battleground or
-- arena, so it drops out of the plan there without anyone having to add a
-- rule. Everyone in the instance evaluates this the same way, so the derived
-- plan stays identical across clients. Any explicit Salvation rule -- of any
-- kind -- means the user has an opinion, and theirs wins.
local function PvpSalvationIgnored()
    local _, instanceType = IsInInstance()
    if instanceType ~= "pvp" and instanceType ~= "arena" then return false end
    for _, rule in ipairs(GetBuffRules()) do
        if rule.buff == "salv" then return false end
    end
    return true
end

-- A paladin this client has seen running neither WhoDoesWhat nor PallyPower.
-- They can't be shown a per-class blessing board by anything, so the plan's
-- careful per-raider split is wasted on them: what they need is one blessing
-- and a whisper saying so, which is the `only` assign rule.
--
-- LOCAL KNOWLEDGE, deliberately kept out of the plan math (see the rule model
-- above): peers announce themselves over time, so this answers "not yet" on
-- everyone for the first seconds in a group and settles as replies land. It
-- drives warnings and what the Add (+) menu writes, never coverage. Fake
-- raiders are never disabled -- nobody is behind them to run anything.
function WhoDoesWhat:IsPaladinDisabled(name)
    if not name or name == UnitName("player") then return false end
    local m = FindMember(name)
    if not m or m.isFake then return false end
    if self.syncPeers and self.syncPeers[name] then return false end
    return not self:PaladinHasPallyPower(name)
end

-- The rules split into the shapes the plan consumes: the ignored-buff set,
-- the guarantee rules in rule order, and the assign rule per paladin (first
-- rule wins if one paladin is somehow named twice).
local function CompileBuffRules()
    local ignored, guaranteed, assigned = {}, {}, {}
    for _, r in ipairs(GetBuffRules()) do
        if r.kind == "ignore" then
            ignored[r.buff] = true
        elseif r.kind == "guarantee" then
            guaranteed[#guaranteed + 1] = r
        elseif r.kind == "assign" and r.value then
            if not assigned[r.value] then
                assigned[r.value] = r
            end
        end
    end
    if PvpSalvationIgnored() then ignored.salv = true end
    return ignored, guaranteed, assigned
end

-- Who hands out blessings, split by how. A paladin whose assign rule carries
-- `only` is LOCKED: one blessing, nothing else, so they sit out the per-raider
-- matching and their blessing is seeded straight into every raider who wants
-- it. Everyone else with known talents joins the matching pool -- unknown
-- paladins wait rather than being assigned commodity blessings on an unsafe
-- zero-rank assumption. A locked paladin needs no talent data: the user named
-- the blessing, so there is nothing left to infer.
local function BuffPaladins(ignored, assigned)
    local pool, locked = {}, {}
    for _, name in ipairs(MembersOfClass("Paladin")) do
        local rule = assigned[name]
        if rule and rule.only and not ignored[rule.buff] then
            locked[#locked + 1] = { name = name, buff = rule.buff }
        elseif WhoDoesWhat:GetPaladinBuffTalents(name) then
            pool[#pool + 1] = name
        end
    end
    return pool, locked
end

-- How many blessings a raider stands to receive: one from each paladin in the
-- matching pool, plus the single one each locked paladin hands out. This is
-- the window a guarantee rule pulls its blessing into, which is why the rule
-- rows quote it back.
local function PaladinBuffSlots()
    local ignored, _, assigned = CompileBuffRules()
    local pool, locked = BuffPaladins(ignored, assigned)
    return #pool + #locked
end

-- Paladins this client sees as disabled that no assign rule speaks for yet.
-- They're still in the pool, collecting a per-class plan nothing can show
-- them, so this drives the (!) beside "Add (+)" and the notes inside its menu.
local function UnhandledDisabledPaladins()
    local _, _, assigned = CompileBuffRules()
    local out = {}
    for _, name in ipairs(MembersOfClass("Paladin")) do
        if not assigned[name] and WhoDoesWhat:IsPaladinDisabled(name) then
            out[#out + 1] = name
        end
    end
    return out
end

-- Does a guarantee rule cover this member?
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
-- out entirely, and guaranteed buffs that cover this member are pulled into
-- the top `slots` -- the range a raider actually receives, `slots` being how
-- many paladins are handing out blessings.
--
-- Pulled in, not moved to the front: a guarantee is a promise of coverage, not
-- a statement that the buff outranks everything the raider already wanted.
-- Anything already inside the window stays exactly where it is. Several
-- guarantees land as a block at the bottom of the window in rule order, so
-- they all fit inside it rather than pushing each other back out.
--
-- A guarantee still can't reach past the raider's role: a blessing the role's
-- buff order excludes stays excluded (the divider in the role's buff order is
-- the stronger statement).
local function RuleAdjustedOrder(m, ignored, guaranteed, slots)
    local roleId = WhoDoesWhat:GetAssignedRole(m.name)
    local base = (roleId and WhoDoesWhat:GetEffectiveBuffOrder(roleId))
        or WhoDoesWhat.CanonicalBuffOrder
    local allowed
    if roleId then
        allowed = {}
        for _, key in ipairs(base) do allowed[key] = true end
    end

    local order, at = {}, {}
    for _, key in ipairs(base) do
        if not ignored[key] and not at[key] then
            order[#order + 1] = key
            at[key] = #order
        end
    end

    -- The guaranteed buffs this member is missing out on, in rule order.
    local promote = {}
    if slots and slots > 0 and slots < #order then
        local seen = {}
        for _, rule in ipairs(guaranteed) do
            local key = rule.buff
            if at[key] and at[key] > slots and not seen[key]
                and (not allowed or allowed[key])
                and RuleMatchesMember(rule, m) then
                promote[#promote + 1] = key
                seen[key] = true
            end
        end
    end
    if #promote == 0 then return order end

    local promoted = {}
    for _, key in ipairs(promote) do promoted[key] = true end
    local kept = {}
    for _, key in ipairs(order) do
        if not promoted[key] then kept[#kept + 1] = key end
    end
    -- The block ends on the last slot the raider will actually be handed.
    local insertAt = math.max(1, math.min(slots, #kept + 1) - #promote + 1)
    for i = #promote, 1, -1 do
        table.insert(kept, insertAt, promote[i])
    end
    return kept
end

-- The same ordered demand list the paladin matcher consumes, exposed for
-- read-only grid diagnostics such as "outside this player's top X buffs".
local function GetPaladinBuffPriorityOrder(playerName)
    local member = FindMember(playerName)
    if not member then
        for _, pet in ipairs(GetPetMembers()) do
            if pet.name == playerName then member = pet break end
        end
    end
    if not member then return nil end
    local ignored, guaranteed, assigned = CompileBuffRules()
    if member.isPet then return PetBuffOrder(ignored) end
    local pool, locked = BuffPaladins(ignored, assigned)
    return RuleAdjustedOrder(member, ignored, guaranteed, #pool + #locked)
end

-- ---------------------------------------------------------------------------
-- Per-raider buff plan (the buff grid's cells + the main window's paladin
-- summary rows)
--
-- There is no stored per-buff assignment: coverage is derived from the roster
-- + roles + talents + the custom rules above. The complete derived plan is
-- cached by those inputs so every view reads the same snapshot and the exact
-- matcher runs only when an input changes. Every non-raider-excluded paladin
-- with known buff talents takes part; unknown paladins wait rather than being
-- assigned commodity blessings on an unsafe zero-rank assumption.
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
--   3. preferring each paladin's own blessing ladder (+15 for their computed
--      PRIMARY, smaller bonuses down their fallbacks -- ComputePaladinBuffLadder
--      below) -- the consolidation glue -- with a rank-proof +100 when an
--      assign rule dictated the pairing.
--
-- Every allowed priority participates. The matcher still assigns at most one
-- blessing per paladin, but if Kings or Sanctuary is uncastable it can fall
-- through to the raider's next allowed choice; below-divider buffs are absent
-- from the order entirely.
--
-- Returns plan[raiderName] = { [paladinName] = buff key }.

-- Each paladin's PRIMARY blessing: the raid-wide greater blessing they'd
-- naturally own, recomputed on the fly and invisible in the UI. It exists to
-- keep the per-raider matching grounded: without it, equal-rank ties resolve
-- per raider and let the same buff bounce between paladins -- Wisdom split
-- across two casters, every paladin juggling 3-4 different blessings. The
-- matcher's stickiness bonus consolidates coverage around one owner per
-- buff; raiders whose priorities skip a paladin's primary still get that
-- paladin's next-best cast, which the fallback ladder below keeps the same
-- from raider to raider.
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
-- A paladin misses out only when nothing castable remains for them.
--
-- One primary each is not enough on its own. A raider who doesn't want a
-- paladin's primary (a Warrior has no use for Wisdom) leaves that paladin
-- falling back to some other blessing, and with the primaries silent about
-- second choices two equally-talented paladins swap their leftovers from
-- raider to raider -- the Wisdom paladin picking up scattered Salvations
-- while the Salvation paladin picks up scattered Mights. So the same solve
-- is repeated round after round, each round barred from the pairs the
-- earlier rounds made, giving every paladin a full ranked fallback ladder
-- (ladder[paladin][buff] = 1..n). It is computed once for the whole raid,
-- so every raider falls back the same way and a paladin's leftovers land on
-- one blessing instead of a spread. Rank 1 is the primary; assign-locked
-- paladins get their assigned buff as rank 1 and ladder the rest.
--
-- `covered` holds the blessings the locked paladins already hand out
-- (BuffPaladins): those are off the table here, so nobody's primary is a
-- blessing every raider is already getting from someone else.
--
-- Returns forced[paladinName] = buff key for the pairs an assign rule locked
-- in (they score a bigger stickiness bonus than any rung), and the ladder.
--
-- SYNC INVARIANT: this result must be deterministic on every client given the
-- same roster, roles, talent ranks, and rules. Keep caster names sorted, buff
-- order canonical, mask traversal numeric, and equal-score tie retention
-- stable; a pairs-order tie-break here would desynchronize blessing displays.
local function ComputePaladinBuffLadder(pool, ignored, covered, guaranteed, preferred, slots)
    local canonical = WhoDoesWhat.CanonicalBuffOrder
    local forced = {}

    -- Rule-ignored buffs, and the ones a locked paladin already covers, are
    -- out of the running entirely.
    local avail = {}
    for _, key in ipairs(canonical) do
        if not ignored[key] and not covered[key] then avail[#avail + 1] = key end
    end
    local depth = math.min(#pool, #avail)
    if depth == 0 then return forced, {} end

    -- Assign rules place their pairs first, as hard locks: the paladin's
    -- primary is decided, they leave the pool, the buff leaves the demand
    -- race. Walked in pool order for determinism; two rules can't name one
    -- paladin (first wins in CompileBuffRules), and absent paladins never
    -- appear in pool.
    local used, lockedBuff = {}, {}
    for _, name in ipairs(pool) do
        local buff = preferred[name]
        if buff and not ignored[buff] and not covered[buff] and not lockedBuff[buff] then
            forced[name] = buff
            used[name] = true
            lockedBuff[buff] = true
        end
    end

    -- Demand votes: each raider's top `depth` wanted buffs, rule-adjusted.
    local votes = {}
    for _, key in ipairs(avail) do votes[key] = 0 end
    for _, m in ipairs(GetEligibleMembers(nil)) do
        if not WhoDoesWhat:IsNonRaider(m.name) then
            local order = RuleAdjustedOrder(m, ignored, guaranteed, slots)
            for i = 1, math.min(depth, #order) do
                if votes[order[i]] then
                    votes[order[i]] = votes[order[i]] + 1
                end
            end
        end
    end
    -- Every hunter's pet votes too (Might, Kings, Light): pet demand shapes the
    -- primaries without anyone assigning anything.
    for _ in ipairs(GetPetMembers()) do
        local order = PetBuffOrder(ignored)
        for i = 1, math.min(depth, #order) do
            if votes[order[i]] then
                votes[order[i]] = votes[order[i]] + 1
            end
        end
    end

    -- Free casters and still-available buffs after the assign-rule locks.
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

    -- Pairs already handed out by an earlier ladder round, so a later round
    -- gives each paladin their NEXT choice instead of the same one again.
    local taken = {}

    -- Weight of pairing a paladin with a buff, or nil if infeasible. A small
    -- base (so filling a slot always beats leaving it empty) + demand (which
    -- buffs the raid wants) + talentRank*10 (routes each specialist onto their
    -- Improved/granted blessing). Gated blessings are only feasible for a
    -- talented caster.
    local function Weight(name, key)
        if taken[name] and taken[name][key] then return nil end
        if Gated(key) and (BuffTalentRank(name, key) or 0) == 0 then
            return nil
        end
        return 1 + votes[key] + (BuffTalentRank(name, key) or 0) * 10
    end

    -- Exact max-weight assignment of casters to distinct buffs, solved by DP
    -- over the set of buff indices already handed out (bitmask). Maximizing
    -- total weight jointly chooses WHICH buffs are taken and WHO owns each:
    -- the specialist's talent weight pulls their Improved buff into the set
    -- and onto them, so the commodity blessings consolidate onto the
    -- non-specialists (one pally owns every Kings while another runs the
    -- Wis/Might split). A slot no caster can fill (a gated buff with no
    -- talented caster) is left unmatched -- the old forfeit-to-next backfill.
    -- Masks are walked numerically for a deterministic, refresh-stable pick.
    -- Returns picks[casterIndex] = buffIndex.
    local function SolveRound(casters, buffs)
        local nb = #buffs
        local full = bit.lshift(1, nb)
        local dp = { [0] = { score = 0, picks = {} } }
        for c = 1, #casters do
            local name = casters[c]
            local ndp = {}
            for mask = 0, full - 1 do
                local st = dp[mask]
                if st then
                    -- This caster takes nothing this round.
                    local cur = ndp[mask]
                    if not cur or st.score > cur.score then ndp[mask] = st end
                    -- Or takes one still-free buff they can cast.
                    for j = 1, nb do
                        local jbit = bit.lshift(1, j - 1)
                        if bit.band(mask, jbit) == 0 then
                            local w = Weight(name, buffs[j])
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
        return best.picks
    end

    -- Round 1 decides the primaries: only the paladins an assign rule didn't
    -- already place, over only the buffs those locks left free.
    local ladder = {}
    local function Record(name, key, round)
        ladder[name] = ladder[name] or {}
        ladder[name][key] = ladder[name][key] or round
        taken[name] = taken[name] or {}
        taken[name][key] = true
    end
    for name, buff in pairs(forced) do Record(name, buff, 1) end

    for c, j in pairs(SolveRound(freeCasters, freeBuffs)) do
        Record(freeCasters[c], freeBuffs[j], 1)
    end

    -- Later rounds rank each paladin's fallbacks. Every paladin takes part
    -- (the assign-locked ones need fallbacks too) over every available buff,
    -- barred only from what they already hold.
    for round = 2, #avail do
        for c, j in pairs(SolveRound(pool, avail)) do
            Record(pool[c], avail[j], round)
        end
    end

    return forced, ladder
end

-- Position values for a raider's 1st..6th buff priority: (7-i)^2 * 1000.
-- Squared so covering { 1st, 4th } beats { 2nd, 3rd } when feasibility forces
-- a choice; the *1000 keeps every rank/stickiness sum (< 1000) from ever
-- outvoting a position step.
local GRID_POS_VALUE = {}
for i = 1, 6 do GRID_POS_VALUE[i] = (7 - i) * (7 - i) * 1000 end

-- Stickiness per ladder rung (ComputePaladinBuffLadder): the primary is worth
-- more than one talent rank, every fallback less than one, so the ladder only
-- ever decides ties between equally-talented paladins -- which is exactly the
-- case that used to scatter their leftovers.
local LADDER_BONUS = { 15, 6, 5, 4, 3, 2 }

local cachedBuffPlanKey, cachedBuffPlan

-- Cheap deterministic key for every input to the expensive matching below.
-- This avoids a brittle list of invalidation calls across roster, talent,
-- role-customization, sync, fake-raid, and local-rule mutation paths.
local function BuffPlanKey(ignored, guaranteed, slots)
    local parts = {}
    local function Add(value) parts[#parts + 1] = tostring(value or "") end

    Add("slots"); Add(slots)
    for _, rule in ipairs(GetBuffRules()) do
        Add("rule")
        Add(rule.buff); Add(rule.kind); Add(rule.scope); Add(rule.value); Add(rule.only)
    end
    for _, m in ipairs(GetEligibleMembers(nil)) do
        local roleId = WhoDoesWhat:GetAssignedRole(m.name)
        Add("member"); Add(m.name); Add(m.classInfo.name); Add(roleId)
        if not WhoDoesWhat:IsNonRaider(m.name) then
            Add(table.concat(RuleAdjustedOrder(m, ignored, guaranteed, slots), ","))
        end
    end
    for _, name in ipairs(MembersOfClass("Paladin")) do
        Add("paladin"); Add(name)
        for _, key in ipairs(WhoDoesWhat.CanonicalBuffOrder) do
            Add(BuffTalentRank(name, key))
        end
    end
    return table.concat(parts, "\31")
end

-- Collapse per-target cells into one class Greater per paladin. Real class
-- members decide; virtual pets vote only when the Warrior bucket has no real
-- assignments. Ties follow canonical blessing order.
local function ComputeGreaterAssignments(plan, targetClass, petTargets)
    local votes = {}
    for raider, cells in pairs(plan) do
        local className = targetClass[raider]
        for paladin, key in pairs(cells) do
            votes[paladin] = votes[paladin] or {}
            local bucket = votes[paladin][className]
            if not bucket then
                bucket = { all = {}, real = {} }
                votes[paladin][className] = bucket
            end
            bucket.all[key] = (bucket.all[key] or 0) + 1
            if not petTargets[raider] then
                bucket.real[key] = (bucket.real[key] or 0) + 1
            end
        end
    end

    local canonicalIndex = {}
    for i, key in ipairs(WhoDoesWhat.CanonicalBuffOrder) do canonicalIndex[key] = i end
    local greaterByPaladin = {}
    for paladin, byClass in pairs(votes) do
        local greater = {}
        for className, bucket in pairs(byClass) do
            local tally = next(bucket.real) and bucket.real or bucket.all
            local bestKey, bestCount
            for key, count in pairs(tally) do
                if not bestKey or count > bestCount
                    or (count == bestCount and canonicalIndex[key] < canonicalIndex[bestKey]) then
                    bestKey, bestCount = key, count
                end
            end
            greater[className] = bestKey
        end
        greaterByPaladin[paladin] = greater
    end
    return greaterByPaladin
end

local function ComputePaladinBuffPlan()
    local ignored, guaranteed, assigned = CompileBuffRules()
    local pool, locked = BuffPaladins(ignored, assigned)
    -- How many blessings a raider stands to receive: one from each matching
    -- paladin, plus the single one each locked paladin hands out. This is the
    -- window a guarantee rule pulls its blessing into.
    local slots = #pool + #locked

    local cacheKey = BuffPlanKey(ignored, guaranteed, slots)
    if cachedBuffPlanKey == cacheKey then return cachedBuffPlan end

    -- What the locked paladins already blanket the raid with, and the soft
    -- primary locks (assign rules without `only`) for the paladins still in
    -- the matching pool.
    local covered, preferred = {}, {}
    for _, lk in ipairs(locked) do covered[lk.buff] = true end
    for _, name in ipairs(pool) do
        local rule = assigned[name]
        if rule then preferred[name] = rule.buff end
    end
    local forced, ladder = ComputePaladinBuffLadder(pool, ignored, covered,
        guaranteed, preferred, slots)

    -- Only talent-GRANTED blessings are gated. Might/Wisdom stay castable at
    -- rank 0; Salvation/Light have no talent requirement.
    local function CanCast(name, key)
        local meta = BuffTalents[key]
        if meta and meta.maxRank == 1 then
            return (BuffTalentRank(name, key) or 0) > 0
        end
        return true
    end

    -- The locked paladins' cells for one raider: each hands out their single
    -- blessing to everyone whose priorities include it, and gives nothing at
    -- all to anyone else. Returns the cells plus the order positions they
    -- consume, which the matcher below starts from -- so the rest of the
    -- paladins fill the raider's REMAINING wants instead of doubling up on a
    -- blessing that is already covered.
    local function SeedLocked(order, unavailable)
        local cells, mask = {}, 0
        for _, lk in ipairs(locked) do
            if not (unavailable and unavailable[lk.name]) then
                for i, key in ipairs(order) do
                    local ibit = bit.lshift(1, i - 1)
                    if key == lk.buff and bit.band(mask, ibit) == 0 then
                        cells[lk.name] = key
                        mask = mask + ibit
                        break
                    end
                end
            end
        end
        return cells, mask
    end

    -- One raider's cells, matched exactly by DP: process the pool paladin by
    -- paladin; a state is the set of order positions already given out
    -- (bitmask, order is always the full 6 buffs) with the best score
    -- reaching it and the picks that did. Each paladin either sits out (mask
    -- unchanged) or takes one free position they can cast. Masks are walked
    -- numerically so equal-score ties resolve the same way every refresh.
    local function SolveRaider(order, unavailable)
        local seedCells, seedMask = SeedLocked(order, unavailable)
        local dp = { [seedMask] = { score = 0, picks = {} } }
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
                    if not (unavailable and unavailable[name]) then
                        for i = 1, #order do
                            local ibit = bit.lshift(1, i - 1)
                            local key = order[i]
                            if bit.band(mask, ibit) == 0 and CanCast(name, key) then
                                -- The +15 primary stickiness outweighs one talent
                                -- rank but not two: near-ties consolidate on the
                                -- primary owner, real rank gaps still win. The
                                -- smaller ladder bonuses below it do the same for
                                -- the fallbacks, so a paladin whose primary this
                                -- raider doesn't want still lands on the same
                                -- second (third, ...) choice they take everywhere
                                -- else -- all of them under one rank step, so
                                -- talent still decides when talent differs. A
                                -- assign-rule pair scores +100 instead -- past
                                -- any possible rank gap (max 50), so the user's
                                -- pick holds; position values still dominate, so
                                -- nobody is force-fed a buff they don't want.
                                local rung = ladder[name] and ladder[name][key]
                                local score = st.score + GRID_POS_VALUE[i]
                                    + (BuffTalentRank(name, key) or 0) * 10
                                    + (forced[name] == key and 100
                                        or rung and LADDER_BONUS[rung] or 0)
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

        local cells = seedCells
        for p, i in pairs(best.picks) do
            cells[pool[p]] = order[i]
        end
        return cells
    end

    local plan, targetClass, petTargets = {}, {}, {}
    for _, m in ipairs(GetEligibleMembers(nil)) do
        -- Non-raiders get no plan entry at all (and no grid row).
        if not WhoDoesWhat:IsNonRaider(m.name) then
            local order = RuleAdjustedOrder(m, ignored, guaranteed, slots)
            plan[m.name] = SolveRaider(order)
            targetClass[m.name] = m.classInfo.name
        end
    end

    -- First establish real Warrior Greaters, then build each pet row around
    -- that inherited coverage. Remaining wants are exactly matched across the
    -- unused paladins as Lesser exceptions. With no real Warrior assignment,
    -- the ordinary pet solve below defines a pets-only Greater bucket.
    local realGreater = ComputeGreaterAssignments(plan, targetClass, petTargets)
    for _, pet in ipairs(GetPetMembers()) do
        local order = PetBuffOrder(ignored)
        local cells, used, covered = {}, {}, {}
        for _, paladin in ipairs(pool) do
            local key = realGreater[paladin]
                and realGreater[paladin].Warrior
            if key and not covered[key] then
                for _, wanted in ipairs(order) do
                    if wanted == key then
                        cells[paladin] = key
                        used[paladin] = true
                        covered[key] = true
                        break
                    end
                end
            end
        end
        local remaining = {}
        for _, key in ipairs(order) do
            if not covered[key] then remaining[#remaining + 1] = key end
        end
        for paladin, key in pairs(SolveRaider(remaining, used)) do
            cells[paladin] = key
        end
        plan[pet.name] = cells
        targetClass[pet.name] = "Warrior"
        petTargets[pet.name] = true
    end

    -- Class Greater decisions are part of the shared plan, not view state.
    local greaterByPaladin = ComputeGreaterAssignments(plan, targetClass, petTargets)

    local lockedPaladins = {}
    for _, lk in ipairs(locked) do lockedPaladins[lk.name] = lk.buff end

    cachedBuffPlanKey = cacheKey
    cachedBuffPlan = {
        grid = plan,
        greaterByPaladin = greaterByPaladin,
        targetClass = targetClass,
        -- paladin -> the single blessing an `only` assign rule gave them.
        -- They're outside the matching, so "no talent data" is not a reason
        -- to hold their row back the way it is for everyone else.
        lockedPaladins = lockedPaladins,
    }
    return cachedBuffPlan
end

local function ComputeBuffGrid()
    return ComputePaladinBuffPlan().grid
end

-- The synchronized raid toggle chooses which plan drives WDW's functional
-- blessing UI. Prefer a co-installed PallyPower's live tables; its observed
-- wire mirror is the fallback when the addon is absent.
local function GetActivePaladinBuffPlan()
    if WhoDoesWhat.db.profile.settings.pallyBuffSource == "pallypower"
        and WhoDoesWhat.GetPallyPowerBuffPlan then
        return WhoDoesWhat:GetPallyPowerBuffPlan("addon")
            or WhoDoesWhat:GetPallyPowerBuffPlan("observed")
    end
    return ComputePaladinBuffPlan()
end

local function IsSimulatedPaladinBuff(paladin, raider)
    if WhoDoesWhat.FakeRaid and WhoDoesWhat:IsFakeRaidEnabled() then
        local simulatedPaladin, simulatedRaider = false, false
        for _, m in ipairs(WhoDoesWhat.FakeRaid.ROSTER) do
            if m.name == paladin and m.class == "PALADIN" then simulatedPaladin = true end
            if m.name == raider
                or (m.class == "HUNTER" and raider == m.name .. "'s Pet") then
                simulatedRaider = true
            end
            if simulatedPaladin and simulatedRaider then return true end
        end
    end
    return false
end

local function DisconnectedGroupTargets()
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    else
        units[1] = "player"
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end

    local disconnected = {}
    for _, unit in ipairs(units) do
        if UnitIsConnected(unit) == false then
            local name = GetUnitKey(unit)
            if name then
                disconnected[name] = true
                disconnected[name .. "'s Pet"] = true
            end
        end
    end
    return disconnected
end

-- A corpse is not a missing buff. Out of combat a dead raider still counts --
-- they're about to be resurrected and rebuffed, and that's the gap the bars
-- exist to show -- but mid-fight nobody can close it, so they drop out of
-- every check until they're back up. The Dead check itself is exempt:
-- reporting corpses is its whole job (`countsDead` in Data.lua).
local function IgnoredWhileDead(name)
    return UnitAffectingCombat("player")
        and WhoDoesWhat:HasBuff(name, "dead") == true
end

-- Live completion of the active plan, raid-wide and per paladin. Simulated
-- paladin -> simulated raider cells count as covered because neither side can
-- produce real aura data; disconnected real targets are left out entirely.
local function ComputePaladinBuffCoverage(buffPlan, includePets)
    local disconnected = DisconnectedGroupTargets()
    local correct, total, byPaladin = 0, 0, {}
    for raider, cells in pairs((buffPlan or GetActivePaladinBuffPlan()).grid) do
        if not disconnected[raider] and not IgnoredWhileDead(raider)
            and (includePets ~= false or not raider:match("'s Pet$")) then
            for paladin, key in pairs(cells) do
                local p = byPaladin[paladin]
                if not p then
                    p = { correct = 0, total = 0, missing = {} }
                    byPaladin[paladin] = p
                end
                total = total + 1
                p.total = p.total + 1
                if IsSimulatedPaladinBuff(paladin, raider)
                    or WhoDoesWhat:HasBuff(raider, key) == true then
                    correct = correct + 1
                    p.correct = p.correct + 1
                else
                    p.missing[#p.missing + 1] = { target = raider, key = key }
                end
            end
        end
    end
    return correct, total, byPaladin
end

-- Which side of a check its tooltip list names. Normally the answer is the
-- unhelpful end: who lacks a buff, or who carries a debuff.
--
-- Sated is the exception (`flagMissingInCombat`), because the question changes
-- when the pull starts. Standing around, the debuff is the cooldown and the
-- list you want is who still has it -- those are the people a lust can't help
-- yet. Once you're fighting, the lust has gone out and the list you want is
-- the inverse: who missed it, and is owed a second one.
local function FlagsTheCovered(buff, options)
    if buff.flagMissingInCombat and UnitAffectingCombat("player") then
        return false
    end
    return options.negative == true
end

local function IsEligibleCoreBuffTarget(m, buff, options, disconnected)
    return not m.isFake and not WhoDoesWhat:IsNonRaider(m.name)
        and not disconnected[m.name]
        and not (not buff.countsDead and IgnoredWhileDead(m.name))
        and not (options.onlyManaUsers
            and WhoDoesWhat.ManaExcludedClasses[m.classInfo.name])
        and not (options.onlyTanks and not WhoDoesWhat:IsMarkedTank(m.name))
end

-- Everyone who can supply a talent-improved core buff, best rank first, each
-- flagged with whether they are actually around to cast it. Unscanned talents
-- sort last as an unknown rank rather than as a zero. Shared by the Buffing
-- Grid's column headers and the WDW Status tooltips.
local function ComputeCoreBuffProviders(key, disconnected)
    local buff = WhoDoesWhat.StatusBarChecks[key]
    local talent = buff and buff.improvedTalent
    local providers = {}
    if not talent or not buff.className then return providers end
    disconnected = disconnected or DisconnectedGroupTargets()
    for _, member in ipairs(GetEligibleMembers(buff.className)) do
        if member.classInfo.name == buff.className then
            providers[#providers + 1] = {
                name = member.name,
                rank = WhoDoesWhat:GetCoreBuffTalent(member.name, key),
                available = member.isFake or not disconnected[member.name],
            }
        end
    end
    table.sort(providers, function(a, b)
        if (a.rank == nil) ~= (b.rank == nil) then return b.rank == nil end
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.name < b.name
    end)
    return providers
end

local function BestAvailableCoreBuffRank(buff, key, disconnected)
    if not buff.improvedTalent or not buff.className then return nil end
    local best
    for _, provider in ipairs(ComputeCoreBuffProviders(key, disconnected)) do
        if provider.available and provider.rank ~= nil
            and (best == nil or provider.rank > best) then
            best = provider.rank
        end
    end
    return best
end

-- Where "Only consider best available" stops applying under its sub-option:
-- mid-fight there is no time to chase a better rank, and a battleground group
-- is strangers whose talents nobody is going to redistribute.
local function AnyBuffContext()
    if UnitAffectingCombat("player") then return true end
    local _, instanceType = IsInInstance()
    return instanceType == "pvp" or instanceType == "arena"
end

-- Live coverage for the non-paladin checks in WDW Status. Only real, connected
-- raiders count; a check may opt into scanned hunter pets through Data.lua.
-- Fake-development members and the Non-raider role remain excluded.
local function ComputeCoreRaidBuffCoverage()
    local disconnected = DisconnectedGroupTargets()
    local members = GetEligibleMembers(nil)
    local pets = GetPetMembers()
    -- Built only if a check asks for it (`allPets`), since it walks the whole
    -- roster rather than the hunters.
    local allPets
    local correct, total, rows = 0, 0, {}
    local anyContext = AnyBuffContext()
    for _, key in ipairs(WhoDoesWhat:GetStatusBarCheckOrder()) do
        local buff = WhoDoesWhat.StatusBarChecks[key]
        if not buff.customOptions and not buff.customCoverage then
            local options = WhoDoesWhat:GetStatusBarCheckOptions(key)
            local bestRank = options.bestAvailable
                and not (options.anyInCombat and anyContext)
                and BestAvailableCoreBuffRank(buff, key, disconnected) or nil
            local row = {
                key = key, name = buff.name, icon = buff.icon,
                correct = 0, total = 0,
                -- How many carry the buff at all, regardless of rank. Equal to
                -- `correct` unless a best-rank requirement is in force, which
                -- is exactly when the tooltip splits the two apart.
                anyCorrect = 0,
                -- Targets worth acting on: raiders missing a buff, or carrying
                -- a tracked debuff on a negative check. Drives the tooltip's
                -- "who still needs this" list.
                flagged = {},
                -- Which end of the check `flagged` holds, since a debuff can
                -- flip mid-pull (see flagMissingInCombat below). The tooltip
                -- can't read it off `negative` alone.
                flaggedAreMissing = not FlagsTheCovered(buff, options),
                -- The improvement rank this check is currently measured
                -- against, so a view can tell who is on the hook for it.
                bestRank = bestRank,
                available = not options.requiredClass
                    or #MembersOfClass(options.requiredClass) > 0,
            }
            local targets = members
            if options.hunterPets and not buff.hunterPetsOptionDisabled then
                local petList = pets
                if buff.allPets then
                    allPets = allPets or GetPetMembers(true)
                    petList = allPets
                end
                targets = {}
                for _, m in ipairs(members) do targets[#targets + 1] = m end
                for _, pet in ipairs(petList) do
                    -- No unit means no pet to feed; only a scanned/summoned pet
                    -- participates, with false representing confirmed missing.
                    if WhoDoesWhat:HasBuff(pet.name, key) ~= nil then
                        targets[#targets + 1] = pet
                    end
                end
            end
            for _, m in ipairs(targets) do
                if IsEligibleCoreBuffTarget(m, buff, options, disconnected) then
                    row.total = row.total + 1
                    total = total + 1
                    local hasBuff = WhoDoesWhat:HasBuff(m.name, key) == true
                    local covered, rank = hasBuff, nil
                    if bestRank and bestRank > 0 then
                        local _, _, r =
                            WhoDoesWhat:GetImprovedBuffState(m.name, key)
                        rank = r
                        covered = r ~= nil and r >= bestRank
                    end
                    if hasBuff then row.anyCorrect = row.anyCorrect + 1 end
                    if covered then
                        row.correct = row.correct + 1
                        correct = correct + 1
                    end
                    if covered == FlagsTheCovered(buff, options) then
                        row.flagged[#row.flagged + 1] = {
                            name = m.name,
                            classInfo = m.classInfo,
                            isPet = m.isPet,
                            -- Buffed, just not by the best caster available:
                            -- a different problem from having nothing at all.
                            unoptimal = not covered and hasBuff or nil,
                            rank = rank,
                        }
                    end
                end
            end
            rows[#rows + 1] = row
        end
    end
    return correct, total, rows
end

-- The plan aggregated per paladin: how many raiders each paladin blesses
-- with each buff. Returns an array of
--   { name, total, buffs = { { key, count }, ... } }
-- with each paladin's buffs count-descending (ties in canonical order) and
-- the paladins themselves total-descending (ties by name). Drives the main
-- window's Paladin Buffs rows and that section's whispers.
local function ComputePaladinBuffSummary(buffPlan)
    local canonical = WhoDoesWhat.CanonicalBuffOrder
    local canonIndex = {}
    for i, key in ipairs(canonical) do canonIndex[key] = i end

    local plan = buffPlan or GetActivePaladinBuffPlan()
    local locked = plan.lockedPaladins or {}
    local counts, names = {}, {}
    for _, name in ipairs(MembersOfClass("Paladin")) do
        counts[name] = {}
        names[#names + 1] = name
    end
    for _, cells in pairs(plan.grid) do
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
        out[#out + 1] = {
            name = name,
            total = total,
            buffs = buffs,
            awaitingTalents = not locked[name]
                and WhoDoesWhat:GetPaladinBuffTalents(name) == nil,
        }
    end
    table.sort(out, function(a, b)
        if a.awaitingTalents ~= b.awaitingTalents then return a.awaitingTalents end
        if a.total ~= b.total then return a.total > b.total end
        return a.name < b.name
    end)
    return out
end

-- Realm-tag-free display name; a hunter pet resolves to "Broll (Rexxar)" so a
-- whispered to-do names both the pet and the hunter to find it next to.
local function ShortAssignmentName(name)
    return WhoDoesWhat:DisplayName(name)
end

local function PaladinBuffWhisperText(coverage)
    local missing = coverage and coverage.missing or {}
    local missingCount = #missing
    if missingCount == 0 then return nil end

    local percent = coverage.total > 0
        and math.floor(coverage.correct * 100 / coverage.total + 0.5) or 0
    local lead = "Pally Buffs (" .. percent .. "%) "

    if missingCount < 5 then
        table.sort(missing, function(a, b)
            local an, bn = ShortAssignmentName(a.target), ShortAssignmentName(b.target)
            if an ~= bn then return an < bn end
            return a.key < b.key
        end)
        local parts = {}
        for _, cell in ipairs(missing) do
            parts[#parts + 1] = ShortAssignmentName(cell.target) .. "->"
                .. WhoDoesWhat.PaladinBuffs[cell.key].name_long
        end
        return lead .. missingCount .. " Missing, " .. table.concat(parts, ", ")
    end

    local counts, parts, canonicalIndex = {}, {}, {}
    for _, cell in ipairs(missing) do
        counts[cell.key] = (counts[cell.key] or 0) + 1
    end
    for i, key in ipairs(WhoDoesWhat.CanonicalBuffOrder) do
        canonicalIndex[key] = i
        if counts[key] then
            parts[#parts + 1] = { key = key, count = counts[key] }
        end
    end
    table.sort(parts, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return canonicalIndex[a.key] < canonicalIndex[b.key]
    end)
    for i, part in ipairs(parts) do
        parts[i] = WhoDoesWhat.PaladinBuffs[part.key].name_long .. " x" .. part.count
    end
    return lead .. "Missing " .. table.concat(parts, ", ")
end

local function GetPaladinBuffWhisper(name)
    local _, _, byPaladin = ComputePaladinBuffCoverage()
    return PaladinBuffWhisperText(byPaladin[name])
end

-- Header-mail collector for the Paladin Buffs section: each incomplete
-- paladin gets the same live missing-buff message as their row button.
local function CollectPaladinBuffWhispers()
    local _, _, byPaladin = ComputePaladinBuffCoverage()
    local out = {}
    for _, p in ipairs(ComputePaladinBuffSummary()) do
        local msg = PaladinBuffWhisperText(byPaladin[p.name])
        if msg then
            out[#out + 1] = {
                name = p.name,
                msg = msg,
                bare = true,
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
    local isClassicEra = WhoDoesWhat.ClientFeatures.isClassicEra
    local curseIds = isClassicEra
        and { "curse_reck", "curse_elements", "curse_shadow" }
        or { "curse_reck", "curse_elements" }
    local function OtherCurseIds(rowId)
        local ids = {}
        for _, id in ipairs(curseIds) do
            if id ~= rowId then ids[#ids + 1] = id end
        end
        return ids
    end
    local reck = {
        id = "curse_reck",
        icon = curses.reck.icon,
        label = curses.reck.name_long,
        spellId = curses.reck.spellId,
        class = "Warlock",
        exclusiveWith = OtherCurseIds("curse_reck"),
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
        preferRoleId = not isClassicEra and "warlock_affl" or nil,
        exclusiveWith = OtherCurseIds("curse_elements"),
        GetWarning = function()
            local name = GetAssignment("curse_elements")
            if not name then
                return "No one is assigned to Curse of the Elements."
            end
            if not isClassicEra and WhoDoesWhat:GetAssignedRole(name) ~= "warlock_affl" then
                return name .. " is not marked as Affliction. Without Malediction,"
                    .. " Curse of the Elements is less effective."
            end
        end,
    }
    local shadow = curses.shadow and {
        id = "curse_shadow",
        icon = curses.shadow.icon,
        label = curses.shadow.name_long,
        spellId = curses.shadow.spellId,
        class = "Warlock",
        exclusiveWith = OtherCurseIds("curse_shadow"),
        GetWarning = function()
            if not GetAssignment("curse_shadow") then
                return "No one is assigned to Curse of Shadow."
            end
        end,
    }
    RowDefs[reck.id] = reck
    RowDefs[elements.id] = elements
    if shadow then RowDefs[shadow.id] = shadow end

    -- TBC prefers an Affliction warlock for Elements, then fills Recklessness.
    -- Classic fills Recklessness, Elements, then Shadow on distinct warlocks.
    -- The two Settings toggles gate magic curses and Recklessness separately;
    -- disabling one leaves its current picks untouched.
    function AutoAssignWarlockCurses() -- file-local, forward-declared above
        local settings = WhoDoesWhat.db.profile.settings
        local locks = MembersOfClass("Warlock")
        if #locks == 0 then
            WhoDoesWhat:Print("Warlock Curses: no warlocks in the group to auto-assign.")
            return
        end

        local store = WhoDoesWhat.db.profile.raidAssignments

        local elementsLock, shadowLock
        local reckLock = not settings.allowRecklessnessAutoAssign
            and store.curse_reck or nil
        if isClassicEra then
            if settings.autoAssignAfflictionElements then
                if settings.allowRecklessnessAutoAssign then
                    reckLock = locks[1]
                    store.curse_reck = reckLock
                end
                for _, name in ipairs(locks) do
                    if name ~= reckLock then
                        if not elementsLock then
                            elementsLock = name
                        elseif not shadowLock then
                            shadowLock = name
                            break
                        end
                    end
                end
                store.curse_elements = elementsLock
                store.curse_shadow = shadowLock
            else
                elementsLock = store.curse_elements
                shadowLock = store.curse_shadow
            end
        else
            elementsLock = store.curse_elements
            if settings.autoAssignAfflictionElements then
                elementsLock = nil
                for _, name in ipairs(locks) do
                    if name ~= reckLock
                        and WhoDoesWhat:GetAssignedRole(name) == "warlock_affl" then
                        elementsLock = name
                        break
                    end
                end
                if not elementsLock then
                    for _, name in ipairs(locks) do
                        if name ~= reckLock then
                            elementsLock = name
                            break
                        end
                    end
                end
                store.curse_elements = elementsLock
            end
        end

        if settings.allowRecklessnessAutoAssign and not reckLock then
            for _, name in ipairs(locks) do
                if name ~= elementsLock and name ~= shadowLock then
                    reckLock = name
                    break
                end
            end
            store.curse_reck = reckLock
        end

        local parts = {}
        if settings.autoAssignAfflictionElements then
            parts[#parts + 1] = elements.label .. " -> " .. (elementsLock or "nobody")
            if shadow then
                parts[#parts + 1] = shadow.label .. " -> "
                    .. (shadowLock or "nobody (no second warlock)")
            end
        end
        if settings.allowRecklessnessAutoAssign then
            parts[#parts + 1] = reck.label .. " -> "
                .. (reckLock or "nobody (no free warlock)")
        end
        if #parts == 0 then
            WhoDoesWhat:Print("Warlock Curses: curse auto-assigns are disabled in Settings.")
        else
            WhoDoesWhat:LogOperation("Warlock Curses auto-assigned: " .. table.concat(parts, ", ") .. ".")
        end
    end

    Sections = {
        -- Paladin blessings aren't stored in this assignment model. The
        -- section renders the active WDW/PallyPower plan as read-only rows.
        { title = "Paladin Buffs", rows = {} },
        { title = "Warlocks", rows = shadow and { reck, elements, shadow }
            or { reck, elements } },
    }
end

-- Named whisper collectors, one per section, so the section views (and any
-- future section) mail through a self-documenting call instead of passing
-- defs around. All are thin wrappers over the two generic collectors above.
local function CollectTankWhispers() return CollectDynamicWhispers(SectionByKey("tank")) end
local function CollectCCWhispers() return CollectDynamicWhispers(SectionByKey("cc")) end
local function CollectMisdirectWhispers() return CollectDynamicWhispers(SectionByKey("md")) end
local function CollectCurseWhispers() return CollectStaticWhispers(Sections[2]) end

-- Drop assignments whose player is no longer in the group, including assign
-- rules tied to a departed paladin. Roster lifecycle reconciliation calls this
-- outside the views, so opening a window is a pure read. Dynamic rows keep
-- their marker and spell; only the departed player is cleared. Read-only
-- clients never mutate the shared board as housekeeping.
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
            WhoDoesWhat:LogOperation(label .. " unassigned: " .. name .. " is no longer in the group.")
        end
    end

    for _, section in ipairs(DynamicSections) do
        for _, entry in ipairs(GetEntries(section)) do
            if entry.player and not present[entry.player] then
                WhoDoesWhat:LogOperation(section.title .. " (" .. EntryText(section, entry, TargetPlainText)
                    .. ") unassigned: " .. entry.player .. " is no longer in the group.")
                entry.player = nil
            end
            -- Player targets (a misdirect's tank) leave the group too.
            if entry.target and not present[entry.target] then
                WhoDoesWhat:LogOperation(section.title .. " target cleared: " .. entry.target
                    .. " is no longer in the group.")
                entry.target = nil
            end
        end
    end

    local rules = WhoDoesWhat.db.profile.paladinBuffRules
    for i = #rules, 1, -1 do
        local rule = rules[i]
        if rule.kind == "assign" and rule.value and not present[rule.value] then
            table.remove(rules, i)
            WhoDoesWhat:LogOperation("Paladin Buffs rule removed: " .. rule.value
                .. " is no longer in the group.")
        end
    end
end

-- Auto-row sections carry one row per roster member (misdirects: every
-- hunter; tanks: every marked tank), not rows the user adds by hand.
-- Reconcile the saved entries on model/lifecycle changes. Retained rows keep
-- their current order (assignments preserved), new members append a blank row
-- in roster order, and rows whose player left the roster drop -- unless
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

-- Keep all roster-derived board storage current without involving a view.
-- Explicit model actions may call this on any permitted editor; the automatic
-- roster event below elects the group leader as the sole housekeeping writer.
local function ReconcileRosterAssignments()
    PruneDepartedAssignments()
    EnsureAutoRows(SectionByKey("tank"))
    EnsureAutoRows(SectionByKey("md"))
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
        WhoDoesWhat:LogOperation(def.label .. " assigned to " .. playerName .. ".")
        for _, otherId in ipairs(def.exclusiveWith or {}) do
            if store[otherId] == playerName then
                store[otherId] = nil
                WhoDoesWhat:LogOperation(playerName .. " removed from " .. RowDefs[otherId].label .. ".")
            end
        end
        if def.pairWith and not store[def.pairWith] then
            store[def.pairWith] = playerName
            WhoDoesWhat:LogOperation(RowDefs[def.pairWith].label .. " also assigned to " .. playerName .. ".")
        end
    else
        WhoDoesWhat:LogOperation(def.label .. " assignment cleared.")
    end

    WhoDoesWhat:RefreshMainAssignmentsView()
    -- The buff grid mirrors the paladin-buff picks; keep it live.
    WhoDoesWhat:RefreshBuffingGridView()
end

-- When a warlock is detected (or respecs) into Affliction, hand them Curse of
-- the Elements so Malediction lands without anyone touching the board -- but
-- only when the setting is on, only with a second warlock present (so
-- Recklessness still has a caster), and only when Elements isn't already on an
-- Affliction warlock. Called from AutoAssignDetectedRole (TalentScanning.lua)
-- after the role is saved. Returns true if it moved the assignment.
local function AutoPlaceAfflictionElements(playerName)
    if WhoDoesWhat.ClientFeatures.isClassicEra then return false end
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
    WhoDoesWhat:LogOperation("Curse of the Elements auto-assigned to " .. playerName
        .. " (detected Affliction).")
    return true
end

-- One paladin's buffing jobs, grouped per CLASS -- the model behind the
-- Paladin Buffing Bar (Views/PaladinBuffingBarView.lua). Reads the active
-- WDW/PallyPower plan and collapses it into class Greaters plus per-player
-- Normal exceptions.
--
-- Hunter pets bucket under WARRIORS to match the client. They inherit the
-- Warrior Greater when it matches their cell; only dissenters enter the
-- right-click Lesser cycle. The Warrior button appears for pets even with no
-- warriors present.
--
-- Returns an array of per-class jobs (class-name sorted). Each member (raider
-- or pet) carries display name, buff key, live state, and -- for pets -- the
-- pet unit token to cast on:
--   { classInfo, greaterKey, greaterBuff, hasPets, hasNonPets,
--     normals  = { { name, key, buff, isPet, petUnit }, ... },  -- right-click
--     raiders  = { { name, key, has, isGreater, classInfo, isPet, owner, petUnit }, ... },
--     total, covered }
local function GetPaladinBuffJobs(paladinName, buffPlan)
    local canonical = WhoDoesWhat.CanonicalBuffOrder
    local canonIndex = {}
    for i, key in ipairs(canonical) do canonIndex[key] = i end

    local classOf = {}
    for _, m in ipairs(WhoDoesWhat:GetGroupMembers(nil)) do
        classOf[m.name] = m.classInfo
    end

    buffPlan = buffPlan or GetActivePaladinBuffPlan()
    local plan = buffPlan.grid
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
            c.members[#c.members + 1] = {
                statusName = raider, display = raider, key = key, classInfo = ci,
            }
            c.hasNonPets = true
        end
    end

    -- Hunter pets share the Warrior bucket; dissenters remain individual
    -- Lesser-blessing targets.
    local warriorCI = GetClassInfoByToken("WARRIOR")
    if warriorCI then
        local petInfo = WhoDoesWhat:GetPetUnitInfo()
        for _, pet in ipairs(GetPetMembers()) do
            local key = plan[pet.name] and plan[pet.name][paladinName]
            if key then
                local c = bucket(warriorCI)
                local info = petInfo[pet.owner]
                c.members[#c.members + 1] = {
                    statusName = pet.name, -- BuffTracking key: "<Owner>'s Pet"
                    -- Narrow fixed-width buttons: the bare pet name, no owner.
                    display = WhoDoesWhat:DisplayName(pet.name, true),
                    key = key, isPet = true, owner = pet.owner, classInfo = pet.classInfo,
                    petUnit = info and info.unit,
                }
                c.hasPets = true
            end
        end
    end

    local jobs = {}
    for _, c in pairs(byClass) do
        local greaterKey = buffPlan.greaterByPaladin[paladinName]
            and buffPlan.greaterByPaladin[paladinName][c.classInfo.name]

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
                isGreater = m.key == greaterKey,
                isPet = m.isPet, owner = m.owner, petUnit = m.petUnit,
                classInfo = m.classInfo,
            }
            job.total = job.total + 1
            if has == true then job.covered = job.covered + 1 end
            if m.key ~= greaterKey then
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
    -- section clears / auto-assigns (the views' header buttons)
    ClearTankAssignments = ClearTankAssignments,
    ClearMisdirectAssignments = ClearMisdirectAssignments,
    AutoAssignWarlockCurses = AutoAssignWarlockCurses,
    -- per-raider buff plan + per-paladin summary + custom rules
    BuffTalents = BuffTalents,
    GetPaladinBuffPriorityOrder = GetPaladinBuffPriorityOrder,
    GetPaladinBuffPlan = ComputePaladinBuffPlan,
    GetActivePaladinBuffPlan = GetActivePaladinBuffPlan,
    ComputeBuffGrid = ComputeBuffGrid,
    IsSimulatedPaladinBuff = IsSimulatedPaladinBuff,
    DisconnectedGroupTargets = DisconnectedGroupTargets,
    ComputePaladinBuffCoverage = ComputePaladinBuffCoverage,
    GetPaladinBuffWhisper = GetPaladinBuffWhisper,
    ComputeCoreRaidBuffCoverage = ComputeCoreRaidBuffCoverage,
    ComputeCoreBuffProviders = ComputeCoreBuffProviders,
    ComputePaladinBuffSummary = ComputePaladinBuffSummary,
    GetPaladinBuffJobs = GetPaladinBuffJobs,
    CollectPaladinBuffWhispers = CollectPaladinBuffWhispers,
    GetBuffRules = GetBuffRules,
    PvpSalvationIgnored = PvpSalvationIgnored,
    UnhandledDisabledPaladins = UnhandledDisabledPaladins,
    PaladinBuffSlots = PaladinBuffSlots,
    ShortAssignmentName = ShortAssignmentName,
    -- storage
    EnsureAutoRows = EnsureAutoRows,
    ReconcileRosterAssignments = ReconcileRosterAssignments,
    SetAssignment = SetAssignment,
    AutoPlaceAfflictionElements = AutoPlaceAfflictionElements,
}

-- Rendering must never mutate or synchronize the board. Roster events settle
-- here instead; one group writer prevents every permitted client from sending
-- the same housekeeping STATE. Fake Raid is the intentional solo exception.
local rosterReconcileFrame = CreateFrame("Frame")
rosterReconcileFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
rosterReconcileFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
local ROSTER_RECONCILE_DELAY = 3
local rosterReconcileGeneration = 0
rosterReconcileFrame:SetScript("OnEvent", function()
    rosterReconcileGeneration = rosterReconcileGeneration + 1
    local generation = rosterReconcileGeneration
    C_Timer.After(ROSTER_RECONCILE_DELAY, function()
        if generation ~= rosterReconcileGeneration or not WhoDoesWhat.db then return end
        local fake = WhoDoesWhat.FakeRaid and WhoDoesWhat:IsFakeRaidEnabled()
        if not IsInGroup() and not fake then return end
        if IsInGroup() and not UnitIsGroupLeader("player") then return end
        ReconcileRosterAssignments()
        WhoDoesWhat:RefreshMainAssignmentsView()
    end)
end)

-- Zoning into (or out of) a battleground silently changes the plan via the
-- implicit Salvation rule, so repaint off the plan hook. The plan cache keys
-- on the rule-adjusted orders, so it invalidates itself.
local pvpRuleFrame = CreateFrame("Frame")
pvpRuleFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
pvpRuleFrame:SetScript("OnEvent", function()
    if not WhoDoesWhat.db then return end
    WhoDoesWhat:RefreshMainAssignmentsView()
    WhoDoesWhat:RefreshBuffingGridView()
end)
