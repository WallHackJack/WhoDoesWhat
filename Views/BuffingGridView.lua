local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Buffing Grid ("Buffing Grid" button on the main view): raid-wide buff
-- status columns followed by every paladin's blessing for each raider. The
-- blessing columns can show WDW's plan, WDW's PLPWR wire mirror, or the live
-- tables of a co-installed PallyPower addon.
-- At SPLIT_AT_ROWS raiders (or more) the grid splits into balanced side-by-side
-- blocks instead of growing taller.
--
-- Grid cells can show WDW's computed plan, a co-installed PallyPower's live
-- tables, or WDW's observed PallyPower mirror. A paladin with no assignment
-- for a raider shows an empty cell. Per-cell
-- click-to-customize is the plan for later, which is why the cells are
-- already buttons.
--
-- Each paladin column is headed by their role icon with an outlined initial;
-- hovering it opens the shared paladin detail tooltip.

local gridFrame = nil
local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit

local OPTIONS_BUTTON = "Interface\\AddOns\\WhoDoesWhat\\Media\\UI-Panel-OptionsButton-"

local MIN_FRAME_W = 330 -- floor for the title text + title-bar buttons; width tracks columns
local MIN_FRAME_H = 260 -- floor so an empty group still shows the chrome
local MARGIN = 12

local NAME_COL_W = 150 -- role icon + raider name (minimum; grows to fill)
-- The name column absorbs whatever width the window has beyond its columns,
-- so a narrow grid still spans the window's minimum width. RefreshGrid sets it.
local nameColW = NAME_COL_W
local COL_W = K.PALADIN_GRID_COL_W -- one paladin column
local ROW_H = 22
local ROLE_ICON_SIZE = 18
local CELL_SIZE = K.PALADIN_GRID_CELL_SIZE
local HEADER_H = 28
local SOURCE_ROW_H = 27
local CORE_CELL_ICON_SIZE = 16
local CORE_MISSING_ICON = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local PALADIN_SECTION_GAP = 12

local SOURCE_OPTIONS = {
    { key = "wdw", label = "WDW" },
    { key = "observed", label = "PP Mirror" },
    { key = "addon", label = "PP Addon" },
}
local SOURCE_LABELS = { wdw = "WDW", observed = "PP Mirror", addon = "PP Addon" }

-- Grid blocks: at this many raiders (or more) the rows split into two
-- side-by-side blocks (balanced halves) rather than making the window taller.
local SPLIT_AT_ROWS = 20
local BLOCK_GAP = 14
local GRID_X = MARGIN

local function RemainingText(seconds)
    seconds = math.ceil(seconds)
    if seconds >= 60 then
        return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
    end
    return seconds .. "s"
end

local function VisibleCoreBuffKeys(coverageByKey)
    local keys = {}
    for _, key in ipairs(WhoDoesWhat.StatusBarCheckOrder) do
        local options = WhoDoesWhat:GetStatusBarCheckOptions(key)
        local coverage = coverageByKey[key]
        -- The coverage pass answers this where it ran, and on a gated check
        -- (Divine Spirit) it has the fuller answer: the class can be standing
        -- right here without the talent that grants the buff.
        local unavailable = coverage and not coverage.available
            or (not coverage and options.requiredClass
                and #A.MembersOfClass(options.requiredClass) == 0)
        local complete = coverage and coverage.total > 0
            and (options.negative and coverage.correct == 0
                or not options.negative and coverage.correct >= coverage.total)
        if options.grid
            and not (options.hideColumnUnavailable and unavailable)
            and not (options.hideColumnComplete and complete) then
            keys[#keys + 1] = key
        end
    end
    return keys
end

local function RankColor(rank, maxRank)
    if rank == nil then return 0.55, 0.55, 0.55 end
    if rank >= maxRank then return 0.25, 1, 0.25 end
    if rank > 0 then return 1, 0.82, 0 end
    return 1, 0.4, 0.4
end

local ImprovedProviders = A.ComputeCoreBuffProviders

local function BestAvailableProvider(providers)
    local best
    for _, provider in ipairs(providers) do
        -- Offspec providers are skipped: this drives "Better available from
        -- X" on a cell, and a caster who would have to respec first is not
        -- somebody to go ask for a rebuff.
        if provider.available and provider.rank ~= nil and not provider.offspec
            and (not best or provider.rank > best.rank) then
            best = provider
        end
    end
    return best
end

-- Group members sorted class > role > name (same ordering the Members page
-- buckets use), so classes clump together down the left side. Non-raiders
-- (the unit-menu pseudo-role) are sitting out and get no grid row. Hunter
-- pets ride along as virtual rows (their own plan cells). They keep Hunter
-- metadata/colors, but sort as a separate section directly after Warriors.
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
        local classA = a.isPet and "Warrior" or a.classInfo.name
        local classB = b.isPet and "Warrior" or b.classInfo.name
        if classA ~= classB then
            return classA < classB
        end
        -- Real Warriors first, then the pet section beneath them.
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
    return K.OrderPaladinsLocalFirst(out)
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

-- One icon raid-buff header, pooled flat across blocks.
local function CreateCoreHeader(f, index)
    local header = CreateFrame("Button", nil, f)
    header:SetSize(CELL_SIZE, CELL_SIZE)
    local icon = header:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    header.icon = icon
    header:SetScript("OnEnter", function(self)
        local buff = WhoDoesWhat.StatusBarChecks[self.buffKey]
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(buff.gridName or buff.name, 1, 1, 1)
        GameTooltip:AddLine(buff.description or "Tracked raid status.",
            0.8, 0.8, 0.8, true)
        if self.available == false then
            GameTooltip:AddLine("Unavailable: requires " .. self.requiredClass .. ".",
                1, 0.45, 0.2, true)
        end
        if buff.improvedTalent then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(buff.improvedTalent.name .. " providers:", 1, 0.82, 0)
            for _, provider in ipairs(self.providers or {}) do
                local rank = provider.rank == nil and "?" or provider.rank
                -- "offspec": the rank is real but their current spec can't
                -- cast the buff at all (see requiredTalent in Data.lua).
                local suffix = (provider.offspec and " (offspec)" or "")
                    .. (provider.available and "" or " (offline)")
                GameTooltip:AddLine(provider.name .. ": " .. rank .. "/"
                    .. buff.improvedTalent.maxRank .. suffix,
                    RankColor(provider.rank, buff.improvedTalent.maxRank))
            end
        end
        GameTooltip:Show()
    end)
    header:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.coreHeaders[index] = header
    return header
end

-- One compact paladin header, pooled flat across blocks.
local function CreatePaladinHeader(f, index)
    local header = K.CreatePaladinGridHeader(f)

    header:SetScript("OnEnter", function(self)
        WhoDoesWhat:ShowRaiderTooltip(self, self.paladin)
    end)
    header:SetScript("OnLeave", function() WhoDoesWhat:HideRaiderTooltip() end)

    f.paladinHeaders[index] = header
    return header
end

local function PositionCell(cell, row, column)
    cell:ClearAllPoints()
    cell:SetPoint("LEFT", row, "LEFT",
        nameColW + (column - 1) * COL_W + (COL_W - CELL_SIZE) / 2, 0)
end

local function PositionPaladinCell(cell, row, coreCount, paladinColumn, paladins)
    cell:ClearAllPoints()
    cell:SetPoint("LEFT", row, "LEFT",
        nameColW + coreCount * COL_W + PALADIN_SECTION_GAP
            + K.PaladinColumnOffset(paladinColumn, paladins, COL_W)
            + (COL_W - CELL_SIZE) / 2, 0)
end

local function CreateCoreCell(row, column)
    local cell = CreateFrame("Button", nil, row)
    cell:SetSize(CELL_SIZE, CELL_SIZE)
    PositionCell(cell, row, column)

    local missing = cell:CreateTexture(nil, "OVERLAY")
    missing:SetTexture(CORE_MISSING_ICON)
    missing:SetSize(CORE_CELL_ICON_SIZE, CORE_CELL_ICON_SIZE)
    missing:SetPoint("CENTER")
    missing:Hide()
    cell.missing = missing

    local warning = cell:CreateTexture(nil, "ARTWORK")
    warning:SetTexture(WhoDoesWhat.WARNING_ICON)
    warning:SetSize(CORE_CELL_ICON_SIZE, CORE_CELL_ICON_SIZE)
    warning:SetPoint("CENTER")
    warning:Hide()
    cell.warning = warning

    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetSize(CORE_CELL_ICON_SIZE, CORE_CELL_ICON_SIZE)
    icon:SetPoint("CENTER")
    cell.icon = icon

    cell:SetScript("OnEnter", function(self)
        local buff = WhoDoesWhat.StatusBarChecks[self.buffKey]
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(buff.name .. " - "
            .. WhoDoesWhat:DisplayName(self.raider), 1, 1, 1)
        if self.notNeeded then
            GameTooltip:AddLine("Not required for this class.", 0.6, 0.6, 0.6)
        elseif not self.connected then
            GameTooltip:AddLine("Aura state is unavailable while this raider is offline.",
                0.6, 0.6, 0.6, true)
        elseif self.negative and self.hasBuff == true then
            GameTooltip:AddLine("Has the debuff.", 1, 0.3, 0.3)
            local remaining = WhoDoesWhat:GetBuffTimeRemaining(
                self.raider, self.buffKey)
            if remaining then
                GameTooltip:AddLine(RemainingText(remaining) .. " remaining.",
                    1, 0.82, 0)
            end
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
            -- Otherwise this cell reads "Active." in green for a buff the
            -- status bar is counting as missing.
            local check = WhoDoesWhat.StatusBarChecks[self.buffKey]
            if check and WhoDoesWhat:GetStatusBarCheckOptions(
                    self.buffKey).flagOutsideRaid
                and WhoDoesWhat:IsBuffFromOutsideRaid(
                    self.raider, self.buffKey) then
                GameTooltip:AddLine("Cast from outside the raid; pulling a boss"
                    .. " strips it.", 1, 0.45, 0.2, true)
            end
            if self.betterProvider then
                GameTooltip:AddLine("Better available from "
                    .. self.betterProvider.name .. " ("
                    .. self.betterProvider.rank .. "/" .. maxRank .. ").",
                    1, 0.45, 0.2, true)
            end
        elseif self.negative and self.hasBuff == false then
            GameTooltip:AddLine("Does not have the debuff.", 0.3, 1, 0.3)
        elseif self.hasBuff == false then
            GameTooltip:AddLine("Missing this buff.", 1, 0.3, 0.3)
        else
            GameTooltip:AddLine("Aura state has not been scanned yet.", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.coreCells[column] = cell
    return cell
end

-- One grid cell (a button already, for the later click-to-customize).
-- Refresh fills cell.paladin / cell.raider / cell.buffKey before showing it.
local function CreatePaladinCell(row, c)
    local cell = K.CreatePaladinBuffCell(row, CELL_SIZE)
    PositionCell(cell, row, c)
    cell.missing = cell.alert

    cell:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local raider = WhoDoesWhat:DisplayName(self.raider)
        if self.buffKey then
            GameTooltip:SetText(self.paladin, 1, 1, 1)
            GameTooltip:AddLine("Blesses " .. raider .. " with "
                .. (self.isGreater and "Greater Blessing of " or "Blessing of ")
                .. WhoDoesWhat.PaladinBuffs[self.buffKey].name_long
                .. (self.isGreater and "." or " (Lesser)."),
                0.8, 0.8, 0.8, true)
            if not WhoDoesWhat.Assign.IsSimulatedPaladinBuff(self.paladin, self.raider)
                and WhoDoesWhat:HasBuff(self.raider, self.buffKey) == false then
                GameTooltip:AddLine(raider .. " is missing this buff.",
                    1, 0.3, 0.3, true)
            end
        else
            GameTooltip:SetText(self.paladin, 1, 1, 1)
            if self.gridSource == "wdw" then
                GameTooltip:AddLine("Nothing for " .. raider .. ": every blessing"
                    .. " they want at this paladin count is already covered, or needs"
                    .. " a talent " .. self.paladin .. " doesn't have.",
                    0.6, 0.6, 0.6, true)
            else
                local source = self.gridSource == "addon"
                    and "the local PallyPower addon" or "observed PallyPower traffic"
                GameTooltip:AddLine("No assignment for " .. raider .. " in "
                    .. source .. ".", 0.6, 0.6, 0.6, true)
            end
        end
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.paladinCells[c] = cell
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

    row.coreCells = {}
    row.paladinCells = {}
    f.rows[index] = row
    return row
end

local function HasPallyPowerAddon()
    return _G.PallyPower and _G.PallyPower_Assignments
        and _G.PallyPower_NormalAssignments
end

local function DefaultGridSource()
    if WhoDoesWhat.db.profile.settings.pallyBuffSource == "pallypower" then
        return HasPallyPowerAddon() and "addon" or "observed"
    end
    return "wdw"
end

local function UpdateSourceControl(f)
    local expected = DefaultGridSource()
    local pallyPowerMode = WhoDoesWhat.db.profile.settings.pallyBuffSource == "pallypower"
    local matchesMode = f.gridSource == expected
        or (pallyPowerMode and (f.gridSource == "addon" or f.gridSource == "observed"))
    UIDropDownMenu_SetText(f.sourceDD, SOURCE_LABELS[f.gridSource] or "WDW")
    if not matchesMode then
        f.sourceWarning.tooltipText = "Paladin blessing cells are showing "
            .. (SOURCE_LABELS[f.gridSource] or "this source")
            .. " for comparison only. They do not represent the raid's active"
            .. " assignment source. Select " .. SOURCE_LABELS[expected]
            .. " to view the plan currently driving WDW. Missing-buff indicators"
            .. " still use live aura data."
        f.sourceWarning:Show()
    else
        f.sourceWarning:Hide()
    end
end

local function BuffPlanForSource(source)
    if source == "observed" then
        return WhoDoesWhat:GetPallyPowerBuffPlan("observed")
    elseif source == "addon" then
        return WhoDoesWhat:GetPallyPowerBuffPlan("addon")
    end
    return WhoDoesWhat.Assign.GetPaladinBuffPlan()
end

-- Map the current group onto the pooled widgets and size the window to its
-- content: width tracks the paladin count and block count. No scrolling.
local function RefreshGrid(f)
    local members = SortedMembers()
    local paladins = GroupPaladins()
    local _, _, coverage = A.ComputeCoreRaidBuffCoverage()
    local coverageByKey = {}
    for _, row in ipairs(coverage) do coverageByKey[row.key] = row end
    local coreKeys = VisibleCoreBuffKeys(coverageByKey)
    local disconnected = WhoDoesWhat.Assign.DisconnectedGroupTargets()
    local providerPools, bestProviders, coreOptions = {}, {}, {}
    for _, key in ipairs(coreKeys) do
        providerPools[key] = ImprovedProviders(key, disconnected)
        bestProviders[key] = BestAvailableProvider(providerPools[key])
        coreOptions[key] = WhoDoesWhat:GetStatusBarCheckOptions(key)
    end

    -- With no paladins in the group there is nothing for the blessing source
    -- row to control, so the header collapses to just the column icons.
    local hasPaladins = #paladins > 0
    f.sourceCaption:SetShown(hasPaladins)
    f.sourceDD:SetShown(hasPaladins)
    f.headerBottom = f.titleBarHeight + 8 + HEADER_H
        + (hasPaladins and SOURCE_ROW_H or 0)
    f.divider:ClearAllPoints()
    f.divider:SetPoint("TOPLEFT", GRID_X, -f.headerBottom)
    f.divider:SetPoint("TOPRIGHT", -MARGIN, -f.headerBottom)

    local numBlocks = (#members >= SPLIT_AT_ROWS) and 2 or 1
    local rowsPerBlock = math.ceil(#members / numBlocks)
    local paladinGap = hasPaladins and PALADIN_SECTION_GAP or 0
    local columnsW = #coreKeys * COL_W + paladinGap
        + K.PaladinColumnsWidth(paladins, COL_W, 0)
    local gaps = GRID_X + (numBlocks - 1) * BLOCK_GAP + MARGIN
    local frameW = math.max(MIN_FRAME_W,
        gaps + numBlocks * (NAME_COL_W + columnsW))
    -- Spend the window's leftover width on the name column so the blocks
    -- always reach the right edge, even at the minimum window width.
    nameColW = (frameW - gaps) / numBlocks - columnsW
    local blockW = nameColW + columnsW
    local function BlockX(b)
        return GRID_X + (b - 1) * (blockW + BLOCK_GAP)
    end

    f:SetWidth(frameW)

    -- Raid-buff icon headers above every block, from one flat pool.
    local coreHeaderCount = 0
    for b = 1, numBlocks do
        for c, key in ipairs(coreKeys) do
            coreHeaderCount = coreHeaderCount + 1
            local header = f.coreHeaders[coreHeaderCount]
                or CreateCoreHeader(f, coreHeaderCount)
            header:ClearAllPoints()
            header:SetPoint("BOTTOMLEFT", f, "TOPLEFT",
                BlockX(b) + nameColW + (c - 1) * COL_W
                    + (COL_W - CELL_SIZE) / 2, -(f.headerBottom - 3))
            header.buffKey = key
            header.providers = providerPools[key]
            local options = coreOptions[key]
            local rowCoverage = coverageByKey[key]
            if rowCoverage then
                -- Same fuller answer VisibleCoreBuffKeys uses, and the name it
                -- carries is the talent rather than the class where the class
                -- is present without it.
                header.available = rowCoverage.available
                header.requiredClass = rowCoverage.unavailableName
            else
                header.available = not options.requiredClass
                    or A.HasMemberOfClass(options.requiredClass)
                header.requiredClass = options.requiredClass
            end
            header.icon:SetTexture(WhoDoesWhat.StatusBarChecks[key].icon)
            header:Show()
        end
    end
    for i = coreHeaderCount + 1, #f.coreHeaders do
        f.coreHeaders[i]:Hide()
        f.coreHeaders[i].buffKey = nil
        f.coreHeaders[i].providers = nil
        f.coreHeaders[i].requiredClass = nil
        f.coreHeaders[i].available = nil
    end

    -- Role-icon paladin headers follow the raid-buff columns.
    local paladinHeaderCount = 0
    for b = 1, numBlocks do
        for c, p in ipairs(paladins) do
            paladinHeaderCount = paladinHeaderCount + 1
            local header = f.paladinHeaders[paladinHeaderCount]
                or CreatePaladinHeader(f, paladinHeaderCount)
            header:ClearAllPoints()
            header:SetPoint("BOTTOMLEFT", f, "TOPLEFT",
                BlockX(b) + nameColW + #coreKeys * COL_W
                    + PALADIN_SECTION_GAP
                    + K.PaladinColumnOffset(c, paladins, COL_W)
                    + (COL_W - CELL_SIZE) / 2, -(f.headerBottom - 3))
            header.paladin = p.name
            header.icon:SetTexture(RoleIconFor(p))
            header.initial:SetText(WhoDoesWhat:NameInitial(p.name))
            header.initial:SetTextColor(p.classInfo.colorRGB.r,
                p.classInfo.colorRGB.g, p.classInfo.colorRGB.b)
            header:Show()
        end
    end
    for i = paladinHeaderCount + 1, #f.paladinHeaders do
        f.paladinHeaders[i]:Hide()
        f.paladinHeaders[i].paladin = nil
    end

    -- The local paladin's first column stays visually attached across the
    -- header and all rows, with a small break before the other paladins.
    for b = 1, 2 do
        local stripe = f.localPaladinStripes[b]
        if b <= numBlocks and paladins[1] and K.IsLocalPaladin(paladins[1]) then
            stripe:ClearAllPoints()
            stripe:SetPoint("TOPLEFT", f, "TOPLEFT",
                BlockX(b) + nameColW + #coreKeys * COL_W
                    + PALADIN_SECTION_GAP,
                -(f.headerBottom - HEADER_H))
            stripe:SetSize(COL_W, HEADER_H + 4 + rowsPerBlock * ROW_H)
            stripe:Show()
        else
            stripe:Hide()
        end
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

    -- All three sources expose the assignment-model snapshot shape expected
    -- below, so the rendering path remains shared.
    local buffPlan = BuffPlanForSource(f.gridSource)
    if not buffPlan then
        f.gridSource = DefaultGridSource()
        buffPlan = BuffPlanForSource(f.gridSource)
    end
    if hasPaladins then
        UpdateSourceControl(f)
    else
        f.sourceWarning:Hide()
    end

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
        WhoDoesWhat:SetRoleIconTexture(row.roleIcon, RoleIconFor(m))
        row.roleIcon:SetDesaturated(not connected)
        row.nameFS:SetText("|cff" .. (connected and m.classInfo.colorHex or "909090")
            .. WhoDoesWhat:DisplayName(m.name) .. "|r")

        for c, key in ipairs(coreKeys) do
            local cell = row.coreCells[c] or CreateCoreCell(row, c)
            PositionCell(cell, row, c)
            local buff = WhoDoesWhat.StatusBarChecks[key]
            local options = coreOptions[key]
            local notNeeded = (options.onlyManaUsers
                    and WhoDoesWhat.ManaExcludedClasses[m.classInfo.name] or false)
                or (options.onlyTanks and not WhoDoesWhat:IsMarkedTank(m.name))
            local showForTarget = not m.isPet
                or (options.hunterPets and not buff.hunterPetsOptionDisabled)
            local has
            if showForTarget and not notNeeded then
                has = WhoDoesWhat:HasBuff(m.name, key)
            end
            cell.raider = m.name
            cell.buffKey = key
            cell.connected = connected
            cell.notNeeded = notNeeded
            cell.hasBuff = has
            cell.negative = options.negative
            local betterProvider
            if not options.negative and connected and has == true
                and buff.improvedTalent then
                local status, _, rank =
                    WhoDoesWhat:GetImprovedBuffState(m.name, key)
                local best = bestProviders[key]
                if (status == "base" or status == "partial") and rank
                    and best and best.rank > rank then
                    betterProvider = best
                end
            end
            cell.betterProvider = betterProvider
            cell.icon:SetTexture(buff.icon)
            cell.icon:SetShown(has == true
                and (options.negative or not betterProvider))
            cell.icon:SetDesaturated(not connected)
            cell.missing:ClearAllPoints()
            if options.negative then
                cell.missing:SetTexture(CORE_MISSING_ICON)
                cell.missing:SetSize(11, 11)
                cell.missing:SetPoint("BOTTOMRIGHT", 1, -1)
            else
                cell.missing:SetTexture(CORE_MISSING_ICON)
                cell.missing:SetSize(CORE_CELL_ICON_SIZE, CORE_CELL_ICON_SIZE)
                cell.missing:SetPoint("CENTER")
            end
            cell.missing:SetShown(not notNeeded and connected and not m.isFake
                and (options.negative and has == true
                    or not options.negative and has == false))
            cell.warning:SetShown(betterProvider ~= nil)
            cell:SetShown(showForTarget)
        end
        for c = #coreKeys + 1, #row.coreCells do row.coreCells[c]:Hide() end

        for c = 1, #paladins do
            local cell = row.paladinCells[c] or CreatePaladinCell(row, c)
            PositionPaladinCell(cell, row, #coreKeys, c, paladins)
            cell.paladin = paladins[c].name
            cell.raider = m.name
            cell.gridSource = f.gridSource
            K.SetPaladinBuffCell(cell, buffPlan, m.name, cell.paladin)
            -- Gray + red outline only when the raider is confirmed to lack
            -- the planned buff; unknown and simulated cells never flag.
            local isMissing = cell.buffKey ~= nil
                and not WhoDoesWhat.Assign.IsSimulatedPaladinBuff(cell.paladin, m.name)
                and WhoDoesWhat:HasBuff(m.name, cell.buffKey) == false
            cell.missing:SetShown(isMissing)
            cell.icon:SetDesaturated(isMissing)
            cell:SetShown(connected)
        end
        for c = #paladins + 1, #row.paladinCells do
            row.paladinCells[c]:Hide()
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

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatBuffingGridFrame",
        MIN_FRAME_W, MIN_FRAME_H, "Buffing Grid")
    f.titleText:ClearAllPoints()
    f.titleText:SetPoint("CENTER", f.titleBarTexture, "CENTER", 0, 0)

    -- Same title-bar cog as the main view, but straight to the page that
    -- configures these columns.
    local settingsBtn = CreateFrame("Button", nil, f)
    settingsBtn:SetSize(32, 32)
    settingsBtn:SetHitRectInsets(4, 4, 4, 4)
    settingsBtn:SetPoint("TOPRIGHT", -20, 1)
    settingsBtn:SetNormalTexture(OPTIONS_BUTTON .. "Up.tga")
    settingsBtn:SetPushedTexture(OPTIONS_BUTTON .. "Down.tga")
    settingsBtn:SetHighlightTexture(
        "Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
    settingsBtn:SetScript("OnClick", function()
        WhoDoesWhat:OpenAddonSettingsView("Buff Tracking")
    end)
    settingsBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Buff Tracking settings", 1, 1, 1)
        GameTooltip:AddLine("Choose which buffs get a column here, and how"
            .. " each one is tracked.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    settingsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local sourceCaption = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sourceCaption:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + 13))
    sourceCaption:SetText("Show Pally Buff Source:")
    f.sourceCaption = sourceCaption

    f.gridSource = DefaultGridSource()
    local sourceDD = CreateFrame("Frame", "WhoDoesWhatBuffGridSourceDD", f,
        "UIDropDownMenuTemplate")
    sourceDD:SetPoint("LEFT", sourceCaption, "RIGHT", -12, -2)
    UIDropDownMenu_SetWidth(sourceDD, 82)
    K.LeftAlignDropdown(sourceDD)
    UIDropDownMenu_Initialize(sourceDD, function(_, level)
        for _, option in ipairs(SOURCE_OPTIONS) do
            local key, label = option.key, option.label
            local info = UIDropDownMenu_CreateInfo()
            info.text = label
            info.checked = f.gridSource == key
            info.disabled = key == "addon" and not HasPallyPowerAddon()
            info.func = function()
                f.gridSource = key
                RefreshGrid(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.sourceDD = sourceDD

    local sourceWarning = K.CreateWarningIcon(f)
    sourceWarning:SetPoint("LEFT", sourceDD, "RIGHT", -10, 0)
    f.sourceWarning = sourceWarning
    UpdateSourceControl(f)

    -- Everything in the grid header hangs off this: the y where the paladin
    -- role icons stand and the rows begin.
    f.headerBottom = f.titleBarHeight + 8 + SOURCE_ROW_H + HEADER_H

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
    f.divider = divider

    WhoDoesWhat:LogUiBuilding("Building buffing grid content.")

    f.coreHeaders = {}
    f.paladinHeaders = {}
    f.localPaladinStripes = {
        K.CreateLocalPaladinStripe(f),
        K.CreateLocalPaladinStripe(f),
    }
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

-- Repaint the grid if the window is up, and nothing else.
--
-- This used to double as the "buff plan changed" hook and fan out to four
-- other views, which made it impossible to read a call site (or a profile) and
-- know what was actually being repainted -- and, because the old Action Items
-- refresh had grown a second fan-out to the same place, any site calling both
-- repainted WDW Status twice. Callers that mean "the plan changed" now say
-- RefreshBoardViews.
function WhoDoesWhat:RefreshBuffingGridView()
    if gridFrame and gridFrame:IsShown() then
        RefreshGrid(gridFrame)
    end
end

-- Toggle the grid window open/closed.
function WhoDoesWhat:OpenBuffingGridView()
    local f = EnsureGridFrame()

    if f:IsShown() then
        self:LogUiBuilding("Buffing Grid View open, closing it.")
        f:Hide()
        return
    end

    self:LogUiBuilding("Opening Buffing Grid View...")
    f.gridSource = DefaultGridSource()
    f:Show()
    RefreshGrid(f)
    f:Raise()
end
