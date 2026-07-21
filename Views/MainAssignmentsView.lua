local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Main /wdw window: two scrollable columns of boxed assignment sections.
--
-- This file is only the window itself: chrome, the top button strip, the
-- editing-permission strip, the scroll/column plumbing, and the refresh
-- coordinator. Every section is hard-coded in its own file under
-- Views/Sections/ (registered on WhoDoesWhat.SectionViews as Build/Refresh
-- pairs, built from the shared primitives in Views/SectionKit.lua):
--
--   left column   TankSection          one auto row per marked tank
--                 PaladinBuffsSection  computed summary + local buff rules
--                 WarlockCursesSection fixed row per curse
--   right column  CCSection            user-grown rows (the template for future
--                                      sections -- see its header comment)
--                 MisdirectSection     one auto row per hunter
--
-- The columns are deliberately uneven: the right one carries the wide dynamic
-- rows (CC, Misdirect), the left one only needs an icon, a name and one
-- dropdown (Tank, Paladin Buffs, Warlock Curses). Boxes are anchor-chained
-- within their column, so a section that changes height pushes the ones under
-- it down on its own. The model -- section defs, member/text helpers, whisper
-- collectors, demand math, auto-assigns, and storage -- lives in
-- Assignments.lua.

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit
local PruneDepartedAssignments = A.PruneDepartedAssignments

local mainFrame = nil

local FRAME_W = 940
-- Paladin-only view also narrows the window to about the section box (378) --
-- the top button row (~438px for the four buttons) is the real floor, so this
-- is sized to keep them on one line; the permission strip hides in this mode
-- so it can't collide with them.
local NARROW_FRAME_W = 470
-- The window auto-fits its height to the visible content (ApplyViewMode), so
-- Paladin-only view collapses to a short, low-profile window while the full
-- board grows -- but never past MAX (it scrolls) or below MIN (the button
-- strip + a stub box still need room).
local MAX_FRAME_H = 520
local MIN_FRAME_H = 130
local MARGIN = 12
local SCROLLBAR_W = 26
local CONTENT_W = FRAME_W - MARGIN * 2 - SCROLLBAR_W
local BUTTON_ROW_H = 22

-- Column geometry (widths only live here; the kit reads them off f.columns).
-- Left is the narrow column (Tank / Paladin Buffs / Warlock Curses -- an icon,
-- a name and a dropdown); right is wider for the busy dynamic rows (CC,
-- Misdirect, and future custom-assignment sections that match them).
local COLUMN_GAP = 12
local LEFT_COLUMN_W = 378
local RIGHT_COLUMN_W = CONTENT_W - COLUMN_GAP - LEFT_COLUMN_W

-- Build + refresh order: left column top-to-bottom, then right column.
-- Within a column this is also the anchor-chain order.
local function OrderedSections()
    local SV = WhoDoesWhat.SectionViews
    return { SV.Tank, SV.PaladinBuffs, SV.WarlockCurses, SV.CC, SV.Misdirect }
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

-- Paladin-only view. With the "Prefer Paladin-only view" setting on, only the
-- Paladin Buffs section shows -- UNTIL the board carries real assignments (the
-- leader is actively assigning tanks/CC/misdirects/curses), at which point the
-- full board is revealed. Off (the default) always shows the full board.
local function ShouldShowFullBoard()
    if not WhoDoesWhat.db.profile.settings.paladinOnlyView then
        return true
    end
    return A.HasActiveAssignments()
end

-- Apply the current view mode: hide every box but Paladin Buffs in paladin-only
-- mode, then re-anchor the visible boxes and recompute the scroll height. Runs
-- after the sections refresh (their heights must be settled first).
local function ApplyViewMode(f)
    local full = ShouldShowFullBoard()

    -- Width + scroll chrome per mode. The full board needs both columns and
    -- keeps its scrollbar (reserving room for it). Paladin-only narrows to
    -- about the section box, drops the scrollbar entirely (the lone box always
    -- fits) and reclaims its width, hides the permission strip (so it can't
    -- collide with the button row -- an empty board has nothing to gate), and
    -- centers the box in the reclaimed interior.
    f:SetWidth(full and FRAME_W or NARROW_FRAME_W)
    f.scroll:ClearAllPoints()
    f.scroll:SetPoint("TOPLEFT", MARGIN, -f.scrollTop)
    if full then
        f.scroll:SetPoint("BOTTOMRIGHT", -(MARGIN + SCROLLBAR_W), MARGIN)
        f.columns[K.COL_LEFT].x = 0
    else
        f.scroll:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN)
        f.permDD:Hide()
        f.permNote:Hide()
        local interior = NARROW_FRAME_W - MARGIN * 2
        f.columns[K.COL_LEFT].x = math.floor((interior - LEFT_COLUMN_W) / 2)
    end

    local keep = f.pallySection and f.pallySection.box
    for _, col in ipairs(f.columns) do
        for _, box in ipairs(col.boxes) do
            box:SetShown(full or box == keep)
        end
    end
    K.LayoutColumnBoxes(f)
    K.UpdateContentHeight(f)

    -- Auto-fit the window to the content: short in Paladin-only view, taller
    -- (up to MAX, then it scrolls) for the full board. UpdateContentHeight
    -- already trailed a SECTION_GAP after the last box, so that doubles as the
    -- bottom margin.
    local desired = f.scrollTop + f.content:GetHeight() + MARGIN
    f:SetHeight(math.max(MIN_FRAME_H, math.min(desired, MAX_FRAME_H)))
end

-- The top-right toggle mirrors the setting; its label names the mode a click
-- switches TO ("Paladin View" while full, "Full View" while paladin-only).
local function UpdateViewToggle(f)
    if not f.viewToggle then return end
    local prefOn = WhoDoesWhat.db.profile.settings.paladinOnlyView
    f.viewToggle:SetText(prefOn and "Full View" or "Paladin View")
end

-- Repaint everything: the permission strip, then every section (each owns
-- its rows, warnings, header buttons and box height), then the view mode
-- (which box(es) show) and the header mail buttons' enabled states. Mail
-- visibility settles first (cheap, no collectors) so every section lays out
-- its header chain against it.
local function RefreshAll(f)
    UpdatePermissionControls(f)
    K.UpdateHeaderMailVisibility(f)
    for _, section in ipairs(f.sections) do
        section.Refresh(f)
    end
    ApplyViewMode(f)
    UpdateViewToggle(f)
    K.UpdateHeaderMailButtons(f)
end

-- Build the window once and reuse it: shared chrome, the Settings / Role
-- Preferences buttons under the title bar, and the two scrollable columns.
local function EnsureMainFrame()
    if mainFrame then return mainFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatMainFrame", FRAME_W, MAX_FRAME_H, "WhoDoesWhat - Raid Assignments")
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

    -- Paladin-only view toggle: flips the local "Prefer Paladin-only view"
    -- setting and repaints. The three view buttons above stay put; only the
    -- section boxes below react (ApplyViewMode).
    local viewBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    viewBtn:SetSize(100, BUTTON_ROW_H)
    viewBtn:SetPoint("RIGHT", raiderBtn, "LEFT", -6, 0)
    viewBtn:SetText("Paladin View")
    viewBtn:SetScript("OnClick", function()
        local s = WhoDoesWhat.db.profile.settings
        s.paladinOnlyView = not s.paladinOnlyView
        WhoDoesWhat:Print("Paladin-only view " .. (s.paladinOnlyView and "enabled." or "disabled."))
        RefreshAll(f)
    end)
    viewBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Prefer Paladin-only view", 1, 1, 1)
        GameTooltip:AddLine("Show only the Paladin Buffs section. The full board"
            .. " still appears automatically while there are active"
            .. " tank / CC / misdirect / curse assignments.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    viewBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.viewToggle = viewBtn

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
    f.scrollTop = scrollTop -- chrome above the scroll area; ApplyViewMode sizes to it
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
    -- Auto-hide the scrollbar when the content fits (always the case in the
    -- narrow Paladin-only view). ApplyViewMode also re-anchors the scroll's
    -- right edge per mode so the hidden bar leaves no reserved gap.
    scroll.scrollBarHideable = 1

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
