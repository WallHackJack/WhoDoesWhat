local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI

-- Buffing Grid (the main window's Buff Grid tab): raid-wide buff status
-- columns followed by every paladin's blessing for each raider. The blessing
-- columns can show WDW's plan, WDW's PLPWR wire mirror, or the live tables of a
-- co-installed PallyPower addon.
-- The grid is centred in its page at its own width; the column headers stay put
-- and the raider rows scroll under them. At SPLIT_AT_ROWS raiders (or more)
-- the rows split into two balanced side-by-side blocks.
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

local MIN_FRAME_W = 330 -- floor for an empty group; width tracks columns
local MARGIN = 12
local SCROLLBAR_W = UI.SCROLLBAR_W

local NAME_COL_W = 150 -- role icon + raider name (grows to fill)
local NAME_MIN_W = 100 -- how far two blocks may squeeze it to fit the page
-- The name column absorbs whatever width the window has beyond its columns,
-- so a narrow grid still spans the window's minimum width. RefreshGrid sets it.
local nameColW = NAME_COL_W
-- One buff column: a little tighter than the kit's paladin columns, so two
-- blocks fit the page side by side.
local COL_W = K.PALADIN_GRID_COL_W - 4
local ROW_H = 22
-- Past this many rows (a 40-man and its pets) the rows tighten up a little.
local COMPACT_AT_ROWS = 30
local COMPACT_ROW_H = 20
local ROLE_ICON_SIZE = 18
local CELL_SIZE = K.PALADIN_GRID_CELL_SIZE
local HEADER_H = 28
local GEAR_SIZE = 16
local SOURCE_BADGE_SIZE = 11
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
-- side-by-side blocks (balanced halves).
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
    UI.AddTooltip(header, function(self)
        local buff = WhoDoesWhat.StatusBarChecks[self.buffKey]
        GameTooltip:SetText(buff.gridName or buff.name, unpack(UI.TOOLTIP_TITLE))
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
        return true
    end)
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

    UI.AddTooltip(cell, function(self)
        local buff = WhoDoesWhat.StatusBarChecks[self.buffKey]
        -- A flask's guardian cell is blank, and so is its tooltip; the battle
        -- cell speaks for it.
        if self.flaskCovered and self.connected then return false end
        -- An elixir on the raider gets the spell's own tooltip.
        if self.elixirSpell and self.connected and GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(self.elixirSpell)
            local remaining = WhoDoesWhat:GetBuffTimeRemaining(
                self.raider, self.buffKey)
            GameTooltip:AddLine("On " .. WhoDoesWhat:DisplayName(self.raider)
                .. (remaining and (", " .. RemainingText(remaining)
                    .. " remaining.") or "."), 1, 0.82, 0)
            return true
        end
        GameTooltip:SetText(buff.name .. " - "
            .. WhoDoesWhat:DisplayName(self.raider), unpack(UI.TOOLTIP_TITLE))
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
        return true
    end)

    row.coreCells[column] = cell
    return cell
end

-- One grid cell (a button already, for the later click-to-customize).
-- Refresh fills cell.paladin / cell.raider / cell.buffKey before showing it.
local function CreatePaladinCell(row, c)
    local cell = K.CreatePaladinBuffCell(row, CELL_SIZE)
    PositionCell(cell, row, c)
    cell.missing = cell.alert

    UI.AddTooltip(cell, function(self)
        local raider = WhoDoesWhat:DisplayName(self.raider)
        if self.buffKey then
            GameTooltip:SetText(self.paladin, unpack(UI.TOOLTIP_TITLE))
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
                    .. " they want at this paladin count is already covered"
                    .. (WhoDoesWhat.ClientFeatures.buffTalents
                        and (", or needs a talent " .. self.paladin .. " doesn't have.")
                        or "."),
                    0.6, 0.6, 0.6, true)
            else
                local source = self.gridSource == "addon"
                    and "the local PallyPower addon" or "observed PallyPower traffic"
                GameTooltip:AddLine("No assignment for " .. raider .. " in "
                    .. source .. ".", 0.6, 0.6, 0.6, true)
            end
        end
        return true
    end)

    row.paladinCells[c] = cell
    return cell
end

-- One pooled raider row: class-tinted alternating background (set by the
-- refresh, since a row's position moves as the group changes), role icon,
-- class-colored name; the buff cells hang off it per column. Rows live in the
-- scroll child; RefreshGrid anchors each one every pass.
local function CreateRow(f, index)
    local row = CreateFrame("Frame", nil, f.rowContent)
    row:SetFrameLevel(f.rowContent:GetFrameLevel() + 1)
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
    nameFS:SetWordWrap(false)
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

-- A source other than the raid's own is a comparison, not the plan: the gear
-- carries a warning badge, and its tooltip says what is on screen instead.
local function UpdateSourceControl(f)
    local expected = DefaultGridSource()
    local pallyPowerMode = WhoDoesWhat.db.profile.settings.pallyBuffSource == "pallypower"
    local matchesMode = f.gridSource == expected
        or (pallyPowerMode and (f.gridSource == "addon" or f.gridSource == "observed"))
    if not matchesMode then
        f.sourceWarningText = "Paladin blessing cells are showing "
            .. (SOURCE_LABELS[f.gridSource] or "this source")
            .. " for comparison only. They do not represent the raid's active"
            .. " assignment source. Select " .. SOURCE_LABELS[expected]
            .. " to view the plan currently driving WDW. Missing-buff indicators"
            .. " still use live aura data."
    else
        f.sourceWarningText = nil
    end
    f.sourceBadge:SetShown(not matchesMode)
end

local function BuffPlanForSource(source)
    if source == "observed" then
        return WhoDoesWhat:GetPallyPowerBuffPlan("observed")
    elseif source == "addon" then
        return WhoDoesWhat:GetPallyPowerBuffPlan("addon")
    end
    return WhoDoesWhat.Assign.GetPaladinBuffPlan()
end

-- Map the current group onto the pooled widgets and size the grid to its
-- content: width tracks the column count, and the rows scroll.
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
    -- gear to control.
    local hasPaladins = #paladins > 0
    f.sourceGear:SetShown(hasPaladins)

    local numBlocks = (#members >= SPLIT_AT_ROWS) and 2 or 1
    local rowsPerBlock = math.ceil(#members / numBlocks)
    local rowH = #members > COMPACT_AT_ROWS and COMPACT_ROW_H or ROW_H
    local paladinGap = hasPaladins and PALADIN_SECTION_GAP or 0
    local columnsW = #coreKeys * COL_W + paladinGap
        + K.PaladinColumnsWidth(paladins, COL_W, 0)
    local gaps = GRID_X + (numBlocks - 1) * BLOCK_GAP + MARGIN
    local frameW = math.max(MIN_FRAME_W,
        gaps + numBlocks * (NAME_COL_W + columnsW))
    -- Two blocks that overflow the page squeeze their name columns first.
    local pageW = f:GetParent():GetWidth()
    if pageW > 0 then
        frameW = math.max(math.min(frameW, pageW - SCROLLBAR_W),
            gaps + numBlocks * (NAME_MIN_W + columnsW))
    end
    -- Spend the leftover width on the name column so the blocks always reach
    -- the right edge, even at the minimum width.
    nameColW = (frameW - gaps) / numBlocks - columnsW
    local blockW = nameColW + columnsW
    local function BlockX(b)
        return GRID_X + (b - 1) * (blockW + BLOCK_GAP)
    end

    -- The grid plus its scrollbar gutter, centred in the page, but never wider
    -- than the page: past that the name column is what gets cut.
    local width = frameW + SCROLLBAR_W
    f:SetWidth(pageW > 0 and math.min(width, pageW) or width)
    f.rowContent:SetWidth(frameW)
    f.scroll:ClearAllPoints()
    f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(f.headerBottom + 4))
    f.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -SCROLLBAR_W, 0)

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
    -- header and all rows, with a small break before the other paladins. Two
    -- pieces, since the header stays put while the rows scroll: one over the
    -- header, one down the scroll child, for each block.
    local localFirst = paladins[1] and K.IsLocalPaladin(paladins[1])
    for b = 1, 2 do
        local headerStripe = f.localPaladinStripes.header[b]
        local rowsStripe = f.localPaladinStripes.rows[b]
        local shown = b <= numBlocks and localFirst and true or false
        headerStripe:SetShown(shown)
        rowsStripe:SetShown(shown and #members > 0)
        if shown then
            local stripeX = BlockX(b) + nameColW + #coreKeys * COL_W
                + PALADIN_SECTION_GAP
            headerStripe:ClearAllPoints()
            headerStripe:SetPoint("TOPLEFT", f, "TOPLEFT", stripeX,
                -(f.headerBottom - HEADER_H))
            headerStripe:SetSize(COL_W, HEADER_H + 4)
            rowsStripe:ClearAllPoints()
            rowsStripe:SetPoint("TOPLEFT", f.rowContent, "TOPLEFT", stripeX, 0)
            rowsStripe:SetSize(COL_W, math.max(rowsPerBlock * rowH, 1))
        end
    end

    -- One "Raider" label per visible block.
    for b = 1, 2 do
        local label = f.raiderLabels[b]
        label:SetShown(b <= numBlocks)
        label:ClearAllPoints()
        label:SetPoint("BOTTOMLEFT", f, "TOPLEFT", BlockX(b) + 4, -(f.headerBottom - 6))
    end

    -- All three sources expose the assignment-model snapshot shape expected
    -- below, so the rendering path remains shared.
    local buffPlan = BuffPlanForSource(f.gridSource)
    if not buffPlan then
        f.gridSource = DefaultGridSource()
        buffPlan = BuffPlanForSource(f.gridSource)
    end
    UpdateSourceControl(f)

    for i, m in ipairs(members) do
        local row = f.rows[i] or CreateRow(f, i)
        -- Anchor into this row's block slot; the stripe follows the
        -- block-local position so both blocks stripe from their own top.
        local b = math.ceil(i / rowsPerBlock)
        local localRow = i - (b - 1) * rowsPerBlock
        row:SetSize(blockW, rowH)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.rowContent, "TOPLEFT",
            BlockX(b), -((localRow - 1) * rowH))
        row.nameFS:SetWidth(nameColW - (4 + ROLE_ICON_SIZE + 6) - 2)
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
                or options.hunterPets
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
            -- An elixir cell wears the elixir actually on the raider. A flask
            -- is drawn once, in the battle column; its guardian cell stays
            -- empty rather than repeating it.
            local elixirSpell, isFlask
            if buff.elixirCategory and has == true then
                elixirSpell, isFlask = WhoDoesWhat:GetElixirSpell(m.name, key)
            end
            cell.elixirSpell = elixirSpell
            cell.flaskCovered = isFlask and buff.elixirCategory == "guardian"
            cell.icon:SetTexture(elixirSpell and GetSpellTexture(elixirSpell)
                or buff.icon)
            cell.icon:SetShown(has == true and not cell.flaskCovered
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
                and not cell.flaskCovered
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

    UI.SetScrollHeight(f.scroll, rowsPerBlock * rowH)
    -- Ask the main window for room to show every row without scrolling; it
    -- stops at the screen's bottom edge, and the rows scroll past that.
    WhoDoesWhat:SetMainPageHeight("grid", f.headerBottom + 4 + rowsPerBlock * rowH)
end

-- Created on first open, not at load: see PaladinBuffsSection's note on
-- DropDownList frames.
local sourceMenu

local function OpenSourceMenu(f, button)
    if not sourceMenu then
        sourceMenu = CreateFrame("Frame", "WhoDoesWhatBuffGridSourceMenu",
            UIParent, "UIDropDownMenuTemplate")
    end
    UIDropDownMenu_Initialize(sourceMenu, function(_, level)
        local title = UIDropDownMenu_CreateInfo()
        title.text = "Show Pally Buff Source"
        title.isTitle = true
        title.notCheckable = true
        UIDropDownMenu_AddButton(title, level)
        for _, option in ipairs(SOURCE_OPTIONS) do
            local key = option.key
            local info = UIDropDownMenu_CreateInfo()
            info.text = option.label
            info.checked = f.gridSource == key
            info.disabled = key == "addon" and not HasPallyPowerAddon()
            info.func = function()
                f.gridSource = key
                RefreshGrid(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end, "MENU")
    ToggleDropDownMenu(1, nil, sourceMenu, button, 0, 0)
end

-- Build the page into the Buff Grid tab. The header parents straight onto the
-- grid frame; the rows go in a scroll child under it. RefreshGrid sizes both.
function WhoDoesWhat:BuildBuffingGridPage(page)
    local f = CreateFrame("Frame", nil, page)
    f:SetPoint("TOP", page, "TOP")
    f:SetPoint("BOTTOM", page, "BOTTOM")
    f:SetWidth(MIN_FRAME_W)
    f.gridSource = DefaultGridSource()

    -- Everything in the grid header hangs off this: the y where the column
    -- icons stand and the rows begin. The header starts at the page's top.
    f.headerBottom = HEADER_H

    -- The blessing-source picker: a gear in the top-right corner, in the
    -- scrollbar's gutter above the rows, so it takes nothing from the grid.
    local gear = UI.CreateBareIconButton(f, UI.GEAR_ICON, GEAR_SIZE,
        function()
            GameTooltip:SetText("Pally Buff Source", unpack(UI.TOOLTIP_TITLE))
            GameTooltip:AddLine("Paladin blessing cells show "
                .. (SOURCE_LABELS[f.gridSource] or "WDW") .. ".",
                0.8, 0.8, 0.8, true)
            if f.sourceWarningText then
                GameTooltip:AddLine(f.sourceWarningText, 1, 0.45, 0.2, true)
            end
            return true
        end, nil,
        function(self) OpenSourceMenu(f, self) end)
    gear:SetPoint("CENTER", f, "TOPRIGHT", -(SCROLLBAR_W / 2),
        -(HEADER_H - 3 - CELL_SIZE / 2))
    f.sourceGear = gear

    local badge = gear:CreateTexture(nil, "OVERLAY")
    badge:SetTexture(UI.WARNING_ICON)
    badge:SetSize(SOURCE_BADGE_SIZE, SOURCE_BADGE_SIZE)
    badge:SetPoint("CENTER", gear, "BOTTOMLEFT", 1, 1)
    f.sourceBadge = badge
    UpdateSourceControl(f)

    f.raiderLabels = {}
    for b = 1, 2 do
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetText("Raider")
        f.raiderLabels[b] = label
    end

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(WhoDoesWhat.Theme.goldDivider))
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", GRID_X, -f.headerBottom)
    divider:SetPoint("TOPRIGHT", -(MARGIN + SCROLLBAR_W), -f.headerBottom)
    f.divider = divider

    local scroll, rowContent = UI.CreateScroll(f, "WhoDoesWhatBuffGridScroll", true)
    f.scroll, f.rowContent = scroll, rowContent

    WhoDoesWhat:LogUiBuilding("Building buffing grid content.")

    f.coreHeaders = {}
    f.paladinHeaders = {}
    f.localPaladinStripes = {
        header = { K.CreateLocalPaladinStripe(f), K.CreateLocalPaladinStripe(f) },
        rows = { K.CreateLocalPaladinStripe(rowContent),
            K.CreateLocalPaladinStripe(rowContent) },
    }
    f.rows = {}

    -- The source picker is a look at something else for comparison, so it goes
    -- back to the raid's real source each time the window is opened - not each
    -- time the tab is switched to.
    local window = page:GetParent():GetParent()
    window:HookScript("OnHide", function() f.gridSource = nil end)
    f:SetScript("OnShow", function(self)
        self.gridSource = self.gridSource or DefaultGridSource()
        RefreshGrid(self)
    end)

    -- Track joins/leaves live while the page is on screen.
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:RegisterEvent("UNIT_CONNECTION")
    f:SetScript("OnEvent", function(self)
        if self:IsVisible() then
            RefreshGrid(self)
        end
    end)

    gridFrame = f
    return f
end

-- Repaint the grid if it is on screen, and nothing else.
--
-- This used to double as the "buff plan changed" hook and fan out to four
-- other views, which made it impossible to read a call site (or a profile) and
-- know what was actually being repainted -- and, because the old Action Items
-- refresh had grown a second fan-out to the same place, any site calling both
-- repainted WDW Status twice. Callers that mean "the plan changed" now say
-- RefreshBoardViews.
function WhoDoesWhat:RefreshBuffingGridView()
    if gridFrame and gridFrame:IsVisible() then
        RefreshGrid(gridFrame)
    end
end

-- Open the main window on the Buff Grid tab, or close it if it is already there.
function WhoDoesWhat:OpenBuffingGridView()
    self:ShowMainTab("grid")
end
