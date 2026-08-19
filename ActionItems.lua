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
-- line naming what outvoted it.
--
-- When NOBODY scores an agreement -- a two-way mismatch with no third answer to
-- break the tie, or a three-way split -- there is no odd one out to name, so it
-- emits ONE line listing the parties instead of accusing each of them in turn.
-- That matters twice over: the tooltip stopped saying the same thing forwards
-- and backwards ("group disagrees with the board", "the board disagrees with
-- group"), and since the badge counts ISSUES, one wrong role stopped being
-- advertised as two.
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
-- Natural-language list: "A", "A and B", "A, B and C".
local function JoinList(parts)
    if #parts <= 1 then return parts[1] or "" end
    if #parts == 2 then return parts[1] .. " and " .. parts[2] end
    return table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
end

local function Capitalize(text)
    return text:sub(1, 1):upper() .. text:sub(2)
end

local ORDER = { "group", "wdw", "talent" }

-- One entry per DISAGREEMENT -- { text = ..., blames = "group"/"wdw"/"talent"
-- or nil } -- not one per accused answer.
--
-- The earlier shape returned a reason per COLUMN, which was right while each
-- was about to light its own warning icon: a two-way mismatch with no third
-- answer to break the tie genuinely blames both, so both gutters lit and the
-- reader saw one row with two marks on it. Collapsed into a single tooltip that
-- became the same sentence twice -- "group role disagrees with the board", "the
-- board disagrees with the group role" -- and, because the badge counts ISSUES,
-- one wrong role was advertised as two.
--
-- So: a majority still names the odd one out and blames it alone. No majority
-- states the disagreement ONCE and names everyone in it, because that is
-- genuinely one problem and there is nothing to choose between the parties.
-- `blames` is nil on those, since either side could be the thing you fix.
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
    local leads = {
        group = "Group role (" .. (WowRoleName(groupWow) or "none")
            .. ") disagrees with ",
        wdw = "WhoDoesWhat role (" .. (data.role and data.role.name or "none")
            .. ") disagrees with ",
        talent = "Talents read as " .. talentName .. ", which disagrees with ",
    }
    local out = {}

    if best > 0 then
        -- Someone is outvoted, so there is an odd one out worth naming.
        for _, key in ipairs(ORDER) do
            if #against[key] > 0 and agreed[key] < best then
                out[#out + 1] = {
                    blames = key,
                    text = leads[key] .. JoinList(against[key]) .. ".",
                }
            end
        end
        return out
    end

    -- Nobody agrees with anybody. Say it once and name the parties rather than
    -- accusing each of them in turn.
    local parties = {}
    for _, key in ipairs(ORDER) do
        if #against[key] > 0 then parties[#parties + 1] = describes[key] end
    end
    if #parties == 0 then return out end
    out[1] = { text = Capitalize(JoinList(parties))
        .. (#parties > 2 and " all disagree" or " disagree")
        .. ", and nothing else is known that would say which is right." }
    return out
end

-- ---------------------------------------------------------------------------
-- Permission
-- ---------------------------------------------------------------------------

-- Whether the local player may pick this member's group role BY HAND.
--
-- This is the MANUAL gate: the WoW rank the server itself demands before it
-- will accept UnitSetRole for someone else (raid assist / party lead), and
-- nothing more. It deliberately does NOT require the single-writer election --
-- that election is there to stop several clients writing the same flag on
-- their own initiative, and a person clicking one dropdown, once, is not a
-- race. Requiring it meant every assistant's dropdown was dead in any raid
-- whose leader also runs WhoDoesWhat, which is the normal case.
--
-- The rank is checked here rather than left to the board permissions because
-- the two disagree loudly: board permissions read wide open when the raid
-- leader has no WhoDoesWhat, which is precisely when a plain raider looks
-- permitted and can still change nobody's flag. Your own is always yours.
--
-- Takes the player key and the resolved unit token, if the roster walk found
-- one. The token is a convenience, not a requirement: WoW accepts a group
-- member NAME as a unit, and ApplyBlizzardRole already leans on exactly that
-- fallback (`unit or playerName`). An earlier version of this refused outright
-- when the token was missing, which greyed the whole Group role column and
-- stopped SetAssignedRole pushing the flag for anyone the walk had not mapped.
--
-- Returns ok, reason -- the reason names the actual blocker, because "this
-- dropdown is grey" has more than one cause and the reader has to be able to
-- tell the standing one (rank) from the temporary one (combat).
function WhoDoesWhat:CanEditGroupRoleOf(name, unit)
    local token = unit or name
    if not token then
        return false, "They are not in the group right now."
    end
    if UnitIsUnit(token, "player") then return true end
    if not self:CanSetOthersBlizzardRoleManually() then
        return false, "Only the raid leader or an assistant can set another"
            .. " player's group role. Your own is always yours to set."
    end
    return true
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
        -- The resolved raidN/partyN token when the roster walk found one, and
        -- the player key itself when it did not: WoW accepts a group member's
        -- NAME as a unit, and ApplyBlizzardRole already relies on that same
        -- fallback. Requiring the token here instead is what greyed the Group
        -- role column and dropped the unit SetAssignedRole needs to push the
        -- flag. A fake raider has neither, and so is the only case left with no
        -- token at all -- which is right, since it has no Blizzard flag either.
        local unit = units[m.name] or (not m.isFake and m.name or nil)
        local real = unit ~= nil

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
        local mayFlag, flagBlocker = false, "Fake raiders have no Blizzard group role."
        if real then
            mayFlag, flagBlocker = self:CanEditGroupRoleOf(m.name, unit)
        end
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

        -- One entry per disagreement. A line that blames the group flag is
        -- actionable on the flag gate; anything else -- including the "no
        -- majority, both are suspect" line, where either side could be the
        -- thing you fix -- follows the board gate, since correcting the board
        -- is the usual remedy and a stale scan is settled by Rescan, which
        -- needs no rights at all.
        for _, entry in ipairs(RowDisagreements({ blizzRole = blizzRole,
            roleId = roleId, role = role }, talentRoles)) do
            Add(entry.text, entry.blames == "group" and mayFlag
                or (mayRole or mayFlag))
        end

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
            flagBlocker = flagBlocker,
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
