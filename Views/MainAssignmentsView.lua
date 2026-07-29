local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Main /wdw window: two scrollable columns of boxed assignment sections.
--
-- This file is only the window itself: chrome, the top button strip, the
-- editing-permission strip, the scroll/column plumbing, and the refresh
-- coordinator. Every section is hard-coded in its own file under
-- Views/Sections/ (registered on WhoDoesWhat.SectionViews as Build/Refresh
-- pairs, built from the shared primitives in Views/SectionKit.lua):
--
--   left column   PaladinBuffsSection  computed summary + local buff rules
--                 ImprovedBuffsSection max-rank Fortitude / Gift coverage
--                 WarlockCursesSection fixed row per curse
--   right column  TankSection          one auto row per marked tank
--                 CCSection            user-grown rows (the template for future
--                                      sections -- see its header comment)
--                 MisdirectSection     one auto row per hunter
--
-- The columns are deliberately uneven: the right one carries Tanks and the
-- wide dynamic rows (CC, Misdirect), while the left carries Paladin Buffs and
-- Warlocks. Boxes are anchor-chained
-- within their column, so a section that changes height pushes the ones under
-- it down on its own. The model -- section defs, member/text helpers, whisper
-- collectors, demand math, auto-assigns, and storage -- lives in
-- Assignments.lua.

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit
local Sync = WhoDoesWhat:GetModule("Sync")
local PruneDepartedAssignments = A.PruneDepartedAssignments

local mainFrame = nil

local FRAME_W = 940
-- Paladin-only view narrows the window to exactly fit the section box (378)
-- plus the two window margins, so the box centers with an even MARGIN on each
-- side -- flush with the header's checkbox (left) and buttons (right), no
-- stray padding. The slimmer header fits well inside this; the permission
-- strip hides in this mode anyway.
local NARROW_FRAME_W = 402 -- LEFT_COLUMN_W (378) + MARGIN (12) * 2
-- The window auto-fits its height to the visible content (ApplyViewMode), so
-- Paladin-only view collapses to a short, low-profile window while the full
-- board grows -- but never past MAX (it scrolls) or below MIN (the button
-- strip + a stub box still need room).
local MAX_FRAME_H = 550
local MIN_FRAME_H = 130
local MARGIN = 12
local CONTENT_W = FRAME_W - MARGIN * 2
local BUTTON_ROW_H = 22

-- Column geometry (widths only live here; the kit reads them off f.columns).
-- Left is the narrow column (Paladin Buffs / Warlocks); right is wider for
-- Tanks, the busy dynamic rows (CC, Misdirect), and future custom-assignment
-- sections that match them.
local COLUMN_GAP = 12
local LEFT_COLUMN_W = 378
local RIGHT_COLUMN_W = CONTENT_W - COLUMN_GAP - LEFT_COLUMN_W

-- Build + refresh order: left column top-to-bottom, then right column.
-- Within a column this is also the anchor-chain order.
local function OrderedSections()
    local SV = WhoDoesWhat.SectionViews
    local sections = {
        SV.Tank, SV.PaladinBuffs, SV.ImprovedBuffs, SV.WarlockCurses, SV.CC,
    }
    if WhoDoesWhat.ClientFeatures.misdirectAssignments then
        sections[#sections + 1] = SV.Misdirect
    end
    return sections
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

-- Apply the current view mode: hide every box but Paladin Buffs in paladin-only
-- mode, then re-anchor the visible boxes and recompute the scroll height. Runs
-- after the sections refresh (their heights must be settled first).
local function ApplyViewMode(f)
    local full = not WhoDoesWhat.db.profile.settings.paladinOnlyView

    -- Width + scroll chrome per mode. The scroll spans the full width in both
    -- modes (no reserved scrollbar gutter -- the boxes must line up with the top
    -- button row, which anchors to the window edge); the scrollbar stays hidden
    -- unless content outgrows the window, in which case it overlays the right
    -- edge. The full board shows both columns; Paladin-only narrows to about the
    -- section box, hides the permission strip (so it can't collide with the
    -- button row -- an empty board has nothing to gate), and centers the lone
    -- box in the interior.
    f:SetWidth(full and FRAME_W or NARROW_FRAME_W)
    f.scroll:ClearAllPoints()
    f.scroll:SetPoint("TOPLEFT", MARGIN, -f.scrollTop)
    f.scroll:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN)
    if full then
        f.columns[K.COL_LEFT].x = 0
    else
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

-- The top-left "Full view" checkbox mirrors the setting: checked whenever the
-- Paladin-only preference is OFF (i.e. the full board is preferred).
local function UpdateViewToggle(f)
    if not f.fullViewCheck then return end
    local prefOn = WhoDoesWhat.db.profile.settings.paladinOnlyView
    f.fullViewCheck:SetChecked(not prefOn)
end

local function UpdateVersionWarning(f)
    if not f.versionWarn then return end
    local current = Sync:GetReportedAddonVersion()
    f.titleText:SetText("WhoDoesWhat (v" .. current .. ")")
    local newer = Sync:GetNewerAddonVersions()
    if #newer == 0 then
        f.versionWarn.tooltipText = nil
        f.versionWarn:Hide()
        return
    end
    local reports = {}
    for _, peer in ipairs(newer) do
        reports[#reports + 1] = peer.name .. " reports using version " .. peer.version
    end
    f.versionWarn.tooltipText = "You are running WhoDoesWhat v" .. current
        .. ", but " .. table.concat(reports, "; ")
        .. ". Update the addon to stay compatible."
    f.versionWarn:Show()
end

-- Repaint everything: the permission strip, then every section (each owns
-- its rows, warnings, header buttons and box height), then the view mode
-- (which box(es) show) and the header mail buttons' enabled states. Mail
-- visibility settles first (cheap, no collectors) so every section lays out
-- its header chain against it.
local function RefreshAll(f)
    UpdateVersionWarning(f)
    UpdatePermissionControls(f)
    K.UpdateHeaderMailVisibility(f)
    for _, section in ipairs(f.sections) do
        section.Refresh(f)
    end
    ApplyViewMode(f)
    UpdateViewToggle(f)
    K.UpdateHeaderMailButtons(f)
end

local function CreateToolbarButton(f, text, width, title, body, onClick)
    local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn:SetSize(width, BUTTON_ROW_H)
    btn:SetText(text)
    btn:SetMotionScriptsWhileDisabled(true)
    btn:SetScript("OnClick", onClick)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(title, 1, 1, 1)
        GameTooltip:AddLine(self.disabledReason or body, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

-- Build the window once and reuse it: shared chrome, the header strip (Full
-- view checkbox + permission strip left, Logs / Members / Roles / Settings right)
-- and the two scrollable columns.
local function EnsureMainFrame()
    if mainFrame then return mainFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatMainFrame", FRAME_W, MAX_FRAME_H,
        "WhoDoesWhat (v" .. Sync:GetReportedAddonVersion() .. ")")
    -- Center the title in the bar (the shared chrome left-aligns it); anchored
    -- to the window's top so it re-centers when the width changes per view mode.
    f.titleText:ClearAllPoints()
    f.titleText:SetPoint("CENTER", f, "TOP", 0, -(f.titleBarHeight / 2 + 5))
    local versionWarn = K.CreateWarningIcon(f)
    versionWarn:SetPoint("LEFT", f.titleText, "RIGHT", 4, 0)
    f.versionWarn = versionWarn
    local top = f.titleBarHeight + 10

    -- Right-side button row: [Logs] [Members] [Roles] [Settings].
    local settingsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    settingsBtn:SetSize(80, BUTTON_ROW_H)
    settingsBtn:SetPoint("TOPRIGHT", -MARGIN, -top)
    settingsBtn:SetText("Settings")
    settingsBtn:SetScript("OnClick", function()
        WhoDoesWhat:OpenAddonSettingsView()
    end)

    local editRolesBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    editRolesBtn:SetSize(60, BUTTON_ROW_H)
    editRolesBtn:SetPoint("RIGHT", settingsBtn, "LEFT", -6, 0)
    editRolesBtn:SetText("Roles")
    editRolesBtn:SetScript("OnClick", function()
        WhoDoesWhat:OpenAllRolesView()
    end)

    local membersBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    membersBtn:SetSize(80, BUTTON_ROW_H)
    membersBtn:SetPoint("RIGHT", editRolesBtn, "LEFT", -6, 0)
    membersBtn:SetText("Members")
    membersBtn:SetScript("OnClick", function()
        WhoDoesWhat:OpenRaiderRolesView()
    end)

    local logsBtn = CreateToolbarButton(f, "Logs", 52, "Sync traffic",
        "Open the combined WhoDoesWhat and PallyPower addon-message logs.",
        function() WhoDoesWhat:OpenSyncLogView("wdw") end)
    logsBtn:SetPoint("RIGHT", membersBtn, "LEFT", -6, 0)

    -- Full-view toggle: a checkbox top-left (checked = full board, unchecked =
    -- show the Paladin-only view). UpdateViewToggle keeps it in sync; only
    -- the section boxes below react (ApplyViewMode).
    local fullViewCB = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    fullViewCB:SetSize(24, 24)
    fullViewCB:SetPoint("LEFT", f, "TOPLEFT", MARGIN, -(top + BUTTON_ROW_H / 2))
    local fvLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fvLabel:SetPoint("LEFT", fullViewCB, "RIGHT", 2, 0)
    fvLabel:SetText("Full view")
    fullViewCB:SetScript("OnClick", function(self)
        local s = WhoDoesWhat.db.profile.settings
        s.paladinOnlyView = not self:GetChecked() -- checked = show the full board
        WhoDoesWhat:LogUiBuilding("Paladin-only view " .. (s.paladinOnlyView and "enabled." or "disabled."))
        RefreshAll(f)
    end)
    fullViewCB:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Full view", 1, 1, 1)
        GameTooltip:AddLine("Show the whole assignment board. Uncheck to show only"
            .. " the Paladin Buffs section.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    fullViewCB:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.fullViewCheck = fullViewCB

    -- Editing-permission strip, to the right of the Full view checkbox: the
    -- raid leader sees the picker, other raid members a read-only note, and
    -- outside raids both hide (UpdatePermissionControls decides each refresh).
    local permDD = CreateFrame("Frame", "WhoDoesWhatPermissionsDD", f, "UIDropDownMenuTemplate")
    permDD:SetPoint("LEFT", fvLabel, "RIGHT", 4, -2) -- template overhangs ~15px left
    UIDropDownMenu_SetWidth(permDD, 170)
    K.LeftAlignDropdown(permDD)
    UIDropDownMenu_Initialize(permDD, InitPermissionsDropdown)
    permDD:Hide()
    f.permDD = permDD

    local permNote = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    permNote:SetPoint("LEFT", fvLabel, "RIGHT", 16, 0)
    permNote:Hide()
    f.permNote = permNote

    local scrollTop = top + BUTTON_ROW_H + 8
    f.scrollTop = scrollTop -- chrome above the scroll area; ApplyViewMode sizes to it
    local scroll = CreateFrame("ScrollFrame", "WhoDoesWhatMainScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", MARGIN, -scrollTop)
    scroll:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN) -- ApplyViewMode re-asserts this each refresh

    local content = CreateFrame("Frame", nil, scroll)
    -- A scroll child with no anchor point has an indeterminate rect until
    -- something forces a re-layout -- the "nothing renders until the window
    -- is moved" bug. Pin it explicitly.
    content:SetPoint("TOPLEFT")
    content:SetWidth(CONTENT_W)
    scroll:SetScrollChild(content)
    f.content = content
    f.scroll = scroll
    -- Hide the scrollbar whenever the content fits -- the usual case, since the
    -- window auto-fits its height up to MAX_FRAME_H. It only appears when a
    -- column outgrows that cap (a long CC list, or a future section), and then
    -- overlays the right edge rather than reserving a permanent gutter that
    -- would push the boxes out of line with the top button row.
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
