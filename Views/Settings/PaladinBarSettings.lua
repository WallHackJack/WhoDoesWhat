local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local L = select(2, ...).L
local S = WhoDoesWhat.SettingsKit

-- Settings > Paladin Bar: the Paladin Buffing Bar (PaladinBuffingBarView.lua).
-- Its test mode is on the Test + Dev page.

local PAGE_X = S.PAGE_X
local AddCompactCheckboxRow = S.AddCompactCheckboxRow
local AddPageDivider = S.AddPageDivider
local AddNextPageDivider = S.AddNextPageDivider
local AddPageIntro = S.AddPageIntro
local AddDropdownRow = S.AddDropdownRow
local PageControlSwitch = S.PageControlSwitch
local AddHighlightControls = S.AddHighlightControls
local AddSliderWithInput = S.AddSliderWithInput

-- The layout dropdowns' choices, as string keys.
local ORIENT_KEYS = { HORIZONTAL = "LAYOUT_HORIZONTAL", VERTICAL = "LAYOUT_VERTICAL" }
local GROW_KEYS = { RIGHT = "LAYOUT_GROW_RIGHT", LEFT = "LAYOUT_GROW_LEFT",
    DOWN = "LAYOUT_GROW_DOWN", UP = "LAYOUT_GROW_UP", CENTER = "LAYOUT_GROW_CENTER" }

local function BuildPaladinBarPage(f, page)
    local paladinPage = page
    local paladinIntro, yL
    paladinIntro, yL = AddPageIntro(paladinPage, S.PAGE_TOP, L.PALADIN_BAR_INTRO)
    yL = AddPageDivider(paladinPage, yL, L.PALADIN_BAR_SECTION)
    local buffingBarLabel
    f.buffingBarCheck, yL, buffingBarLabel = AddCompactCheckboxRow(paladinPage, PAGE_X, yL,
        L.PALADIN_BAR_ENABLE, L.PALADIN_BAR_ENABLE_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarEnabled = value
            WhoDoesWhat:LogUiBuilding("Paladin Buffing Bar " .. (value and "enabled." or "disabled."))
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
            f.SetPaladinControlsEnabled(value)
        end)

    f.buffingAuraCheck, yL = AddCompactCheckboxRow(paladinPage, PAGE_X, yL,
        L.PALADIN_BAR_AURA_HELPER, L.PALADIN_BAR_AURA_HELPER_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarAuraButton = value
            WhoDoesWhat:LogUiBuilding("Paladin Aura Helper "
                .. (value and "enabled." or "disabled."))
            WhoDoesWhat:RefreshPaladinBuffingBar()
        end)

    f.buffingRighteousFuryCheck, yL = AddCompactCheckboxRow(paladinPage, PAGE_X, yL,
        L.PALADIN_BAR_RIGHTEOUS_FURY, L.PALADIN_BAR_RIGHTEOUS_FURY_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarRighteousFury = value
            WhoDoesWhat:LogUiBuilding("Righteous Fury Reminder "
                .. (value and "enabled." or "disabled."))
            WhoDoesWhat:RefreshPaladinBuffingBar()
        end)

    f.buffingHideCompletedCheck, yL = AddCompactCheckboxRow(paladinPage, PAGE_X, yL,
        L.PALADIN_BAR_HIDE_COMPLETED, L.PALADIN_BAR_HIDE_COMPLETED_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarHideCompleted = value
            WhoDoesWhat:LogUiBuilding("Buffing bar completed-class hiding "
                .. (value and "enabled." or "disabled."))
            WhoDoesWhat:RefreshPaladinBuffingBar()
        end)

    -- Three linked dropdowns. The orientation decides which axis the other two
    -- speak, so both of their option lists (and the text on their buttons) are
    -- read off it rather than fixed; the view translates the saved choices when
    -- the bar turns, so nothing here has to.
    local BAR_GROW_MODES = { HORIZONTAL = { "RIGHT", "LEFT", "CENTER" },
        VERTICAL = { "DOWN", "UP", "CENTER" } }
    local MENU_GROW_MODES = { HORIZONTAL = { "DOWN", "UP" },
        VERTICAL = { "RIGHT", "LEFT" } }
    local function BuffingAxis()
        return WhoDoesWhat.db.profile.settings.buffingBarOrientation == "VERTICAL"
            and "VERTICAL" or "HORIZONTAL"
    end

    yL = AddNextPageDivider(paladinPage, yL, L.PALADIN_BAR_SECTION_LAYOUT)
    local orientDD, growDD, menuGrowDD, _
    _, orientDD, yL = AddDropdownRow(paladinPage, yL, L.PALADIN_BAR_LAYOUT_LABEL,
        "WhoDoesWhatBuffingOrientDD")
    _, growDD, yL = AddDropdownRow(paladinPage, yL, L.PALADIN_BAR_GROWS_LABEL,
        "WhoDoesWhatBuffingGrowDD")
    _, menuGrowDD, yL = AddDropdownRow(paladinPage, yL, L.PALADIN_BAR_MENU_GROWS_LABEL,
        "WhoDoesWhatBuffingMenuGrowDD")

    -- Re-label all three from the DB: the orientation dropdown changes what the
    -- other two are showing, and so does loading a different profile.
    local function RefreshBuffingLayout()
        UIDropDownMenu_SetText(orientDD, L[ORIENT_KEYS[BuffingAxis()]])
        UIDropDownMenu_SetText(growDD, L[GROW_KEYS[WhoDoesWhat:GetBuffingBarGrow()]])
        UIDropDownMenu_SetText(menuGrowDD,
            L[GROW_KEYS[WhoDoesWhat:GetBuffingMenuGrow()]])
    end

    UIDropDownMenu_Initialize(orientDD, function(_, level)
        local saved = BuffingAxis()
        for _, mode in ipairs({ "HORIZONTAL", "VERTICAL" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = L[ORIENT_KEYS[mode]]
            info.checked = (saved == mode)
            info.func = function()
                WhoDoesWhat:SetBuffingBarOrientation(mode)
                RefreshBuffingLayout()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.buffingOrientDD = orientDD

    UIDropDownMenu_Initialize(growDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffingBarGrow()
        for _, mode in ipairs(BAR_GROW_MODES[BuffingAxis()]) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = L[GROW_KEYS[mode]]
            info.checked = (saved == mode)
            info.func = function()
                WhoDoesWhat:SetBuffingBarGrow(mode)
                UIDropDownMenu_SetText(growDD, L[GROW_KEYS[mode]])
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.buffingGrowDD = growDD

    UIDropDownMenu_Initialize(menuGrowDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffingMenuGrow()
        for _, mode in ipairs(MENU_GROW_MODES[BuffingAxis()]) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = L[GROW_KEYS[mode]]
            info.checked = (saved == mode)
            info.func = function()
                WhoDoesWhat:SetBuffingMenuGrow(mode)
                UIDropDownMenu_SetText(menuGrowDD, L[GROW_KEYS[mode]])
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.buffingMenuGrowDD = menuGrowDD

    local buffingSettings = WhoDoesWhat.db.profile.settings
    local buffingIconRange = WhoDoesWhat.BUFFING_BAR_ICON_SIZE
    f.RefreshBuffingIconSize, yL = AddSliderWithInput(paladinPage, PAGE_X,
        yL, {
            name = "WhoDoesWhatBuffingBarIconSizeSlider",
            label = L.BUFF_ICON_SIZE_LABEL,
            tooltip = L.PALADIN_BAR_ICON_SIZE_TIP,
            min = buffingIconRange.min,
            max = buffingIconRange.max,
        },
        function() return WhoDoesWhat:GetBuffingBarIconSize() end,
        function(value) buffingSettings.buffingBarIconSize = value end,
        function() WhoDoesWhat:RefreshPaladinBuffingBar() end)

    -- One threshold, two tells: the countdown that appears over a class button
    -- and the yellow player rows inside it.
    yL = AddNextPageDivider(paladinPage, yL, L.SECTION_HIGHLIGHT)
    local warnDD
    _, warnDD, yL = AddDropdownRow(paladinPage, yL, L.WARN_BELOW_LABEL,
        "WhoDoesWhatBuffingWarnDD")
    UIDropDownMenu_Initialize(warnDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffingWarnMinutes()
        for _, minutes in ipairs(WhoDoesWhat.BuffingWarnMinutes) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = S.MinutesLabel(minutes)
            info.checked = (saved == minutes)
            info.func = function()
                WhoDoesWhat.db.profile.settings.buffingMenuWarnMinutes = minutes
                UIDropDownMenu_SetText(warnDD, S.MinutesLabel(minutes))
                WhoDoesWhat:RefreshPaladinBuffingBar()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.buffingWarnDD = warnDD
    f.RefreshBuffingWarn = function()
        UIDropDownMenu_SetText(warnDD, S.MinutesLabel(WhoDoesWhat:GetBuffingWarnMinutes()))
    end

    -- The status bars' highlight styles, in this bar's own two colours.
    f.RefreshBuffingHighlight, yL = AddHighlightControls(paladinPage,
        PAGE_X, yL, {
            name = "WhoDoesWhatBuffingBarHighlightDD",
            tooltip = L.PALADIN_BAR_HIGHLIGHT_TIP,
            GetStyle = function()
                return buffingSettings.buffingBarGlowStyle
            end,
            SetStyle = function(key)
                buffingSettings.buffingBarGlowStyle = key
            end,
            colors = {
                {
                    label = L.MISSING_COLOR_LABEL,
                    tooltip = L.PALADIN_BAR_MISSING_COLOR_TIP,
                    key = "buffingBarGlowMissingColor",
                },
                {
                    label = L.EXPIRING_COLOR_LABEL,
                    tooltip = L.PALADIN_BAR_EXPIRING_COLOR_TIP,
                    key = "buffingBarGlowExpiringColor",
                },
            },
            OnChange = function()
                WhoDoesWhat:RefreshPaladinBuffingBar()
            end,
        })

    -- Every widget on this page, read back out of the settings. Called when the
    -- window opens and again after the Defaults button has rewritten them.
    f.SetPaladinControlsEnabled = PageControlSwitch(paladinPage,
        { paladinIntro, f.buffingBarCheck, buffingBarLabel })
    f.RefreshPaladinPage = function()
        local settings = WhoDoesWhat.db.profile.settings
        f.buffingBarCheck:SetChecked(settings.buffingBarEnabled)
        f.buffingAuraCheck:SetChecked(settings.buffingBarAuraButton ~= false)
        f.buffingRighteousFuryCheck:SetChecked(
            settings.buffingBarRighteousFury ~= false)
        f.buffingHideCompletedCheck:SetChecked(settings.buffingBarHideCompleted)
        RefreshBuffingLayout()
        f.RefreshBuffingWarn()
        f.RefreshBuffingIconSize()
        f.RefreshBuffingHighlight()
        f.SetPaladinControlsEnabled(settings.buffingBarEnabled and true or false)
    end
end

S.RegisterPage({
    id = "Paladin Bar", labelKey = "SETTINGS_PALADIN_BAR",
    titleKey = "SETTINGS_PALADIN_BAR_TITLE", color = { 0.96, 0.55, 0.73 },
    descriptionKey = "SETTINGS_PALADIN_BAR_RESET",
    Build = BuildPaladinBarPage,
    Refresh = function(f) f.RefreshPaladinPage() end,
    Reset = function() WhoDoesWhat:ResetPaladinBarSettings() end,
})
