local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI

-- Main /wdw window: one fixed-size window, one tab per page.
--
--   Raid  Members  Buff Grid  Calculator  Settings              Logs  About
--
-- This file owns the window, its tab row and the Raid page. Every other page is
-- built by its own view file (BuildMembersPage and friends) the first time its
-- tab is opened, and repaints itself whenever it comes back on screen. The
-- old per-page openers (OpenMembersView, OpenAddonSettingsView...) now open
-- this window on their tab through ShowMainTab.
--
-- The Raid page is laid out like Settings: a second row of tabs over one title
-- strip (the permission picker hard right, where Settings has Reset), and each
-- tab's page in a navy well. A page scrolls one centred column of boxed
-- assignment sections; Blessings splits its well, sections on the left and the
-- PallyPower differences (PallyPowerDiffView.lua) on the right. Every section is
-- hard-coded in its own file under Views/Sections/ (registered on
-- WhoDoesWhat.SectionViews as Build/Refresh pairs, built from the shared
-- primitives in Views/SectionKit.lua) and names the tab it sits on:
--
--   Blessings       PaladinBuffsSection  computed summary + buff rules
--                   CustomRolesSection   the raid's shared + overridden roles
--   Tanking         TankSection          one auto row per marked tank
--                   MisdirectSection     one auto row per hunter
--   Crowd Control   CCSection            user-grown rows (the template for
--                                        future sections -- see its header)
--   Warlocks        WarlockCursesSection fixed row per curse
--
-- Boxes are anchor-chained within their tab, so a section that changes height
-- pushes the ones under it down on its own. Every tab's sections are built and
-- refreshed together, whichever one is up. The model -- section defs,
-- member/text helpers, whisper collectors, demand math, auto-assigns, and
-- storage -- lives in Assignments.lua.

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit
local Sync = WhoDoesWhat:GetModule("Sync")

local mainFrame = nil

local SCROLLBAR_W = UI.SCROLLBAR_W
-- Fixed width: wide enough for the widest page (Members, the Buff Grid) inside
-- the tab panel. WINDOW_H is the height every page gets unless it asks for more
-- (SetMainPageHeight); pages taller than the panel scroll.
local WINDOW_W = 900
local WINDOW_H = 560
-- Page key -> the content height that page asked for.
local pageHeights = {}

local SETTINGS_LABEL = "|T" .. UI.GEAR_ICON .. ":14:14:0:0|t Settings"
local ISSUE_MARKUP = " |T" .. UI.WARNING_ICON .. ":14:14:0:0|t"

-- Page backgrounds over the window's blue panel. The roster-style pages sit on
-- near-black, which their class-tinted rows were picked against and read muddy
-- on blue, and Logs reads better on it too. Settings sits on it around its own
-- section tabs, whose pages are slate. About stays on the panel's own blue.
local THEME = WhoDoesWhat.Theme
local PAGE_DARK = THEME.pageDark
local PAGE_COLORS = {
    raid = PAGE_DARK, members = PAGE_DARK, grid = PAGE_DARK, calculator = PAGE_DARK,
    logs = PAGE_DARK, settings = PAGE_DARK,
}

-- The Raid page's sub-tabs, left to right. Sections pick theirs by key.
-- `title` heads the page, as Settings' sections do, in gold or the accent of
-- the tab's `palette` (panel, well and accent colours; Theme.lua), which
-- otherwise keeps the Settings slate and navy. Blessings is split: its
-- sections flat on a narrow panel on the left, the PallyPower differences on
-- the right.
local RAID_TABS = {
    { label = "Blessings", page = K.TAB_BLESSINGS, title = "Paladin Blessings",
        palette = THEME.blessings, split = true },
    { label = "Tanking", page = K.TAB_TANKING, title = "Tanking" },
    { label = "Crowd Control", page = K.TAB_CC, title = "Crowd Control" },
    { label = "Warlocks", page = K.TAB_WARLOCKS, title = "Warlocks",
        palette = { accent = { 0.58, 0.51, 0.79 } } },
}

-- Sub-tab geometry. Every section is SECTION_W wide, bar the split Blessings
-- panel's, which keep the compact Paladin Buffs minimum. The shared title strip
-- sits above each page's well, and a split well's two panels keep a gap of the
-- slate between them.
local SECTION_W = 500
local SPLIT_SECTION_W = 330
local HEADER_H = 34
local WELL_INSET = 10
local STACK_TOP = 10
local SPLIT_LEFT_W = SPLIT_SECTION_W + 8 + SCROLLBAR_W
local SPLIT_GAP = 8

-- Build + refresh order. Within a tab this is also the anchor-chain order.
local function OrderedSections()
    local SV = WhoDoesWhat.SectionViews
    local sections = {
        SV.Tank, SV.PaladinBuffs, SV.CustomRoles, SV.WarlockCurses, SV.CC,
    }
    if WhoDoesWhat.ClientFeatures.misdirectAssignments then
        table.insert(sections, 2, SV.Misdirect) -- under Tanks
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

-- The strip at the right of the Raid page's title: the raid leader gets the picker
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
    -- "25 Raiders - 3 (!)": the group's size and kind, then how many issues it
    -- has. Solo, it is just "Members". A fake raid (solo-only) reads as the
    -- raid it simulates, counted off the roster that folds the fakes in.
    local label = "Members"
    if WhoDoesWhat:IsFakeRaidEnabled() then
        label = #WhoDoesWhat:GetGroupMembers(nil) .. " Raiders"
    elseif IsInRaid() then
        label = GetNumGroupMembers() .. " Raiders"
    elseif IsInGroup() then
        label = GetNumGroupMembers() .. " Party Members"
    end
    f:SetTabLabel("members", label .. (count > 0 and (" - " .. count) or "")
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
    K.UpdateHeaderMailVisibility(f)
    for _, section in ipairs(f.sections) do
        section.Refresh(f)
    end
    K.UpdateHeaderMailButtons(f)
end

-- Top and bottom edge shadows across one panel of a well, over its scroll area.
local function AddWellShadows(well, scroll, left, right)
    local level = scroll:GetFrameLevel() + 20
    local topEdge = UI.CreateEdgeShadow(well, level, true)
    topEdge:SetPoint("TOPLEFT", left, "TOPLEFT")
    topEdge:SetPoint("TOPRIGHT", right, "TOPRIGHT")
    local bottomEdge = UI.CreateEdgeShadow(well, level, false)
    bottomEdge:SetPoint("BOTTOMLEFT", left, "BOTTOMLEFT")
    bottomEdge:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT")
    -- Its arrows otherwise sit right at the ends, under the shadows.
    UI.InsetScrollBar(scroll, 12)
end

-- The Raid page, laid out like Settings: a row of sub-tabs over one title
-- strip, and under it each tab's page in a well of its own. The strip carries
-- the permission picker where Settings has its Reset button. A page scrolls
-- one centred column of sections; Blessings splits its well in two.
local function BuildRaidPage(f, page)
    f.raidPage = page

    local tabs = CreateFrame("Frame", nil, page)
    tabs:SetAllPoints(page)
    tabs.titleBarHeight = 0
    local subPages = UI.AddTabs(tabs, RAID_TABS,
        { colors = THEME.TabsWith({ panel = THEME.panelSlate }, THEME.subTabs) })
    local panel = tabs.tabPanel

    WhoDoesWhat:LogUiBuilding("Building main assignments content.")

    -- ---- Title strip ----
    local header = CreateFrame("Frame", nil, panel)
    header:SetPoint("TOPLEFT", WELL_INSET, -WELL_INSET)
    header:SetPoint("TOPRIGHT", -WELL_INSET, -WELL_INSET)
    header:SetHeight(HEADER_H)
    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", 0, 3)

    -- Editing-permission picker, hard right: the raid leader sees the picker,
    -- other raid members a read-only note, and outside raids both hide
    -- (UpdatePermissionControls decides each refresh).
    local permDD = UI.CreateMenuDropdown(header, "WhoDoesWhatPermissionsDD", 170)
    -- The template overhangs ~15px past each side of its visible box.
    permDD:SetPoint("RIGHT", header, "RIGHT", 15, 1)
    UIDropDownMenu_Initialize(permDD, InitPermissionsDropdown)
    permDD:Hide()
    f.permDD = permDD

    local permNote = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    permNote:SetPoint("RIGHT", header, "RIGHT", 0, 3)
    permNote:Hide()
    f.permNote = permNote

    -- The strip's title, and the panel around it in the tab's own colour.
    -- AddTabs has already selected the first tab, before anyone listened.
    local function ShowTitle(index)
        local spec = RAID_TABS[index]
        local color = spec.palette and spec.palette.accent or THEME.gold
        title:SetText(spec.title)
        title:SetTextColor(color[1], color[2], color[3])
        local fill = spec.palette and spec.palette.panel or THEME.panelSlate
        panel:SetBackdropColor(fill[1], fill[2], fill[3], fill[4])
    end
    tabs:OnTabSelected(ShowTitle)
    ShowTitle(tabs.selectedTab)

    -- ---- Wells ----
    -- Each tab's page is its well, below the strip. One scroll area of
    -- sections in it, whose boxes hang from a stack: centred across the well
    -- (scrollbar gutter included), or in the split's left panel.
    f.sectionTabs = {}
    for _, spec in ipairs(RAID_TABS) do
        local well = subPages[spec.page]
        local wellColor = spec.palette and spec.palette.well or THEME.pageWell
        well:ClearAllPoints()
        well:SetPoint("TOPLEFT", panel, "TOPLEFT", WELL_INSET, -(WELL_INSET + HEADER_H))
        well:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -WELL_INSET, WELL_INSET)

        local scroll, content = UI.CreateScroll(well, "WhoDoesWhatRaidScroll_" .. spec.page)
        local stack = CreateFrame("Frame", nil, content)
        stack:SetHeight(1)
        if spec.split then
            local leftFill = well:CreateTexture(nil, "BACKGROUND")
            leftFill:SetPoint("TOPLEFT")
            leftFill:SetPoint("BOTTOMLEFT")
            leftFill:SetWidth(SPLIT_LEFT_W)
            local rightFill = well:CreateTexture(nil, "BACKGROUND")
            rightFill:SetPoint("TOPLEFT", SPLIT_LEFT_W + SPLIT_GAP, 0)
            rightFill:SetPoint("BOTTOMRIGHT")
            for _, fill in ipairs({ leftFill, rightFill }) do
                fill:SetColorTexture(wellColor[1], wellColor[2], wellColor[3], wellColor[4])
            end

            scroll:SetPoint("TOPLEFT")
            scroll:SetPoint("BOTTOMLEFT")
            scroll:SetWidth(SPLIT_LEFT_W - SCROLLBAR_W)
            stack:SetPoint("TOP", content, "TOP", 0, -STACK_TOP)
            stack:SetWidth(SPLIT_SECTION_W)
            AddWellShadows(well, scroll, leftFill, leftFill)

            local right = CreateFrame("Frame", nil, well)
            right:SetPoint("TOPLEFT", SPLIT_LEFT_W + SPLIT_GAP, 0)
            right:SetPoint("BOTTOMRIGHT")
            WhoDoesWhat:BuildPallyPowerDiffPanel(right)
        else
            local fill = well:CreateTexture(nil, "BACKGROUND")
            fill:SetAllPoints()
            fill:SetColorTexture(wellColor[1], wellColor[2], wellColor[3], wellColor[4])

            scroll:SetPoint("TOPLEFT")
            scroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_W, 0)
            stack:SetPoint("TOP", content, "TOP", SCROLLBAR_W / 2, -STACK_TOP)
            stack:SetWidth(SECTION_W)
            AddWellShadows(well, scroll, well, well)
        end
        -- The split panel's sections sit straight on the well, Settings-style.
        f.sectionTabs[spec.page] = {
            boxes = {}, stack = stack, scroll = scroll, top = STACK_TOP,
            flat = spec.split, accent = spec.palette and spec.palette.accent,
            rowColors = spec.palette and spec.palette.rows,
        }
    end
    f.raidTabs = tabs

    f.headerMail = {} -- section-header mass-mail buttons (SectionKit)
    f.sections = OrderedSections()
    for _, section in ipairs(f.sections) do
        section.Build(f)
    end

    -- Every time the page comes up, whether by tab or by the window opening.
    page:HookScript("OnShow", function() RefreshRaidPage(f) end)
end

-- Size the window to the selected page's request. It resizes from the top: the
-- window is re-anchored by its top-left first, so the title bar and the tab row
-- hold still and only the bottom edge moves. Never below WINDOW_H, and never
-- past the bottom of the screen -- the page scrolls beyond that.
local function ApplyWindowHeight(f)
    -- The window's chrome above and below a page: title bar, tab row, the
    -- panel's border and the page's inset in it (UI.AddTabs).
    local chromeH = f.tabTop + UI.TAB_H - UI.TAB_LIP + UI.INSET + 20
    local request = pageHeights[f.selectedPage]
    local height = request and (request + chromeH) or WINDOW_H
    local top, left = f:GetTop(), f:GetLeft()
    if top and left then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        height = math.min(height, top)
    end
    f:SetHeight(math.max(WINDOW_H, height))
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
        { label = "Raid & Assignments", page = "raid",
            tooltip = "The assignment board: paladin buffs, roles, curses, tanks, CC and misdirects.",
            build = function(page) BuildRaidPage(f, page) end },
        { label = "Members", page = "members",
            tooltip = "A list of all members in your group, sorted by role. Used to assign"
                .. " roles, get an overview of your raiders, and address issues",
            build = ViewPage("BuildMembersPage") },
        { label = "Buff Grid", page = "grid",
            tooltip = "The raid-wide paladin blessing plan and live buff status.",
            build = ViewPage("BuildBuffingGridPage") },
        { label = "Calculator", page = "calculator",
            tooltip = "Estimate how much raid damage each curse provided (or could have"
                .. " provided) in a fight, pulling the fight data from Details!.",
            build = ViewPage("BuildCurseCalculatorPage") },
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

    f:OnTabSelected(function() ApplyWindowHeight(f) end)
    f:HookScript("OnShow", ApplyWindowHeight)
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

-- A page asks for the height its content needs (nil: the default). The window
-- grows or shrinks to it while that page is the one on screen.
function WhoDoesWhat:SetMainPageHeight(key, height)
    if pageHeights[key] == height then return end
    pageHeights[key] = height
    if mainFrame and mainFrame.selectedPage == key then
        ApplyWindowHeight(mainFrame)
    end
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

-- Open the main window on one of the Raid page's sub-tabs (K.TAB_*), never
-- closing it.
function WhoDoesWhat:ShowRaidTab(key)
    self:ShowMainTab("raid", true)
    mainFrame.raidTabs:SelectTab(key)
end
