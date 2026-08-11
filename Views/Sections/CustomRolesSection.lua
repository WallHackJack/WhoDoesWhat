local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Custom Roles section: every role this raid has changed, and the only place a
-- blessing order deviates from the defaults.
--
--   Custom Roles                              [Add (+)] [gear] [x]
--   [class icon] Sunder Warrior                DPS       [gear] [x]
--   [class icon] Mage DPS (default x3)         DPS       [gear] [x]
--
-- Two kinds of row, and Add (+) offers both:
--
--   custom role   one of your own, published out of the Roles window's library.
--                 A custom role's definition lives in one player's profile and
--                 the board only ever syncs role IDS, so until it is here every
--                 other client resolves it to nothing -- canonical blessing
--                 order, guarantee rules scoped by group role skipping that
--                 raider, a custom tank not reading as a tank. Assigning
--                 somebody one publishes it the same way
--                 (EnsureRoleIsShareable).
--   override      a built-in role or category, retuned for this raid. Built-in
--                 roles can't be edited any more -- there is no per-profile
--                 store to edit them in -- so changing one means putting it
--                 here. A category override fans out to every sub-role, and a
--                 sub-role overridden in its own right wins over it.
--
-- Both are board state: same permission as any assignment, same broadcast,
-- cleared on leave. Removal differs, though, and that is why the rows say which
-- kind they are. Removing a custom role deletes the raid's only definition of
-- it, so everyone assigned to it is cleared and the row confirms first with the
-- count. Removing an override just puts a built-in role back on its defaults --
-- it still exists, nobody loses anything, no prompt.
--
-- The header strip's gear opens the Roles window. A gear rather than a label so
-- it lands in the same column as the per-role gears and reads as the same
-- action one level up: a row edits one shared role, the header opens the
-- library they come from. It stays visible for read-only viewers -- those are
-- their own local roles -- and takes the edge slot when the edit buttons hide.

local K = WhoDoesWhat.SectionKit

local ROW_H = K.ROW_H

local GEAR_ICON = "Interface\\Buttons\\UI-OptionsButton"

local Refresh -- forward declaration; CreateCustomRoleRow is defined above it

local addCustomRoleMenu

-- Anything coming off this list changes what the whole raid computes, so every
-- removal asks first -- the message carries the whole sentence rather than the
-- dialog holding a fixed tail, because the three cases say different things.
-- The `data` passed to StaticPopup_Show is the function to run on Yes, matching
-- SectionKit's clear-section dialog.
StaticPopupDialogs["WHODOESWHAT_REMOVE_CUSTOM_ROLE"] = {
    text = "%s",
    button1 = "Remove",
    button2 = "Cancel",
    OnAccept = function(self) self.data() end,
    timeout = 0,
    hideOnEscape = true,
    preferredIndex = 3, -- keep Blizzard's default dialog slots free (taint)
}

local function GetRaidCustomRoles()
    return WhoDoesWhat:GetRaidCustomRoles()
end

local function ClassInfoByName(className)
    for _, ci in ipairs(WhoDoesWhat.Classes) do
        if ci.name == className then return ci end
    end
    return nil
end

-- What a board entry looks like. A published custom role carries its own
-- identity; an override carries only an id, so everything shown for one comes
-- from the built-in role or category it names.
local function RoleDisplay(def)
    if WhoDoesWhat:IsRaidCustomRoleDef(def) then
        local classInfo = ClassInfoByName(def.class)
        return {
            classInfo = classInfo,
            name = tostring(def.name),
            icon = def.icon or (classInfo and classInfo.classIcon) or K.CUSTOM_TARGET_ICON,
            wowRole = def.wowRole,
        }
    end
    local raw = WhoDoesWhat.RolesAndCategories[def.id]
    local classInfo, role = WhoDoesWhat:FindRoleById(def.id)
    if not raw or not role then
        return { name = tostring(def.id), icon = K.CUSTOM_TARGET_ICON, override = true }
    end
    -- A category has no icon or group role of its own worth showing; borrow
    -- the sub-role its defaults already come from, same as the customizer.
    local source = raw.allSubRoles
        and (WhoDoesWhat.RolesAndCategories[raw.allSubRoles[1]] or role) or role
    return {
        classInfo = classInfo,
        name = raw.name,
        icon = raw.allSubRoles and (classInfo and classInfo.classIcon) or source.icon,
        wowRole = source.wowRole,
        override = true,
        -- Only worth saying for a real category; a one-role category reads as
        -- the role it wraps.
        subRoles = raw.allSubRoles and #raw.allSubRoles > 1 and #raw.allSubRoles or nil,
    }
end

-- The name wears its class's colour, same as every other role name in the UI.
-- An override says so in grey after it: the two kinds behave differently on
-- removal, and "Frost" could just as easily be somebody's custom role.
local function RoleName(display)
    local name = display.classInfo
        and ("|cff" .. display.classInfo.colorHex .. display.name .. "|r")
        or display.name
    if not display.override then return name end
    return name .. " |cff909090(default"
        .. (display.subRoles and (" x" .. display.subRoles) or "") .. ")|r"
end

-- The row's detail column: just the group role, since the class is already
-- carried twice over by the row's icon and the colour of its name. Singular --
-- it names THIS role's group role, not a set of raiders.
local function RoleDetail(display)
    local meta = WhoDoesWhat.BasicWowRoles[display.wowRole]
    return WhoDoesWhat:GetWowRoleIconMarkup(display.wowRole, 14) .. " "
        .. (meta and meta.name or "?")
end

local function ConfirmRemoval(message, Remove)
    StaticPopup_Show("WHODOESWHAT_REMOVE_CUSTOM_ROLE", message, nil, Remove)
end

-- Confirm taking one entry off the board, then do it. Public because the role
-- editor's Remove button is the same action from a different window, and the
-- two must not drift on what they warn about.
--
-- Three cases, because they cost different things: an override reverts a
-- built-in role and costs nobody anything, an unused custom role just
-- disappears, and a custom role somebody holds takes their assignment with it.
function WhoDoesWhat:ConfirmRemoveRaidRole(roleId, OnRemoved)
    local def = self:FindRaidCustomRole(roleId)
    if not def then return end
    local name = RoleName(RoleDisplay(def))
    local message
    if not self:IsRaidCustomRoleDef(def) then
        message = "Stop overriding " .. name .. "?\n\nIt goes back to its"
            .. " default blessing order. Nobody loses their role."
    else
        local users = self:PlayersAssignedToRole(roleId)
        message = "Remove " .. name .. " from the raid?\n\n"
            .. (#users > 0
                and (#users .. (#users == 1 and " raider is" or " raiders are")
                    .. " assigned to it and will be set back to no role. ")
                or "")
            .. "Your own copy in the Roles window is not deleted."
    end
    ConfirmRemoval(message, function()
        self:RemoveRaidCustomRole(roleId)
        if OnRemoved then OnRemoved() end
    end)
end

local function AddToBoard(Publish, roleId)
    if not WhoDoesWhat:RequireEditPermission() then return end
    CloseDropDownMenus()
    if not Publish(WhoDoesWhat, roleId) then return end
    WhoDoesWhat:RefreshMainAssignmentsView()
    WhoDoesWhat:RefreshBuffingGridView()
end

-- Level 1's custom-role list is the local library (classInfo.libraryRoles), not
-- what role pickers currently offer: in a group those are already the published
-- ones, which is precisely the set this menu exists to grow.
local function AddLibraryRoles(level)
    local any = false
    for _, ci in ipairs(WhoDoesWhat.Classes) do
        for _, role in ipairs(ci.libraryRoles or {}) do
            any = true
            local published = WhoDoesWhat:FindRaidCustomRole(role.id) ~= nil
            local info = UIDropDownMenu_CreateInfo()
            info.text = WhoDoesWhat:RoleIconMarkup(role.icon, 14) .. " |cff"
                .. ci.colorHex .. role.name .. "|r"
                .. (published and " |cff909090(already added)|r" or "")
            info.notCheckable = true
            info.disabled = published
            info.func = function()
                AddToBoard(WhoDoesWhat.PublishCustomRole, role.id)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end
    return any
end

-- Level 3 of the override branch: one class's categories and roles. Categories
-- come first and are offered whole -- overriding "Mage DPS" retunes all three
-- specs at once -- with the individual roles below for the finer cut.
--
-- An entry already covered by an override is disabled and says which: a role
-- inside an overridden category is already following it, and overriding the
-- role as well would only be confusing about which one wins (the role does).
local function AddOverridableRoles(level, className)
    local classInfo
    for _, ci in ipairs(WhoDoesWhat.Classes) do
        if ci.name == className then
            classInfo = ci
            break
        end
    end
    if not classInfo then return end
    local function AddRoleItem(role, indent)
        local onBoard = WhoDoesWhat:FindRaidCustomRole(role.id) ~= nil
        local covered = not onBoard and WhoDoesWhat:IsRoleOverridden(role.id)
        local info = UIDropDownMenu_CreateInfo()
        info.text = indent .. WhoDoesWhat:RoleIconMarkup(role.icon, 14) .. " |cff"
            .. classInfo.colorHex .. role.name .. "|r"
            .. (onBoard and " |cff909090(already added)|r"
                or (covered and " |cff909090(covered by a category)|r" or ""))
        info.notCheckable = true
        info.disabled = onBoard or covered
        info.func = function()
            AddToBoard(WhoDoesWhat.PublishRoleOverride, role.id)
        end
        UIDropDownMenu_AddButton(info, level)
    end
    for _, category in ipairs(classInfo.categories or {}) do
        AddRoleItem(category, "")
    end
    for _, role in ipairs(classInfo.roles) do
        AddRoleItem(role, classInfo.categories and "   " or "")
    end
end

local function AddOverrideClasses(level)
    for _, ci in ipairs(WhoDoesWhat.Classes) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = "|cff" .. ci.colorHex .. ci.name .. "|r"
        info.notCheckable = true
        info.hasArrow = true
        info.keepShownOnClick = true
        info.value = { override = ci.name }
        UIDropDownMenu_AddButton(info, level)
    end
end

local function InitAddCustomRoleMenu(_, level)
    level = level or 1
    if level == 1 then
        if not AddLibraryRoles(level) then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "|cff909090You have no custom roles|r"
            info.notCheckable = true
            info.disabled = true
            UIDropDownMenu_AddButton(info, level)
        end
        K.AddDropdownDivider(level)

        -- Built-in roles can't be edited in place, so retuning one for the raid
        -- is putting an override of it on this list.
        local override = UIDropDownMenu_CreateInfo()
        override.text = "Override a default role"
        override.notCheckable = true
        override.hasArrow = true
        override.keepShownOnClick = true
        override.value = "override"
        UIDropDownMenu_AddButton(override, level)

        local create = UIDropDownMenu_CreateInfo()
        create.text = "Create a new custom role..."
        create.notCheckable = true
        create.func = function()
            CloseDropDownMenus()
            WhoDoesWhat:OpenCustomizerForNewRole()
        end
        UIDropDownMenu_AddButton(create, level)
        return
    end

    local value = UIDROPDOWNMENU_MENU_VALUE
    if value == "override" then
        AddOverrideClasses(level)
    elseif type(value) == "table" and value.override then
        AddOverridableRoles(level, value.override)
    end
end

local function OpenAddCustomRoleMenu(button)
    if not addCustomRoleMenu then
        addCustomRoleMenu = CreateFrame("Frame", "WhoDoesWhatAddCustomRoleMenu",
            UIParent, "UIDropDownMenuTemplate")
    end
    UIDropDownMenu_Initialize(addCustomRoleMenu, InitAddCustomRoleMenu, "MENU")
    ToggleDropDownMenu(1, nil, addCustomRoleMenu, button, 0, 0)
end

-- A gear button. Used for both "edit this role" on a row and "edit your role
-- library" in the header strip, so the two read as the same kind of action and
-- sit in the same column down the right edge of the box.
local function CreateGearButton(parent, tooltipTitle, tooltipText, OnClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(K.MAIL_BTN_SIZE, K.MAIL_BTN_SIZE)
    btn:SetText("")
    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(GEAR_ICON)
    btn:SetScript("OnClick", OnClick)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tooltipTitle, 1, 1, 1)
        GameTooltip:AddLine(tooltipText, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

-- Build pooled custom-role row #index. Position comes from Refresh; the buttons
-- look their role up by index at click time.
local function CreateCustomRoleRow(f, index)
    local state = f.customRolesSection
    local row = CreateFrame("Frame", nil, state.box)
    row:SetFrameLevel(state.box:GetFrameLevel() + 1)
    row:SetSize(state.box:GetWidth() - K.BOX_PAD * 2, ROW_H)
    K.AddRowBackground(row, index)

    local delBtn = K.CreateCloseButton(row)
    delBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    delBtn:SetScript("OnClick", function()
        if not WhoDoesWhat:RequireEditPermission() then return end
        local def = GetRaidCustomRoles()[index]
        if not def then return end
        local roleId = def.id
        WhoDoesWhat:ConfirmRemoveRaidRole(roleId, function()
            -- Through the main refresh, not the section-local one: the box
            -- shrinks by a row and the collapsed view has to refit.
            WhoDoesWhat:RefreshMainAssignmentsView()
            WhoDoesWhat:RefreshBuffingGridView()
        end)
    end)
    delBtn:SetScript("OnEnter", function(self)
        local def = GetRaidCustomRoles()[index]
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove from the raid", 1, 1, 1)
        if def and not WhoDoesWhat:IsRaidCustomRoleDef(def) then
            GameTooltip:AddLine("Put this role back on its default blessing"
                .. " order. It is a built-in role, so nobody loses their"
                .. " assignment.", 0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine("Everyone stops seeing this role, and anyone"
                .. " assigned to it goes back to no role. Your own copy in the"
                .. " Roles window is not deleted.", 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    delBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.delBtn = delBtn

    local editBtn = CreateGearButton(row, "Edit this role",
        "Change the blessing order the whole raid uses for it -- plus the name,"
        .. " icon and group role when it is a custom role of your own.",
        function()
            local def = GetRaidCustomRoles()[index]
            if def then WhoDoesWhat:OpenCustomizer(def.id, true) end
        end)
    editBtn:SetPoint("RIGHT", delBtn, "LEFT", -2, 0)
    row.editBtn = editBtn

    local detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detail:SetPoint("RIGHT", editBtn, "LEFT", -6, 0)
    detail:SetJustifyH("RIGHT")
    detail:SetWordWrap(false)
    row.detail = detail

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", row, "LEFT", 4, 0)
    text:SetPoint("RIGHT", detail, "LEFT", -6, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    row.text = text

    state.customRows[index] = row
    return row
end

function Refresh(f) -- forward declared above
    local state = f.customRolesSection
    local editable = WhoDoesWhat:CanEditAssignments()
    local customRoles = GetRaidCustomRoles()

    -- The edit buttons hide for read-only viewers; the library gear does not --
    -- it edits their own local roles, which is nobody else's business.
    -- LayoutHeaderChain then slides it out to the edge on its own.
    state.addBtn:SetShown(editable)
    state.clearBtn:SetShown(editable)
    state.clearBtn:SetEnabled(#customRoles > 0)
    K.LayoutHeaderChain(state.headerChain)

    local rowsTop = K.BOX_PAD + K.SECTION_TITLE_H
    for i, def in ipairs(customRoles) do
        local row = state.customRows[i] or CreateCustomRoleRow(f, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", K.BOX_PAD, -(rowsTop + (i - 1) * ROW_H))
        row:Show()
        local display = RoleDisplay(def)
        row.text:SetText(WhoDoesWhat:RoleIconMarkup(display.icon, K.ROW_ICON_SIZE)
            .. " " .. RoleName(display))
        row.detail:SetText(RoleDetail(display))
        row.editBtn:SetShown(editable)
        row.delBtn:SetShown(editable)
        -- The detail column hugs the buttons, or the row edge when they hide
        -- in read-only mode, so it never leaves a hole at the right.
        row.detail:ClearAllPoints()
        if editable then
            row.detail:SetPoint("RIGHT", row.editBtn, "LEFT", -6, 0)
        else
            row.detail:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        end
    end
    for i = #customRoles + 1, #state.customRows do
        state.customRows[i]:Hide()
    end

    -- CreateEmptyHint already anchors itself at the top of the rows area.
    state.emptyHint:SetShown(#customRoles == 0)
    local rowsH = (#customRoles > 0) and (#customRoles * ROW_H) or K.DYN_EMPTY_H

    state.box:SetHeight(rowsTop + rowsH + K.BOX_PAD)
    K.UpdateContentHeight(f)
end

local function Build(f, content)
    local chrome = K.CreateSectionChrome(f, content, {
        title = "Custom Roles",
        column = K.COL_LEFT,
    })
    local box = chrome.box

    local clearBtn = K.CreateCloseButton(box, nil, 0.25)
    clearBtn:SetScript("OnClick", function()
        if not WhoDoesWhat:RequireEditPermission() then return end
        -- One count across the whole list rather than a name each: the prompt
        -- has to say how many people this costs, not enumerate the roles.
        -- Overrides cost nobody their role, so only custom entries are counted.
        local list = GetRaidCustomRoles()
        local affected = 0
        for _, def in ipairs(list) do
            if WhoDoesWhat:IsRaidCustomRoleDef(def) then
                affected = affected + #WhoDoesWhat:PlayersAssignedToRole(def.id)
            end
        end
        local message = "Remove all " .. #list .. " role"
            .. (#list == 1 and "" or "s") .. " from the raid?\n\n"
            .. "Overridden roles go back to their defaults."
            .. (affected > 0
                and (" " .. affected
                    .. (affected == 1 and " raider is" or " raiders are")
                    .. " assigned to a custom role and will be set back to no"
                    .. " role.")
                or "")
        ConfirmRemoval(message, function()
            local removed = WhoDoesWhat:ClearRaidCustomRoles()
            WhoDoesWhat:LogOperation("Custom Roles: " .. removed .. " role"
                .. (removed == 1 and "" or "s") .. " removed from the raid.")
            WhoDoesWhat:RefreshMainAssignmentsView()
            WhoDoesWhat:RefreshBuffingGridView()
        end)
    end)
    clearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self:IsEnabled() then
            GameTooltip:SetText("Clear the list", 1, 1, 1)
            GameTooltip:AddLine("Put every default role back on its defaults and"
                .. " take every custom role off the raid, clearing anyone"
                .. " assigned to one. Your own copies are not deleted.",
                0.8, 0.8, 0.8, true)
        else
            GameTooltip:SetText("Nothing to clear", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    K.ChainHeaderButton(chrome, clearBtn)

    -- Chained between Add (+) and the clear-all X, which puts it in the same
    -- column as the rows' own gears: one gear per role below, and above them the
    -- gear for the library those roles are published from.
    local rolesBtn = CreateGearButton(box, "Roles",
        "Every role WDW knows, plus your own custom ones. Built-in roles are a"
        .. " read-only reference there -- change one by overriding it here.",
        function() WhoDoesWhat:OpenAllRolesView() end)
    rolesBtn:SetPoint("RIGHT", clearBtn, "LEFT", -2, 0) -- placeholder; see LayoutHeaderChain
    K.ChainHeaderButton(chrome, rolesBtn)

    local addBtn
    addBtn = K.AddHeaderTextButton(box, rolesBtn, "Add (+)", "Add a role",
        "Share one of your custom roles with the raid, or override a built-in"
        .. " role or category to retune its blessing order.", function()
            if not WhoDoesWhat:RequireEditPermission() then return end
            OpenAddCustomRoleMenu(addBtn)
        end)
    K.ChainHeaderButton(chrome, addBtn)

    local emptyHint = K.CreateEmptyHint(box)
    emptyHint:SetText("Every role is on its defaults")

    f.customRolesSection = {
        box = box,
        headerChain = chrome.headerChain,
        addBtn = addBtn,
        rolesBtn = rolesBtn,
        clearBtn = clearBtn,
        emptyHint = emptyHint,
        customRows = {},
    }
end

WhoDoesWhat.SectionViews.CustomRoles = { Build = Build, Refresh = Refresh }
