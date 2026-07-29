local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Paladin Buff Grid ("Full Grid" button on the main view): every raiding
-- group member down the left with their role icon (Non-raiders are left out
-- entirely), every paladin across the top, and at each intersection the
-- buff that paladin gives that raider. At SPLIT_AT_ROWS raiders (or more) the
-- grid splits into two side-by-side blocks (balanced halves), each with its
-- own header names, instead of growing taller.
--
-- The grid cells come from ComputeBuffGrid (Assignments.lua): coverage is
-- computed per raider from the roster, roles and talents -- blessings are
-- never assigned to a paladin, so there is nothing to edit here. A paladin
-- with nothing useful left for a raider shows an empty cell. Per-cell
-- click-to-customize is the plan for later, which is why the cells are
-- already buttons.
--
-- The title bar's Rescan button force-inspects every reachable paladin because
-- talent data arrives asynchronously through LibClassicInspector.
--
-- Each paladin column is headed by their role icon with an outlined initial;
-- hovering it opens the shared paladin detail tooltip.

local gridFrame = nil

local MIN_FRAME_W = 330 -- floor for the title text + title-bar buttons; width tracks columns
local MIN_FRAME_H = 260 -- floor so an empty group still shows the chrome
local MARGIN = 12

local NAME_COL_W = 150 -- role icon + raider name
local COL_W = 26       -- one paladin column
local ROW_H = 22
local ROLE_ICON_SIZE = 18
local CELL_SIZE = 20
local CELL_ICON_SIZE = 18
local HEADER_H = 28

-- Grid blocks: at this many raiders (or more) the rows split into two
-- side-by-side blocks (balanced halves) rather than making the window taller.
local SPLIT_AT_ROWS = 20
local BLOCK_GAP = 14
local GRID_X = MARGIN

-- Group members sorted class > role > name (same ordering the Raider Roles
-- buckets use), so classes clump together down the left side. Non-raiders
-- (the unit-menu pseudo-role) are sitting out and get no grid row. Hunter
-- pets ride along as virtual rows (their own plan cells); they carry the
-- Hunter class name but sort AFTER the real hunters, forming a "Pets"
-- section directly beneath the hunter block.
local function SortedMembers()
    local members = {}
    for _, m in ipairs(WhoDoesWhat:GetGroupMembers(nil)) do
        if not WhoDoesWhat:IsNonRaider(m.name) then
            members[#members + 1] = m
        end
    end
    for _, pet in ipairs(WhoDoesWhat.Assign.GetPetMembers()) do
        members[#members + 1] = pet
    end
    table.sort(members, function(a, b)
        if a.classInfo.name ~= b.classInfo.name then
            return a.classInfo.name < b.classInfo.name
        end
        -- Real class members first, then the pet "section" beneath them.
        if (a.isPet or false) ~= (b.isPet or false) then
            return not a.isPet
        end
        -- Within a class, group by assigned role (tank/heal/dps clump together).
        local ra, rb = WhoDoesWhat:RoleSortRank(a.name), WhoDoesWhat:RoleSortRank(b.name)
        if ra ~= rb then return ra < rb end
        return a.name < b.name
    end)
    return members
end

-- The group's paladins, strictly by class: Developer Mode widens
-- GetGroupMembers' class filter to everyone, but non-paladin columns would be
-- pure noise here.
local function GroupPaladins()
    local out = {}
    for _, m in ipairs(WhoDoesWhat:GetGroupMembers("Paladin")) do
        if m.classInfo.name == "Paladin" then
            out[#out + 1] = m
        end
    end
    return out
end

-- A raider's row icon: their assigned role's icon, their class icon while
-- they have no (resolvable) role. Pets always show the pet pseudo-role's
-- icon -- they have no assignment to look up.
local function RoleIconFor(m)
    if m.isPet then
        return WhoDoesWhat.HunterPetRole.icon
    end
    local roleId = WhoDoesWhat:GetAssignedRole(m.name)
    if roleId then
        local _, role = WhoDoesWhat:FindRoleById(roleId)
        if role then return role.icon end
    end
    return m.classInfo.classIcon
end

-- One compact paladin header, pooled flat across blocks.
local function CreateHeaderCell(f, index)
    local header = CreateFrame("Button", nil, f)
    header:SetSize(CELL_SIZE, CELL_SIZE)

    local icon = header:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    header.icon = icon

    local initial = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    initial:SetPoint("CENTER")
    local font, size = initial:GetFont()
    if font then initial:SetFont(font, size + 1, "OUTLINE") end
    header.initial = initial

    header:SetScript("OnEnter", function(self)
        WhoDoesWhat:ShowRaiderTooltip(self, self.paladin)
    end)
    header:SetScript("OnLeave", function() WhoDoesWhat:HideRaiderTooltip() end)

    f.headerCells[index] = header
    return header
end

-- One grid cell (a button already, for the later click-to-customize).
-- Refresh fills cell.paladin / cell.raider / cell.buffKey before showing it.
local function CreateCell(f, row, c)
    local cell = CreateFrame("Button", nil, row)
    cell:SetSize(CELL_SIZE, CELL_SIZE)
    cell:SetPoint("LEFT", row, "LEFT",
        NAME_COL_W + (c - 1) * COL_W + (COL_W - CELL_SIZE) / 2, 0)

    -- Bright border, shown when this raider is confirmed to be MISSING the
    -- blessing this cell plans for them (BuffTracking.lua). The icon is also
    -- desaturated so missing reads differently without animation or fading.
    local missing = CreateFrame("Frame", nil, cell, "BackdropTemplate")
    missing:SetAllPoints()
    missing:SetFrameLevel(cell:GetFrameLevel() + 1)
    missing:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 2,
    })
    missing:SetBackdropBorderColor(1, 0.05, 0.05, 1)
    missing:Hide()
    cell.missing = missing

    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetSize(CELL_ICON_SIZE, CELL_ICON_SIZE)
    icon:SetPoint("CENTER")
    cell.icon = icon

    cell:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.buffKey then
            GameTooltip:SetText(self.paladin, 1, 1, 1)
            GameTooltip:AddLine("Blesses " .. self.raider .. " with "
                .. (self.isGreater and "Greater Blessing of " or "Blessing of ")
                .. WhoDoesWhat.PaladinBuffs[self.buffKey].name_long
                .. (self.isGreater and "." or " (Lesser)."),
                0.8, 0.8, 0.8, true)
            if not WhoDoesWhat.Assign.IsSimulatedPaladinBuff(self.paladin, self.raider)
                and WhoDoesWhat:HasBuff(self.raider, self.buffKey) == false then
                GameTooltip:AddLine(self.raider .. " is missing this buff.",
                    1, 0.3, 0.3, true)
            end
        else
            GameTooltip:SetText(self.paladin, 1, 1, 1)
            GameTooltip:AddLine("Nothing for " .. self.raider .. ": every blessing"
                .. " they want at this paladin count is already covered, or needs"
                .. " a talent " .. self.paladin .. " doesn't have.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.cells[c] = cell
    return cell
end

-- One pooled raider row: class-tinted alternating background (set by the
-- refresh, since a row's block-local position moves as the group changes),
-- role icon, class-colored name; the buff cells hang off it per column.
-- RefreshGrid anchors it into its block each pass.
local function CreateRow(f, index)
    local row = CreateFrame("Frame", nil, f)
    row:SetFrameLevel(f:GetFrameLevel() + 1)
    row:SetHeight(ROW_H)

    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    row.stripe = stripe

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ROLE_ICON_SIZE, ROLE_ICON_SIZE)
    icon:SetPoint("LEFT", 4, 0)
    row.roleIcon = icon

    local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameFS:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    nameFS:SetJustifyH("LEFT")
    row.nameFS = nameFS

    row.cells = {}
    f.rows[index] = row
    return row
end

-- Map the current group onto the pooled widgets and size the window to its
-- content: width tracks the paladin count and block count. No scrolling.
local function RefreshGrid(f)
    local members = SortedMembers()
    local paladins = GroupPaladins()
    local disconnected = WhoDoesWhat.Assign.DisconnectedGroupTargets()

    local numBlocks = (#members >= SPLIT_AT_ROWS) and 2 or 1
    local rowsPerBlock = math.ceil(#members / numBlocks)
    local blockW = NAME_COL_W + math.max(#paladins, 1) * COL_W
    local function BlockX(b)
        return GRID_X + (b - 1) * (blockW + BLOCK_GAP)
    end

    f:SetWidth(math.max(MIN_FRAME_W,
        GRID_X + numBlocks * blockW + (numBlocks - 1) * BLOCK_GAP + MARGIN))

    -- Role-icon paladin headers above every block, from one flat pool.
    local hc = 0
    for b = 1, numBlocks do
        for c, p in ipairs(paladins) do
            hc = hc + 1
            local header = f.headerCells[hc] or CreateHeaderCell(f, hc)
            header:ClearAllPoints()
            header:SetPoint("BOTTOMLEFT", f, "TOPLEFT",
                BlockX(b) + NAME_COL_W + (c - 1) * COL_W
                    + (COL_W - CELL_SIZE) / 2, -(f.headerBottom - 3))
            header.paladin = p.name
            header.icon:SetTexture(RoleIconFor(p))
            header.initial:SetText(p.name:sub(1, 1))
            header.initial:SetTextColor(p.classInfo.colorRGB.r,
                p.classInfo.colorRGB.g, p.classInfo.colorRGB.b)
            header:Show()
        end
    end
    for i = hc + 1, #f.headerCells do
        f.headerCells[i]:Hide()
        f.headerCells[i].paladin = nil
    end

    -- One "Raider" label per visible block.
    for b = 1, #f.raiderLabels do
        local lbl = f.raiderLabels[b]
        if b <= numBlocks then
            lbl:ClearAllPoints()
            lbl:SetPoint("BOTTOMLEFT", f, "TOPLEFT", BlockX(b) + 4, -(f.headerBottom - 6))
            lbl:Show()
        else
            lbl:Hide()
        end
    end

    f.emptyHint:SetShown(#paladins == 0)

    -- One shared assignment-model snapshot supplies both cells and their
    -- Greater/Lesser classification (see Assignments.lua).
    local buffPlan = WhoDoesWhat.Assign.GetPaladinBuffPlan()
    local plan = buffPlan.grid

    for i, m in ipairs(members) do
        local row = f.rows[i] or CreateRow(f, i)
        -- Anchor into this row's block slot; the stripe follows the
        -- block-local position so both blocks stripe from their own top.
        local b = math.ceil(i / rowsPerBlock)
        local localRow = i - (b - 1) * rowsPerBlock
        row:SetWidth(blockW)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f, "TOPLEFT",
            BlockX(b), -(f.headerBottom + 4 + (localRow - 1) * ROW_H))
        local connected = m.isFake or not disconnected[m.name]
        local rowColors = connected and m.classInfo.gridRowColors
            or WhoDoesWhat.DisconnectedGridRowColors
        local rowColor = rowColors[localRow % 2 == 1 and 1 or 2]
        row.stripe:SetColorTexture(rowColor.r, rowColor.g, rowColor.b, rowColor.a)
        row:Show()
        row.roleIcon:SetTexture(RoleIconFor(m))
        row.roleIcon:SetDesaturated(not connected)
        row.nameFS:SetText("|cff" .. (connected and m.classInfo.colorHex or "909090")
            .. m.name .. "|r")

        local cellsFor = plan[m.name] or {}
        for c = 1, #paladins do
            local cell = row.cells[c] or CreateCell(f, row, c)
            cell.paladin = paladins[c].name
            cell.raider = m.name
            cell.buffKey = cellsFor[cell.paladin]
            if cell.buffKey then
                local buff = WhoDoesWhat.PaladinBuffs[cell.buffKey]
                local greater = buffPlan.greaterByPaladin[cell.paladin]
                cell.isGreater = greater
                    and greater[buffPlan.targetClass[m.name]] == cell.buffKey
                cell.icon:SetTexture(cell.isGreater and buff.icon or buff.normalIcon)
                cell.icon:Show()
            else
                cell.isGreater = nil
                cell.icon:Hide()
            end
            -- Gray + red outline only when the raider is confirmed to lack
            -- the planned buff; unknown and simulated cells never flag.
            local isMissing = cell.buffKey ~= nil
                and not WhoDoesWhat.Assign.IsSimulatedPaladinBuff(cell.paladin, m.name)
                and WhoDoesWhat:HasBuff(m.name, cell.buffKey) == false
            cell.missing:SetShown(isMissing)
            cell.icon:SetDesaturated(isMissing)
            cell:SetShown(connected)
        end
        for c = #paladins + 1, #row.cells do
            row.cells[c]:Hide()
        end
    end
    for i = #members + 1, #f.rows do
        f.rows[i]:Hide()
    end

    local gridH = f.headerBottom + 4 + rowsPerBlock * ROW_H + MARGIN
    f:SetHeight(math.max(gridH, MIN_FRAME_H))
end

-- Build the window once and reuse it. Everything parents straight onto the
-- window; RefreshGrid sizes it to the content.
local function EnsureGridFrame()
    if gridFrame then return gridFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatPaladinBuffGridFrame",
        MIN_FRAME_W, MIN_FRAME_H, "WhoDoesWhat - Paladin Buff Grid")

    -- "Rescan" in the title bar: force a fresh inspect of every reachable
    -- paladin (see WhoDoesWhat:RescanPaladinTalents).
    local rescan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    rescan:SetSize(60, 18)
    rescan:SetPoint("TOPRIGHT", -28, -6)
    rescan:SetText("Rescan")
    rescan:SetScript("OnClick", function() WhoDoesWhat:RescanPaladinTalents() end)
    rescan:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText("Rescan talents", 1, 1, 1)
        GameTooltip:AddLine("Force a fresh inspect of every paladin in range."
            .. " Out-of-range paladins keep their last-known ranks until they"
            .. " come closer.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    rescan:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Everything in the grid header hangs off this: the y where the paladin
    -- role icons stand and the rows begin.
    f.headerBottom = f.titleBarHeight + 8 + HEADER_H

    -- One "Raider" label per possible block; RefreshGrid positions and shows
    -- however many blocks are in use.
    f.raiderLabels = {}
    for b = 1, 2 do
        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetText("Raider")
        lbl:Hide()
        f.raiderLabels[b] = lbl
    end

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", GRID_X, -f.headerBottom)
    divider:SetPoint("TOPRIGHT", -MARGIN, -f.headerBottom)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMLEFT", f, "TOPLEFT",
        GRID_X + NAME_COL_W + 6, -(f.headerBottom - 6))
    hint:SetTextColor(0.55, 0.55, 0.55)
    hint:SetText("No paladins in the group.")
    f.emptyHint = hint

    WhoDoesWhat:LogUiBuilding("Building paladin buff grid content.")

    f.headerCells = {}
    f.rows = {}

    -- Track joins/leaves live while the window is open.
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:RegisterEvent("UNIT_CONNECTION")
    f:SetScript("OnEvent", function(self)
        if self:IsShown() then
            RefreshGrid(self)
        end
    end)

    gridFrame = f
    return f
end

-- Repaint the grid if the window is up. Called from outside the view when
-- buff assignments change (SetAssignment / auto-assign) or talent data
-- arrives (TalentScanning.lua, Sync.lua). This is the de-facto "buff plan
-- changed" hook, so it also nudges the compact status views -- every plan-
-- mutation site already routes through here, and their refreshes no-op while
-- hidden.
function WhoDoesWhat:RefreshPaladinBuffGridView()
    if gridFrame and gridFrame:IsShown() then
        RefreshGrid(gridFrame)
    end
    self:RefreshRaiderTooltip()
    self:RefreshPaladinBuffingBar()
    self:RefreshStatusBarsView()
end

-- Toggle the grid window open/closed. Shown before the refresh so the
-- header-name rotation animations play against a visible frame.
function WhoDoesWhat:OpenPaladinBuffGridView()
    local f = EnsureGridFrame()

    if f:IsShown() then
        self:LogUiBuilding("Paladin Buff Grid View open, closing it.")
        f:Hide()
        return
    end

    self:LogUiBuilding("Opening Paladin Buff Grid View...")
    f:Show()
    RefreshGrid(f)
    f:Raise()
end
