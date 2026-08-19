local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- The roster-issues model: everything wrong with a group member, derived from
-- the roster, the board and the last talent scan. No frames -- Views/
-- MembersView.lua draws one warning icon per member off this, and both the main
-- window's Members button and the WDW Status row read the counts from here.
--
-- This used to back a separate Action Items window, which was the Members
-- window filtered to the rows with a problem: the same roster line, the same
-- class tinting, the same role dropdown. The two merged, so what survives here
-- is the judging -- what counts as wrong and how to say it -- while the drawing
-- all lives in one view.
--
-- Five things put an issue on a player:
--   * PENDING: no WDW role at all -- not scanned, not assigned. Blizzard drops
--     every new raider on DAMAGER, so this is the bulk of the list when a raid
--     first forms, and it's the one you actually work down.
--   * STALE ROLE: a saved role id that no longer resolves (a deleted custom
--     role). Not "unassigned" -- it needs a new pick, so it says so.
--   * DISAGREEMENT: the group flag, the board and the talent scan state the
--     same fact and don't match. See RowDisagreements for which of the three
--     gets blamed.
--   * UNSET FLAG: on the board, but Blizzard has no flag for them at all. A
--     kicked-and-reinvited player lands here, since a kick clears the flag.
--     Compared against nothing above -- an absent flag isn't a wrong answer --
--     so it needs saying outright.
--   * UNPROMOTED TANK: a raid tank nobody promoted to Main Tank. Advisory:
--     SetPartyAssignment is a Blizzard-UI-only action, so no addon can do it.
--
-- Solo, the flag-derived issues are skipped: outside a group Blizzard reports
-- your own flag as NONE, which would be a permanent complaint about a flag that
-- means nothing until you're grouped. Fake raiders (FakeRaid.lua) skip them
-- too -- they have no unit, so there is no flag to read or promotion to check.

-- Blizzard's group-role token to our wowRole string. Shared with the view,
-- which uses it to tick the right entry in the group-role dropdown.
WhoDoesWhat.BLIZZ_ROLE_TO_WOW_ROLE = {
    TANK = "tank", HEALER = "healer", DAMAGER = "dps",
}
local BLIZZ_TO_WOW = WhoDoesWhat.BLIZZ_ROLE_TO_WOW_ROLE

-- Stable player key for a unit: "Name" same-realm, "Name-Realm" foreign.
-- Matches the keying used by db.profile.assignments.
local function UnitKey(unit)
    local name, realm = UnitName(unit)
    if not name then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- Player key -> unit token, in one roster walk. The view needs a unit per row
-- (to write the Blizzard flag, to read talents, to rescan) and resolving them
-- one name at a time re-walked the roster per row, which is quadratic on a
-- 40-man list. Fake raiders simply have no entry.
local function UnitsByName()
    local map = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            local key = UnitExists(unit) and UnitKey(unit)
            if key then map[key] = unit end
        end
        return map
    end
    local selfKey = UnitKey("player")
    if selfKey then map[selfKey] = "player" end
    for i = 1, GetNumSubgroupMembers() do
        local unit = "party" .. i
        local key = UnitExists(unit) and UnitKey(unit)
        if key then map[key] = unit end
    end
    return map
end

-- ---------------------------------------------------------------------------
-- Agreement between a player's three answers
--
-- The same fact is stated three times -- Blizzard's flag, the board, and the
-- last talent scan -- and the point of the window is the places they disagree.
-- The three are compared pairwise, and the blame goes on the ODD ONE OUT: a
-- resto shaman the board and his talents both call Restoration, flagged
-- DAMAGER, has one thing wrong with him, and naming all three makes the reader
-- do the elimination this already did.
--
-- The rule is a plain majority. Each answer counts how many of the others it
-- agrees with; anything below the best score, and in a disagreement, earns a
-- line. Two answers that disagree with nothing else to break the tie blame BOTH
-- -- there genuinely is no odd one out -- and so does a three-way split, where
-- nobody scores an agreement at all.
--
-- Only answers we actually have take part. A player nobody has inspected, or a
-- flag Blizzard never set, is unknown rather than wrong, and a warning on top of
-- that would fire on most of the roster the moment a raid forms. So does a pair
-- that can't be compared: the group flag only ever names tank/healer/dps, so it
-- is compared at that coarseness, and a role the points can't name
-- (warlock_firetank, custom roles) can't be argued with by the scan in either
-- direction.
-- ---------------------------------------------------------------------------

local function WowRoleName(wowRole)
    local meta = wowRole and WhoDoesWhat.BasicWowRoles[wowRole]
    return meta and meta.name or nil
end

-- The three comparisons, in the order the counts below walk them.
local COMPARISONS = {
    { "group", "wdw" }, { "group", "talent" }, { "wdw", "talent" },
}

local function Reason(others, agreed, best, lead)
    if #others == 0 then return nil end
    -- Outvoted, or nothing to be outvoted by.
    if best > 0 and agreed >= best then return nil end
    return lead .. table.concat(others, " and ") .. "."
end

-- Reason strings for the three answers, nil where that one is right, alone, or
-- unknown. All three land in the same tooltip now, so they read as sentences
-- rather than as a hint attached to a column.
local function RowDisagreements(data, talentRoles)
    local groupWow = data.blizzRole and BLIZZ_TO_WOW[data.blizzRole] or nil
    local wdwWow = data.role and data.role.wowRole or nil
    local haveTalents = #talentRoles > 0

    local talentMatchesGroup, talentMatchesWdw = false, false
    local talentNames = {}
    for _, role in ipairs(talentRoles) do
        if role.wowRole == groupWow then talentMatchesGroup = true end
        if role.id == data.roleId then talentMatchesWdw = true end
        talentNames[#talentNames + 1] = role.name
    end
    local talentName = table.concat(talentNames, " / ")

    -- Can the scan judge the role on the board at all? Where it can't, it must
    -- not argue with the flag either -- a Fire Tank warlock's points read as
    -- destro DPS forever, and blaming his TANK flag for that is a warning that
    -- can never be cleared.
    local judgeable = WhoDoesWhat:TalentsCanJudgeRole(data.roleId)
    local comparable = {
        (groupWow and wdwWow) and true or false,
        (groupWow and haveTalents and (not data.roleId or judgeable)) and true or false,
        (haveTalents and judgeable) and true or false,
    }
    local agrees = {
        groupWow == wdwWow,
        talentMatchesGroup,
        talentMatchesWdw,
    }

    local describes = {
        group = "their group role (" .. (WowRoleName(groupWow) or "none") .. ")",
        wdw = "the WhoDoesWhat role (" .. (data.role and data.role.name or "none") .. ")",
        talent = "their talents (" .. talentName .. ")",
    }
    local agreed = { group = 0, wdw = 0, talent = 0 }
    local against = { group = {}, wdw = {}, talent = {} }
    for i = 1, #COMPARISONS do
        if comparable[i] then
            local a, b = COMPARISONS[i][1], COMPARISONS[i][2]
            if agrees[i] then
                agreed[a] = agreed[a] + 1
                agreed[b] = agreed[b] + 1
            else
                against[a][#against[a] + 1] = describes[b]
                against[b][#against[b] + 1] = describes[a]
            end
        end
    end

    local best = math.max(agreed.group, agreed.wdw, agreed.talent)
    return Reason(against.group, agreed.group, best,
            "Group role (" .. (WowRoleName(groupWow) or "none")
                .. ") disagrees with "),
        Reason(against.wdw, agreed.wdw, best,
            "WhoDoesWhat role (" .. (data.role and data.role.name or "none")
                .. ") disagrees with "),
        Reason(against.talent, agreed.talent, best,
            "Talents read as " .. talentName .. ", which disagrees with ")
end

-- ---------------------------------------------------------------------------
-- Permission
-- ---------------------------------------------------------------------------

-- Writing another member's Blizzard flag needs BOTH: the WoW rank that lets the
-- server accept it at all (raid assist / party lead), and our single-writer
-- election on top, so ten assistants don't all set flags at once. Your own is
-- always yours.
--
-- The rank half is stated here rather than left to the election because the two
-- can disagree loudly: board permissions read wide open when the raid leader
-- has no WhoDoesWhat, which is precisely when a plain raider looks permitted
-- and can still change nobody's flag.
function WhoDoesWhat:CanEditGroupRoleOf(unit)
    if not unit then return false end
    if UnitIsUnit(unit, "player") then return true end
    return self:PlayerCanSetGroupRoles(UnitName("player"))
        and self:CanSetOthersBlizzardRole()
end

-- The key that opens Blizzard's social/raid panel, rendered the way the game's
-- own tips do it: yellow, in brackets. Read at build time -- a keybinding can
-- change under an open window -- and simply omitted when unbound. The raid tab
-- has had its own binding name on some builds and not others, so try that first
-- and fall back to the socials panel it lives in.
local RAID_PANEL_BINDINGS = { "TOGGLERAIDTAB", "TOGGLESOCIAL" }

local function RaidPanelKeyMarkup()
    if not GetBindingKey then return "" end
    for _, binding in ipairs(RAID_PANEL_BINDINGS) do
        local key = GetBindingKey(binding)
        if key and key ~= "" then
            local shown = GetBindingText and GetBindingText(key, "KEY_") or key
            return " |cffffd100[" .. shown .. "]|r"
        end
    end
    return ""
end

-- ---------------------------------------------------------------------------
-- The pass
-- ---------------------------------------------------------------------------

-- Everything the Members window needs about every group member, keyed by player
-- key, plus the two counts the toolbar button and the status row advertise.
--
-- Each entry carries the row's raw material -- unit, saved role, Blizzard flag,
-- talent snapshot and the roles that snapshot names -- alongside its `issues`
-- list, so the view resolves none of it a second time. Members with nothing
-- wrong still get an entry with an empty list; the view draws every one of them.
--
-- The two counts differ for an unpermitted raider, and that gap is the whole
-- point: they still get an honest count of what's outstanding, but nothing
-- glows at them, because none of it is theirs to fix. Promotions count for
-- anyone who could actually promote -- leader or assistant, the same rule the
-- promote-watch arrow fires on.
function WhoDoesWhat:GetRosterIssues()
    local byName, total, actionable = {}, 0, 0
    if not self.db then return byName, total, actionable end

    local units = UnitsByName()
    local inGroup = IsInGroup()
    local inRaid = IsInRaid()
    local canPromote = self:CanPromoteMainTank()
    local haveRoleApi = UnitGroupRolesAssigned ~= nil

    for _, m in ipairs(self:GetGroupMembers(nil)) do
        local unit = units[m.name]
        -- A fake raider has no unit, so every flag- and promotion-derived
        -- question below is unanswerable rather than failing.
        local real = unit ~= nil and not m.isFake

        local roleId = self.db.profile.assignments[m.name]
        local role = nil
        if roleId then
            local _
            _, role = self:FindRoleById(roleId)
        end

        local blizzRole = nil
        if real and inGroup and haveRoleApi then
            blizzRole = UnitGroupRolesAssigned(unit)
            if blizzRole == "NONE" then blizzRole = nil end
        end

        local snapshot = unit and self:GetTalentSnapshot(unit) or nil
        local talentRoles = {}
        if snapshot and snapshot.roleIds then
            for _, id in ipairs(snapshot.roleIds) do
                local _, r = self:FindRoleById(id)
                if r then talentRoles[#talentRoles + 1] = r end
            end
        end

        local mayRole = self:CanEditRoleOf(m.name)
        local mayFlag = real and self:CanEditGroupRoleOf(unit) or false
        local issues = {}
        local function Add(text, canFix)
            issues[#issues + 1] = text
            total = total + 1
            if canFix then actionable = actionable + 1 end
        end

        if not roleId then
            Add(m.name .. " has no role yet. Pick one here, or wait for talent"
                .. " data to fill it in automatically.", mayRole)
        elseif not role then
            Add(m.name .. "'s saved role no longer exists. Pick a new one.",
                mayRole)
        end

        local groupReason, wdwReason, talentReason =
            RowDisagreements({ blizzRole = blizzRole, roleId = roleId,
                role = role }, talentRoles)
        if groupReason then Add(groupReason, mayFlag) end
        -- A stale scan is settled by Rescan, which needs no rights at all --
        -- but the fix that usually applies is correcting the board, so this
        -- counts as actionable on the same rule the board does.
        if wdwReason then Add(wdwReason, mayRole) end
        if talentReason then Add(talentReason, mayRole) end

        if real and inGroup and role and not blizzRole then
            Add(m.name .. " has no group role set at all. Pick Tank, Healer or"
                .. " Damage so Blizzard's own raid tools agree with the board.",
                mayFlag)
        end

        -- Promoting is protected, so this is a prompt for a human, never
        -- something the addon can carry out. An assistant is told where to do
        -- it; everyone else is told who to ask.
        if real and inRaid and role and role.wowRole == "tank"
            and not GetPartyAssignment("MAINTANK", m.name, true) then
            Add(m.name .. " is a Tank but isn't promoted to Main Tank. "
                .. (self:IsRaidAssistant()
                    and ("Promote them in the raid UI" .. RaidPanelKeyMarkup()
                        .. " -- SetPartyAssignment is a Blizzard-UI-only"
                        .. " action, so no addon can do it for you.")
                    or "Ask the raid leader or an assistant to promote them."),
                canPromote)
        end

        byName[m.name] = {
            unit = unit,
            roleId = roleId,
            role = role,
            blizzRole = blizzRole,
            snapshot = snapshot,
            talentRoles = talentRoles,
            mayRole = mayRole,
            mayFlag = mayFlag,
            issues = issues,
        }
    end

    return byName, total, actionable
end

-- What the toolbar button and the status row advertise: the total, plus how
-- many of them THIS client could actually do something about. Named for the
-- status-bar check key ("actionItems") that has counted them since before the
-- windows merged.
function WhoDoesWhat:CountActionItems()
    local _, total, actionable = self:GetRosterIssues()
    return total, actionable
end
