local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local K = WhoDoesWhat.SectionKit

-- Raider Roles window ("Raider Roles" button on the main view): every group
-- member in one of four role grids, bucketed by their assigned role's
-- tank/healer/dps classification and sorted by class then name. Each row
-- carries the same role dropdown the unit right-click menu offers, WDW
-- presence, plus the (!) alert while the player has no usable role.
--
-- The "No Role" bucket also collects players whose role has no tank/healer/
-- dps classification (custom roles left unclassified); only players with no
-- role at all get the (!). Talent auto-detection (Talents.lua) fills most
-- rows on its own as data arrives, so this page is mainly for reviewing and
-- correcting.

local rolesFrame = nil

local FRAME_W = 460
local FRAME_H = 560
local MARGIN = 12
local SCROLLBAR_W = 26
local CONTENT_W = FRAME_W - MARGIN * 2 - SCROLLBAR_W

local GRID_GAP = 10
local GRID_HEADER_H = 26
local ROW_H = 30
local EMPTY_H = 20 -- rows-area height for an empty bucket's hint line
local DROPDOWN_WIDTH = 130
local ADDON_COL_W = 38
local WARNING_ICON_SIZE = 18
local CLASS_ICON_SIZE = 20
local READY_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"
local NOT_READY_ICON = "Interface\\RaidFrame\\ReadyCheck-NotReady"

local SECTIONS = {
    { key = "tank",   title = "Tanks",   empty = "No tanks assigned yet." },
    { key = "healer", title = "Healers", empty = "No healers assigned yet." },
    { key = "dps",    title = "DPS",     empty = "No DPS assigned yet." },
    { key = "none",   title = "No Role", empty = "Everyone has a role." },
}

-- Stable player key for a unit: "Name" same-realm, "Name-Realm" foreign.
-- Matches the keying used by db.profile.assignments (UnitMenuExtensions.lua).
local function GetUnitKey(unit)
    local name, realm = UnitName(unit)
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

-- The unit token for a group member's name, so SetAssignedRole can sync the
-- blizzard role flag like the unit menu does. Nil once they can't be resolved
-- (the assignment itself still saves fine without it).
local function UnitForName(name)
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            if GetUnitKey("raid" .. i) == name then return "raid" .. i end
        end
        return nil
    end
    if GetUnitKey("player") == name then return "player" end
    for i = 1, GetNumSubgroupMembers() do
        if GetUnitKey("party" .. i) == name then return "party" .. i end
    end
    return nil
end

-- Same permission rule as the unit menu's CanAssignRoleTo: other people's
-- roles take board edit permission (Permissions.lua); your own is always
-- yours.
local function CanAssign(name)
    return WhoDoesWhat:CanEditRoleOf(name)
end

-- Dropdown row / collapsed text for a role: spec icon + class-colored name.
local function RoleText(role, classInfo)
    return WhoDoesWhat:RoleIconMarkup(role.icon, 14) .. " |cff"
        .. classInfo.colorHex .. role.name .. "|r"
end

-- The player's assigned role entry, plus the raw id. role is nil both when
-- nothing is assigned and when the id no longer resolves (deleted custom
-- role) -- either way the row needs attention, so both show the (!).
local function AssignedRole(name)
    local roleId = WhoDoesWhat:GetAssignedRole(name)
    if not roleId then return nil, nil end
    local _, role = WhoDoesWhat:FindRoleById(roleId)
    return role, roleId
end

-- Group members split into the four buckets, each sorted class > role > name.
local function BucketedMembers()
    local buckets = { tank = {}, healer = {}, dps = {}, none = {} }
    for _, m in ipairs(WhoDoesWhat:GetGroupMembers(nil)) do
        local role = AssignedRole(m.name)
        local bucket = role and role.wowRole or "none" -- wowRole=false lands here too
        local list = buckets[bucket] or buckets.none
        list[#list + 1] = m
    end
    for _, list in pairs(buckets) do
        table.sort(list, function(a, b)
            if a.classInfo.name ~= b.classInfo.name then
                return a.classInfo.name < b.classInfo.name
            end
            -- Within a class, group by assigned role (specs clump together).
            local ra, rb = WhoDoesWhat:RoleSortRank(a.name), WhoDoesWhat:RoleSortRank(b.name)
            if ra ~= rb then return ra < rb end
            return a.name < b.name
        end)
    end
    return buckets
end

-- Warning (!) icon with a hover tooltip; same pattern as the main view's.
local function CreateWarningIcon(row)
    local warn = CreateFrame("Frame", nil, row)
    warn:SetSize(WARNING_ICON_SIZE, WARNING_ICON_SIZE)
    local tex = warn:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture(WhoDoesWhat.WARNING_ICON)
    warn:EnableMouse(true)
    warn:SetScript("OnEnter", function(self)
        if self.tooltipText then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Warning", 1, 0.82, 0)
            GameTooltip:AddLine(self.tooltipText, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    warn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    warn:Hide()
    return warn
end

local RefreshRoster -- forward declared; row callbacks repaint through it

-- A repaint rebuckets everyone, so a role landing anywhere grows one grid and
-- shrinks another -- and both ends of that close every open dropdown. Hiding a
-- surplus row hides the dropdown frame inside it, and UIDropDownMenuTemplate's
-- OnHide is a global CloseDropDownMenus(); CreateRow's UIDropDownMenu_Initialize
-- hides every menu level outright. Neither cares which row you had open.
--
-- Mid-raid the repaint triggers never stop -- talent detection alone fires once
-- per player as inspect data lands (Talents.lua), which is exactly the stretch
-- where you're here fixing the stragglers -- so menus were being yanked shut
-- before they could be clicked. Hold repaints while a menu is up and flush once
-- it closes.
local pendingRepaint = false

local function MenuIsOpen()
    return DropDownList1 and DropDownList1:IsShown()
end

-- Build pooled row #index inside a role grid. The position is fixed;
-- RefreshRoster maps a member onto it (row.member) and hides surplus rows, so
-- the dropdown reads row.member at open time.
local function CreateRow(f, section, index)
    local state = f.sections[section.key]
    local box = state.box

    local row = CreateFrame("Frame", nil, box)
    row:SetFrameLevel(box:GetFrameLevel() + 1)
    row:SetSize(box:GetWidth(), ROW_H)
    row:SetPoint("TOPLEFT", 0, -(GRID_HEADER_H + (index - 1) * ROW_H))

    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    row.stripe = stripe

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(CLASS_ICON_SIZE, CLASS_ICON_SIZE)
    icon:SetPoint("LEFT", 4, 0)
    row.classIcon = icon

    local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameFS:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    nameFS:SetJustifyH("LEFT")
    row.nameFS = nameFS

    local nameHover = CreateFrame("Frame", nil, row)
    nameHover:SetHeight(ROW_H)
    nameHover:SetPoint("LEFT", 4, 0)
    nameHover:EnableMouse(true)
    nameHover:SetScript("OnEnter", function(self)
        WhoDoesWhat:ShowRaiderTooltip(self, self.memberName)
    end)
    nameHover:SetScript("OnLeave", function() WhoDoesWhat:HideRaiderTooltip() end)
    row.nameHover = nameHover

    -- UIDropDownMenu carries ~15px of transparent padding each side; overhang
    -- the row edge so the visible box lands flush right (same trick as the
    -- main view's rows).
    local dropdown = CreateFrame("Frame",
        "WhoDoesWhatRaiderRoleDD_" .. section.key .. index, row, "UIDropDownMenuTemplate")
    dropdown:SetPoint("RIGHT", row, "RIGHT", 14, -2)
    UIDropDownMenu_SetWidth(dropdown, DROPDOWN_WIDTH)
    K.LeftAlignDropdown(dropdown)
    UIDropDownMenu_Initialize(dropdown, function(_, level)
        local m = row.member
        if not m then return end
        local saved = WhoDoesWhat:GetAssignedRole(m.name)

        local function AddRole(role)
            local info = UIDropDownMenu_CreateInfo()
            info.text = RoleText(role, m.classInfo)
            info.checked = (saved == role.id)
            info.func = function()
                -- SetAssignedRole repaints this view (and the main one).
                WhoDoesWhat:SetAssignedRole(m.name, role.id, UnitForName(m.name))
            end
            UIDropDownMenu_AddButton(info, level)
        end
        for _, role in ipairs(m.classInfo.roles) do
            AddRole(role)
        end
        for _, role in ipairs(m.classInfo.customRoles or {}) do
            AddRole(role)
        end

        -- Non-raider (the classless "sitting out" pseudo-role), below a
        -- divider like the unit menu -- it isn't one of the class's specs.
        if UIDropDownMenu_AddSeparator then
            UIDropDownMenu_AddSeparator(level)
        end
        local nr = WhoDoesWhat.NonRaiderRole
        local nrInfo = UIDropDownMenu_CreateInfo()
        nrInfo.text = RoleText(nr, WhoDoesWhat.NonRaiderClass)
        nrInfo.checked = (saved == nr.id)
        nrInfo.func = function()
            WhoDoesWhat:SetAssignedRole(m.name, nr.id, UnitForName(m.name))
        end
        UIDropDownMenu_AddButton(nrInfo, level)

        -- "None" matches the unit menu: a passive read-out of the roleless
        -- state, shown only while the player has no role and never clickable.
        -- Once assigned, the way to change is to pick another role -- neither
        -- panel un-assigns a role back to roleless.
        if saved == nil then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "None"
            info.checked = true
            info.disabled = true
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    row.dropdown = dropdown

    local addonStatus = CreateFrame("Frame", nil, row)
    addonStatus:SetSize(ADDON_COL_W, ROW_H)
    addonStatus:SetPoint("RIGHT", row, "RIGHT", -(DROPDOWN_WIDTH + 33), 0)
    local addonIcon = addonStatus:CreateTexture(nil, "OVERLAY")
    addonIcon:SetSize(16, 16)
    addonIcon:SetPoint("CENTER")
    row.addonIcon = addonIcon

    local warn = CreateWarningIcon(row)
    warn:SetPoint("RIGHT", addonStatus, "LEFT", -2, 2)
    row.warnIcon = warn

    nameFS:SetPoint("RIGHT", warn, "LEFT", -4, 0)

    state.rows[index] = row
    return row
end

-- Recompute the scroll child's height from the stacked grids.
local function UpdateContentHeight(f)
    local h = 0
    for _, section in ipairs(SECTIONS) do
        h = h + f.sections[section.key].box:GetHeight() + GRID_GAP
    end
    f.content:SetHeight(math.max(h, 1))
    f.scroll:UpdateScrollChildRect()
end

-- Map the current group onto the pooled rows, retitle each grid with its
-- count, and resize everything. The grids are anchor-chained, so height
-- changes ripple down on their own.
function RefreshRoster(f)
    if MenuIsOpen() then
        pendingRepaint = true
        return
    end
    pendingRepaint = false

    local buckets = BucketedMembers()
    for _, section in ipairs(SECTIONS) do
        local state = f.sections[section.key]
        local members = buckets[section.key]

        state.title:SetText(section.title .. " (" .. #members .. ")")

        for i, m in ipairs(members) do
            local row = state.rows[i] or CreateRow(f, section, i)
            row.member = m
            row:Show()

            local role, roleId = AssignedRole(m.name)
            local unit = UnitForName(m.name)
            local connected = m.isFake
                or (unit and UnitIsConnected(unit) ~= false) or false
            local rowColors = connected and m.classInfo.gridRowColors
                or WhoDoesWhat.DisconnectedGridRowColors
            local rowColor = rowColors[i % 2 == 1 and 1 or 2]
            row.stripe:SetColorTexture(rowColor.r, rowColor.g, rowColor.b, rowColor.a)
            -- Role's spec icon when we have one; the class icon is the fallback
            -- for roleless / unresolved-role members.
            WhoDoesWhat:SetRoleIconTexture(row.classIcon,
                (role and role.icon) or m.classInfo.classIcon)
            row.classIcon:SetDesaturated(not connected)
            row.nameFS:SetText("|cff" .. (connected and m.classInfo.colorHex or "909090")
                .. m.name .. "|r")
            row.nameHover.memberName = m.name
            row.nameHover:SetWidth(CLASS_ICON_SIZE + 8 + row.nameFS:GetStringWidth())
            local installed = m.name == UnitName("player")
                or WhoDoesWhat.syncPeers[m.name] == true
            row.addonIcon:SetTexture(not connected and WhoDoesWhat.WARNING_ICON
                or (installed and READY_ICON or NOT_READY_ICON))
            row.addonIcon:SetSize(not connected and WARNING_ICON_SIZE or 16,
                not connected and WARNING_ICON_SIZE or (installed and 13 or 16))

            if role then
                UIDropDownMenu_SetText(row.dropdown, RoleText(role, m.classInfo))
            elseif roleId then
                -- An id that no longer resolves (deleted custom role): show
                -- honest confusion rather than pretending it's unassigned.
                UIDropDownMenu_SetText(row.dropdown, "|cff909090?|r")
            else
                UIDropDownMenu_SetText(row.dropdown, "|cff909090None|r")
            end

            if CanAssign(m.name) then
                UIDropDownMenu_EnableDropDown(row.dropdown)
            else
                UIDropDownMenu_DisableDropDown(row.dropdown)
            end
            row.dropdown:SetAlpha(connected and 1 or 0.55)

            row.warnIcon.tooltipText = roleId
                and (m.name .. "'s saved role no longer exists. Pick a new one.")
                or (m.name .. " has no role yet. Pick one here, or wait for"
                    .. " talent data to fill it in automatically.")
            row.warnIcon:SetShown(role == nil)
        end
        for i = #members + 1, #state.rows do
            state.rows[i]:Hide()
            state.rows[i].member = nil
            state.rows[i].nameHover.memberName = nil
        end
        state.emptyHint:SetShown(#members == 0)

        local rowsH = (#members > 0) and (#members * ROW_H) or EMPTY_H
        state.box:SetHeight(GRID_HEADER_H + rowsH)
    end
    UpdateContentHeight(f)
end

-- Build the window once and reuse it: shared chrome, a scroll column, and the
-- four role grids (rows come from RefreshRoster).
local function EnsureRolesFrame()
    if rolesFrame then return rolesFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatRaiderRolesFrame",
        FRAME_W, FRAME_H, "WhoDoesWhat - Raider Roles")

    local scroll = CreateFrame("ScrollFrame", "WhoDoesWhatRaiderRolesScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + 10))
    scroll:SetPoint("BOTTOMRIGHT", -(MARGIN + SCROLLBAR_W), MARGIN)

    local content = CreateFrame("Frame", nil, scroll)
    -- Pin the scroll child explicitly or nothing renders until the window
    -- moves (same fix as the main view).
    content:SetPoint("TOPLEFT")
    content:SetWidth(CONTENT_W)
    scroll:SetScrollChild(content)
    f.content = content
    f.scroll = scroll

    WhoDoesWhat:LogUiBuilding("Building raider roles content.")

    f.sections = {}
    local prevBox
    for _, section in ipairs(SECTIONS) do
        local box = CreateFrame("Frame", nil, content)
        box:SetFrameLevel(content:GetFrameLevel() + 1)
        box:SetWidth(CONTENT_W)
        if prevBox then
            box:SetPoint("TOPLEFT", prevBox, "BOTTOMLEFT", 0, -GRID_GAP)
        else
            box:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        end
        prevBox = box

        local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 4, -4)
        title:SetText(section.title)

        local addonTitle = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        addonTitle:SetWidth(ADDON_COL_W)
        addonTitle:SetPoint("TOPRIGHT", box, "TOPRIGHT",
            -(DROPDOWN_WIDTH + 33), -5)
        addonTitle:SetJustifyH("CENTER")
        addonTitle:SetText("WDW")

        local roleTitle = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        roleTitle:SetWidth(DROPDOWN_WIDTH)
        roleTitle:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -5)
        roleTitle:SetJustifyH("LEFT")
        roleTitle:SetText("Role")

        local line = box:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(0.4, 0.4, 0.4, 0.6)
        line:SetHeight(1)
        line:SetPoint("TOPLEFT", 0, -25)
        line:SetPoint("TOPRIGHT", 0, -25)

        local hint = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOPLEFT", 4, -(GRID_HEADER_H + 4))
        hint:SetTextColor(0.55, 0.55, 0.55)
        hint:SetText(section.empty)

        f.sections[section.key] = { box = box, title = title, emptyHint = hint, rows = {} }
    end

    -- Track joins/leaves live while the window is open.
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:RegisterEvent("UNIT_CONNECTION")
    f:SetScript("OnEvent", function(self)
        if self:IsShown() then
            RefreshRoster(self)
        end
    end)

    -- Flush whatever the open menu held back. A selection made here doesn't
    -- come through this path: Blizzard hides the list before running the
    -- clicked button's func, so SetAssignedRole's repaint arrives with nothing
    -- open and paints straight away.
    if DropDownList1 then
        DropDownList1:HookScript("OnHide", function()
            if not pendingRepaint then return end
            pendingRepaint = false
            if rolesFrame and rolesFrame:IsShown() then
                RefreshRoster(rolesFrame)
            end
        end)
    end

    rolesFrame = f
    return f
end

-- Repaint if the window is up. Called from outside the view when assignments
-- change (SetAssignedRole in UnitMenuExtensions.lua, talent auto-detection).
function WhoDoesWhat:RefreshRaiderRolesView()
    if rolesFrame and rolesFrame:IsShown() then
        RefreshRoster(rolesFrame)
    end
end

-- Toggle the raider roles window open/closed.
function WhoDoesWhat:OpenRaiderRolesView()
    local f = EnsureRolesFrame()

    if f:IsShown() then
        self:LogUiBuilding("Raider Roles View open, closing it.")
        f:Hide()
        return
    end

    self:LogUiBuilding("Opening Raider Roles View...")
    RefreshRoster(f)
    f:Show()
    f:Raise()
end
