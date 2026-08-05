local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Appends the WDW role assignment to Blizzard's unit tooltip, so a raider's
-- job is readable by hovering them in the world or on a raid frame instead of
-- opening the board. Display only: this never inspects, never sends anything,
-- and never triggers a scan -- targeting a player already refreshes their
-- talents through the inspector's own path (see TalentScanning.lua).
--
-- Deliberately quiet: one line, only for players in our group who actually
-- have an assignment, and only while the setting is on. Nothing is added for
-- strangers, NPCs, or roleless members, so tooltips stay their usual size
-- next to a tooltip addon like TacoTip.

local ICON_SIZE = 14

-- Same "Name" / "Name-Realm" keying db.profile.assignments uses.
local function UnitKey(unit)
    local name, realm = UnitName(unit)
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function RoleLine(name)
    local roleId = WhoDoesWhat:GetAssignedRole(name)
    if not roleId then return nil end
    local _, role = WhoDoesWhat:FindRoleById(roleId)
    if not role then return nil end
    return WhoDoesWhat.Assign.RoleIconMarkup(name, ICON_SIZE) .. role.name
end

local function AddRoleLine(tooltip)
    if not (WhoDoesWhat.db
        and WhoDoesWhat.db.profile.settings.unitTooltipRole) then
        return
    end
    local _, unit = tooltip:GetUnit()
    if not (unit and UnitIsPlayer(unit)) then return end
    if not (UnitIsUnit(unit, "player") or UnitInParty(unit)
        or UnitInRaid(unit)) then
        return
    end
    local name = UnitKey(unit)
    local line = name and RoleLine(name)
    if not line then return end
    tooltip:AddLine(line .. " |cffffd100(WDW)|r", 1, 1, 1)
    tooltip:Show()
end

GameTooltip:HookScript("OnTooltipSetUnit", AddRoleLine)
