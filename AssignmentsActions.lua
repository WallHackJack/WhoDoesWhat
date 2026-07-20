local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Unit right-click menu integration for the assignments board, consumed by
-- UnitMenuExtensions.lua and split out of MainAssignmentsView.lua so that file stays
-- UI-only. The shared model lives in Assignments.lua (WhoDoesWhat.Assign).

local A = WhoDoesWhat.Assign
local DynamicSections = A.DynamicSections
local GetEntries = A.GetEntries
local EntryText = A.EntryText
local TargetPlainText = A.TargetPlainText
local SpellById = A.SpellById
local MarkerByIndex = A.MarkerByIndex
local GetEligibleMembers = A.GetEligibleMembers

-- The menu doesn't list the saved rows; it offers the full skull-through-star
-- grid (tanks: multi-select; CC: one target per spell) and maps each pick
-- onto the stored entries: overwrite the row already covering that slot,
-- create one when none does. Clicking a slot this player already holds toggles
-- it off, deleting that row (RemoveTankMarker / RemoveCCAssignment) -- the same
-- effect as the window's [x].

local function SectionByKey(key)
    for _, section in ipairs(DynamicSections) do
        if section.key == key then return section end
    end
end

local function PrintAssignment(section, entry)
    WhoDoesWhat:Print(section.title .. ": " .. entry.player .. " -> "
        .. EntryText(section, entry, TargetPlainText) .. ".")
end

-- The tank row covering a marker (first one wins if the window holds
-- duplicates), or nil.
local function TankEntryForMarker(markerIndex)
    for _, entry in ipairs(GetEntries(SectionByKey("tank"))) do
        if entry.marker == markerIndex then return entry end
    end
end

function WhoDoesWhat:GetTankMarkerAssignee(markerIndex)
    local entry = TankEntryForMarker(markerIndex)
    return entry and entry.player or nil
end

-- The raid markers a player is assigned to tank, in row order -- numeric only,
-- so the "Everything else"/custom pseudo-markers are skipped. Misdirects
-- inherit from these: a hunter follows their tank onto the tank's first marker.
function WhoDoesWhat:TankMarkers(tankName)
    local out = {}
    if not tankName then return out end
    for _, entry in ipairs(GetEntries(SectionByKey("tank"))) do
        if entry.player == tankName and type(entry.marker) == "number" then
            out[#out + 1] = entry.marker
        end
    end
    return out
end

function WhoDoesWhat:FirstTankMarker(tankName)
    return self:TankMarkers(tankName)[1]
end

-- Pull every misdirect aimed at a tank onto that tank's first marker, so a
-- hunter's misdirect follows when the tank's marker is (re)assigned. A nil
-- first marker (the tank lost all its markers) clears the misdirect's marker.
function WhoDoesWhat:SyncMisdirectsForTank(tankName)
    if not tankName then return end
    local marker = self:FirstTankMarker(tankName)
    for _, entry in ipairs(GetEntries(SectionByKey("md"))) do
        if entry.target == tankName then
            entry.marker = marker
        end
    end
end

-- The reverse: when a tank is assigned to a marker, adopt any misdirect that
-- was already set to that marker but had no tank picked yet, pointing it at the
-- new tank. Only fills empty targets -- it never steals a misdirect off another
-- tank.
function WhoDoesWhat:AdoptMisdirectsForMarker(markerIndex, tankName)
    if not (markerIndex and tankName) then return end
    for _, entry in ipairs(GetEntries(SectionByKey("md"))) do
        if entry.marker == markerIndex and not entry.target then
            entry.target = tankName
        end
    end
end

-- Put a player on a tank marker -- replacing whoever held it, creating the
-- row when none covers that marker yet -- or clear the marker with nil.
-- All four setters below are permission-gated: the unit menu renders
-- read-only without edit rights, and this backstops it.
function WhoDoesWhat:SetTankMarkerPlayer(markerIndex, playerName)
    if not self:RequireEditPermission() then return end
    local section = SectionByKey("tank")
    local entry = TankEntryForMarker(markerIndex)
    if not entry then
        if not playerName then return end
        entry = { marker = markerIndex, custom = "" }
        local entries = GetEntries(section)
        entries[#entries + 1] = entry
    end
    if entry.player == playerName then return end
    local prev = entry.player
    entry.player = playerName
    if playerName then
        PrintAssignment(section, entry)
    else
        WhoDoesWhat:Print(section.title .. ": "
            .. EntryText(section, entry, TargetPlainText) .. " cleared.")
    end
    -- The displaced tank and the new one both changed marker coverage; pull
    -- their misdirects along, and adopt any tank-less misdirect on this marker.
    self:SyncMisdirectsForTank(prev)
    self:SyncMisdirectsForTank(playerName)
    self:AdoptMisdirectsForMarker(markerIndex, playerName)
    WhoDoesWhat:RefreshMainAssignmentsView()
end

-- Delete the tank row covering a marker outright (the unit menu's toggle-off
-- removes the row rather than just blanking its player). No-op without edit
-- rights or when no row holds the marker.
function WhoDoesWhat:RemoveTankMarker(markerIndex)
    if not self:RequireEditPermission() then return end
    local section = SectionByKey("tank")
    local entries = GetEntries(section)
    for i, entry in ipairs(entries) do
        if entry.marker == markerIndex then
            local prev = entry.player
            table.remove(entries, i)
            self:SyncMisdirectsForTank(prev)
            WhoDoesWhat:Print(section.title .. ": " .. section.noun .. " removed.")
            WhoDoesWhat:RefreshMainAssignmentsView()
            return
        end
    end
end

function WhoDoesWhat:GetCCAssignee(spellId, markerIndex)
    for _, entry in ipairs(GetEntries(SectionByKey("cc"))) do
        if entry.spell == spellId and entry.marker == markerIndex then
            return entry.player
        end
    end
end

-- The marker a player currently holds for a spell (nil = none); drives the
-- menu's per-spell None state.
function WhoDoesWhat:GetPlayerCCTarget(spellId, playerName)
    for _, entry in ipairs(GetEntries(SectionByKey("cc"))) do
        if entry.spell == spellId and entry.player == playerName then
            return entry.marker
        end
    end
end

-- Assign a player to cast a spell on a marker: overwrites the identical row
-- (same spell + marker) when the window already has one, otherwise fills a
-- spell-less placeholder row already on that marker, and only creates a new
-- row when neither exists. Frees any other target the player held for that
-- spell -- one mage, one sheep. markerIndex = nil clears the player's
-- assignment for the spell entirely.
function WhoDoesWhat:SetCCAssignment(spellId, markerIndex, playerName)
    if not self:RequireEditPermission() then return end
    local section = SectionByKey("cc")
    local entries = GetEntries(section)

    local changed = false
    for _, entry in ipairs(entries) do
        if entry.spell == spellId and entry.player == playerName
            and entry.marker ~= markerIndex then
            entry.player = nil
            changed = true
        end
    end

    if markerIndex then
        -- Prefer the identical row (same spell + marker) to overwrite; failing
        -- that, reuse a row already on this marker that has no ability picked
        -- yet (a placeholder to be filled) rather than adding a duplicate.
        local target, blank
        for _, entry in ipairs(entries) do
            if entry.marker == markerIndex then
                if entry.spell == spellId then
                    target = entry
                    break
                elseif not entry.spell and not blank then
                    blank = entry
                end
            end
        end
        target = target or blank
        if not target then
            target = { marker = markerIndex, custom = "" }
            entries[#entries + 1] = target
        end
        if target.spell ~= spellId then
            target.spell = spellId
            changed = true
        end
        if target.player ~= playerName then
            target.player = playerName
            changed = true
        end
        if changed then
            PrintAssignment(section, target)
        end
    elseif changed then
        local spell = SpellById(spellId)
        WhoDoesWhat:Print(section.title .. ": " .. playerName
            .. " no longer assigned to " .. (spell and spell.name or "?") .. ".")
    end

    if changed then
        WhoDoesWhat:RefreshMainAssignmentsView()
    end
end

-- Delete the CC row for a spell on a marker outright (the unit menu's
-- toggle-off removes the row rather than just clearing the player). No-op
-- without edit rights or when no such row exists.
function WhoDoesWhat:RemoveCCAssignment(spellId, markerIndex)
    if not self:RequireEditPermission() then return end
    local section = SectionByKey("cc")
    local entries = GetEntries(section)
    for i, entry in ipairs(entries) do
        if entry.spell == spellId and entry.marker == markerIndex then
            table.remove(entries, i)
            WhoDoesWhat:Print(section.title .. ": " .. section.noun .. " removed.")
            WhoDoesWhat:RefreshMainAssignmentsView()
            return
        end
    end
end

-- Group members in the shape the window's dropdowns use ({ name, classInfo }
-- entries, sorted), for the unit menu's misdirect pickers. Class filter and
-- the Developer Mode lift included.
function WhoDoesWhat:GetGroupMembers(onlyClassName)
    return GetEligibleMembers(onlyClassName)
end

-- The tank a hunter is assigned to misdirect onto, or nil.
function WhoDoesWhat:GetMisdirectTarget(hunterName)
    for _, entry in ipairs(GetEntries(SectionByKey("md"))) do
        if entry.player == hunterName and entry.target then
            return entry.target
        end
    end
end

-- The hunter's misdirect row (first one wins; freeExtras also clears the
-- player off any panel-made duplicate rows). Returns row, freedAny.
local function MisdirectRowFor(hunterName, freeExtras)
    local mine, freed
    for _, entry in ipairs(GetEntries(SectionByKey("md"))) do
        if entry.player == hunterName then
            if not mine then
                mine = entry
            elseif freeExtras then
                entry.player = nil
                freed = true
            end
        end
    end
    return mine, freed
end

-- Point a hunter's misdirect at a tank (nil clears it). One tank per hunter:
-- the hunter's existing row is retargeted in place -- defaulting its marker to
-- the tank's first marker -- rather than swapped for another row. A hunter
-- without a row claims an unmanned row already aimed at that tank before
-- creating a fresh one; rows are never deleted here.
function WhoDoesWhat:SetMisdirectTarget(hunterName, tankName)
    if not self:RequireEditPermission() then return end
    local section = SectionByKey("md")
    local entries = GetEntries(section)
    local mine, freed = MisdirectRowFor(hunterName, true)

    if not tankName then
        if mine then
            mine.player = nil
            freed = true
            WhoDoesWhat:Print(section.title .. ": " .. hunterName .. "'s misdirect cleared.")
        end
    elseif not mine or mine.target ~= tankName then
        if not mine then
            for _, entry in ipairs(entries) do
                if entry.target == tankName and not entry.player then
                    mine = entry
                    break
                end
            end
            if not mine then
                mine = {}
                entries[#entries + 1] = mine
            end
            mine.player = hunterName
        end
        mine.target = tankName
        mine.marker = self:FirstTankMarker(tankName) -- default to the tank's marker
        PrintAssignment(section, mine)
        freed = true -- repaint either way
    end

    if freed then
        WhoDoesWhat:RefreshMainAssignmentsView()
    end
end

-- The optional raid marker on a hunter's misdirect, or nil.
function WhoDoesWhat:GetMisdirectMarker(hunterName)
    local mine = MisdirectRowFor(hunterName)
    return mine and mine.marker or nil
end

-- Set (nil clears) the optional marker on a hunter's misdirect. A hunter
-- with no row yet gets one created marker-first, so the pick isn't lost --
-- the tank can be chosen after (the row warns until it is).
function WhoDoesWhat:SetMisdirectMarker(hunterName, markerIndex)
    if not self:RequireEditPermission() then return end
    local section = SectionByKey("md")
    local mine = MisdirectRowFor(hunterName)
    if not mine then
        if not markerIndex then return end
        mine = { player = hunterName }
        local entries = GetEntries(section)
        entries[#entries + 1] = mine
    end
    if mine.marker == markerIndex then return end
    mine.marker = markerIndex
    if not markerIndex then
        WhoDoesWhat:Print(section.title .. ": " .. hunterName .. "'s marker cleared.")
    elseif mine.target then
        PrintAssignment(section, mine)
    else
        local m = MarkerByIndex(markerIndex)
        WhoDoesWhat:Print(section.title .. ": " .. hunterName .. " -> "
            .. (m and m.name or "?") .. " (no tank picked yet).")
    end
    WhoDoesWhat:RefreshMainAssignmentsView()
end
