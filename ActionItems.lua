local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- The Action Items model: what still needs tidying before a pull, derived from
-- the roster, the board and the last talent scan. No frames -- Views/
-- ActionItemsView.lua draws it, and both the main window's toolbar button and
-- the WDW Status row read the count from here.
--
-- Four things put a player in the roles list:
--   * MISMATCH: their group role and WDW role disagree.
--   * TALENT MISMATCH: their WDW role and their last-scanned talents disagree.
--     A first sighting deliberately loses to an existing assignment
--     (AutoAssignDetectedRole), so a role picked before anyone could inspect
--     them stays on the board until someone looks at this row. Only roles
--     talents can name count -- see TalentsContradictRole.
--   * UNSET: they have a WDW role but no group role at all. A kicked-and-
--     reinvited player lands here, since a kick clears the flag.
--   * PENDING: they have no WDW role yet -- not scanned, not assigned. Blizzard
--     drops every new raider on DAMAGER, so this is the bulk of the list when a
--     raid first forms, and it's the list you actually work down.
--
-- Separately, a raid tank who hasn't been promoted to Main Tank earns a promote
-- row. Promoting is a protected action an addon can't perform, so that list is
-- advisory.
--
-- Solo is always empty. Outside a group Blizzard reports your own flag as NONE,
-- which would show a permanent one-row "fix" for a flag that means nothing
-- until you're grouped.

local A = WhoDoesWhat.Assign

-- Blizzard's group-role token to our wowRole string. Shared with the view,
-- which uses it to tick the right entry in the group-role dropdown.
WhoDoesWhat.BLIZZ_ROLE_TO_WOW_ROLE = {
    TANK = "tank", HEALER = "healer", DAMAGER = "dps",
}
local BLIZZ_TO_WOW = WhoDoesWhat.BLIZZ_ROLE_TO_WOW_ROLE

local function ClassInfoForUnit(unit)
    local _, englishClass = UnitClass(unit)
    return englishClass and A.GetClassInfoByToken(englishClass) or nil
end

-- Both lists the window shows, roster order: role rows first, promote rows
-- second. See the header for what earns a row in each.
function WhoDoesWhat:GetActionItems()
    local roleRows, promoteRows = {}, {}
    if not (self.db and UnitGroupRolesAssigned) then return roleRows, promoteRows end
    if not IsInGroup() then return roleRows, promoteRows end
    local inRaid = IsInRaid()

    local units = {}
    if inRaid then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    else
        units[1] = "player"
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end

    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local name, realm = UnitName(unit)
            local key = (realm and realm ~= "") and (name .. "-" .. realm) or name
            local classInfo = ClassInfoForUnit(unit)
            local roleId = key and self.db.profile.assignments[key]
            local _, role = nil, nil
            if roleId then _, role = self:FindRoleById(roleId) end

            local blizzRole = UnitGroupRolesAssigned(unit)
            if blizzRole == "NONE" then blizzRole = nil end
            local wanted = role and role.wowRole or nil

            local mismatched = (wanted and blizzRole
                and BLIZZ_TO_WOW[blizzRole] ~= wanted) and true or false
            local unset = (wanted and not blizzRole) and true or false
            -- No WDW role at all: the scan hasn't reached them or nobody has
            -- assigned one. Not a disagreement -- a blank waiting to be filled.
            local pending = (not roleId) and true or false
            -- The board says one spec, their talents read as another. Roles
            -- that talents can't name are excluded (TalentsContradictRole), so
            -- a Warlock Tank never sits here unfixably.
            local talentMismatch = self:TalentsContradictRole(unit, roleId)

            if classInfo and (mismatched or unset or pending or talentMismatch) then
                roleRows[#roleRows + 1] = {
                    name = key,
                    unit = unit,
                    classInfo = classInfo,
                    blizzRole = blizzRole,
                    roleId = roleId,
                    role = role,
                    mismatched = mismatched,
                    unset = unset,
                    pending = pending,
                    talentMismatch = talentMismatch,
                }
            end

            if classInfo and inRaid and wanted == "tank"
                and not GetPartyAssignment("MAINTANK", key, true) then
                promoteRows[#promoteRows + 1] = {
                    name = key,
                    classInfo = classInfo,
                    role = role,
                }
            end
        end
    end
    return roleRows, promoteRows
end

-- What the toolbar button and the status row advertise: the total, plus how
-- many of them THIS client could actually do something about. One pass over the
-- roster with no frame work, and always agreeing with the window by
-- construction.
--
-- The two numbers differ for an unpermitted raider, and that gap is the whole
-- point: they still get an honest count of what's outstanding, but nothing
-- glows or turns gold at them, because none of it is theirs to fix. Promotions
-- count for anyone who could actually promote -- leader or assistant, the same
-- rule the promote-watch arrow fires on.
function WhoDoesWhat:CountActionItems()
    local roleRows, promoteRows = self:GetActionItems()
    local actionable = 0
    for _, data in ipairs(roleRows) do
        if self:CanEditRoleOf(data.name) then actionable = actionable + 1 end
    end
    if self:CanPromoteMainTank() then
        actionable = actionable + #promoteRows
    end
    return #roleRows + #promoteRows, actionable
end
