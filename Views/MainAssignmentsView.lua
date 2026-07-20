local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Main /wdw window: two scrollable columns of boxed assignment sections.
--
-- This file is only the window itself: chrome, the top button strip, the
-- editing-permission strip, the scroll/column plumbing, and the refresh
-- coordinator. Every section is hard-coded in its own file under
-- Views/Sections/ (registered on WhoDoesWhat.SectionViews as Build/Refresh
-- pairs, built from the shared primitives in Views/SectionKit.lua):
--
--   left column   TankSection      one auto row per marked tank
--                 CCSection        user-grown rows (the template for future
--                                  sections -- see its header comment)
--                 MisdirectSection one auto row per hunter
--   right column  PaladinBuffsSection  computed summary + local buff rules
--                 WarlockCursesSection fixed row per curse
--
-- The columns are deliberately uneven: the left one carries the wide dynamic
-- rows, the right one only needs an icon, a name and one dropdown. Boxes are
-- anchor-chained within their column, so a section that changes height
-- pushes the ones under it down on its own. The model -- section defs,
-- member/text helpers, whisper collectors, demand math, auto-assigns, and
-- storage -- lives in Assignments.lua.

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit
local PruneDepartedAssignments = A.PruneDepartedAssignments

local mainFrame = nil

local FRAME_W = 940
local FRAME_H = 560
local MARGIN = 12
local SCROLLBAR_W = 26
local CONTENT_W = FRAME_W - MARGIN * 2 - SCROLLBAR_W
local BUTTON_ROW_H = 22

-- Column geometry (widths only live here; the kit reads them off f.columns).
local COLUMN_GAP = 12
local LEFT_COLUMN_W = 500
local RIGHT_COLUMN_W = CONTENT_W - COLUMN_GAP - LEFT_COLUMN_W

-- Build + refresh order: left column top-to-bottom, then right column.
-- Within a column this is also the anchor-chain order.
local function OrderedSections()
    local SV = WhoDoesWhat.SectionViews
    return { SV.Tank, SV.CC, SV.Misdirect, SV.PaladinBuffs, SV.WarlockCurses }
end

-- ---------------------------------------------------------------------------
-- Editing-permission strip (Permissions.lua)
-- ---------------------------------------------------------------------------

-- The raid leader's editing-permission picker. Level 1 lists the four modes;
-- "One assistant" opens a level-2 list of the raid's current assistants
-- (UIDROPDOWNMENU_MENU_VALUE pattern). Selection goes through
-- SetPermissionMode, which announces, repaints, and lets the sync poll carry
-- the new rule to everyone.
local PERMISSION_OPTIONS = {
    { mode = "leader", text = "Only me (leader)" },
    { mode = "assistant", text = "One assistant", hasArrow = true },
    { mode = "assists", text = "All assistants" },
    { mode = "everyone", text = "Everyone" },
}

local function InitPermissionsDropdown(_, level)
    local perms = WhoDoesWhat:GetPermissions()

    if level == 2 and UIDROPDOWNMENU_MENU_VALUE == "assistant" then
        local found = 0
        for i = 1, GetNumGroupMembers() do
            local name, rank, _, _, _, classToken = GetRaidRosterInfo(i)
            if rank == 1 then
                found = found + 1
                local color = classToken and RAID_CLASS_COLORS[classToken]
                local info = UIDropDownMenu_CreateInfo()
                info.text = color and ("|c" .. color.colorStr .. name .. "|r") or name
                info.checked = (perms.mode == "assistant" and perms.assistant == name)
                info.func = function()
                    WhoDoesWhat:SetPermissionMode("assistant", name)
                    CloseDropDownMenus()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
        if found == 0 then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "|cff909090No assistants - promote one first|r"
            info.notCheckable = true
            info.disabled = true
            UIDropDownMenu_AddButton(info, level)
        end
        return
    end

    for _, opt in ipairs(PERMISSION_OPTIONS) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = opt.text
        if opt.hasArrow then
            info.hasArrow = true
            info.value = "assistant"
            info.keepShownOnClick = true
            info.checked = (perms.mode == "assistant")
            info.func = function() end -- picking happens in the submenu
        else
            info.checked = (perms.mode == opt.mode)
            info.func = function()
                WhoDoesWhat:SetPermissionMode(opt.mode)
            end
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

-- The strip at the window's top-left: the raid leader gets the picker
-- dropdown, every other raid member a note naming the rule (and whether the
-- board is read-only for them). Hidden outside raids -- parties and solo are
-- always open, nothing to say.
local function UpdatePermissionControls(f)
    if not IsInRaid() then
        f.permDD:Hide()
        f.permNote:Hide()
        return
    end
    -- Rule stood down (battleground, or the leader doesn't run the addon):
    -- everyone edits, and the note says why -- the picker would be a lie.
    local openReason = WhoDoesWhat:PermissionsOpenReason()
    if openReason then
        f.permDD:Hide()
        f.permNote:SetText("|cff909090Editing: everyone (" .. openReason .. ")|r")
        f.permNote:Show()
        return
    end
    if UnitIsGroupLeader("player") then
        UIDropDownMenu_SetText(f.permDD, "Editing: " .. WhoDoesWhat:PermissionModeLabel())
        f.permDD:Show()
        f.permNote:Hide()
    else
        f.permDD:Hide()
        f.permNote:SetText("|cff909090Editing: " .. WhoDoesWhat:PermissionModeLabel()
            .. (WhoDoesWhat:CanEditAssignments() and ""
                or " - the board is read-only for you") .. "|r")
        f.permNote:Show()
    end
end

-- ---------------------------------------------------------------------------
-- Refresh coordinator + window
-- ---------------------------------------------------------------------------

-- Repaint everything: the permission strip, then every section (each owns
-- its rows, warnings, header buttons and box height), then the header mail
-- buttons' enabled states. Mail visibility settles first (cheap, no
-- collectors) so every section lays out its header chain against it.
local function RefreshAll(f)
    UpdatePermissionControls(f)
    K.UpdateHeaderMailVisibility(f)
    for _, section in ipairs(f.sections) do
        section.Refresh(f)
    end
    K.UpdateHeaderMailButtons(f)
end

-- Build the window once and reuse it: shared chrome, the Settings / Role
-- Preferences buttons under the title bar, and the two scrollable columns.
local function EnsureMainFrame()
    if mainFrame then return mainFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatMainFrame", FRAME_W, FRAME_H, "WhoDoesWhat - Raid Assignments")
    local top = f.titleBarHeight + 10

    local settingsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    settingsBtn:SetSize(80, BUTTON_ROW_H)
    settingsBtn:SetPoint("TOPRIGHT", -MARGIN, -top)
    settingsBtn:SetText("Settings")
    settingsBtn:SetScript("OnClick", function()
        WhoDoesWhat:OpenAddonSettingsView()
    end)

    local prefsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    prefsBtn:SetSize(130, BUTTON_ROW_H)
    prefsBtn:SetPoint("RIGHT", settingsBtn, "LEFT", -6, 0)
    prefsBtn:SetText("Role Preferences")
    prefsBtn:SetScript("OnClick", function()
        WhoDoesWhat:OpenAllRolesView()
    end)

    local raiderBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    raiderBtn:SetSize(110, BUTTON_ROW_H)
    raiderBtn:SetPoint("RIGHT", prefsBtn, "LEFT", -6, 0)
    raiderBtn:SetText("Raider Roles")
    raiderBtn:SetScript("OnClick", function()
        WhoDoesWhat:OpenRaiderRolesView()
    end)

    -- Editing-permission strip, top-left across from the view buttons: the
    -- raid leader sees the picker, other raid members a read-only note, and
    -- outside raids both hide (UpdatePermissionControls decides each refresh).
    -- The dropdown overhangs left by its template's ~15px padding so its
    -- visible box lines up with the window margin.
    local permDD = CreateFrame("Frame", "WhoDoesWhatPermissionsDD", f, "UIDropDownMenuTemplate")
    permDD:SetPoint("TOPLEFT", MARGIN - 15, -(top - 2))
    UIDropDownMenu_SetWidth(permDD, 170)
    K.LeftAlignDropdown(permDD)
    UIDropDownMenu_Initialize(permDD, InitPermissionsDropdown)
    permDD:Hide()
    f.permDD = permDD

    local permNote = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    permNote:SetPoint("TOPLEFT", MARGIN + 4, -(top + 6))
    permNote:Hide()
    f.permNote = permNote

    local scrollTop = top + BUTTON_ROW_H + 8
    local scroll = CreateFrame("ScrollFrame", "WhoDoesWhatMainScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", MARGIN, -scrollTop)
    scroll:SetPoint("BOTTOMRIGHT", -(MARGIN + SCROLLBAR_W), MARGIN)

    local content = CreateFrame("Frame", nil, scroll)
    -- A scroll child with no anchor point has an indeterminate rect until
    -- something forces a re-layout -- the "nothing renders until the window
    -- is moved" bug. Pin it explicitly.
    content:SetPoint("TOPLEFT")
    content:SetWidth(CONTENT_W)
    scroll:SetScrollChild(content)
    f.content = content
    f.scroll = scroll

    WhoDoesWhat:LogUiBuilding("Building main assignments content.")

    f.headerMail = {} -- section-header mass-mail buttons (SectionKit)
    f.columns = {
        [K.COL_LEFT] = { boxes = {}, x = 0, width = LEFT_COLUMN_W },
        [K.COL_RIGHT] = { boxes = {}, x = LEFT_COLUMN_W + COLUMN_GAP, width = RIGHT_COLUMN_W },
    }

    f.sections = OrderedSections()
    for _, section in ipairs(f.sections) do
        section.Build(f, content)
    end
    -- Creates rows for saved entries and settles every height.
    RefreshAll(f)

    -- Keep names' class colors and the warnings honest while the window is
    -- open (an assigned player leaving the group turns gray, etc.).
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:SetScript("OnEvent", function(self)
        if self:IsShown() then
            RefreshAll(self)
        end
    end)

    mainFrame = f
    return f
end

-- Repaint if the window is up. Called from outside the view when something
-- board-relevant changes (setters, sync, role assignments in UnitMenu).
function WhoDoesWhat:RefreshMainAssignmentsView()
    if mainFrame and mainFrame:IsShown() then
        RefreshAll(mainFrame)
    end
end

-- Toggle the main assignments window open/closed.
function WhoDoesWhat:OpenMainAssignmentsView()
    local f = EnsureMainFrame()

    if f:IsShown() then
        self:LogUiBuilding("Main Assignments View open, closing it.")
        f:Hide()
        return
    end

    self:LogUiBuilding("Opening Main Assignments View...")
    PruneDepartedAssignments()
    RefreshAll(f)
    f:Show()
    f:Raise()
end
