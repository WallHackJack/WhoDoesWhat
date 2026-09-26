local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local L = select(2, ...).L
local S = WhoDoesWhat.SettingsKit

-- Settings > Warrior Bar: the Warrior Shout Bar (WarriorShoutBarView.lua), in
-- whichever of its two account-wide settings sets is being edited.

local PAGE_X = S.PAGE_X
local AddCompactCheckboxRow = S.AddCompactCheckboxRow
local AddPageDivider = S.AddPageDivider
local AddNextPageDivider = S.AddNextPageDivider
local AddPageIntro = S.AddPageIntro
local AddDropdownRow = S.AddDropdownRow
local PageControlSwitch = S.PageControlSwitch
local AddHighlightControls = S.AddHighlightControls
local AddSliderWithInput = S.AddSliderWithInput

local function BuildWarriorBarPage(f, page)
    local warriorPage = page
    local shoutIntro, yL
    shoutIntro, yL = AddPageIntro(warriorPage, S.PAGE_TOP, L.SHOUT_INTRO)

    -- Two sets of these settings, per account: a warrior's, and everyone
    -- else's. The page opens on the set your class uses; picking the other
    -- shows it on the bar while you edit, and closing the settings hands the
    -- bar back to your class's set.
    local SHOUT_SET_KEYS = {
        warrior = "SHOUT_SET_WARRIOR", nonWarrior = "SHOUT_SET_NON_WARRIOR",
    }
    local shoutEditingLabel, shoutEditingDD
    shoutEditingLabel, shoutEditingDD, yL = AddDropdownRow(warriorPage, yL,
        L.SHOUT_EDITING_LABEL, "WhoDoesWhatShoutBarEditingDD")
    shoutEditingLabel:SetFontObject(GameFontNormalLarge)
    UIDropDownMenu_Initialize(shoutEditingDD, function(_, level)
        local current = WhoDoesWhat:GetShoutBarSettingsKey()
        for _, key in ipairs({ "warrior", "nonWarrior" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = L[SHOUT_SET_KEYS[key]]
            info.checked = current == key
            info.func = function()
                WhoDoesWhat:SetShoutBarEditingKey(key)
                S.LoadSettings(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(shoutEditingDD, shoutEditingLabel, L.SHOUT_EDITING,
        L.SHOUT_EDITING_TIP)
    f.shoutEditingDD = shoutEditingDD
    f.shoutSetKeys = SHOUT_SET_KEYS
    f:HookScript("OnHide", function() WhoDoesWhat:SetShoutBarEditingKey(nil) end)

    local shoutStore = function() return WhoDoesWhat:GetShoutBarSettings() end

    yL = AddPageDivider(warriorPage, yL, L.SHOUT_SECTION_BAR)
    local shoutEnableLabel
    f.shoutEnableCheck, yL, shoutEnableLabel = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, L.SHOUT_ENABLE, L.SHOUT_ENABLE_TIP,
        function(value)
            shoutStore().enabled = value
            WhoDoesWhat:LogUiBuilding("Warrior Shout Bar "
                .. (value and "enabled." or "disabled."))
            WhoDoesWhat:UpdateWarriorShoutBarVisibility()
            f.SetShoutControlsEnabled(value)
        end)
    -- The on switch greys out everything under it.
    f.SetShoutControlsEnabled = PageControlSwitch(warriorPage,
        { shoutIntro, shoutEditingLabel, shoutEditingDD, f.shoutEnableCheck,
            shoutEnableLabel })

    local shoutAnchorLabel, shoutAnchorDD
    shoutAnchorLabel, shoutAnchorDD, yL = AddDropdownRow(warriorPage, yL,
        L.SHOUT_ANCHOR_LABEL, "WhoDoesWhatShoutBarAnchorDD")
    UIDropDownMenu_Initialize(shoutAnchorDD, function(_, level)
        local saved = WhoDoesWhat:GetShoutBarAnchor()
        for _, anchor in ipairs(WhoDoesWhat.ShoutBarAnchors) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = L[anchor.labelKey]
            info.checked = (saved == anchor.key)
            info.func = function()
                WhoDoesWhat:SetShoutBarAnchor(anchor.key)
                UIDropDownMenu_SetText(shoutAnchorDD, L[anchor.labelKey])
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(shoutAnchorDD, shoutAnchorLabel, L.SHOUT_ANCHOR,
        L.SHOUT_ANCHOR_TIP)
    f.shoutAnchorDD = shoutAnchorDD

    local shoutTimerLabel, shoutTimerDD
    shoutTimerLabel, shoutTimerDD, yL = AddDropdownRow(warriorPage, yL,
        L.SHOUT_TIMER_LABEL, "WhoDoesWhatShoutBarTimerDD")
    UIDropDownMenu_Initialize(shoutTimerDD, function(_, level)
        local saved = WhoDoesWhat:GetShoutBarTimerSeconds()
        for _, seconds in ipairs(WhoDoesWhat.ShoutBarTimerSeconds) do
            local label = WhoDoesWhat:GetShoutBarTimerLabel(seconds)
            local info = UIDropDownMenu_CreateInfo()
            info.text = label
            info.checked = (saved == seconds)
            info.func = function()
                shoutStore().timerSeconds = seconds
                UIDropDownMenu_SetText(shoutTimerDD, label)
                WhoDoesWhat:RefreshWarriorShoutBar()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(shoutTimerDD, shoutTimerLabel, L.SHOUT_TIMER,
        L.SHOUT_TIMER_TIP)
    f.shoutTimerDD = shoutTimerDD

    yL = AddNextPageDivider(warriorPage, yL, L.SHOUT_SECTION_DISPLAY)
    f.shoutHideBackgroundCheck, yL = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, L.SHOUT_HIDE_BACKGROUND, L.SHOUT_HIDE_BACKGROUND_TIP,
        function(value)
            shoutStore().hideBackground = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    f.shoutHideNumbersCheck, yL = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, L.SHOUT_HIDE_NUMBERS, L.SHOUT_HIDE_NUMBERS_TIP,
        function(value)
            shoutStore().hideNumbers = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    f.shoutHideWhenBuffedCheck, yL = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, L.SHOUT_HIDE_WHEN_BUFFED, L.SHOUT_HIDE_WHEN_BUFFED_TIP,
        function(value)
            shoutStore().hideWhenBuffed = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    f.shoutHideWhenSelfBuffedCheck, yL = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, L.SHOUT_HIDE_WHEN_SELF_BUFFED, L.SHOUT_HIDE_WHEN_SELF_BUFFED_TIP,
        function(value)
            shoutStore().hideWhenSelfBuffed = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    -- Warrior Settings only: someone asking for a shout has no use for trimming
    -- who counts. Everything under it rides a frame of its own, so hiding the
    -- row slides the rest up rather than leaving a hole.
    local shoutRangeLabel, _
    f.shoutIgnoreRangeCheck, _, shoutRangeLabel = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, L.SHOUT_IGNORE_RANGE, L.SHOUT_IGNORE_RANGE_TIP,
        function(value)
            shoutStore().ignoreOutOfRange = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)
    local shoutRangeY = yL
    local shoutLower = CreateFrame("Frame", nil, warriorPage)
    local yLower = 0

    local shoutIconRange = WhoDoesWhat.SHOUT_BAR_ICON_SIZE
    f.RefreshShoutIconSize, yLower = AddSliderWithInput(shoutLower, PAGE_X,
        yLower, {
            name = "WhoDoesWhatShoutBarIconSizeSlider",
            label = L.BUFF_ICON_SIZE_LABEL,
            tooltip = L.SHOUT_ICON_SIZE_TIP,
            min = shoutIconRange.min,
            max = shoutIconRange.max,
        },
        function() return WhoDoesWhat:GetShoutBarIconSize() end,
        function(value) shoutStore().iconSize = value end,
        function() WhoDoesWhat:RefreshWarriorShoutBar() end)

    -- The status bars' highlight styles, in this bar's own two colours.
    yLower = AddNextPageDivider(shoutLower, yLower, L.SECTION_HIGHLIGHT)
    local shoutHighlightLabels, shoutHighlightFields
    f.RefreshShoutHighlight, yLower, shoutHighlightLabels, shoutHighlightFields =
        AddHighlightControls(shoutLower, PAGE_X, yLower, {
            name = "WhoDoesWhatShoutBarHighlightDD",
            tooltip = L.SHOUT_HIGHLIGHT_TIP,
            GetStyle = function() return shoutStore().glowStyle end,
            SetStyle = function(key) shoutStore().glowStyle = key end,
            Store = shoutStore,
            Defaults = function()
                return WhoDoesWhat.db.defaults.global.shoutBar[
                    WhoDoesWhat:GetShoutBarSettingsKey()]
            end,
            colors = {
                {
                    label = L.MISSING_COLOR_LABEL,
                    tooltip = L.SHOUT_MISSING_COLOR_TIP,
                    key = "glowMissingColor",
                },
                {
                    label = L.SHOUT_PARTIAL_COLOR_LABEL,
                    tooltip = L.SHOUT_PARTIAL_COLOR_TIP,
                    key = "glowPartialColor",
                },
            },
            OnChange = function() WhoDoesWhat:RefreshWarriorShoutBar() end,
        })
    -- Sized to what it holds, which is what the page's scroll height measures.
    shoutLower:SetHeight(yLower)

    -- The on switch reaches into the frame as well as the page around it.
    local SwitchShoutLower = PageControlSwitch(shoutLower, {})
    local SwitchShoutPage = f.SetShoutControlsEnabled
    f.SetShoutControlsEnabled = function(enabled)
        SwitchShoutPage(enabled)
        -- The page pass dims the frame as one more child; its own pass does
        -- the dimming inside it, and doing both would dim twice.
        shoutLower:SetAlpha(1)
        SwitchShoutLower(enabled)
    end

    -- The warrior-only rows in and out, the frame below following. The partial
    -- colour is the last row on the page, so it leaves no hole to close.
    function f.SetShoutWarriorRowsShown(shown)
        f.shoutIgnoreRangeCheck:SetShown(shown)
        shoutRangeLabel:SetShown(shown)
        shoutHighlightLabels[2]:SetShown(shown)
        shoutHighlightFields[2]:SetShown(shown)
        shoutLower:ClearAllPoints()
        shoutLower:SetPoint("TOPLEFT", 0, -(shoutRangeY + (shown and 28 or 0)))
        shoutLower:SetPoint("TOPRIGHT", 0, -(shoutRangeY + (shown and 28 or 0)))
    end
    f.SetShoutWarriorRowsShown(true)
end

local function RefreshWarriorBarPage(f)
    local self = WhoDoesWhat
    local shout = self:GetShoutBarSettings()
    UIDropDownMenu_SetText(f.shoutEditingDD,
        L[f.shoutSetKeys[self:GetShoutBarSettingsKey()]])
    f.shoutEnableCheck:SetChecked(shout.enabled)
    local shoutAnchor = self:GetShoutBarAnchor()
    UIDropDownMenu_SetText(f.shoutAnchorDD,
        self:GetShoutBarAnchorLabel(shoutAnchor))
    UIDropDownMenu_SetText(f.shoutTimerDD,
        self:GetShoutBarTimerLabel(self:GetShoutBarTimerSeconds()))
    f.shoutHideBackgroundCheck:SetChecked(shout.hideBackground)
    f.shoutHideNumbersCheck:SetChecked(shout.hideNumbers)
    f.shoutHideWhenBuffedCheck:SetChecked(shout.hideWhenBuffed)
    f.shoutHideWhenSelfBuffedCheck:SetChecked(shout.hideWhenSelfBuffed)
    f.shoutIgnoreRangeCheck:SetChecked(shout.ignoreOutOfRange)
    local editingWarrior = self:GetShoutBarSettingsKey() == "warrior"
    f.SetShoutWarriorRowsShown(editingWarrior)
    f.RefreshShoutIconSize()
    f.RefreshShoutHighlight()
    f.SetShoutControlsEnabled(shout.enabled and true or false)
end

S.RegisterPage({
    id = "Warrior Bar", labelKey = "SETTINGS_WARRIOR_BAR",
    titleKey = "SETTINGS_WARRIOR_BAR_TITLE", color = { 0.78, 0.61, 0.43 },
    descriptionKey = "SETTINGS_WARRIOR_BAR_RESET",
    Build = BuildWarriorBarPage,
    Refresh = RefreshWarriorBarPage,
    Reset = function() WhoDoesWhat:ResetShoutBarSettings() end,
})
