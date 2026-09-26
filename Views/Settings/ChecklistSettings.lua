local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local L = select(2, ...).L
local S = WhoDoesWhat.SettingsKit

-- Settings > Checklist: the Buff Checklist (BuffChecklistView.lua). The item
-- tracking rows are per character; everything else is the profile's.

local PAGE_X = S.PAGE_X
local AddCompactCheckboxRow = S.AddCompactCheckboxRow
local AddPageDivider = S.AddPageDivider
local AddNextPageDivider = S.AddNextPageDivider
local AddPageIntro = S.AddPageIntro
local AddDropdownRow = S.AddDropdownRow
local PageControlSwitch = S.PageControlSwitch
local AddHighlightControls = S.AddHighlightControls
local AddSliderWithInput = S.AddSliderWithInput

local function BuildChecklistPage(f, page)
    local checklistPage = page
    local checklistIntro, yL
    checklistIntro, yL = AddPageIntro(checklistPage, S.PAGE_TOP, L.CHECKLIST_INTRO)
    local checklistSettings = function() return WhoDoesWhat.db.profile.settings end

    yL = AddPageDivider(checklistPage, yL, L.CHECKLIST_SECTION)
    local checklistEnableLabel
    f.checklistEnableCheck, yL, checklistEnableLabel = AddCompactCheckboxRow(
        checklistPage, PAGE_X, yL, L.CHECKLIST_ENABLE, L.CHECKLIST_ENABLE_TIP,
        function(value)
            checklistSettings().buffChecklistEnabled = value
            WhoDoesWhat:RefreshBuffChecklist()
            f.SetChecklistControlsEnabled(value)
        end)
    f.SetChecklistControlsEnabled = PageControlSwitch(checklistPage,
        { checklistIntro, f.checklistEnableCheck, checklistEnableLabel })

    local checklistAlignLabel, checklistAlignDD
    checklistAlignLabel, checklistAlignDD, yL = AddDropdownRow(checklistPage, yL,
        L.CHECKLIST_ALIGN_LABEL, "WhoDoesWhatBuffChecklistAlignDD")
    UIDropDownMenu_Initialize(checklistAlignDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffChecklistAlign()
        for _, align in ipairs(WhoDoesWhat.BuffChecklistAligns) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = L[align.labelKey]
            info.checked = saved == align.key
            info.func = function()
                WhoDoesWhat:SetBuffChecklistAlign(align.key)
                UIDropDownMenu_SetText(checklistAlignDD, L[align.labelKey])
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(checklistAlignDD, checklistAlignLabel, L.CHECKLIST_ALIGN,
        L.CHECKLIST_ALIGN_TIP)
    f.checklistAlignDD = checklistAlignDD

    local checklistPopoutLabel, checklistPopoutDD
    checklistPopoutLabel, checklistPopoutDD, yL = AddDropdownRow(checklistPage, yL,
        L.CHECKLIST_POPOUT_LABEL, "WhoDoesWhatBuffChecklistPopoutDD")
    UIDropDownMenu_Initialize(checklistPopoutDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffChecklistPopoutDirection()
        for _, direction in ipairs(WhoDoesWhat.BuffChecklistPopoutDirections) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = L[direction.labelKey]
            info.checked = saved == direction
            info.func = function()
                checklistSettings().buffChecklistPopoutDirection = direction.key
                UIDropDownMenu_SetText(checklistPopoutDD, L[direction.labelKey])
                WhoDoesWhat:RefreshBuffChecklist()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(checklistPopoutDD, checklistPopoutLabel,
        L.CHECKLIST_POPOUT, L.CHECKLIST_POPOUT_TIP)
    f.checklistPopoutDD = checklistPopoutDD

    local columnRange = WhoDoesWhat.BUFF_CHECKLIST_COLUMNS
    f.RefreshChecklistColumns, yL = AddSliderWithInput(checklistPage, PAGE_X, yL, {
            name = "WhoDoesWhatBuffChecklistColumnsSlider",
            label = L.CHECKLIST_COLUMNS_LABEL,
            tooltip = L.CHECKLIST_COLUMNS_TIP,
            min = columnRange.min,
            max = columnRange.max,
        },
        function() return WhoDoesWhat:GetBuffChecklistColumns() end,
        function(value) checklistSettings().buffChecklistColumns = value end,
        function() WhoDoesWhat:RefreshBuffChecklist() end)

    local checklistIconRange = WhoDoesWhat.BUFF_CHECKLIST_ICON_SIZE
    f.RefreshChecklistIconSize, yL = AddSliderWithInput(checklistPage, PAGE_X, yL, {
            name = "WhoDoesWhatBuffChecklistIconSizeSlider",
            label = L.BUFF_ICON_SIZE_LABEL,
            tooltip = L.CHECKLIST_ICON_SIZE_TIP,
            min = checklistIconRange.min,
            max = checklistIconRange.max,
        },
        function() return WhoDoesWhat:GetBuffChecklistIconSize() end,
        function(value) checklistSettings().buffChecklistIconSize = value end,
        function() WhoDoesWhat:RefreshBuffChecklist() end)

    local checklistSpacingLabel, checklistSpacingDD
    checklistSpacingLabel, checklistSpacingDD, yL = AddDropdownRow(checklistPage, yL,
        L.CHECKLIST_SPACING_LABEL, "WhoDoesWhatBuffChecklistSpacingDD")
    UIDropDownMenu_Initialize(checklistSpacingDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffChecklistSpacing()
        for _, spacing in ipairs(WhoDoesWhat.BuffChecklistSpacings) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = L[spacing.labelKey]
            info.checked = saved == spacing
            info.func = function()
                checklistSettings().buffChecklistSpacing = spacing.key
                UIDropDownMenu_SetText(checklistSpacingDD, L[spacing.labelKey])
                WhoDoesWhat:RefreshBuffChecklist()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(checklistSpacingDD, checklistSpacingLabel,
        L.CHECKLIST_SPACING, L.CHECKLIST_SPACING_TIP)
    f.checklistSpacingDD = checklistSpacingDD

    f.checklistHeaderCheck, yL = AddCompactCheckboxRow(checklistPage,
        PAGE_X, yL, L.CHECKLIST_SHOW_HEADER, L.CHECKLIST_SHOW_HEADER_TIP,
        function(value)
            checklistSettings().buffChecklistShowHeader = value
            WhoDoesWhat:RefreshBuffChecklist()
        end)

    f.checklistSplitOthersCheck, yL = AddCompactCheckboxRow(checklistPage,
        PAGE_X, yL, L.CHECKLIST_SPLIT_OTHERS, L.CHECKLIST_SPLIT_OTHERS_TIP,
        function(value)
            checklistSettings().buffChecklistSplitOthers = value
            WhoDoesWhat:RefreshBuffChecklist()
        end)

    f.checklistHideHaveCheck, yL = AddCompactCheckboxRow(checklistPage,
        PAGE_X, yL, L.CHECKLIST_HIDE_HAVE, L.CHECKLIST_HIDE_HAVE_TIP,
        function(value)
            checklistSettings().buffChecklistHideHave = value
            WhoDoesWhat:RefreshBuffChecklist()
        end)

    f.checklistHideOthersCheck, yL = AddCompactCheckboxRow(checklistPage,
        PAGE_X, yL, L.CHECKLIST_HIDE_OTHERS, L.CHECKLIST_HIDE_OTHERS_TIP,
        function(value)
            checklistSettings().buffChecklistHideOthersHave = value
            WhoDoesWhat:RefreshBuffChecklist()
        end)

    -- Classic Era has no battle/guardian elixir split, so no row for it.
    if WhoDoesWhat.ElixirItems then
        f.checklistElixirsCheck, yL = AddCompactCheckboxRow(checklistPage,
            PAGE_X, yL, L.CHECKLIST_TRACK_ELIXIRS, L.CHECKLIST_TRACK_ELIXIRS_TIP,
            function(value)
                WhoDoesWhat.db.char.buffChecklistElixirs = value
                WhoDoesWhat:RefreshBuffChecklist()
            end)
    end

    f.checklistScrollsCheck, yL = AddCompactCheckboxRow(checklistPage,
        PAGE_X, yL, L.CHECKLIST_TRACK_SCROLLS, L.CHECKLIST_TRACK_SCROLLS_TIP,
        function(value)
            WhoDoesWhat.db.char.buffChecklistScrolls = value
            WhoDoesWhat:RefreshBuffChecklist()
        end)

    f.checklistWeaponsCheck, yL = AddCompactCheckboxRow(checklistPage,
        PAGE_X, yL, L.CHECKLIST_TRACK_WEAPONS, L.CHECKLIST_TRACK_WEAPONS_TIP,
        function(value)
            WhoDoesWhat.db.char.buffChecklistWeapons = value
            WhoDoesWhat:RefreshBuffChecklist()
        end)

    -- The status bars' highlight styles, in the checklist's own two colours.
    yL = AddNextPageDivider(checklistPage, yL, L.SECTION_HIGHLIGHT)
    -- One threshold, two tells, as on the Paladin Bar: the countdown over an
    -- icon and its expiring glow.
    local checklistWarnLabel, checklistWarnDD
    checklistWarnLabel, checklistWarnDD, yL = AddDropdownRow(checklistPage, yL,
        L.WARN_BELOW_LABEL, "WhoDoesWhatBuffChecklistWarnDD")
    UIDropDownMenu_Initialize(checklistWarnDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffChecklistWarnMinutes()
        for _, minutes in ipairs(WhoDoesWhat.BuffingWarnMinutes) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = S.MinutesLabel(minutes)
            info.checked = (saved == minutes)
            info.func = function()
                checklistSettings().buffChecklistWarnMinutes = minutes
                UIDropDownMenu_SetText(checklistWarnDD, S.MinutesLabel(minutes))
                WhoDoesWhat:RefreshBuffChecklist()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(checklistWarnDD, checklistWarnLabel, L.WARN_BELOW,
        L.CHECKLIST_WARN_BELOW_TIP)
    f.RefreshChecklistWarn = function()
        UIDropDownMenu_SetText(checklistWarnDD,
            S.MinutesLabel(WhoDoesWhat:GetBuffChecklistWarnMinutes()))
    end

    f.RefreshChecklistHighlight, yL = AddHighlightControls(checklistPage,
        PAGE_X, yL, {
            name = "WhoDoesWhatBuffChecklistHighlightDD",
            -- Icons packed edge to edge leave no room for wings beside them.
            noWings = true,
            tooltip = L.CHECKLIST_HIGHLIGHT_TIP,
            GetStyle = function()
                return checklistSettings().buffChecklistGlowStyle
            end,
            SetStyle = function(key)
                checklistSettings().buffChecklistGlowStyle = key
            end,
            colors = {
                {
                    label = L.MISSING_COLOR_LABEL,
                    tooltip = L.CHECKLIST_MISSING_COLOR_TIP,
                    key = "buffChecklistGlowMissingColor",
                },
                {
                    label = L.EXPIRING_COLOR_LABEL,
                    tooltip = L.CHECKLIST_EXPIRING_COLOR_TIP,
                    key = "buffChecklistGlowExpiringColor",
                },
            },
            OnChange = function() WhoDoesWhat:RefreshBuffChecklist() end,
        })
end

local function RefreshChecklistPage(f)
    local self = WhoDoesWhat
    local settings = self.db.profile.settings
    f.checklistEnableCheck:SetChecked(settings.buffChecklistEnabled)
    f.checklistHideHaveCheck:SetChecked(settings.buffChecklistHideHave)
    f.checklistHideOthersCheck:SetChecked(settings.buffChecklistHideOthersHave)
    f.checklistHeaderCheck:SetChecked(settings.buffChecklistShowHeader)
    f.checklistSplitOthersCheck:SetChecked(settings.buffChecklistSplitOthers)
    f.checklistWeaponsCheck:SetChecked(self.db.char.buffChecklistWeapons)
    f.RefreshChecklistWarn()
    f.RefreshChecklistHighlight()
    if f.checklistElixirsCheck then
        f.checklistElixirsCheck:SetChecked(self.db.char.buffChecklistElixirs)
    end
    f.checklistScrollsCheck:SetChecked(self.db.char.buffChecklistScrolls)
    UIDropDownMenu_SetText(f.checklistAlignDD,
        self:GetBuffChecklistAlignLabel(self:GetBuffChecklistAlign()))
    UIDropDownMenu_SetText(f.checklistPopoutDD,
        L[self:GetBuffChecklistPopoutDirection().labelKey])
    f.RefreshChecklistColumns()
    f.RefreshChecklistIconSize()
    UIDropDownMenu_SetText(f.checklistSpacingDD,
        L[self:GetBuffChecklistSpacing().labelKey])
    f.SetChecklistControlsEnabled(settings.buffChecklistEnabled and true or false)
end

S.RegisterPage({
    id = "Checklist", labelKey = "SETTINGS_CHECKLIST",
    titleKey = "SETTINGS_CHECKLIST_TITLE", descriptionKey = "SETTINGS_CHECKLIST_RESET",
    Build = BuildChecklistPage,
    Refresh = RefreshChecklistPage,
    Reset = function() WhoDoesWhat:ResetBuffChecklistSettings() end,
})
