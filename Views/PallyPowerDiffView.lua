local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Side-by-side paladin-buff grids for the players whose current PallyPower
-- coverage differs from WhoDoesWhat's suggested plan.

local K = WhoDoesWhat.SectionKit
local A = WhoDoesWhat.Assign
local diffFrame = nil
local RenderDiffs

local FRAME_MIN_W = 560
local FRAME_H = 470
local COMPACT_W = 390
local COMPACT_H = 92
local MARGIN = 10
local BOTTOM_STRIP = 30
local STATUS_H = 46
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
        GameTooltip:AddLine(self.isDemo and "Disabled for view-only demo data."
            or "Send only this player's WDW blessing plan to PallyPower.",
            0.8, 0.8, 0.8, true)
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

local function SetCompact(f, reason)
    f:SetSize(COMPACT_W, COMPACT_H)
    f.titleText:SetText("WhoDoesWhat - PallyPower")
    f.scroll:Hide()
    f.sendBtn:Hide()
    f.secondaryBtn:Hide()
    if reason == "no-paladins" then
        f.status:SetText("|cff909090There are no paladins in the group"
            .. " -- nothing to compare.|r")
    else
        f.status:SetText("|cff40ff40PallyPower matches the current WDW plan.|r")
    end
end

local function SetExpanded(f, width)
    f:SetSize(math.max(FRAME_MIN_W, width), FRAME_H)
    f.titleText:SetText("WhoDoesWhat - PallyPower Differences")
    f.scroll:Show()
    f.sendBtn:Show()
    f.secondaryBtn:Show()
end

local function RenderGrid(f, data)
    local paladins = data.paladins
    local localGap = paladins[1] and K.IsLocalPaladin(paladins[1])
        and K.PALADIN_GRID_LOCAL_GAP or 0
    local paladinW = math.max(K.PaladinColumnsWidth(paladins, COL_W),
        COL_W * 3 + localGap)
    local leftW = LEFT_PREFIX_W + paladinW
    local rightW = paladinW
    local rightX = leftW + GRID_GAP
    local fixX = rightX + rightW + FIX_GAP
    local canFix = WhoDoesWhat:CanFixPallyPowerAssignments()
    local showRowFix = data.isDemo or canFix
    local contentW = showRowFix and (fixX + FIX_W) or (rightX + rightW)
    local frameW = contentW + MARGIN * 2 + 24
    SetExpanded(f, frameW)
    f.content:SetWidth(contentW)

    local gridX = { 0, rightX }
    local gridW = { leftW, rightW }
    local columnStart = { LEFT_PREFIX_W, 0 }
    local plans = { data.current, data.suggested }
    local sourceLabels = { "Current", "Suggested" }

    for _, member in ipairs(data.members) do
        member.topBuffs = TopBuffSet(data, member)
    end

    for side = 1, 2 do
        local x = gridX[side]
        local title = f.gridTitles[side]
        title:ClearAllPoints()
        title:SetPoint("TOPLEFT", f.content, "TOPLEFT", x + columnStart[side], 0)
        title:SetWidth(paladinW)
        title:SetJustifyH("CENTER")
        title:SetText(sourceLabels[side])
        title:Show()

        for column, paladin in ipairs(paladins) do
            local header = f.content.headers[side][column]
                or CreatePaladinHeader(f.content, side, column)
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", f.content, "TOPLEFT",
                x + columnStart[side]
                    + K.PaladinColumnOffset(column, paladins, COL_W)
                    + (COL_W - CELL_SIZE) / 2,
                -(TITLE_H + (HEADER_H - CELL_SIZE) / 2))
            header.paladin = paladin.name
            header.paladinMember = paladin
            header.icon:SetTexture(RoleIconFor(paladin))
            header.initial:SetText(paladin.name:sub(1, 1))
            local color = paladin.classInfo and paladin.classInfo.colorRGB
            header.initial:SetTextColor(color and color.r or 0.96,
                color and color.g or 0.55, color and color.b or 0.73)
            header:Show()
        end
        for column = #paladins + 1, #f.content.headers[side] do
            f.content.headers[side][column]:Hide()
        end

        local stripe = f.localPaladinStripes[side]
        if paladins[1] and K.IsLocalPaladin(paladins[1]) then
            stripe:ClearAllPoints()
            stripe:SetPoint("TOPLEFT", f.content, "TOPLEFT",
                x + columnStart[side], -TITLE_H)
            stripe:SetSize(COL_W, HEADER_H + #data.members * ROW_H)
            stripe:Show()
        else
            stripe:Hide()
        end

        for index, member in ipairs(data.members) do
            local row = f.content.rows[side][index]
                or CreateComparisonRow(f.content, side, index)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", f.content, "TOPLEFT", x,
                -(TITLE_H + HEADER_H + (index - 1) * ROW_H))
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
        if showRowFix then
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", f.content, "TOPLEFT", fixX,
                -(TITLE_H + HEADER_H + (index - 1) * ROW_H + 2))
            button:SetEnabled(not data.isDemo)
            button:Show()
        else
            button:Hide()
        end
    end
    for index = #data.members + 1, #f.content.fixButtons do
        f.content.fixButtons[index]:Hide()
        f.content.fixButtons[index].member = nil
    end

    f.content:SetHeight(TITLE_H + HEADER_H + #data.members * ROW_H)
    f.scroll:SetVerticalScroll(0)
    f.scroll:UpdateScrollChildRect()
end

RenderDiffs = function(f)
    local data, reason
    if f.demoData then
        data = f.demoData
    else
        data, reason = LiveComparisonData()
    end
    if not data then
        SetCompact(f, reason)
        return false
    end

    RenderGrid(f, data)
    f.diffCount = data.diffCount
    f.sendBtn:SetText("Fix All (" .. data.diffCount .. ")")
    if data.isDemo then
        f.status:SetText("|cffffd000Demo data:|r side-by-side current and suggested"
            .. " assignments. Red is outside top X; yellow has a better improved caster.")
        f.sendBtn:Disable()
        f.secondaryBtn:SetText("Close")
    else
        f.sendBtn.canFix = WhoDoesWhat:CanFixPallyPowerAssignments()
        f.sendBtn:SetEnabled(f.sendBtn.canFix)
        f.secondaryBtn:SetText(f.warningText and "Ignore" or "Recheck")
        f.status:SetText(f.warningText
            and ("|cffff6060PallyPower was not auto-updated.|r " .. f.warningText)
            or ("|cffffd000" .. #data.members .. " player"
                .. (#data.members == 1 and " differs" or "s differ")
                .. " from the WDW plan.|r " .. data.diffCount .. " changed buff"
                .. (data.diffCount == 1 and ". " or "s. ")
                .. "Red is outside top X; yellow has a better improved caster."))
    end
    return true
end

local function EnsureFrame()
    if diffFrame then return diffFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatPallyPowerDiffFrame",
        FRAME_MIN_W, FRAME_H, "WhoDoesWhat - PallyPower Differences")

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
                WhoDoesWhat:SyncToPallyPower()
                WhoDoesWhat:RefreshMainAssignmentsView()
                f:Hide()
            end)
    end)
    sendBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Fix all PallyPower assignments", 1, 1, 1)
        local detail = f.demoData and "Disabled for view-only demo data."
            or not self.canFix and "Only the party leader or a raid lead/assist can fix PallyPower."
            or "Broadcast the complete WDW blessing plan to PallyPower clients"
                .. " and update WDW's local mirror."
        GameTooltip:AddLine(detail, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    sendBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.sendBtn = sendBtn

    local secondary = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    secondary:SetSize(80, 22)
    secondary:SetPoint("RIGHT", sendBtn, "LEFT", -6, 0)
    secondary:SetText("Recheck")
    secondary:SetScript("OnClick", function()
        if f.demoData or f.warningText then
            f.demoData = nil
            f.warningText = nil
            f:Hide()
        else
            RenderDiffs(f)
        end
    end)
    f.secondaryBtn = secondary

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    status:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + 10))
    status:SetPoint("TOPRIGHT", -MARGIN, -(f.titleBarHeight + 10))
    status:SetHeight(STATUS_H)
    status:SetJustifyH("LEFT")
    status:SetJustifyV("TOP")
    f.status = status

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + 10 + STATUS_H))
    scroll:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN + BOTTOM_STRIP)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetPoint("TOPLEFT")
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    scroll.scrollBarHideable = 1
    f.scroll = scroll
    f.content = content

    content.headers = { {}, {} }
    content.rows = { {}, {} }
    content.fixButtons = {}
    f.gridTitles = {}
    f.localPaladinStripes = {}
    for side = 1, 2 do
        local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:Hide()
        f.gridTitles[side] = title
        f.localPaladinStripes[side] = K.CreateLocalPaladinStripe(content)
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

function WhoDoesWhat:RefreshPallyPowerDiffView()
    if diffFrame and diffFrame:IsShown() and not diffFrame.demoData then
        diffFrame.warningText = nil
        RenderDiffs(diffFrame)
    end
end
