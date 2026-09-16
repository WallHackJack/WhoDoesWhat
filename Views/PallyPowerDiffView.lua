local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI

-- Side-by-side paladin-buff grids for the players whose current PallyPower
-- coverage differs from WhoDoesWhat's suggested plan. Above each grid's
-- columns sits a per-paladin overview strip -- the blessings that paladin
-- mostly carries in that plan, count-descending -- the same shape as the
-- Paladin Buffs rows in the main window.
--
-- It lives in the right-hand panel of the main window's Blessings page, beside
-- the sections it compares against: a heading with Fix All, then the grids.
-- The grids stretch across the panel; the role picker shows just the role's icon, and
-- a raid with enough paladins to outgrow it has the grids scaled down to fit
-- rather than cut off. With nothing to compare -- PallyPower agrees, or a
-- simulated raid it can't see -- it shows the overview strip of the running
-- plan alone (RenderPlan).

local K = WhoDoesWhat.SectionKit
local A = WhoDoesWhat.Assign
local THEME = WhoDoesWhat.Theme
local diffPanel = nil
local RenderDiffs

local BAR_H = 38
local MARGIN = 6
local WARNING_H = 34
local SCROLLBAR_W = UI.SCROLLBAR_W
local SCROLLBAR_GAP = 4
local GRID_GAP = 6
local PLAYER_COL_W = 104
-- An icon-only dropdown: the template's floor, plus its ~15px overhang.
local ROLE_DD_W = K.MARKER_DD_WIDTH
local ROLE_COL_W = 66
local ROLE_GRID_GAP = 8
local LEFT_PREFIX_W = PLAYER_COL_W + ROLE_COL_W + ROLE_GRID_GAP
local FIX_GAP = 6
local FIX_W = 34
local TITLE_H = 22
local HEADER_H = 26
local ROW_H = 24
local ROLE_ICON_SIZE = 18
-- The Paladin Buffs rows: the full-height row style of the sections, big buff
-- icons, and a Progress column right-aligned just before the first plan column,
-- which needs PROGRESS_ROOM more than the grids' own name prefix leaves.
local SUMMARY_ROW_H = UI.ROW_H
local SUMMARY_MAX_BUFFS = 3
local SUMMARY_ICON = K.ROW_ICON_SIZE
local SUMMARY_SLOT_W = SUMMARY_ICON + 2
local PROGRESS_ROOM = 80
local PROGRESS_W = 124
local PROGRESS_GAP = 10
local COVERAGE_OK_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"
-- The PallyPower Differences heading between those rows and the grids.
local DIFF_GAP = 10
local DIFF_HEADING_H = 30
local CELL_SIZE = K.PALADIN_GRID_CELL_SIZE
-- The line under the Differences heading, in one of three styles: the fix
-- warning in small red, a plain note in small grey, and "all in sync" in large
-- green behind a tick, since that one is the good news the panel exists for.
local FIX_WARNING = "PallyPower is this raid's buff source and you have no edit"
    .. " rights. Use fixes sparingly; they rely on paladins who enabled"
    .. " Free Assignment."
local WARNING_STYLE = { font = "GameFontHighlightSmall", color = { 1, 0.2, 0.2 } }
local NOTE_STYLE = { font = "GameFontHighlightSmall", color = { 0.7, 0.7, 0.7 } }
local SYNCED_STYLE = { font = "GameFontNormalLarge", color = { 0.3, 1, 0.3 },
    icon = "Interface\\RaidFrame\\ReadyCheck-Ready", padTop = 12, padBottom = 12 }
local NOTE_ICON_SIZE = 22
local NOTE_ICON_GAP = 6
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
    return WhoDoesWhat:RoleIconMarkup(role.icon, 14) .. " |cff"
        .. classInfo.colorHex .. role.name .. "|r"
end

-- The rows' picker shows only this; the menu and the tooltip carry the name.
local function RoleIcon(role)
    return WhoDoesWhat:RoleIconMarkup(role.icon, 14)
end

local function AssignedRole(data, member)
    local roleId = data.isDemo and member.testRoleId
        or WhoDoesWhat:GetAssignedRole(member.name)
    local role
    if roleId then _, role = WhoDoesWhat:FindRoleById(roleId) end
    return role, roleId
end

-- Matches the bridge's rule so the greyed rows and the rows Fix All skips are
-- always the same set. Pets and rows for players who already left the group
-- have no role of their own to pick.
local function NeedsRole(data, member)
    if not member.classInfo or member.isPet then return false end
    if data.isDemo then return member.testRoleId == nil end
    return WhoDoesWhat:PallyPowerRowNeedsRole(member.planName)
end

local function PallyPowerMode()
    return (WhoDoesWhat.db.profile.settings.pallyBuffSource or "wdw") == "pallypower"
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
            display.displayName = WhoDoesWhat:DisplayName(member.name)
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
                displayName = WhoDoesWhat:DisplayName(diff.target),
                roleIcon = diff.targetIcon,
                roleName = diff.targetRole,
            }
        end
    end
    -- Same ordering as the buff grid: class > pets after Warriors > role >
    -- name. Rows kept for targets who have left the group carry no class
    -- metadata, so they fall to the bottom.
    table.sort(members, function(a, b)
        local classA = a.isPet and "Warrior" or (a.classInfo and a.classInfo.name)
        local classB = b.isPet and "Warrior" or (b.classInfo and b.classInfo.name)
        if classA ~= classB then
            if not classA then return false end
            if not classB then return true end
            return classA < classB
        end
        -- Real Warriors first, then the pet section beneath them.
        if (a.isPet or false) ~= (b.isPet or false) then
            return not a.isPet
        end
        -- Within a class, group by assigned role (tank/heal/dps clump together).
        local ra = WhoDoesWhat:RoleSortRank(a.planName)
        local rb = WhoDoesWhat:RoleSortRank(b.planName)
        if ra ~= rb then return ra < rb end
        return a.planName < b.planName
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
    -- Roleless rows still show as differences -- they are worth seeing -- but
    -- Fix All will not touch them, so they are not part of its count.
    local fixable = 0
    for _, diff in ipairs(diffs) do
        if not WhoDoesWhat:PallyPowerRowNeedsRole(
            diff.planTarget or ShortName(diff.target)) then
            fixable = fixable + 1
        end
    end
    return {
        fixableCount = fixable,
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
            UI.ShowTooltip(self, self.paladin, "Simulated Paladin")
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
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", 6, 0)
        name:SetWidth(PLAYER_COL_W - 10)
        name:SetJustifyH("LEFT")
        row.name = name

        -- In the role column: the picker, or for a row with no role to pick
        -- (a pet, a raider who left) just the icon.
        local roleIcon = row:CreateTexture(nil, "ARTWORK")
        roleIcon:SetSize(ROLE_ICON_SIZE, ROLE_ICON_SIZE)
        roleIcon:SetPoint("LEFT", PLAYER_COL_W + 8, 0)
        row.roleIcon = roleIcon

        local dropdown = UI.CreateMenuDropdown(row, "WhoDoesWhatPpDiffRoleDD" .. index, ROLE_DD_W)
        dropdown:SetPoint("LEFT", row, "LEFT", PLAYER_COL_W - 15, -2)
        UI.AddDropdownTooltip(dropdown, nil, function()
            local member = row.member
            if not (member and member.classInfo) then return end
            local role = AssignedRole(row.data, member)
            return member.displayName, role and RoleText(role, member.classInfo)
                or "No role yet."
        end)
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
                        WhoDoesWhat:SetAssignedRole(member.name, role.id, nil, true)
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
    UI.AddTooltip(cell, function(self)
        GameTooltip:SetText(self.paladin, unpack(UI.TOOLTIP_TITLE))
        if self.buffKey then
            GameTooltip:AddLine(self.sourceLabel .. ": "
                .. (self.isGreater and "Greater Blessing of " or "Blessing of ")
                .. WhoDoesWhat.PaladinBuffs[self.buffKey].name_long .. ".",
                0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine(self.sourceLabel .. ": no assignment for "
                .. self.raider .. ".", 0.6, 0.6, 0.6, true)
        end
        if self.needsRole then
            GameTooltip:AddLine(self.raider .. " has no role yet, so this is a"
                .. " default guess.", 1, 0.82, 0, true)
        end
        if self.alertMessage then
            local color = self.alertKind == "red" and { 1, 0.3, 0.3 }
                or { 1, 0.82, 0 }
            GameTooltip:AddLine(self.alertMessage, color[1], color[2], color[3], true)
        end
        return true
    end)
    row.cells[index] = cell
    return cell
end

local function CreateFixButton(content, index)
    local button = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    button:SetSize(FIX_W, 20)
    button:SetText("Fix")
    button:SetScript("OnClick", function(self)
        if not self.member or self.isDemo then return end
        if WhoDoesWhat:FixPlayerBuffsInPallyPower(self.member.planName) then
            WhoDoesWhat:RefreshMainAssignmentsView()
        end
        RenderDiffs(self.ownerFrame)
    end)
    UI.AddTooltip(button, function(self)
        GameTooltip:SetText("Fix " .. (self.member and self.member.displayName or "row"),
            unpack(UI.TOOLTIP_TITLE))
        if self.isDemo then
            GameTooltip:AddLine("Disabled for view-only demo data.", 0.8, 0.8, 0.8, true)
        elseif self.member and self.member.needsRole then
            GameTooltip:AddLine("This player has no role yet.", 1, 0.82, 0, true)
            GameTooltip:AddLine("Pick a role before pushing a blessing plan for them.",
                0.8, 0.8, 0.8, true)
        elseif self.blockedPaladin then
            GameTooltip:AddLine(self.blockedPaladin
                .. " has Free Assignment turned off.", 1, 0.2, 0.2, true)
            GameTooltip:AddLine("This row cannot be fixed by a non-assistant.",
                0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine("Send only this player's WDW blessing plan to PallyPower.",
                0.8, 0.8, 0.8, true)
        end
        return true
    end)
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
-- Paladin Buffs rows, above the grids: each paladin's live progress on the
-- plan WDW is running, then which blessings they mostly carry in each plan
-- shown (count-descending, under that plan's grid), and the whisper for what
-- they are missing at the far right, over the Fix column. The blessings are
-- computed straight off the plan grids so they also work for the demo data's
-- simulated paladins.
-- ---------------------------------------------------------------------------

local function CoverageTextColor(correct, total)
    if total == 0 then return 0.5, 0.5, 0.5 end
    local ratio = correct / total
    if ratio >= 1 then return 0.3, 1, 0.3 end
    local t = math.min(ratio / 0.95, 1)
    return 1, 0.2 + 0.62 * t, 0.2
end

local function CoverageText(correct, total)
    if total == 0 then return "|cff909090No assignments|r", "" end
    local r, g, b = CoverageTextColor(correct, total)
    local color = string.format("%02x%02x%02x",
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5))
    local percent = math.floor(correct / total * 100 + 0.5)
    return "|cff" .. color .. correct .. "|r |cff909090of|r |cffffffff"
        .. total .. "|r",
        "(" .. percent .. "%)"
end

function WhoDoesWhat:TestPaladinCoverageText()
    assert(CoverageText(0, 0):find("No assignments", 1, true))
    assert(CoverageText(0, 10):find("|cffff33330|r", 1, true))
    local text, percent = CoverageText(19, 20)
    assert(text:find("|cffffd13319|r", 1, true) and percent == "(95%)")
    assert(CoverageText(10, 10):find("|cff4dff4d10|r", 1, true))
    self:Print("Paladin coverage-text check passed.")
end

-- What the Progress column reads, worked out once per paint: live coverage on
-- the active plan, who is still waiting on talent data (WDW mode only -- in
-- PallyPower mode their board assigns them regardless), and whether edits
-- are this client's to make.
local function PaladinProgress()
    local plan = A.GetActivePaladinBuffPlan()
    local _, _, byPaladin = A.ComputePaladinBuffCoverage(plan)
    local wdw = not PallyPowerMode()
    local awaiting = {}
    if wdw then
        for _, paladin in ipairs(A.ComputePaladinBuffSummary(plan)) do
            if paladin.awaitingTalents then awaiting[paladin.name] = true end
        end
    end
    return {
        byPaladin = byPaladin or {},
        awaiting = awaiting,
        wdw = wdw,
        editable = WhoDoesWhat:CanEditAssignments(),
    }
end

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

local function SummarySlotTooltip(self)
    if not self.buffKey then return end
    return WhoDoesWhat.PaladinBuffs[self.buffKey].name_long,
        self.sourceLabel .. ": " .. self.paladin .. " blesses " .. self.buffCount
            .. (self.buffCount == 1 and " raider" or " raiders") .. "."
end

local function CreateSummaryRow(f, index)
    local row = CreateFrame("Frame", nil, f.header)
    row:SetHeight(SUMMARY_ROW_H)

    local stripe = THEME.blessings.rows[index % 2 == 1 and 1 or 2]
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(stripe[1], stripe[2], stripe[3], 1)

    -- Role icon and name as one string; the paladin's own tooltip over it.
    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("LEFT", 4, 0)
    name:SetWidth(K.NAME_LABEL_W)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    row.name = name

    local nameHover = CreateFrame("Frame", nil, row)
    nameHover:SetSize(K.NAME_LABEL_W, SUMMARY_ROW_H)
    nameHover:SetPoint("LEFT", 4, 0)
    nameHover:EnableMouse(true)
    nameHover:SetScript("OnEnter", function(self)
        local paladin = row.paladin
        if not paladin then return end
        if paladin.isTestFallback then
            UI.ShowTooltip(self, paladin.name, "Simulated Paladin")
        else
            WhoDoesWhat:ShowRaiderTooltip(self, paladin.name)
        end
    end)
    nameHover:SetScript("OnLeave", function() WhoDoesWhat:HideRaiderTooltip() end)

    -- Far right, over the grids' Fix column: whisper the paladin what they
    -- still have to cast.
    row.mailBtn = K.CreateMailButton(row, function()
        local paladin = row.paladin
        if not paladin then return end
        local msg = A.GetPaladinBuffWhisper(paladin.name)
        if msg then return paladin.name, msg, msg, true end
    end)
    row.mailBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)

    -- Progress, right to left from where RenderSummary puts the percentage:
    -- the percentage, "n of n", a tick (or the awaiting-talents mark), and a (!)
    -- for a paladin running neither addon. Hovering the column explains the
    -- awaiting-talents state, which the short text can't.
    local percent = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    local percentFont, percentSize, percentFlags = percent:GetFont()
    if percentFont then
        percent:SetFont(percentFont, math.max(percentSize - 2, 8), percentFlags)
    end
    row.coveragePercent = percent
    local coverage = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    coverage:SetPoint("RIGHT", percent, "LEFT", -2, 0)
    row.coverageText = coverage
    local coverageIcon = row:CreateTexture(nil, "OVERLAY")
    coverageIcon:SetSize(16, 16)
    coverageIcon:SetPoint("RIGHT", coverage, "LEFT", -4, 0)
    row.coverageIcon = coverageIcon

    local progressHover = CreateFrame("Frame", nil, row)
    progressHover:SetSize(PROGRESS_W, SUMMARY_ROW_H)
    progressHover:SetPoint("RIGHT", percent, "RIGHT")
    UI.AddTooltip(progressHover, function()
        if row.progressTip then return "Awaiting talents", row.progressTip end
    end)

    local warn = UI.CreateWarningIcon(row)
    warn:SetPoint("RIGHT", coverageIcon, "LEFT", -2, -1)
    warn:SetFrameLevel(progressHover:GetFrameLevel() + 1)
    row.warnIcon = warn

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
            UI.AddTooltip(slot, SummarySlotTooltip)
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

-- A paladin who blesses nobody in either plan is a pair of columns full of
-- X's -- wide, and silent about the difference this window exists to show.
-- Drop them from the paint only; data.paladins stays whole because the "top N
-- buffs" rule counts the raid's paladins, not the ones on screen.
local function VisiblePaladins(data)
    local shown = {}
    for _, paladin in ipairs(data.paladins) do
        for _, member in ipairs(data.members) do
            local current = data.current and data.current.grid[member.planName]
            local suggested = data.suggested and data.suggested.grid[member.planName]
            if (current and current[paladin.name])
                or (suggested and suggested[paladin.name]) then
                shown[#shown + 1] = paladin
                break
            end
        end
    end
    -- Never paint a grid with no columns at all.
    return #shown > 0 and shown or data.paladins
end

-- Paint the column titles and one row per paladin, `contentW` wide. Plan side
-- N's blessings start at columnX[N], `columnW` wide under its title; the plan
-- view (RenderPlan) passes one side only. Returns the height painted.
local function RenderSummary(f, paladins, columnX, plans, sourceLabels, columnW, contentW)
    local progressRight = columnX[1] - PROGRESS_GAP
    f.progressTitle:ClearAllPoints()
    f.progressTitle:SetPoint("RIGHT", f.header, "TOPLEFT", progressRight, -TITLE_H / 2)
    f.progressTitle:Show()
    for side = 1, 2 do
        local title = f.gridTitles[side]
        title:ClearAllPoints()
        if columnX[side] then
            title:SetPoint("TOPLEFT", f.header, "TOPLEFT", columnX[side], 0)
            title:SetSize(columnW, TITLE_H)
            title:SetJustifyH("CENTER")
            title:SetText(sourceLabels[side])
        end
        title:SetShown(columnX[side] ~= nil)
    end

    local progress = PaladinProgress()
    for index, paladin in ipairs(paladins) do
        local row = f.summaryRows[index] or CreateSummaryRow(f, index)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.header, "TOPLEFT", 0, -(TITLE_H + (index - 1) * SUMMARY_ROW_H))
        row:SetWidth(contentW)
        row.paladin = paladin

        -- Realm tags would eat the name column; tooltips and whispers still
        -- carry the full name.
        if paladin.isTestFallback then
            row.name:SetText(WhoDoesWhat:RoleIconMarkup(RoleIconFor(paladin), SUMMARY_ICON)
                .. " |cfff58cba" .. paladin.name .. "|r")
        else
            row.name:SetText(A.PlayerTextWithRole(paladin.name, SUMMARY_ICON,
                A.ShortAssignmentName(paladin.name)))
        end

        local name = paladin.name
        local awaiting = progress.awaiting[name]
        local coverage = progress.byPaladin[name] or { correct = 0, total = 0 }
        local complete = coverage.total > 0 and coverage.correct == coverage.total
        local missing = coverage.correct < coverage.total
        row.coveragePercent:ClearAllPoints()
        row.coveragePercent:SetPoint("RIGHT", row, "LEFT", progressRight, 0)
        row.coverageIcon:SetTexture(awaiting and WhoDoesWhat.WARNING_ICON or COVERAGE_OK_ICON)
        row.coverageIcon:SetShown(awaiting or complete)
        if awaiting then
            row.coverageText:SetText("Awaiting talents")
            row.coverageText:SetTextColor(1, 0.62, 0.25)
            row.coveragePercent:SetText("")
            row.progressTip = "WDW will not assign blessings to " .. name
                .. " until talent data arrives. Target them once while in range"
                .. " to pull it, or mark them Non-raider if they are sitting out."
        else
            local text, percent = CoverageText(coverage.correct, coverage.total)
            row.coverageText:SetText(text)
            row.coverageText:SetTextColor(1, 1, 1)
            row.coveragePercent:SetText(percent)
            row.progressTip = nil
        end
        local disabled = progress.wdw and not paladin.isTestFallback
            and WhoDoesWhat:IsPaladinDisabled(name)
        row.warnIcon:SetShown(disabled and true or false)
        if disabled then row.warnIcon.tooltipText = K.DisabledPaladinTooltip({ name }) end
        row.mailBtn:SetShown(progress.editable and not awaiting)
        row.mailBtn:SetEnabled(missing)
        row.mailBtn.icon:SetDesaturated(not missing)

        for side = 1, 2 do
            local x = columnX[side]
            local spread = x and BuffSpread(plans[side], paladin.name) or {}
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
            local none = row.sides[side].none
            more:ClearAllPoints()
            none:ClearAllPoints()
            if x then
                more:SetPoint("LEFT", row, "LEFT", x + shown * SUMMARY_SLOT_W + 1, 0)
                none:SetPoint("LEFT", row, "LEFT", x, 0)
            end
            more:SetShown(x and #spread > SUMMARY_MAX_BUFFS or false)
            none:SetShown(x and #spread == 0 or false)
        end
        row:Show()
    end
    for index = #paladins + 1, #f.summaryRows do
        f.summaryRows[index]:Hide()
        f.summaryRows[index].paladin = nil
    end
    return TITLE_H + #paladins * SUMMARY_ROW_H
end

-- No paladins at all: a line in the middle of the panel says so. With no rows
-- to span, the heading runs across the panel inside its margins -- FitCanvas
-- never places it until there are grids.
local function SetCompact(f)
    f.canvas:Hide()
    f.heading:ClearAllPoints()
    f.heading:SetPoint("LEFT", f, "TOPLEFT", MARGIN, -BAR_H / 2)
    f.heading:SetPoint("RIGHT", f, "TOPRIGHT", -MARGIN, -BAR_H / 2)
    f.emptyText:SetText("No paladins in the group.")
    f.emptyText:Show()
end

-- The room a block `contentW` wide leaves across the panel, which the grids
-- take up between the names and the paladin columns so they always span it.
-- None when the block is already too wide -- FitCanvas scales that down.
local function StretchRoom(f, contentW)
    local width = f:GetWidth() or 0
    return math.max(0, math.floor(width
        - (contentW + SCROLLBAR_GAP + SCROLLBAR_W + MARGIN * 2)))
end

-- The PallyPower Differences heading, `y` down the header under the Paladin
-- Buffs rows: named for the mode, Fix All (and End Demo) at its right end with
-- its rule running up to them, and `note` under it when given, in `noteStyle`
-- (one of the *_STYLE tables). Returns the y below it all.
local function PlaceDiffHeading(f, y, contentW, note, noteStyle, showFix)
    y = y + DIFF_GAP
    local heading = f.diffHeading
    local mid = -(y + DIFF_HEADING_H / 2)
    heading:ClearAllPoints()
    heading:SetPoint("LEFT", f.header, "TOPLEFT", 0, mid)
    heading:SetPoint("RIGHT", f.header, "TOPLEFT", contentW, mid)
    heading.label:SetText(PallyPowerMode() and "Unoptimized Buffs"
        or "PallyPower Differences")
    f.sendBtn:SetShown(showFix)

    local rule = heading.right
    rule:ClearAllPoints()
    rule:SetPoint("LEFT", heading.label, "RIGHT", 6, 0)
    local leftmost = (f.closeDemoBtn:IsShown() and f.closeDemoBtn)
        or (showFix and f.sendBtn) or nil
    if leftmost then
        rule:SetPoint("RIGHT", leftmost, "LEFT", -6, 0)
    else
        rule:SetPoint("RIGHT", heading, "RIGHT")
    end
    y = y + DIFF_HEADING_H

    f.warning:ClearAllPoints()
    f.noteIcon:Hide()
    if note then
        -- The font object first: setting one resets the colour.
        f.warning:SetFontObject(noteStyle.font)
        f.warning:SetText(note)
        local color = noteStyle.color
        f.warning:SetTextColor(color[1], color[2], color[3])
        y = y + (noteStyle.padTop or 0)
        if noteStyle.icon then
            -- One line, sized to its text and centred across the rows, with the
            -- icon as a texture of its own on the text's midline: an inline
            -- |T|t icon sits on the baseline and hangs below a large font.
            f.warning:SetSize(0, 0)
            f.warning:SetPoint("TOP", f.header, "TOPLEFT",
                contentW / 2 + (NOTE_ICON_SIZE + NOTE_ICON_GAP) / 2, -y)
            f.noteIcon:SetTexture(noteStyle.icon)
            f.noteIcon:ClearAllPoints()
            f.noteIcon:SetPoint("RIGHT", f.warning, "LEFT", -NOTE_ICON_GAP, 0)
            f.noteIcon:Show()
            y = y + math.max(NOTE_ICON_SIZE, math.ceil(f.warning:GetStringHeight()))
                + (noteStyle.padBottom or 0)
        else
            f.warning:SetSize(contentW - MARGIN * 2, WARNING_H)
            f.warning:SetPoint("TOPLEFT", f.header, "TOPLEFT", MARGIN, -y)
            y = y + WARNING_H
        end
        f.warning:Show()
    else
        f.warning:Hide()
    end
    return y
end

-- Fit the grids to the panel: the canvas under the title bar is scaled down
-- only when the grids and their scrollbar are wider than the panel, and then
-- stretched back to fill it at that scale. Re-run whenever the panel resizes.
local function FitCanvas(f)
    local width, height = f:GetWidth(), f:GetHeight()
    if not (f.neededW and width and width > 0) then return end
    local scale = math.min(1, width / f.neededW)
    local canvas = f.canvas
    canvas:SetScale(scale)
    canvas:ClearAllPoints()
    canvas:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -BAR_H / scale)
    canvas:SetSize(width / scale, math.max(1, height - BAR_H) / scale)
    -- Centred when there is room to spare.
    local x = math.max(MARGIN, (width / scale - f.neededW) / 2 + MARGIN)
    f.header:ClearAllPoints()
    f.header:SetPoint("TOPLEFT", canvas, "TOPLEFT", x, -f.headerTop)
    f.scroll:ClearAllPoints()
    f.scroll:SetPoint("TOPLEFT", f.header, "BOTTOMLEFT")
    f.scroll:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", x, MARGIN)
    -- The heading above, outside the canvas and so in the panel's own units,
    -- runs exactly as far as the rows: not into the scrollbar's gutter.
    local rowsW = f.neededW - SCROLLBAR_GAP - SCROLLBAR_W - MARGIN * 2
    f.heading:ClearAllPoints()
    f.heading:SetPoint("LEFT", f, "TOPLEFT", x * scale, -BAR_H / 2)
    f.heading:SetPoint("RIGHT", f, "TOPLEFT", (x + rowsW) * scale, -BAR_H / 2)
end

local function SetExpanded(f, contentW)
    f.emptyText:Hide()
    f.neededW = contentW + SCROLLBAR_GAP + SCROLLBAR_W + MARGIN * 2
    f.scroll:SetWidth(contentW + SCROLLBAR_GAP)
    FitCanvas(f)
    f.canvas:Show()
end

local function RenderGrid(f, data)
    local paladins = VisiblePaladins(data)
    local paladinW = K.PaladinColumnsWidth(paladins, COL_W, 3)
    -- Between the role pickers and the first grid: room for the Progress
    -- column in the rows above, plus whatever width the panel has to spare.
    local gap = PROGRESS_ROOM + StretchRoom(f, LEFT_PREFIX_W + PROGRESS_ROOM
        + paladinW * 2 + GRID_GAP + FIX_GAP + FIX_W)
    local leftW = LEFT_PREFIX_W + gap + paladinW
    local rightW = paladinW
    local rightX = leftW + GRID_GAP
    local fixX = rightX + rightW + FIX_GAP
    local contentW = fixX + FIX_W
    local bodyHeight = #data.members * ROW_H
    -- The "your fixes may upset the raid" note is only true in the one case it
    -- describes: PallyPower is the controller of record for this raid and you
    -- hold no board rights, so pushing over it is stepping on someone else's
    -- plan. With WDW as the source, or with edit rights, the fixes ARE the
    -- plan and the warning was just noise.
    local warn = not data.isDemo and PallyPowerMode()
        and not WhoDoesWhat:CanEditAssignments()
    SetExpanded(f, contentW)
    f.content:SetWidth(contentW)

    local gridX = { 0, rightX }
    local gridW = { leftW, rightW }
    local columnStart = { LEFT_PREFIX_W + gap, 0 }
    local plans = { data.current, data.suggested }
    -- In PallyPower mode its board IS the plan, and WDW's is only the better
    -- one on offer.
    local sourceLabels = PallyPowerMode() and { "PallyPower", "Optimized" }
        or { "Current", "Suggested" }

    -- Every paladin gets a row, including any VisiblePaladins left out of the
    -- grids: their progress still counts.
    local headerIconsTop = RenderSummary(f, data.paladins, { columnStart[1], rightX },
        plans, sourceLabels, paladinW, contentW)
    headerIconsTop = PlaceDiffHeading(f, headerIconsTop, contentW,
        warn and FIX_WARNING or nil, WARNING_STYLE, true)
    f.header:SetSize(contentW, headerIconsTop + HEADER_H)

    -- A raider with no role yet only gets the canonical fallback order, so the
    -- "suggested" column is a guess rather than a plan. Show it greyed out and
    -- keep Fix off the table until someone picks a role.
    for _, member in ipairs(data.members) do
        member.topBuffs = TopBuffSet(data, member)
        member.needsRole = NeedsRole(data, member)
    end

    for side = 1, 2 do
        local x = gridX[side]
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
            header.initial:SetText(WhoDoesWhat:NameInitial(paladin.name))
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
                x + columnStart[side], -headerIconsTop)
            headerStripe:SetSize(COL_W, HEADER_H)
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
                local colorHex = member.classInfo and member.classInfo.colorHex or "c0c0c0"
                row.name:SetText("|cff" .. colorHex .. member.displayName .. "|r")

                local picks = row.dropdown and member.classInfo and not member.isPet
                local roleIcon = not picks and ((role and role.icon) or RoleIconFor(member))
                if roleIcon then WhoDoesWhat:SetRoleIconTexture(row.roleIcon, roleIcon) end
                row.roleIcon:SetShown(roleIcon and true or false)
                if picks then
                    row.dropdown:SetShown(true)
                    UIDropDownMenu_SetText(row.dropdown, role and RoleIcon(role)
                        or (roleId and "|cff909090?|r" or "|cff909090--|r"))
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
                cell.needsRole = side == 2 and member.needsRole or nil
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
                cell.icon:SetDesaturated(cell.needsRole == true)
                cell.icon:SetAlpha(cell.needsRole and 0.35 or 1)
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
        button:SetEnabled(not data.isDemo and canFix and not member.needsRole)
        button:Show()
    end
    for index = #data.members + 1, #f.content.fixButtons do
        f.content.fixButtons[index]:Hide()
        f.content.fixButtons[index].member = nil
    end

    UI.SetScrollHeight(f.scroll, bodyHeight)
end

-- Nothing to compare -- PallyPower agrees with the plan, or it's a simulated
-- raid PallyPower can't see -- still shows the Paladin Buffs rows, with one
-- column of the plan WDW is running, and under the Differences heading a line
-- saying why there are no grids.
local function RenderPlan(f, paladins, plan, note, noteStyle)
    local buffsW = SUMMARY_MAX_BUFFS * SUMMARY_SLOT_W + 12
    local buffsX = LEFT_PREFIX_W + PROGRESS_ROOM + StretchRoom(f, LEFT_PREFIX_W
        + PROGRESS_ROOM + buffsW + FIX_GAP + FIX_W)
    local contentW = buffsX + buffsW + FIX_GAP + FIX_W
    SetExpanded(f, contentW)
    f.content:SetWidth(contentW)

    local y = RenderSummary(f, paladins, { buffsX }, { plan }, { "Assigned" },
        buffsW, contentW)
    y = PlaceDiffHeading(f, y, contentW, note, noteStyle, false)
    f.header:SetSize(contentW, y)

    for side = 1, 2 do
        for _, header in ipairs(f.header.headers[side]) do header:Hide() end
        f.headerPaladinStripes[side]:Hide()
        f.bodyPaladinStripes[side]:Hide()
        for _, row in ipairs(f.content.rows[side]) do row:Hide() end
    end
    for _, button in ipairs(f.content.fixButtons) do
        button:Hide()
        button.member = nil
    end
    UI.SetScrollHeight(f.scroll, 0)
end

-- Run once an open dropdown menu closes, for a render it held back.
local function FlushHeldDiffs()
    if diffPanel and diffPanel:IsVisible() then RenderDiffs(diffPanel) end
end

RenderDiffs = function(f)
    -- Every row carries a role dropdown, and hiding or initializing one closes
    -- any menu that is open (HoldRepaintWhileMenuOpen, ViewRefresh.lua).
    if WhoDoesWhat:HoldRepaintWhileMenuOpen("pallyPowerDiff", FlushHeldDiffs) then
        return
    end
    local data
    if f.demoData then
        data = f.demoData
    else
        data = LiveComparisonData()
    end
    f.closeDemoBtn:SetShown(data and data.isDemo or false)
    if not data then
        local paladins = GroupPaladins()
        if #paladins == 0 then
            SetCompact(f)
        elseif WhoDoesWhat:IsFakeRaidEnabled() then
            RenderPlan(f, paladins, A.GetActivePaladinBuffPlan(),
                "Simulated raid: PallyPower can't see these paladins, so there is"
                    .. " nothing to compare.", NOTE_STYLE)
        else
            RenderPlan(f, paladins, A.GetActivePaladinBuffPlan(),
                PallyPowerMode() and "No unoptimized buffs."
                    or "PallyPower matches WDW's plan.", SYNCED_STYLE)
        end
        return false
    end

    RenderGrid(f, data)
    f.diffCount = data.fixableCount or data.diffCount
    f.sendBtn:SetText("Fix All (" .. f.diffCount .. ")")
    f.sendBtn:SetWidth(f.sendBtn:GetTextWidth() + 24)
    if data.isDemo then
        f.sendBtn:Disable()
    else
        f.sendBtn.canFix, f.sendBtn.blockedPaladin =
            WhoDoesWhat:CanFixAllPallyPowerAssignments()
        f.sendBtn.noneFixable = f.diffCount == 0
        f.sendBtn:SetEnabled(f.sendBtn.canFix and not f.sendBtn.noneFixable)
    end
    return true
end

-- Build the panel into the Blessings tab's right-hand frame (MainAssignmentsView):
-- a gold Blessing Assignments heading like the sections beside it, over a canvas
-- holding the paladin rows, the PallyPower Differences heading with Fix All,
-- and the grids -- which stretch across the panel, and FitCanvas scales down
-- when they can't fit. It repaints whenever it comes on screen, and from
-- RefreshBoardViews while it is up.
function WhoDoesWhat:BuildPallyPowerDiffPanel(f)
    local accent = THEME.blessings.accent

    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("TOPRIGHT")
    bar:SetHeight(BAR_H)
    -- Spans the rows under it, not the whole panel; FitCanvas places it.
    local heading = UI.CreateDivider(bar, "Blessing Assignments", accent)
    heading:SetPoint("LEFT", MARGIN, 0)
    heading:SetPoint("RIGHT", -MARGIN, 0)
    f.heading = heading

    local emptyText = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("CENTER", 0, -BAR_H / 2)
    emptyText:Hide()
    f.emptyText = emptyText

    local canvas = CreateFrame("Frame", nil, f)
    f.canvas = canvas
    f.headerTop = MARGIN

    local header = CreateFrame("Frame", nil, canvas)
    local scroll, content = UI.CreateScroll(canvas,
        "WhoDoesWhatPallyPowerDiffScroll", true)
    f.header = header
    f.scroll = scroll
    f.content = content

    local progressTitle = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    progressTitle:SetText("Progress")
    progressTitle:Hide()
    f.progressTitle = progressTitle

    -- Placed by PlaceDiffHeading under the paladin rows.
    f.diffHeading = UI.CreateDivider(header, "PallyPower Differences", accent)

    local sendBtn = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
    sendBtn:SetHeight(22)
    sendBtn:SetPoint("RIGHT", f.diffHeading, "RIGHT", 0, 0)
    sendBtn:SetText("Fix All (0)")
    sendBtn:SetScript("OnClick", function()
        if f.demoData then return end
        StaticPopup_Hide("WHODOESWHAT_FIX_ALL_PALLYPOWER")
        StaticPopup_Show("WHODOESWHAT_FIX_ALL_PALLYPOWER", f.diffCount, nil,
            function()
                if WhoDoesWhat:SyncToPallyPower() then
                    WhoDoesWhat:RefreshMainAssignmentsView()
                end
                RenderDiffs(f)
            end)
    end)
    UI.AddTooltip(sendBtn, function(self)
        GameTooltip:SetText("Fix all PallyPower assignments", unpack(UI.TOOLTIP_TITLE))
        if f.demoData then
            GameTooltip:AddLine("Disabled for view-only demo data.", 0.8, 0.8, 0.8, true)
        elseif self.noneFixable then
            GameTooltip:AddLine("Every remaining difference is for a raider with"
                .. " no role yet.", 1, 0.82, 0, true)
            GameTooltip:AddLine("Give them roles and their rows become fixable.",
                0.8, 0.8, 0.8, true)
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
        return true
    end)
    f.sendBtn = sendBtn

    -- Demo data (/wdw ppdifftest) replaces the live comparison until closed.
    local closeDemoBtn = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
    closeDemoBtn:SetSize(80, 22)
    closeDemoBtn:SetPoint("RIGHT", sendBtn, "LEFT", -4, 0)
    closeDemoBtn:SetText("End Demo")
    closeDemoBtn:SetScript("OnClick", function()
        f.demoData = nil
        RenderDiffs(f)
    end)
    closeDemoBtn:Hide()
    f.closeDemoBtn = closeDemoBtn

    -- The line under the Differences heading: the fix warning, or why there
    -- are no grids.
    local warning = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    warning:SetHeight(WARNING_H)
    warning:SetJustifyH("CENTER")
    warning:SetJustifyV("TOP")
    warning:Hide()
    f.warning = warning
    local noteIcon = header:CreateTexture(nil, "OVERLAY")
    noteIcon:SetSize(NOTE_ICON_SIZE, NOTE_ICON_SIZE)
    noteIcon:Hide()
    f.noteIcon = noteIcon

    header.headers = { {}, {} }
    content.rows = { {}, {} }
    content.fixButtons = {}
    f.summaryRows = {}
    f.gridTitles = {}
    f.headerPaladinStripes = {}
    f.bodyPaladinStripes = {}
    for side = 1, 2 do
        local gridTitle = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        gridTitle:Hide()
        f.gridTitles[side] = gridTitle
        f.headerPaladinStripes[side] = K.CreateLocalPaladinStripe(header)
        f.bodyPaladinStripes[side] = K.CreateLocalPaladinStripe(content)
    end

    -- A shadow along the bottom, as the Settings wells have, over everything
    -- the canvas draws.
    local level = scroll:GetFrameLevel() + 20
    bar:SetFrameLevel(level)
    local bottomEdge = UI.CreateEdgeShadow(f, level, false)
    bottomEdge:SetPoint("BOTTOMLEFT")
    bottomEdge:SetPoint("BOTTOMRIGHT")
    UI.InsetScrollBar(scroll, 4)

    -- The stretch is worked out at paint time, so a new size repaints.
    f:SetScript("OnSizeChanged", function(self)
        if self:IsVisible() then RenderDiffs(self) else FitCanvas(self) end
    end)
    f:SetScript("OnShow", RenderDiffs)

    WhoDoesWhat:LogUiBuilding("Building PallyPower diff grids.")
    diffPanel = f
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

-- Open the main window on the Blessings tab, where the differences sit.
function WhoDoesWhat:OpenPallyPowerDiffView()
    self:LogUiBuilding("Opening PallyPower Differences...")
    self:ShowMainTab("blessings", true)
end

function WhoDoesWhat:OpenPallyPowerDiffTestView()
    self:ShowMainTab("blessings", true)
    diffPanel.demoData = DummyData()
    ValidateDummyData(diffPanel.demoData)
    RenderDiffs(diffPanel)
    self:LogUiBuilding("Opening PallyPower Differences test data...")
end

-- Repainted from RefreshBoardViews, the addon's "board changed" hook, so the
-- panel tracks PallyPower traffic, role changes, buffing rules and talent
-- arrivals while it is on screen. Off screen it catches up when it is shown.
function WhoDoesWhat:RefreshPallyPowerDiffView()
    if diffPanel and diffPanel:IsVisible() and not diffPanel.demoData then
        RenderDiffs(diffPanel)
    end
end
