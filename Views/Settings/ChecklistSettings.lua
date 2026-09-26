local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
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
    checklistIntro, yL = AddPageIntro(checklistPage, S.PAGE_TOP,"A grid of the buffs"
        .. " your character should have: the blessings the plan gives you, the"
        .. " class buffs and food Buff Tracking checks, your party's shouts, and"
        .. " your weapon enchants. Shift-click a missing buff to ask for it;"
        .. " click food or a weapon to pick an item, then right-click to use it.")
    local checklistSettings = function() return WhoDoesWhat.db.profile.settings end

    yL = AddPageDivider(checklistPage, yL, "Checklist")
    local checklistEnableLabel
    f.checklistEnableCheck, yL, checklistEnableLabel = AddCompactCheckboxRow(
        checklistPage, PAGE_X, yL, "Enable Buff Checklist (Beta)",
        "Shows the checklist whenever there is a buff you should have.",
        function(value)
            checklistSettings().buffChecklistEnabled = value
            WhoDoesWhat:RefreshBuffChecklist()
            f.SetChecklistControlsEnabled(value)
        end)
    f.SetChecklistControlsEnabled = PageControlSwitch(checklistPage,
        { checklistIntro, f.checklistEnableCheck, checklistEnableLabel })

    local checklistAlignLabel, checklistAlignDD
    checklistAlignLabel, checklistAlignDD, yL = AddDropdownRow(checklistPage, yL,
        "Align:", "WhoDoesWhatBuffChecklistAlignDD")
    UIDropDownMenu_Initialize(checklistAlignDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffChecklistAlign()
        for _, align in ipairs(WhoDoesWhat.BuffChecklistAligns) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = align.label
            info.checked = saved == align.key
            info.func = function()
                WhoDoesWhat:SetBuffChecklistAlign(align.key)
                UIDropDownMenu_SetText(checklistAlignDD, align.label)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(checklistAlignDD, checklistAlignLabel, "Align",
        "Which side of the checklist stays put as buffs come and go. On Right"
        .. " the grid starts from the top-right corner and fills leftwards.")
    f.checklistAlignDD = checklistAlignDD

    local checklistPopoutLabel, checklistPopoutDD
    checklistPopoutLabel, checklistPopoutDD, yL = AddDropdownRow(checklistPage, yL,
        "Menus open:", "WhoDoesWhatBuffChecklistPopoutDD")
    UIDropDownMenu_Initialize(checklistPopoutDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffChecklistPopoutDirection()
        for _, direction in ipairs(WhoDoesWhat.BuffChecklistPopoutDirections) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = direction.label
            info.checked = saved == direction
            info.func = function()
                checklistSettings().buffChecklistPopoutDirection = direction.key
                UIDropDownMenu_SetText(checklistPopoutDD, direction.label)
                WhoDoesWhat:RefreshBuffChecklist()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(checklistPopoutDD, checklistPopoutLabel, "Menus open",
        "Which way the item picker and the aura or aspect menu open from the"
        .. " icon you click. The diagonals meet the icon corner to corner, which"
        .. " keeps a menu clear of the rest of the checklist.")
    f.checklistPopoutDD = checklistPopoutDD

    local columnRange = WhoDoesWhat.BUFF_CHECKLIST_COLUMNS
    f.RefreshChecklistColumns, yL = AddSliderWithInput(checklistPage, PAGE_X, yL, {
            name = "WhoDoesWhatBuffChecklistColumnsSlider",
            label = "Columns:",
            tooltip = "How many icons a row holds before the grid wraps onto"
                .. " the next one.",
            min = columnRange.min,
            max = columnRange.max,
        },
        function() return WhoDoesWhat:GetBuffChecklistColumns() end,
        function(value) checklistSettings().buffChecklistColumns = value end,
        function() WhoDoesWhat:RefreshBuffChecklist() end)

    local checklistIconRange = WhoDoesWhat.BUFF_CHECKLIST_ICON_SIZE
    f.RefreshChecklistIconSize, yL = AddSliderWithInput(checklistPage, PAGE_X, yL, {
            name = "WhoDoesWhatBuffChecklistIconSizeSlider",
            label = "Buff icon size:",
            tooltip = "How big each buff icon is drawn, in pixels.",
            min = checklistIconRange.min,
            max = checklistIconRange.max,
        },
        function() return WhoDoesWhat:GetBuffChecklistIconSize() end,
        function(value) checklistSettings().buffChecklistIconSize = value end,
        function() WhoDoesWhat:RefreshBuffChecklist() end)

    local checklistSpacingLabel, checklistSpacingDD
    checklistSpacingLabel, checklistSpacingDD, yL = AddDropdownRow(checklistPage, yL,
        "Spacing:", "WhoDoesWhatBuffChecklistSpacingDD")
    UIDropDownMenu_Initialize(checklistSpacingDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffChecklistSpacing()
        for _, spacing in ipairs(WhoDoesWhat.BuffChecklistSpacings) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = spacing.label
            info.checked = saved == spacing
            info.func = function()
                checklistSettings().buffChecklistSpacing = spacing.key
                UIDropDownMenu_SetText(checklistSpacingDD, spacing.label)
                WhoDoesWhat:RefreshBuffChecklist()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(checklistSpacingDD, checklistSpacingLabel, "Spacing",
        "How tightly the checklist packs: the gap between icons, the padding"
        .. " around them, and the size of the pet divider. Compact makes the"
        .. " smallest checklist.")
    f.checklistSpacingDD = checklistSpacingDD

    f.checklistHeaderCheck, yL = AddCompactCheckboxRow(checklistPage,
        PAGE_X, yL, "Show header",
        "Puts a \"Buff Checklist\" title strip across the top. Alt-drag it to"
        .. " move the checklist, like the icons.",
        function(value)
            checklistSettings().buffChecklistShowHeader = value
            WhoDoesWhat:RefreshBuffChecklist()
        end)

    f.checklistSplitOthersCheck, yL = AddCompactCheckboxRow(checklistPage,
        PAGE_X, yL, "Divide own buffs from others'",
        "Draws a \"From Others\" line between the buffs you see to yourself"
        .. " (auras, food, elixirs, weapons) and the ones other raiders cast on"
        .. " you (blessings, Fortitude, shouts). The pet's section stays as it is.",
        function(value)
            checklistSettings().buffChecklistSplitOthers = value
            WhoDoesWhat:RefreshBuffChecklist()
        end)

    f.checklistHideHaveCheck, yL = AddCompactCheckboxRow(checklistPage,
        PAGE_X, yL, "Hide buffs I have",
        "Shows only what you are missing or about to lose. With everything up"
        .. " the checklist hides, so place it before turning this on.",
        function(value)
            checklistSettings().buffChecklistHideHave = value
            WhoDoesWhat:RefreshBuffChecklist()
        end)

    f.checklistHideOthersCheck, yL = AddCompactCheckboxRow(checklistPage,
        PAGE_X, yL, "Hide other classes' buffs I have",
        "Hides a buff another class casts on you (blessings, Fortitude, shouts)"
        .. " while it's up, and brings it back when it drops or is about to."
        .. " Your own class's buffs, food, elixirs and weapons stay.",
        function(value)
            checklistSettings().buffChecklistHideOthersHave = value
            WhoDoesWhat:RefreshBuffChecklist()
        end)

    -- Classic Era has no battle/guardian elixir split, so no row for it.
    if WhoDoesWhat.ElixirItems then
        f.checklistElixirsCheck, yL = AddCompactCheckboxRow(checklistPage,
            PAGE_X, yL, "Track elixirs",
            "Adds a Battle Elixir and a Guardian Elixir icon. Click one to pick"
            .. " what to drink; a flask fills both. This character only.",
            function(value)
                WhoDoesWhat.db.char.buffChecklistElixirs = value
                WhoDoesWhat:RefreshBuffChecklist()
            end)
    end

    f.checklistScrollsCheck, yL = AddCompactCheckboxRow(checklistPage,
        PAGE_X, yL, "Track scrolls",
        "For physical damage roles, adds a Scroll of Agility and a Scroll of"
        .. " Strength icon. Click one to pick the rank to read. This character"
        .. " only.",
        function(value)
            WhoDoesWhat.db.char.buffChecklistScrolls = value
            WhoDoesWhat:RefreshBuffChecklist()
        end)

    f.checklistWeaponsCheck, yL = AddCompactCheckboxRow(checklistPage,
        PAGE_X, yL, "Track weapon enchants",
        "Adds an icon per weapon you wield for its oil, stone or poison. Click"
        .. " one to pick what goes on it, or to keep it bare for Windfury."
        .. " This character only.",
        function(value)
            WhoDoesWhat.db.char.buffChecklistWeapons = value
            WhoDoesWhat:RefreshBuffChecklist()
        end)

    -- The status bars' highlight styles, in the checklist's own two colours.
    yL = AddNextPageDivider(checklistPage, yL, "Highlight")
    -- One threshold, two tells, as on the Paladin Bar: the countdown over an
    -- icon and its expiring glow.
    local checklistWarnLabel, checklistWarnDD
    checklistWarnLabel, checklistWarnDD, yL = AddDropdownRow(checklistPage, yL,
        "Warn below:", "WhoDoesWhatBuffChecklistWarnDD")
    local function ChecklistWarnLabel(minutes)
        return minutes .. (minutes == 1 and " minute" or " minutes")
    end
    UIDropDownMenu_Initialize(checklistWarnDD, function(_, level)
        local saved = WhoDoesWhat:GetBuffChecklistWarnMinutes()
        for _, minutes in ipairs(WhoDoesWhat.BuffingWarnMinutes) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = ChecklistWarnLabel(minutes)
            info.checked = (saved == minutes)
            info.func = function()
                checklistSettings().buffChecklistWarnMinutes = minutes
                UIDropDownMenu_SetText(checklistWarnDD, ChecklistWarnLabel(minutes))
                WhoDoesWhat:RefreshBuffChecklist()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(checklistWarnDD, checklistWarnLabel, "Warn below",
        "How close to dropping a buff gets before its icon glows in the"
        .. " expiring color and counts down.")
    f.RefreshChecklistWarn = function()
        UIDropDownMenu_SetText(checklistWarnDD,
            ChecklistWarnLabel(WhoDoesWhat:GetBuffChecklistWarnMinutes()))
    end

    f.RefreshChecklistHighlight, yL = AddHighlightControls(checklistPage,
        PAGE_X, yL, {
            name = "WhoDoesWhatBuffChecklistHighlightDD",
            -- Icons packed edge to edge leave no room for wings beside them.
            noWings = true,
            tooltip = "The animation a checklist icon wears while that buff"
                .. " is missing or about to drop -- the box to the right shows"
                .. " it running.",
            GetStyle = function()
                return checklistSettings().buffChecklistGlowStyle
            end,
            SetStyle = function(key)
                checklistSettings().buffChecklistGlowStyle = key
            end,
            colors = {
                {
                    label = "Missing color:",
                    tooltip = "The color an icon glows while its buff is"
                        .. " missing, or isn't the one you picked. Right-click"
                        .. " the swatch to reset it.",
                    key = "buffChecklistGlowMissingColor",
                },
                {
                    label = "Expiring color:",
                    tooltip = "The color an icon glows, and its countdown"
                        .. " reads in, once its buff is inside the warning"
                        .. " time above. Right-click the swatch to reset it.",
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
        self:GetBuffChecklistPopoutDirection().label)
    f.RefreshChecklistColumns()
    f.RefreshChecklistIconSize()
    UIDropDownMenu_SetText(f.checklistSpacingDD,
        self:GetBuffChecklistSpacing().label)
    f.SetChecklistControlsEnabled(settings.buffChecklistEnabled and true or false)
end

S.RegisterPage({
    label = "Checklist", title = "Buff Checklist (Beta)",
    description = "Puts every option on this page back and re-centres the"
        .. " checklist.",
    Build = BuildChecklistPage,
    Refresh = RefreshChecklistPage,
    Reset = function() WhoDoesWhat:ResetBuffChecklistSettings() end,
})
