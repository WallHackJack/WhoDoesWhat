local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local S = WhoDoesWhat.SettingsKit

-- Addon settings (the main window's Settings tab). Checkbox state persists in db.profile.settings except
-- detailed sync logging, which is deliberately session-only and resets off.
--
-- This file is the tab around the pages: a second, indented row of tabs, the
-- shared title and Reset Defaults header, and a well per page. The pages are
-- the files in Views/Settings/, each registered with SettingsKit.

local settingsFrame = nil

-- The pages' tabs, left to right; a page flagged `right` runs from the other end.
local PAGE_ORDER = {
    "General", "Roles", "Status Bars", "Buffs", "Paladin Bar", "Warrior Bar",
    "Checklist", "Test + Dev",
}

-- Behind each section its well, and around the header and wells the slate
-- panel (Theme.lua).
local PAGE_WELL = WhoDoesWhat.Theme.pageWell
local PANEL_SLATE = WhoDoesWhat.Theme.panelSlate
-- The shared title and Reset Defaults strip above every section.
local HEADER_H = 34

-- Put every control back in step with the saved settings. Run each time the
-- page comes up, since anything can have changed them while it was away.
function S.LoadSettings(f)
    for _, section in ipairs(f.sections) do
        if section.Refresh then section.Refresh(f) end
    end
end

-- Every page's reset in one go (General's Reset ALL Defaults).
function S.ResetAllPages(f)
    for _, section in ipairs(f.sections) do
        section.Reset(f)
    end
    WhoDoesWhat:RefreshMainAssignmentsView()
    WhoDoesWhat:RefreshBoardViews()
    S.LoadSettings(f)
end

-- Build the page into the Settings tab: a second, indented row of tabs, one per
-- section, under one shared header, each over its own scroll area. A section's
-- scrollbar only appears if its content outgrows the tab.
function WhoDoesWhat:BuildAddonSettingsPage(tabPage)
    local f = CreateFrame("Frame", nil, tabPage)
    f:SetAllPoints(tabPage)
    f.titleBarHeight = 0

    local sections = {}
    for i, label in ipairs(PAGE_ORDER) do
        sections[i] = S.pages[label]
    end
    f.sections = sections

    local specs = {}
    for i, section in ipairs(sections) do
        specs[i] = { label = section.label, right = section.right }
    end
    -- The section panel, around the header and each section's well, in a
    -- lighter slate than the Settings tab's near-black: each well reads as sunk
    -- into it, and its edge shadows have something to fall away from.
    local sectionTabs = UI.AddTabs(f, specs,
        { colors = WhoDoesWhat.Theme.TabsWith({ panel = PANEL_SLATE },
            WhoDoesWhat.Theme.subTabs) })
    local panel = f.tabPanel

    -- One header for every section, above its content: the title, centred, and
    -- the Reset Defaults button hard right. Both read the section that is up.
    local header = CreateFrame("Frame", nil, panel)
    header:SetPoint("TOPLEFT", 10, -10)
    header:SetPoint("TOPRIGHT", -10, -10)
    header:SetHeight(HEADER_H)

    local title = CreateFrame("Frame", nil, header)
    title:SetPoint("CENTER", 0, 3)
    title.text = title:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title.text:SetPoint("CENTER")
    UI.AddTooltip(title, function()
        if f.section.tooltip then return f.section.title, f.section.tooltip end
    end)

    -- A page's reset, then every control read back: a reset can reach past
    -- its own page (the fake raid moves the buffing bar's test paladin).
    local resetButton = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
    resetButton:SetSize(110, 22)
    resetButton:SetPoint("RIGHT", 0, 4)
    resetButton:SetText("Reset Defaults")
    resetButton:SetScript("OnClick", function()
        local section = f.section
        StaticPopup_Show("WHODOESWHAT_RESET_SETTINGS", "Reset " .. section.title
            .. " to defaults?\n\n" .. section.description, nil, function()
                section.Reset(f)
                S.LoadSettings(f)
            end)
    end)
    UI.AddTooltip(resetButton, function()
        return "Reset " .. f.section.title, f.section.description
    end)

    -- Each section's content sits below the header in a well of its own,
    -- which is all its scroll area - and scrollbar - covers.
    local scrolls = {}
    for i, section in ipairs(sections) do
        local well = sectionTabs[i]
        well:ClearAllPoints()
        well:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -(10 + HEADER_H))
        well:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 10)
        local fill = well:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints()
        fill:SetColorTexture(PAGE_WELL[1], PAGE_WELL[2], PAGE_WELL[3], PAGE_WELL[4])
        well.fill = fill
        -- Flush with the grey on every side, bar the scrollbar's gutter. A
        -- shadow along the top and bottom edges shows the content scrolling
        -- under them. A page that re-lays its own well out draws its own.
        local scroll, page = UI.CreateScroll(well, "WhoDoesWhatSettingsSection" .. i)
        scroll:SetPoint("TOPLEFT")
        scroll:SetPoint("BOTTOMRIGHT", -UI.SCROLLBAR_W, 0)
        if not section.ownScroll then
            local level = scroll:GetFrameLevel() + 20
            local topEdge = UI.CreateEdgeShadow(well, level, true)
            topEdge:SetPoint("TOPLEFT")
            topEdge:SetPoint("TOPRIGHT")
            local bottomEdge = UI.CreateEdgeShadow(well, level, false)
            bottomEdge:SetPoint("BOTTOMLEFT")
            bottomEdge:SetPoint("BOTTOMRIGHT")
            -- Its arrows otherwise sit right at the ends, under the shadows.
            UI.InsetScrollBar(scroll, 12)
        end
        scrolls[i] = scroll
        section.Build(f, page, scroll)
    end

    -- A section always opens at its top, and is re-measured each time it comes
    -- up: what it shows can have changed since it was last looked at.
    f:OnTabSelected(function(index)
        UI.CancelColorPicker()
        local section = sections[index]
        f.section = section
        title.text:SetText(section.title)
        local color = section.color or { 1, 0.82, 0 }
        title.text:SetTextColor(color[1], color[2], color[3])
        title:SetSize(title.text:GetStringWidth(), title.text:GetStringHeight())
        f.currentScroll = scrolls[index]
        f.currentScroll:SetVerticalScroll(0)
        if section.OnShow then section.OnShow(f) end
        UI.FitScrollToContent(f.currentScroll)
    end)

    f.SelectSection = function(label)
        for i, section in ipairs(sections) do
            if section.label == label then f:SelectTab(i) return end
        end
    end

    f:SelectTab(1)
    f:HookScript("OnHide", UI.CancelColorPicker)
    f:SetScript("OnShow", function(self)
        S.LoadSettings(self)
        if self.currentScroll then UI.FitScrollToContent(self.currentScroll) end
    end)
    settingsFrame = f
    return f
end

-- Open the main window on the Settings tab, or close it if it is already there.
-- A section label opens straight to that section and never closes the window.
function WhoDoesWhat:OpenAddonSettingsView(section)
    if self:ShowMainTab("settings", section ~= nil) and section then
        settingsFrame.SelectSection(section)
    end
end
