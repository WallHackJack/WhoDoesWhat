local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI

-- Main /wdw window: one fixed-size window, one tab per page.
--
--   Raid  Members  Buff Grid                          Logs  About  Settings
--
-- This file owns the window, its tab row and the Raid page. Every other page is
-- built by its own view file (BuildMembersPage and friends) the first time its
-- tab is opened, and repaints itself whenever it comes back on screen. The
-- old per-page openers (OpenMembersView, OpenAddonSettingsView...) now open
-- this window on their tab through ShowMainTab.
--
-- The Raid page is the permission strip over two scrollable columns of boxed
-- assignment sections. Every section is hard-coded in its own file under
-- Views/Sections/ (registered on WhoDoesWhat.SectionViews as Build/Refresh
-- pairs, built from the shared primitives in Views/SectionKit.lua):
--
--   left column   PaladinBuffsSection  computed summary + buff rules
--                 CustomRolesSection   the raid's shared + overridden roles
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

local mainFrame = nil

local SCROLLBAR_W = UI.SCROLLBAR_W
-- Fixed size: wide enough for the Raid board's two columns and its scrollbar
-- inside the tab panel. Pages taller than the panel scroll.
local WINDOW_W = 900
local WINDOW_H = 560
-- Room above the Raid page's columns for the permission picker.
local PERMISSION_STRIP_H = 30

local SETTINGS_LABEL = "|T" .. UI.GEAR_ICON .. ":14:14:0:0|t Settings"
local ISSUE_MARKUP = " |T" .. UI.WARNING_ICON .. ":14:14:0:0|t"

-- Page backgrounds over the window's blue panel. The roster-style pages sit on
-- near-black, which their class-tinted rows were picked against and read muddy
-- on blue, and Logs reads better on it too. Settings sits on it around its own
-- section tabs, whose pages are slate. About stays on the panel's own blue.
local THEME = WhoDoesWhat.Theme
local PAGE_DARK = THEME.pageDark
local PAGE_COLORS = {
    raid = PAGE_DARK, members = PAGE_DARK, grid = PAGE_DARK, logs = PAGE_DARK,
    settings = PAGE_DARK,
}

-- Column geometry (widths only live here; the kit reads them off f.columns).
-- Left is the narrow column (Paladin Buffs / Warlocks); right is wider for
-- Tanks, the busy dynamic rows (CC, Misdirect), and future custom-assignment
-- sections that match them.
local COLUMN_GAP = 12
local LEFT_COLUMN_W = 330
local RIGHT_COLUMN_W = 500
local CONTENT_W = LEFT_COLUMN_W + COLUMN_GAP + RIGHT_COLUMN_W

-- Build + refresh order: left column top-to-bottom, then right column.
-- Within a column this is also the anchor-chain order.
local function OrderedSections()
    local SV = WhoDoesWhat.SectionViews
    local sections = {
        SV.Tank, SV.PaladinBuffs, SV.CustomRoles, SV.WarlockCurses, SV.CC,
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

-- The strip at the Raid page's top-left: the raid leader gets the picker
-- dropdown, every other raid member a note: the rule if they may edit under it,
-- otherwise just "Read Only Mode". Hidden outside raids -- parties and solo are
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
        f.permNote:SetText("|cff909090" .. (WhoDoesWhat:CanEditAssignments()
            and ("Editing: " .. WhoDoesWhat:PermissionModeLabel())
            or "Read Only Mode") .. "|r")
        f.permNote:Show()
    end
end

-- ---------------------------------------------------------------------------
-- Refresh coordinator + window
-- ---------------------------------------------------------------------------

-- The Raid page's scroll area starts under the permission strip while the strip
-- has something to say, and takes its room back when it doesn't (outside raids).
local function LayoutRaidPage(f)
    local stripShown = f.permDD:IsShown() or f.permNote:IsShown()
    f.scroll:ClearAllPoints()
    f.scroll:SetPoint("TOPLEFT", f.raidPage, "TOPLEFT", 0,
        stripShown and -PERMISSION_STRIP_H or 0)
    f.scroll:SetPoint("BOTTOMRIGHT", f.raidPage, "BOTTOMRIGHT", -SCROLLBAR_W, 0)
end

local function UpdateVersionWarning(f)
    local current = Sync:GetReportedAddonVersion()
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

-- The tab row's own state: the Members count and its warning, and whether Logs
-- is on offer.
--
-- The warning is a PROMPT, so it follows what this client may actually fix, not
-- the raw total. An unpermitted raider still sees an honest "Members (23)" if
-- they go looking -- nothing flags at them about roles that are the leader's to
-- set. Nothing about the count makes the tab unselectable either: opening it to
-- confirm "nothing to fix" is a legitimate thing to want before a pull.
local function UpdateTabs(f)
    local count, actionable = WhoDoesWhat:CountActionItems()
    f:SetTabLabel("members", (count > 0 and ("Members (" .. count .. ")") or "Members")
        .. (actionable > 0 and ISSUE_MARKUP or ""))
    -- Asking for the logs directly (/wdw log) shows the tab for the rest of the
    -- session even with the setting off; otherwise the setting decides.
    f:SetTabShown("logs", f.logsRequested
        or WhoDoesWhat.db.profile.settings.showLogsButton)
    UpdateVersionWarning(f)
end

-- Repaint the Raid page: the permission strip, then every section (each owns
-- its rows, warnings, header buttons and box height), then the header mail
-- buttons' enabled states. Mail visibility settles first (cheap, no
-- collectors) so every section lays out its header chain against it.
local function RefreshRaidPage(f)
    UpdatePermissionControls(f)
    LayoutRaidPage(f)
    K.UpdateHeaderMailVisibility(f)
    for _, section in ipairs(f.sections) do
        section.Refresh(f)
    end
    K.UpdateHeaderMailButtons(f)
end

-- The Raid page: the permission strip over the two scrollable columns.
local function BuildRaidPage(f, page)
    f.raidPage = page

    -- Editing-permission strip: the raid leader sees the picker, other raid
    -- members a read-only note, and outside raids both hide
    -- (UpdatePermissionControls decides each refresh).
    local permDD = UI.CreateMenuDropdown(page, "WhoDoesWhatPermissionsDD", 170)
    -- The template overhangs ~15px left of its visible box.
    permDD:SetPoint("LEFT", page, "TOPLEFT", -15, -(PERMISSION_STRIP_H / 2) - 2)
    UIDropDownMenu_Initialize(permDD, InitPermissionsDropdown)
    permDD:Hide()
    f.permDD = permDD

    local permNote = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    permNote:SetPoint("LEFT", page, "TOPLEFT", 0, -(PERMISSION_STRIP_H / 2))
    permNote:Hide()
    f.permNote = permNote

    local scroll, content = UI.CreateScroll(page, "WhoDoesWhatMainScroll", true)
    content:SetWidth(CONTENT_W)
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

    -- Every time the page comes up, whether by tab or by the window opening.
    page:HookScript("OnShow", function() RefreshRaidPage(f) end)
end

-- Build the window once and reuse it: the chrome, the tab row, and the Raid
-- page. Every other page is built by its own view the first time it is opened.
local function EnsureMainFrame()
    if mainFrame then return mainFrame end

    -- The icon rides inside the title as a texture escape, so icon, name and
    -- version stamp stay one centred string.
    local f = UI.CreateWindow("WhoDoesWhatMainFrame", WINDOW_W, WINDOW_H,
        "|T" .. WhoDoesWhat.ADDON_ICON .. ":16:16:0:0|t WhoDoesWhat", {
            version = true,
            titleBarColor = THEME.window.titleBarColor,
            borderColor = THEME.mainBorder,
        })
    f.closeButton:SetHitRectInsets(4, 4, 4, 4)
    local versionWarn = UI.CreateWarningIcon(f)
    versionWarn:SetPoint("LEFT", f.titleText, "RIGHT", 4, 0)
    f.versionWarn = versionWarn
    mainFrame = f

    local function ViewPage(builder)
        return function(page) WhoDoesWhat[builder](WhoDoesWhat, page) end
    end
    -- Left to right, then the right-hand run from the window's right edge
    -- inward: About is outermost.
    local pages = UI.AddTabs(f, {
        { label = "Raid", page = "raid",
            tooltip = "The assignment board: paladin buffs, roles, curses, tanks, CC and misdirects.",
            build = function(page) BuildRaidPage(f, page) end },
        { label = "Members", page = "members",
            tooltip = "Everyone in the group, the role each of them holds, and anything still"
                .. " wrong with them -- players waiting on a role, group roles that don't"
                .. " match, talents that disagree, and tanks not yet promoted to Main Tank.",
            build = ViewPage("BuildMembersPage") },
        { label = "Buff Grid", page = "grid",
            tooltip = "The raid-wide paladin blessing plan and live buff status.",
            build = ViewPage("BuildBuffingGridPage") },
        { label = SETTINGS_LABEL, page = "settings",
            build = ViewPage("BuildAddonSettingsPage") },
        { label = "About", page = "about", right = true,
            tooltip = "Links, contact information, version details, and release notes.",
            build = ViewPage("BuildAboutPage") },
        { label = "Logs", page = "logs", right = true, hidden = true,
            tooltip = "The combined WhoDoesWhat and PallyPower addon-message logs.",
            build = ViewPage("BuildSyncLogPage") },
    }, { initial = "raid", colors = THEME.tabs })
    for key, color in pairs(PAGE_COLORS) do UI.SetTabPageColor(pages[key], color) end

    f:HookScript("OnShow", UpdateTabs)
    UpdateTabs(f)

    -- Keep names' class colors and the warnings honest while the window is
    -- open (an assigned player leaving the group turns gray, etc.).
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:SetScript("OnEvent", function(self)
        if not self:IsShown() then return end
        UpdateTabs(self)
        if self.raidPage:IsVisible() then RefreshRaidPage(self) end
    end)

    return f
end

-- Repaint if the window is up: the tab row always, the Raid page only while it
-- is the page on screen - it repaints itself when it comes back. Called from
-- outside the view when something board-relevant changes (setters, sync, role
-- assignments in UnitMenu).
function WhoDoesWhat:RefreshMainAssignmentsView()
    if not (mainFrame and mainFrame:IsShown()) then return end
    UpdateTabs(mainFrame)
    if mainFrame.raidPage:IsVisible() then RefreshRaidPage(mainFrame) end
end

-- Just the tab row, for a page whose change moves the Members count without
-- touching the board.
function WhoDoesWhat:RefreshMainTabs()
    if mainFrame and mainFrame:IsShown() then UpdateTabs(mainFrame) end
end

-- Open the main window on a tab, by page key. Asking for the tab that is
-- already up closes the window, as every opener used to close its own window;
-- asking for any other tab switches to it. `stayOpen` switches without ever
-- closing, for an opener that also picks something inside the page.
--
-- Returns whether the window is open on that tab afterwards.
function WhoDoesWhat:ShowMainTab(key, stayOpen)
    local f = EnsureMainFrame()
    if key == "logs" and not f.logsRequested then
        f.logsRequested = true
        UpdateTabs(f)
    end
    if f:IsShown() and f.selectedPage == key and not stayOpen then
        self:LogUiBuilding("Main window open on " .. key .. ", closing it.")
        f:Hide()
        return false
    end
    self:LogUiBuilding("Opening main window on " .. key .. "...")
    f:SelectTab(key)
    f:Show()
    f:Raise()
    return true
end

-- Toggle the main window on the Raid page.
function WhoDoesWhat:OpenMainAssignmentsView()
    self:ShowMainTab("raid")
end
