local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

local customizeFrame = nil

local FRAME_W = 250
local FRAME_H = 400        -- built-in roles: no assign-role row
local FRAME_H_CUSTOM = 434 -- custom/create: assign-role row below the buff list
local CLASS_ICON_SIZE = 52
local SPEC_ICON_SIZE = 26

local QUESTION_MARK_ICON = 134400 -- INV_Misc_QuestionMark, the custom-role icon

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


-- Refresh the status line above the buttons. Unsaved edits (and create mode)
-- point the user at Save/Apply; otherwise it reports the saved state from the
-- DB (a category reads "Customized" when any of its sub-roles deviates).
local function UpdateCustomStatus(f)
    if f.isCreateMode then
        f.customStatus:SetText("|cffff9933New role - click Save to create|r")
    elseif f.dirty then
        local action = (f.currentRole and f.currentRole.isCustom) and "Save" or "Apply"
        f.customStatus:SetText("|cffff9933Unsaved changes - click " .. action .. "|r")
    elseif f.currentRole and WhoDoesWhat:IsRoleCustomized(f.currentRole.id) then
        f.customStatus:SetText("|TInterface\\Buttons\\UI-OptionsButton:11:11:0:0|t |cffffd100Customized|r")
    else
        f.customStatus:SetText("|cff909090Using defaults|r")
    end
end


-- Flag an unsaved edit and refresh the status line. In create mode the status
-- already reads "click Save to create", so nothing changes there.
local function MarkDirty(f)
    if not f.isCreateMode then
        f.dirty = true
        UpdateCustomStatus(f)
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
local function RenderBuffRows(f)
    f.buffDivider:ClearAllPoints()
    f.buffDivider:SetPoint("TOPLEFT", 16,
        -(f.buffListTop + f.allowedCount * BUFF_ROW_H))
    for i, row in ipairs(f.buffRows) do
        local key = f.buffOrder[i]
        local buff = WhoDoesWhat.PaladinBuffs[key]
        local isBanned = i > f.allowedCount
        local visualIndex = i + (isBanned and 1 or 0)
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
        SetArrowEnabled(row.upBtn, i > 1 or i > f.allowedCount)
        SetArrowEnabled(row.downBtn, i <= f.allowedCount)
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
    MarkDirty(f)
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


-- Close the window and refresh the All Roles view (row list + gear markers).
local function CloseAndRefresh(f)
    f:Hide()
    WhoDoesWhat:RebuildAllRolesView()
end


-- Save/Apply: persist the window state and close. Create mode makes the new
-- custom role first (name + class required); editing a custom role also saves
-- its name and assigned wow role. A category fans the order out to every
-- sub-role, and any role whose result matches its own defaults has its DB
-- entry cleared instead (the DB only stores deviations).
local function OnApply(f)
    if f.isCreateMode then
        local name = strtrim(f.nameEdit:GetText() or "")
        if name == "" then
            WhoDoesWhat:Print("Enter a name for the new role before saving.")
            f.nameEdit:SetFocus()
            return
        end
        if not f.selectedClass then
            WhoDoesWhat:Print("Select a class for the new role before saving.")
            return
        end
        local role = WhoDoesWhat:CreateCustomRole(name, f.selectedClass, GetRoleControls(f))
        if not role then return end -- storage rejected it and said why
        WhoDoesWhat:SetRoleCustomization(role.id, f.buffOrder, f.allowedCount)
        WhoDoesWhat:LogOperation("Custom role '" .. name .. "' created under " .. f.selectedClass .. ".")
    else
        local role = f.currentRole
        if not role then return end

        if role.isCustom then
            local name = strtrim(f.nameEdit:GetText() or "")
            if name == "" then
                WhoDoesWhat:Print("Enter a name for the role before saving.")
                f.nameEdit:SetFocus()
                return
            end
            if not WhoDoesWhat:UpdateCustomRole(role.id, name, GetRoleControls(f)) then
                return -- storage rejected it and said why
            end
            WhoDoesWhat:SetRoleCustomization(role.id, f.buffOrder, f.allowedCount)
            WhoDoesWhat:LogOperation("Custom role '" .. name .. "' saved.")
        else
            local targets = role.allSubRoles or { role.id }
            local customized = 0
            for _, id in ipairs(targets) do
                if WhoDoesWhat:SetRoleCustomization(id, f.buffOrder, f.allowedCount) then
                    customized = customized + 1
                end
            end

            if customized == 0 then
                WhoDoesWhat:LogOperation("Settings match the defaults - saved customizations cleared.")
            elseif #targets > 1 then
                WhoDoesWhat:LogOperation("Customizations saved for " .. #targets .. " roles.")
            else
                WhoDoesWhat:LogOperation("Customizations saved for " .. role.name .. ".")
            end
        end
    end
    CloseAndRefresh(f)
end


-- The context-dependent secondary button:
--   create mode    "Cancel"            close, discarding the unmade role
--   custom role    "Delete"            remove the role entirely, close
--   standard role  "Reset to Defaults" immediately clear the saved
--                                      customizations (category: all
--                                      sub-roles) and close
local function OnSecondary(f)
    if f.isCreateMode then
        f:Hide()
    elseif f.currentRole and f.currentRole.isCustom then
        WhoDoesWhat:LogOperation("Custom role '" .. f.currentRole.name .. "' deleted.")
        WhoDoesWhat:DeleteCustomRole(f.currentRole.id)
        CloseAndRefresh(f)
    elseif f.currentRole then
        WhoDoesWhat:ClearRoleCustomization(f.currentRole.id)
        WhoDoesWhat:LogOperation(f.currentRole.name .. " reset to defaults.")
        CloseAndRefresh(f)
    end
end


-- Build the customize window once (chrome + placeholder widgets we update per
-- role). Reused across opens.
local function EnsureCustomizeFrame()
    if customizeFrame then return customizeFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatCustomizeFrame", FRAME_W, FRAME_H, "")
    local top = f.titleBarHeight + 14

    -- Large class icon, top-left ("?" in create mode until a class is picked)
    local classIcon = f:CreateTexture(nil, "ARTWORK")
    classIcon:SetSize(CLASS_ICON_SIZE, CLASS_ICON_SIZE)
    classIcon:SetPoint("TOPLEFT", 16, -top)
    f.classIcon = classIcon

    -- Smaller spec icon overlapping the class icon's bottom-right: the spec
    -- icon for built-in roles, the "?" for custom roles.
    local specIcon = f:CreateTexture(nil, "OVERLAY")
    specIcon:SetSize(SPEC_ICON_SIZE, SPEC_ICON_SIZE)
    specIcon:SetPoint("BOTTOMRIGHT", classIcon, "BOTTOMRIGHT", 5, -5)
    f.specIcon = specIcon

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
                -- Preview: big icon becomes the class, "?" moves to the spec slot.
                f.classIcon:SetTexture(classInfo.classIcon)
                f.specIcon:SetTexture(QUESTION_MARK_ICON)
                f.specIcon:Show()
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
    nameEdit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then MarkDirty(f) end
    end)
    nameEdit:Hide()
    f.nameEdit = nameEdit

    -- Centered list heading with a bit of padding above it
    local buffHeading = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    buffHeading:SetPoint("TOP", f, "TOP", 0, -(top + CLASS_ICON_SIZE + 16))
    buffHeading:SetText("Paladin Buff Priority")
    f.buffHeading = buffHeading

    -- Buff priority rows: number, icon, spell name, and up/down arrows, with an
    -- END divider inserted between allowed and banned blessings at render time.
    local canonical = WhoDoesWhat.CanonicalBuffOrder
    f.buffOrder = { unpack(canonical) }
    f.allowedCount = #canonical
    f.buffRows = {}
    local listTop = top + CLASS_ICON_SIZE + 36
    f.buffListTop = listTop
    local divider = CreateFrame("Frame", nil, f)
    divider:SetSize(FRAME_W - 32, BUFF_ROW_H)
    local dividerLabel = divider:CreateFontString(nil, "BACKGROUND", "GameFontNormalLarge")
    dividerLabel:SetPoint("TOP")
    dividerLabel:SetPoint("BOTTOM")
    dividerLabel:SetJustifyH("CENTER")
    dividerLabel:SetText("END")
    dividerLabel:SetTextColor(1, 0.2, 0.2)
    local dividerLeft = divider:CreateTexture(nil, "BACKGROUND")
    dividerLeft:SetHeight(8)
    dividerLeft:SetPoint("LEFT", 3, 0)
    dividerLeft:SetPoint("RIGHT", dividerLabel, "LEFT", -5, 0)
    dividerLeft:SetTexture(137057) -- Interface\Tooltips\UI-Tooltip-Border
    dividerLeft:SetTexCoord(0.81, 0.94, 0.5, 1)
    dividerLeft:SetVertexColor(1, 0.2, 0.2)
    local dividerRight = divider:CreateTexture(nil, "BACKGROUND")
    dividerRight:SetHeight(8)
    dividerRight:SetPoint("RIGHT", -3, 0)
    dividerRight:SetPoint("LEFT", dividerLabel, "RIGHT", 5, 0)
    dividerRight:SetTexture(137057)
    dividerRight:SetTexCoord(0.81, 0.94, 0.5, 1)
    dividerRight:SetVertexColor(1, 0.2, 0.2)
    f.buffDivider = divider
    for i = 1, #canonical do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(FRAME_W - 32, BUFF_ROW_H)

        -- Up/down arrows on the left, then number, icon, and name.
        local upBtn = CreateArrowButton(row, "Up")
        upBtn:SetPoint("LEFT", 0, 0)
        upBtn:SetScript("OnClick", function() MoveBuff(f, i, -1) end)
        row.upBtn = upBtn

        local downBtn = CreateArrowButton(row, "Down")
        downBtn:SetPoint("LEFT", upBtn, "RIGHT", 2, 0)
        downBtn:SetScript("OnClick", function() MoveBuff(f, i, 1) end)
        row.downBtn = downBtn

        local index = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        index:SetPoint("LEFT", downBtn, "RIGHT", 8, 0)
        index:SetWidth(22)
        index:SetJustifyH("LEFT")
        row.index = index

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(BUFF_ICON_SIZE, BUFF_ICON_SIZE)
        icon:SetPoint("LEFT", index, "RIGHT", 2, 0)
        row.icon = icon

        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        label:SetPoint("LEFT", icon, "RIGHT", 8, 0)
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

    -- Group-role row (custom roles / create mode only). Every custom role has
    -- one -- there is no "unassigned" any more, so this is a plain label +
    -- dropdown rather than an opt-in checkbox.
    local optionsTop = listTop + (#canonical + 1) * BUFF_ROW_H + 8

    local assignLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    assignLabel:SetPoint("TOPLEFT", 18, -(optionsTop + 6))
    assignLabel:SetText("Group role")
    f.assignLabel = assignLabel

    local roleDropdown = CreateFrame("Frame", "WhoDoesWhatRoleDropDown", f, "UIDropDownMenuTemplate")
    -- UIDropDownMenu has ~15px of transparent left padding; pull it toward the label.
    roleDropdown:SetPoint("LEFT", assignLabel, "RIGHT", -8, -2)
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
                MarkDirty(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.roleDropdown = roleDropdown

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


-- Show/hide the custom-role widgets and size the window for the mode.
local function SetCustomControlsShown(f, shown)
    f.assignLabel:SetShown(shown)
    f.roleDropdown:SetShown(shown)
    f:SetHeight(shown and FRAME_H_CUSTOM or FRAME_H)
end


-- Open the single-role customizer for the given role id. Loads the role's
-- effective buff order (saved customization or default); edits are live in the
-- window only until the primary button persists them and closes (a category
-- applies to all its allSubRoles). Custom roles get an editable name, the
-- assign-role controls, and Save/Delete buttons.
function WhoDoesWhat:OpenCustomizer(roleId)

    local classInfo, role = self:FindRoleById(roleId)
    if not role then
        self:Print("OpenCustomizer: unknown role id '" .. tostring(roleId) .. "'")
        return
    end

    local f = EnsureCustomizeFrame()
    f.isCreateMode = false
    f.dirty = false
    f.currentRole = role
    f.selectedClass = nil
    f.classDropdown:Hide()

    if role.allSubRoles then
        f.titleText:SetText("Editing Category (" .. #role.allSubRoles .. " roles)")
    elseif role.isCustom then
        f.titleText:SetText("Editing Custom Role")
    else
        f.titleText:SetText("Editing Role")
    end

    -- Big class icon + class-colored class name
    f.classIcon:SetTexture(classInfo.classIcon)
    f.className:SetText("|cff" .. classInfo.colorHex .. classInfo.name .. "|r")
    f.className:Show()

    -- Role name: a static label for built-in roles, an editable box for custom
    -- ones (renamed on Save).
    if role.isCustom then
        f.roleName:Hide()
        f.nameEdit:SetText(role.name)
        f.nameEdit:Show()
    else
        f.nameEdit:Hide()
        f.roleName:SetText("|cff" .. classInfo.colorHex .. role.name .. "|r")
        f.roleName:Show()
    end

    -- Spec icon overlay: the role's own icon (custom roles' is the "?");
    -- categories have no single spec.
    if role.allSubRoles then
        f.specIcon:Hide()
    else
        f.specIcon:SetTexture(role.icon)
        f.specIcon:Show()
    end

    -- Load the full effective order and its divider position (a category reads
    -- from its first sub-role). Copied so the in-window arrows don't mutate the
    -- saved/default tables; nothing is persisted until Save/Apply.
    local order
    order, f.allowedCount = self:GetEffectiveBuffSetup(role.id)
    f.buffOrder = { unpack(order) }
    RenderBuffRows(f)

    -- Custom roles: assign-role controls + Save/Delete.
    SetCustomControlsShown(f, role.isCustom and true or false)
    if role.isCustom then
        SetRoleControls(f, role.wowRole)
        f.applyBtn:SetText("Save")
        f.secondaryBtn:SetText("Delete")
        f.secondaryBtn:SetWidth(70)
    else
        f.applyBtn:SetText("Apply")
        f.secondaryBtn:SetText("Reset to Defaults")
        f.secondaryBtn:SetWidth(120)
    end

    UpdateCustomStatus(f)

    self:LogUiBuilding("Opening customizer for " .. classInfo.name .. " / " .. role.name)
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
    f.dirty = false
    f.currentRole = nil
    f.selectedClass = nil

    f.titleText:SetText("New Custom Role")
    f.classIcon:SetTexture(QUESTION_MARK_ICON)
    f.specIcon:Hide()
    f.className:Hide()
    f.roleName:Hide()

    UIDropDownMenu_SetSelectedValue(f.classDropdown, nil)
    UIDropDownMenu_SetText(f.classDropdown, "Select class...")
    f.classDropdown:Show()

    f.nameEdit:SetText("")
    f.nameEdit:Show()

    f.buffOrder = { unpack(self.CanonicalBuffOrder) }
    f.allowedCount = #f.buffOrder
    RenderBuffRows(f)

    SetCustomControlsShown(f, true)
    SetRoleControls(f, "dps") -- assign defaults to on, DPS
    f.applyBtn:SetText("Save")
    f.secondaryBtn:SetText("Cancel")
    f.secondaryBtn:SetWidth(70)

    UpdateCustomStatus(f)

    self:LogUiBuilding("Opening customizer to create a new custom role.")
    f:Show()
    f:Raise()
    f.nameEdit:SetFocus()
end
