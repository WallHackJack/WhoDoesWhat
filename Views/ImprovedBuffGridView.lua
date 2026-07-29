local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Raid Buff Grid. It deliberately mirrors the Paladin Full Grid: the same
-- name/column/row/cell sizes, angled one-icon-wide headers, and balanced
-- side-by-side blocks for a large raid.

local A = WhoDoesWhat.Assign
local gridFrame

local BUFF_KEYS = { "gift", "fortitude", "intellect", "food" }
local BUFF_LABELS = {
    gift = "Mark",
    fortitude = "Fortitude",
    intellect = "Intellect",
    food = "Food",
}

local MIN_FRAME_W = 330
local MIN_FRAME_H = 230
local MARGIN = 12
local NAME_COL_W = 150
local COL_W = 26
local ROW_H = 22
local ROLE_ICON_SIZE = 16
local CELL_SIZE = 20
local CELL_ICON_SIZE = 16
local HEADER_H = 90
local SPLIT_AT_ROWS = 20
local BLOCK_GAP = 14
local MISSING_ICON = "Interface\\RaidFrame\\ReadyCheck-NotReady"

local classHex = {}
for _, classInfo in ipairs(WhoDoesWhat.Classes) do
    classHex[classInfo.name] = classInfo.colorHex
end

local function UnitKey(unit)
    local name, realm = UnitName(unit)
    if not name then return nil end
    return realm and realm ~= "" and (name .. "-" .. realm) or name
end

local function GroupUnitsByName()
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            local name = UnitKey(unit)
            if name then units[name] = unit end
        end
    else
        local name = UnitKey("player")
        if name then units[name] = "player" end
        for i = 1, GetNumSubgroupMembers() do
            local unit = "party" .. i
            name = UnitKey(unit)
            if name then units[name] = unit end
        end
    end
    return units
end

local function SortedRaiders()
    local units = GroupUnitsByName()
    local raiders = {}
    for _, member in ipairs(A.GetEligibleMembers(nil)) do
        if not WhoDoesWhat:IsNonRaider(member.name) then
            local unit = units[member.name]
            member.connected = member.isFake
                or (unit and UnitIsConnected(unit) ~= false) or false
            raiders[#raiders + 1] = member
        end
    end
    table.sort(raiders, function(a, b)
        if a.classInfo.name ~= b.classInfo.name then
            return a.classInfo.name < b.classInfo.name
        end
        local ar, br = WhoDoesWhat:RoleSortRank(a.name), WhoDoesWhat:RoleSortRank(b.name)
        if ar ~= br then return ar < br end
        return a.name < b.name
    end)
    return raiders
end

local function RoleIconFor(member)
    local roleId = WhoDoesWhat:GetAssignedRole(member.name)
    if roleId then
        local _, role = WhoDoesWhat:FindRoleById(roleId)
        if role then return role.icon end
    end
    return member.classInfo.classIcon
end

local function HeaderText(key)
    local buff = WhoDoesWhat.CoreRaidBuffs[key]
    local hex = buff.colorRGB and "ffd100" or classHex[buff.className] or "ffffff"
    return "|cff" .. hex .. BUFF_LABELS[key] .. "|r"
end

local function CreateHeaderCell(f, index)
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetJustifyH("LEFT")
    local ag = fs:CreateAnimationGroup()
    local rot = ag:CreateAnimation("Rotation")
    rot:SetDegrees(75)
    rot:SetDuration(0)
    rot:SetEndDelay(2147483647)
    rot:SetOrigin("BOTTOMLEFT", 0, 0)
    f.headerCells[index] = { fs = fs, ag = ag }
    return f.headerCells[index]
end

local function CreateCell(row, column)
    local cell = CreateFrame("Button", nil, row)
    cell:SetSize(CELL_SIZE, CELL_SIZE)
    cell:SetPoint("LEFT", row, "LEFT",
        NAME_COL_W + (column - 1) * COL_W + (COL_W - CELL_SIZE) / 2, 0)

    local missing = cell:CreateTexture(nil, "ARTWORK")
    missing:SetTexture(MISSING_ICON)
    missing:SetSize(CELL_ICON_SIZE, CELL_ICON_SIZE)
    missing:SetPoint("CENTER")
    missing:Hide()
    cell.missing = missing

    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetSize(CELL_ICON_SIZE, CELL_ICON_SIZE)
    icon:SetPoint("CENTER")
    cell.icon = icon

    cell:SetScript("OnEnter", function(self)
        local buff = WhoDoesWhat.CoreRaidBuffs[self.buffKey]
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(buff.name .. " - " .. self.raider, 1, 1, 1)
        if self.notNeeded then
            GameTooltip:AddLine("Not required for this class.", 0.6, 0.6, 0.6)
        elseif not self.connected then
            GameTooltip:AddLine("Aura state is unavailable while this raider is offline.",
                0.6, 0.6, 0.6, true)
        elseif self.hasBuff == true then
            local status, source, rank, maxRank =
                WhoDoesWhat:GetImprovedBuffState(self.raider, self.buffKey)
            if status == "max" then
                GameTooltip:AddLine("Active from " .. source .. " (max rank "
                    .. rank .. "/" .. maxRank .. ").", 0.3, 1, 0.3, true)
            elseif status == "partial" or status == "base" then
                GameTooltip:AddLine("Active from " .. source .. " (" .. rank
                    .. "/" .. maxRank .. ").", 1, 0.7, 0.2, true)
            else
                source = WhoDoesWhat:GetBuffSource(self.raider, self.buffKey)
                GameTooltip:AddLine(source and ("Active from " .. source .. ".")
                    or "Active.", 0.3, 1, 0.3, true)
            end
        elseif self.hasBuff == false then
            GameTooltip:AddLine("Missing this buff.", 1, 0.3, 0.3)
        else
            GameTooltip:AddLine("Aura state has not been scanned yet.", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.cells[column] = cell
    return cell
end

local function CreateRow(f, index)
    local row = CreateFrame("Frame", nil, f)
    row:SetFrameLevel(f:GetFrameLevel() + 1)
    row:SetHeight(ROW_H)
    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    stripe:SetColorTexture(1, 1, 1, 0.04)
    row.stripe = stripe
    local roleIcon = row:CreateTexture(nil, "ARTWORK")
    roleIcon:SetSize(ROLE_ICON_SIZE, ROLE_ICON_SIZE)
    roleIcon:SetPoint("LEFT", 4, 0)
    row.roleIcon = roleIcon
    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", roleIcon, "RIGHT", 6, 0)
    name:SetJustifyH("LEFT")
    row.name = name
    row.cells = {}
    f.rows[index] = row
    return row
end

local function RefreshGrid(f)
    local raiders = SortedRaiders()
    local buffKeys = {}
    for _, key in ipairs(BUFF_KEYS) do
        local buff = WhoDoesWhat.CoreRaidBuffs[key]
        if not buff.className or #A.MembersOfClass(buff.className) > 0 then
            buffKeys[#buffKeys + 1] = key
        end
    end
    local numBlocks = (#raiders >= SPLIT_AT_ROWS) and 2 or 1
    local rowsPerBlock = math.max(1, math.ceil(#raiders / numBlocks))
    local blockW = NAME_COL_W + #buffKeys * COL_W
    local function BlockX(block)
        return MARGIN + (block - 1) * (blockW + BLOCK_GAP)
    end

    f:SetWidth(math.max(MIN_FRAME_W,
        MARGIN + numBlocks * blockW + (numBlocks - 1) * BLOCK_GAP + MARGIN))

    local hi = 0
    for block = 1, numBlocks do
        for column, key in ipairs(buffKeys) do
            hi = hi + 1
            local header = f.headerCells[hi] or CreateHeaderCell(f, hi)
            header.fs:ClearAllPoints()
            header.fs:SetPoint("BOTTOMLEFT", f, "TOPLEFT",
                BlockX(block) + NAME_COL_W + (column - 1) * COL_W
                    + COL_W / 2 - 5, -(f.headerBottom + 6))
            header.fs:SetText(HeaderText(key))
            header.fs:Show()
            header.ag:Stop()
            header.ag:Play()
        end
    end
    for i = hi + 1, #f.headerCells do f.headerCells[i].fs:Hide() end

    for block, label in ipairs(f.raiderLabels) do
        if block <= numBlocks then
            label:ClearAllPoints()
            label:SetPoint("BOTTOMLEFT", f, "TOPLEFT",
                BlockX(block) + 4, -(f.headerBottom - 6))
            label:Show()
        else
            label:Hide()
        end
    end

    for i, member in ipairs(raiders) do
        local row = f.rows[i] or CreateRow(f, i)
        local block = math.ceil(i / rowsPerBlock)
        local localRow = i - (block - 1) * rowsPerBlock
        row:SetWidth(blockW)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f, "TOPLEFT", BlockX(block),
            -(f.headerBottom + 4 + (localRow - 1) * ROW_H))
        row.stripe:SetShown(localRow % 2 == 1)
        row.roleIcon:SetTexture(RoleIconFor(member))
        row.name:SetText("|cff" .. member.classInfo.colorHex .. member.name .. "|r")
        row:SetAlpha(member.connected and 1 or 0.55)
        for column, key in ipairs(buffKeys) do
            local cell = row.cells[column] or CreateCell(row, column)
            local buff = WhoDoesWhat.CoreRaidBuffs[key]
            local notNeeded = buff.excludedClasses
                and buff.excludedClasses[member.classInfo.name] or false
            local has = notNeeded and nil or WhoDoesWhat:HasBuff(member.name, key)
            cell.raider = member.name
            cell.buffKey = key
            cell.connected = member.connected
            cell.notNeeded = notNeeded
            cell.hasBuff = has
            cell.icon:SetTexture(buff.icon)
            cell.icon:SetShown(has == true)
            cell.missing:SetShown(not notNeeded and member.connected
                and not member.isFake and has == false)
            cell:Show()
        end
        for column = #buffKeys + 1, #row.cells do row.cells[column]:Hide() end
        row:Show()
    end
    for i = #raiders + 1, #f.rows do f.rows[i]:Hide() end

    f.emptyHint:SetShown(#raiders == 0)
    f:SetHeight(math.max(MIN_FRAME_H,
        f.headerBottom + 4 + rowsPerBlock * ROW_H + MARGIN))
end

local function EnsureGridFrame()
    if gridFrame then return gridFrame end
    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatImprovedBuffGridFrame",
        MIN_FRAME_W, MIN_FRAME_H, "WhoDoesWhat - Raid Buff Grid")

    local rescan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    rescan:SetSize(60, 18)
    rescan:SetPoint("TOPRIGHT", -28, -6)
    rescan:SetText("Rescan")
    rescan:SetScript("OnClick", function() WhoDoesWhat:RescanImprovedBuffTalents() end)
    rescan:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText("Rescan improved-buff talents", 1, 1, 1)
        GameTooltip:AddLine("Inspect every Priest and Druid currently in range.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    rescan:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.headerBottom = f.titleBarHeight + 8 + HEADER_H
    f.raiderLabels = {}
    for block = 1, 2 do
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetText("Raider")
        label:Hide()
        f.raiderLabels[block] = label
    end
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", MARGIN, -f.headerBottom)
    divider:SetPoint("TOPRIGHT", -MARGIN, -f.headerBottom)
    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    empty:SetPoint("BOTTOMLEFT", f, "TOPLEFT",
        MARGIN + NAME_COL_W + 6, -(f.headerBottom - 6))
    empty:SetTextColor(0.55, 0.55, 0.55)
    empty:SetText("No raiders in the group.")
    f.emptyHint = empty

    f.headerCells, f.rows = {}, {}
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:SetScript("OnEvent", function(self)
        if self:IsShown() then RefreshGrid(self) end
    end)
    gridFrame = f
    return f
end

function WhoDoesWhat:RefreshImprovedBuffGridView()
    if gridFrame and gridFrame:IsShown() then RefreshGrid(gridFrame) end
end

function WhoDoesWhat:OpenImprovedBuffGridView()
    local f = EnsureGridFrame()
    if f:IsShown() then
        f:Hide()
        return
    end
    self:LogUiBuilding("Opening Raid Buff Grid...")
    f:Show()
    RefreshGrid(f)
    f:Raise()
end
