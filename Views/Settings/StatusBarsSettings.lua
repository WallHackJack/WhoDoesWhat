local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local L = select(2, ...).L
local S = WhoDoesWhat.SettingsKit

-- Settings > Status Bars: the WDW Status window itself. Which bars it shows,
-- and each one's options, are the Buffs page (BuffTrackingSettings.lua).

local PAGE_X = S.PAGE_X
local StatusDisplayLabel = S.StatusDisplayLabel
local AddCompactCheckboxRow = S.AddCompactCheckboxRow
local AddPageDivider = S.AddPageDivider
local AddNextPageDivider = S.AddNextPageDivider
local AddPageIntro = S.AddPageIntro
local AddDropdownRow = S.AddDropdownRow
local PageControlSwitch = S.PageControlSwitch
local AddHighlightControls = S.AddHighlightControls

local STATUS_TOOLTIP_ANCHOR_KEYS = {
    LEFT = "STATUS_TOOLTIP_SIDE_LEFT", RIGHT = "STATUS_TOOLTIP_SIDE_RIGHT",
    ABOVE = "STATUS_TOOLTIP_SIDE_ABOVE", BELOW = "STATUS_TOOLTIP_SIDE_BELOW",
}
local ANCHOR_KEYS = {
    TOPLEFT = "STATUS_ANCHOR_TOP_LEFT", TOPRIGHT = "STATUS_ANCHOR_TOP_RIGHT",
    BOTTOMLEFT = "STATUS_ANCHOR_BOTTOM_LEFT",
    BOTTOMRIGHT = "STATUS_ANCHOR_BOTTOM_RIGHT",
}
-- How many names a status-bar tooltip lists before the rest become a count.
-- 40 is a full raid, so it is the "everyone" end without needing a sentinel.
local STATUS_TOOLTIP_NAME_COUNTS = { 3, 5, 10, 20, 40 }
local DEFAULT_TOOLTIP_NAMES = 10

local function AnchorLabel(anchor)
    return L[ANCHOR_KEYS[anchor] or ANCHOR_KEYS.TOPLEFT]
end

local function TooltipAnchorLabel(anchor)
    return L[STATUS_TOOLTIP_ANCHOR_KEYS[anchor] or STATUS_TOOLTIP_ANCHOR_KEYS.LEFT]
end

local function BuildStatusBarsPage(f, page)
    local statusPage = page
    local statusIntro, yL
    statusIntro, yL = AddPageIntro(statusPage, S.PAGE_TOP, L.STATUS_INTRO)
    yL = AddPageDivider(statusPage, yL, L.STATUS_SECTION_WINDOW)
    local overviewLabel
    f.overviewCheck, yL, overviewLabel = AddCompactCheckboxRow(statusPage, PAGE_X, yL,
        L.STATUS_ENABLE, L.STATUS_ENABLE_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.overviewEnabled = value
            WhoDoesWhat:UpdateStatusBarsViewVisibility()
            f.SetStatusControlsEnabled(value)
        end)
    local anchorLabel, anchorDD
    anchorLabel, anchorDD, yL = AddDropdownRow(statusPage, yL, L.STATUS_ANCHOR_LABEL,
        "WhoDoesWhatStatusBarsAnchorDD")
    UIDropDownMenu_Initialize(anchorDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.overviewAnchor or "TOPLEFT"
        for _, anchor in ipairs({ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = AnchorLabel(anchor)
            info.checked = (saved == anchor)
            info.func = function()
                WhoDoesWhat:SetStatusBarsAnchor(anchor)
                UIDropDownMenu_SetText(anchorDD, AnchorLabel(anchor))
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(anchorDD, anchorLabel, L.STATUS_ANCHOR, L.STATUS_ANCHOR_TIP)
    f.overviewAnchorDD = anchorDD

    local defaultDisplayLabel, defaultDisplayDD
    defaultDisplayLabel, defaultDisplayDD, yL = AddDropdownRow(statusPage, yL,
        L.STATUS_DEFAULT_DISPLAY_LABEL, "WhoDoesWhatStatusBarsDefaultDisplayDD")
    UIDropDownMenu_Initialize(defaultDisplayDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.overviewDefaultDisplay
            or "percent"
        for _, display in ipairs({ "percent", "applied", "missing", "fraction" }) do
            local displayName = display
            local info = UIDropDownMenu_CreateInfo()
            info.text = StatusDisplayLabel(displayName)
            info.checked = saved == displayName
            info.func = function()
                WhoDoesWhat.db.profile.settings.overviewDefaultDisplay = displayName
                UIDropDownMenu_SetText(defaultDisplayDD,
                    StatusDisplayLabel(displayName))
                WhoDoesWhat:RefreshStatusBarsView()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(defaultDisplayDD, defaultDisplayLabel,
        L.STATUS_DEFAULT_DISPLAY, L.STATUS_DEFAULT_DISPLAY_TIP)
    f.overviewDefaultDisplayDD = defaultDisplayDD

    yL = AddNextPageDivider(statusPage, yL, L.STATUS_SECTION_TOOLTIPS)
    local tooltipAnchorLabel, tooltipAnchorDD
    tooltipAnchorLabel, tooltipAnchorDD, yL = AddDropdownRow(statusPage, yL,
        L.STATUS_TOOLTIP_SIDE_LABEL, "WhoDoesWhatStatusBarsTooltipAnchorDD")
    UIDropDownMenu_Initialize(tooltipAnchorDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.statusBarTooltipAnchor
            or "LEFT"
        for _, anchor in ipairs({ "LEFT", "RIGHT", "ABOVE", "BELOW" }) do
            local anchorName = anchor
            local info = UIDropDownMenu_CreateInfo()
            info.text = TooltipAnchorLabel(anchorName)
            info.checked = saved == anchorName
            info.func = function()
                WhoDoesWhat.db.profile.settings.statusBarTooltipAnchor = anchorName
                UIDropDownMenu_SetText(tooltipAnchorDD, TooltipAnchorLabel(anchorName))
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(tooltipAnchorDD, tooltipAnchorLabel,
        L.STATUS_TOOLTIP_SIDE, L.STATUS_TOOLTIP_SIDE_TIP)
    f.overviewTooltipAnchorDD = tooltipAnchorDD

    local tooltipNamesLabel, tooltipNamesDD
    tooltipNamesLabel, tooltipNamesDD, yL = AddDropdownRow(statusPage, yL,
        L.STATUS_TOOLTIP_NAMES_LABEL, "WhoDoesWhatStatusBarsTooltipNamesDD")
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
    UI.AddDropdownTooltip(tooltipNamesDD, tooltipNamesLabel,
        L.STATUS_TOOLTIP_NAMES, L.STATUS_TOOLTIP_NAMES_TIP)
    f.overviewTooltipNamesDD = tooltipNamesDD

    -- The highlight style, with a live sample of it beside the dropdown --
    -- these read as animation names on their own, and the box is the only
    -- honest way to say what each one looks like -- and one colour under it
    -- for whichever style is selected, rather than a colour baked into each.
    -- The same three controls the shout bar and the buffing bar carry.
    local statusSettings = WhoDoesWhat.db.profile.settings
    yL = AddNextPageDivider(statusPage, yL, L.SECTION_HIGHLIGHT)
    local RefreshStatusHighlight
    RefreshStatusHighlight, yL = AddHighlightControls(statusPage, PAGE_X,
        yL, {
            name = "WhoDoesWhatStatusBarsHighlightDD",
            tooltip = L.STATUS_HIGHLIGHT_TIP,
            GetStyle = function()
                return statusSettings.statusBarHighlightStyle
            end,
            SetStyle = function(key)
                statusSettings.statusBarHighlightStyle = key
            end,
            colors = {
                {
                    label = L.STATUS_HIGHLIGHT_COLOR,
                    tooltip = L.STATUS_HIGHLIGHT_COLOR_TIP,
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
        UIDropDownMenu_SetText(f.overviewAnchorDD, AnchorLabel(settings.overviewAnchor))
        UIDropDownMenu_SetText(f.overviewDefaultDisplayDD,
            StatusDisplayLabel(settings.overviewDefaultDisplay or "percent", "percent"))
        UIDropDownMenu_SetText(f.overviewTooltipAnchorDD,
            TooltipAnchorLabel(settings.statusBarTooltipAnchor))
        UIDropDownMenu_SetText(f.overviewTooltipNamesDD,
            tostring(settings.statusBarTooltipNames or DEFAULT_TOOLTIP_NAMES))
        -- The dropdown's text, the swatch, and the running sample in one go.
        RefreshStatusHighlight()
        f.SetStatusControlsEnabled(settings.overviewEnabled and true or false)
    end
end

S.RegisterPage({
    id = "Status Bars", labelKey = "SETTINGS_STATUS_BARS",
    descriptionKey = "SETTINGS_STATUS_BARS_RESET",
    Build = BuildStatusBarsPage,
    Refresh = function(f) f.RefreshStatusPage() end,
    Reset = function()
        UI.CancelColorPicker()
        WhoDoesWhat:ResetStatusBarSettings()
    end,
})
