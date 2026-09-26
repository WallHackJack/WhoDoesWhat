local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
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

local function BuildPaladinBarPage(f, page)
    local paladinPage = page
    local paladinIntro, yL
    paladinIntro, yL = AddPageIntro(paladinPage, S.PAGE_TOP,"A clickable bar of your"
        .. " assigned blessings, a Nova-style alternative to PallyPower. Only"
        .. " shown when you're a paladin. Hover the bar and check the tooltips"
        .. " for additional info")
    yL = AddPageDivider(paladinPage, yL, "Bar")
    local buffingBarLabel
    f.buffingBarCheck, yL, buffingBarLabel = AddCompactCheckboxRow(paladinPage, PAGE_X, yL, "Enable Paladin Buffing Bar",
        "Show a movable, clickable bar of your assigned blessings - a Nova-style alternative to PallyPower. Appears only when you're a paladin, unless test mode is on.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarEnabled = value
            WhoDoesWhat:LogUiBuilding("Paladin Buffing Bar " .. (value and "enabled." or "disabled."))
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
            f.SetPaladinControlsEnabled(value)
        end)

    f.buffingAuraCheck, yL = AddCompactCheckboxRow(paladinPage, PAGE_X, yL,
        "Paladin Aura Helper",
        "Add an aura swapper at the left end of the bar. Hovering it opens a picker of every aura you know, left-click casts the one it's offering; it turns grey with a red glow while that aura isn't the one you're running.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarAuraButton = value
            WhoDoesWhat:LogUiBuilding("Paladin Aura Helper "
                .. (value and "enabled." or "disabled."))
            WhoDoesWhat:RefreshPaladinBuffingBar()
        end)

    f.buffingRighteousFuryCheck, yL = AddCompactCheckboxRow(paladinPage, PAGE_X, yL,
        "Righteous Fury Reminder",
        "Add a Righteous Fury button next to the aura swapper, shown only while you hold a tank role. Left-click refreshes it; red glow when it's down, yellow with a countdown in its last ten minutes.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarRighteousFury = value
            WhoDoesWhat:LogUiBuilding("Righteous Fury Reminder "
                .. (value and "enabled." or "disabled."))
            WhoDoesWhat:RefreshPaladinBuffingBar()
        end)

    f.buffingHideCompletedCheck, yL = AddCompactCheckboxRow(paladinPage, PAGE_X, yL,
        "Hide completed classes",
        "Drop a class button off the bar while everyone it covers is buffed, so the bar shows only what's left to do. Buttons come back as blessings lapse, though adding or removing one has to wait until you leave combat.",
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
    local ORIENT_LABELS = { HORIZONTAL = "Horizontal", VERTICAL = "Vertical" }
    local GROW_LABELS = { RIGHT = "Right", LEFT = "Left", DOWN = "Down",
        UP = "Up", CENTER = "From Center" }
    local BAR_GROW_MODES = { HORIZONTAL = { "RIGHT", "LEFT", "CENTER" },
        VERTICAL = { "DOWN", "UP", "CENTER" } }
    local MENU_GROW_MODES = { HORIZONTAL = { "DOWN", "UP" },
        VERTICAL = { "RIGHT", "LEFT" } }
    local function BuffingAxis()
        return WhoDoesWhat.db.profile.settings.buffingBarOrientation == "VERTICAL"
            and "VERTICAL" or "HORIZONTAL"
    end

    yL = AddNextPageDivider(paladinPage, yL, "Layout")
    local orientDD, growDD, menuGrowDD, _
    _, orientDD, yL = AddDropdownRow(paladinPage, yL, "Bar layout:",
        "WhoDoesWhatBuffingOrientDD")
    _, growDD, yL = AddDropdownRow(paladinPage, yL, "Bar grows:",
        "WhoDoesWhatBuffingGrowDD")
    _, menuGrowDD, yL = AddDropdownRow(paladinPage, yL, "Player menu grows:",
        "WhoDoesWhatBuffingMenuGrowDD")

    -- Re-label all three from the DB: the orientation dropdown changes what the
    -- other two are showing, and so does loading a different profile.
    local function RefreshBuffingLayout()
        UIDropDownMenu_SetText(orientDD, ORIENT_LABELS[BuffingAxis()])
        UIDropDownMenu_SetText(growDD, GROW_LABELS[WhoDoesWhat:GetBuffingBarGrow()])
        UIDropDownMenu_SetText(menuGrowDD,
            GROW_LABELS[WhoDoesWhat:GetBuffingMenuGrow()])
    end

    UIDropDownMenu_Initialize(orientDD, function(_, level)
        local saved = BuffingAxis()
        for _, mode in ipairs({ "HORIZONTAL", "VERTICAL" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = ORIENT_LABELS[mode]
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
            info.text = GROW_LABELS[mode]
            info.checked = (saved == mode)
            info.func = function()
                WhoDoesWhat:SetBuffingBarGrow(mode)
                UIDropDownMenu_SetText(growDD, GROW_LABELS[mode])
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.buffingGrowDD = growDD

    UIDropDownMenu_Initialize(menuGrowDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffingMenuGrow()
        for _, mode in ipairs(MENU_GROW_MODES[BuffingAxis()]) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = GROW_LABELS[mode]
            info.checked = (saved == mode)
            info.func = function()
                WhoDoesWhat:SetBuffingMenuGrow(mode)
                UIDropDownMenu_SetText(menuGrowDD, GROW_LABELS[mode])
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
            label = "Buff icon size:",
            tooltip = "How big each button on the bar is drawn, in pixels."
                .. " Everything else on the bar is measured off it, so the"
                .. " whole bar grows with it. Drag the slider or type an exact"
                .. " number; a resize during a fight waits until you leave"
                .. " combat.",
            min = buffingIconRange.min,
            max = buffingIconRange.max,
        },
        function() return WhoDoesWhat:GetBuffingBarIconSize() end,
        function(value) buffingSettings.buffingBarIconSize = value end,
        function() WhoDoesWhat:RefreshPaladinBuffingBar() end)

    -- One threshold, two tells: the countdown that appears over a class button
    -- and the yellow player rows inside it.
    yL = AddNextPageDivider(paladinPage, yL, "Highlight")
    local warnDD
    _, warnDD, yL = AddDropdownRow(paladinPage, yL, "Warn below:",
        "WhoDoesWhatBuffingWarnDD")
    local function WarnLabel(minutes)
        return minutes .. (minutes == 1 and " minute" or " minutes")
    end
    UIDropDownMenu_Initialize(warnDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffingWarnMinutes()
        for _, minutes in ipairs(WhoDoesWhat.BuffingWarnMinutes) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = WarnLabel(minutes)
            info.checked = (saved == minutes)
            info.func = function()
                WhoDoesWhat.db.profile.settings.buffingMenuWarnMinutes = minutes
                UIDropDownMenu_SetText(warnDD, WarnLabel(minutes))
                WhoDoesWhat:RefreshPaladinBuffingBar()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.buffingWarnDD = warnDD
    f.RefreshBuffingWarn = function()
        UIDropDownMenu_SetText(warnDD, WarnLabel(WhoDoesWhat:GetBuffingWarnMinutes()))
    end

    -- The status bars' highlight styles, in this bar's own two colours.
    f.RefreshBuffingHighlight, yL = AddHighlightControls(paladinPage,
        PAGE_X, yL, {
            name = "WhoDoesWhatBuffingBarHighlightDD",
            tooltip = "The animation a button on the bar wears when it wants"
                .. " your attention -- the box to the right shows it running."
                .. " The wide player rows inside a class button keep pulsing"
                .. " their own outline either way.",
            GetStyle = function()
                return buffingSettings.buffingBarGlowStyle
            end,
            SetStyle = function(key)
                buffingSettings.buffingBarGlowStyle = key
            end,
            colors = {
                {
                    label = "Missing color:",
                    tooltip = "The color a button glows while there is work on"
                        .. " it: a class with somebody still to buff, or a"
                        .. " self-buff that is down. Right-click the swatch to"
                        .. " reset it.",
                    key = "buffingBarGlowMissingColor",
                },
                {
                    label = "Expiring color:",
                    tooltip = "The color a self-buff button glows once it is"
                        .. " inside its warning window, with a countdown"
                        .. " running. Right-click the swatch to reset it.",
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
    label = "Paladin Bar", title = "Paladin Buffing Bar",
    color = { 0.96, 0.55, 0.73 },
    description = "Puts every option on this page back and moves the bar"
        .. " to where a fresh install finds it. Test mode on the Test +"
        .. " Dev page is left alone.",
    Build = BuildPaladinBarPage,
    Refresh = function(f) f.RefreshPaladinPage() end,
    Reset = function() WhoDoesWhat:ResetPaladinBarSettings() end,
})
