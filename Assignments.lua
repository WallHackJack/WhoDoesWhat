local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Assignment model for the main /wdw window -- the non-UI half of what used
-- to be one large MainAssignmentsView.lua: group-member helpers, marker /
-- spell / target text, the dynamic + static section definitions, whisper
-- collectors, the paladin buff-talent demand math, the auto-assigns, and the
-- saved-assignment storage. Everything is exported on WhoDoesWhat.Assign
-- (see the bottom); the view and UnitMenuExtensions.lua re-localize what
-- they use. Nothing here creates frames; repaints go through the views'
-- public Refresh methods, which no-op while their window is closed.

-- Column id for the static sections' `column` field; matches the view's
-- COL_RIGHT geometry constant.
local COL_RIGHT = 2

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
local function PlayerTextWithRole(name)
    return RoleIconMarkup(name) .. PlayerText(name)
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

-- Collapsed marker-dropdown text: the bare icon, since the box is only wide
-- enough for one (the menu items themselves keep their names). Custom borrows
-- the addon's "?" icon. "Everything else" has no icon to stand in for it, so
-- it spells itself out and widens its box -- see TANK_MARKER_DD_WIDE.
local function TargetText(entry)
    if entry.marker == "custom" then
        return "|T" .. CUSTOM_TARGET_ICON .. ":14:14:0:0|t"
    elseif entry.marker == "all" then
        return "Everything else"
    end
    local m = MarkerByIndex(entry.marker)
    return m and MarkerMarkup(m.index, 14) or "?"
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
    if entry.marker == "custom" then
        return (entry.custom and entry.custom ~= "") and entry.custom or "Custom"
    elseif entry.marker == "all" then
        return "Everything else"
    end
    local m = MarkerByIndex(entry.marker)
    return m and m.name or "?"
end

-- Target text for whispers: chat's own raid-marker tokens, which the
-- receiving client expands into the real icon. The eight valid tokens are
-- exactly our lowercased marker names ({skull}, {cross}, {star}, ...).
-- Custom / Everything else have no icon, so they stay as words. Player
-- targets (Misdirects) lead with the name, marker token after when set.
local function TargetChatText(entry)
    local m = (entry.marker ~= "custom" and entry.marker ~= "all")
        and MarkerByIndex(entry.marker) or nil
    local token = m and ("{" .. m.name:lower() .. "}")
    if entry.target then
        return token and (entry.target .. " " .. token) or entry.target
    end
    return token or TargetPlainText(entry)
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

-- ---------------------------------------------------------------------------
-- Dynamic section definitions
--
--   key         unique prefix for global widget names
--   title       section box title
--   store       db.profile key holding this section's entry array
--   noun        used in the empty hint, the [+] tooltip and Print lines
--   whisperLead text leading the compiled list in the whisper
--   spells      optional spell list; its presence adds the spell dropdown and
--               gives entries a .spell field (a CCSpells id)
--   allowAll    include "Everything else" in the marker dropdown
--   clearAll    header "X" button that removes every row in the section
--               (behind a confirm popup)
--   playerClass optional class filter for the player dropdown ("Hunter";
--               Developer Mode lifts it like every other class filter)
--   targetPlayer entries target a group member (entry.target, a player name)
--               instead of a raid marker: the marker dropdown and custom text
--               box are replaced by a second player picker plus a compact
--               optional-marker picker (entry.marker = 1..8 or nil)
--   IsPreferred(member, entry) floats a member to the top of the player list
--   IsPreferredTarget(member)  same, for the target picker (targetPlayer only)
--   GetWarning(entry)          row warning text, or nil when all is well
-- ---------------------------------------------------------------------------

local DynamicSections = {
    {
        key = "tank",
        title = "Tank Assignments",
        store = "tankAssignments",
        noun = "tank assignment",
        whisperLead = "Tank ",
        allowAll = true,
        clearAll = true,
        IsPreferred = function(m) return WhoDoesWhat:IsMarkedTank(m.name) end,
        GetWarning = function(entry)
            if entry.player and not WhoDoesWhat:IsMarkedTank(entry.player) then
                return entry.player .. " is not marked as a tank. Assign them a"
                    .. " tank role from the unit right-click menu."
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
        allowAll = false, -- CC lands on one target; there's no "everything else"
        clearAll = true,
        IsPreferred = function(m, entry)
            local spell = SpellById(entry.spell)
            return spell ~= nil and m.classInfo.name == spell.class
        end,
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
        title = "Misdirect Assignments",
        store = "mdAssignments",
        noun = "misdirect assignment",
        whisperLead = "Misdirect to ",
        playerClass = "Hunter",
        targetPlayer = true,
        IsPreferredTarget = function(m) return WhoDoesWhat:IsMarkedTank(m.name) end,
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
        end,
    },
}

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

-- Distinct assigned players in a dynamic section, whispers in chat-token form.
local function CollectDynamicWhispers(section)
    local seen, out = {}, {}
    for _, entry in ipairs(GetEntries(section)) do
        if entry.player and not seen[entry.player] then
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

    local order, inOrder = {}, {}
    for _, rule in ipairs(prioritized) do
        if not ignored[rule.buff] and not inOrder[rule.buff]
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
-- The pick itself mirrors the retired Auto-assign: raiders vote for the top
-- N buffs of their priority order (N = paladin count), the N most-demanded
-- castable buffs win one paladin each, and casters match scarcity-first --
-- the talent-granted blessings have the fewest possible casters, the
-- Improved ones want their best specialists, and Salvation/Light take
-- whoever's left. A chosen gated buff with no talented caster forfeits its
-- slot to the next-demanded buff.
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
    local used, lockedBuff, lockedCount = {}, {}, 0
    for _, name in ipairs(pool) do
        local buff = preferred[name]
        if buff and not ignored[buff] and not lockedBuff[buff] then
            primary[name] = buff
            forced[name] = buff
            used[name] = true
            lockedBuff[buff] = true
            lockedCount = lockedCount + 1
        end
    end
    local freeSlots = math.max(slots - lockedCount, 0)

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

    -- The available buffs by demand (ties break canonical, itself roughly
    -- importance-ordered).
    local canonIndex = {}
    for i, key in ipairs(canonical) do canonIndex[key] = i end
    local demand = {}
    for _, key in ipairs(avail) do demand[#demand + 1] = key end
    table.sort(demand, function(a, b)
        if votes[a] ~= votes[b] then return votes[a] > votes[b] end
        return canonIndex[a] < canonIndex[b]
    end)
    local demandIndex = {}
    for i, key in ipairs(demand) do demandIndex[key] = i end

    local function Gated(key)
        local meta = BuffTalents[key]
        return meta ~= nil and meta.maxRank == 1
    end
    local function AnyTalented(key)
        for _, name in ipairs(pool) do
            if not used[name] and (BuffTalentRank(name, key) or 0) > 0 then
                return true
            end
        end
        return false
    end

    -- The winners: the `freeSlots` most-demanded unlocked buffs someone in
    -- the free pool can cast.
    local chosen, chosenSet = {}, {}
    for _, key in ipairs(demand) do
        if #chosen == freeSlots then break end
        if not lockedBuff[key] and (not Gated(key) or AnyTalented(key)) then
            chosen[#chosen + 1] = key
            chosenSet[key] = true
        end
    end

    -- Scarcity order for the caster matching; equal scarcity falls back to
    -- demand order.
    local scarcity = { kings = 1, sanctuary = 1, might = 2, wisdom = 2 }
    table.sort(chosen, function(a, b)
        local sa, sb = scarcity[a] or 3, scarcity[b] or 3
        if sa ~= sb then return sa < sb end
        return demandIndex[a] < demandIndex[b]
    end)

    -- Chosen buffs first, then the also-rans as backfill for any slot a
    -- chosen buff has to forfeit. Locked buffs are neither: already placed.
    local sequence = {}
    for _, key in ipairs(chosen) do sequence[#sequence + 1] = key end
    for _, key in ipairs(demand) do
        if not chosenSet[key] and not lockedBuff[key] then
            sequence[#sequence + 1] = key
        end
    end

    local function BestCaster(key)
        local gated = Gated(key)
        local bestName, bestRank
        for _, name in ipairs(pool) do
            if not used[name] then
                local rank = BuffTalentRank(name, key) or 0
                if not (gated and rank == 0)
                    and (not bestName or rank > bestRank) then
                    bestName, bestRank = name, rank
                end
            end
        end
        return bestName
    end

    local placed = 0
    for _, key in ipairs(sequence) do
        if placed == freeSlots then break end
        local caster = BestCaster(key)
        if caster then
            primary[caster] = key
            used[caster] = true
            placed = placed + 1
        end
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
--   Section fields: title, rows, column, plus optionally:
--     AutoAssign() (+ autoTooltip)  one-click fills the section's rows from
--                   the group; a header "Auto" button appears when set
--     gridButton    header "Info + Grid" button opening the combined paladin
--                   info + buff grid window
--     paladinSummary  the section has NO assignment rows; the view renders
--                   one computed read-only row per paladin instead
--                   (ComputePaladinBuffSummary) -- who blesses how many
--                   raiders with what, derived, never stored
--     disableWhenNoClass  class name; the whole section grays out (dead
--                   dropdowns/buttons, desaturated rows) while the group
--                   has nobody of that class (Developer Mode keeps it live)
-- ---------------------------------------------------------------------------

local RowDefs = {} -- row id -> definition, for cross-row lookups
local Sections     -- ordered { title, rows, column } section list

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
    local function AutoAssignWarlockCurses()
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
        -- roster, roles and talents (ComputeBuffGrid), and this section shows
        -- the result: one read-only row per paladin with their blessing
        -- workload. rows stays empty; the view builds pooled paladin rows.
        {
            title = "Paladin Buffs", rows = {}, column = COL_RIGHT,
            paladinSummary = true,
            gridButton = true, -- header button opening the info + grid window
            disableWhenNoClass = "Paladin", -- gray the section out sans paladins
        },
        {
            title = "Warlock Curses", rows = { reck, elements }, column = COL_RIGHT,
            calcButton = true, -- header button opening the Curse Value Calculator
            AutoAssign = AutoAssignWarlockCurses,
            autoTooltip = "Put Curse of the Elements on an Affliction warlock"
                .. " and Curse of Recklessness on another warlock. Each curse"
                .. " is gated by its Settings toggle; a disabled one keeps its"
                .. " current pick.",
        },
    }
end

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

-- ---------------------------------------------------------------------------
-- Exports: the shared vocabulary the view and the unit-menu API re-localize.
-- ---------------------------------------------------------------------------

WhoDoesWhat.Assign = {
    -- group members / text
    DevMode = DevMode,
    GetEligibleMembers = GetEligibleMembers,
    FindMember = FindMember,
    MembersOfClass = MembersOfClass,
    PlayerText = PlayerText,
    PlayerTextWithRole = PlayerTextWithRole,
    RoleIconMarkup = RoleIconMarkup,
    GetAssignment = GetAssignment,
    -- marker / spell / target
    MarkerMarkup = MarkerMarkup,
    MarkerByIndex = MarkerByIndex,
    TargetText = TargetText,
    TargetPlainText = TargetPlainText,
    TargetChatText = TargetChatText,
    SpellText = SpellText,
    SpellById = SpellById,
    SpellsForEntry = SpellsForEntry,
    ClearSpellIfUncastable = ClearSpellIfUncastable,
    -- sections + entries
    DynamicSections = DynamicSections,
    Sections = Sections,
    RowDefs = RowDefs,
    GetEntries = GetEntries,
    EntryText = EntryText,
    PlayerEntriesText = PlayerEntriesText,
    FirstUnusedMarker = FirstUnusedMarker,
    -- whispers
    CollectDynamicWhispers = CollectDynamicWhispers,
    CollectStaticWhispers = CollectStaticWhispers,
    MassWhisper = MassWhisper,
    -- per-raider buff plan + per-paladin summary + custom rules
    BuffTalents = BuffTalents,
    ComputeBuffGrid = ComputeBuffGrid,
    ComputePaladinBuffSummary = ComputePaladinBuffSummary,
    CollectPaladinBuffWhispers = CollectPaladinBuffWhispers,
    GetBuffRules = GetBuffRules,
    -- storage
    PruneDepartedAssignments = PruneDepartedAssignments,
    SetAssignment = SetAssignment,
    AutoPlaceAfflictionElements = AutoPlaceAfflictionElements,
}
