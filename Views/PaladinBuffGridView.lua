local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Paladin Info + Grid ("Info + Grid" button on the main view): one window,
-- two panes, no scrolling -- the window sizes itself to its content each
-- refresh. The left pane is one box per group paladin with their four
-- buff-talent ranks in a 2x2 square plus their WDW/PallyPower availability
-- (the old Paladin Info window, folded in and condensed). The right pane is
-- the buff grid: every raiding group
-- member down the left with their role icon (Non-raiders are left out
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
-- Talent data arrives asynchronously (LibClassicInspector), so a freshly-seen
-- paladin's talent lines read a gray "?" until their data lands; the title
-- bar's Rescan button force-inspects every reachable paladin.
--
-- The paladin names are drawn vertically (90 degrees) so a column only needs
-- to be an icon wide. FontStrings can't be rotated directly; the trick is a
-- zero-duration Rotation animation that never ends (huge end delay), which
-- holds the string at its rotated angle indefinitely. Hidden frames stop
-- their animations, so every refresh re-Plays them -- and the window always
-- refreshes on open.

local gridFrame = nil

local MIN_FRAME_W = 500 -- floor for the title text + title-bar buttons; width tracks columns
local MIN_FRAME_H = 260 -- floor so an empty group still shows the chrome
local MARGIN = 12

local NAME_COL_W = 150 -- role icon + raider name
local COL_W = 26       -- one paladin column
local ROW_H = 22
local ROLE_ICON_SIZE = 16
local CELL_SIZE = 20
local CELL_ICON_SIZE = 16
local HEADER_H = 90    -- room for the angled names

-- Grid blocks: at this many raiders (or more) the rows split into two
-- side-by-side blocks (balanced halves) rather than making the window taller.
local SPLIT_AT_ROWS = 20
local BLOCK_GAP = 14

-- Left pane: the per-paladin info boxes; the grid pane starts at GRID_X.
local INFO_COL_W = 270
local PANE_GAP = 10
local GRID_X = MARGIN + INFO_COL_W + PANE_GAP
local INFO_BOX_PAD = 8
local INFO_GAP = 10 -- vertical gap between paladin boxes
-- Vertical layout inside a paladin box (offsets from the box top): the name
-- line, a divider, then the four talent lines in a 2x2 square (two per row,
-- so only two line-heights).
local INFO_NAME_Y = INFO_BOX_PAD
local INFO_DIVIDER_Y = INFO_BOX_PAD + 20
local INFO_TALENT_Y0 = INFO_BOX_PAD + 26
local INFO_LINE_H = 16
local INFO_ADDON_DIVIDER_Y = INFO_TALENT_Y0 + 2 * INFO_LINE_H + 2
local INFO_ADDON_Y = INFO_ADDON_DIVIDER_Y + 7
local INFO_BOX_H = INFO_ADDON_Y + INFO_LINE_H + INFO_BOX_PAD

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

-- ---------------------------------------------------------------------------
-- Left pane: per-paladin info boxes
-- ---------------------------------------------------------------------------

-- The four talent-affected blessings, in the order the box lists them
-- (Sanctuary last -- it's the nichest of the four). The 1-point talents
-- (max 1) *grant* their blessing outright -- an untalented paladin can't cast
-- Kings or Sanctuary at all -- while the graded ones improve a baseline
-- blessing every paladin already has. Salvation and Light have no talent, so
-- they aren't listed here.
local TALENT_LINES = {
    { key = "kings",  max = 1 },
    { key = "might",  max = 5 },
    { key = "wisdom", max = 2 },
    { key = "sanctuary", max = 1 },
}

-- Inline icon markup for a buff key, at the given pixel size.
local function BuffIcon(key, size)
    return "|T" .. WhoDoesWhat.PaladinBuffs[key].iconId .. ":" .. size .. ":" .. size .. ":0:0|t"
end

-- One talent line's text: icon + blessing name + a colored status. nil rank
-- (talents not seen yet) reads a gray "?" -- the lines share a 2x2 square,
-- so the status has half a box width at most; an untalented gated blessing
-- collapses to a red X + red name (they can't cast it at all); a graded one
-- shows "n/max" colored by fullness.
local function TalentLineText(line, rank)
    local buff = WhoDoesWhat.PaladinBuffs[line.key]
    local lead = BuffIcon(line.key, 14) .. " " .. buff.name_long

    if rank == nil then
        return lead .. ": |cff909090?|r"
    end
    if line.max == 1 then
        if rank >= 1 then
            return lead .. ": |cff40ff40Talented|r"
        end
        return "|cffff6060X|r " .. BuffIcon(line.key, 14)
            .. " |cffff6060" .. buff.name_long .. "|r"
    end

    local color
    if rank >= line.max then
        color = "40ff40" -- full ranks: green
    elseif rank > 0 then
        color = "ffd000" -- partial: gold
    else
        color = "909090" -- none: gray (baseline blessing still castable)
    end
    return lead .. ": |cff" .. color .. rank .. "/" .. line.max .. "|r"
end

-- Build pooled info box #index. Its fontstrings are filled by RefreshInfoPane;
-- the boxes are anchor-chained so a changing count ripples down on its own.
local function CreateInfoBox(f, index)
    local box = CreateFrame("Frame", nil, f, "BackdropTemplate")
    box:SetFrameLevel(f:GetFrameLevel() + 1)
    box:SetWidth(INFO_COL_W)
    box:SetHeight(INFO_BOX_H)
    local prev = f.infoBoxes[index - 1]
    if prev then
        box:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -INFO_GAP)
    else
        box:SetPoint("TOPLEFT", f, "TOPLEFT", MARGIN, -f.infoTop)
    end
    box:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    box:SetBackdropColor(0.16, 0.16, 0.18, 0.9)
    box:SetBackdropBorderColor(0.4, 0.4, 0.4)

    local nameFS = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameFS:SetPoint("TOPLEFT", INFO_BOX_PAD + 2, -INFO_NAME_Y)
    box.nameFS = nameFS

    local line = box:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", INFO_BOX_PAD, -INFO_DIVIDER_Y)
    line:SetPoint("TOPRIGHT", -INFO_BOX_PAD, -INFO_DIVIDER_Y)

    -- The four talent lines as a 2x2 square, row-major (kings | might over
    -- wisdom | sanctuary), each line owning half the box width.
    box.talentFS = {}
    local halfW = (INFO_COL_W - INFO_BOX_PAD * 2) / 2
    for i = 1, #TALENT_LINES do
        local col = (i - 1) % 2
        local rowI = math.floor((i - 1) / 2)
        local fs = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", INFO_BOX_PAD + 4 + col * halfW,
            -(INFO_TALENT_Y0 + rowI * INFO_LINE_H))
        fs:SetJustifyH("LEFT")
        box.talentFS[i] = fs
    end

    local addonLine = box:CreateTexture(nil, "ARTWORK")
    addonLine:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    addonLine:SetHeight(1)
    addonLine:SetPoint("TOPLEFT", INFO_BOX_PAD, -INFO_ADDON_DIVIDER_Y)
    addonLine:SetPoint("TOPRIGHT", -INFO_BOX_PAD, -INFO_ADDON_DIVIDER_Y)

    box.addonFS = {}
    for i = 1, 2 do
        local fs = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", INFO_BOX_PAD + 4 + (i - 1) * halfW, -INFO_ADDON_Y)
        fs:SetJustifyH("LEFT")
        box.addonFS[i] = fs
    end

    f.infoBoxes[index] = box
    return box
end

local function AddonStatusText(label, installed)
    return "|cff" .. (installed and "40ff40" or "ff6060") .. label
        .. ": " .. (installed and "Yes" or "No") .. "|r"
end

-- Map the current paladins onto pooled info boxes and hide the surplus.
local function RefreshInfoPane(f, paladins)
    for i, m in ipairs(paladins) do
        local box = f.infoBoxes[i] or CreateInfoBox(f, i)
        box:Show()
        box.nameFS:SetText("|cff" .. m.classInfo.colorHex .. m.name .. "|r")

        local talents = WhoDoesWhat:GetPaladinBuffTalents(m.name)
        for j, line in ipairs(TALENT_LINES) do
            box.talentFS[j]:SetText(TalentLineText(line, talents and talents[line.key]))
        end
        box.addonFS[1]:SetText(AddonStatusText("PallyPower",
            WhoDoesWhat:PaladinHasPallyPower(m.name)))
        box.addonFS[2]:SetText(AddonStatusText("WDW",
            m.name == UnitName("player") or WhoDoesWhat.syncPeers[m.name] == true))
    end
    for i = #paladins + 1, #f.infoBoxes do
        f.infoBoxes[i]:Hide()
    end

    f.infoHint:SetShown(#paladins == 0)
end

-- ---------------------------------------------------------------------------
-- Right pane: the buff grid
-- ---------------------------------------------------------------------------

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

-- One angled header name, pooled flat across blocks (RefreshGrid positions
-- it each pass). Anchored by its (pre-rotation) bottom-left at the column's
-- base on the header divider; rotating +90 around that same corner swings
-- the text straight up (vertical, reading bottom-to-top).
local function CreateHeaderCell(f, index)
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetJustifyH("LEFT")

    local ag = fs:CreateAnimationGroup()
    local rot = ag:CreateAnimation("Rotation")
    rot:SetDegrees(75)
    rot:SetDuration(0)
    rot:SetEndDelay(2147483647) -- hold the angle "forever"
    rot:SetOrigin("BOTTOMLEFT", 0, 0)

    f.headerCells[index] = { fs = fs, ag = ag }
    return f.headerCells[index]
end

-- One grid cell (a button already, for the later click-to-customize).
-- Refresh fills cell.paladin / cell.raider / cell.buffKey before showing it.
local function CreateCell(f, row, c)
    local cell = CreateFrame("Button", nil, row)
    cell:SetSize(CELL_SIZE, CELL_SIZE)
    cell:SetPoint("LEFT", row, "LEFT",
        NAME_COL_W + (c - 1) * COL_W + (COL_W - CELL_SIZE) / 2, 0)

    -- Red backdrop, shown when this raider is confirmed to be MISSING the
    -- blessing this cell plans for them (BuffTracking.lua). Behind the icon so
    -- the planned buff still reads through it; hidden while they have it or
    -- while their state is unknown -- not yet scanned or no real unit (see
    -- WhoDoesWhat:HasBuff).
    local missing = cell:CreateTexture(nil, "BACKGROUND")
    missing:SetAllPoints()
    missing:SetColorTexture(0.8, 0.1, 0.1, 0.4)
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
                .. WhoDoesWhat.PaladinBuffs[self.buffKey].name_long .. ".",
                0.8, 0.8, 0.8, true)
            if WhoDoesWhat:HasBuff(self.raider, self.buffKey) == false then
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

-- One pooled raider row: alternate-row stripe (toggled by the refresh, since
-- a row's block-local position moves as the group changes), role icon,
-- class-colored name; the buff cells hang off it per column. RefreshGrid
-- anchors it into its block each pass.
local function CreateRow(f, index)
    local row = CreateFrame("Frame", nil, f)
    row:SetFrameLevel(f:GetFrameLevel() + 1)
    row:SetHeight(ROW_H)

    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    stripe:SetColorTexture(1, 1, 1, 0.04)
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
-- content: width tracks the paladin count and block count, height whichever
-- pane is taller. No scrolling anywhere.
local function RefreshGrid(f)
    local members = SortedMembers()
    local paladins = GroupPaladins()

    RefreshInfoPane(f, paladins)

    local numBlocks = (#members >= SPLIT_AT_ROWS) and 2 or 1
    local rowsPerBlock = math.ceil(#members / numBlocks)
    local blockW = NAME_COL_W + math.max(#paladins, 1) * COL_W
    local function BlockX(b)
        return GRID_X + (b - 1) * (blockW + BLOCK_GAP)
    end

    f:SetWidth(math.max(MIN_FRAME_W,
        GRID_X + numBlocks * blockW + (numBlocks - 1) * BLOCK_GAP + MARGIN))

    -- Angled paladin names above every block, from one flat pool.
    local hc = 0
    for b = 1, numBlocks do
        for c, p in ipairs(paladins) do
            hc = hc + 1
            local cell = f.headerCells[hc] or CreateHeaderCell(f, hc)
            cell.fs:ClearAllPoints()
            cell.fs:SetPoint("BOTTOMLEFT", f, "TOPLEFT",
                BlockX(b) + NAME_COL_W + (c - 1) * COL_W + COL_W / 2 - 5, -(f.headerBottom + 6))
            cell.fs:SetText("|cff" .. p.classInfo.colorHex .. p.name .. "|r")
            cell.fs:Show()
            cell.ag:Stop()
            cell.ag:Play() -- re-apply the angle (hidden frames stop animations)
        end
    end
    for i = hc + 1, #f.headerCells do
        f.headerCells[i].fs:Hide()
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

    -- The computed per-raider coverage (see Assignments.lua).
    local plan = WhoDoesWhat.Assign.ComputeBuffGrid()

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
        row.stripe:SetShown(localRow % 2 == 1)
        row:Show()
        row.roleIcon:SetTexture(RoleIconFor(m))
        row.nameFS:SetText("|cff" .. m.classInfo.colorHex .. m.name .. "|r")

        local cellsFor = plan[m.name] or {}
        for c = 1, #paladins do
            local cell = row.cells[c] or CreateCell(f, row, c)
            cell.paladin = paladins[c].name
            cell.raider = m.name
            cell.buffKey = cellsFor[cell.paladin]
            if cell.buffKey then
                cell.icon:SetTexture(WhoDoesWhat.PaladinBuffs[cell.buffKey].iconId)
                cell.icon:Show()
            else
                cell.icon:Hide()
            end
            -- Red only when the raider is confirmed to lack the planned buff;
            -- unknown (nil -- not yet scanned, or pets with no unit) never flags.
            cell.missing:SetShown(cell.buffKey ~= nil
                and WhoDoesWhat:HasBuff(m.name, cell.buffKey) == false)
            cell:Show()
        end
        for c = #paladins + 1, #row.cells do
            row.cells[c]:Hide()
        end
    end
    for i = #members + 1, #f.rows do
        f.rows[i]:Hide()
    end

    -- Height to the taller pane, chrome included.
    local infoH = f.infoTop + #paladins * (INFO_BOX_H + INFO_GAP) + MARGIN
    local gridH = f.headerBottom + 4 + rowsPerBlock * ROW_H + MARGIN
    f:SetHeight(math.max(infoH, gridH, MIN_FRAME_H))
end

-- Build the window once and reuse it: shared chrome, the info pane on the
-- left, and on the right the header strip for the angled names plus the
-- raider-row blocks. Everything parents straight onto the window -- no
-- scroll frames; RefreshGrid sizes the window to the content instead.
local function EnsureGridFrame()
    if gridFrame then return gridFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatPaladinBuffGridFrame",
        MIN_FRAME_W, MIN_FRAME_H, "WhoDoesWhat - Paladin Info + Grid")

    -- "Rescan" in the title bar: force a fresh inspect of every reachable
    -- paladin (see WhoDoesWhat:RescanPaladinTalents). Talent data only arrives
    -- for paladins the library can inspect in range, so this is the fix when a
    -- box reads the wrong ranks (typically Kings/Sanctuary as untalented).
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

    -- Left pane origin: where the first info box hangs (CreateInfoBox).
    f.infoTop = f.titleBarHeight + 10

    local infoHint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    infoHint:SetPoint("TOPLEFT", MARGIN + 4, -(f.infoTop + 4))
    infoHint:SetTextColor(0.55, 0.55, 0.55)
    infoHint:SetText("No paladins in the group.")
    f.infoHint = infoHint

    -- Vertical divider between the panes, centered in PANE_GAP. Anchored to
    -- the window bottom, so it follows the computed height.
    local vline = f:CreateTexture(nil, "ARTWORK")
    vline:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    vline:SetWidth(1)
    vline:SetPoint("TOPLEFT", GRID_X - PANE_GAP / 2, -f.infoTop)
    vline:SetPoint("BOTTOMLEFT", GRID_X - PANE_GAP / 2, MARGIN)

    -- Everything in the grid header hangs off this: the y where the angled
    -- names stand and the rows begin.
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

    WhoDoesWhat:LogUiBuilding("Building paladin info + grid content.")

    f.headerCells = {}
    f.rows = {}
    f.infoBoxes = {}

    -- Track joins/leaves live while the window is open.
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:SetScript("OnEvent", function(self)
        if self:IsShown() then
            RefreshGrid(self)
        end
    end)

    gridFrame = f
    return f
end

-- Repaint (both panes) if the window is up. Called from outside the view when
-- buff assignments change (SetAssignment / auto-assign) or talent data
-- arrives (TalentScanning.lua, Sync.lua). This is the de-facto "buff plan
-- changed" hook, so it also nudges the buffing bar -- every plan-mutation site
-- already routes through here, and the bar refresh no-ops when it's hidden.
function WhoDoesWhat:RefreshPaladinBuffGridView()
    if gridFrame and gridFrame:IsShown() then
        RefreshGrid(gridFrame)
    end
    self:RefreshPaladinBuffingBar()
end

-- Toggle the info + grid window open/closed. Shown before the refresh so the
-- header-name rotation animations play against a visible frame.
function WhoDoesWhat:OpenPaladinBuffGridView()
    local f = EnsureGridFrame()

    if f:IsShown() then
        self:LogUiBuilding("Paladin Info + Grid View open, closing it.")
        f:Hide()
        return
    end

    self:LogUiBuilding("Opening Paladin Info + Grid View...")
    f:Show()
    self:RequestPallyPowerPeers()
    RefreshGrid(f)
    f:Raise()
end
