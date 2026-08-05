local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local K = WhoDoesWhat.SectionKit

-- Addon settings window. Checkbox state persists in db.profile.settings except
-- detailed sync logging, which is deliberately session-only and resets off.

local settingsFrame = nil
local buffOptionsFrame = nil

local NAV_X = 14
local NAV_W = 104
local CONTENT_X = 134
local CONTENT_W = 410
local FRAME_W = 560
local FRAME_H = 564
local BUFF_OPTIONS_W = 242
--@do-not-package@
FRAME_H = 594
--@end-do-not-package@
local FIRST_PALADIN_LABEL = "(use first paladin)"
local IS_CLASSIC_ERA = WhoDoesWhat.ClientFeatures.isClassicEra
local STATUS_SCOPE_LABELS = {
    always = "All", raid = "Raid", party = "Party",
}
local STATUS_DISPLAY_LABELS = {
    default = "Default", percent = "Percent", missing = "Missing Count",
    fraction = "Fraction", applied = "Applied Count",
}
local STATUS_SATURATED_LABELS = {
    hide = "Hide Bar", x = "X", check = "Checkmark",
}
local STATUS_TOOLTIP_ANCHOR_LABELS = {
    LEFT = "Left", RIGHT = "Right", ABOVE = "Above", BELOW = "Below",
}
local OPTIONS_BUTTON = "Interface\\AddOns\\WhoDoesWhat\\Media\\UI-Panel-OptionsButton-"
local STATUS_BUFF_ROW_H = 26
local STATUS_ARROW_NUDGE = { Up = 2, Down = -4 }

local function RefreshBuffingTestPaladinDropdown(f)
    WhoDoesWhat:GetBuffingBarTestPaladin()
    if f.buffingTestDD then
        UIDropDownMenu_SetText(f.buffingTestDD,
            WhoDoesWhat.db.profile.settings.buffingBarTestPaladin or FIRST_PALADIN_LABEL)
    end
end

-- Section heading at column origin `x`. Returns the y below it.
local function AddHeading(f, x, y, text, r, g, b)
    local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    h:SetPoint("TOPLEFT", x, -y)
    h:SetText(text)
    if r then h:SetTextColor(r, g, b) end
    return y + 28, h
end

local function CreateStatusArrow(parent, direction)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(24, 24)
    button:SetText("")
    if button.SetMotionScriptsWhileDisabled then
        button:SetMotionScriptsWhileDisabled(true)
    end
    local arrow = button:CreateTexture(nil, "OVERLAY")
    arrow:SetSize(12, 12)
    arrow:SetPoint("CENTER", 0, STATUS_ARROW_NUDGE[direction])
    arrow:SetTexture("Interface\\Buttons\\Arrow-" .. direction .. "-Up")
    button.arrow = arrow
    return button
end

local function SetStatusArrowEnabled(button, enabled)
    button:SetEnabled(enabled)
    button.arrow:SetDesaturated(not enabled)
    button.arrow:SetVertexColor(enabled and 1 or 0.5,
        enabled and 1 or 0.5, enabled and 1 or 0.5)
end

local function StoreStatusBuffOption(key, option, value)
    local settings = WhoDoesWhat.db.profile.settings
    settings.statusBarChecks = settings.statusBarChecks or {}
    settings.statusBarChecks[key] = settings.statusBarChecks[key] or {}
    settings.statusBarChecks[key][option] = value
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
    if not f.statusBuffRows then return end
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
        SetStatusArrowEnabled(row.up, index > 1 or disabled)
        SetStatusArrowEnabled(row.down, index <= enabledCount)
        row.bar:SetChecked(options.bar)
        row.grid:SetChecked(options.grid)
        row.grid:SetShown(not WhoDoesWhat.StatusBarChecks[key].gridOptionDisabled)
        local shade = index % 2 == 1 and 0.18 or 0.10
        row.stripe:SetColorTexture(shade, shade, shade + 0.02, 0.72)
    end
end

local function FinishStatusBuffOrderChange(f)
    local settings = WhoDoesWhat.db.profile.settings
    settings.statusBarOrder = { unpack(f.statusBuffOrder) }
    RefreshStatusBuffRows(f)
    WhoDoesWhat:RefreshBuffingGridView()
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

local function MoveStatusBuff(f, key, delta)
    local index
    for i, orderedKey in ipairs(f.statusBuffOrder) do
        if orderedKey == key then index = i break end
    end
    if not index then return end
    local active = f.statusBuffEnabledCount
    if delta < 0 and index > active then
        table.remove(f.statusBuffOrder, index)
        active = active + 1
        table.insert(f.statusBuffOrder, active, key)
        StoreStatusBuffOption(key, "bar", true)
    elseif delta < 0 and index > 1 then
        f.statusBuffOrder[index], f.statusBuffOrder[index - 1] =
            f.statusBuffOrder[index - 1], f.statusBuffOrder[index]
    elseif delta > 0 and index == active then
        active = active - 1
        StoreStatusBuffOption(key, "bar", false)
    elseif delta > 0 and index < active then
        f.statusBuffOrder[index], f.statusBuffOrder[index + 1] =
            f.statusBuffOrder[index + 1], f.statusBuffOrder[index]
    else
        return
    end
    f.statusBuffEnabledCount = active
    FinishStatusBuffOrderChange(f)
end

local function SetStatusBuffOption(f, key, option, value)
    StoreStatusBuffOption(key, option, value)
    RefreshStatusBuffRows(f)
    WhoDoesWhat:RefreshBuffingGridView()
    WhoDoesWhat:RefreshStatusBarsView()
end

local function AddTooltip(region, title, text)
    region:EnableMouse(true)
    local previousEnter = region:GetScript("OnEnter")
    local previousLeave = region:GetScript("OnLeave")
    region:SetScript("OnEnter", function(self, ...)
        if previousEnter then previousEnter(self, ...) end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        GameTooltip:AddLine(text, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    region:SetScript("OnLeave", function(self, ...)
        if previousLeave then previousLeave(self, ...) end
        GameTooltip:Hide()
    end)
end

local function AddDropdownTooltip(dd, label, title, text)
    AddTooltip(label, title, text)
    local button = _G[dd:GetName() .. "Button"]
    if button then AddTooltip(button, title, text) end
end

local function AddCompactCheckboxRow(f, x, y, labelText, tooltip, apply)
    local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("TOPLEFT", x, -y)
    check:SetHitRectInsets(0, -(CONTENT_W - 30 - (x - CONTENT_X)), 0, 0)
    check:SetMotionScriptsWhileDisabled(true)
    check:SetScript("OnClick", function(self)
        apply(self:GetChecked() and true or false)
    end)
    local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", check, "RIGHT", 2, 0)
    label:SetText(labelText)
    AddTooltip(check, labelText, tooltip)
    return check, y + 28, label
end

local MINIMAP_NAME = "WhoDoesWhat"
local MINIMAP_ICON = "Interface\\AddOns\\WhoDoesWhat\\Icon.png"
local minimapIcon
local minimapLoader = CreateFrame("Frame")

local function MinimapClick(_, mouseButton)
    local shift = IsShiftKeyDown()
    if shift and mouseButton == "RightButton" then
        WhoDoesWhat:OpenAddonSettingsView()
    elseif shift then
        WhoDoesWhat:OpenRaiderRolesView()
    elseif mouseButton == "RightButton" then
        WhoDoesWhat:OpenBuffingGridView()
    else
        WhoDoesWhat:ToggleMainUI()
    end
end

local function MinimapTooltip(tooltip)
    tooltip:AddLine("WhoDoesWhat", 1, 1, 1)
    tooltip:AddDoubleLine("Left-Click:", "Assignments",
        1, 0.82, 0, 1, 1, 1)
    tooltip:AddDoubleLine("Right-Click:", "Buffing Grid",
        1, 0.82, 0, 1, 1, 1)
    tooltip:AddDoubleLine("Shift-Left-Click:", "Members",
        1, 0.82, 0, 1, 1, 1)
    tooltip:AddDoubleLine("Shift-Right-Click:", "Settings",
        1, 0.82, 0, 1, 1, 1)
end

function WhoDoesWhat:InitializeMinimapButton()
    if minimapIcon then return end
    local broker = LibStub("LibDataBroker-1.1", true)
    local icon = LibStub("LibDBIcon-1.0", true)
    if not broker or not icon or not icon.ShowOnEnter then
        self:Print("Minimap button unavailable: compatible LibDataBroker and LibDBIcon libraries are not loaded.")
        return
    end
    local launcher = broker:NewDataObject(MINIMAP_NAME, {
        type = "launcher",
        text = MINIMAP_NAME,
        icon = MINIMAP_ICON,
        OnClick = MinimapClick,
        OnTooltipShow = MinimapTooltip,
    })
    icon:Register(MINIMAP_NAME, launcher,
        self.db.profile.settings.minimapButton)
    local button = icon:GetMinimapButton(MINIMAP_NAME)
    local mask = button:CreateMaskTexture(nil, "ARTWORK")
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(button.icon)
    button.icon:AddMaskTexture(mask)
    button.wdwIconMask = mask
    icon:ShowOnEnter(MINIMAP_NAME, true)
    minimapIcon = icon
    self:UpdateMinimapButtonVisibility()
end

function WhoDoesWhat:ScheduleMinimapButtonInitialization()
    if IsLoggedIn() then
        self:InitializeMinimapButton()
        return
    end
    minimapLoader:SetScript("OnEvent", function(frame)
        frame:UnregisterEvent("PLAYER_LOGIN")
        WhoDoesWhat:InitializeMinimapButton()
    end)
    minimapLoader:RegisterEvent("PLAYER_LOGIN")
end

function WhoDoesWhat:UpdateMinimapButtonVisibility()
    if not minimapIcon then return end
    local db = self.db.profile.settings.minimapButton
    if db.hide then
        minimapIcon:Hide(MINIMAP_NAME)
    else
        minimapIcon:Show(MINIMAP_NAME)
    end
end

local function SetOptionAvailable(check, label, available)
    check:SetEnabled(available)
    label:SetTextColor(available and 1 or 0.45,
        available and 1 or 0.45, available and 1 or 0.45)
end

local function DefaultStatusBarColor(definition)
    if definition.colorRGB then return definition.colorRGB end
    for _, classInfo in ipairs(WhoDoesWhat.Classes) do
        if classInfo.name == definition.className then return classInfo.colorRGB end
    end
    return { r = 0.96, g = 0.55, b = 0.73 }
end

local function ColorHex(color)
    local function Byte(value)
        return math.floor(math.max(0, math.min(1, value)) * 255 + 0.5)
    end
    return string.format("#%02X%02X%02X",
        Byte(color.r), Byte(color.g), Byte(color.b))
end

local function ParseColorHex(text)
    local hex = text and text:match("^#?(%x%x%x%x%x%x)$")
    if not hex then return nil end
    return tonumber(hex:sub(1, 2), 16) / 255,
        tonumber(hex:sub(3, 4), 16) / 255,
        tonumber(hex:sub(5, 6), 16) / 255
end

local function CreateMiniDivider(parent, text)
    local divider = CreateFrame("Frame", nil, parent)
    divider:SetSize(BUFF_OPTIONS_W - 16, 10)
    local label = divider:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(text)
    label:SetTextColor(0.52, 0.52, 0.52)
    local left = divider:CreateTexture(nil, "ARTWORK")
    left:SetHeight(1)
    left:SetPoint("LEFT")
    left:SetPoint("RIGHT", label, "LEFT", -6, 0)
    left:SetColorTexture(0.35, 0.35, 0.35, 0.7)
    local right = divider:CreateTexture(nil, "ARTWORK")
    right:SetHeight(1)
    right:SetPoint("LEFT", label, "RIGHT", 6, 0)
    right:SetPoint("RIGHT")
    right:SetColorTexture(0.35, 0.35, 0.35, 0.7)
    return divider
end

local function RefreshBuffOptionsFrame()
    local f = buffOptionsFrame
    if not f or not f.buffKey then return end
    local definition = WhoDoesWhat.StatusBarChecks[f.buffKey]
    local options = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey)
    local pallyPower = definition.customOptions == "pallyPower"
    f.buffIcon:SetShown(not pallyPower)
    f.ppHeaderBadge:SetShown(pallyPower)
    if not pallyPower then f.buffIcon:SetTexture(definition.icon) end
    f.buffName:SetText(definition.name)
    UIDropDownMenu_SetText(f.scopeDD,
        STATUS_SCOPE_LABELS[options.scope] or STATUS_SCOPE_LABELS.always)

    local function PlaceDropdown(label, dd, y)
        label:ClearAllPoints()
        label:SetPoint("TOPLEFT", 10, -(y + 1))
        dd:ClearAllPoints()
        dd:SetPoint("LEFT", label, "RIGHT", -7, -4)
    end
    for _, region in ipairs(f.normalOptionRegions) do
        region:SetShown(not pallyPower)
    end
    f.ppHideSyncedCheck:SetShown(pallyPower)
    f.ppHideSyncedLabel:SetShown(pallyPower)
    f.ppHideInactiveCheck:SetShown(pallyPower)
    f.ppHideInactiveLabel:SetShown(pallyPower)
    f.ppGlowCheck:SetShown(pallyPower)
    f.ppGlowLabel:SetShown(pallyPower)
    if pallyPower then
        PlaceDropdown(f.scopeLabel, f.scopeDD, 36)
        f:SetHeight(140)
        local ppRows = {
            { f.ppHideSyncedCheck, 66 },
            { f.ppHideInactiveCheck, 88 },
            { f.ppGlowCheck, 110 },
        }
        for _, row in ipairs(ppRows) do
            row[1]:ClearAllPoints()
            row[1]:SetPoint("TOPLEFT", 7, -row[2])
        end
        f.ppHideSyncedCheck:SetChecked(options.hideWhenSynced)
        f.ppHideInactiveCheck:SetChecked(options.hideWhenInactive)
        f.ppGlowCheck:SetChecked(options.assignmentIssuesGlow)
        SetOptionAvailable(f.ppGlowCheck, f.ppGlowLabel, true)
        return
    end

    UIDropDownMenu_SetText(f.displayDD,
        STATUS_DISPLAY_LABELS[options.display] or STATUS_DISPLAY_LABELS.default)
    UIDropDownMenu_SetText(f.classDD, options.requiredClass or "None")
    UIDropDownMenu_SetText(f.saturatedDD,
        STATUS_SATURATED_LABELS[options.saturatedStyle]
            or STATUS_SATURATED_LABELS.check)
    local color = options.barColor or DefaultStatusBarColor(definition)
    f.colorSwatch.color:SetColorTexture(color.r, color.g, color.b, 1)
    f.colorHex.buffKey = f.buffKey
    if not f.colorHex:HasFocus() then f.colorHex:SetText(ColorHex(color)) end
    for option, check in pairs(f.optionChecks) do
        check:SetChecked(options[option])
    end

    local hidden = definition.hiddenOptions or {}
    local hasRequirement = options.requiredClass ~= false
    local function PlaceOption(option, shown, y)
        local check, label = f.optionChecks[option], f.optionLabels[option]
        check:SetShown(shown)
        label:SetShown(shown)
        if shown then
            check:ClearAllPoints()
            check:SetPoint("TOPLEFT", 7, -y)
            return y + 21
        end
        return y
    end
    local function PlaceDivider(divider, shown, y)
        divider:SetShown(shown)
        if shown then
            divider:ClearAllPoints()
            divider:SetPoint("TOPLEFT", 8, -y)
            return y + 10
        end
        return y
    end

    local y = 36
    y = PlaceOption("combinePaladinBars", f.buffKey == "paladinBuffs", y)

    y = PlaceDivider(f.displayDivider, true, y + 1)
    y = y + 8
    PlaceDropdown(f.displayLabel, f.displayDD, y)
    y = y + 23
    f.colorLabel:ClearAllPoints()
    f.colorLabel:SetPoint("TOPLEFT", 10, -y)
    f.colorSwatch:ClearAllPoints()
    f.colorSwatch:SetPoint("LEFT", f.colorLabel, "RIGHT", 6, 0)
    y = y + 21

    y = PlaceDivider(f.requirementDivider, true, y + 1)
    y = y + 8
    PlaceDropdown(f.scopeLabel, f.scopeDD, y)
    y = y + 23
    PlaceDropdown(f.classLabel, f.classDD, y)
    local showBest = definition.improvedTalent ~= nil
        and not hidden.bestAvailable
    local showHideBarUnavailable = hasRequirement
        and not hidden.hideBarUnavailable
    local showHideColumnUnavailable = hasRequirement
        and not definition.gridOptionDisabled
        and not hidden.hideColumnUnavailable
    -- Responsibility follows the "Requires Class" dropdown: clearing it means
    -- nobody in particular owns the buff, so the glow has nothing to key on.
    local showResponsibleGlow = hasRequirement and not options.negative
        and not hidden.responsibleGlow
    y = y + ((showBest or showHideBarUnavailable
        or showHideColumnUnavailable or showResponsibleGlow) and 18 or 25)
    y = PlaceOption("bestAvailable", showBest, y)
    y = PlaceOption("responsibleGlow", showResponsibleGlow, y)
    y = PlaceOption("hideBarUnavailable", showHideBarUnavailable, y)
    y = PlaceOption("hideColumnUnavailable", showHideColumnUnavailable, y)

    y = PlaceDivider(f.completionDivider, true, y + 1)
    y = PlaceOption("negative", not hidden.negative, y)
    f.optionLabels.hideComplete:SetText(options.negative
        and "Hide Bar when debuff missing" or "Hide Bar when complete")
    y = PlaceOption("hideComplete", not hidden.hideComplete, y)
    f.saturatedLabel:SetShown(options.negative)
    f.saturatedDD:SetShown(options.negative)
    local showHideColumnComplete = not definition.gridOptionDisabled
        and not hidden.hideColumnComplete
    if options.negative then
        PlaceDropdown(f.saturatedLabel, f.saturatedDD, y + 2)
        y = y + (showHideColumnComplete and 20 or 25)
    end
    f.optionLabels.hideColumnComplete:SetText(options.negative
        and "Hide grid column when debuff missing"
        or "Hide grid column when complete")
    y = PlaceOption("hideColumnComplete", showHideColumnComplete, y)
    local showIncludeInTotal = not options.negative
        and not hidden.includeInTotal
    y = PlaceOption("includeInTotal", showIncludeInTotal, y)

    local showMana = not hidden.onlyManaUsers
    local showTanks = not hidden.onlyTanks
    local showPets = not hidden.hunterPets
    y = PlaceDivider(f.targetsDivider,
        showMana or showTanks or showPets, y + 1)
    y = PlaceOption("onlyManaUsers", showMana, y)
    y = PlaceOption("onlyTanks", showTanks, y)
    y = PlaceOption("hunterPets", showPets, y)
    for _, option in ipairs({ "bestAvailable", "hideBarUnavailable",
        "hideColumnUnavailable", "combinePaladinBars", "includeInTotal",
        "negative", "hideComplete", "responsibleGlow",
        "hideColumnComplete", "onlyManaUsers", "onlyTanks", "hunterPets" }) do
        if not f.optionChecks[option]:IsShown() then
            f.optionLabels[option]:Hide()
        end
    end
    if f.optionChecks.hunterPets:IsShown() then
        SetOptionAvailable(f.optionChecks.hunterPets,
            f.optionLabels.hunterPets,
            not definition.hunterPetsOptionDisabled)
    end
    f:SetHeight(y + 7)
end

local activeColorPickerCancel
local function CancelActiveColorPicker()
    local cancel = activeColorPickerCancel
    local owned = cancel ~= nil
        or WhoDoesWhat.statusBarColorPreviewKey ~= nil
    activeColorPickerCancel = nil
    if cancel then cancel() end
    if owned and ColorPickerFrame:IsShown() then
        ColorPickerFrame:Hide()
    elseif owned and WhoDoesWhat.statusBarColorPreviewKey then
        WhoDoesWhat.statusBarColorPreviewKey = nil
        WhoDoesWhat:RefreshStatusBarsView()
    end
end

local function OpenBarColorPicker(owner, f)
    CancelActiveColorPicker()
    local key = f.buffKey
    local options = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey)
    local definition = WhoDoesWhat.StatusBarChecks[f.buffKey]
    local color = options.barColor or DefaultStatusBarColor(definition)
    local original = options.barColor and {
        r = options.barColor.r,
        g = options.barColor.g,
        b = options.barColor.b,
    } or false
    local function Apply(r, g, b)
        SetStatusBuffOption(owner, key, "barColor",
            { r = r, g = g, b = b })
        RefreshBuffOptionsFrame()
    end
    local function Changed()
        Apply(ColorPickerFrame:GetColorRGB())
    end
    local function Cancel()
        if activeColorPickerCancel == Cancel then activeColorPickerCancel = nil end
        SetStatusBuffOption(owner, key, "barColor", original)
        RefreshBuffOptionsFrame()
    end

    if not ColorPickerFrame.wdwStatusPreviewHooked then
        ColorPickerFrame:HookScript("OnHide", function()
            activeColorPickerCancel = nil
            if not WhoDoesWhat.statusBarColorPreviewKey then return end
            WhoDoesWhat.statusBarColorPreviewKey = nil
            WhoDoesWhat:RefreshStatusBarsView()
        end)
        ColorPickerFrame.wdwStatusPreviewHooked = true
    end
    ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    ColorPickerFrame:SetFrameLevel(f:GetFrameLevel() + 10)
    ColorPickerFrame:SetClampedToScreen(true)
    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow({
            r = color.r, g = color.g, b = color.b,
            hasOpacity = false,
            swatchFunc = Changed,
            cancelFunc = Cancel,
        })
    else
        ColorPickerFrame.func = Changed
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.opacityFunc = nil
        ColorPickerFrame.cancelFunc = Cancel
        ColorPickerFrame:SetColorRGB(color.r, color.g, color.b)
        ColorPickerFrame:Show()
    end
    activeColorPickerCancel = Cancel
    WhoDoesWhat.statusBarColorPreviewKey = key
    WhoDoesWhat:RefreshStatusBarsView()
end

local function EnsureBuffOptionsFrame(owner, key)
    if buffOptionsFrame then return buffOptionsFrame end
    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatBuffTrackingOptionsFrame",
        BUFF_OPTIONS_W, 230, "")
    -- UIDropDownMenu_Initialize runs its callback immediately, before this
    -- constructor returns, so the selected key must already be available.
    f.buffKey = key
    f:SetParent(owner)
    f:SetToplevel(false)
    f:SetFrameLevel(owner:GetFrameLevel() + 20)
    f:HookScript("OnHide", CancelActiveColorPicker)
    f.titleBarTexture:Hide()
    f.titleText:Hide()
    f.titleBarHeight = 0
    f:ClearAllPoints()
    f:SetPoint("LEFT", owner, "RIGHT", 8, 0)

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", 8, -8)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.buffIcon = icon
    local ppHeaderBadge = K.CreatePallyPowerBadge(f, 20)
    ppHeaderBadge:SetPoint("TOPLEFT", 8, -8)
    ppHeaderBadge:Hide()
    f.ppHeaderBadge = ppHeaderBadge
    local name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    name:SetWidth(BUFF_OPTIONS_W - 55)
    name:SetJustifyH("LEFT")
    f.buffName = name

    local scopeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    scopeLabel:SetPoint("TOPLEFT", 10, -46)
    scopeLabel:SetText("Party type")
    local scopeDD = CreateFrame("Frame", "WhoDoesWhatBuffTrackingScopeDD", f,
        "UIDropDownMenuTemplate")
    scopeDD:SetPoint("LEFT", scopeLabel, "RIGHT", -7, -2)
    UIDropDownMenu_SetWidth(scopeDD, 72)
    WhoDoesWhat:StyleDropdown(scopeDD, true)
    UIDropDownMenu_Initialize(scopeDD, function(_, level)
        local saved = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey).scope
        for _, scope in ipairs({ "always", "raid", "party" }) do
            local scopeName = scope
            local info = UIDropDownMenu_CreateInfo()
            info.text = STATUS_SCOPE_LABELS[scopeName]
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
    AddDropdownTooltip(scopeDD, scopeLabel, "Party type",
        "Limit this check to raids, parties, or all group types.")

    local displayLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    displayLabel:SetPoint("TOPLEFT", 190, -46)
    displayLabel:SetText("Text Mode")
    local displayDD = CreateFrame("Frame", "WhoDoesWhatBuffTrackingDisplayDD", f,
        "UIDropDownMenuTemplate")
    displayDD:SetPoint("LEFT", displayLabel, "RIGHT", -7, -2)
    UIDropDownMenu_SetWidth(displayDD, 98)
    WhoDoesWhat:StyleDropdown(displayDD, true)
    UIDropDownMenu_Initialize(displayDD, function(_, level)
        local saved = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey).display
        for _, display in ipairs({
            "default", "percent", "applied", "missing", "fraction",
        }) do
            local displayName = display
            local info = UIDropDownMenu_CreateInfo()
            info.text = STATUS_DISPLAY_LABELS[displayName]
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
    AddDropdownTooltip(displayDD, displayLabel, "Text Mode",
        "Choose the text shown on the bar: percent, counts, or a fraction.")

    local classLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    classLabel:SetPoint("TOPLEFT", 10, -77)
    classLabel:SetText("Requires Class:")
    local classDD = CreateFrame("Frame", "WhoDoesWhatBuffTrackingClassDD", f,
        "UIDropDownMenuTemplate")
    classDD:SetPoint("LEFT", classLabel, "RIGHT", -7, -2)
    UIDropDownMenu_SetWidth(classDD, 90)
    WhoDoesWhat:StyleDropdown(classDD, true)
    UIDropDownMenu_Initialize(classDD, function(_, level)
        local saved = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey).requiredClass
        local none = UIDropDownMenu_CreateInfo()
        none.text = "None"
        none.checked = saved == false
        none.func = function()
            SetStatusBuffOption(owner, f.buffKey, "requiredClass", false)
            RefreshBuffOptionsFrame()
        end
        UIDropDownMenu_AddButton(none, level)
        for _, classInfo in ipairs(WhoDoesWhat.Classes) do
            local className = classInfo.name
            local info = UIDropDownMenu_CreateInfo()
            info.text = className
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
    AddDropdownTooltip(classDD, classLabel, "Requires class",
        "The check is unavailable unless a member of this class is present.")

    local colorLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    colorLabel:SetPoint("TOPLEFT", 190, -77)
    colorLabel:SetText("Bar Color")
    local colorSwatch = CreateFrame("Button", nil, f)
    colorSwatch:SetSize(22, 11)
    colorSwatch:SetPoint("LEFT", colorLabel, "RIGHT", 6, 0)
    colorSwatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local color = colorSwatch:CreateTexture(nil, "ARTWORK")
    color:SetAllPoints()
    colorSwatch.color = color
    colorSwatch:SetScript("OnClick", function(_, button)
        if f.colorHex and f.colorHex:HasFocus() then f.colorHex:ClearFocus() end
        if button == "RightButton" then
            SetStatusBuffOption(owner, f.buffKey, "barColor", false)
            RefreshBuffOptionsFrame()
        else
            OpenBarColorPicker(owner, f)
        end
    end)
    AddTooltip(colorLabel, "Bar color",
        "Choose the filled status-bar color. Right-click the swatch to reset it.")
    AddTooltip(colorSwatch, "Bar color",
        "Left-click for the WoW color picker; right-click to reset.")
    f.colorSwatch = colorSwatch
    f.colorLabel = colorLabel

    local colorHex = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    colorHex:SetSize(64, 18)
    colorHex:SetPoint("LEFT", colorSwatch, "RIGHT", 7, 0)
    colorHex:SetAutoFocus(false)
    colorHex:SetMaxLetters(7)
    colorHex:SetText("#FFFFFF")
    colorHex:SetScript("OnEditFocusGained", function(self)
        CancelActiveColorPicker()
        local options = WhoDoesWhat:GetStatusBarCheckOptions(self.buffKey)
        local definition = WhoDoesWhat.StatusBarChecks[self.buffKey]
        self:SetText(ColorHex(options.barColor
            or DefaultStatusBarColor(definition)))
        self:HighlightText()
    end)
    colorHex:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    colorHex:SetScript("OnEscapePressed", function(self)
        self.reverting = true
        self:ClearFocus()
        RefreshBuffOptionsFrame()
    end)
    colorHex:SetScript("OnEditFocusLost", function(self)
        if self.reverting then
            self.reverting = nil
            return
        end
        local r, g, b = ParseColorHex(self:GetText())
        if r then
            SetStatusBuffOption(owner, self.buffKey, "barColor",
                { r = r, g = g, b = b })
        else
            RefreshBuffOptionsFrame()
        end
    end)
    AddTooltip(colorHex, "Hex color",
        "Enter a six-digit RGB color, with or without #, then press Enter.")
    f.colorHex = colorHex

    local saturatedLabel = f:CreateFontString(nil, "OVERLAY",
        "GameFontHighlightSmall")
    saturatedLabel:SetText("Fully Debuffed Style:")
    local saturatedDD = CreateFrame("Frame",
        "WhoDoesWhatBuffTrackingSaturatedStyleDD", f,
        "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(saturatedDD, 72)
    WhoDoesWhat:StyleDropdown(saturatedDD, true)
    UIDropDownMenu_Initialize(saturatedDD, function(_, level)
        local saved = WhoDoesWhat:GetStatusBarCheckOptions(
            f.buffKey).saturatedStyle
        for _, style in ipairs({ "hide", "x", "check" }) do
            local styleName = style
            local info = UIDropDownMenu_CreateInfo()
            info.text = STATUS_SATURATED_LABELS[styleName]
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
    AddDropdownTooltip(saturatedDD, saturatedLabel,
        "Fully Debuffed Style",
        "Choose what the status bar does once every tracked target has the"
            .. " debuff: show a checkmark, show an X, or hide the bar.")

    f.displayDivider = CreateMiniDivider(f, "Display")
    f.requirementDivider = CreateMiniDivider(f, "Requirement")
    f.completionDivider = CreateMiniDivider(f, "Completion")
    f.targetsDivider = CreateMiniDivider(f, "Targets")
    f.optionChecks, f.optionLabels = {}, {}
    f.normalOptionRegions = {
        displayLabel, displayDD, classLabel, classDD, colorLabel, colorSwatch,
        colorHex,
        saturatedLabel, saturatedDD, f.displayDivider, f.requirementDivider,
        f.completionDivider, f.targetsDivider,
    }
    local checkboxOptions = {
        { "negative", "Debuff",
            "Treat presence as the tracked condition; a missing debuff can hide its status row or grid column." },
        { "hideComplete", "Hide Bar when complete",
            "Hide the WDW Status row when the check is complete, or when a debuff is absent from everyone." },
        { "hideColumnComplete", "Hide grid column when complete",
            "Hide the Buffing Grid column when the check is complete, or when a debuff is absent from everyone." },
        { "bestAvailable", "Only consider best available",
            "Untalented buffs will not be counted toward the total buffing progress while a better buff is available." },
        { "onlyManaUsers", "Only for mana-users",
            "Only include classes that use mana." },
        { "onlyTanks", "Only for tanks",
            "Only include raiders assigned a tank role." },
        { "hunterPets", "Used by hunter pets",
            "Include active Hunter pets in this check." },
        { "hideBarUnavailable", "Hide bar when unavailable",
            "Hide the WDW Status row while the required class is absent." },
        { "hideColumnUnavailable", "Hide grid column when unavailable",
            "Hide the Buff Grid column while the required class is absent." },
        { "combinePaladinBars", "Show single combined Paladin row",
            "Replace the individual Paladin progress bars with one raid-wide blessing progress bar." },
        { "includeInTotal", "Include in Total Coverage Calculation",
            "Count this buff in the percentage shown in the WDW Status header." },
        { "responsibleGlow", "Glow when responsible",
            "Glow this WDW Status row while you are the class that supplies the"
                .. " buff and somebody is still missing it. With \"Only consider"
                .. " best available\" on, only the raid's best-talented caster"
                .. " is asked." },
    }
    for index, entry in ipairs(checkboxOptions) do
        local option, labelText, tooltip = entry[1], entry[2], entry[3]
        local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", 7, -(104 + (index - 1) * 21))
        check:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
        if check.SetMotionScriptsWhileDisabled then
            check:SetMotionScriptsWhileDisabled(true)
        end
        check:SetScript("OnClick", function(self)
            SetStatusBuffOption(owner, f.buffKey, option,
                self:GetChecked() and true or false)
            RefreshBuffOptionsFrame()
        end)
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", check, "RIGHT", 1, 0)
        label:SetText(labelText)
        AddTooltip(check, labelText, tooltip)
        f.optionChecks[option] = check
        f.optionLabels[option] = label
        f.normalOptionRegions[#f.normalOptionRegions + 1] = check
        f.normalOptionRegions[#f.normalOptionRegions + 1] = label
    end

    f.ppHideSyncedCheck, _, f.ppHideSyncedLabel = AddCompactCheckboxRow(
        f, 7, 76, "Hide when synced",
        "Hide this row while assignments are synchronized.",
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "hideWhenSynced", value)
            RefreshBuffOptionsFrame()
        end)
    f.ppHideSyncedCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
    f.ppHideInactiveCheck, _, f.ppHideInactiveLabel = AddCompactCheckboxRow(
        f, 7, 104, "Hide when inactive",
        "Hide this row when no active Paladin assignments can be compared.",
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "hideWhenInactive", value)
            RefreshBuffOptionsFrame()
        end)
    f.ppHideInactiveCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
    f.ppGlowCheck, _, f.ppGlowLabel = AddCompactCheckboxRow(
        f, 7, 132, "Assignment issues glow",
        "This bar will glow when Pally buffs need attention and you are a raid assistant.",
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "assignmentIssuesGlow", value)
            RefreshBuffOptionsFrame()
        end)
    f.ppGlowCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
    f.ppHideSyncedCheck:Hide()
    f.ppHideSyncedLabel:Hide()
    f.ppHideInactiveCheck:Hide()
    f.ppHideInactiveLabel:Hide()
    f.ppGlowCheck:Hide()
    f.ppGlowLabel:Hide()

    buffOptionsFrame = f
    return f
end

local function OpenBuffOptions(owner, key)
    local f = EnsureBuffOptionsFrame(owner, key)
    if f.buffKey ~= key then CancelActiveColorPicker() end
    f.buffKey = key
    RefreshBuffOptionsFrame()
    f:Show()
    f:Raise()
end

local function ResetBuffTrackingPage(f)
    local settings = WhoDoesWhat.db.profile.settings
    wipe(settings.statusBarChecks)
    settings.statusBarOrder = nil
    RefreshStatusBuffRows(f)
    RefreshBuffOptionsFrame()
    WhoDoesWhat:RefreshBuffingGridView()
    WhoDoesWhat:RefreshStatusBarsView()
end

local function CloseBuffOptions()
    CancelActiveColorPicker()
    if buffOptionsFrame then buffOptionsFrame:Hide() end
end

-- Build the settings window once and reuse it. Section buttons down the left
-- keep each page to one narrow column and work consistently across clients.
local function EnsureSettingsFrame()
    if settingsFrame then return settingsFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatSettingsFrame", FRAME_W, FRAME_H, "WhoDoesWhat - Settings")
    local y0 = f.titleBarHeight + 20
    local pages = {}
    local buttons = {}
    local sectionLabels = {
        "General", "Status Bars", "Buff Tracking", "Paladin Bar",
        "Warlocks", "Testing", "Developer",
    }

    local function SelectSection(index)
        CloseBuffOptions()
        for i, page in ipairs(pages) do
            if i == index then page:Show() else page:Hide() end
            if i == index then buttons[i]:LockHighlight() else buttons[i]:UnlockHighlight() end
        end
    end

    f.SelectSection = function(label)
        for i, name in ipairs(sectionLabels) do
            if name == label then SelectSection(i) return end
        end
    end

    for i, label in ipairs(sectionLabels) do
        local index = i
        local button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        button:SetSize(NAV_W, 24)
        button:SetPoint("TOPLEFT", f, "TOPLEFT", NAV_X, -(y0 + (i - 1) * 28))
        button:SetText(label)
        button:SetScript("OnClick", function() SelectSection(index) end)
        buttons[i] = button

        local page = CreateFrame("Frame", nil, f)
        page:SetAllPoints(f)
        pages[i] = page
    end

    -- ---- General ----
    local generalPage = pages[1]
    local yL = y0
    yL = AddHeading(generalPage, CONTENT_X, yL, "General")
    f.minimapCheck, yL = AddCompactCheckboxRow(generalPage, CONTENT_X, yL,
        "Show minimap button",
        "Show a draggable WhoDoesWhat button on the minimap.",
        function(value)
            WhoDoesWhat.db.profile.settings.minimapButton.hide = not value
            WhoDoesWhat:UpdateMinimapButtonVisibility()
        end)
    f.unitTooltipCheck, yL = AddCompactCheckboxRow(generalPage, CONTENT_X, yL,
        "Show roles in unit tooltips",
        "Add the player's assigned WhoDoesWhat role to Blizzard's unit tooltip "
            .. "when you hover a group member. Display only - nothing is "
            .. "scanned or sent.",
        function(value)
            WhoDoesWhat.db.profile.settings.unitTooltipRole = value
        end)
    f.announceRoleCheck, yL = AddCompactCheckboxRow(generalPage, CONTENT_X, yL, "Announce role changes in chat",
        "Post to raid/party chat when someone's role is changed. Turn off to keep role edits silent.",
        function(value)
            WhoDoesWhat.db.profile.settings.announceRoleChanges = value
            WhoDoesWhat:LogUiBuilding("Announce role changes " .. (value and "enabled." or "disabled."))
        end)
    f.manageBlizzRolesCheck, yL = AddCompactCheckboxRow(generalPage, CONTENT_X, yL,
        "Set Blizzard group roles",
        "Keep each player's Blizzard group role (Tank / Healer / Damage Dealer) "
            .. "and main-tank state matching their WhoDoesWhat role.\n\n"
            .. "Turn off if group roles start flipping back and forth -- usually "
            .. "another role addon, or a raider on an out-of-date WhoDoesWhat. "
            .. "WhoDoesWhat's own assignments keep working either way; only "
            .. "Blizzard's role flags are left alone.\n\n"
            .. "This setting is yours alone and is not shared with the raid.",
        function(value)
            WhoDoesWhat.db.profile.settings.manageBlizzardRoles = value
            WhoDoesWhat:LogUiBuilding("Blizzard group roles "
                .. (value and "managed." or "left alone."))
            -- Turning it back on should catch the group up rather than wait for
            -- the next role change or roster event.
            if value then WhoDoesWhat:ReconcileBlizzardRoles() end
        end)

    -- ---- Status Bars ----
    local statusPage = pages[2]
    yL = y0
    yL = AddHeading(statusPage, CONTENT_X, yL, "Status Bars", 0.96, 0.55, 0.73)
    f.overviewCheck, yL = AddCompactCheckboxRow(statusPage, CONTENT_X, yL,
        "Enable WDW Status Bars UI",
        "Shows a persistent UI element with many bars to see your raid's status at a quick glance.",
        function(value)
            WhoDoesWhat.db.profile.settings.overviewEnabled = value
            WhoDoesWhat:UpdateStatusBarsViewVisibility()
        end)
    local anchorLabels = {
        TOPLEFT = "Top Left", TOPRIGHT = "Top Right",
        BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
    }
    local anchorLabel = statusPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    anchorLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 4))
    anchorLabel:SetText("Anchor point:")
    local anchorDD = CreateFrame("Frame", "WhoDoesWhatStatusBarsAnchorDD", statusPage,
        "UIDropDownMenuTemplate")
    anchorDD:SetPoint("LEFT", anchorLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(anchorDD, 110)
    WhoDoesWhat:StyleDropdown(anchorDD, true)
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
    AddDropdownTooltip(anchorDD, anchorLabel, "Anchor point",
        "The window grows away from this corner as rows or width change.")
    f.overviewAnchorDD = anchorDD
    f.overviewAnchorLabels = anchorLabels
    yL = yL + 32

    local defaultDisplayLabel = statusPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    defaultDisplayLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 4))
    defaultDisplayLabel:SetText("Default text-mode:")
    local defaultDisplayDD = CreateFrame("Frame",
        "WhoDoesWhatStatusBarsDefaultDisplayDD", statusPage,
        "UIDropDownMenuTemplate")
    defaultDisplayDD:SetPoint("LEFT", defaultDisplayLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(defaultDisplayDD, 110)
    WhoDoesWhat:StyleDropdown(defaultDisplayDD, true)
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
    AddDropdownTooltip(defaultDisplayDD, defaultDisplayLabel, "Default text-mode",
        "Used by paladin bars and any Buff Tracking row set to Default.")
    f.overviewDefaultDisplayDD = defaultDisplayDD
    yL = yL + 32

    local tooltipAnchorLabel = statusPage:CreateFontString(nil, "OVERLAY",
        "GameFontHighlight")
    tooltipAnchorLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 4))
    tooltipAnchorLabel:SetText("Tooltip side:")
    local tooltipAnchorDD = CreateFrame("Frame",
        "WhoDoesWhatStatusBarsTooltipAnchorDD", statusPage,
        "UIDropDownMenuTemplate")
    tooltipAnchorDD:SetPoint("LEFT", tooltipAnchorLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(tooltipAnchorDD, 110)
    WhoDoesWhat:StyleDropdown(tooltipAnchorDD, true)
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
    AddDropdownTooltip(tooltipAnchorDD, tooltipAnchorLabel, "Tooltip side",
        "Where a status bar's tooltip opens. Left and right follow the hovered"
            .. " bar; above and below clear the whole window.")
    f.overviewTooltipAnchorDD = tooltipAnchorDD
    yL = yL + 32

    -- ---- Buff Tracking ----
    local statusBuffPage = pages[3]
    yL = y0
    local statusBuffHeading
    yL, statusBuffHeading = AddHeading(statusBuffPage, CONTENT_X, yL,
        "Buff Tracking", 0.96, 0.55, 0.73)
    AddTooltip(statusBuffHeading, "Buff Tracking",
        "Use arrows to order Bars; disabled rows move below the divider. Use the cog for display and target options.")
    local resetBuffs = CreateFrame("Button", nil, statusBuffPage, "UIPanelButtonTemplate")
    resetBuffs:SetSize(100, 22)
    resetBuffs:SetPoint("TOPRIGHT", statusBuffPage, "TOPRIGHT", -16, -(y0 - 2))
    resetBuffs:SetText("Reset Defaults")
    resetBuffs:SetScript("OnClick", function() ResetBuffTrackingPage(f) end)
    AddTooltip(resetBuffs, "Reset Buff Tracking",
        "Restore the default order, visibility, colors, and per-row options.")
    yL = yL + 6

    local headers = {
        { "Buff", 84, 155 }, { "Bars", 250, 44 },
        { "Buff Grid", 298, 62 }, { "Options", 364, 46 },
    }
    for _, header in ipairs(headers) do
        local text = statusBuffPage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("TOPLEFT", CONTENT_X + header[2], -yL)
        text:SetSize(header[3], 26)
        text:SetJustifyH(header[1] == "Buff" and "LEFT" or "CENTER")
        text:SetText(header[1])
        local tips = {
            Buff = "The tracked buff, debuff, death, or assignment status.",
            Bars = "Show and order this row in WDW Status.",
            ["Buff Grid"] = "Show this check as a Buffing Grid column.",
            Options = "Open the settings specific to this row.",
        }
        AddTooltip(text, header[1], tips[header[1]])
    end
    yL = yL + 28
    f.statusBuffListTop = yL
    local divider = CreateFrame("Frame", nil, statusBuffPage)
    divider:SetSize(CONTENT_W, STATUS_BUFF_ROW_H)
    local dividerLabel = divider:CreateFontString(nil, "BACKGROUND", "GameFontNormalSmall")
    dividerLabel:SetPoint("TOP")
    dividerLabel:SetPoint("BOTTOM")
    dividerLabel:SetText("Hidden from Status Bars")
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
    AddTooltip(divider, "Hidden from Status Bars",
        "Move a row above this divider to show it in WDW Status again.")
    f.statusBuffDivider = divider
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

        row.up = CreateStatusArrow(row, "Up")
        row.up:SetPoint("LEFT", 0, 0)
        row.up:SetScript("OnClick", function() MoveStatusBuff(f, rowKey, -1) end)
        AddTooltip(row.up, "Move up", "Move this row earlier in WDW Status.")
        row.down = CreateStatusArrow(row, "Down")
        row.down:SetPoint("LEFT", row.up, "RIGHT", 2, 0)
        row.down:SetScript("OnClick", function() MoveStatusBuff(f, rowKey, 1) end)
        AddTooltip(row.down, "Move down",
            "Move this row later, or disable it when it is last.")

        local index = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        index:SetPoint("LEFT", row.down, "RIGHT", 5, 0)
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
            icon:SetTexture(definition.icon)
            icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        end
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", icon, "RIGHT", 7, 0)
        name:SetWidth(148)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)
        name:SetText(definition.name)
        AddTooltip(row, definition.name, definition.description)

        row.bar = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.bar:SetSize(24, 24)
        row.bar:SetPoint("CENTER", row, "LEFT", 272, 0)
        row.bar:SetScript("OnClick", function(self)
            SetStatusBuffBarEnabled(f, rowKey,
                self:GetChecked() and true or false)
        end)
        AddTooltip(row.bar, "Show in Bars",
            "Show this row in WDW Status. Turning it off moves it below the divider.")
        row.grid = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.grid:SetSize(24, 24)
        row.grid:SetPoint("CENTER", row, "LEFT", 329, 0)
        row.grid:SetScript("OnClick", function(self)
            SetStatusBuffOption(f, rowKey, "grid", self:GetChecked() and true or false)
        end)
        AddTooltip(row.grid, "Show in Buff Grid",
            "Show this check as a column in the Buffing Grid.")
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
        options:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(definition.name .. " options", 1, 1, 1)
            GameTooltip:AddLine("Open this row's settings.",
                0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        options:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.options = options
    end
    RefreshStatusBuffRows(f)

    -- ---- Paladin ----
    local paladinPage = pages[4]
    yL = y0
    yL = AddHeading(paladinPage, CONTENT_X, yL, "Paladin Buffing Bar", 0.96, 0.55, 0.73)

    f.buffingBarCheck, yL = AddCompactCheckboxRow(paladinPage, CONTENT_X, yL, "Enable Paladin Buffing Bar",
        "Show a movable, clickable bar of your assigned blessings - a Nova-style alternative to PallyPower. Appears only when you're a paladin, unless test mode is on.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarEnabled = value
            WhoDoesWhat:LogUiBuilding("Paladin Buffing Bar " .. (value and "enabled." or "disabled."))
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end)

    f.buffingAuraCheck, yL = AddCompactCheckboxRow(paladinPage, CONTENT_X, yL,
        "Paladin Aura Helper",
        "Add an aura swapper at the left end of the bar. Right-click offers the next aura you know, left-click casts it; it turns grey with a red glow while that aura isn't the one you're running.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarAuraButton = value
            WhoDoesWhat:LogUiBuilding("Paladin Aura Helper "
                .. (value and "enabled." or "disabled."))
            WhoDoesWhat:RefreshPaladinBuffingBar()
        end)

    f.buffingRighteousFuryCheck, yL = AddCompactCheckboxRow(paladinPage, CONTENT_X, yL,
        "Righteous Fury Reminder",
        "Add a Righteous Fury button next to the aura swapper, shown only while you hold a tank role. Left-click refreshes it; red glow when it's down, yellow with a countdown in its last ten minutes.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarRighteousFury = value
            WhoDoesWhat:LogUiBuilding("Righteous Fury Reminder "
                .. (value and "enabled." or "disabled."))
            WhoDoesWhat:RefreshPaladinBuffingBar()
        end)

    local growLabel = paladinPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    growLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 4))
    growLabel:SetText("Bar grows:")
    local growLabels = { RIGHT = "Right", LEFT = "Left", CENTER = "From Center" }
    f.buffingGrowLabels = growLabels
    local growDD = CreateFrame("Frame", "WhoDoesWhatBuffingGrowDD", paladinPage, "UIDropDownMenuTemplate")
    growDD:SetPoint("LEFT", growLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(growDD, 90)
    WhoDoesWhat:StyleDropdown(growDD, true)
    UIDropDownMenu_Initialize(growDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.buffingBarGrow or "RIGHT"
        for _, mode in ipairs({ "RIGHT", "LEFT", "CENTER" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = growLabels[mode]
            info.checked = (saved == mode)
            info.func = function()
                WhoDoesWhat:SetBuffingBarGrow(mode)
                UIDropDownMenu_SetText(growDD, growLabels[mode])
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.buffingGrowDD = growDD

    local menuGrowLabel = paladinPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    menuGrowLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 34))
    menuGrowLabel:SetText("Player menu grows:")
    local menuGrowLabels = { DOWN = "Down", UP = "Up" }
    local menuGrowDD = CreateFrame("Frame", "WhoDoesWhatBuffingMenuGrowDD", paladinPage,
        "UIDropDownMenuTemplate")
    menuGrowDD:SetPoint("LEFT", menuGrowLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(menuGrowDD, 80)
    WhoDoesWhat:StyleDropdown(menuGrowDD, true)
    UIDropDownMenu_Initialize(menuGrowDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.buffingMenuGrow or "DOWN"
        for _, mode in ipairs({ "DOWN", "UP" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = menuGrowLabels[mode]
            info.checked = (saved == mode)
            info.func = function()
                WhoDoesWhat:SetBuffingMenuGrow(mode)
                UIDropDownMenu_SetText(menuGrowDD, menuGrowLabels[mode])
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.buffingMenuGrowDD = menuGrowDD

    f.buffingMenuExpiringCheck, yL = AddCompactCheckboxRow(paladinPage, CONTENT_X, yL + 68,
        "Warn below five minutes",
        "Color player rows yellow when their active blessing has less than five minutes remaining.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingMenuWarnExpiring = value
            WhoDoesWhat:RefreshPaladinBuffingBar()
        end)

    -- ---- Warlock ----
    local warlockPage = pages[5]
    yL = y0
    yL = AddHeading(warlockPage, CONTENT_X, yL, "Warlock Curses", 0.72, 0.45, 1)
    local magicCurseLabel = IS_CLASSIC_ERA and "Auto assign elements and shadow"
        or "Auto assign Affliction to elements"
    local magicCurseDescription = IS_CLASSIC_ERA
        and "Let the Auto button fill Curse of the Elements and Curse of Shadow on separate warlocks."
        or "Auto-place Curse of the Elements on an Affliction warlock - on spec detection and via the Auto button."
    f.afflElementsCheck, yL = AddCompactCheckboxRow(warlockPage, CONTENT_X, yL, magicCurseLabel,
        magicCurseDescription,
        function(value)
            WhoDoesWhat.db.profile.settings.autoAssignAfflictionElements = value
            local settingName = IS_CLASSIC_ERA and "Magic curse auto-assign"
                or "Auto-assign Affliction to Elements"
            WhoDoesWhat:LogUiBuilding(settingName .. " "
                .. (value and "enabled." or "disabled."))
        end)
    f.recklessnessCheck, yL = AddCompactCheckboxRow(warlockPage, CONTENT_X, yL, "Allow recklessness auto-assign",
        "Let auto-assign fill Curse of Recklessness. It raises the boss's damage, so it can be risky.",
        function(value)
            WhoDoesWhat.db.profile.settings.allowRecklessnessAutoAssign = value
            WhoDoesWhat:LogUiBuilding("Recklessness auto-assign " .. (value and "enabled." or "disabled."))
        end)

    -- ---- Developer ----
    local developerPage = pages[7]
    local yR = y0
    yR = AddHeading(developerPage, CONTENT_X, yR, "Developer Options")
    f.devModeCheck, yR = AddCompactCheckboxRow(developerPage, CONTENT_X, yR, "Developer Mode",
        "Assignment dropdowns list every group member, not just the eligible class.",
        function(value)
            WhoDoesWhat.db.profile.settings.developerMode = value
            WhoDoesWhat:LogUiBuilding("Developer Mode " .. (value and "enabled." or "disabled."))
        end)
    f.showLogsCheck, yR = AddCompactCheckboxRow(developerPage, CONTENT_X, yR, "Show Logs button",
        "Show the combined WhoDoesWhat and PallyPower traffic-log button on the assignment window.",
        function(value)
            WhoDoesWhat.db.profile.settings.showLogsButton = value
            WhoDoesWhat:RefreshMainAssignmentsView()
        end)
    f.logUiCheck, yR = AddCompactCheckboxRow(developerPage, CONTENT_X, yR, "Log UI Updates",
        "Print verbose UI build and layout logging to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logUiUpdates = value
            WhoDoesWhat.LOG_UI_BUILDING = value
            WhoDoesWhat:LogUiBuilding("Log UI Updates " .. (value and "enabled." or "disabled."))
        end)
    f.logOperationsCheck, yR = AddCompactCheckboxRow(developerPage, CONTENT_X, yR, "Log Operations",
        "Print routine assignment, reset, auto-assign, role, and whisper confirmations to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logOperations = value
            WhoDoesWhat.LOG_OPERATIONS = value
            WhoDoesWhat:LogUiBuilding("Log Operations " .. (value and "enabled." or "disabled."))
        end)
    f.logSyncStatusCheck, yR = AddCompactCheckboxRow(developerPage, CONTENT_X, yR, "Log sync status",
        "Print automatic board updates, role syncs, and group-clear notices to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logSyncStatus = value
            WhoDoesWhat:LogUiBuilding("Log sync status " .. (value and "enabled." or "disabled."))
        end)
    f.logSyncTrafficCheck, yR = AddCompactCheckboxRow(developerPage, CONTENT_X, yR, "Log sync details",
        "Capture WDW/PallyPower traffic and print WDW sync diagnostics to chat. Session-only; resets off on reload.",
        function(value)
            WhoDoesWhat:SetSyncLoggingEnabled(value)
            WhoDoesWhat:LogUiBuilding("Log sync details " .. (value and "enabled." or "disabled."))
        end)
    f.logBuffingClicksCheck, yR = AddCompactCheckboxRow(developerPage, CONTENT_X, yR, "Log buffing bar clicks",
        "Print each recognized left/right buffing-bar click and its castable target count.",
        function(value)
            WhoDoesWhat.db.profile.settings.logBuffingBarClicks = value
            WhoDoesWhat:LogUiBuilding("Log buffing bar clicks "
                .. (value and "enabled." or "disabled."))
        end)
    f.logRolePromotionCheck, yR = AddCompactCheckboxRow(developerPage, CONTENT_X, yR, "Log role/promotion flow",
        "Trace role picks, Blizzard role writes, promotion gating, Raid-tab opening, and row highlighting.",
        function(value)
            WhoDoesWhat.db.profile.settings.logRolePromotion = value
            WhoDoesWhat:LogUiBuilding("Log role/promotion flow "
                .. (value and "enabled." or "disabled."))
        end)
--@do-not-package@
    f.newerVersionTestCheck, yR = AddCompactCheckboxRow(developerPage, CONTENT_X, yR,
        "|cffff2020Simulate newer addon version|r",
        "|cffff2020WARNING: This feature should never be turned on. It falsely reports the next addon version to your group.|r",
        function(value)
            WhoDoesWhat.db.profile.settings.simulateNewerAddonVersion = value
            WhoDoesWhat:RefreshMainAssignmentsView()
            WhoDoesWhat:LogUiBuilding("Addon version simulation "
                .. (value and "enabled." or "disabled."))
        end)
--@end-do-not-package@

    -- ---- Testing ----
    local testingPage = pages[6]
    yR = y0
    yR = AddHeading(testingPage, CONTENT_X, yR, "Testing")
    f.fakeRaidCheck, yR = AddCompactCheckboxRow(testingPage, CONTENT_X, yR, "Populate Fake Raid",
        "Fill the roster with 23 fake raiders to develop buff strategies solo. Wipes the assignment board on toggle.",
        function(value)
            WhoDoesWhat:SetFakeRaidEnabled(value)
            RefreshBuffingTestPaladinDropdown(f)
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end)

    local palLabel = testingPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    palLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yR + 6))
    palLabel:SetText("Fake paladins:")
    local palDD = CreateFrame("Frame", "WhoDoesWhatFakePaladinCountDD", testingPage, "UIDropDownMenuTemplate")
    palDD:SetPoint("LEFT", palLabel, "RIGHT", -8, -2)
    UIDropDownMenu_SetWidth(palDD, 40)
    WhoDoesWhat:StyleDropdown(palDD, true)
    UIDropDownMenu_Initialize(palDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.fakeRaidPaladinCount or 3
        for n = 1, 4 do
            local info = UIDropDownMenu_CreateInfo()
            info.text = tostring(n)
            info.checked = (saved == n)
            info.func = function()
                WhoDoesWhat:SetFakeRaidPaladinCount(n)
                UIDropDownMenu_SetText(palDD, tostring(n))
                RefreshBuffingTestPaladinDropdown(f)
                WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.fakePaladinDD = palDD
    yR = yR + 40

    f.buffingTestCheck, yR = AddCompactCheckboxRow(testingPage, CONTENT_X, yR, "Show buffing bar as non-paladin",
        "Render the Paladin Buffing Bar even when you're not a paladin, as the paladin picked below (real or fake). Preview only.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarTestMode = value
            WhoDoesWhat:LogUiBuilding("Buffing bar test mode " .. (value and "enabled." or "disabled."))
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end)

    local testLabel = testingPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    testLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yR + 6))
    testLabel:SetText("Test as paladin:")
    local testDD = CreateFrame("Frame", "WhoDoesWhatBuffingTestPaladinDD", testingPage, "UIDropDownMenuTemplate")
    testDD:SetPoint("LEFT", testLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(testDD, 120)
    WhoDoesWhat:StyleDropdown(testDD, true)
    UIDropDownMenu_Initialize(testDD, function(_, level)
        RefreshBuffingTestPaladinDropdown(f)
        local saved = WhoDoesWhat.db.profile.settings.buffingBarTestPaladin
        local defaultInfo = UIDropDownMenu_CreateInfo()
        defaultInfo.text = FIRST_PALADIN_LABEL
        defaultInfo.checked = (saved == nil)
        defaultInfo.func = function()
            WhoDoesWhat.db.profile.settings.buffingBarTestPaladin = nil
            UIDropDownMenu_SetText(testDD, FIRST_PALADIN_LABEL)
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end
        UIDropDownMenu_AddButton(defaultInfo, level)
        for _, pname in ipairs(WhoDoesWhat:GetBuffingBarPaladins()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = pname
            info.checked = (saved == pname)
            info.func = function()
                WhoDoesWhat.db.profile.settings.buffingBarTestPaladin = pname
                UIDropDownMenu_SetText(testDD, pname)
                WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.buffingTestDD = testDD

    SelectSection(1)
    f:HookScript("OnHide", CloseBuffOptions)
    settingsFrame = f
    return f
end

-- Toggle the settings window open/closed, loading checkbox state from the DB.
-- An optional section label opens straight to that page instead of toggling.
function WhoDoesWhat:OpenAddonSettingsView(section)
    local f = EnsureSettingsFrame()

    if f:IsShown() then
        if section then
            f.SelectSection(section)
            f:Raise()
            return
        end
        self:LogUiBuilding("Addon Settings View open, closing it.")
        f:Hide()
        return
    end

    local settings = self.db.profile.settings
    f.minimapCheck:SetChecked(not settings.minimapButton.hide)
    f.buffingBarCheck:SetChecked(settings.buffingBarEnabled)
    UIDropDownMenu_SetText(f.buffingGrowDD,
        f.buffingGrowLabels[settings.buffingBarGrow or "RIGHT"]
            or f.buffingGrowLabels.RIGHT)
    UIDropDownMenu_SetText(f.buffingMenuGrowDD,
        settings.buffingMenuGrow == "UP" and "Up" or "Down")
    f.buffingMenuExpiringCheck:SetChecked(settings.buffingMenuWarnExpiring)
    f.buffingAuraCheck:SetChecked(settings.buffingBarAuraButton ~= false)
    f.buffingRighteousFuryCheck:SetChecked(settings.buffingBarRighteousFury ~= false)
    f.buffingTestCheck:SetChecked(settings.buffingBarTestMode)
    RefreshBuffingTestPaladinDropdown(f)
    f.unitTooltipCheck:SetChecked(settings.unitTooltipRole ~= false)
    f.announceRoleCheck:SetChecked(settings.announceRoleChanges)
    f.manageBlizzRolesCheck:SetChecked(settings.manageBlizzardRoles ~= false)
    f.overviewCheck:SetChecked(settings.overviewEnabled)
    local overviewAnchor = settings.overviewAnchor or "TOPLEFT"
    UIDropDownMenu_SetText(f.overviewAnchorDD,
        f.overviewAnchorLabels[overviewAnchor] or f.overviewAnchorLabels.TOPLEFT)
    local overviewDisplay = settings.overviewDefaultDisplay or "percent"
    UIDropDownMenu_SetText(f.overviewDefaultDisplayDD,
        STATUS_DISPLAY_LABELS[overviewDisplay] or STATUS_DISPLAY_LABELS.percent)
    local tooltipAnchor = settings.statusBarTooltipAnchor or "LEFT"
    UIDropDownMenu_SetText(f.overviewTooltipAnchorDD,
        STATUS_TOOLTIP_ANCHOR_LABELS[tooltipAnchor]
            or STATUS_TOOLTIP_ANCHOR_LABELS.LEFT)
    RefreshStatusBuffRows(f)
    f.devModeCheck:SetChecked(settings.developerMode)
    f.showLogsCheck:SetChecked(settings.showLogsButton)
    f.logUiCheck:SetChecked(settings.logUiUpdates)
    f.logOperationsCheck:SetChecked(settings.logOperations)
    f.logSyncStatusCheck:SetChecked(settings.logSyncStatus)
    f.logSyncTrafficCheck:SetChecked(self.LOG_SYNC)
    f.logBuffingClicksCheck:SetChecked(settings.logBuffingBarClicks)
    f.logRolePromotionCheck:SetChecked(settings.logRolePromotion)
    f.afflElementsCheck:SetChecked(settings.autoAssignAfflictionElements)
    f.recklessnessCheck:SetChecked(settings.allowRecklessnessAutoAssign)
--@do-not-package@
    f.newerVersionTestCheck:SetChecked(settings.simulateNewerAddonVersion)
--@end-do-not-package@
    f.fakeRaidCheck:SetChecked(settings.populateFakeRaid)
    UIDropDownMenu_SetText(f.fakePaladinDD, tostring(settings.fakeRaidPaladinCount or 3))

    if section then f.SelectSection(section) end

    self:LogUiBuilding("Opening Addon Settings View...")
    f:Show()
    f:Raise()
end

-- Open one check's cog options directly (WDW Status' shift-right-click on a
-- bar). Selecting the page closes any open options popup, so the popup opens
-- after the window is on the right page.
function WhoDoesWhat:OpenBuffTrackingOptions(key)
    if not self.StatusBarChecks[key] then return end
    local f = EnsureSettingsFrame()
    if f:IsShown() then
        f.SelectSection("Buff Tracking")
        f:Raise()
    else
        self:OpenAddonSettingsView("Buff Tracking")
    end
    OpenBuffOptions(f, key)
end

function WhoDoesWhat:RefreshAddonSettingsLoggingCheck()
    if settingsFrame and settingsFrame.logSyncTrafficCheck then
        settingsFrame.logSyncTrafficCheck:SetChecked(self.LOG_SYNC)
    end
end
