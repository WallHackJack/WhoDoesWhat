local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- "Group Roles" window: players whose Blizzard group role (Tank / Healer /
-- Damage Dealer) disagrees with their WhoDoesWhat role, plus WDW tanks who
-- haven't been promoted to Main Tank. Opened by hand from the main window's
-- toolbar -- nothing here pops up on its own.
--
-- Fixes run in the direction the automatic paths DON'T: Blizzard's flag is
-- treated as the truth and adopted into WDW as a guessed spec. That is the
-- useful direction when someone set their role in Blizzard's own UI or another
-- addon, because the reverse (board -> flag) is what ReconcileBlizzardRoles
-- already does unprompted.
--
-- What is deliberately NOT a mismatch: a player with no WDW role at all. Every
-- unscanned raider arrives on Blizzard's default DAMAGER flag, and listing the
-- whole roster as "mismatched" the second they zone in would bury the handful
-- of rows that mean something. They get a role from the talent scan or from
-- the leader, and only then can they disagree with anything.
--
-- The model lives at the top of this file rather than in Assignments.lua: it is
-- a few lines of comparison used by nothing else, and splitting it would cost
-- more than it explains.

local K = WhoDoesWhat.SectionKit

local mismatchFrame = nil
local RenderRows

local FRAME_W = 620
local FRAME_MAX_H = 460
local FRAME_MIN_H = 170
local MARGIN = 10
local BOTTOM_STRIP = 32
local TITLE_H = 22
local HEADER_H = 24
local ROW_H = 26
local SCROLLBAR_W = 26
local ROLE_ICON_SIZE = 16

local NAME_COL_W = 118
local BLIZZ_COL_W = 96
local WDW_COL_W = 104
local FLAG_COL_W = 24          -- the header-less main-tank column
local FIX_W = 44
local DD_W = 150

-- ---------------------------------------------------------------------------
-- Model
-- ---------------------------------------------------------------------------

local BLIZZ_TO_WOW = { TANK = "tank", HEALER = "healer", DAMAGER = "dps" }

-- Which spec to offer when adopting a Blizzard role into WDW. The class's own
-- role list already yields the common answer for almost everything -- its first
-- entry matching the group role is Beast Mastery, Combat, Protection, Feral
-- Tank, Restoration and so on. PREFERRED_GUESS only overrides where the list
-- order disagrees with what people actually mean; add to it rather than
-- reordering Data.lua, which drives menus everywhere else.
local PREFERRED_GUESS = {
    PRIEST_healer = "priest_holy", -- list order would offer Discipline first
}

local function GuessRoleId(classInfo, wowRole)
    if not (classInfo and wowRole) then return nil end
    local preferred = PREFERRED_GUESS[classInfo.name:upper() .. "_" .. wowRole]
    if preferred then
        for _, role in ipairs(classInfo.roles) do
            if role.id == preferred then return role.id end
        end
    end
    for _, role in ipairs(classInfo.roles) do
        if role.wowRole == wowRole then return role.id end
    end
    return nil
end

local function ClassInfoForUnit(unit)
    local _, englishClass = UnitClass(unit)
    if not englishClass then return nil end
    for _, classInfo in ipairs(WhoDoesWhat.Classes) do
        if classInfo.name:upper() == englishClass then return classInfo end
    end
    return nil
end

-- Every row the window should show, roster order. See the header for why a
-- player with no WDW role is never a mismatch.
function WhoDoesWhat:GetRoleMismatches()
    local rows = {}
    if not (self.db and UnitGroupRolesAssigned) then return rows end
    local inRaid = IsInRaid()

    local units = {}
    if inRaid then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    else
        units[1] = "player"
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end

    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local name, realm = UnitName(unit)
            local key = (realm and realm ~= "") and (name .. "-" .. realm) or name
            local classInfo = ClassInfoForUnit(unit)
            local roleId = key and self.db.profile.assignments[key]
            local _, role = nil, nil
            if roleId then _, role = self:FindRoleById(roleId) end

            local blizzRole = UnitGroupRolesAssigned(unit)
            if blizzRole == "NONE" then blizzRole = nil end
            local wanted = role and role.wowRole or nil

            -- A disagreement needs a real value on BOTH sides. No WDW role, no
            -- group role, or a role that carries no group role at all (Non-raider,
            -- a legacy custom role) means there is nothing to compare.
            local mismatched = (wanted and blizzRole
                and BLIZZ_TO_WOW[blizzRole] ~= wanted) and true or false

            local needsPromote = (inRaid and wanted == "tank"
                and not GetPartyAssignment("MAINTANK", key, true)) and true or false

            if classInfo and (mismatched or needsPromote) then
                local suggested = mismatched
                    and GuessRoleId(classInfo, BLIZZ_TO_WOW[blizzRole]) or nil
                rows[#rows + 1] = {
                    name = key,
                    unit = unit,
                    classInfo = classInfo,
                    blizzRole = blizzRole,
                    roleId = roleId,
                    role = role,
                    mismatched = mismatched,
                    needsPromote = needsPromote,
                    suggestedId = suggested,
                    -- What Fix will apply; the dropdown overwrites it.
                    selectedId = suggested,
                }
            end
        end
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- View
-- ---------------------------------------------------------------------------

local function BlizzRoleText(blizzRole)
    if not blizzRole then return "|cff909090none|r" end
    local wowRole = BLIZZ_TO_WOW[blizzRole]
    local meta = wowRole and WhoDoesWhat.BasicWowRoles[wowRole]
    if not meta then return "|cff909090none|r" end
    return WhoDoesWhat:GetWowRoleIconMarkup(wowRole, 14) .. " " .. meta.name
end

local function RoleText(role, classInfo)
    if not role then return "|cff909090none|r" end
    return "|T" .. role.icon .. ":14:14:0:0|t |cff"
        .. (classInfo and classInfo.colorHex or "ffffff") .. role.name .. "|r"
end

-- Your own role is always yours, permissions or not (Permissions.lua), so an
-- unpermitted raider still gets a working button on their own row rather than
-- a greyed one they can't explain.
local function CanAct(playerName)
    if InCombatLockdown() then return false end
    if playerName and playerName == UnitName("player") then return true end
    return WhoDoesWhat:CanEditAssignments()
end

-- A row can only be fixed from here when there is a role to adopt. A row that
-- is ONLY an unpromoted main tank has no button: promoting is protected, so
-- there is no action this addon could perform on the user's behalf.
local function RowFixable(data)
    return data.mismatched and data.selectedId ~= nil
end

local function CreateRow(content, index)
    local row = CreateFrame("Frame", nil, content)
    row:SetHeight(ROW_H)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    row.bg = bg

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", 6, 0)
    name:SetWidth(NAME_COL_W - 10)
    name:SetJustifyH("LEFT")
    row.name = name

    local blizz = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    blizz:SetPoint("LEFT", row, "LEFT", NAME_COL_W, 0)
    blizz:SetWidth(BLIZZ_COL_W)
    blizz:SetJustifyH("LEFT")
    row.blizz = blizz

    local wdw = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    wdw:SetPoint("LEFT", row, "LEFT", NAME_COL_W + BLIZZ_COL_W, 0)
    wdw:SetWidth(WDW_COL_W)
    wdw:SetJustifyH("LEFT")
    row.wdw = wdw

    -- Header-less column: the X marker for a tank who hasn't been promoted.
    local flag = CreateFrame("Button", nil, row)
    flag:SetSize(FLAG_COL_W - 6, FLAG_COL_W - 6)
    flag:SetPoint("LEFT", row, "LEFT", NAME_COL_W + BLIZZ_COL_W + WDW_COL_W, 0)
    local flagTex = flag:CreateTexture(nil, "ARTWORK")
    flagTex:SetAllPoints()
    flagTex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_7")
    flag:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Not promoted to Main Tank", 1, 1, 1)
        GameTooltip:AddLine("This player holds a tank role in WhoDoesWhat but "
            .. "isn't the raid's Main Tank.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Promoting is a protected action an addon can't "
            .. "perform. Open the Raid tab and WhoDoesWhat will point at their "
            .. "row.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    flag:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.flag = flag

    local fix = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    fix:SetSize(FIX_W, ROW_H - 6)
    fix:SetPoint("RIGHT", -6, 0)
    fix:SetText("Fix")
    fix:SetMotionScriptsWhileDisabled(true)
    fix:SetScript("OnClick", function()
        local data = row.data
        if not (data and RowFixable(data)) then return end
        WhoDoesWhat:SetAssignedRole(data.name, data.selectedId)
        RenderRows(row.ownerFrame)
    end)
    fix:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Fix role", 1, 1, 1)
        if self.blockedReason then
            GameTooltip:AddLine(self.blockedReason, 1, 0.4, 0.4, true)
        else
            GameTooltip:AddLine("Set this player's WhoDoesWhat role to the spec "
                .. "shown, matching their Blizzard group role.", 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    fix:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.fix = fix

    local dropdown = CreateFrame("Frame", "WhoDoesWhatRoleMismatchDD" .. index,
        row, "UIDropDownMenuTemplate")
    dropdown:SetPoint("RIGHT", fix, "LEFT", 6, -2)
    UIDropDownMenu_SetWidth(dropdown, DD_W - 24)
    K.LeftAlignDropdown(dropdown)
    UIDropDownMenu_Initialize(dropdown, function(_, level)
        local data = row.data
        if not (data and data.classInfo) then return end
        local function AddRole(role, classInfo)
            local info = UIDropDownMenu_CreateInfo()
            info.text = RoleText(role, classInfo)
            info.checked = data.selectedId == role.id
            info.func = function()
                data.selectedId = role.id
                UIDropDownMenu_SetSelectedValue(dropdown, role.id)
                UIDropDownMenu_SetText(dropdown, RoleText(role, classInfo))
                RenderRows(row.ownerFrame)
            end
            UIDropDownMenu_AddButton(info, level)
        end
        for _, role in ipairs(data.classInfo.roles) do
            AddRole(role, data.classInfo)
        end
        for _, role in ipairs(data.classInfo.customRoles or {}) do
            AddRole(role, data.classInfo)
        end
    end)
    row.dropdown = dropdown

    content.rows[index] = row
    return row
end

local function LayoutRow(row, data, index, ownerFrame)
    row.data = data
    row.ownerFrame = ownerFrame

    row.name:SetText("|cff" .. data.classInfo.colorHex
        .. (data.name:match("^[^-]+") or data.name) .. "|r")
    row.blizz:SetText(BlizzRoleText(data.blizzRole))
    row.wdw:SetText(RoleText(data.role, data.classInfo))
    row.flag:SetShown(data.needsPromote)

    -- Alternating fill, matching the section rows in the main window.
    if index % 2 == 0 then
        row.bg:SetColorTexture(1, 1, 1, 0.04)
    else
        row.bg:SetColorTexture(0, 0, 0, 0)
    end

    local fixable = RowFixable(data)
    row.dropdown:SetShown(fixable)
    row.fix:SetShown(fixable)
    if fixable then
        local _, role = WhoDoesWhat:FindRoleById(data.selectedId)
        UIDropDownMenu_SetSelectedValue(row.dropdown, data.selectedId)
        UIDropDownMenu_SetText(row.dropdown, RoleText(role, data.classInfo))
        local allowed = CanAct(data.name)
        row.fix:SetEnabled(allowed)
        row.fix.blockedReason = (not allowed)
            and (InCombatLockdown() and "Can't change roles in combat."
                or "You don't have permission to edit assignments.")
            or nil
    end
    row:Show()
end

RenderRows = function(f)
    local rows = WhoDoesWhat:GetRoleMismatches()
    local content = f.content

    for i, data in ipairs(rows) do
        local row = content.rows[i] or CreateRow(content, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((i - 1) * ROW_H))
        row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        LayoutRow(row, data, i, f)
    end
    for i = #rows + 1, #content.rows do content.rows[i]:Hide() end

    local fixable = 0
    for _, data in ipairs(rows) do
        if RowFixable(data) and CanAct(data.name) then fixable = fixable + 1 end
    end
    f.fixAllBtn:SetText("Fix All (" .. fixable .. ")")
    f.fixAllBtn:SetEnabled(fixable > 0)
    f.fixAllRows = rows

    f.emptyText:SetShown(#rows == 0)
    content:SetHeight(math.max(1, #rows * ROW_H))

    local desired = f.titleBarHeight + TITLE_H + HEADER_H + #rows * ROW_H
        + BOTTOM_STRIP + MARGIN * 2
    f:SetHeight(math.max(FRAME_MIN_H, math.min(desired, FRAME_MAX_H)))
    return #rows > 0
end

local function EnsureFrame()
    if mismatchFrame then return mismatchFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatRoleMismatchFrame",
        FRAME_W, FRAME_MIN_H, "Group Roles")
    f.titleText:ClearAllPoints()
    f.titleText:SetPoint("CENTER", f, "TOP", 0, -(f.titleBarHeight / 2 + 5))

    local top = f.titleBarHeight + 8

    local intro = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", MARGIN, -top)
    intro:SetPoint("TOPRIGHT", -MARGIN, -top)
    intro:SetJustifyH("LEFT")
    intro:SetText("|cff909090Blizzard group roles that don't match "
        .. "WhoDoesWhat. Fix adopts the Blizzard role, guessing a spec.|r")

    local headerY = top + TITLE_H
    local function Header(text, x, w)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", MARGIN + x, -headerY)
        fs:SetWidth(w)
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        return fs
    end
    Header("Player", 0, NAME_COL_W)
    Header("Blizzard", NAME_COL_W, BLIZZ_COL_W)
    Header("WhoDoesWhat", NAME_COL_W + BLIZZ_COL_W, WDW_COL_W)
    -- The main-tank column is deliberately header-less: it's a flag, not data.

    local scroll = CreateFrame("ScrollFrame", "WhoDoesWhatRoleMismatchScroll", f,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", MARGIN, -(headerY + HEADER_H))
    scroll:SetPoint("BOTTOMRIGHT", -(MARGIN + SCROLLBAR_W), MARGIN + BOTTOM_STRIP)
    scroll.scrollBarHideable = 1

    local content = CreateFrame("Frame", nil, scroll)
    content:SetPoint("TOPLEFT")
    content:SetWidth(FRAME_W - MARGIN * 2 - SCROLLBAR_W)
    content.rows = {}
    scroll:SetScrollChild(content)
    f.content = content

    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    empty:SetPoint("CENTER", scroll, "CENTER", 0, 0)
    empty:SetText("|cff909090Everyone's group role matches their "
        .. "WhoDoesWhat role.|r")
    f.emptyText = empty

    local fixAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    fixAll:SetSize(110, 22)
    fixAll:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN)
    fixAll:SetText("Fix All (0)")
    fixAll:SetMotionScriptsWhileDisabled(true)
    fixAll:SetScript("OnClick", function()
        for _, data in ipairs(f.fixAllRows or {}) do
            if RowFixable(data) and CanAct(data.name) then
                WhoDoesWhat:SetAssignedRole(data.name, data.selectedId)
            end
        end
        RenderRows(f)
    end)
    fixAll:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Fix all roles", 1, 1, 1)
        GameTooltip:AddLine("Apply every row's spec. Unpromoted main tanks are "
            .. "not included -- promoting is the leader's to do by hand.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    fixAll:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.fixAllBtn = fixAll

    local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refresh:SetSize(80, 22)
    refresh:SetPoint("RIGHT", fixAll, "LEFT", -6, 0)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", function() RenderRows(f) end)

    -- Roles move under the window while it's open (talent scans, other clients'
    -- edits, promotions), so track the same events the other roster views do.
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:SetScript("OnEvent", function(self)
        if self:IsShown() then RenderRows(self) end
    end)

    mismatchFrame = f
    return f
end

function WhoDoesWhat:RefreshRoleMismatchView()
    if mismatchFrame and mismatchFrame:IsShown() then RenderRows(mismatchFrame) end
end

function WhoDoesWhat:OpenRoleMismatchView()
    local f = EnsureFrame()
    if f:IsShown() then
        f:Hide()
        return
    end
    RenderRows(f)
    self:LogUiBuilding("Opening Group Roles...")
    f:Show()
    f:Raise()
end
