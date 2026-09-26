local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local S = WhoDoesWhat.SettingsKit

-- Settings > Status Bars: the WDW Status window itself. Which bars it shows,
-- and each one's options, are the Buffs page (BuffTrackingSettings.lua).

local PAGE_X = S.PAGE_X
local STATUS_DISPLAY_LABELS = S.STATUS_DISPLAY_LABELS
local AddCompactCheckboxRow = S.AddCompactCheckboxRow
local AddPageDivider = S.AddPageDivider
local AddNextPageDivider = S.AddNextPageDivider
local AddPageIntro = S.AddPageIntro
local AddDropdownRow = S.AddDropdownRow
local PageControlSwitch = S.PageControlSwitch
local AddHighlightControls = S.AddHighlightControls

local STATUS_TOOLTIP_ANCHOR_LABELS = {
    LEFT = "Left", RIGHT = "Right", ABOVE = "Above", BELOW = "Below",
}
-- How many names a status-bar tooltip lists before the rest become a count.
-- 40 is a full raid, so it is the "everyone" end without needing a sentinel.
local STATUS_TOOLTIP_NAME_COUNTS = { 3, 5, 10, 20, 40 }
local DEFAULT_TOOLTIP_NAMES = 10

local function BuildStatusBarsPage(f, page)
    local statusPage = page
    local statusIntro, yL
    statusIntro, yL = AddPageIntro(statusPage, S.PAGE_TOP,"A compact window of bars"
        .. " showing your raid's buffs, debuffs and assignments at a glance."
        .. " Choose which bars show on the Buffs tab. Hover the window and check"
        .. " the tooltips for additional info")
    yL = AddPageDivider(statusPage, yL, "Window")
    local overviewLabel
    f.overviewCheck, yL, overviewLabel = AddCompactCheckboxRow(statusPage, PAGE_X, yL,
        "Enable Status Bars",
        "Shows a persistent UI element with many bars to see your raid's status at a quick glance.",
        function(value)
            WhoDoesWhat.db.profile.settings.overviewEnabled = value
            WhoDoesWhat:UpdateStatusBarsViewVisibility()
            f.SetStatusControlsEnabled(value)
        end)
    local anchorLabels = {
        TOPLEFT = "Top Left", TOPRIGHT = "Top Right",
        BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
    }
    local anchorLabel, anchorDD
    anchorLabel, anchorDD, yL = AddDropdownRow(statusPage, yL, "Anchor point:",
        "WhoDoesWhatStatusBarsAnchorDD")
    UIDropDownMenu_Initialize(anchorDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.overviewAnchor or "TOPLEFT"
        for _, anchor in ipairs({ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = anchorLabels[anchor]
            info.checked = (saved == anchor)
            info.func = function()
                WhoDoesWhat:SetStatusBarsAnchor(anchor)
                UIDropDownMenu_SetText(anchorDD, anchorLabels[anchor])
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(anchorDD, anchorLabel, "Anchor point",
        "The window grows away from this corner as rows or width change.")
    f.overviewAnchorDD = anchorDD
    f.overviewAnchorLabels = anchorLabels

    local defaultDisplayLabel, defaultDisplayDD
    defaultDisplayLabel, defaultDisplayDD, yL = AddDropdownRow(statusPage, yL,
        "Default text-mode:", "WhoDoesWhatStatusBarsDefaultDisplayDD")
    UIDropDownMenu_Initialize(defaultDisplayDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.overviewDefaultDisplay
            or "percent"
        for _, display in ipairs({ "percent", "applied", "missing", "fraction" }) do
            local displayName = display
            local info = UIDropDownMenu_CreateInfo()
            info.text = STATUS_DISPLAY_LABELS[displayName]
            info.checked = saved == displayName
            info.func = function()
                WhoDoesWhat.db.profile.settings.overviewDefaultDisplay = displayName
                UIDropDownMenu_SetText(defaultDisplayDD,
                    STATUS_DISPLAY_LABELS[displayName])
                WhoDoesWhat:RefreshStatusBarsView()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(defaultDisplayDD, defaultDisplayLabel, "Default text-mode",
        "Used by paladin bars and any Buff Tracking row set to Default.")
    f.overviewDefaultDisplayDD = defaultDisplayDD

    yL = AddNextPageDivider(statusPage, yL, "Tooltips")
    local tooltipAnchorLabel, tooltipAnchorDD
    tooltipAnchorLabel, tooltipAnchorDD, yL = AddDropdownRow(statusPage, yL,
        "Tooltip side:", "WhoDoesWhatStatusBarsTooltipAnchorDD")
    UIDropDownMenu_Initialize(tooltipAnchorDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.statusBarTooltipAnchor
            or "LEFT"
        for _, anchor in ipairs({ "LEFT", "RIGHT", "ABOVE", "BELOW" }) do
            local anchorName = anchor
            local info = UIDropDownMenu_CreateInfo()
            info.text = STATUS_TOOLTIP_ANCHOR_LABELS[anchorName]
            info.checked = saved == anchorName
            info.func = function()
                WhoDoesWhat.db.profile.settings.statusBarTooltipAnchor = anchorName
                UIDropDownMenu_SetText(tooltipAnchorDD,
                    STATUS_TOOLTIP_ANCHOR_LABELS[anchorName])
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(tooltipAnchorDD, tooltipAnchorLabel, "Tooltip side",
        "Where a status bar's tooltip opens. Left and right follow the hovered"
            .. " bar; above and below clear the whole window.")
    f.overviewTooltipAnchorDD = tooltipAnchorDD

    local tooltipNamesLabel, tooltipNamesDD
    tooltipNamesLabel, tooltipNamesDD, yL = AddDropdownRow(statusPage, yL,
        "Tooltip names:", "WhoDoesWhatStatusBarsTooltipNamesDD")
    UIDropDownMenu_Initialize(tooltipNamesDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.statusBarTooltipNames
            or DEFAULT_TOOLTIP_NAMES
        for _, count in ipairs(STATUS_TOOLTIP_NAME_COUNTS) do
            local value = count
            local info = UIDropDownMenu_CreateInfo()
            info.text = tostring(value)
            info.checked = saved == value
            info.func = function()
                WhoDoesWhat.db.profile.settings.statusBarTooltipNames = value
                UIDropDownMenu_SetText(tooltipNamesDD, tostring(value))
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(tooltipNamesDD, tooltipNamesLabel, "Tooltip names",
        "How many raiders a status bar's tooltip names before the rest"
            .. " collapse into \"... and N more\". Applies to every bar,"
            .. " including the paladin ones.")
    f.overviewTooltipNamesDD = tooltipNamesDD

    -- The highlight style, with a live sample of it beside the dropdown --
    -- these read as animation names on their own, and the box is the only
    -- honest way to say what each one looks like -- and one colour under it
    -- for whichever style is selected, rather than a colour baked into each.
    -- The same three controls the shout bar and the buffing bar carry.
    local statusSettings = WhoDoesWhat.db.profile.settings
    yL = AddNextPageDivider(statusPage, yL, "Highlight")
    local RefreshStatusHighlight
    RefreshStatusHighlight, yL = AddHighlightControls(statusPage, PAGE_X,
        yL, {
            name = "WhoDoesWhatStatusBarsHighlightDD",
            tooltip = "The animation a status bar uses when it wants your"
                .. " attention -- the box to the right shows it running.",
            GetStyle = function()
                return statusSettings.statusBarHighlightStyle
            end,
            SetStyle = function(key)
                statusSettings.statusBarHighlightStyle = key
            end,
            colors = {
                {
                    label = "Highlight color:",
                    tooltip = "The color every highlight style is drawn in."
                        .. " Right-click the swatch to reset it.",
                    key = "statusBarHighlightColor",
                },
            },
            OnChange = function()
                WhoDoesWhat:RefreshStatusBarsView()
                WhoDoesWhat:RefreshStatusBarHighlights()
            end,
        })

    -- Every widget on this page, read back out of the settings. Called when the
    -- window opens and again after the Defaults button has rewritten them.
    f.SetStatusControlsEnabled = PageControlSwitch(statusPage,
        { statusIntro, f.overviewCheck, overviewLabel })
    f.RefreshStatusPage = function()
        local settings = WhoDoesWhat.db.profile.settings
        f.overviewCheck:SetChecked(settings.overviewEnabled)
        local anchor = settings.overviewAnchor or "TOPLEFT"
        UIDropDownMenu_SetText(f.overviewAnchorDD,
            anchorLabels[anchor] or anchorLabels.TOPLEFT)
        local display = settings.overviewDefaultDisplay or "percent"
        UIDropDownMenu_SetText(f.overviewDefaultDisplayDD,
            STATUS_DISPLAY_LABELS[display] or STATUS_DISPLAY_LABELS.percent)
        local tooltipAnchor = settings.statusBarTooltipAnchor or "LEFT"
        UIDropDownMenu_SetText(f.overviewTooltipAnchorDD,
            STATUS_TOOLTIP_ANCHOR_LABELS[tooltipAnchor]
                or STATUS_TOOLTIP_ANCHOR_LABELS.LEFT)
        UIDropDownMenu_SetText(f.overviewTooltipNamesDD,
            tostring(settings.statusBarTooltipNames or DEFAULT_TOOLTIP_NAMES))
        -- The dropdown's text, the swatch, and the running sample in one go.
        RefreshStatusHighlight()
        f.SetStatusControlsEnabled(settings.overviewEnabled and true or false)
    end
end

S.RegisterPage({
    label = "Status Bars", title = "Status Bars",
    description = "Puts every option on this page back and moves the"
        .. " window to the middle of the screen. Per-check options on"
        .. " the Buffs page are left alone.",
    Build = BuildStatusBarsPage,
    Refresh = function(f) f.RefreshStatusPage() end,
    Reset = function()
        UI.CancelColorPicker()
        WhoDoesWhat:ResetStatusBarSettings()
    end,
})
