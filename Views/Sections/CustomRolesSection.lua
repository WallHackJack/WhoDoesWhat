local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Custom Roles section. The raid's shared custom-role list, leading the left
-- column above Paladin Buffs:
--
--   Custom Roles                            [Add (+)] [gear] [x]
--   [class icon] Sunder Warrior              DPS       [gear] [x]
--
-- The header strip's gear opens the local role library those roles are
-- published from. A gear rather than a "Roles" label so it lands in the same
-- column as the per-role gears and reads as the same action one level up: a row
-- edits one shared role, the header edits the library they come from. It stays
-- visible for read-only viewers -- those are their own local roles -- and takes
-- the edge slot when the edit buttons hide.
--
-- A custom role is a role definition living in one player's profile, and the
-- board only ever syncs role IDS. Until the definition is on this list, every
-- other client resolves an assigned custom role to nothing and quietly falls
-- back to the canonical blessing order -- which is how one raid ends up with
-- several different paladin buff plans. Adding a role here publishes the
-- definition (name, class, group role, icon, buff order and divider) as board state:
-- same permission as any assignment, same broadcast, cleared on leave.
--
-- Add (+) offers the local Customize Role Defaults library; assigning somebody
-- a custom role publishes it the same way (EnsureRoleIsShareable). The gear
-- edits the RAID's copy -- the library template it came from is left alone, so
-- one raid night's edits don't rewrite what you bring to the next.
--
-- Removing a role clears it from everyone assigned to it, because the
-- alternative is leaving them holding an id nobody can resolve -- the state
-- this list exists to prevent. A row that is in use confirms first and says how
-- many raiders it costs.

local K = WhoDoesWhat.SectionKit

local ROW_H = K.ROW_H

local GEAR_ICON = "Interface\\Buttons\\UI-OptionsButton"
local WOW_ROLE_LABELS = { tank = "Tanks", healer = "Healers", dps = "DPS" }

local Refresh -- forward declaration; CreateCustomRoleRow is defined above it

local addCustomRoleMenu

-- Removing a shared role un-assigns everyone on it, so a row that is in use
-- asks first. The `data` passed to StaticPopup_Show is the function to run on
-- Yes, matching SectionKit's clear-section dialog.
StaticPopupDialogs["WHODOESWHAT_REMOVE_CUSTOM_ROLE"] = {
    text = "%s\n\nThey will be set back to no role.",
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

-- A custom role wears its owning class's colour, same as every other role name
-- in the UI.
local function CustomRoleName(def)
    local classInfo = ClassInfoByName(def.class)
    local name = tostring(def.name)
    return classInfo and ("|cff" .. classInfo.colorHex .. name .. "|r") or name
end

-- The role's picked icon, or its class icon -- matching what
-- PopulateRolesAndCategories registers for the same role.
local function CustomRoleIcon(def)
    if def.icon then return def.icon end
    local classInfo = ClassInfoByName(def.class)
    return classInfo and classInfo.classIcon or K.CUSTOM_TARGET_ICON
end

-- The row's detail column: just the group role, since the class is already
-- carried twice over by the row's icon and the colour of its name.
local function CustomRoleDetail(def)
    return WhoDoesWhat:GetWowRoleIconMarkup(def.wowRole, 14) .. " "
        .. (WOW_ROLE_LABELS[def.wowRole] or "?")
end

-- "3 raiders are assigned to Sunder Warrior", or nil when nobody is on it.
local function InUseText(def)
    local users = WhoDoesWhat:PlayersAssignedToRole(def.id)
    if #users == 0 then return nil end
    return #users .. (#users == 1 and " raider is" or " raiders are")
        .. " assigned to " .. CustomRoleName(def) .. "."
end

-- Run `Remove` straight away when nothing is assigned to the role(s), or after
-- a confirm naming who loses their assignment.
local function ConfirmRemoval(warning, Remove)
    if not warning then
        Remove()
        return
    end
    StaticPopup_Show("WHODOESWHAT_REMOVE_CUSTOM_ROLE", warning, nil, Remove)
end

local function AddCustomRole(roleId)
    if not WhoDoesWhat:RequireEditPermission() then return end
    CloseDropDownMenus()
    if not WhoDoesWhat:PublishCustomRole(roleId) then return end
    WhoDoesWhat:RefreshMainAssignmentsView()
    WhoDoesWhat:RefreshBuffingGridView()
end

-- The menu lists the local library (classInfo.libraryRoles), not what role
-- pickers currently offer: in a group those are already the published ones,
-- which is precisely the set this menu exists to grow.
local function InitAddCustomRoleMenu(_, level)
    level = level or 1
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
            info.func = function() AddCustomRole(role.id) end
            UIDropDownMenu_AddButton(info, level)
        end
    end
    if not any then
        local info = UIDropDownMenu_CreateInfo()
        info.text = "|cff909090You have no custom roles|r"
        info.notCheckable = true
        info.disabled = true
        UIDropDownMenu_AddButton(info, level)
    end
    K.AddDropdownDivider(level)
    local create = UIDropDownMenu_CreateInfo()
    create.text = "Create a new custom role..."
    create.notCheckable = true
    create.func = function()
        CloseDropDownMenus()
        WhoDoesWhat:OpenCustomizerForNewRole()
    end
    UIDropDownMenu_AddButton(create, level)
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
        ConfirmRemoval(InUseText(def), function()
            WhoDoesWhat:RemoveRaidCustomRole(roleId)
            -- Through the main refresh, not the section-local one: the box
            -- shrinks by a row and the collapsed view has to refit.
            WhoDoesWhat:RefreshMainAssignmentsView()
            WhoDoesWhat:RefreshBuffingGridView()
        end)
    end)
    delBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove from the raid", 1, 1, 1)
        GameTooltip:AddLine("Everyone stops seeing this role, and anyone assigned"
            .. " to it goes back to no role. Your own copy in Customize Role"
            .. " Defaults is not deleted.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    delBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.delBtn = delBtn

    local editBtn = CreateGearButton(row, "Edit this role",
        "Change the name, icon, group role, and blessing order the whole raid"
        .. " uses for it.", function()
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
        row.text:SetText(WhoDoesWhat:RoleIconMarkup(CustomRoleIcon(def),
            K.ROW_ICON_SIZE) .. " " .. CustomRoleName(def))
        row.detail:SetText(CustomRoleDetail(def))
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
        local affected = 0
        for _, def in ipairs(GetRaidCustomRoles()) do
            affected = affected + #WhoDoesWhat:PlayersAssignedToRole(def.id)
        end
        local warning = affected > 0 and (affected
            .. (affected == 1 and " raider is" or " raiders are")
            .. " assigned to the raid's custom roles.") or nil
        ConfirmRemoval(warning, function()
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
            GameTooltip:SetText("Clear custom roles", 1, 1, 1)
            GameTooltip:AddLine("Take every custom role off the raid's list."
                .. " Anyone assigned to one goes back to no role. Your own copies"
                .. " are not deleted.", 0.8, 0.8, 0.8, true)
        else
            GameTooltip:SetText("No custom roles to clear", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    K.ChainHeaderButton(chrome, clearBtn)

    -- Chained between Add (+) and the clear-all X, which puts it in the same
    -- column as the rows' own gears: one gear per role below, and above them the
    -- gear for the library those roles are published from.
    local rolesBtn = CreateGearButton(box, "Customize Role Defaults",
        "Your own library of role buff orders and custom roles. Local to you"
        .. " until a custom role is added to the raid.",
        function() WhoDoesWhat:OpenAllRolesView() end)
    rolesBtn:SetPoint("RIGHT", clearBtn, "LEFT", -2, 0) -- placeholder; see LayoutHeaderChain
    K.ChainHeaderButton(chrome, rolesBtn)

    local addBtn
    addBtn = K.AddHeaderTextButton(box, rolesBtn, "Add (+)", "Share a custom role",
        "Publish one of your custom roles to the raid so every client resolves"
        .. " it the same way.", function()
            if not WhoDoesWhat:RequireEditPermission() then return end
            OpenAddCustomRoleMenu(addBtn)
        end)
    K.ChainHeaderButton(chrome, addBtn)

    local emptyHint = K.CreateEmptyHint(box)
    emptyHint:SetText("No custom roles are shared")

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
