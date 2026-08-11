local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

local customizeFrame = nil

local FRAME_W = 250
local FRAME_H = 400        -- built-in roles: no group-role dropdown
local FRAME_H_CUSTOM = 434 -- custom/create: group-role dropdown under the name
local ROLE_ROW_H = 34      -- what that dropdown adds above the buff list
-- Group-role icon in front of a read-only role's name. Sized against
-- GameFontNormalLarge rather than the 14px the tooltips and rows use.
local ROLE_NAME_ICON = 20
local CLASS_ICON_SIZE = 52
local SPEC_ICON_SIZE = 26

-- Create mode's placeholder until a class is picked. It is no longer any role's
-- icon: a custom role wears its class's icon (Data.lua).
local QUESTION_MARK_ICON = 134400 -- INV_Misc_QuestionMark

local BUFF_ROW_H = 30
local BUFF_ICON_SIZE = 22
local ARROW_BTN_SIZE = 24

-- The Blizzard arrow art sits off-center inside its texture (the up caret rides
-- high, the down caret rides low), so nudge each vertically to visually center
-- it in the button. Tweak here if a different arrow texture is swapped in.
local ARROW_NUDGE = { Up = 2, Down = -4 }


-- A small standard (red) WoW button with an arrow texture centered inside,
-- used to nudge a buff up or down in the list. `dir` is "Up" or "Down".
local function CreateArrowButton(parent, dir)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(ARROW_BTN_SIZE, ARROW_BTN_SIZE)
    b:SetText("")

    local arrow = b:CreateTexture(nil, "OVERLAY")
    arrow:SetSize(12, 12)
    arrow:SetPoint("CENTER", 0, ARROW_NUDGE[dir] or 0)
    arrow:SetTexture("Interface\\Buttons\\Arrow-" .. dir .. "-Up")
    b.arrow = arrow

    return b
end


-- Enable/disable an arrow button. UIPanelButtonTemplate greys its own chrome on
-- Disable(), but our overlaid arrow texture isn't part of that, so dim it too.
local function SetArrowEnabled(b, enabled)
    b:SetEnabled(enabled)
    b.arrow:SetDesaturated(not enabled)
    if enabled then
        b.arrow:SetVertexColor(1, 1, 1)
    else
        b.arrow:SetVertexColor(0.5, 0.5, 0.5)
    end
end


-- Dropdown display text for a WoW role: its micro atlas icon + name.
local function RoleText(key)
    return WhoDoesWhat:GetWowRoleIconMarkup(key, 14) .. " " .. WhoDoesWhat.BasicWowRoles[key].name
end


-- Dropdown display text for a class: class-colored name.
local function ClassText(classInfo)
    return "|cff" .. classInfo.colorHex .. classInfo.name .. "|r"
end


-- The status line says one thing and only one: that this edit is not private.
-- Everywhere else it stays empty -- the window's title, buttons and controls
-- already say what mode you are in, and a line restating that is noise sitting
-- where the one warning worth reading should be.
local function UpdateCustomStatus(f)
    if f.isRaidRole then
        f.customStatus:SetText("|T" .. WhoDoesWhat.WARNING_ICON .. ":14:14:0:0|t"
            .. " |cffff9933Changes affect the entire raid|r")
    else
        f.customStatus:SetText("")
    end
end


-- Point the group-role dropdown at a wowRole value. A custom role must carry
-- one (see GetRoleControls), so a legacy role saved without one -- back when
-- "unassigned" was allowed -- opens showing DPS and is fixed by saving.
local function SetRoleControls(f, wowRole)
    local key = wowRole or "dps"
    UIDropDownMenu_SetSelectedValue(f.roleDropdown, key)
    UIDropDownMenu_SetText(f.roleDropdown, RoleText(key))
end


-- Read the group role back out: always one of "dps"/"tank"/"healer".
-- "Unassigned" used to be selectable here and is deliberately gone: a custom
-- role without a group role can't drive the Blizzard role flag, and -- worse --
-- a main tank switched onto one couldn't be classified as not-a-tank, so the
-- main-tank mark stuck until someone cleared it by hand.
local function GetRoleControls(f)
    return UIDropDownMenu_GetSelectedValue(f.roleDropdown) or "dps"
end


-- Repaint the full order around the END divider. Rows below it are banned:
-- their Up arrow promotes them, while their Down arrow is disabled.
--
-- The arrows disappear for a built-in role, which is the one thing this window
-- can't change: its order is WDW's default, retuned only by overriding it for
-- the raid. They live on the row's right edge, so hiding them leaves the list
-- itself exactly where it was.
local function RenderBuffRows(f)
    local editable = f.orderEditable and true or false
    -- The divider only means something while the list can be reordered: it is
    -- the line you drag a blessing across. Read-only, the greyed rows and their
    -- X already say which ones are never assigned, so it hides and the rows
    -- close up rather than leaving a gap around nothing.
    f.buffDivider:SetShown(editable)
    f.buffDivider:ClearAllPoints()
    f.buffDivider:SetPoint("TOPLEFT", 16,
        -(f.buffListTop + f.allowedCount * BUFF_ROW_H))
    for i, row in ipairs(f.buffRows) do
        local key = f.buffOrder[i]
        local buff = WhoDoesWhat.PaladinBuffs[key]
        local isBanned = i > f.allowedCount
        local visualIndex = i + ((isBanned and editable) and 1 or 0)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 16,
            -(f.buffListTop + (visualIndex - 1) * BUFF_ROW_H))
        row.buffKey = key
        row.icon:SetTexture(buff.iconId)
        row.label:SetText(buff.name_long)
        if isBanned then
            row.index:SetText("X")
            row.index:SetTextColor(1, 0.2, 0.2)
            row.label:SetTextColor(0.5, 0.5, 0.5)
        else
            row.index:SetText(i .. ".")
            row.index:SetTextColor(1, 0.82, 0)
            row.label:SetTextColor(1, 1, 1)
        end
        row.upBtn:SetShown(editable)
        row.downBtn:SetShown(editable)
        if editable then
            SetArrowEnabled(row.upBtn, i > 1 or i > f.allowedCount)
            SetArrowEnabled(row.downBtn, i <= f.allowedCount)
        end
        row:Show()
    end
end


-- Reorder allowed buffs, ban the last allowed buff, or promote any banned buff
-- to the lowest allowed priority.
local function MoveBuff(f, index, delta)
    if delta < 0 and index > f.allowedCount then
        local key = table.remove(f.buffOrder, index)
        f.allowedCount = f.allowedCount + 1
        table.insert(f.buffOrder, f.allowedCount, key)
    elseif delta < 0 and index > 1 then
        f.buffOrder[index], f.buffOrder[index - 1] = f.buffOrder[index - 1], f.buffOrder[index]
    elseif delta > 0 and index == f.allowedCount then
        f.allowedCount = f.allowedCount - 1
    elseif delta > 0 and index < f.allowedCount then
        f.buffOrder[index], f.buffOrder[index + 1] = f.buffOrder[index + 1], f.buffOrder[index]
    else
        return
    end
    RenderBuffRows(f)
end


-- When a custom role becomes a tank, place its role-type defaults below the
-- divider. The user can immediately promote them again with Up.
local function ApplyWowRoleBans(f, wowRole)
    local banned = WhoDoesWhat.PaladinBuffBansByWowRole[wowRole]
    if not banned then return end
    local i = 1
    while i <= f.allowedCount do
        if banned[f.buffOrder[i]] then
            table.insert(f.buffOrder, table.remove(f.buffOrder, i))
            f.allowedCount = f.allowedCount - 1
        else
            i = i + 1
        end
    end
    RenderBuffRows(f)
end


-- ---------------------------------------------------------------------------
-- Custom-role icon picker
--
-- A small curated grid rather than the client's whole macro-icon set: the job
-- is telling two custom roles apart in a list, which a dozen relevant icons do
-- and several thousand irrelevant ones actively get in the way of. The choices
-- come from CustomRoleIconChoices -- class icon, that class's own role icons,
-- then the generic group-role icons.
--
-- Nothing is saved until the window's Save button runs; the picker only moves
-- f.selectedIcon, and an unpicked icon stays nil so the role keeps following
-- its class.
-- ---------------------------------------------------------------------------

local ICON_CELL = 28
local ICON_COLS = 6
local ICON_PAD = 4

local ToggleIconPicker -- forward declaration; the header button calls it

-- The class whose icons the picker should offer: the create-mode pick, or the
-- open role's own class.
local function CurrentClassName(f)
    if f.selectedClass then return f.selectedClass end
    local role = f.currentRole
    return role and role.classInfo and role.classInfo.name
end

-- Show an icon in the header slot. `icon` may be a texture or a "role:*" micro
-- role icon, so it goes through the shared setter.
local function ShowRoleIcon(f, icon)
    WhoDoesWhat:SetRoleIconTexture(f.specIcon, icon)
    f.specIcon:Show()
end

local function SetRoleIcon(f, icon)
    f.selectedIcon = icon
    ShowRoleIcon(f, icon)
end

local function CreateIconCell(picker, index)
    local cell = CreateFrame("Button", nil, picker)
    cell:SetSize(ICON_CELL, ICON_CELL)
    cell:SetFrameLevel(picker:GetFrameLevel() + 1)

    -- The "selected" mark is a gold plate behind an inset icon, so the choice
    -- in use wears a border without a second texture on top of the art.
    local selected = cell:CreateTexture(nil, "BACKGROUND")
    selected:SetAllPoints()
    selected:SetColorTexture(1, 0.82, 0)
    cell.selected = selected

    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    cell.icon = icon

    local highlight = cell:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    cell:SetScript("OnEnter", function(self)
        if not self.label then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.label, 1, 1, 1)
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)

    picker.cells[index] = cell
    return cell
end

local function RefreshIconPicker(f)
    local picker = f.iconPicker
    local choices = WhoDoesWhat:CustomRoleIconChoices(CurrentClassName(f))
    for i, choice in ipairs(choices) do
        local cell = picker.cells[i] or CreateIconCell(picker, i)
        local col = (i - 1) % ICON_COLS
        local row = math.floor((i - 1) / ICON_COLS)
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", ICON_PAD + col * (ICON_CELL + ICON_PAD),
            -(ICON_PAD + row * (ICON_CELL + ICON_PAD)))
        WhoDoesWhat:SetRoleIconTexture(cell.icon, choice.icon)
        cell.label = choice.label
        -- Compared against the effective icon, not the stored one: an unpicked
        -- role reads as "the first choice is selected", which is what it wears.
        cell.selected:SetShown((f.selectedIcon or choices[1].icon) == choice.icon)
        cell:SetScript("OnClick", function()
            SetRoleIcon(f, choice.icon)
            picker:Hide()
        end)
        cell:Show()
    end
    for i = #choices + 1, #picker.cells do
        picker.cells[i]:Hide()
    end

    local rows = math.ceil(#choices / ICON_COLS)
    picker:SetSize(ICON_PAD * 2 + ICON_COLS * ICON_CELL + (ICON_COLS - 1) * ICON_PAD,
        ICON_PAD * 2 + rows * ICON_CELL + (rows - 1) * ICON_PAD)
end

function ToggleIconPicker(f) -- forward declared above
    if not f.iconPicker then
        local picker = CreateFrame("Frame", nil, f, "BackdropTemplate")
        picker:SetFrameLevel(f:GetFrameLevel() + 10)
        picker:SetPoint("TOPLEFT", f.classIcon, "BOTTOMLEFT", 0, -4)
        picker:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        picker:SetBackdropColor(0.1, 0.1, 0.12, 0.95)
        picker:SetBackdropBorderColor(0.4, 0.4, 0.4)
        picker.cells = {}
        picker:Hide()
        f.iconPicker = picker
    end
    if f.iconPicker:IsShown() then
        f.iconPicker:Hide()
        return
    end
    RefreshIconPicker(f)
    -- Re-stacked on every open: the window's own Raise() moves its level, and a
    -- grid that opens behind the buff rows it covers is worse than useless.
    f.iconPicker:SetFrameLevel(f:GetFrameLevel() + 10)
    f.iconPicker:Show()
end

-- Close the window and refresh the All Roles view (row list + gear markers).
-- A raid role isn't in that window at all, but it is in the main window's
-- Custom Roles list and in every blessing the plan derives from it.
local function CloseAndRefresh(f)
    f:Hide()
    if f.isRaidRole then
        WhoDoesWhat:RefreshMainAssignmentsView()
        WhoDoesWhat:RefreshBuffingGridView()
    else
        WhoDoesWhat:RebuildAllRolesView()
    end
end


-- Read the name box, complaining and focusing it when empty. nil means stop.
local function ReadName(f)
    local name = strtrim(f.nameEdit:GetText() or "")
    if name == "" then
        WhoDoesWhat:Print("Enter a name for the role before saving.")
        f.nameEdit:SetFocus()
        return nil
    end
    return name
end

-- Save: persist the window state and close. Built-in roles have no Save at all
-- (see the mode table above OpenCustomizer); the three modes that do are create,
-- editing a library role's identity, and editing a board entry.
local function OnApply(f)
    if f.isBuiltIn then
        CloseAndRefresh(f) -- the button reads "Close"; there is nothing to save
        return
    end
    if f.isCreateMode then
        local name = ReadName(f)
        if not name then return end
        if not f.selectedClass then
            WhoDoesWhat:Print("Select a class for the new role before saving.")
            return
        end
        local role = WhoDoesWhat:CreateCustomRole(name, f.selectedClass,
            GetRoleControls(f), f.selectedIcon, f.buffOrder, f.allowedCount)
        if not role then return end -- storage rejected it and said why
        WhoDoesWhat:LogOperation("Custom role '" .. name .. "' created under " .. f.selectedClass .. ".")
    elseif f.isRaidRole then
        local role = f.currentRole
        if not role then return end
        if not WhoDoesWhat:RequireEditPermission() then return end
        -- An override carries no identity of its own; only its order is saved.
        local name = f.identityEditable and ReadName(f) or role.name
        if not name then return end
        if not WhoDoesWhat:UpdateRaidCustomRole(f.currentRoleId, name,
            GetRoleControls(f), f.selectedIcon, f.buffOrder, f.allowedCount) then
            return -- storage rejected it and said why
        end
        WhoDoesWhat:LogOperation("Raid role '" .. name .. "' saved.")
    else
        local role = f.currentRole
        if not role or not role.isCustom then return end
        local name = ReadName(f)
        if not name then return end
        if not WhoDoesWhat:UpdateCustomRole(f.currentRoleId, name,
            GetRoleControls(f), f.selectedIcon, f.buffOrder, f.allowedCount) then
            return -- storage rejected it and said why
        end
        WhoDoesWhat:LogOperation("Custom role '" .. name .. "' saved.")
    end
    CloseAndRefresh(f)
end


-- The context-dependent secondary button:
--   create mode    "Cancel"          close, discarding the unmade role
--   raid entry     "Remove"          take it off the raid's list, close (the
--                                    library role it came from is left alone;
--                                    an override just reverts to defaults)
--   custom role    "Delete"          remove the role entirely, close
--   built-in role  "Create a Copy"   clone it into a custom role of your own
--                                    and open that for editing -- built-in
--                                    roles themselves can't be changed
local function OnSecondary(f)
    if f.isCreateMode then
        f:Hide()
    elseif f.isBuiltIn and f.currentRole then
        local clone = WhoDoesWhat:CloneRoleToCustom(f.currentRoleId)
        if not clone then return end
        WhoDoesWhat:LogOperation("Custom role '" .. clone.name .. "' copied from "
            .. f.currentRole.name .. ".")
        WhoDoesWhat:RebuildAllRolesView()
        WhoDoesWhat:OpenCustomizer(clone.id)
    elseif f.isRaidRole and f.currentRole then
        if not WhoDoesWhat:RequireEditPermission() then return end
        -- Exactly what the Custom Roles row's [x] does, prompt included: same
        -- action, so it must not warn about different things depending on which
        -- window you happened to click it in.
        WhoDoesWhat:ConfirmRemoveRaidRole(f.currentRoleId, function()
            CloseAndRefresh(f)
        end)
    elseif f.currentRole and f.currentRole.isCustom then
        WhoDoesWhat:LogOperation("Custom role '" .. f.currentRole.name .. "' deleted.")
        WhoDoesWhat:DeleteCustomRole(f.currentRoleId)
        CloseAndRefresh(f)
    end
end


-- Build the customize window once (chrome + placeholder widgets we update per
-- role). Reused across opens.
local function EnsureCustomizeFrame()
    if customizeFrame then return customizeFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatCustomizeFrame", FRAME_W, FRAME_H, "")
    local top = f.titleBarHeight + 14

    -- The icon grid is a child, so it would otherwise survive Escape and the
    -- close button as a floating orphan. Hooked rather than set, so whatever
    -- the shared chrome does on hide still runs.
    f:HookScript("OnHide", function(self)
        if self.iconPicker then self.iconPicker:Hide() end
    end)

    -- Large class icon, top-left ("?" in create mode until a class is picked)
    local classIcon = f:CreateTexture(nil, "ARTWORK")
    classIcon:SetSize(CLASS_ICON_SIZE, CLASS_ICON_SIZE)
    classIcon:SetPoint("TOPLEFT", 16, -top)
    f.classIcon = classIcon

    -- Smaller spec icon overlapping the class icon's bottom-right. For a
    -- built-in role it is that spec's icon and nothing more; for a custom role
    -- it is the role's own icon and clicking it opens the picker below.
    local specIcon = f:CreateTexture(nil, "OVERLAY")
    specIcon:SetSize(SPEC_ICON_SIZE, SPEC_ICON_SIZE)
    specIcon:SetPoint("BOTTOMRIGHT", classIcon, "BOTTOMRIGHT", 5, -5)
    f.specIcon = specIcon

    local iconBtn = CreateFrame("Button", nil, f)
    iconBtn:SetAllPoints(specIcon)
    iconBtn:SetFrameLevel(f:GetFrameLevel() + 2)
    local iconHighlight = iconBtn:CreateTexture(nil, "HIGHLIGHT")
    iconHighlight:SetAllPoints()
    iconHighlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    iconHighlight:SetBlendMode("ADD")
    iconBtn:SetScript("OnClick", function() ToggleIconPicker(f) end)
    iconBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Role icon", 1, 1, 1)
        GameTooltip:AddLine("Click to pick a different one. Nothing picked means"
            .. " the class icon.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    iconBtn:Hide()
    f.iconBtn = iconBtn

    -- Class name, big and class-colored, to the right of the icon
    local className = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    className:SetPoint("LEFT", classIcon, "RIGHT", 14, 9)
    f.className = className

    -- Class picker occupying the class-name spot (create mode only; a custom
    -- role's class can't change after creation). Selecting a class previews it
    -- in the header icons. UIDropDownMenu has ~15px of transparent left
    -- padding; pull it toward the icon.
    local classDropdown = CreateFrame("Frame", "WhoDoesWhatClassDropDown", f, "UIDropDownMenuTemplate")
    classDropdown:SetPoint("LEFT", classIcon, "RIGHT", -2, 12)
    UIDropDownMenu_SetWidth(classDropdown, 110)
    WhoDoesWhat:StyleDropdown(classDropdown, true)
    UIDropDownMenu_Initialize(classDropdown, function(_, level)
        for _, classInfo in ipairs(WhoDoesWhat.Classes) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = ClassText(classInfo)
            info.value = classInfo.name
            info.func = function(item)
                UIDropDownMenu_SetSelectedValue(classDropdown, item.value)
                UIDropDownMenu_SetText(classDropdown, ClassText(classInfo))
                f.selectedClass = classInfo.name
                -- Preview: the big icon becomes the class, and the icon slot
                -- follows it. A class-specific pick is dropped -- it came from
                -- the old class's icons -- but a group-role pick survives,
                -- since those are offered whatever the class.
                f.classIcon:SetTexture(classInfo.classIcon)
                if f.iconPicker then f.iconPicker:Hide() end
                if not WhoDoesWhat:RoleIconKey(f.selectedIcon) then
                    f.selectedIcon = nil
                    ShowRoleIcon(f, classInfo.classIcon)
                end
                f.iconBtn:Show()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    classDropdown:Hide()
    f.classDropdown = classDropdown

    -- Role name just below the class name (built-in roles)
    local roleName = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    roleName:SetPoint("TOPLEFT", className, "BOTTOMLEFT", 0, -2)
    f.roleName = roleName

    -- Editable name box occupying the role-name spot (custom roles / create
    -- mode). InputBoxTemplate's art hangs ~5px left of the frame, hence the
    -- small x offset.
    local nameEdit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    nameEdit:SetSize(130, 20)
    nameEdit:SetPoint("TOPLEFT", className, "BOTTOMLEFT", 6, -1)
    nameEdit:SetAutoFocus(false)
    nameEdit:SetMaxLetters(20)
    nameEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    nameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    nameEdit:Hide()
    f.nameEdit = nameEdit

    -- Group-role dropdown, tucked under the name field it belongs with rather
    -- than parked at the bottom of the window. No label: the three entries say
    -- Tank/Healer/DPS in words and wear the client's role icons. The x offset
    -- cancels UIDropDownMenu's ~15px of transparent left padding so its visible
    -- edge lines up with the name above it -- same trick as the class picker.
    -- Anchored off the class icon rather than the name above it: in create mode
    -- className is hidden but keeps whatever size its last text gave it, which
    -- would drift this row between opens. The icon never moves or resizes.
    local roleDropdown = CreateFrame("Frame", "WhoDoesWhatRoleDropDown", f, "UIDropDownMenuTemplate")
    roleDropdown:SetPoint("TOPLEFT", classIcon, "BOTTOMRIGHT", -2, 4)
    UIDropDownMenu_SetWidth(roleDropdown, 80)
    WhoDoesWhat:StyleDropdown(roleDropdown, true)
    UIDropDownMenu_Initialize(roleDropdown, function(_, level)
        for _, key in ipairs({ "dps", "tank", "healer" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = RoleText(key)
            info.value = key
            info.func = function(item)
                UIDropDownMenu_SetSelectedValue(roleDropdown, item.value)
                UIDropDownMenu_SetText(roleDropdown, RoleText(item.value))
                ApplyWowRoleBans(f, item.value)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.roleDropdown = roleDropdown

    -- Left-aligned list heading. Its y and the list's move down together when
    -- the group-role dropdown is showing; see SetIdentityControlsShown.
    f.headingTop = top + CLASS_ICON_SIZE + 16
    f.listTopBase = top + CLASS_ICON_SIZE + 36
    local buffHeading = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    buffHeading:SetPoint("TOPLEFT", 16, -f.headingTop)
    buffHeading:SetText("Paladin Buff Priority")
    f.buffHeading = buffHeading

    -- Buff priority rows: number, icon, spell name, and up/down arrows, with an
    -- END divider inserted between allowed and banned blessings at render time.
    local canonical = WhoDoesWhat.CanonicalBuffOrder
    f.buffOrder = { unpack(canonical) }
    f.allowedCount = #canonical
    f.buffRows = {}
    f.buffListTop = f.listTopBase -- re-set per open by SetIdentityControlsShown
    -- The boundary between blessings this role receives and the ones it never
    -- does. Grey and small: it labels the rest of the list rather than warning
    -- about it, and it only appears while the list can actually be reordered.
    local divider = CreateFrame("Frame", nil, f)
    divider:SetSize(FRAME_W - 32, BUFF_ROW_H)
    local dividerLabel = divider:CreateFontString(nil, "BACKGROUND", "GameFontNormalSmall")
    dividerLabel:SetPoint("TOP")
    dividerLabel:SetPoint("BOTTOM")
    dividerLabel:SetJustifyH("CENTER")
    dividerLabel:SetText("Never assigned")
    dividerLabel:SetTextColor(0.55, 0.55, 0.55)
    local dividerLeft = divider:CreateTexture(nil, "BACKGROUND")
    dividerLeft:SetHeight(8)
    dividerLeft:SetPoint("LEFT", 3, 0)
    dividerLeft:SetPoint("RIGHT", dividerLabel, "LEFT", -5, 0)
    dividerLeft:SetTexture(137057) -- Interface\Tooltips\UI-Tooltip-Border
    dividerLeft:SetTexCoord(0.81, 0.94, 0.5, 1)
    dividerLeft:SetVertexColor(0.55, 0.55, 0.55)
    local dividerRight = divider:CreateTexture(nil, "BACKGROUND")
    dividerRight:SetHeight(8)
    dividerRight:SetPoint("RIGHT", -3, 0)
    dividerRight:SetPoint("LEFT", dividerLabel, "RIGHT", 5, 0)
    dividerRight:SetTexture(137057)
    dividerRight:SetTexCoord(0.81, 0.94, 0.5, 1)
    dividerRight:SetVertexColor(0.55, 0.55, 0.55)
    f.buffDivider = divider
    for i = 1, #canonical do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(FRAME_W - 32, BUFF_ROW_H)

        -- Number, icon and name read from the left; the arrows sit on the right
        -- edge, out of the way of the list itself. A built-in role hides them,
        -- and because they were never holding left-hand space the rows still
        -- line up with everything above.
        local downBtn = CreateArrowButton(row, "Down")
        downBtn:SetPoint("RIGHT", 0, 0)
        downBtn:SetScript("OnClick", function() MoveBuff(f, i, 1) end)
        row.downBtn = downBtn

        local upBtn = CreateArrowButton(row, "Up")
        upBtn:SetPoint("RIGHT", downBtn, "LEFT", -2, 0)
        upBtn:SetScript("OnClick", function() MoveBuff(f, i, -1) end)
        row.upBtn = upBtn

        local index = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        index:SetPoint("LEFT", 0, 0)
        index:SetWidth(22)
        index:SetJustifyH("LEFT")
        row.index = index

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(BUFF_ICON_SIZE, BUFF_ICON_SIZE)
        icon:SetPoint("LEFT", index, "RIGHT", 2, 0)
        row.icon = icon

        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        label:SetPoint("LEFT", icon, "RIGHT", 8, 0)
        label:SetPoint("RIGHT", upBtn, "LEFT", -6, 0)
        label:SetJustifyH("LEFT")
        row.label = label

        -- Ability tooltip when hovering the buff icon only (textures can't
        -- take mouse events, so a small invisible frame sits over it),
        -- anchored with its bottom-left just above the icon (same style as
        -- the main assignments view). buffKey is read at hover time since
        -- RenderBuffRows reshuffles the rows.
        local iconHover = CreateFrame("Frame", nil, row)
        iconHover:SetAllPoints(icon)
        iconHover:EnableMouse(true)
        iconHover:SetScript("OnEnter", function()
            local buff = row.buffKey and WhoDoesWhat.PaladinBuffs[row.buffKey]
            if buff and buff.spellId then
                GameTooltip:SetOwner(row, "ANCHOR_NONE")
                GameTooltip:SetPoint("BOTTOMLEFT", row.icon, "TOPLEFT", 0, 6)
                GameTooltip:SetHyperlink("spell:" .. buff.spellId)
                GameTooltip:Show()
            end
        end)
        iconHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

        f.buffRows[i] = row
    end

    -- Status line ("Customized" / "Using defaults" / unsaved-edit prompts),
    -- right-aligned just above the buttons so it points at Save/Apply.
    local customStatus = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    customStatus:SetPoint("BOTTOMRIGHT", -14, 42)
    f.customStatus = customStatus

    -- Primary + secondary buttons, bottom-right; per-mode labels set on open:
    --   built-in:    [Reset to Defaults] [Apply]
    --   custom edit: [Delete]            [Save]
    --   create:      [Cancel]            [Save]
    local applyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    applyBtn:SetSize(90, 22)
    applyBtn:SetPoint("BOTTOMRIGHT", -12, 12)
    applyBtn:SetScript("OnClick", function() OnApply(f) end)
    f.applyBtn = applyBtn

    local secondaryBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    secondaryBtn:SetSize(120, 22)
    secondaryBtn:SetPoint("RIGHT", applyBtn, "LEFT", -8, 0)
    secondaryBtn:SetScript("OnClick", function() OnSecondary(f) end)
    f.secondaryBtn = secondaryBtn

    customizeFrame = f
    return f
end


-- Show or hide the group-role dropdown and lay the window out around it. When
-- it is hidden the group role rides in front of the role's name instead (see
-- OpenCustomizer), so nothing needs the row and everything below moves back up.
--
-- Must run BEFORE RenderBuffRows, which positions the rows from f.buffListTop.
local function SetIdentityControlsShown(f, editable)
    f.roleDropdown:SetShown(editable)
    local extra = editable and ROLE_ROW_H or 0
    f.buffHeading:ClearAllPoints()
    f.buffHeading:SetPoint("TOPLEFT", 16, -(f.headingTop + extra))
    f.buffListTop = f.listTopBase + extra
    f:SetHeight(editable and FRAME_H_CUSTOM or FRAME_H)
end


-- Open the single-role customizer for the given role id. Edits are live in the
-- window only until the primary button persists them and closes.
--
-- Four modes, and what separates them is WHERE the thing being edited lives:
--
--   raidMode      a board entry (the Custom Roles section): the raid's order
--                 for that role. A published custom role also has its identity
--                 editable; an override of a built-in role or category has none
--                 of its own, so only the order. Save / Remove.
--   library role  one of your own custom roles -- its whole definition, order
--                 included. Save / Delete.
--   built-in      a stock role or category. Entirely read-only, since its order
--                 IS the default: change it by overriding it for the raid, or
--                 copy it into a role of your own. Create a Copy only.
--   create        see OpenCustomizerForNewRole.
function WhoDoesWhat:OpenCustomizer(roleId, raidMode)

    local role = not raidMode and self.LibraryRoles and self.LibraryRoles[roleId]
    local classInfo = role and role.classInfo
    if not role then
        classInfo, role = self:FindRoleById(roleId)
    end
    if not role then
        self:Print("OpenCustomizer: unknown role id '" .. tostring(roleId) .. "'")
        return
    end
    if raidMode and not self:FindRaidCustomRole(roleId) then
        self:Print("OpenCustomizer: '" .. tostring(roleId) .. "' is not on the raid's list")
        return
    end

    -- A category is only reachable in raid mode (as an override) or read-only,
    -- so the resolved entry is the right one to describe either way. Its own
    -- entry is what carries allSubRoles, so look it up unresolved.
    local raw = self.RolesAndCategories[roleId] or role
    local isCategory = raw.allSubRoles ~= nil
    local boardDef = raidMode and self:FindRaidCustomRole(roleId) or nil

    local f = EnsureCustomizeFrame()
    f.isCreateMode = false
    f.isRaidRole = raidMode and true or false
    f.isBuiltIn = (not raidMode) and not role.isCustom
    -- Everything but a built-in role owns its order: a board entry holds the
    -- raid's, a custom role holds its own definition.
    f.orderEditable = not f.isBuiltIn
    f.identityEditable = f.isRaidRole and self:IsRaidCustomRoleDef(boardDef)
        or (not f.isRaidRole and role.isCustom and true or false)
    f.currentRole = role
    -- The id the caller asked for, NOT role.id: FindRoleById resolves a
    -- one-role category to that role, so a board entry keyed by the category
    -- would be unfindable on Save/Remove if we trusted the resolved entry.
    f.currentRoleId = roleId
    f.selectedClass = nil
    f.classDropdown:Hide()

    if raidMode then
        f.titleText:SetText(f.identityEditable and "Editing Shared Custom Role"
            or ("Overriding " .. (isCategory and "Category" or "Role")))
    elseif role.isCustom then
        f.titleText:SetText("Editing Custom Role")
    elseif isCategory then
        f.titleText:SetText("Category Defaults (" .. #raw.allSubRoles .. " roles)")
    else
        f.titleText:SetText("Role Defaults")
    end

    -- Big class icon + class-colored class name
    f.classIcon:SetTexture(classInfo.classIcon)
    f.className:SetText("|cff" .. classInfo.colorHex .. classInfo.name .. "|r")
    f.className:Show()

    -- A category has no group role of its own; take it from the sub-role its
    -- defaults already come from, same as the Custom Roles rows do.
    local source = isCategory
        and (self.RolesAndCategories[raw.allSubRoles[1]] or role) or role

    -- Role name: an editable box only where the identity is this window's to
    -- change; a static label otherwise. Categories show their own name.
    --
    -- The static form leads with the group-role icon -- "[DPS] Fury" -- which
    -- is where a read-only role states its group role. Nothing else has to make
    -- room for it, unlike the dropdown the editable form needs.
    local displayName = (isCategory and raw.name) or role.name
    if f.identityEditable then
        f.roleName:Hide()
        f.nameEdit:SetText(displayName)
        f.nameEdit:Show()
    else
        f.nameEdit:Hide()
        local roleIcon = source.wowRole
            and (self:GetWowRoleIconMarkup(source.wowRole, ROLE_NAME_ICON) .. " ")
            or ""
        f.roleName:SetText(roleIcon .. "|cff" .. classInfo.colorHex
            .. displayName .. "|r")
        f.roleName:Show()
    end

    -- Spec icon overlay: the role's own icon. Categories have no single spec.
    -- The same slot is the icon picker's button where the icon is editable.
    if f.iconPicker then f.iconPicker:Hide() end
    f.selectedIcon = nil
    if isCategory then
        f.specIcon:Hide()
        f.iconBtn:Hide()
    else
        if f.identityEditable then
            -- The STORED pick, not the effective icon: leaving it nil is what
            -- keeps an undecorated role following its class.
            local stored = boardDef or self:FindLocalCustomRole(role.id)
            f.selectedIcon = stored and stored.icon or nil
        end
        ShowRoleIcon(f, role.icon)
        f.iconBtn:SetShown(f.identityEditable)
    end

    -- Lay out first: this decides where the buff list starts.
    SetIdentityControlsShown(f, f.identityEditable)
    if f.identityEditable then SetRoleControls(f, role.wowRole) end

    -- The effective order: the board's override where there is one, the
    -- defaults otherwise. Copied so the in-window arrows don't mutate the
    -- stored tables; nothing is persisted until Save.
    local order
    order, f.allowedCount = self:GetEffectiveBuffSetup(roleId)
    f.buffOrder = { unpack(order) }
    RenderBuffRows(f)

    -- Nothing about a built-in role can be saved, so it has no primary button
    -- at all -- the title bar's X closes it, same as any other window here --
    -- and Create a Copy takes the corner on its own.
    f.applyBtn:SetShown(not f.isBuiltIn)
    f.secondaryBtn:ClearAllPoints()
    if f.isBuiltIn then
        f.secondaryBtn:SetPoint("BOTTOMRIGHT", -12, 12)
        f.secondaryBtn:SetText("Create a Copy")
        f.secondaryBtn:SetWidth(110)
    else
        f.secondaryBtn:SetPoint("RIGHT", f.applyBtn, "LEFT", -8, 0)
        f.applyBtn:SetText("Save")
        f.secondaryBtn:SetText(raidMode and "Remove" or "Delete")
        f.secondaryBtn:SetWidth(raidMode and 80 or 70)
    end

    UpdateCustomStatus(f)

    self:LogUiBuilding("Opening customizer for " .. classInfo.name .. " / " .. displayName)
    f:Show()
    f:Raise()
end


-- Open the customizer in create mode: blank name, class picker (required),
-- canonical buff order, assign-role defaulted to on/DPS, and Save/Cancel
-- buttons. The header shows "?" until a class is picked; the saved role keeps
-- the "?" as its own icon inside that class's list.
function WhoDoesWhat:OpenCustomizerForNewRole()
    local f = EnsureCustomizeFrame()

    f.isCreateMode = true
    f.isRaidRole = false
    f.isBuiltIn = false
    -- A new role is entirely yours: name, class, group role, icon and order.
    f.identityEditable = true
    f.orderEditable = true
    f.currentRole = nil
    f.currentRoleId = nil
    f.selectedClass = nil

    f.titleText:SetText("New Custom Role")
    f.classIcon:SetTexture(QUESTION_MARK_ICON)
    -- The icon slot is live from the start: with no class picked the grid still
    -- offers the group-role icons, and the class's own are added to it as soon
    -- as one is chosen. The "?" here means "nothing picked", same as the big
    -- icon beside it.
    if f.iconPicker then f.iconPicker:Hide() end
    f.selectedIcon = nil
    ShowRoleIcon(f, QUESTION_MARK_ICON)
    f.iconBtn:Show()
    f.className:Hide()
    f.roleName:Hide()

    UIDropDownMenu_SetSelectedValue(f.classDropdown, nil)
    UIDropDownMenu_SetText(f.classDropdown, "Select class...")
    f.classDropdown:Show()

    f.nameEdit:SetText("")
    f.nameEdit:Show()

    -- Layout before rows, same as OpenCustomizer: the dropdown decides where
    -- the buff list starts.
    SetIdentityControlsShown(f, true)
    SetRoleControls(f, "dps") -- a new role defaults to DPS

    f.buffOrder = { unpack(self.CanonicalBuffOrder) }
    f.allowedCount = #f.buffOrder
    RenderBuffRows(f)

    f.applyBtn:Show()
    f.applyBtn:SetText("Save")
    f.secondaryBtn:ClearAllPoints()
    f.secondaryBtn:SetPoint("RIGHT", f.applyBtn, "LEFT", -8, 0)
    f.secondaryBtn:SetText("Cancel")
    f.secondaryBtn:SetWidth(70)

    UpdateCustomStatus(f)

    self:LogUiBuilding("Opening customizer to create a new custom role.")
    f:Show()
    f:Raise()
    f.nameEdit:SetFocus()
end
