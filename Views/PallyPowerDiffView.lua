local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Side-by-side paladin-buff grids for the players whose current PallyPower
-- coverage differs from WhoDoesWhat's suggested plan. Above each grid's
-- columns sits a per-paladin overview strip -- the blessings that paladin
-- mostly carries in that plan, count-descending -- the same shape as the
-- Paladin Buffs rows in the main window.

local K = WhoDoesWhat.SectionKit
local A = WhoDoesWhat.Assign
local diffFrame = nil
local RenderDiffs

local FRAME_MAX_H = 470
local FRAME_MIN_H = 150
local COMPACT_W = 390
local COMPACT_H = 54
local MARGIN = 10
local BOTTOM_STRIP = 30
local WARNING_H = 34
local SCROLLBAR_W = 26
local SCROLLBAR_GAP = 8
local GRID_GAP = 6
local PLAYER_COL_W = 116
local ROLE_COL_W = 112
local ROLE_GRID_GAP = 16
local LEFT_PREFIX_W = PLAYER_COL_W + ROLE_COL_W + ROLE_GRID_GAP
local FIX_GAP = 6
local FIX_W = 38
local TITLE_H = 22
local HEADER_H = 26
local ROW_H = 24
local ROLE_ICON_SIZE = 18
local SUMMARY_ROW_H = 20
local SUMMARY_GAP = 10
local SUMMARY_MAX_BUFFS = 3
local SUMMARY_ICON = 16
local SUMMARY_SLOT_W = 20
local CELL_SIZE = K.PALADIN_GRID_CELL_SIZE
local COL_W = K.PALADIN_GRID_COL_W

StaticPopupDialogs["WHODOESWHAT_FIX_ALL_PALLYPOWER"] = {
    text = "This will overwrite %d PallyPower buff choices and may upset the raid. Continue?",
    button1 = "Fix All",
    button2 = "Cancel",
    OnAccept = function(self) self.data() end,
    timeout = 0,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function ShortName(name)
    return name and name:match("^([^%-]+)") or name
end

local function ClassInfo(className)
    for _, classInfo in ipairs(WhoDoesWhat.Classes) do
        if classInfo.name == className then return classInfo end
    end
end

local function RoleIconFor(member)
    if member.roleIcon then return member.roleIcon end
    if member.isPet then return WhoDoesWhat.HunterPetRole.icon end
    local roleId = WhoDoesWhat:GetAssignedRole(member.name)
    local role = roleId and WhoDoesWhat.RolesAndCategories[roleId]
    return (role and role.icon) or (member.classInfo and member.classInfo.classIcon)
end

local function RoleText(role, classInfo)
    return "|T" .. role.icon .. ":14:14:0:0|t |cff"
        .. classInfo.colorHex .. role.name .. "|r"
end

local function AssignedRole(data, member)
    local roleId = data.isDemo and member.testRoleId
        or WhoDoesWhat:GetAssignedRole(member.name)
    local role
    if roleId then _, role = WhoDoesWhat:FindRoleById(roleId) end
    return role, roleId
end

local function GroupPaladins()
    local paladins = {}
    for _, member in ipairs(WhoDoesWhat:GetGroupMembers("Paladin")) do
        if member.classInfo.name == "Paladin" then
            paladins[#paladins + 1] = member
        end
    end
    return K.OrderPaladinsLocalFirst(paladins)
end

local function ComparisonMembers(diffs)
    local wanted, firstDiff, seen = {}, {}, {}
    for _, diff in ipairs(diffs) do
        local planTarget = diff.planTarget or ShortName(diff.target)
        wanted[planTarget] = true
        firstDiff[planTarget] = firstDiff[planTarget] or diff
    end

    local members = {}
    local function Add(member)
        local key = wanted[member.name] and member.name or ShortName(member.name)
        if wanted[key] and not seen[key] then
            local display = {}
            for field, value in pairs(member) do display[field] = value end
            display.planName = member.name
            display.displayName = ShortName(member.name)
            members[#members + 1] = display
            seen[key] = true
        end
    end
    for _, member in ipairs(WhoDoesWhat:GetGroupMembers(nil)) do
        if not WhoDoesWhat:IsNonRaider(member.name) then Add(member) end
    end
    for _, pet in ipairs(A.GetPetMembers()) do Add(pet) end

    -- Keep a useful row if a target left the group between the diff and paint.
    for planTarget in pairs(wanted) do
        if not seen[planTarget] then
            local diff = firstDiff[planTarget]
            members[#members + 1] = {
                name = planTarget,
                planName = planTarget,
                displayName = ShortName(diff.target),
                roleIcon = diff.targetIcon,
                roleName = diff.targetRole,
            }
        end
    end
    table.sort(members, function(a, b)
        return a.displayName:lower() < b.displayName:lower()
    end)
    return members
end

local function CurrentPallyPowerPlan()
    return WhoDoesWhat:GetPallyPowerBuffPlan("addon")
        or WhoDoesWhat:GetPallyPowerBuffPlan("observed")
end

local function LiveComparisonData()
    local diffs, reason = WhoDoesWhat:CheckPallyPowerSync()
    if not diffs or #diffs == 0 then return nil, reason or "synced" end
    return {
        paladins = GroupPaladins(),
        members = ComparisonMembers(diffs),
        current = CurrentPallyPowerPlan(),
        suggested = A.GetPaladinBuffPlan(),
        diffCount = #diffs,
        diffs = diffs,
    }
end

local function CreatePaladinHeader(content, side, index)
    local header = K.CreatePaladinGridHeader(content)
    header:SetScript("OnEnter", function(self)
        if self.paladinMember and not self.paladinMember.isTestFallback then
            WhoDoesWhat:ShowRaiderTooltip(self, self.paladin)
        else
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.paladin, 1, 1, 1)
            GameTooltip:AddLine("Simulated Paladin", 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end
    end)
    header:SetScript("OnLeave", function() WhoDoesWhat:HideRaiderTooltip() end)
    content.headers[side][index] = header
    return header
end

local function CreateComparisonRow(content, side, index)
    local row = CreateFrame("Frame", nil, content)
    row:SetHeight(ROW_H)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    row.bg = bg
    row.cells = {}

    if side == 1 then
        local roleIcon = row:CreateTexture(nil, "ARTWORK")
        roleIcon:SetSize(ROLE_ICON_SIZE, ROLE_ICON_SIZE)
        roleIcon:SetPoint("LEFT", 4, 0)
        row.roleIcon = roleIcon

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", roleIcon, "RIGHT", 6, 0)
        name:SetWidth(PLAYER_COL_W - ROLE_ICON_SIZE - 12)
        name:SetJustifyH("LEFT")
        row.name = name

        local dropdown = CreateFrame("Frame",
            "WhoDoesWhatPpDiffRoleDD" .. index, row, "UIDropDownMenuTemplate")
        dropdown:SetPoint("LEFT", row, "LEFT", PLAYER_COL_W - 16, -2)
        UIDropDownMenu_SetWidth(dropdown, ROLE_COL_W - 14)
        K.LeftAlignDropdown(dropdown)
        UIDropDownMenu_Initialize(dropdown, function(_, level)
            local member, data, frame = row.member, row.data, row.ownerFrame
            if not member or not member.classInfo then return end
            local _, saved = AssignedRole(data, member)
            local function AddRole(role, classInfo)
                local info = UIDropDownMenu_CreateInfo()
                info.text = RoleText(role, classInfo)
                info.checked = saved == role.id
                info.func = function()
                    if data.isDemo then
                        member.testRoleId = role.id
                        RenderDiffs(frame)
                    else
                        WhoDoesWhat:SetAssignedRole(member.name, role.id)
                    end
                end
                UIDropDownMenu_AddButton(info, level)
            end
            for _, role in ipairs(member.classInfo.roles) do
                AddRole(role, member.classInfo)
            end
            for _, role in ipairs(member.classInfo.customRoles or {}) do
                AddRole(role, member.classInfo)
            end
            if UIDropDownMenu_AddSeparator then UIDropDownMenu_AddSeparator(level) end
            AddRole(WhoDoesWhat.NonRaiderRole, WhoDoesWhat.NonRaiderClass)
        end)
        row.dropdown = dropdown
    end
    content.rows[side][index] = row
    return row
end

local function CreatePlanCell(row, index)
    local cell = K.CreatePaladinBuffCell(row, CELL_SIZE)
    local empty = cell:CreateTexture(nil, "ARTWORK")
    empty:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
    empty:SetSize(CELL_SIZE * 0.8, CELL_SIZE * 0.8)
    empty:SetPoint("CENTER")
    empty:Hide()
    cell.empty = empty
    cell:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.paladin, 1, 1, 1)
        if self.buffKey then
            GameTooltip:AddLine(self.sourceLabel .. ": "
                .. (self.isGreater and "Greater Blessing of " or "Blessing of ")
                .. WhoDoesWhat.PaladinBuffs[self.buffKey].name_long .. ".",
                0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine(self.sourceLabel .. ": no assignment for "
                .. self.raider .. ".", 0.6, 0.6, 0.6, true)
        end
        if self.alertMessage then
            local color = self.alertKind == "red" and { 1, 0.3, 0.3 }
                or { 1, 0.82, 0 }
            GameTooltip:AddLine(self.alertMessage, color[1], color[2], color[3], true)
        end
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.cells[index] = cell
    return cell
end

local function CreateFixButton(content, index)
    local button = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    button:SetSize(FIX_W, 20)
    button:SetText("Fix")
    button:SetMotionScriptsWhileDisabled(true)
    button:SetScript("OnClick", function(self)
        if not self.member or self.isDemo then return end
        if WhoDoesWhat:FixPlayerBuffsInPallyPower(self.member.planName) then
            WhoDoesWhat:RefreshMainAssignmentsView()
        end
        RenderDiffs(self.ownerFrame)
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Fix " .. (self.member and self.member.displayName or "row"),
            1, 1, 1)
        if self.isDemo then
            GameTooltip:AddLine("Disabled for view-only demo data.", 0.8, 0.8, 0.8, true)
        elseif self.blockedPaladin then
            GameTooltip:AddLine(self.blockedPaladin
                .. " has Free Assignment turned off.", 1, 0.2, 0.2, true)
            GameTooltip:AddLine("This row cannot be fixed by a non-assistant.",
                0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine("Send only this player's WDW blessing plan to PallyPower.",
                0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    content.fixButtons[index] = button
    return button
end

local function TopBuffSet(data, member)
    local order
    if data.isDemo and member.testRoleId then
        order = WhoDoesWhat:GetEffectiveBuffOrder(member.testRoleId)
    else
        order = A.GetPaladinBuffPriorityOrder(member.planName)
    end
    order = order or WhoDoesWhat.CanonicalBuffOrder
    local top = {}
    for i = 1, math.min(#data.paladins, #order) do top[order[i]] = true end
    return top
end

local function TalentRank(data, paladinName, buffKey)
    local ranks = data.talentRanks and data.talentRanks[paladinName]
        or WhoDoesWhat:GetPaladinBuffTalents(paladinName)
    return ranks and ranks[buffKey]
end

local function CellOutline(data, member, paladin, buffKey)
    if not buffKey then return nil end
    if not member.topBuffs[buffKey] then
        return "red", "This blessing is outside the player's top "
            .. #data.paladins .. " buffs."
    end

    local talent = A.BuffTalents[buffKey]
    if not talent or talent.maxRank <= 1 then return nil end
    local suggested = data.suggested.grid[member.planName] or {}
    for _, betterPaladin in ipairs(data.paladins) do
        if suggested[betterPaladin.name] == buffKey
            and betterPaladin.name ~= paladin.name then
            local currentRank = TalentRank(data, paladin.name, buffKey)
            local betterRank = TalentRank(data, betterPaladin.name, buffKey)
            if currentRank ~= nil and betterRank ~= nil and betterRank > currentRank then
                return "yellow", "WDW assigns this to " .. betterPaladin.name
                    .. " at " .. betterRank .. "/" .. talent.maxRank
                    .. " instead of " .. currentRank .. "/" .. talent.maxRank .. "."
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Per-paladin overview strip (mirrors the Paladin Buffs rows in the main
-- window): which blessings each paladin mostly carries, count-descending,
-- for both plans. Computed straight off the plan grids so it also works for
-- the demo data's simulated paladins.
-- ---------------------------------------------------------------------------

local function BuffSpread(plan, paladinName)
    local counts = {}
    for _, cells in pairs(plan and plan.grid or {}) do
        local key = cells[paladinName]
        if key then counts[key] = (counts[key] or 0) + 1 end
    end
    local canonIndex = {}
    for i, key in ipairs(WhoDoesWhat.CanonicalBuffOrder) do canonIndex[key] = i end
    local spread = {}
    for key, count in pairs(counts) do
        spread[#spread + 1] = { key = key, count = count }
    end
    table.sort(spread, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return canonIndex[a.key] < canonIndex[b.key]
    end)
    return spread
end

local function SummarySlotEnter(self)
    if not self.buffKey then return end
    local buff = WhoDoesWhat.PaladinBuffs[self.buffKey]
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(buff.name_long, 1, 1, 1)
    GameTooltip:AddLine(self.sourceLabel .. ": " .. self.paladin .. " blesses "
        .. self.buffCount .. (self.buffCount == 1 and " raider" or " raiders")
        .. ".", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end

local function CreateSummaryRow(f, index)
    local row = CreateFrame("Frame", nil, f.header)
    row:SetHeight(SUMMARY_ROW_H)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.72, 0.72, 0.72, index % 2 == 1 and 0.07 or 0.03)

    local roleIcon = row:CreateTexture(nil, "ARTWORK")
    roleIcon:SetSize(SUMMARY_ICON, SUMMARY_ICON)
    roleIcon:SetPoint("LEFT", 4, 0)
    row.roleIcon = roleIcon

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", roleIcon, "RIGHT", 6, 0)
    name:SetWidth(LEFT_PREFIX_W - SUMMARY_ICON - 14)
    name:SetJustifyH("LEFT")
    row.name = name

    row.sides = {}
    for side = 1, 2 do
        local slots = {}
        for i = 1, SUMMARY_MAX_BUFFS do
            local slot = CreateFrame("Frame", nil, row)
            slot:SetSize(SUMMARY_SLOT_W, SUMMARY_ROW_H)
            local icon = slot:CreateTexture(nil, "OVERLAY")
            icon:SetSize(SUMMARY_ICON, SUMMARY_ICON)
            icon:SetPoint("LEFT")
            slot.icon = icon
            slot:EnableMouse(true)
            slot:SetScript("OnEnter", SummarySlotEnter)
            slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
            slot:Hide()
            slots[i] = slot
        end
        local more = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        more:SetText("...")
        more:Hide()
        local none = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        none:SetText("none")
        none:Hide()
        row.sides[side] = { slots = slots, more = more, none = none }
    end

    f.summaryRows[index] = row
    return row
end

local function RenderSummary(f, data, gridX, columnStart, plans, sourceLabels)
    for index, paladin in ipairs(data.paladins) do
        local row = f.summaryRows[index] or CreateSummaryRow(f, index)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.header, "TOPLEFT", 0, -(TITLE_H + (index - 1) * SUMMARY_ROW_H))
        row:SetWidth(f.header:GetWidth())

        local icon = RoleIconFor(paladin)
        row.roleIcon:SetTexture(icon)
        row.roleIcon:SetShown(icon ~= nil)
        local colorHex = paladin.classInfo and paladin.classInfo.colorHex or "f58cba"
        row.name:SetText("|cff" .. colorHex .. paladin.name .. "|r")

        for side = 1, 2 do
            local x = gridX[side] + columnStart[side]
            local spread = BuffSpread(plans[side], paladin.name)
            local shown = 0
            for i, slot in ipairs(row.sides[side].slots) do
                local entry = spread[i]
                if entry then
                    slot:ClearAllPoints()
                    slot:SetPoint("LEFT", row, "LEFT", x + (i - 1) * SUMMARY_SLOT_W, 0)
                    slot.icon:SetTexture(WhoDoesWhat.PaladinBuffs[entry.key].iconId)
                    slot.buffKey = entry.key
                    slot.buffCount = entry.count
                    slot.paladin = paladin.name
                    slot.sourceLabel = sourceLabels[side]
                    slot:Show()
                    shown = i
                else
                    slot.buffKey = nil
                    slot:Hide()
                end
            end
            local more = row.sides[side].more
            more:ClearAllPoints()
            more:SetPoint("LEFT", row, "LEFT", x + shown * SUMMARY_SLOT_W + 1, 0)
            more:SetShown(#spread > SUMMARY_MAX_BUFFS)
            local none = row.sides[side].none
            none:ClearAllPoints()
            none:SetPoint("LEFT", row, "LEFT", x, 0)
            none:SetShown(#spread == 0)
        end
        row:Show()
    end
    for index = #data.paladins + 1, #f.summaryRows do
        f.summaryRows[index]:Hide()
    end
end

local function SetCompact(f)
    f:SetSize(COMPACT_W, COMPACT_H)
    f.warning:Hide()
    f.header:Hide()
    f.scroll:Hide()
    f.sendBtn:Hide()
    f.secondaryBtn:Hide()
end

local function SetExpanded(f, width, summaryHeight, bodyHeight, showWarning)
    local headerTop = f.titleBarHeight + 10
    if showWarning then
        f.warning:ClearAllPoints()
        f.warning:SetPoint("TOPLEFT", MARGIN, -headerTop)
        f.warning:SetPoint("TOPRIGHT", -MARGIN, -headerTop)
        f.warning:Show()
        headerTop = headerTop + WARNING_H
    else
        f.warning:Hide()
    end
    f.header:ClearAllPoints()
    f.header:SetPoint("TOPLEFT", MARGIN, -headerTop)
    f.scroll:ClearAllPoints()
    f.scroll:SetPoint("TOPLEFT", f.header, "BOTTOMLEFT")
    f.scroll:SetPoint("BOTTOMRIGHT", -(MARGIN + SCROLLBAR_W),
        MARGIN + BOTTOM_STRIP)
    local height = headerTop + TITLE_H + summaryHeight + HEADER_H + bodyHeight
        + MARGIN + BOTTOM_STRIP
    f:SetSize(width, math.min(FRAME_MAX_H, math.max(FRAME_MIN_H, height)))
    f.header:Show()
    f.scroll:Show()
    f.sendBtn:Show()
    f.secondaryBtn:Show()
end

local function RenderGrid(f, data)
    local paladins = data.paladins
    local paladinW = K.PaladinColumnsWidth(paladins, COL_W, 3)
    local leftW = LEFT_PREFIX_W + paladinW
    local rightW = paladinW
    local rightX = leftW + GRID_GAP
    local fixX = rightX + rightW + FIX_GAP
    local contentW = fixX + FIX_W
    local frameW = contentW + MARGIN * 2 + SCROLLBAR_GAP + SCROLLBAR_W
    local bodyHeight = #data.members * ROW_H
    -- The overview strip keeps a gap between itself and the column headers so
    -- it reads as its own block rather than the grid's first rows.
    local summaryHeight = #paladins * SUMMARY_ROW_H + SUMMARY_GAP
    -- The "your fixes may upset the raid" note is only true in the one case it
    -- describes: PallyPower is the controller of record for this raid and you
    -- hold no board rights, so pushing over it is stepping on someone else's
    -- plan. With WDW as the source, or with edit rights, the fixes ARE the
    -- plan and the warning was just noise.
    SetExpanded(f, frameW, summaryHeight, bodyHeight,
        not data.isDemo
        and (WhoDoesWhat.db.profile.settings.pallyBuffSource or "wdw") == "pallypower"
        and not WhoDoesWhat:CanEditAssignments())
    f.header:SetSize(contentW, TITLE_H + summaryHeight + HEADER_H)
    f.content:SetWidth(contentW)

    local gridX = { 0, rightX }
    local gridW = { leftW, rightW }
    local columnStart = { LEFT_PREFIX_W, 0 }
    local plans = { data.current, data.suggested }
    local sourceLabels = { "Current", "Suggested" }
    local headerIconsTop = TITLE_H + summaryHeight

    RenderSummary(f, data, gridX, columnStart, plans, sourceLabels)

    for _, member in ipairs(data.members) do
        member.topBuffs = TopBuffSet(data, member)
    end

    for side = 1, 2 do
        local x = gridX[side]
        local title = f.gridTitles[side]
        title:ClearAllPoints()
        title:SetPoint("TOPLEFT", f.header, "TOPLEFT", x + columnStart[side], 0)
        title:SetWidth(paladinW)
        title:SetJustifyH("CENTER")
        title:SetText(sourceLabels[side])
        title:Show()

        for column, paladin in ipairs(paladins) do
            local header = f.header.headers[side][column]
                or CreatePaladinHeader(f.header, side, column)
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", f.header, "TOPLEFT",
                x + columnStart[side]
                    + K.PaladinColumnOffset(column, paladins, COL_W)
                    + (COL_W - CELL_SIZE) / 2,
                -(headerIconsTop + (HEADER_H - CELL_SIZE) / 2))
            header.paladin = paladin.name
            header.paladinMember = paladin
            header.icon:SetTexture(RoleIconFor(paladin))
            header.initial:SetText(paladin.name:sub(1, 1))
            local color = paladin.classInfo and paladin.classInfo.colorRGB
            header.initial:SetTextColor(color and color.r or 0.96,
                color and color.g or 0.55, color and color.b or 0.73)
            header:Show()
        end
        for column = #paladins + 1, #f.header.headers[side] do
            f.header.headers[side][column]:Hide()
        end

        local headerStripe = f.headerPaladinStripes[side]
        local bodyStripe = f.bodyPaladinStripes[side]
        if paladins[1] and K.IsLocalPaladin(paladins[1]) then
            headerStripe:ClearAllPoints()
            headerStripe:SetPoint("TOPLEFT", f.header, "TOPLEFT",
                x + columnStart[side], -TITLE_H)
            headerStripe:SetSize(COL_W, summaryHeight + HEADER_H)
            headerStripe:Show()
            bodyStripe:ClearAllPoints()
            bodyStripe:SetPoint("TOPLEFT", f.content, "TOPLEFT",
                x + columnStart[side], 0)
            bodyStripe:SetSize(COL_W, bodyHeight)
            bodyStripe:Show()
        else
            headerStripe:Hide()
            bodyStripe:Hide()
        end

        for index, member in ipairs(data.members) do
            local row = f.content.rows[side][index]
                or CreateComparisonRow(f.content, side, index)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", f.content, "TOPLEFT", x,
                -((index - 1) * ROW_H))
            row:SetWidth(gridW[side])
            row.member = member
            row.data = data
            row.ownerFrame = f
            local colors = member.classInfo and member.classInfo.gridRowColors
            local rowColor = colors and colors[index % 2 == 1 and 1 or 2]
            row.bg:SetColorTexture(rowColor and rowColor.r or 0.22,
                rowColor and rowColor.g or 0.22,
                rowColor and rowColor.b or 0.22,
                rowColor and math.max(rowColor.a or 0, 0.12) or 0.12)
            if side == 1 then
                local role, roleId = AssignedRole(data, member)
                local roleIcon = (role and role.icon) or RoleIconFor(member)
                row.roleIcon:SetTexture(roleIcon)
                row.roleIcon:SetShown(roleIcon ~= nil)
                local colorHex = member.classInfo and member.classInfo.colorHex or "c0c0c0"
                row.name:SetText("|cff" .. colorHex .. member.displayName .. "|r")

                if row.dropdown and member.classInfo and not member.isPet then
                    row.dropdown:SetShown(true)
                    UIDropDownMenu_SetText(row.dropdown, role
                        and RoleText(role, member.classInfo)
                        or (roleId and "|cff909090?|r" or "|cff909090None|r"))
                    if data.isDemo or WhoDoesWhat:CanEditRoleOf(member.name) then
                        UIDropDownMenu_EnableDropDown(row.dropdown)
                    else
                        UIDropDownMenu_DisableDropDown(row.dropdown)
                    end
                elseif row.dropdown then
                    row.dropdown:Hide()
                end
            end
            for column, paladin in ipairs(paladins) do
                local cell = row.cells[column] or CreatePlanCell(row, column)
                cell:ClearAllPoints()
                cell:SetPoint("LEFT", row, "LEFT",
                    columnStart[side]
                        + K.PaladinColumnOffset(column, paladins, COL_W)
                        + (COL_W - CELL_SIZE) / 2, 0)
                cell.paladin = paladin.name
                cell.raider = member.displayName
                cell.sourceLabel = sourceLabels[side]
                K.SetPaladinBuffCell(cell, plans[side], member.planName, paladin)
                cell.empty:SetShown(cell.buffKey == nil)
                cell.alertKind, cell.alertMessage = nil, nil
                if side == 1 then
                    cell.alertKind, cell.alertMessage =
                        CellOutline(data, member, paladin, cell.buffKey)
                end
                if cell.alertKind == "red" then
                    cell.alert:SetBackdropBorderColor(1, 0.05, 0.05, 1)
                elseif cell.alertKind == "yellow" then
                    cell.alert:SetBackdropBorderColor(1, 0.82, 0, 1)
                end
                cell.alert:SetShown(cell.alertKind ~= nil)
                cell.icon:SetDesaturated(false)
                cell:Show()
            end
            for column = #paladins + 1, #row.cells do row.cells[column]:Hide() end
            row:Show()
        end
        for index = #data.members + 1, #f.content.rows[side] do
            f.content.rows[side][index]:Hide()
        end
    end

    for index, member in ipairs(data.members) do
        local button = f.content.fixButtons[index] or CreateFixButton(f.content, index)
        button.member = member
        button.ownerFrame = f
        button.isDemo = data.isDemo
        local canFix, blocked = false, nil
        if not data.isDemo then
            canFix, blocked = WhoDoesWhat:CanFixPlayerBuffsInPallyPower(
                member.planName, data.diffs)
        end
        button.blockedPaladin = blocked
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", f.content, "TOPLEFT", fixX,
            -((index - 1) * ROW_H + 2))
        button:SetEnabled(not data.isDemo and canFix)
        button:Show()
    end
    for index = #data.members + 1, #f.content.fixButtons do
        f.content.fixButtons[index]:Hide()
        f.content.fixButtons[index].member = nil
    end

    f.content:SetHeight(bodyHeight)
    f.scroll:SetVerticalScroll(0)
    f.scroll:UpdateScrollChildRect()
    K.UpdatePaladinGridScroll(f.scroll, bodyHeight)
end

RenderDiffs = function(f)
    local data
    if f.demoData then
        data = f.demoData
    else
        data = LiveComparisonData()
    end
    if not data then
        SetCompact(f)
        return false
    end

    RenderGrid(f, data)
    f.diffCount = data.diffCount
    f.sendBtn:SetText("Fix All (" .. data.diffCount .. ")")
    if data.isDemo then
        f.sendBtn:Disable()
        f.secondaryBtn:SetText("Close")
    else
        f.sendBtn.canFix, f.sendBtn.blockedPaladin =
            WhoDoesWhat:CanFixAllPallyPowerAssignments()
        f.sendBtn:SetEnabled(f.sendBtn.canFix)
        f.secondaryBtn:SetText("Ignore")
    end
    -- The window repaints itself on every plan change (RefreshBuffingGridView
    -- is the "buff plan changed" hook and reaches us), so the second button
    -- only exists to dismiss the two modes that aren't live diffs.
    f.secondaryBtn:SetShown(data.isDemo or f.warningText ~= nil)
    return true
end

local function EnsureFrame()
    if diffFrame then return diffFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatPallyPowerDiffFrame",
        COMPACT_W, COMPACT_H, "Paladin Assignment Differences")
    f.titleText:ClearAllPoints()
    f.titleText:SetPoint("CENTER", f, "TOP", 0, -(f.titleBarHeight / 2 + 5))

    local sendBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sendBtn:SetSize(130, 22)
    sendBtn:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN)
    sendBtn:SetText("Fix All (0)")
    sendBtn:SetMotionScriptsWhileDisabled(true)
    sendBtn:SetScript("OnClick", function()
        if f.demoData then return end
        StaticPopup_Hide("WHODOESWHAT_FIX_ALL_PALLYPOWER")
        StaticPopup_Show("WHODOESWHAT_FIX_ALL_PALLYPOWER", f.diffCount, nil,
            function()
                f.warningText = nil
                if WhoDoesWhat:SyncToPallyPower() then
                    WhoDoesWhat:RefreshMainAssignmentsView()
                    f:Hide()
                end
            end)
    end)
    sendBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Fix all PallyPower assignments", 1, 1, 1)
        if f.demoData then
            GameTooltip:AddLine("Disabled for view-only demo data.", 0.8, 0.8, 0.8, true)
        elseif not self.canFix then
            GameTooltip:AddLine(self.blockedPaladin
                .. " has Free Assignment turned off.", 1, 0.2, 0.2, true)
            GameTooltip:AddLine("Fix All cannot be used by a non-assistant until"
                .. " every paladin enables it.", 0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine("Broadcast the complete WDW blessing plan to"
                .. " PallyPower clients and update WDW's local mirror.",
                0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    sendBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.sendBtn = sendBtn

    local secondary = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    secondary:SetSize(80, 22)
    secondary:SetPoint("RIGHT", sendBtn, "LEFT", -6, 0)
    secondary:SetText("Ignore")
    secondary:SetScript("OnClick", function()
        f.demoData = nil
        f.warningText = nil
        f:Hide()
    end)
    f.secondaryBtn = secondary

    local warning = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    warning:SetHeight(WARNING_H)
    warning:SetJustifyH("CENTER")
    warning:SetJustifyV("TOP")
    warning:SetTextColor(1, 0.2, 0.2)
    warning:SetText("PallyPower is this raid's buff source and you have no edit"
        .. " rights. Use fixes sparingly; they rely on paladins who enabled"
        .. " Free Assignment.")
    warning:Hide()
    f.warning = warning

    local header = CreateFrame("Frame", nil, f)
    local scroll, content = K.CreatePaladinGridScroll(f,
        "WhoDoesWhatPallyPowerDiffScroll")
    f.header = header
    f.scroll = scroll
    f.content = content

    header.headers = { {}, {} }
    content.rows = { {}, {} }
    content.fixButtons = {}
    f.summaryRows = {}
    f.gridTitles = {}
    f.headerPaladinStripes = {}
    f.bodyPaladinStripes = {}
    for side = 1, 2 do
        local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:Hide()
        f.gridTitles[side] = title
        f.headerPaladinStripes[side] = K.CreateLocalPaladinStripe(header)
        f.bodyPaladinStripes[side] = K.CreateLocalPaladinStripe(content)
    end

    WhoDoesWhat:LogUiBuilding("Building PallyPower diff grids.")
    diffFrame = f
    return f
end

local function DummyPlan(paladins, members, assignments)
    local plan = { grid = {}, greaterByPaladin = {}, targetClass = {} }
    for _, paladin in ipairs(paladins) do
        plan.greaterByPaladin[paladin.name] = {}
    end
    for row, member in ipairs(members) do
        local className = member.classInfo.name
        plan.grid[member.name] = {}
        plan.targetClass[member.name] = className
        for column, paladin in ipairs(paladins) do
            local buffKey = assignments[row][column]
            plan.grid[member.name][paladin.name] = buffKey
            plan.greaterByPaladin[paladin.name][className] = buffKey
        end
    end
    return plan
end

local function TestPaladins()
    local paladin = ClassInfo("Paladin")
    local paladins, used = {}, {}
    for _, member in ipairs(GroupPaladins()) do
        if #paladins == 3 then break end
        paladins[#paladins + 1] = member
        used[member.name] = true
    end
    for _, fake in ipairs(WhoDoesWhat.FakeRaid.PALADINS) do
        if #paladins == 3 then break end
        if not used[fake.name] then
            local role = WhoDoesWhat.RolesAndCategories[fake.role]
            paladins[#paladins + 1] = {
                name = fake.name,
                classInfo = paladin,
                roleIcon = role and role.icon,
                isTestFallback = true,
            }
            used[fake.name] = true
        end
    end
    return K.OrderPaladinsLocalFirst(paladins)
end

local function DummyData()
    local paladins = TestPaladins()
    local members = {
        { name = "Ironhide", classInfo = ClassInfo("Warrior"), testRoleId = "warrior_prot" },
        { name = "Lightwell", classInfo = ClassInfo("Priest"), testRoleId = "priest_holy" },
        { name = "Arcanum", classInfo = ClassInfo("Mage"), testRoleId = "mage_arcane" },
        { name = "Backstabby", classInfo = ClassInfo("Rogue"), testRoleId = "rogue_combat" },
        { name = "Beastly", classInfo = ClassInfo("Hunter"), testRoleId = "hunter_bm" },
    }
    for _, member in ipairs(members) do
        member.planName = member.name
        member.displayName = member.name
    end

    local suggestedRows, currentRows, orders = {}, {}, {}
    for row, member in ipairs(members) do
        local order = WhoDoesWhat:GetEffectiveBuffOrder(member.testRoleId)
            or WhoDoesWhat.CanonicalBuffOrder
        orders[row] = order
        local top, special
        top = {}
        for i = 1, math.min(#paladins, #order) do
            top[#top + 1] = order[i]
            if order[i] == "might" or order[i] == "wisdom" then special = order[i] end
        end

        local suggestedRow, used = {}, {}
        if special and #paladins > 1 then
            suggestedRow[2] = special
            used[special] = true
        end
        local nextBuff = 1
        for column = 1, #paladins do
            if not suggestedRow[column] then
                while top[nextBuff] and used[top[nextBuff]] do nextBuff = nextBuff + 1 end
                suggestedRow[column] = top[nextBuff]
                if top[nextBuff] then used[top[nextBuff]] = true end
                nextBuff = nextBuff + 1
            end
        end
        suggestedRows[row] = suggestedRow
        currentRows[row] = { unpack(suggestedRow) }
    end

    -- One explicit outside-top-X case, one valid-but-less-improved case, then
    -- harmless column swaps so every demo row remains a visible difference.
    currentRows[1][1] = orders[1][#paladins + 1]
    currentRows[2][1], currentRows[2][2] = currentRows[2][2], currentRows[2][1]
    for row = 3, #currentRows do
        currentRows[row][1], currentRows[row][2] =
            currentRows[row][2], currentRows[row][1]
    end

    local talentRanks = {}
    for index, paladinMember in ipairs(paladins) do
        talentRanks[paladinMember.name] = {
            kings = 1,
            sanctuary = 1,
            might = index == 2 and 5 or 0,
            wisdom = index == 2 and 2 or 0,
        }
    end
    local current = DummyPlan(paladins, members, currentRows)
    local suggested = DummyPlan(paladins, members, suggestedRows)
    local diffCount = 0
    for row = 1, #members do
        for column = 1, #paladins do
            if currentRows[row][column] ~= suggestedRows[row][column] then
                diffCount = diffCount + 1
            end
        end
    end
    return {
        paladins = paladins,
        members = members,
        current = current,
        suggested = suggested,
        talentRanks = talentRanks,
        diffCount = diffCount,
        isDemo = true,
    }
end

local function ValidateDummyData(data)
    assert(#data.paladins == 3)
    assert(K.PaladinColumnsWidth({}, COL_W, 3) == COL_W * 3)
    local red, yellow, changed = 0, 0, 0
    for _, member in ipairs(data.members) do
        local differs = false
        member.topBuffs = TopBuffSet(data, member)
        for _, paladin in ipairs(data.paladins) do
            if data.current.grid[member.name][paladin.name]
                ~= data.suggested.grid[member.name][paladin.name] then
                differs = true
                changed = changed + 1
            end
            local kind = CellOutline(data, member, paladin,
                data.current.grid[member.name][paladin.name])
            if kind == "red" then red = red + 1 end
            if kind == "yellow" then yellow = yellow + 1 end
        end
        assert(differs)
    end
    assert(red > 0 and yellow > 0 and changed == data.diffCount)
end

function WhoDoesWhat:OpenPallyPowerDiffView(warningText)
    local f = EnsureFrame()
    f.demoData = nil
    f.warningText = warningText
    local hasDiffs = RenderDiffs(f)
    if not warningText then self:RefreshMainAssignmentsView() end
    if warningText and not hasDiffs then return end
    self:LogUiBuilding("Opening PallyPower Differences...")
    f:Show()
    f:Raise()
end

function WhoDoesWhat:OpenPallyPowerDiffTestView()
    local f = EnsureFrame()
    f.warningText = nil
    f.demoData = DummyData()
    ValidateDummyData(f.demoData)
    RenderDiffs(f)
    self:LogUiBuilding("Opening PallyPower Differences test data...")
    f:Show()
    f:Raise()
end

-- Repainted from RefreshBuffingGridView, the addon's "buff plan changed" hook,
-- so the open window tracks PallyPower traffic, role changes, buffing rules
-- and talent arrivals without the user asking. Nothing left to differ means
-- nothing left to show, so the window gets out of the way.
function WhoDoesWhat:RefreshPallyPowerDiffView()
    if diffFrame and diffFrame:IsShown() and not diffFrame.demoData then
        diffFrame.warningText = nil
        if not RenderDiffs(diffFrame) then diffFrame:Hide() end
    end
end
