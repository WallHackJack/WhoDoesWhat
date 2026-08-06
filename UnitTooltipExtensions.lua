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
--
-- A second setting appends the roster hover summary (Views/RaiderTooltipView)
-- under that line -- longer, so it is off by default and gated separately.

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
    local settings = WhoDoesWhat.db and WhoDoesWhat.db.profile.settings
    if not settings then return end
    if not (settings.unitTooltipRole or settings.unitTooltipDetail) then return end
    local _, unit = tooltip:GetUnit()
    if not (unit and UnitIsPlayer(unit)) then return end
    if not (UnitIsUnit(unit, "player") or UnitInParty(unit)
        or UnitInRaid(unit)) then
        return
    end
    local name = UnitKey(unit)
    if not name then return end
    local added = false
    local line = settings.unitTooltipRole and RoleLine(name)
    if line then
        tooltip:AddLine(line .. " |cffffd100(WDW)|r", 1, 1, 1)
        added = true
    end
    -- The class summary the roster views show on hover: paladin blessing
    -- talents, or a warlock's Improved Healthstone. Same data, no extra work.
    if settings.unitTooltipDetail
        and WhoDoesWhat:AddRaiderTooltipDetail(tooltip, name) then
        added = true
    end
    if added then tooltip:Show() end
end

GameTooltip:HookScript("OnTooltipSetUnit", AddRoleLine)
