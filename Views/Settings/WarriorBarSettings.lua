local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
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
    shoutIntro, yL = AddPageIntro(warriorPage, S.PAGE_TOP,"An efficient warrior"
        .. " buffing bar for shouts. Includes pets and ignores irrelevant party"
        .. " members based on WDW roles. Hover the bar and check the tooltips"
        .. " for additional info")

    -- Two sets of these settings, per account: a warrior's, and everyone
    -- else's. The page opens on the set your class uses; picking the other
    -- shows it on the bar while you edit, and closing the settings hands the
    -- bar back to your class's set.
    local SHOUT_SET_LABELS = {
        warrior = "Warrior Settings", nonWarrior = "Non-Warrior Settings",
    }
    local shoutEditingLabel, shoutEditingDD
    shoutEditingLabel, shoutEditingDD, yL = AddDropdownRow(warriorPage, yL,
        "Editing:", "WhoDoesWhatShoutBarEditingDD")
    shoutEditingLabel:SetFontObject(GameFontNormalLarge)
    UIDropDownMenu_Initialize(shoutEditingDD, function(_, level)
        local current = WhoDoesWhat:GetShoutBarSettingsKey()
        for _, key in ipairs({ "warrior", "nonWarrior" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = SHOUT_SET_LABELS[key]
            info.checked = current == key
            info.func = function()
                WhoDoesWhat:SetShoutBarEditingKey(key)
                S.LoadSettings(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(shoutEditingDD, shoutEditingLabel, "Editing",
        "Warriors and everyone else keep separate Warrior Shout Bar settings,"
        .. " shared across your account. A warrior's bar casts shouts; anyone"
        .. " else's asks for them in party chat.\n\nThe bar shows the set you"
        .. " are editing until you close the settings, then goes back to the"
        .. " set for your class.")
    f.shoutEditingDD = shoutEditingDD
    f.shoutSetLabels = SHOUT_SET_LABELS
    f:HookScript("OnHide", function() WhoDoesWhat:SetShoutBarEditingKey(nil) end)

    local shoutStore = function() return WhoDoesWhat:GetShoutBarSettings() end

    yL = AddPageDivider(warriorPage, yL, "Bar")
    local shoutEnableLabel
    f.shoutEnableCheck, yL, shoutEnableLabel = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, "Enable Warrior Shout Bar",
        "Shows the bar while your party has a warrior in it. A warrior's bar"
        .. " casts shouts; anyone else's asks for them.",
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
        "Anchor:", "WhoDoesWhatShoutBarAnchorDD")
    UIDropDownMenu_Initialize(shoutAnchorDD, function(_, level)
        local saved = WhoDoesWhat:GetShoutBarAnchor()
        for _, anchor in ipairs(WhoDoesWhat.ShoutBarAnchors) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = anchor.label
            info.checked = (saved == anchor.key)
            info.func = function()
                WhoDoesWhat:SetShoutBarAnchor(anchor.key)
                UIDropDownMenu_SetText(shoutAnchorDD, anchor.label)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(shoutAnchorDD, shoutAnchorLabel, "Anchor",
        "Which edge of the bar stays put when a shout icon comes or goes."
        .. " Center spreads it both ways.")
    f.shoutAnchorDD = shoutAnchorDD

    local shoutTimerLabel, shoutTimerDD
    shoutTimerLabel, shoutTimerDD, yL = AddDropdownRow(warriorPage, yL,
        "Countdown Timer:", "WhoDoesWhatShoutBarTimerDD")
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
    UI.AddDropdownTooltip(shoutTimerDD, shoutTimerLabel, "Countdown Timer",
        "Puts a countdown over the icon once the first person is that close to"
        .. " losing the shout. Always shows it whenever the shout is up; Never"
        .. " hides it entirely.")
    f.shoutTimerDD = shoutTimerDD

    yL = AddNextPageDivider(warriorPage, yL, "Display")
    f.shoutHideBackgroundCheck, yL = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, "Hide background",
        "Leaves just the icons floating on your screen. Alt-drag still moves"
        .. " the bar.",
        function(value)
            shoutStore().hideBackground = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    f.shoutHideNumbersCheck, yL = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, "Hide Coverage Numbers",
        "Drops the count under each icon. The glow still tells you somebody is"
        .. " missing the shout, and the tooltip still names them.",
        function(value)
            shoutStore().hideNumbers = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    f.shoutHideWhenBuffedCheck, yL = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, "Hide while everything is up",
        "Hides each icon while its own shout is on everybody, and brings it"
        .. " back the moment somebody loses it. Hidden icons can't be clicked"
        .. " or dragged, so place the bar before turning this on.",
        function(value)
            shoutStore().hideWhenBuffed = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    f.shoutHideWhenSelfBuffedCheck, yL = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, "Hide when I have it",
        "Hides each icon while its shout is on you, even if others in your"
        .. " party are still missing it. Hidden icons can't be clicked or"
        .. " dragged, so place the bar before turning this on.",
        function(value)
            shoutStore().hideWhenSelfBuffed = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    -- Warrior Settings only: someone asking for a shout has no use for trimming
    -- who counts. Everything under it rides a frame of its own, so hiding the
    -- row slides the rest up rather than leaving a hole.
    local shoutRangeLabel, _
    f.shoutIgnoreRangeCheck, _, shoutRangeLabel = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, "Ignore players far out of range",
        "Stops counting party members who are nowhere near you. Anyone just a"
        .. " step too far back still counts, since stepping in is the fix.",
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
            label = "Buff icon size:",
            tooltip = "How big each shout icon is drawn, in pixels. The bar is"
                .. " exactly as wide as its icons, so this sizes the whole"
                .. " strip. Drag the slider or type an exact number; a resize"
                .. " during a fight waits until you leave combat.",
            min = shoutIconRange.min,
            max = shoutIconRange.max,
        },
        function() return WhoDoesWhat:GetShoutBarIconSize() end,
        function(value) shoutStore().iconSize = value end,
        function() WhoDoesWhat:RefreshWarriorShoutBar() end)

    -- The status bars' highlight styles, in this bar's own two colours.
    yLower = AddNextPageDivider(shoutLower, yLower, "Highlight")
    local shoutHighlightLabels, shoutHighlightFields
    f.RefreshShoutHighlight, yLower, shoutHighlightLabels, shoutHighlightFields =
        AddHighlightControls(shoutLower, PAGE_X, yLower, {
            name = "WhoDoesWhatShoutBarHighlightDD",
            tooltip = "The animation a shout icon wears while somebody in the"
                .. " party is missing that shout -- the box to the right shows"
                .. " it running.",
            GetStyle = function() return shoutStore().glowStyle end,
            SetStyle = function(key) shoutStore().glowStyle = key end,
            Store = shoutStore,
            Defaults = function()
                return WhoDoesWhat.db.defaults.global.shoutBar[
                    WhoDoesWhat:GetShoutBarSettingsKey()]
            end,
            colors = {
                {
                    label = "Missing color:",
                    tooltip = "The color a shout icon glows while nobody in"
                        .. " the party has that shout. Right-click the swatch"
                        .. " to reset it.",
                    key = "glowMissingColor",
                },
                {
                    label = "Partial color:",
                    tooltip = "The color a shout icon glows once some of the"
                        .. " party has that shout but not all of it. Right-click"
                        .. " the swatch to reset it.",
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
        f.shoutSetLabels[self:GetShoutBarSettingsKey()])
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
    label = "Warrior Bar", title = "Warrior Shouts", color = { 0.78, 0.61, 0.43 },
    description = "Puts every option on this page back and re-centres the"
        .. " shout bar -- for the settings you are editing now only.",
    Build = BuildWarriorBarPage,
    Refresh = RefreshWarriorBarPage,
    Reset = function() WhoDoesWhat:ResetShoutBarSettings() end,
})
