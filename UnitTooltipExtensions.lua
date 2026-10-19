local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local L = select(2, ...).L

-- Appends the WDW role assignment to Blizzard's unit tooltip, so a raider's
-- job is readable by hovering them in the world or on a raid frame instead of
-- opening the board. Display only: this never inspects, never sends anything,
-- and never triggers a scan -- targeting a player already refreshes their
-- talents through the inspector's own path (see TalentScanning.lua).
--
-- Deliberately quiet: one line, only for players in our group who actually
-- have an assignment, and only while the setting is on. Nothing is added for
-- NPCs or roleless members, so tooltips stay their usual size next to a
-- tooltip addon like TacoTip. Strangers get a line only under the separate
-- unitTooltipStrangers setting -- and that one does inspect them.
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

-- GUID of the stranger whose tooltip went up without a talent line because
-- their inspect was still out; AddStrangerTooltipLine fills it in.
local pendingGuid = nil

-- A player outside the group has no board role, so the opt-in stranger line
-- says what their talents read as instead, with the raw spread beside it.
-- Someone read with nothing spent says so in red; unread players get an
-- inspect requested (throttled; see RequestStrangerInspect) and nothing drawn:
-- the line is added to the tooltip once the answer lands.
local function TalentLine(unit)
    local snapshot = WhoDoesWhat:GetTalentSnapshot(unit)
    if not (snapshot and snapshot.roleIds) then
        if WhoDoesWhat:UnitTalentsReadEmpty(unit) then
            return "|cffff4040" .. L.TOOLTIP_NO_TALENTS .. "|r"
        end
        local guid = UnitGUID(unit)
        if guid and not WhoDoesWhat:IsSecret(guid) then pendingGuid = guid end
        WhoDoesWhat:RequestStrangerInspect(unit)
        return nil
    end
    local names = {}
    for _, roleId in ipairs(snapshot.roleIds) do
        local _, role = WhoDoesWhat:FindRoleById(roleId)
        if role then
            names[#names + 1] = WhoDoesWhat:RoleIconMarkup(role.icon, ICON_SIZE)
                .. role.name
        end
    end
    if #names == 0 then return nil end
    local p = snapshot.points
    return table.concat(names, " / ") .. string.format(
        " |cffffd100(%d/%d/%d)|r", p[1], p[2], p[3])
end

local function AddRoleLine(tooltip)
    pendingGuid = nil
    local settings = WhoDoesWhat.db and WhoDoesWhat.db.profile.settings
    if not settings then return end
    if not (settings.unitTooltipRole or settings.unitTooltipDetail) then return end
    local _, unit = tooltip:GetUnit()
    -- Forever hands back a secret unit token for units it will not let an addon
    -- identify -- hovering something in the world inside a dungeon is the case
    -- in point -- and passing one to UnitIsPlayer is itself the error, so the
    -- token has to be tested before the first unit call, not around it.
    if not unit or WhoDoesWhat:IsSecret(unit) then return end
    if not UnitIsPlayer(unit) then return end
    if not (UnitIsUnit(unit, "player") or UnitInParty(unit)
        or UnitInRaid(unit)) then
        local line = settings.unitTooltipRole and settings.unitTooltipStrangers
            and TalentLine(unit)
        if line then
            tooltip:AddLine(line, 1, 1, 1)
            tooltip:Show()
        end
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

-- A stranger's inspect landed: add their line to the tooltip already up, and
-- only while the cursor is still on them. This used to re-set the tooltip with
-- SetUnit, but a unit tooltip set from addon code is no longer the client's
-- mouseover tooltip and never fades when the cursor leaves -- it stayed on
-- screen until something else was hovered. One that is already fading out is
-- left alone, and pendingGuid keeps the line from going in twice.
function WhoDoesWhat:AddStrangerTooltipLine(guid)
    if not guid or guid ~= pendingGuid or not GameTooltip:IsShown() then return end
    local _, unit = GameTooltip:GetUnit()
    if not unit or self:IsSecret(unit) then return end
    local shown, hovered = UnitGUID(unit), UnitGUID("mouseover")
    if not (shown and hovered) or self:IsSecret(shown) or self:IsSecret(hovered)
        or shown ~= guid or hovered ~= guid then
        return
    end
    local line = TalentLine(unit)
    if not line then return end
    pendingGuid = nil
    GameTooltip:AddLine(line, 1, 1, 1)
    GameTooltip:Show()
end

-- Same two-client split as the healthstone line (ItemTooltipExtensions): the
-- OnTooltipSet* scripts are gone on Forever, where tooltips are extended
-- through TooltipDataProcessor instead. AddRoleLine reads the unit off the
-- tooltip either way, so it needs no second form.
if GameTooltip:HasScript("OnTooltipSetUnit") then
    GameTooltip:HookScript("OnTooltipSetUnit", AddRoleLine)
elseif TooltipDataProcessor then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit,
        function(tooltip)
            if tooltip == GameTooltip then AddRoleLine(tooltip) end
        end)
end
