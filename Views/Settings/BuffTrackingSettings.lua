local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local L = select(2, ...).L
local K = WhoDoesWhat.SectionKit
local S = WhoDoesWhat.SettingsKit

-- Settings > Buffs: the table of every WDW Status check -- drag to reorder,
-- whether it shows in Bars and the Buff Grid -- and beside it the options panel
-- for whichever row's cog was clicked last.

local CONTENT_X = S.CONTENT_X
local CONTENT_W = S.CONTENT_W
local DIVIDER_GAP = S.DIVIDER_GAP
local StatusDisplayLabel = S.StatusDisplayLabel
local AddCompactCheckboxRow = S.AddCompactCheckboxRow
local SetOptionAvailable = S.SetOptionAvailable
local CreateMiniDivider = UI.CreateDivider
local PAGE_WELL = WhoDoesWhat.Theme.pageWell
-- Over the row options, the deep navy title bar (Theme.lua).
local OPTIONS_HEADER_BLUE = WhoDoesWhat.Theme.wellHeaderBlue
-- Settings table rows, over the well: odd, even.
local ROW_STRIPES = WhoDoesWhat.Theme.wellRows
local BUFF_OPTIONS_W = 242
-- Buff Tracking splits its section in two: the table on a panel just wide
-- enough for it and its scrollbar, and the row options on a second panel that
-- takes the rest. The table's column headings stay put above its rows.
local BUFF_TABLE_W = CONTENT_X + CONTENT_W + UI.SCROLLBAR_W
local BUFF_PANEL_GAP = 8
local BUFF_HEADINGS_H = 30
-- The row options' own heading bar, a little taller for its bigger icon.
local OPTIONS_HEADER_H = 38
-- The row options' layout. Labels sit at the left; every dropdown box and the
-- colour swatch start at one shared x beside them. The dropdown template draws
-- its box DROPDOWN_INSET in from its own left edge.
local OPTIONS_LABEL_X = 10
local OPTIONS_FIELD_X = 150
local DROPDOWN_INSET = S.DROPDOWN_INSET
-- One width for every dropdown there, wide enough for the longest choice.
local OPTIONS_DROPDOWN_W = 120
local OPTION_ROW_H = 22
local DROPDOWN_ROW_H = 28
local STATUS_SCOPE_KEYS = {
    always = "BUFFS_SCOPE_ALL", raid = "BUFFS_SCOPE_RAID", party = "BUFFS_SCOPE_PARTY",
}
local STATUS_SATURATED_KEYS = {
    hide = "BUFFS_SATURATED_HIDE", x = "BUFFS_SATURATED_X",
    check = "BUFFS_SATURATED_CHECK",
}

local function ScopeLabel(scope)
    return L[STATUS_SCOPE_KEYS[scope] or STATUS_SCOPE_KEYS.always]
end

local function SaturatedLabel(style)
    return L[STATUS_SATURATED_KEYS[style] or STATUS_SATURATED_KEYS.check]
end
local OPTIONS_BUTTON = "Interface\\AddOns\\WhoDoesWhat\\Media\\UI-Panel-OptionsButton-"
local STATUS_BUFF_ROW_H = 26

local buffOptionsFrame = nil

local function StoreStatusBuffOption(key, option, value)
    local settings = WhoDoesWhat.db.profile.settings
    settings.statusBarChecks = settings.statusBarChecks or {}
    settings.statusBarChecks[key] = settings.statusBarChecks[key] or {}
    settings.statusBarChecks[key][option] = value
    -- The resolved options are cached (Data.lua); this is the one writer, so
    -- the edit only reaches the views through here.
    WhoDoesWhat:InvalidateStatusBarCheckCache()
end

local function GetStatusBuffSetup()
    local enabled, disabled = {}, {}
    for _, key in ipairs(WhoDoesWhat:GetStatusBarCheckOrder()) do
        local target = WhoDoesWhat:GetStatusBarCheckOptions(key).bar
            and enabled or disabled
        target[#target + 1] = key
    end
    local enabledCount = #enabled
    for _, key in ipairs(disabled) do enabled[#enabled + 1] = key end
    return enabled, enabledCount
end

local function RefreshStatusBuffRows(f)
    -- A drag lays the rows out itself every frame and repaints them on drop.
    if not f.statusBuffRows or f.statusBuffDrag then return end
    local order, enabledCount = GetStatusBuffSetup()
    f.statusBuffOrder = order
    f.statusBuffEnabledCount = enabledCount
    f.statusBuffDivider:ClearAllPoints()
    f.statusBuffDivider:SetPoint("TOPLEFT", CONTENT_X,
        -(f.statusBuffListTop + enabledCount * STATUS_BUFF_ROW_H))
    f.statusBuffDivider:SetShown(enabledCount < #order)
    for index, key in ipairs(order) do
        local row = f.statusBuffRows[key]
        local options = WhoDoesWhat:GetStatusBarCheckOptions(key)
        local disabled = index > enabledCount
        local visualIndex = index + (disabled and 1 or 0)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", CONTENT_X,
            -(f.statusBuffListTop + (visualIndex - 1) * STATUS_BUFF_ROW_H))
        row.index:SetText(disabled and "" or (index .. "."))
        row.bar:SetChecked(options.bar)
        row.grid:SetChecked(options.grid)
        row.grid:SetShown(not WhoDoesWhat.StatusBarChecks[key].gridOptionDisabled)
        if buffOptionsFrame and buffOptionsFrame.buffKey == key then
            -- The row whose options are showing beside the table.
            row.stripe:SetColorTexture(0.42, 0.33, 0.04, 0.85)
        else
            local shade = ROW_STRIPES[index % 2 == 1 and 1 or 2]
            row.stripe:SetColorTexture(shade[1], shade[2], shade[3], 0.72)
        end
    end
end

local function FinishStatusBuffOrderChange(f)
    local settings = WhoDoesWhat.db.profile.settings
    settings.statusBarOrder = { unpack(f.statusBuffOrder) }
    WhoDoesWhat:InvalidateStatusBarCheckCache()
    RefreshStatusBuffRows(f)
    WhoDoesWhat:RefreshBoardViews()
    WhoDoesWhat:RefreshStatusBarsView()
end

local function SetStatusBuffBarEnabled(f, key, enabled)
    local index
    for i, orderedKey in ipairs(f.statusBuffOrder) do
        if orderedKey == key then index = i break end
    end
    if not index then return end
    local active = f.statusBuffEnabledCount
    if (index <= active) == enabled then return end
    table.remove(f.statusBuffOrder, index)
    if enabled then
        active = active + 1
    else
        active = active - 1
    end
    table.insert(f.statusBuffOrder, active + (enabled and 0 or 1), key)
    f.statusBuffEnabledCount = active
    StoreStatusBuffOption(key, "bar", enabled)
    FinishStatusBuffOrderChange(f)
end

local function SetStatusBuffOption(f, key, option, value)
    StoreStatusBuffOption(key, option, value)
    RefreshStatusBuffRows(f)
    WhoDoesWhat:RefreshBoardViews()
    WhoDoesWhat:RefreshStatusBarsView()
end

local function DefaultStatusBarColor(definition)
    if definition.colorRGB then return definition.colorRGB end
    for _, classInfo in ipairs(WhoDoesWhat.Classes) do
        if classInfo.name == definition.className then return classInfo.colorRGB end
    end
    return { r = 0.96, g = 0.55, b = 0.73 }
end

local function RefreshBuffOptionsFrame()
    local f = buffOptionsFrame
    if not f or not f.buffKey then return end
    local definition = WhoDoesWhat.StatusBarChecks[f.buffKey]
    local options = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey)
    -- Checks with `customOptions` are not coverage checks: they replace the
    -- whole normal option stack with their own short list. PallyPower has no
    -- icon of its own (it wears the addon's badge); Action Items does.
    local custom = definition.customOptions
    local pallyPower = custom == "pallyPower"
    f.buffIcon:SetShown(not pallyPower)
    f.ppHeaderBadge:SetShown(pallyPower)
    if not pallyPower then
        WhoDoesWhat:ApplyStatusCheckIcon(f.buffIcon, definition)
    end
    f.buffName:SetText(definition.name)
    f.buffNameGroup:SetWidth(33 + f.buffName:GetStringWidth())
    UIDropDownMenu_SetText(f.scopeDD, ScopeLabel(options.scope))

    -- A label, and its dropdown's box at the shared field x on the same line.
    -- Returns the y below the row.
    local function PlaceDropdown(label, dd, y)
        label:ClearAllPoints()
        label:SetPoint("TOPLEFT", OPTIONS_LABEL_X, -(y + 7))
        dd:ClearAllPoints()
        dd:SetPoint("LEFT", label, "LEFT",
            OPTIONS_FIELD_X - OPTIONS_LABEL_X - DROPDOWN_INSET, -2)
        return y + DROPDOWN_ROW_H
    end
    for _, region in ipairs(f.normalOptionRegions) do
        region:SetShown(not custom)
    end
    -- Both custom stacks are three checkboxes under the Party type dropdown,
    -- so they share the placement below; only which trio is shown differs.
    local customRows = {
        pallyPower = {
            { f.ppHideSyncedCheck, f.ppHideSyncedLabel, options.hideWhenSynced },
            { f.ppHideInactiveCheck, f.ppHideInactiveLabel,
                options.hideWhenInactive },
            { f.ppGlowCheck, f.ppGlowLabel, options.assignmentIssuesGlow },
        },
        actionItems = {
            { f.aiHideClearCheck, f.aiHideClearLabel, options.hideWhenClear },
            { f.aiHideSoloCheck, f.aiHideSoloLabel, options.hideWhenSolo },
            { f.aiHideNotYoursCheck, f.aiHideNotYoursLabel,
                options.hideWhenNotYours },
            { f.aiGlowCheck, f.aiGlowLabel, options.actionItemsGlow },
        },
    }
    local activeRows = custom and customRows[custom]
    for key, rows in pairs(customRows) do
        for _, row in ipairs(rows) do
            row[1]:SetShown(rows == activeRows)
            row[2]:SetShown(rows == activeRows)
        end
    end
    if activeRows then
        local top = PlaceDropdown(f.scopeLabel, f.scopeDD, 4) + 2
        -- Sized to the stack rather than a constant: the two custom checks no
        -- longer have the same number of rows.
        f:SetHeight(top + #activeRows * OPTION_ROW_H + 8)
        for index, row in ipairs(activeRows) do
            row[1]:ClearAllPoints()
            row[1]:SetPoint("TOPLEFT", 7, -(top + (index - 1) * OPTION_ROW_H))
            row[1]:SetChecked(row[3])
            SetOptionAvailable(row[1], row[2], true)
        end
        return
    end

    UIDropDownMenu_SetText(f.displayDD, StatusDisplayLabel(options.display, "default"))
    UIDropDownMenu_SetText(f.classDD, options.requiredClass
        and WhoDoesWhat:ClassLabel(options.requiredClass) or L.BUFFS_CLASS_NONE)
    UIDropDownMenu_SetText(f.saturatedDD, SaturatedLabel(options.saturatedStyle))
    f.colorField:Refresh()
    for option, check in pairs(f.optionChecks) do
        check:SetChecked(options[option])
    end

    -- What shows is StatusBarOptionRules' call (Data.lua); only the order and
    -- the spacing are decided here.
    local function Shown(option)
        return WhoDoesWhat:StatusBarOptionShown(f.buffKey, option)
    end
    local function PlaceOption(option, y, indent)
        local check, label = f.optionChecks[option], f.optionLabels[option]
        local shown = Shown(option)
        check:SetShown(shown)
        label:SetShown(shown)
        if shown then
            check:ClearAllPoints()
            check:SetPoint("TOPLEFT", 7 + (indent or 0), -y)
            return y + OPTION_ROW_H
        end
        return y
    end
    -- A section divider across the panel, with room above and below it.
    local function PlaceDivider(divider, shown, y)
        divider:SetShown(shown)
        if shown then
            y = y + DIVIDER_GAP
            divider:ClearAllPoints()
            divider:SetPoint("TOPLEFT", 8, -y)
            divider:SetPoint("TOPRIGHT", -8, -y)
            return y + 10 + 8
        end
        return y
    end

    local y = -6
    if Shown("combinePaladinBars") then y = 4 end
    y = PlaceOption("combinePaladinBars", y)

    y = PlaceDivider(f.displayDivider, true, y)
    y = PlaceDropdown(f.displayLabel, f.displayDD, y)
    f.colorLabel:ClearAllPoints()
    f.colorLabel:SetPoint("TOPLEFT", OPTIONS_LABEL_X, -(y + 4))
    f.colorField:ClearAllPoints()
    f.colorField:SetPoint("LEFT", f.colorLabel, "LEFT",
        OPTIONS_FIELD_X - OPTIONS_LABEL_X, 0)
    y = y + 24

    y = PlaceDivider(f.requirementDivider, true, y)
    y = PlaceDropdown(f.scopeLabel, f.scopeDD, y)
    local showClass = Shown("requiredClass")
    f.classLabel:SetShown(showClass)
    f.classDD:SetShown(showClass)
    if showClass then y = PlaceDropdown(f.classLabel, f.classDD, y) end
    y = PlaceOption("bestAvailable", y)
    y = PlaceOption("anyInCombat", y, 14)
    y = PlaceOption("flagOutsideRaid", y)
    y = PlaceOption("responsibleGlow", y)
    y = PlaceOption("offspecResponsible", y, 14)
    -- Names the check's class where it has one.
    f.optionLabels.partialGlowOnlyClass:SetText(options.requiredClass
        and L.BUFFS_PARTIAL_GLOW_ONLY_AS:format(WhoDoesWhat:ClassLabel(options.requiredClass))
        or L.BUFFS_PARTIAL_GLOW_ONLY_CLASS)
    y = PlaceOption("partialGlow", y)
    y = PlaceOption("partialGlowOnlyClass", y, 14)
    y = PlaceOption("hideBarUnavailable", y)
    y = PlaceOption("hideColumnUnavailable", y)

    y = PlaceDivider(f.completionDivider, true, y)
    y = PlaceOption("negative", y)
    f.optionLabels.hideComplete:SetText(options.negative
        and L.BUFFS_HIDE_BAR_DEBUFF_MISSING or L.BUFFS_HIDE_BAR_COMPLETE)
    y = PlaceOption("hideComplete", y)
    local showSaturated = Shown("saturatedStyle")
    f.saturatedLabel:SetShown(showSaturated)
    f.saturatedDD:SetShown(showSaturated)
    if showSaturated then
        y = PlaceDropdown(f.saturatedLabel, f.saturatedDD, y)
    end
    f.optionLabels.hideColumnComplete:SetText(options.negative
        and L.BUFFS_HIDE_COLUMN_DEBUFF_MISSING or L.BUFFS_HIDE_COLUMN_COMPLETE)
    y = PlaceOption("hideColumnComplete", y)

    y = PlaceDivider(f.targetsDivider, Shown("onlyManaUsers")
        or Shown("onlyTanks") or Shown("hunterPets"), y)
    y = PlaceOption("onlyManaUsers", y)
    y = PlaceOption("onlyTanks", y)
    -- A check that counts every class's pet says so; the rest are hunters-only.
    f.optionLabels.hunterPets:SetText(definition.allPets
        and L.BUFFS_PETS or L.BUFFS_HUNTER_PETS)
    y = PlaceOption("hunterPets", y)
    f:SetHeight(y + 7)
end

-- Put one check's options back to its defaults. Whether it shows in Bars and in
-- the Buff Grid, and where it sits in the order, belong to the table beside the
-- options, so they are kept.
local function ResetBuffOptions(key)
    UI.CancelColorPicker()
    local all = WhoDoesWhat.db.profile.settings.statusBarChecks
    local saved = all and all[key]
    if saved then
        all[key] = { bar = saved.bar, enabled = saved.enabled, grid = saved.grid }
    end
    WhoDoesWhat:InvalidateStatusBarCheckCache()
    RefreshBuffOptionsFrame()
    WhoDoesWhat:RefreshBoardViews()
    WhoDoesWhat:RefreshStatusBarsView()
end

local function EnsureBuffOptionsFrame(owner, key)
    if buffOptionsFrame then return buffOptionsFrame end
    local _
    -- The right-hand panel of the Buff Tracking section, beside its table, in
    -- a scroll area of its own: the rows and the options each scroll on their
    -- own, and both come and go with the section's tab.
    local well = owner.buffTrackingWell
    local scroll, content = UI.CreateScroll(well, "WhoDoesWhatBuffTrackingOptionsScroll")
    scroll:SetPoint("TOPLEFT", well, "TOPLEFT", BUFF_TABLE_W + BUFF_PANEL_GAP + 4,
        -OPTIONS_HEADER_H)
    scroll:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -UI.SCROLLBAR_W, 0)

    local f = CreateFrame("Frame", "WhoDoesWhatBuffTrackingOptionsFrame", content)
    f:SetPoint("TOPLEFT")
    f:SetPoint("TOPRIGHT")
    f:SetHeight(230)
    UI.SetScrollHeight(scroll, 230)
    -- The refresh sizes the panel to whichever option stack is showing.
    f:SetScript("OnSizeChanged", function(_, _, height)
        UI.SetScrollHeight(scroll, height)
    end)
    -- UIDropDownMenu_Initialize runs its callback immediately, before this
    -- constructor returns, so the selected key must already be available.
    f.buffKey = key
    f:HookScript("OnHide", UI.CancelColorPicker)

    -- The row's icon and name, centred on a lighter bar across the top of the
    -- options panel, down to where the scroll area starts. Outside the scroll
    -- area so they stay in view, and above it so the bar's shadow falls over
    -- the options as they scroll up under it. The group is re-fitted to the
    -- name on every refresh.
    local nameBar = CreateFrame("Frame", nil, well)
    nameBar:SetPoint("TOPLEFT", well, "TOPLEFT", BUFF_TABLE_W + BUFF_PANEL_GAP, 0)
    nameBar:SetPoint("TOPRIGHT", well, "TOPRIGHT")
    nameBar:SetHeight(OPTIONS_HEADER_H)
    nameBar:SetFrameLevel(scroll:GetFrameLevel() + 20)
    local barFill = nameBar:CreateTexture(nil, "BACKGROUND")
    barFill:SetAllPoints()
    local blue = OPTIONS_HEADER_BLUE
    barFill:SetColorTexture(blue[1], blue[2], blue[3], blue[4])
    local topEdge = UI.CreateEdgeShadow(well, scroll:GetFrameLevel() + 20, true)
    topEdge:SetPoint("TOPLEFT", nameBar, "BOTTOMLEFT")
    topEdge:SetPoint("TOPRIGHT", nameBar, "BOTTOMRIGHT")
    -- The same shadow upside down along the panel's bottom edge, which the
    -- options scroll down under.
    local bottomEdge = UI.CreateEdgeShadow(well, scroll:GetFrameLevel() + 20, false)
    bottomEdge:SetPoint("BOTTOMLEFT", well, "BOTTOMLEFT", BUFF_TABLE_W + BUFF_PANEL_GAP, 0)
    bottomEdge:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT")

    -- Clear of the heading bar and the bottom shadow.
    UI.InsetScrollBar(scroll, 12)

    local nameGroup = CreateFrame("Frame", nil, nameBar)
    nameGroup:SetPoint("CENTER")
    nameGroup:SetHeight(26)
    f.buffNameGroup = nameGroup

    local resetRow = CreateFrame("Button", nil, nameBar, "UIPanelButtonTemplate")
    resetRow:SetSize(60, 22)
    resetRow:SetPoint("RIGHT", -8, 0)
    resetRow:SetText(L.COMMON_RESET)
    resetRow:SetScript("OnClick", function()
        local rowKey = f.buffKey
        S.ConfirmReset(L.SETTINGS_RESET_PAGE_PROMPT:format(
            WhoDoesWhat.StatusBarChecks[rowKey].name, L.BUFFS_ROW_RESET),
            function() ResetBuffOptions(rowKey) end)
    end)
    UI.AddTooltip(resetRow, function()
        return L.SETTINGS_RESET_PAGE_TITLE:format(
            WhoDoesWhat.StatusBarChecks[f.buffKey].name), L.BUFFS_ROW_RESET
    end)

    local icon = nameGroup:CreateTexture(nil, "ARTWORK")
    icon:SetSize(26, 26)
    icon:SetPoint("LEFT")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.buffIcon = icon
    local ppHeaderBadge = K.CreatePallyPowerBadge(nameGroup, 26)
    ppHeaderBadge:SetPoint("LEFT")
    ppHeaderBadge:Hide()
    f.ppHeaderBadge = ppHeaderBadge
    local name = nameGroup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    name:SetPoint("LEFT", icon, "RIGHT", 7, 0)
    f.buffName = name

    local scopeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    scopeLabel:SetPoint("TOPLEFT", 10, -46)
    scopeLabel:SetText(L.BUFFS_SCOPE)
    local scopeDD = UI.CreateMenuDropdown(f, "WhoDoesWhatBuffTrackingScopeDD", OPTIONS_DROPDOWN_W)
    scopeDD:SetPoint("LEFT", scopeLabel, "RIGHT", -7, -2)
    UIDropDownMenu_Initialize(scopeDD, function(_, level)
        local saved = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey).scope
        for _, scope in ipairs({ "always", "raid", "party" }) do
            local scopeName = scope
            local info = UIDropDownMenu_CreateInfo()
            info.text = ScopeLabel(scopeName)
            info.checked = saved == scopeName
            info.func = function()
                SetStatusBuffOption(owner, f.buffKey, "scope", scopeName)
                RefreshBuffOptionsFrame()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.scopeDD = scopeDD
    f.scopeLabel = scopeLabel
    UI.AddDropdownTooltip(scopeDD, scopeLabel, L.BUFFS_SCOPE, L.BUFFS_SCOPE_TIP)

    local displayLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    displayLabel:SetPoint("TOPLEFT", 190, -46)
    displayLabel:SetText(L.BUFFS_DISPLAY)
    local displayDD = UI.CreateMenuDropdown(f, "WhoDoesWhatBuffTrackingDisplayDD", OPTIONS_DROPDOWN_W)
    displayDD:SetPoint("LEFT", displayLabel, "RIGHT", -7, -2)
    UIDropDownMenu_Initialize(displayDD, function(_, level)
        local saved = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey).display
        for _, display in ipairs({
            "default", "percent", "applied", "missing", "fraction",
        }) do
            local displayName = display
            local info = UIDropDownMenu_CreateInfo()
            info.text = StatusDisplayLabel(displayName)
            info.checked = saved == displayName
            info.func = function()
                SetStatusBuffOption(owner, f.buffKey, "display", displayName)
                RefreshBuffOptionsFrame()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.displayDD = displayDD
    f.displayLabel = displayLabel
    UI.AddDropdownTooltip(displayDD, displayLabel, L.BUFFS_DISPLAY, L.BUFFS_DISPLAY_TIP)

    local classLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    classLabel:SetPoint("TOPLEFT", 10, -77)
    classLabel:SetText(L.BUFFS_CLASS_LABEL)
    local classDD = UI.CreateMenuDropdown(f, "WhoDoesWhatBuffTrackingClassDD", OPTIONS_DROPDOWN_W)
    classDD:SetPoint("LEFT", classLabel, "RIGHT", -7, -2)
    UIDropDownMenu_Initialize(classDD, function(_, level)
        local saved = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey).requiredClass
        local none = UIDropDownMenu_CreateInfo()
        none.text = L.BUFFS_CLASS_NONE
        none.checked = saved == false
        none.func = function()
            SetStatusBuffOption(owner, f.buffKey, "requiredClass", false)
            RefreshBuffOptionsFrame()
        end
        UIDropDownMenu_AddButton(none, level)
        for _, classInfo in ipairs(WhoDoesWhat.Classes) do
            local className = classInfo.name
            local info = UIDropDownMenu_CreateInfo()
            info.text = classInfo.label
            info.checked = saved == className
            info.func = function()
                SetStatusBuffOption(owner, f.buffKey, "requiredClass", className)
                RefreshBuffOptionsFrame()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.classDD = classDD
    f.classLabel = classLabel
    UI.AddDropdownTooltip(classDD, classLabel, L.BUFFS_CLASS, L.BUFFS_CLASS_TIP)

    local colorLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    colorLabel:SetPoint("TOPLEFT", 190, -77)
    colorLabel:SetText(L.BUFFS_BAR_COLOR)
    local colorField = UI.CreateColorField(f, {
        title = L.BUFFS_BAR_COLOR,
        Get = function() return WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey).barColor end,
        Set = function(color)
            SetStatusBuffOption(owner, f.buffKey, "barColor", color or false)
        end,
        Default = function()
            return DefaultStatusBarColor(WhoDoesWhat.StatusBarChecks[f.buffKey])
        end,
        OnChange = RefreshBuffOptionsFrame,
        -- WDW Status shows this row's colour live only while it is picked.
        OnOpen = function()
            WhoDoesWhat.statusBarColorPreviewKey = f.buffKey
            WhoDoesWhat:RefreshStatusBarsView()
        end,
        OnClose = function()
            WhoDoesWhat.statusBarColorPreviewKey = nil
            WhoDoesWhat:RefreshStatusBarsView()
        end,
    })
    UI.AddTooltip(colorLabel, L.BUFFS_BAR_COLOR, L.BUFFS_BAR_COLOR_TIP)
    f.colorField = colorField
    f.colorLabel = colorLabel

    local saturatedLabel = f:CreateFontString(nil, "OVERLAY",
        "GameFontHighlight")
    saturatedLabel:SetText(L.BUFFS_SATURATED_LABEL)
    local saturatedDD = UI.CreateMenuDropdown(f, "WhoDoesWhatBuffTrackingSaturatedStyleDD", OPTIONS_DROPDOWN_W)
    UIDropDownMenu_Initialize(saturatedDD, function(_, level)
        local saved = WhoDoesWhat:GetStatusBarCheckOptions(
            f.buffKey).saturatedStyle
        for _, style in ipairs({ "hide", "x", "check" }) do
            local styleName = style
            local info = UIDropDownMenu_CreateInfo()
            info.text = SaturatedLabel(styleName)
            info.checked = saved == styleName
            info.func = function()
                SetStatusBuffOption(owner, f.buffKey,
                    "saturatedStyle", styleName)
                RefreshBuffOptionsFrame()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.saturatedLabel = saturatedLabel
    f.saturatedDD = saturatedDD
    UI.AddDropdownTooltip(saturatedDD, saturatedLabel, L.BUFFS_SATURATED,
        L.BUFFS_SATURATED_TIP)

    f.displayDivider = CreateMiniDivider(f, L.BUFFS_SECTION_DISPLAY)
    f.requirementDivider = CreateMiniDivider(f, L.BUFFS_SECTION_REQUIREMENT)
    f.completionDivider = CreateMiniDivider(f, L.BUFFS_SECTION_COMPLETION)
    f.targetsDivider = CreateMiniDivider(f, L.BUFFS_SECTION_TARGETS)
    f.optionChecks, f.optionLabels = {}, {}
    f.normalOptionRegions = {
        displayLabel, displayDD, classLabel, classDD, colorLabel, colorField,
        saturatedLabel, saturatedDD, f.displayDivider, f.requirementDivider,
        f.completionDivider, f.targetsDivider,
    }
    -- Each option with the string keys of its label and tooltip.
    local checkboxOptions = {
        { "negative", "BUFFS_NEGATIVE", "BUFFS_NEGATIVE_TIP" },
        { "hideComplete", "BUFFS_HIDE_BAR_COMPLETE", "BUFFS_HIDE_BAR_COMPLETE_TIP" },
        { "hideColumnComplete", "BUFFS_HIDE_COLUMN_COMPLETE",
            "BUFFS_HIDE_COLUMN_COMPLETE_TIP" },
        { "flagOutsideRaid", "BUFFS_FLAG_OUTSIDE_RAID", "BUFFS_FLAG_OUTSIDE_RAID_TIP" },
        { "bestAvailable", "BUFFS_BEST_AVAILABLE", "BUFFS_BEST_AVAILABLE_TIP" },
        { "anyInCombat", "BUFFS_ANY_IN_COMBAT", "BUFFS_ANY_IN_COMBAT_TIP" },
        { "onlyManaUsers", "BUFFS_ONLY_MANA_USERS", "BUFFS_ONLY_MANA_USERS_TIP" },
        { "onlyTanks", "BUFFS_ONLY_TANKS", "BUFFS_ONLY_TANKS_TIP" },
        { "hunterPets", "BUFFS_HUNTER_PETS", "BUFFS_HUNTER_PETS_TIP" },
        { "hideBarUnavailable", "BUFFS_HIDE_BAR_UNAVAILABLE",
            "BUFFS_HIDE_BAR_UNAVAILABLE_TIP" },
        { "hideColumnUnavailable", "BUFFS_HIDE_COLUMN_UNAVAILABLE",
            "BUFFS_HIDE_COLUMN_UNAVAILABLE_TIP" },
        { "combinePaladinBars", "BUFFS_COMBINE_PALADIN_BARS",
            "BUFFS_COMBINE_PALADIN_BARS_TIP" },
        { "responsibleGlow", "BUFFS_RESPONSIBLE_GLOW",
            WhoDoesWhat.ClientFeatures.buffTalents
                and "BUFFS_RESPONSIBLE_GLOW_TALENTS_TIP" or "BUFFS_RESPONSIBLE_GLOW_TIP" },
        { "offspecResponsible", "BUFFS_OFFSPEC_RESPONSIBLE",
            "BUFFS_OFFSPEC_RESPONSIBLE_TIP" },
        { "partialGlow", "BUFFS_PARTIAL_GLOW", "BUFFS_PARTIAL_GLOW_TIP" },
        { "partialGlowOnlyClass", "BUFFS_PARTIAL_GLOW_ONLY_CLASS",
            "BUFFS_PARTIAL_GLOW_ONLY_CLASS_TIP" },
    }
    for index, entry in ipairs(checkboxOptions) do
        local option, labelText, tooltip = entry[1], L[entry[2]], L[entry[3]]
        local check = UI.CreateCheckbox(f, labelText, labelText, tooltip,
            function(self)
                SetStatusBuffOption(owner, f.buffKey, option,
                    self:GetChecked() and true or false)
                RefreshBuffOptionsFrame()
            end,
            { size = 24, font = "GameFontHighlight", gap = 2, labelParent = f })
        check:SetPoint("TOPLEFT", 7, -(104 + (index - 1) * OPTION_ROW_H))
        check:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
        local label = check.label
        f.optionChecks[option] = check
        f.optionLabels[option] = label
        f.normalOptionRegions[#f.normalOptionRegions + 1] = check
        f.normalOptionRegions[#f.normalOptionRegions + 1] = label
    end

    f.ppHideSyncedCheck, _, f.ppHideSyncedLabel = AddCompactCheckboxRow(
        f, 7, 76, L.BUFFS_PP_HIDE_SYNCED, L.BUFFS_PP_HIDE_SYNCED_TIP,
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "hideWhenSynced", value)
            RefreshBuffOptionsFrame()
        end)
    f.ppHideSyncedCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
    f.ppHideInactiveCheck, _, f.ppHideInactiveLabel = AddCompactCheckboxRow(
        f, 7, 104, L.BUFFS_PP_HIDE_INACTIVE, L.BUFFS_PP_HIDE_INACTIVE_TIP,
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "hideWhenInactive", value)
            RefreshBuffOptionsFrame()
        end)
    f.ppHideInactiveCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
    f.ppGlowCheck, _, f.ppGlowLabel = AddCompactCheckboxRow(
        f, 7, 132, L.BUFFS_PP_GLOW, L.BUFFS_PP_GLOW_TIP,
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "assignmentIssuesGlow", value)
            RefreshBuffOptionsFrame()
        end)
    f.ppGlowCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)

    -- Action Items' trio, the same shape as PallyPower's above: two "when is
    -- this row worth a line" toggles and one glow. RefreshBuffOptionsFrame
    -- places them; the y values here are overwritten on the first open.
    f.aiHideClearCheck, _, f.aiHideClearLabel = AddCompactCheckboxRow(
        f, 7, 76, L.BUFFS_AI_HIDE_CLEAR, L.BUFFS_AI_HIDE_CLEAR_TIP,
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "hideWhenClear", value)
            RefreshBuffOptionsFrame()
        end)
    f.aiHideClearCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
    f.aiHideSoloCheck, _, f.aiHideSoloLabel = AddCompactCheckboxRow(
        f, 7, 104, L.BUFFS_AI_HIDE_SOLO, L.BUFFS_AI_HIDE_SOLO_TIP,
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "hideWhenSolo", value)
            RefreshBuffOptionsFrame()
        end)
    f.aiHideSoloCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
    f.aiHideNotYoursCheck, _, f.aiHideNotYoursLabel = AddCompactCheckboxRow(
        f, 7, 132, L.BUFFS_AI_HIDE_NOT_YOURS, L.BUFFS_AI_HIDE_NOT_YOURS_TIP,
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "hideWhenNotYours", value)
            RefreshBuffOptionsFrame()
        end)
    f.aiHideNotYoursCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
    f.aiGlowCheck, _, f.aiGlowLabel = AddCompactCheckboxRow(
        f, 7, 132, L.BUFFS_AI_GLOW, L.BUFFS_AI_GLOW_TIP,
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "actionItemsGlow", value)
            RefreshBuffOptionsFrame()
        end)
    f.aiGlowCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)

    for _, region in ipairs({
        f.ppHideSyncedCheck, f.ppHideSyncedLabel,
        f.ppHideInactiveCheck, f.ppHideInactiveLabel,
        f.ppGlowCheck, f.ppGlowLabel,
        f.aiHideClearCheck, f.aiHideClearLabel,
        f.aiHideSoloCheck, f.aiHideSoloLabel,
        f.aiHideNotYoursCheck, f.aiHideNotYoursLabel,
        f.aiGlowCheck, f.aiGlowLabel,
    }) do
        region:Hide()
    end

    buffOptionsFrame = f
    return f
end

local function OpenBuffOptions(owner, key)
    local f = EnsureBuffOptionsFrame(owner, key)
    if f.buffKey ~= key then UI.CancelColorPicker() end
    f.buffKey = key
    RefreshBuffOptionsFrame()
    RefreshStatusBuffRows(owner)
    f:Show()
end

-- Drag to reorder. The dragged row follows the cursor and the others close up
-- around the slot it would land in. The "Hidden from Status Bars" divider is
-- one of the slots' neighbours like any row, so dropping below it turns the
-- row's bar off and dropping above it turns it back on.
local DRAG_SCROLL_EDGE = 20   -- how near the scroll's top or bottom starts scrolling
local DRAG_SCROLL_SPEED = 300 -- pixels a second

local function UpdateStatusBuffDrag(f, elapsed)
    local drag = f.statusBuffDrag
    local page, scroll = drag.row:GetParent(), f.statusBuffScroll
    local _, cursorY = GetCursorPosition()
    cursorY = cursorY / page:GetEffectiveScale()

    -- Held against an edge of the list, scroll it. Through the bar, which
    -- clamps to the range and keeps its thumb in step.
    local bar = scroll.uiScrollBar
    if bar and bar:IsShown() then
        local step = (cursorY > scroll:GetTop() - DRAG_SCROLL_EDGE and -1)
            or (cursorY < scroll:GetBottom() + DRAG_SCROLL_EDGE and 1) or 0
        if step ~= 0 then
            bar:SetValue(bar:GetValue() + step * DRAG_SCROLL_SPEED * elapsed)
        end
    end

    -- How far down the list the dragged row's top edge is, and the gap nearest
    -- it: gap N sits below the first N of the remaining rows-plus-divider.
    local depth = page:GetTop() - (cursorY + drag.grabOffset) - f.statusBuffListTop
    local others, otherEnabled = drag.others, drag.otherEnabled
    local slots = #others + 1
    local gap = math.max(0, math.min(slots,
        math.floor(depth / STATUS_BUFF_ROW_H + 0.5)))
    drag.gap = gap

    drag.row:ClearAllPoints()
    drag.row:SetPoint("TOPLEFT", CONTENT_X, -(f.statusBuffListTop + depth))
    drag.row.index:SetText(gap <= otherEnabled and ((gap + 1) .. ".") or "")
    for i = 1, slots do
        local region
        if i == otherEnabled + 1 then
            region = f.statusBuffDivider
        else
            region = f.statusBuffRows[others[i > otherEnabled and i - 1 or i]]
            if i <= otherEnabled then
                region.index:SetText((i + (gap < i and 1 or 0)) .. ".")
            end
        end
        local slot = i + (i > gap and 1 or 0)
        region:ClearAllPoints()
        region:SetPoint("TOPLEFT", CONTENT_X,
            -(f.statusBuffListTop + (slot - 1) * STATUS_BUFF_ROW_H))
    end
end

local function StartStatusBuffDrag(f, row, key)
    if f.statusBuffDrag then return end
    local others, otherEnabled, wasEnabled = {}, f.statusBuffEnabledCount, false
    for i, orderedKey in ipairs(f.statusBuffOrder) do
        if orderedKey == key then
            wasEnabled = i <= f.statusBuffEnabledCount
            if wasEnabled then otherEnabled = otherEnabled - 1 end
        else
            others[#others + 1] = orderedKey
        end
    end
    f.statusBuffDrag = {
        row = row, key = key, others = others, otherEnabled = otherEnabled,
        wasEnabled = wasEnabled, level = row:GetFrameLevel(),
        grabOffset = row.grabOffset,
    }
    -- The row's follow-the-cursor tooltip would ride along with the drag.
    row.hover:SetScript("OnUpdate", nil)
    if GameTooltip:GetOwner() == row.hover then GameTooltip:Hide() end
    row:SetFrameLevel(row:GetFrameLevel() + 10)
    row.stripe:SetColorTexture(0.42, 0.33, 0.04, 1)
    f.statusBuffDivider:Show()
    UpdateStatusBuffDrag(f, 0)
    f.statusBuffDragDriver:Show()
end

-- `commit` false puts everything back where it was: the page closed mid-drag.
local function StopStatusBuffDrag(f, commit)
    local drag = f.statusBuffDrag
    if not drag then return end
    f.statusBuffDrag = nil
    f.statusBuffDragDriver:Hide()
    drag.row:SetFrameLevel(drag.level)
    if not commit then
        RefreshStatusBuffRows(f)
        return
    end
    local enabled = drag.gap <= drag.otherEnabled
    local order = drag.others
    table.insert(order, drag.gap + (enabled and 1 or 0), drag.key)
    f.statusBuffOrder = order
    f.statusBuffEnabledCount = drag.otherEnabled + (enabled and 1 or 0)
    if enabled ~= drag.wasEnabled then
        StoreStatusBuffOption(drag.key, "bar", enabled)
    end
    FinishStatusBuffOrderChange(f)
    OpenBuffOptions(f, drag.key)
end

local function ResetBuffTrackingPage(f)
    local settings = WhoDoesWhat.db.profile.settings
    wipe(settings.statusBarChecks)
    settings.statusBarOrder = nil
    WhoDoesWhat:InvalidateStatusBarCheckCache()
    RefreshStatusBuffRows(f)
    RefreshBuffOptionsFrame()
    WhoDoesWhat:RefreshBoardViews()
    WhoDoesWhat:RefreshStatusBarsView()
end

-- The Settings frame the table was built into, for opening a row from outside.
local settingsFrame = nil

local function BuildBuffTrackingPage(f, page, scroll)
    settingsFrame = f
    local statusBuffPage = page
    local buffScroll = scroll
    local buffWell = buffScroll:GetParent()

    -- Two panels in place of the section's one fill: the table's on the
    -- left, the row options' on the right.
    buffWell.fill:Hide()
    local tableFill = buffWell:CreateTexture(nil, "BACKGROUND")
    tableFill:SetPoint("TOPLEFT")
    tableFill:SetPoint("BOTTOMLEFT")
    tableFill:SetWidth(BUFF_TABLE_W)
    local optionsFill = buffWell:CreateTexture(nil, "BACKGROUND")
    optionsFill:SetPoint("TOPLEFT", BUFF_TABLE_W + BUFF_PANEL_GAP, 0)
    optionsFill:SetPoint("BOTTOMRIGHT")
    for _, fill in ipairs({ tableFill, optionsFill }) do
        fill:SetColorTexture(PAGE_WELL[1], PAGE_WELL[2], PAGE_WELL[3], PAGE_WELL[4])
    end

    -- The rows scroll under their column headings, which sit on the panel
    -- itself and so stay in view. The scrollbar runs down the panel's right.
    buffScroll:ClearAllPoints()
    buffScroll:SetPoint("TOPLEFT", 0, -BUFF_HEADINGS_H)
    buffScroll:SetPoint("BOTTOMLEFT", 0, 4)
    buffScroll:SetWidth(CONTENT_X + CONTENT_W)

    -- Each column's heading and tooltip keys, x and width.
    local headers = {
        { "BUFFS_COLUMN_BUFF", "BUFFS_COLUMN_BUFF_TIP", 84, 155 },
        { "BUFFS_COLUMN_BARS", "BUFFS_COLUMN_BARS_TIP", 250, 44 },
        { "BUFFS_COLUMN_GRID", "BUFFS_COLUMN_GRID_TIP", 298, 62 },
        { "BUFFS_COLUMN_OPTIONS", "BUFFS_COLUMN_OPTIONS_TIP", 364, 46 },
    }
    for index, header in ipairs(headers) do
        local text = buffWell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("TOPLEFT", CONTENT_X + header[3], -2)
        text:SetSize(header[4], 26)
        text:SetJustifyH(index == 1 and "LEFT" or "CENTER")
        text:SetText(L[header[1]])
        UI.AddTooltip(text, L[header[1]], L[header[2]])
    end
    f.statusBuffListTop = 0
    local divider = CreateFrame("Frame", nil, statusBuffPage)
    divider:SetSize(CONTENT_W, STATUS_BUFF_ROW_H)
    local dividerLabel = divider:CreateFontString(nil, "BACKGROUND", "GameFontNormalSmall")
    dividerLabel:SetPoint("TOP")
    dividerLabel:SetPoint("BOTTOM")
    dividerLabel:SetText(L.BUFFS_HIDDEN_DIVIDER)
    dividerLabel:SetTextColor(0.55, 0.55, 0.55)
    local dividerLeft = divider:CreateTexture(nil, "BACKGROUND")
    dividerLeft:SetHeight(8)
    dividerLeft:SetPoint("LEFT", 3, 0)
    dividerLeft:SetPoint("RIGHT", dividerLabel, "LEFT", -5, 0)
    dividerLeft:SetTexture(137057)
    dividerLeft:SetTexCoord(0.81, 0.94, 0.5, 1)
    dividerLeft:SetVertexColor(0.45, 0.45, 0.45)
    local dividerRight = divider:CreateTexture(nil, "BACKGROUND")
    dividerRight:SetHeight(8)
    dividerRight:SetPoint("RIGHT", -3, 0)
    dividerRight:SetPoint("LEFT", dividerLabel, "RIGHT", 5, 0)
    dividerRight:SetTexture(137057)
    dividerRight:SetTexCoord(0.81, 0.94, 0.5, 1)
    dividerRight:SetVertexColor(0.45, 0.45, 0.45)
    UI.AddTooltip(divider, L.BUFFS_HIDDEN_DIVIDER, L.BUFFS_HIDDEN_DIVIDER_TIP)
    f.statusBuffDivider = divider
    f.statusBuffScroll = buffScroll
    local dragDriver = CreateFrame("Frame", nil, statusBuffPage)
    dragDriver:Hide()
    dragDriver:SetScript("OnUpdate", function(_, elapsed)
        UpdateStatusBuffDrag(f, elapsed)
    end)
    f.statusBuffDragDriver = dragDriver
    f.statusBuffRows = {}
    for _, key in ipairs(WhoDoesWhat.StatusBarCheckOrder) do
        local rowKey = key
        local definition = WhoDoesWhat.StatusBarChecks[rowKey]
        local row = CreateFrame("Frame", nil, statusBuffPage)
        row:SetSize(CONTENT_W, STATUS_BUFF_ROW_H)
        f.statusBuffRows[rowKey] = row

        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        row.stripe = stripe

        -- The whole row is the drag handle; the checkboxes and cog take their
        -- own clicks first. The grip dots, where the arrows used to be, say so.
        -- The row's tooltip sits on `hover`, which stops short of the grip so
        -- reaching for the handle doesn't open one; it drags the row too.
        local hover = CreateFrame("Frame", nil, row)
        hover:SetPoint("TOPLEFT", 50, 0)
        hover:SetPoint("BOTTOMRIGHT")
        hover:SetFrameLevel(row:GetFrameLevel()) -- under the checkboxes and cog
        row.hover = hover
        for _, handle in ipairs({ row, hover }) do
            handle:EnableMouse(true)
            handle:RegisterForDrag("LeftButton")
            -- Where on the row it was grabbed is taken at the press, not when
            -- the drag starts: the client holds OnDragStart back until the
            -- cursor has travelled a few pixels, and measuring then would leave
            -- the row trailing the cursor by that distance for the whole drag.
            handle:SetScript("OnMouseDown", function()
                local _, cursorY = GetCursorPosition()
                row.grabOffset = row:GetTop() - cursorY / row:GetEffectiveScale()
            end)
            handle:SetScript("OnDragStart", function()
                StartStatusBuffDrag(f, row, rowKey)
            end)
            handle:SetScript("OnDragStop", function() StopStatusBuffDrag(f, true) end)
        end
        row:HookScript("OnHide", function() StopStatusBuffDrag(f, false) end)
        for col = 0, 1 do
            for line = -1, 1 do
                local dot = row:CreateTexture(nil, "ARTWORK")
                dot:SetSize(3, 3)
                dot:SetPoint("CENTER", row, "LEFT", 22 + col * 6, line * 6)
                dot:SetColorTexture(0.6, 0.6, 0.6, 0.9)
            end
        end

        local index = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        index:SetPoint("LEFT", 55, 0)
        index:SetWidth(20)
        index:SetJustifyH("LEFT")
        index:SetTextColor(1, 0.82, 0)
        row.index = index

        local icon
        if definition.customOptions == "pallyPower" then
            icon = K.CreatePallyPowerBadge(row, 16)
            icon:SetPoint("LEFT", index, "RIGHT", 1, 0)
        else
            icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(16, 16)
            icon:SetPoint("LEFT", index, "RIGHT", 1, 0)
            WhoDoesWhat:ApplyStatusCheckIcon(icon, definition)
        end
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", icon, "RIGHT", 7, 0)
        name:SetWidth(148)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)
        name:SetText(definition.name)
        UI.AddTooltip(hover, definition.name, definition.description, nil, true)

        row.bar = UI.CreateCheckbox(row, nil, L.BUFFS_SHOW_IN_BARS, L.BUFFS_SHOW_IN_BARS_TIP,
            function(self)
                SetStatusBuffBarEnabled(f, rowKey, self:GetChecked() and true or false)
            end, { size = 24 })
        row.bar:SetPoint("CENTER", row, "LEFT", 272, 0)
        row.grid = UI.CreateCheckbox(row, nil, L.BUFFS_SHOW_IN_GRID, L.BUFFS_SHOW_IN_GRID_TIP,
            function(self)
                SetStatusBuffOption(f, rowKey, "grid", self:GetChecked() and true or false)
            end, { size = 24 })
        row.grid:SetPoint("CENTER", row, "LEFT", 329, 0)
        local options = CreateFrame("Button", nil, row)
        options:SetSize(24, 24)
        options:SetPoint("CENTER", row, "LEFT", 387, 0)
        options:RegisterForClicks("LeftButtonUp")
        options:SetNormalTexture(OPTIONS_BUTTON .. "Up.tga")
        options:SetPushedTexture(OPTIONS_BUTTON .. "Down.tga")
        -- Keep Blizzard's 32px source at 1:1 so its tiny cog is not blurred
        -- by scaling the whole padded texture down to the row's hit box.
        for _, texture in ipairs({ options:GetNormalTexture(),
            options:GetPushedTexture() }) do
            texture:ClearAllPoints()
            texture:SetPoint("CENTER")
            texture:SetSize(32, 32)
        end
        options:SetHighlightTexture(
            "Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
        options:SetScript("OnClick", function() OpenBuffOptions(f, rowKey) end)
        UI.AddTooltip(options, L.BUFFS_ROW_OPTIONS:format(definition.name),
            L.BUFFS_ROW_OPTIONS_TIP)
        row.options = options
    end
    RefreshStatusBuffRows(f)
    -- The options view is part of the section, so it always shows a row: the
    -- first one until a cog picks another.
    f.buffTrackingWell = buffWell
    OpenBuffOptions(f, WhoDoesWhat:GetStatusBarCheckOrder()[1])
end

S.RegisterPage({
    id = "Buffs", labelKey = "SETTINGS_BUFFS", titleKey = "SETTINGS_BUFFS_TITLE",
    tooltipKey = "SETTINGS_BUFFS_TIP", descriptionKey = "SETTINGS_BUFFS_RESET",
    -- Its scroll moves below the column headings, and the options panel
    -- beside it draws the shadows.
    ownScroll = true,
    Build = BuildBuffTrackingPage,
    Refresh = RefreshStatusBuffRows,
    Reset = ResetBuffTrackingPage,
})

-- Open one check's cog options directly (WDW Status' shift-right-click on a
-- bar). Selecting the page cancels any open colour picker, so the row is
-- picked after the window is on the right page.
function WhoDoesWhat:OpenBuffTrackingOptions(key)
    if not self.StatusBarChecks[key] then return end
    self:OpenAddonSettingsView("Buffs")
    OpenBuffOptions(settingsFrame, key)
end
