local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Shared player tooltip used by roster-style views. Paladins get the full
-- talent/addon summary; Warlocks get their Improved Healthstone result.

local ICON_SIZE = 16
local READY_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"
local NOT_READY_ICON = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local CHECK_HEIGHT = math.floor(ICON_SIZE * 0.8 + 0.5)
local TALENT_LINES = {
    { key = "kings", max = 1 },
    { key = "sanctuary", max = 1 },
    { key = "might", max = 5 },
    { key = "wisdom", max = 2 },
}
local tooltipOwner, tooltipName
local originalBackdrop
local paladinBackdrop

for _, classInfo in ipairs(WhoDoesWhat.Classes) do
    if classInfo.name == "Paladin" then
        local tint = classInfo.gridRowColors[1]
        paladinBackdrop = { tint.r * tint.a, tint.g * tint.a, tint.b * tint.a, 0.95 }
        break
    end
end

local function Icon(texture)
    local height = texture == READY_ICON and CHECK_HEIGHT or ICON_SIZE
    return "|T" .. texture .. ":" .. height .. ":" .. ICON_SIZE .. ":0:0|t"
end

local function TalentLine(line, rank)
    local buff = WhoDoesWhat.PaladinBuffs[line.key]
    local complete = rank and rank >= line.max
    -- Might and Wisdom are always castable; incomplete Improved ranks warn
    -- rather than presenting as a hard failure like missing Kings/Sanctuary.
    local partial = rank == nil or line.max > 1 or rank > 0
    local status = complete and READY_ICON
        or (partial and WhoDoesWhat.WARNING_ICON or NOT_READY_ICON)
    local color = complete and "40ff40" or (partial and "ff9f40" or "ff6060")
    return Icon(status) .. " " .. Icon(buff.iconId) .. " |cff" .. color
        .. buff.name_long .. " (" .. (rank == nil and "?" or rank)
        .. "/" .. line.max .. ")|r", complete and 1 or (partial and 2 or 3)
end

local function AddonLine(label, installed)
    return Icon(installed and READY_ICON or NOT_READY_ICON) .. " |cff"
        .. (installed and "40ff40" or "ff6060") .. label .. "|r"
end

local function MemberClass(name)
    for _, member in ipairs(WhoDoesWhat:GetGroupMembers(nil)) do
        if member.name == name then return member.classInfo.name end
    end
end

-- The detail lines alone, without the player header or the tooltip plumbing.
-- Split out so Blizzard's unit tooltip can append the same summary under the
-- role line (UnitTooltipExtensions.lua). Returns the class it wrote for, or
-- nil when the raider has nothing worth saying.
function WhoDoesWhat:AddRaiderTooltipDetail(tooltip, name)
    local className = name and MemberClass(name)
    if className ~= "Paladin" and className ~= "Warlock" then return nil end

    if className == "Warlock" then
        local healthstone = self.WarlockHealthstone
        local rank = self:GetWarlockHealthstoneTalent(name)
        local amount = rank ~= nil and healthstone.lifeByTalentRank[rank]
        local detail = healthstone.name .. " (" .. (rank == nil and "?" or rank)
            .. "/" .. healthstone.maxRank .. ")"
        if amount then detail = detail .. " - " .. amount .. " life" end
        tooltip:AddLine(Icon(healthstone.icon) .. " |cff909090" .. detail .. "|r",
            1, 1, 1)
        return className
    end

    local talents = self:GetPaladinBuffTalents(name)
    if not talents then
        tooltip:AddLine(Icon(self.WARNING_ICON)
            .. " |cffff9f40Awaiting Paladin talents|r", 1, 1, 1)
        tooltip:AddLine("WDW will not assign this paladin any blessings until talent data arrives.",
            0.9, 0.8, 0.6, true)
        tooltip:AddLine("If they are sitting out, mark them as Non-raider instead.",
            0.8, 0.8, 0.8, true)
        tooltip:AddLine(" ")
    elseif talents._source == "pallypower" then
        tooltip:AddLine("|cff909090Talent data from external addon (PallyPower).|r",
            1, 1, 1)
        tooltip:AddLine("Targeting them in range will confirm and replace it.",
            0.8, 0.8, 0.8, true)
        tooltip:AddLine(" ")
    end
    local entries = {}
    for order, line in ipairs(TALENT_LINES) do
        local text, status = TalentLine(line, talents and talents[line.key])
        entries[#entries + 1] = { text = text, status = status, order = order }
    end
    table.sort(entries, function(a, b)
        return a.status < b.status or (a.status == b.status and a.order < b.order)
    end)
    for _, entry in ipairs(entries) do
        tooltip:AddLine(entry.text, 1, 1, 1)
    end
    tooltip:AddLine(" ")
    tooltip:AddLine(AddonLine("PallyPower", self:PaladinHasPallyPower(name)), 1, 1, 1)
    tooltip:AddLine(AddonLine("WDW",
        name == UnitName("player") or self.syncPeers[name] == true), 1, 1, 1)
    return className
end

function WhoDoesWhat:ShowRaiderTooltip(owner, name)
    local className = name and MemberClass(name)
    if className ~= "Paladin" and className ~= "Warlock" then return end

    tooltipOwner, tooltipName = owner, name
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR_RIGHT", 12, 12)
    if GameTooltip.SetBackdropColor then
        if not originalBackdrop and GameTooltip.GetBackdropColor then
            local r, g, b, a = GameTooltip:GetBackdropColor()
            if r then originalBackdrop = { r, g, b, a } end
        end
        local background = className == "Paladin" and paladinBackdrop or originalBackdrop
        if background then GameTooltip:SetBackdropColor(unpack(background)) end
    end
    GameTooltip:SetText(self.Assign.PlayerTextWithRole(name, ICON_SIZE), 1, 1, 1)
    self:AddRaiderTooltipDetail(GameTooltip, name)
    GameTooltip:Show()
end

function WhoDoesWhat:HideRaiderTooltip()
    tooltipOwner, tooltipName = nil, nil
    if originalBackdrop and GameTooltip.SetBackdropColor then
        GameTooltip:SetBackdropColor(unpack(originalBackdrop))
    end
    originalBackdrop = nil
    GameTooltip:Hide()
end

function WhoDoesWhat:RefreshRaiderTooltip()
    if tooltipOwner and tooltipOwner:IsShown() then
        self:ShowRaiderTooltip(tooltipOwner, tooltipName)
    end
end
