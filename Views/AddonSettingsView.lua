local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local K = WhoDoesWhat.SectionKit

-- Addon settings (the main window's Settings tab). Checkbox state persists in db.profile.settings except
-- detailed sync logging, which is deliberately session-only and resets off.

local settingsFrame = nil
local buffOptionsFrame = nil

local NAV_X = 14
local NAV_W = 104
-- Each section scrolls on its own from here rightwards, so the navigation
-- column beside it stays put. Everything a section lays out is measured from
-- the left of its own scroll area, which is why CONTENT_X is so small.
local PAGE_X = 126
local CONTENT_X = 8
local CONTENT_W = 410
local FRAME_W = 560
local BUFF_OPTIONS_W = 242
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
-- How many names a status-bar tooltip lists before the rest become a count.
-- 40 is a full raid, so it is the "everyone" end without needing a sentinel.
local STATUS_TOOLTIP_NAME_COUNTS = { 3, 5, 10, 20, 40 }
local DEFAULT_TOOLTIP_NAMES = 10
local OPTIONS_BUTTON = "Interface\\AddOns\\WhoDoesWhat\\Media\\UI-Panel-OptionsButton-"
local STATUS_BUFF_ROW_H = 26

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
        row.up:SetArrowEnabled(index > 1 or disabled)
        row.down:SetArrowEnabled(index <= enabledCount)
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
    WhoDoesWhat:RefreshBoardViews()
    WhoDoesWhat:RefreshStatusBarsView()
end

-- The label lives on the page rather than on the box: the pages fade a
-- checkbox and its label separately, and a label parented to the box would
-- take both fades. The hit rect runs the width of the column, so the label and
-- the air after it toggle the box too.
local function AddCompactCheckboxRow(f, x, y, labelText, tooltip, apply)
    local check = UI.CreateCheckbox(f, labelText, labelText, tooltip,
        function(self) apply(self:GetChecked() and true or false) end,
        { size = 24, font = "GameFontHighlight", gap = 2, labelParent = f })
    check:SetPoint("TOPLEFT", x, -y)
    check:SetHitRectInsets(0, -(CONTENT_W - 30 - (x - CONTENT_X)), 0, 0)
    return check, y + 28, check.label
end

local MINIMAP_NAME = "WhoDoesWhat"
-- The TGA, not the PNG beside it: the client loads BLP and TGA and nothing
-- else, so the artwork the README shows is not something the game can draw.
-- 64px for a button rendered at about 17, which leaves it sharp without
-- shipping the full-size source in the package (see .pkgmeta).
local MINIMAP_ICON = WhoDoesWhat.ADDON_ICON
local minimapIcon
local minimapLoader = CreateFrame("Frame")

local function MinimapClick(_, mouseButton)
    local shift = IsShiftKeyDown()
    if shift and mouseButton == "RightButton" then
        WhoDoesWhat:OpenAddonSettingsView()
    elseif shift then
        WhoDoesWhat:OpenMembersView()
    elseif mouseButton == "RightButton" then
        WhoDoesWhat:OpenBuffingGridView()
    else
        WhoDoesWhat:ToggleMainUI()
    end
end

local function MinimapTooltip(tooltip)
    tooltip:AddLine("WhoDoesWhat", 1, 1, 1)
    UI.AddTooltipHint(tooltip, "Left-Click:", "Assignments")
    UI.AddTooltipHint(tooltip, "Right-Click:", "Buffing Grid")
    UI.AddTooltipHint(tooltip, "Shift-Left-Click:", "Members")
    UI.AddTooltipHint(tooltip, "Shift-Right-Click:", "Settings")
end

-- LibDBIcon, and nothing of our own on top of it. That is the whole point.
--
-- Every addon that manages minimap buttons -- Leatrix Plus's "hide addon
-- buttons", MinimapButtonButton's bag, SexyMap, Chinchilla -- finds buttons by
-- walking LibDBIcon's own registry. Registering is what makes the user's
-- minimap addon responsible for showing, hiding and fading this button, which
-- is where that belongs: if it fades, it is because they asked something to
-- fade it, and if it does not, they did not.
--
-- This used to call ShowOnEnter on itself, so the button faded out whenever
-- the mouse left the minimap whether or not anybody had asked for that -- our
-- own half of a job the user's minimap addon was already doing, and not
-- reachable from any setting of ours. Gone; the library's default is to sit
-- there and be visible.
--
-- The libraries are bundled now rather than borrowed. They were declared
-- OptionalDeps and looked up hopefully, which meant the button existed only
-- when some OTHER addon happened to embed LibDBIcon -- and silently printed a
-- "libraries are not loaded" line at anyone whose addon set did not.
function WhoDoesWhat:InitializeMinimapButton()
    if minimapIcon then return end
    local broker = LibStub("LibDataBroker-1.1", true)
    local icon = LibStub("LibDBIcon-1.0", true)
    -- Shipped in Libs, so this should not fail -- but an older copy of either
    -- can win LibStub if another addon loaded first, and a nil here should be
    -- a missing button rather than an error thrown at somebody mid-pull.
    if not broker or not icon then return end
    local launcher = broker:NewDataObject(MINIMAP_NAME, {
        type = "launcher",
        text = MINIMAP_NAME,
        icon = MINIMAP_ICON,
        OnClick = MinimapClick,
        OnTooltipShow = MinimapTooltip,
    })
    icon:Register(MINIMAP_NAME, launcher,
        self.db.profile.settings.minimapButton)
    minimapIcon = icon

    -- Round the artwork off so a square icon sits inside the ring instead of
    -- poking out of its four corners. Guarded: CreateMaskTexture is not on
    -- every client this loads on, and without it the icon is a square, which
    -- is what every minimap button looked like for fifteen years.
    local button = icon:GetMinimapButton(MINIMAP_NAME)
    if button and button.CreateMaskTexture then
        local mask = button:CreateMaskTexture(nil, "ARTWORK")
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(button.icon)
        button.icon:AddMaskTexture(mask)
    end

    self:UpdateMinimapButtonVisibility()
end

-- PLAYER_LOGIN rather than straight away, even though the libraries are ours
-- now: it is when Leatrix Plus and friends do their own setup, and registering
-- here is what lets their LibDBIcon_IconCreated callback see us -- that
-- callback is how a late button inherits the user's setting.
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

-- The raid-frame master switch owns the style and combat rows under it: with
-- it off we touch Blizzard's frames at all, so neither has anything to say.
local function RefreshRaidFrameOptionStates(f)
    local on = WhoDoesWhat.db.profile.settings.raidFrameRoleIcons ~= false
    SetOptionAvailable(f.raidFrameCombatCheck, f.raidFrameCombatLabel, on)
    local shade = on and 1 or 0.45
    f.raidStyleLabel:SetTextColor(shade, shade, shade)
    if on then
        UIDropDownMenu_EnableDropDown(f.raidStyleDD)
    else
        UIDropDownMenu_DisableDropDown(f.raidStyleDD)
    end
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
    UIDropDownMenu_SetText(f.scopeDD,
        STATUS_SCOPE_LABELS[options.scope] or STATUS_SCOPE_LABELS.always)

    local function PlaceDropdown(label, dd, y)
        label:ClearAllPoints()
        label:SetPoint("TOPLEFT", 10, -(y + 1))
        dd:ClearAllPoints()
        dd:SetPoint("LEFT", label, "RIGHT", -7, -4)
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
        PlaceDropdown(f.scopeLabel, f.scopeDD, 36)
        -- Sized to the stack rather than a constant: the two custom checks no
        -- longer have the same number of rows.
        f:SetHeight(74 + #activeRows * 22)
        for index, row in ipairs(activeRows) do
            row[1]:ClearAllPoints()
            row[1]:SetPoint("TOPLEFT", 7, -(66 + (index - 1) * 22))
            row[1]:SetChecked(row[3])
            SetOptionAvailable(row[1], row[2], true)
        end
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
    local function PlaceOption(option, shown, y, indent)
        local check, label = f.optionChecks[option], f.optionLabels[option]
        check:SetShown(shown)
        label:SetShown(shown)
        if shown then
            check:ClearAllPoints()
            check:SetPoint("TOPLEFT", 7 + (indent or 0), -y)
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
    -- A self-supplied check answers the question a different way -- it is
    -- always your own job -- so it offers the option without a class set.
    local showResponsibleGlow = (hasRequirement or definition.selfSupplied)
        and not options.negative and not hidden.responsibleGlow
    -- Only where the check asks for it: "most of them have it" is a sensible
    -- thing to glow about for a raid-wide cast, and nonsense for a buff that
    -- is applied one raider at a time.
    local showPartialGlow = definition.partialGlow == true
    -- Applies to any positive check, talent ranks or not: what matters is who
    -- cast it, not how well.
    local showFlagOutside = not options.negative
        and not hidden.flagOutsideRaid
    y = y + ((showBest or showHideBarUnavailable or showHideColumnUnavailable
        or showResponsibleGlow or showPartialGlow or showFlagOutside)
        and 18 or 25)
    y = PlaceOption("bestAvailable", showBest, y)
    -- A sub-option of the box above it: indented, and gone entirely while the
    -- rule it relaxes is switched off.
    y = PlaceOption("anyInCombat", showBest and options.bestAvailable, y, 14)
    y = PlaceOption("flagOutsideRaid", showFlagOutside, y)
    y = PlaceOption("responsibleGlow", showResponsibleGlow, y)
    -- Sub-option of the box above it, and only on a check whose class does not
    -- all get the spell (Divine Spirit): everywhere else there is no offspec
    -- question to answer.
    y = PlaceOption("offspecResponsible",
        showResponsibleGlow and options.responsibleGlow
            and definition.requiredTalent ~= nil, y, 14)
    -- The class this one names is the "Requires Class" one, so it says which.
    f.optionLabels.partialGlowOnlyClass:SetText(options.requiredClass
        and ("Only as " .. options.requiredClass)
        or "Only as the supplying class")
    y = PlaceOption("partialGlow", showPartialGlow, y)
    y = PlaceOption("partialGlowOnlyClass",
        showPartialGlow and options.partialGlow and hasRequirement, y, 14)
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

    local showMana = not hidden.onlyManaUsers
    local showTanks = not hidden.onlyTanks
    local showPets = not hidden.hunterPets
    y = PlaceDivider(f.targetsDivider,
        showMana or showTanks or showPets, y + 1)
    y = PlaceOption("onlyManaUsers", showMana, y)
    y = PlaceOption("onlyTanks", showTanks, y)
    -- A check that counts every class's pet says so; the rest are hunters-only.
    f.optionLabels.hunterPets:SetText(definition.allPets
        and "Used by pets" or "Used by hunter pets")
    y = PlaceOption("hunterPets", showPets, y)
    for _, option in ipairs({ "bestAvailable", "anyInCombat", "flagOutsideRaid",
        "hideBarUnavailable",
        "hideColumnUnavailable", "combinePaladinBars",
        "negative", "hideComplete", "responsibleGlow", "offspecResponsible",
        "partialGlow", "partialGlowOnlyClass",
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

-- ---------------------------------------------------------------------------
-- Option widgets three pages share
-- ---------------------------------------------------------------------------

-- The WoW picker, opened over one profile setting. `Get` hands back the saved
-- {r,g,b} (or nil, meaning the profile default), `Set` writes one back or nil
-- to hand it to the default again, and `OnChange` runs after either -- the
-- picker calls it on every drag, so whatever it repaints has to be cheap.
local function OpenSettingColorPicker(parent, Get, Set, OnChange)
    UI.CancelColorPicker()
    local saved = Get()
    local original = saved and { r = saved.r, g = saved.g, b = saved.b } or nil
    UI.OpenColorPicker({
        color = saved, above = parent,
        OnChange = function(r, g, b)
            Set({ r = r, g = g, b = b })
            OnChange()
        end,
        OnCancel = function()
            Set(original)
            OnChange()
        end,
    })
end

-- The highlight-style dropdown, the box beside it showing that style running,
-- and one colour swatch per state the caller has. Three pages want exactly
-- these controls over three different sets of settings, so the settings are
-- what varies:
--   spec.name       a unique frame name for the dropdown
--   spec.styleLabel the dropdown's caption
--   spec.tooltip    what this bar's highlight is for, in one sentence
--   spec.GetStyle / spec.SetStyle
--   spec.colors     { { label, tooltip, Get, Set }, ... }, first one leading:
--                   it is the colour the preview box is drawn in
--   spec.OnChange   repaint whatever wears these
-- Returns the page refresher and the y the next widget starts at.
local function AddHighlightControls(parent, x, y, spec)
    -- A colour setting reads back through the profile defaults, so a reset
    -- hands the default straight back rather than leaving a hole. This is only
    -- reached if a profile has somehow lost the default too, and it keeps a
    -- missing colour from taking the settings window down with it.
    local function EntryColor(entry)
        return entry.Get() or { r = 1, g = 1, b = 1 }
    end

    local styleLabel = parent:CreateFontString(nil, "OVERLAY",
        "GameFontHighlight")
    styleLabel:SetPoint("TOPLEFT", x + 4, -(y + 4))
    styleLabel:SetText(spec.styleLabel or "Highlight style:")

    -- Wide enough for the longest of the wing styles ("Pulsing wings (right)").
    local dd = UI.CreateMenuDropdown(parent, spec.name, 135)
    dd:SetPoint("LEFT", styleLabel, "RIGHT", -6, -2)

    -- Built like a status row rather than as one flat frame: the sample's own
    -- art lives on a child frame, and the box sits a few levels above the page,
    -- so the styles that draw behind a row land behind this too. The clearance
    -- to its left is for the ones that draw outside the box -- the wings flank
    -- it the way they flank a real row.
    local preview = CreateFrame("Frame", nil, parent)
    preview:SetSize(56, 18)
    preview:SetPoint("LEFT", dd, "RIGHT", 28, 2)
    preview:SetFrameLevel(parent:GetFrameLevel() + 3)
    local previewBody = CreateFrame("Frame", nil, preview)
    previewBody:SetAllPoints()
    local previewBg = previewBody:CreateTexture(nil, "BACKGROUND")
    previewBg:SetAllPoints()
    previewBg:SetColorTexture(0.16, 0.16, 0.18, 1)
    local previewFill = previewBody:CreateTexture(nil, "ARTWORK")
    previewFill:SetPoint("TOPLEFT", 1, -1)
    previewFill:SetPoint("BOTTOMLEFT", 1, 1)
    previewFill:SetWidth(34)
    previewFill:SetColorTexture(0.96, 0.55, 0.73, 0.8)

    local function SavedStyle()
        local styles, _, default = WhoDoesWhat:GetStatusBarHighlightStyles()
        local saved = spec.GetStyle()
        if not styles[saved] then saved = default end
        return saved, styles
    end

    local function ApplyPreview(styleKey)
        -- Off and on again: the colour and the size are read at start, so a
        -- style that is already running has to be rebuilt to pick either up.
        local color = EntryColor(spec.colors[1])
        WhoDoesWhat:ApplyStatusBarHighlight(preview, false, styleKey, color)
        WhoDoesWhat:ApplyStatusBarHighlight(preview, true, styleKey, color)
    end

    UIDropDownMenu_Initialize(dd, function(_, level)
        local styles, order = WhoDoesWhat:GetStatusBarHighlightStyles()
        local saved = SavedStyle()
        for _, key in ipairs(order) do
            local styleKey = key
            local info = UIDropDownMenu_CreateInfo()
            info.text = styles[styleKey].label
            info.checked = saved == styleKey
            info.func = function()
                spec.SetStyle(styleKey)
                UIDropDownMenu_SetText(dd, styles[styleKey].label)
                ApplyPreview(styleKey)
                spec.OnChange()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(dd, styleLabel, "Highlight style", spec.tooltip)

    -- The swatches go under the dropdown so the sample box beside it shows a
    -- colour change as it is dragged.
    local swatches = {}
    local rowY = y + 32
    for _, entry in ipairs(spec.colors) do
        local label = parent:CreateFontString(nil, "OVERLAY",
            "GameFontHighlight")
        label:SetPoint("TOPLEFT", x + 4, -(rowY + 4))
        label:SetText(entry.label)
        local swatch = CreateFrame("Button", nil, parent)
        swatch:SetSize(22, 11)
        swatch:SetPoint("LEFT", label, "RIGHT", 6, 0)
        swatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        swatch.color = swatch:CreateTexture(nil, "ARTWORK")
        swatch.color:SetAllPoints()
        swatch.entry = entry
        swatches[#swatches + 1] = swatch
        UI.AddTooltip(label, entry.label, entry.tooltip)
        UI.AddTooltip(swatch, entry.label,
            "Left-click for the WoW color picker; right-click to reset.")
        rowY = rowY + 24
    end

    local function PaintSwatches()
        for _, swatch in ipairs(swatches) do
            local c = EntryColor(swatch.entry)
            swatch.color:SetColorTexture(c.r, c.g, c.b)
        end
        ApplyPreview(SavedStyle())
    end

    -- The picker's live preview: paint the swatch and the sample, then let
    -- whatever wears these colours pick the change up on the way past.
    local function RefreshColors()
        PaintSwatches()
        spec.OnChange()
    end

    for _, swatch in ipairs(swatches) do
        swatch:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                -- nil is not "no colour": the profile default takes over
                -- again, which is what a reset means here.
                self.entry.Set(nil)
                RefreshColors()
            else
                OpenSettingColorPicker(parent, self.entry.Get,
                    self.entry.Set, RefreshColors)
            end
        end)
    end

    -- Every control here, read back out of the settings: the window opening,
    -- a page's Defaults button, or a different profile loading.
    local function Refresh()
        local styles = WhoDoesWhat:GetStatusBarHighlightStyles()
        UIDropDownMenu_SetText(dd, styles[SavedStyle()].label)
        PaintSwatches()
    end

    return Refresh, rowY + 4
end

-- A whole number with two ways in: a slider to drag, and a box beside it to
-- type an exact value into. `spec` is { name, label, tooltip, min, max },
-- `Get` reads the saved number, `Set` writes one back, `OnChange` repaints.
local function AddSliderWithInput(parent, x, y, spec, Get, Set, OnChange)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", x + 4, -y)
    label:SetText(spec.label)

    local slider, edit, Refresh = UI.CreateSliderWithInput(parent, spec, Get, Set, OnChange)
    slider:SetPoint("TOPLEFT", x + 8, -(y + 22))

    UI.AddTooltip(label, spec.label, spec.tooltip)
    UI.AddTooltip(edit, spec.label, spec.tooltip)

    return Refresh, y + 52
end

local function OpenBarColorPicker(owner, f)
    UI.CancelColorPicker()
    local key = f.buffKey
    local options = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey)
    local definition = WhoDoesWhat.StatusBarChecks[f.buffKey]
    local color = options.barColor or DefaultStatusBarColor(definition)
    local original = options.barColor and {
        r = options.barColor.r,
        g = options.barColor.g,
        b = options.barColor.b,
    } or false
    UI.OpenColorPicker({
        color = color, above = f,
        OnChange = function(r, g, b)
            SetStatusBuffOption(owner, key, "barColor", { r = r, g = g, b = b })
            RefreshBuffOptionsFrame()
        end,
        OnCancel = function()
            SetStatusBuffOption(owner, key, "barColor", original)
            RefreshBuffOptionsFrame()
        end,
        -- WDW Status shows this row's colour live only while it is picked.
        OnClose = function()
            WhoDoesWhat.statusBarColorPreviewKey = nil
            WhoDoesWhat:RefreshStatusBarsView()
        end,
    })
    WhoDoesWhat.statusBarColorPreviewKey = key
    WhoDoesWhat:RefreshStatusBarsView()
end

local function EnsureBuffOptionsFrame(owner, key)
    if buffOptionsFrame then return buffOptionsFrame end
    local f = UI.CreateWindow("WhoDoesWhatBuffTrackingOptionsFrame",
        BUFF_OPTIONS_W, 230, nil, { bare = true, closeButton = true })
    -- UIDropDownMenu_Initialize runs its callback immediately, before this
    -- constructor returns, so the selected key must already be available.
    f.buffKey = key
    f:SetParent(owner)
    f:SetToplevel(false)
    f:SetFrameLevel(owner:GetFrameLevel() + 20)
    f:HookScript("OnHide", UI.CancelColorPicker)
    f:ClearAllPoints()
    -- Clear of the section's scrollbar, which hangs off the right of the page.
    f:SetPoint("LEFT", owner, "RIGHT", 8 + UI.SCROLLBAR_W, 0)

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
    local scopeDD = UI.CreateMenuDropdown(f, "WhoDoesWhatBuffTrackingScopeDD", 72)
    scopeDD:SetPoint("LEFT", scopeLabel, "RIGHT", -7, -2)
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
    UI.AddDropdownTooltip(scopeDD, scopeLabel, "Party type",
        "Limit this check to raids, parties, or all group types.")

    local displayLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    displayLabel:SetPoint("TOPLEFT", 190, -46)
    displayLabel:SetText("Text Mode")
    local displayDD = UI.CreateMenuDropdown(f, "WhoDoesWhatBuffTrackingDisplayDD", 98)
    displayDD:SetPoint("LEFT", displayLabel, "RIGHT", -7, -2)
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
    UI.AddDropdownTooltip(displayDD, displayLabel, "Text Mode",
        "Choose the text shown on the bar: percent, counts, or a fraction.")

    local classLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    classLabel:SetPoint("TOPLEFT", 10, -77)
    classLabel:SetText("Requires Class:")
    local classDD = UI.CreateMenuDropdown(f, "WhoDoesWhatBuffTrackingClassDD", 90)
    classDD:SetPoint("LEFT", classLabel, "RIGHT", -7, -2)
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
    UI.AddDropdownTooltip(classDD, classLabel, "Requires class",
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
    UI.AddTooltip(colorLabel, "Bar color",
        "Choose the filled status-bar color. Right-click the swatch to reset it.")
    UI.AddTooltip(colorSwatch, "Bar color",
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
        UI.CancelColorPicker()
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
    UI.AddTooltip(colorHex, "Hex color",
        "Enter a six-digit RGB color, with or without #, then press Enter.")
    f.colorHex = colorHex

    local saturatedLabel = f:CreateFontString(nil, "OVERLAY",
        "GameFontHighlightSmall")
    saturatedLabel:SetText("Fully Debuffed Style:")
    local saturatedDD = UI.CreateMenuDropdown(f, "WhoDoesWhatBuffTrackingSaturatedStyleDD", 72)
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
    UI.AddDropdownTooltip(saturatedDD, saturatedLabel,
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
        { "flagOutsideRaid", "Flag buffs from outside the raid",
            "Count a buff as missing when whoever cast it is not in the raid."
                .. " Pulling a boss strips those buffs, so a raider carrying"
                .. " one is unbuffed the moment it matters. Only applies in a"
                .. " raid -- party and dungeon groups are never stripped." },
        { "bestAvailable", "Only consider best available",
            "Untalented buffs will not be counted toward the total buffing progress while a better buff is available." },
        { "anyInCombat", "Consider all in combat and BGs",
            "While you are in combat, or anywhere in a battleground or arena,"
                .. " count any buff as covered. Mid-fight there is no time to"
                .. " chase a better rank." },
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
        { "responsibleGlow", "Glow when responsible",
            "Glow this WDW Status row while you are the class that supplies the"
                .. " buff and somebody is still missing it. With \"Only consider"
                .. " best available\" on, only the raid's best-talented caster"
                .. " is asked. On a buff nobody can cast for you, such as food,"
                .. " it glows while you or your pet are the ones going"
                .. " without." },
        { "offspecResponsible", "Allow offspec responsibility",
            "Keep glowing this row when the talent that grants the buff sits"
                .. " in your other talent group rather than the spec you are"
                .. " in. A respec is a real answer in a raid where nobody has"
                .. " it in the spec they are standing in; off, only your"
                .. " current spec puts you on the hook." },
        { "partialGlow", "Glow when some missing",
            "Glow this WDW Status row once most of the raid is covered but a"
                .. " few are not -- raiders who were dead when it went out, or"
                .. " a pet summoned since. That handful is worth one more"
                .. " cast; an empty raid-wide bar is not." },
        { "partialGlowOnlyClass", "Only as the supplying class",
            "Restrict that glow to the class named above, the one that can"
                .. " actually cast it. Off, everybody sees the stragglers." },
    }
    for index, entry in ipairs(checkboxOptions) do
        local option, labelText, tooltip = entry[1], entry[2], entry[3]
        local check = UI.CreateCheckbox(f, labelText, labelText, tooltip,
            function(self)
                SetStatusBuffOption(owner, f.buffKey, option,
                    self:GetChecked() and true or false)
                RefreshBuffOptionsFrame()
            end,
            { size = 22, font = "GameFontHighlightSmall", gap = 1, labelParent = f })
        check:SetPoint("TOPLEFT", 7, -(104 + (index - 1) * 21))
        check:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
        local label = check.label
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

    -- Action Items' trio, the same shape as PallyPower's above: two "when is
    -- this row worth a line" toggles and one glow. RefreshBuffOptionsFrame
    -- places them; the y values here are overwritten on the first open.
    f.aiHideClearCheck, _, f.aiHideClearLabel = AddCompactCheckboxRow(
        f, 7, 76, "Hide when nothing to fix",
        "Hide this row while there is nothing to fix on the roster.",
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "hideWhenClear", value)
            RefreshBuffOptionsFrame()
        end)
    f.aiHideClearCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
    f.aiHideSoloCheck, _, f.aiHideSoloLabel = AddCompactCheckboxRow(
        f, 7, 104, "Hide when not in a group",
        "Hide this row while you are solo, where there is nothing to check.",
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "hideWhenSolo", value)
            RefreshBuffOptionsFrame()
        end)
    f.aiHideSoloCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
    f.aiHideNotYoursCheck, _, f.aiHideNotYoursLabel = AddCompactCheckboxRow(
        f, 7, 132, "Hide when nothing is yours to fix",
        "Hide this row while every outstanding item belongs to someone else "
            .. "and you have no permission to set their roles. Turn this off "
            .. "to keep an informational count instead.",
        function(value)
            SetStatusBuffOption(owner, f.buffKey, "hideWhenNotYours", value)
            RefreshBuffOptionsFrame()
        end)
    f.aiHideNotYoursCheck:SetHitRectInsets(0, -(BUFF_OPTIONS_W - 40), 0, 0)
    f.aiGlowCheck, _, f.aiGlowLabel = AddCompactCheckboxRow(
        f, 7, 132, "Action items glow",
        "This bar will glow while items are waiting and you have permission to"
            .. " edit assignments.",
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
    f:Show()
    f:Raise()
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

local function CloseBuffOptions()
    UI.CancelColorPicker()
    if buffOptionsFrame then buffOptionsFrame:Hide() end
end

-- Build the settings window once and reuse it. Section buttons down the left
-- keep each page to one narrow column and work consistently across clients.
local LoadSettings -- defined after the page, which it reads the controls off

-- Build the page into the Settings tab: the navigation column, fixed, and one
-- scroll area per section beside it. Left-aligned so the buff options pop-up has
-- room to the right. A section's scrollbar only appears if its content outgrows
-- the tab.
function WhoDoesWhat:BuildAddonSettingsPage(tabPage)
    local f = CreateFrame("Frame", nil, tabPage)
    f:SetPoint("TOPLEFT", tabPage, "TOPLEFT")
    f:SetPoint("BOTTOMLEFT", tabPage, "BOTTOMLEFT")
    f:SetWidth(FRAME_W)
    f.titleBarHeight = 0
    local y0 = f.titleBarHeight + 20
    local pages, scrolls = {}, {}
    local buttons = {}
    local sectionLabels = {
        "General", "Status Bars", "Buff Tracking", "Paladin Bar",
        "Warriors", "Warlocks", "Testing", "Developer",
    }

    -- A section always opens at its top, and is re-measured each time it comes
    -- up: what it shows can have changed since it was last looked at.
    local function SelectSection(index)
        CloseBuffOptions()
        f.currentScroll = scrolls[index]
        for i, scroll in ipairs(scrolls) do
            scroll:SetShown(i == index)
            if i == index then buttons[i]:LockHighlight() else buttons[i]:UnlockHighlight() end
        end
        f.currentScroll:SetVerticalScroll(0)
        UI.FitScrollToContent(f.currentScroll)
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

        local scroll, page = UI.CreateScroll(f, "WhoDoesWhatSettingsSection" .. i, true)
        scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAGE_X, 0)
        scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT")
        page:SetWidth(FRAME_W - PAGE_X)
        scroll:Hide()
        pages[i], scrolls[i] = page, scroll
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
    f.unitTooltipDetailCheck, yL = AddCompactCheckboxRow(generalPage, CONTENT_X, yL,
        "Show class details in unit tooltips",
        "Also append the summary the roster views show on hover: a Paladin's "
            .. "blessing talents and addon status, or a Warlock's Improved "
            .. "Healthstone. Only Paladins and Warlocks add anything.",
        function(value)
            WhoDoesWhat.db.profile.settings.unitTooltipDetail = value
        end)
    f.raidFrameRoleCheck, yL = AddCompactCheckboxRow(generalPage, CONTENT_X, yL,
        "Show roles on raid frames",
        "Draw each raider's spec icon onto Blizzard's raid frames, over the "
            .. "group icon that normally sits there. Players whose spec has "
            .. "not been chosen or scanned yet keep the corner Blizzard drew."
            .. "\n\nOff leaves Blizzard's raid frames entirely alone, and "
            .. "greys out the two options below.",
        function(value)
            WhoDoesWhat.db.profile.settings.raidFrameRoleIcons = value
            WhoDoesWhat:LogUiBuilding("Raid frame role icons "
                .. (value and "enabled." or "disabled."))
            RefreshRaidFrameOptionStates(f)
            WhoDoesWhat:RefreshRaidFrameRoleIcons()
        end)

    local raidStyleLabel = generalPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    raidStyleLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 4))
    raidStyleLabel:SetText("Raid frame style:")
    local raidStyleLabels = {
        corner = "Replace WoW Icon",
        band = "Left band",
        bandFaded = "Left band, faded",
        bandRight = "Right band",
        bandRightFaded = "Right band, faded",
    }
    f.raidStyleLabels = raidStyleLabels
    local raidStyleDD = UI.CreateMenuDropdown(generalPage, "WhoDoesWhatRaidFrameStyleDD", 120)
    raidStyleDD:SetPoint("LEFT", raidStyleLabel, "RIGHT", -6, -2)
    UIDropDownMenu_Initialize(raidStyleDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.raidFrameRoleIconStyle
            or "corner"
        for _, mode in ipairs({ "corner", "band", "bandFaded",
            "bandRight", "bandRightFaded" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = raidStyleLabels[mode]
            info.checked = (saved == mode)
            info.func = function()
                WhoDoesWhat.db.profile.settings.raidFrameRoleIconStyle = mode
                UIDropDownMenu_SetText(raidStyleDD, raidStyleLabels[mode])
                WhoDoesWhat:LogUiBuilding("Raid frame role icon style: " .. mode)
                WhoDoesWhat:RefreshRaidFrameRoleIcons()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.raidStyleDD = raidStyleDD
    f.raidStyleLabel = raidStyleLabel
    yL = yL + 32

    f.raidFrameCombatCheck, yL, f.raidFrameCombatLabel = AddCompactCheckboxRow(
        generalPage, CONTENT_X, yL,
        "Keep raid frame roles in combat",
        "Leave those spec icons up while you are fighting. Turn off to hand "
            .. "that corner back to Blizzard for the length of a pull and take "
            .. "it again once the fight ends.",
        function(value)
            WhoDoesWhat.db.profile.settings.raidFrameRoleIconsInCombat = value
            WhoDoesWhat:LogUiBuilding("Raid frame role icons in combat "
                .. (value and "enabled." or "disabled."))
            WhoDoesWhat:RefreshRaidFrameRoleIcons()
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

    -- On the heading's line, hard right: it undoes this whole page at once, so
    -- it belongs beside the page's name rather than buried under the last
    -- option it happens to reset.
    local resetButton = CreateFrame("Button", nil, statusPage,
        "UIPanelButtonTemplate")
    resetButton:SetSize(80, 22)
    resetButton:SetPoint("TOPRIGHT", statusPage, "TOPRIGHT", -16, -(y0 - 2))
    resetButton:SetText("Defaults")
    resetButton:SetScript("OnClick", function()
        CloseBuffOptions()
        WhoDoesWhat:ResetStatusBarSettings()
        f.RefreshStatusPage()
    end)
    UI.AddTooltip(resetButton, "Reset Status Bars",
        "Put every option on this page back to its default and move the"
            .. " window to the middle of the screen. Per-check options on the"
            .. " Buff Tracking page are left alone.")
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
    local anchorDD = UI.CreateMenuDropdown(statusPage, "WhoDoesWhatStatusBarsAnchorDD", 110)
    anchorDD:SetPoint("LEFT", anchorLabel, "RIGHT", -6, -2)
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
    yL = yL + 32

    local defaultDisplayLabel = statusPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    defaultDisplayLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 4))
    defaultDisplayLabel:SetText("Default text-mode:")
    local defaultDisplayDD = UI.CreateMenuDropdown(statusPage, "WhoDoesWhatStatusBarsDefaultDisplayDD", 110)
    defaultDisplayDD:SetPoint("LEFT", defaultDisplayLabel, "RIGHT", -6, -2)
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
    yL = yL + 32

    local tooltipAnchorLabel = statusPage:CreateFontString(nil, "OVERLAY",
        "GameFontHighlight")
    tooltipAnchorLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 4))
    tooltipAnchorLabel:SetText("Tooltip side:")
    local tooltipAnchorDD = UI.CreateMenuDropdown(statusPage, "WhoDoesWhatStatusBarsTooltipAnchorDD", 110)
    tooltipAnchorDD:SetPoint("LEFT", tooltipAnchorLabel, "RIGHT", -6, -2)
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
    yL = yL + 32

    local tooltipNamesLabel = statusPage:CreateFontString(nil, "OVERLAY",
        "GameFontHighlight")
    tooltipNamesLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 4))
    tooltipNamesLabel:SetText("Tooltip names:")
    local tooltipNamesDD = UI.CreateMenuDropdown(statusPage, "WhoDoesWhatStatusBarsTooltipNamesDD", 110)
    tooltipNamesDD:SetPoint("LEFT", tooltipNamesLabel, "RIGHT", -6, -2)
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
    yL = yL + 32

    -- The highlight style, with a live sample of it beside the dropdown --
    -- these read as animation names on their own, and the box is the only
    -- honest way to say what each one looks like -- and one colour under it
    -- for whichever style is selected, rather than a colour baked into each.
    -- The same three controls the shout bar and the buffing bar carry.
    local statusSettings = WhoDoesWhat.db.profile.settings
    local RefreshStatusHighlight
    RefreshStatusHighlight, yL = AddHighlightControls(statusPage, CONTENT_X,
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
                    Get = function()
                        return statusSettings.statusBarHighlightColor
                    end,
                    Set = function(color)
                        statusSettings.statusBarHighlightColor = color
                    end,
                },
            },
            OnChange = function()
                WhoDoesWhat:RefreshStatusBarsView()
                WhoDoesWhat:RefreshStatusBarHighlights()
            end,
        })

    -- Every widget on this page, read back out of the settings. Called when the
    -- window opens and again after the Defaults button has rewritten them.
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
    end

    -- ---- Buff Tracking ----
    local statusBuffPage = pages[3]
    yL = y0
    local statusBuffHeading
    yL, statusBuffHeading = AddHeading(statusBuffPage, CONTENT_X, yL,
        "Buff Tracking", 0.96, 0.55, 0.73)
    UI.AddTooltip(statusBuffHeading, "Buff Tracking",
        "Use arrows to order Bars; disabled rows move below the divider. Use the cog for display and target options.")
    local resetBuffs = CreateFrame("Button", nil, statusBuffPage, "UIPanelButtonTemplate")
    resetBuffs:SetSize(100, 22)
    resetBuffs:SetPoint("TOPRIGHT", statusBuffPage, "TOPRIGHT", -16, -(y0 - 2))
    resetBuffs:SetText("Reset Defaults")
    resetBuffs:SetScript("OnClick", function() ResetBuffTrackingPage(f) end)
    UI.AddTooltip(resetBuffs, "Reset Buff Tracking",
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
        UI.AddTooltip(text, header[1], tips[header[1]])
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
    UI.AddTooltip(divider, "Hidden from Status Bars",
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

        row.up = UI.CreateArrowButton(row, "Up")
        row.up:SetPoint("LEFT", 0, 0)
        row.up:SetScript("OnClick", function() MoveStatusBuff(f, rowKey, -1) end)
        UI.AddTooltip(row.up, "Move up", "Move this row earlier in WDW Status.")
        row.down = UI.CreateArrowButton(row, "Down")
        row.down:SetPoint("LEFT", row.up, "RIGHT", 2, 0)
        row.down:SetScript("OnClick", function() MoveStatusBuff(f, rowKey, 1) end)
        UI.AddTooltip(row.down, "Move down",
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
            WhoDoesWhat:ApplyStatusCheckIcon(icon, definition)
        end
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", icon, "RIGHT", 7, 0)
        name:SetWidth(148)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)
        name:SetText(definition.name)
        UI.AddTooltip(row, definition.name, definition.description, nil, true)

        row.bar = UI.CreateCheckbox(row, nil, "Show in Bars",
            "Show this row in WDW Status. Turning it off moves it below the divider.",
            function(self)
                SetStatusBuffBarEnabled(f, rowKey, self:GetChecked() and true or false)
            end, { size = 24 })
        row.bar:SetPoint("CENTER", row, "LEFT", 272, 0)
        row.grid = UI.CreateCheckbox(row, nil, "Show in Buff Grid",
            "Show this check as a column in the Buffing Grid.",
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
        UI.AddTooltip(options, definition.name .. " options", "Open this row's settings.")
        row.options = options
    end
    RefreshStatusBuffRows(f)

    -- ---- Paladin ----
    local paladinPage = pages[4]
    yL = y0
    yL = AddHeading(paladinPage, CONTENT_X, yL, "Paladin Buffing Bar", 0.96, 0.55, 0.73)

    -- Same place and same job as the Status Bars page's: on the heading line,
    -- hard right, undoing the whole page at once.
    local paladinReset = CreateFrame("Button", nil, paladinPage,
        "UIPanelButtonTemplate")
    paladinReset:SetSize(80, 22)
    paladinReset:SetPoint("TOPRIGHT", paladinPage, "TOPRIGHT", -16, -(y0 - 2))
    paladinReset:SetText("Defaults")
    paladinReset:SetScript("OnClick", function()
        WhoDoesWhat:ResetPaladinBarSettings()
        f.RefreshPaladinPage()
    end)
    UI.AddTooltip(paladinReset, "Reset Paladin Bar",
        "Put every option on this page back to its default and move the bar"
            .. " to where a fresh install finds it. Test mode on the Developer"
            .. " page is left alone.")

    f.buffingBarCheck, yL = AddCompactCheckboxRow(paladinPage, CONTENT_X, yL, "Enable Paladin Buffing Bar",
        "Show a movable, clickable bar of your assigned blessings - a Nova-style alternative to PallyPower. Appears only when you're a paladin, unless test mode is on.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarEnabled = value
            WhoDoesWhat:LogUiBuilding("Paladin Buffing Bar " .. (value and "enabled." or "disabled."))
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end)

    f.buffingAuraCheck, yL = AddCompactCheckboxRow(paladinPage, CONTENT_X, yL,
        "Paladin Aura Helper",
        "Add an aura swapper at the left end of the bar. Hovering it opens a picker of every aura you know, left-click casts the one it's offering; it turns grey with a red glow while that aura isn't the one you're running.",
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

    f.buffingHideCompletedCheck, yL = AddCompactCheckboxRow(paladinPage, CONTENT_X, yL,
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

    local function AddBuffingDropdown(name, text, dy, width)
        local label = paladinPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + dy))
        label:SetText(text)
        local dd = UI.CreateMenuDropdown(paladinPage, name, width)
        dd:SetPoint("LEFT", label, "RIGHT", -6, -2)
        return dd
    end

    local orientDD = AddBuffingDropdown("WhoDoesWhatBuffingOrientDD",
        "Bar layout:", 4, 90)
    local growDD = AddBuffingDropdown("WhoDoesWhatBuffingGrowDD",
        "Bar grows:", 34, 90)
    local menuGrowDD = AddBuffingDropdown("WhoDoesWhatBuffingMenuGrowDD",
        "Player menu grows:", 64, 80)

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

    -- One threshold, two tells: the countdown that appears over a class button
    -- and the yellow player rows inside it.
    local warnDD = AddBuffingDropdown("WhoDoesWhatBuffingWarnDD",
        "Warn below:", 94, 100)
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

    -- Past the four dropdowns above, which hang off a frozen yL at fixed
    -- offsets rather than advancing it.
    yL = yL + 124

    local buffingSettings = WhoDoesWhat.db.profile.settings
    local buffingIconRange = WhoDoesWhat.BUFFING_BAR_ICON_SIZE
    f.RefreshBuffingIconSize, yL = AddSliderWithInput(paladinPage, CONTENT_X,
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

    -- The status bars' highlight styles, in this bar's own two colours.
    f.RefreshBuffingHighlight, yL = AddHighlightControls(paladinPage,
        CONTENT_X, yL, {
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
                    Get = function()
                        return buffingSettings.buffingBarGlowMissingColor
                    end,
                    Set = function(color)
                        buffingSettings.buffingBarGlowMissingColor = color
                    end,
                },
                {
                    label = "Expiring color:",
                    tooltip = "The color a self-buff button glows once it is"
                        .. " inside its warning window, with a countdown"
                        .. " running. Right-click the swatch to reset it.",
                    Get = function()
                        return buffingSettings.buffingBarGlowExpiringColor
                    end,
                    Set = function(color)
                        buffingSettings.buffingBarGlowExpiringColor = color
                    end,
                },
            },
            OnChange = function()
                WhoDoesWhat:RefreshPaladinBuffingBar()
            end,
        })

    -- Every widget on this page, read back out of the settings. Called when the
    -- window opens and again after the Defaults button has rewritten them.
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
    end

    -- ---- Warrior ----
    local warriorPage = pages[5]
    yL = y0
    yL = AddHeading(warriorPage, CONTENT_X, yL, "Warrior Shouts", 0.78, 0.61, 0.43)

    local shoutIntro = warriorPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    shoutIntro:SetPoint("TOPLEFT", CONTENT_X + 4, -yL)
    shoutIntro:SetWidth(CONTENT_W - 8)
    shoutIntro:SetJustifyH("LEFT")
    shoutIntro:SetTextColor(0.7, 0.7, 0.7)
    shoutIntro:SetText("An efficient warrior buffing bar for shouts. Includes"
        .. " pets and ignores irrelevant party members based on WDW roles."
        .. " Hover the bar and check the tooltips for additional info")
    yL = yL + math.ceil(shoutIntro:GetStringHeight()) + 12

    local shoutShowLabel = warriorPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    shoutShowLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 4))
    shoutShowLabel:SetText("Show shout bar:")
    local shoutShowDD = UI.CreateMenuDropdown(warriorPage, "WhoDoesWhatShoutBarShowDD", 120)
    shoutShowDD:SetPoint("LEFT", shoutShowLabel, "RIGHT", -6, -2)
    UIDropDownMenu_Initialize(shoutShowDD, function(_, level)
        local saved = WhoDoesWhat:GetShoutBarMode()
        for _, mode in ipairs(WhoDoesWhat.ShoutBarModes) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = mode.label
            info.checked = (saved == mode.key)
            info.func = function()
                WhoDoesWhat.db.profile.settings.shoutBarShow = mode.key
                UIDropDownMenu_SetText(shoutShowDD, mode.label)
                WhoDoesWhat:LogUiBuilding("Warrior Shout Bar set to "
                    .. mode.label .. ".")
                WhoDoesWhat:UpdateWarriorShoutBarVisibility()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    -- Category names in yellow so the four answers are scannable, and Always
    -- in red because it is a testing setting: a shout bar in a group with no
    -- warrior is glowing at something nobody present can cast.
    UI.AddDropdownTooltip(shoutShowDD, shoutShowLabel, "Show shout bar",
        "|cffffd100Warriors only:|r Only visible if YOU are a warrior"
        .. "\n\n|cffffd100With a warrior:|r Only visible with a warrior in"
        .. " your group"
        .. "\n\n|cffff4d4dAlways:|r Testing only - shown even with no warrior"
        .. " around to cast anything"
        .. "\n\n|cffffd100Never:|r never shown")
    f.shoutShowDD = shoutShowDD

    local shoutAnchorLabel = warriorPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    shoutAnchorLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 34))
    shoutAnchorLabel:SetText("Anchor:")
    local shoutAnchorDD = UI.CreateMenuDropdown(warriorPage, "WhoDoesWhatShoutBarAnchorDD", 90)
    shoutAnchorDD:SetPoint("LEFT", shoutAnchorLabel, "RIGHT", -6, -2)
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

    local shoutTimerLabel = warriorPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    shoutTimerLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 64))
    shoutTimerLabel:SetText("Countdown at:")
    local shoutTimerDD = UI.CreateMenuDropdown(warriorPage, "WhoDoesWhatShoutBarTimerDD", 70)
    shoutTimerDD:SetPoint("LEFT", shoutTimerLabel, "RIGHT", -6, -2)
    UIDropDownMenu_Initialize(shoutTimerDD, function(_, level)
        local saved = WhoDoesWhat:GetShoutBarTimerSeconds()
        for _, seconds in ipairs(WhoDoesWhat.ShoutBarTimerSeconds) do
            local label = WhoDoesWhat:GetShoutBarTimerLabel(seconds)
            local info = UIDropDownMenu_CreateInfo()
            info.text = label
            info.checked = (saved == seconds)
            info.func = function()
                WhoDoesWhat.db.profile.settings.shoutBarTimerSeconds = seconds
                UIDropDownMenu_SetText(shoutTimerDD, label)
                WhoDoesWhat:RefreshWarriorShoutBar()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UI.AddDropdownTooltip(shoutTimerDD, shoutTimerLabel, "Countdown at",
        "Puts a countdown over the icon when the first person is about to lose"
        .. " the shout. Off hides it entirely.")
    f.shoutTimerDD = shoutTimerDD

    f.shoutHideBackgroundCheck, yL = AddCompactCheckboxRow(warriorPage,
        CONTENT_X, yL + 98, "Hide background",
        "Leaves just the icons floating on your screen. Alt-drag still moves"
        .. " the bar.",
        function(value)
            WhoDoesWhat.db.profile.settings.shoutBarHideBackground = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    f.shoutHideNumbersCheck, yL = AddCompactCheckboxRow(warriorPage,
        CONTENT_X, yL, "Hide numbers",
        "Drops the count under each icon. The glow still tells you somebody is"
        .. " missing the shout, and the tooltip still names them.",
        function(value)
            WhoDoesWhat.db.profile.settings.shoutBarHideNumbers = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    f.shoutHideWhenBuffedCheck, yL = AddCompactCheckboxRow(warriorPage,
        CONTENT_X, yL, "Hide while everything is up",
        "Hides each icon while its own shout is on everybody, and brings it"
        .. " back the moment somebody loses it. Hidden icons can't be clicked"
        .. " or dragged, so place the bar before turning this on.",
        function(value)
            WhoDoesWhat.db.profile.settings.shoutBarHideWhenBuffed = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    f.shoutIgnoreRangeCheck, yL = AddCompactCheckboxRow(warriorPage,
        CONTENT_X, yL, "Ignore players far out of range",
        "Stops counting party members who are nowhere near you. Anyone just a"
        .. " step too far back still counts, since stepping in is the fix.",
        function(value)
            WhoDoesWhat.db.profile.settings.shoutBarIgnoreOutOfRange = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    local shoutSettings = WhoDoesWhat.db.profile.settings
    local shoutIconRange = WhoDoesWhat.SHOUT_BAR_ICON_SIZE
    f.RefreshShoutIconSize, yL = AddSliderWithInput(warriorPage, CONTENT_X,
        yL + 4, {
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
        function(value) shoutSettings.shoutBarIconSize = value end,
        function() WhoDoesWhat:RefreshWarriorShoutBar() end)

    -- The status bars' highlight styles, in this bar's own two colours.
    f.RefreshShoutHighlight, yL = AddHighlightControls(warriorPage, CONTENT_X,
        yL, {
            name = "WhoDoesWhatShoutBarHighlightDD",
            tooltip = "The animation a shout icon wears while somebody in the"
                .. " party is missing that shout -- the box to the right shows"
                .. " it running.",
            GetStyle = function() return shoutSettings.shoutBarGlowStyle end,
            SetStyle = function(key) shoutSettings.shoutBarGlowStyle = key end,
            colors = {
                {
                    label = "Missing color:",
                    tooltip = "The color a shout icon glows while nobody in"
                        .. " the party has that shout. Right-click the swatch"
                        .. " to reset it.",
                    Get = function()
                        return shoutSettings.shoutBarGlowMissingColor
                    end,
                    Set = function(color)
                        shoutSettings.shoutBarGlowMissingColor = color
                    end,
                },
                {
                    label = "Partial color:",
                    tooltip = "The color a shout icon glows once some of the"
                        .. " party has that shout but not all of it -- the"
                        .. " same state the count under the icon reads in"
                        .. " yellow for. Right-click the swatch to reset it.",
                    Get = function()
                        return shoutSettings.shoutBarGlowPartialColor
                    end,
                    Set = function(color)
                        shoutSettings.shoutBarGlowPartialColor = color
                    end,
                },
            },
            OnChange = function() WhoDoesWhat:RefreshWarriorShoutBar() end,
        })

    -- ---- Warlock ----
    local warlockPage = pages[6]
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
    local developerPage = pages[8]
    local yR = y0
    yR = AddHeading(developerPage, CONTENT_X, yR, "Developer Options")
    f.devModeCheck, yR = AddCompactCheckboxRow(developerPage, CONTENT_X, yR, "Developer Mode",
        "Assignment dropdowns list every group member, not just the eligible class.",
        function(value)
            WhoDoesWhat.db.profile.settings.developerMode = value
            WhoDoesWhat:LogUiBuilding("Developer Mode " .. (value and "enabled." or "disabled."))
        end)
    f.showLogsCheck, yR = AddCompactCheckboxRow(developerPage, CONTENT_X, yR, "Show Logs tab",
        "Show the combined WhoDoesWhat and PallyPower traffic logs as a tab in the main window.",
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
    local testingPage = pages[7]
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
    local palDD = UI.CreateMenuDropdown(testingPage, "WhoDoesWhatFakePaladinCountDD", 40)
    palDD:SetPoint("LEFT", palLabel, "RIGHT", -8, -2)
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
    local testDD = UI.CreateMenuDropdown(testingPage, "WhoDoesWhatBuffingTestPaladinDD", 120)
    testDD:SetPoint("LEFT", testLabel, "RIGHT", -6, -2)
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
    f:SetScript("OnShow", function(self)
        LoadSettings(self)
        if self.currentScroll then UI.FitScrollToContent(self.currentScroll) end
    end)
    settingsFrame = f
    return f
end

-- Put every control back in step with the saved settings. Run each time the
-- page comes up, since anything can have changed them while it was away.
function LoadSettings(f)
    local self = WhoDoesWhat
    local settings = self.db.profile.settings
    f.minimapCheck:SetChecked(not settings.minimapButton.hide)
    f.RefreshPaladinPage()
    f.buffingTestCheck:SetChecked(settings.buffingBarTestMode)
    RefreshBuffingTestPaladinDropdown(f)
    f.unitTooltipCheck:SetChecked(settings.unitTooltipRole ~= false)
    f.unitTooltipDetailCheck:SetChecked(settings.unitTooltipDetail)
    f.raidFrameRoleCheck:SetChecked(settings.raidFrameRoleIcons ~= false)
    f.raidFrameCombatCheck:SetChecked(settings.raidFrameRoleIconsInCombat ~= false)
    UIDropDownMenu_SetText(f.raidStyleDD,
        f.raidStyleLabels[settings.raidFrameRoleIconStyle or "corner"]
            or f.raidStyleLabels.corner)
    RefreshRaidFrameOptionStates(f)
    f.announceRoleCheck:SetChecked(settings.announceRoleChanges)
    f.manageBlizzRolesCheck:SetChecked(settings.manageBlizzardRoles ~= false)
    f.RefreshStatusPage()
    RefreshStatusBuffRows(f)
    f.devModeCheck:SetChecked(settings.developerMode)
    f.showLogsCheck:SetChecked(settings.showLogsButton)
    f.logUiCheck:SetChecked(settings.logUiUpdates)
    f.logOperationsCheck:SetChecked(settings.logOperations)
    f.logSyncStatusCheck:SetChecked(settings.logSyncStatus)
    f.logSyncTrafficCheck:SetChecked(self.LOG_SYNC)
    f.logBuffingClicksCheck:SetChecked(settings.logBuffingBarClicks)
    f.logRolePromotionCheck:SetChecked(settings.logRolePromotion)
    local shoutMode = self:GetShoutBarMode()
    UIDropDownMenu_SetText(f.shoutShowDD, self:GetShoutBarModeLabel(shoutMode))
    local shoutAnchor = self:GetShoutBarAnchor()
    UIDropDownMenu_SetText(f.shoutAnchorDD,
        self:GetShoutBarAnchorLabel(shoutAnchor))
    UIDropDownMenu_SetText(f.shoutTimerDD,
        self:GetShoutBarTimerLabel(self:GetShoutBarTimerSeconds()))
    f.shoutHideBackgroundCheck:SetChecked(settings.shoutBarHideBackground)
    f.shoutHideNumbersCheck:SetChecked(settings.shoutBarHideNumbers)
    f.shoutHideWhenBuffedCheck:SetChecked(settings.shoutBarHideWhenBuffed)
    f.shoutIgnoreRangeCheck:SetChecked(settings.shoutBarIgnoreOutOfRange)
    f.RefreshShoutIconSize()
    f.RefreshShoutHighlight()
    f.afflElementsCheck:SetChecked(settings.autoAssignAfflictionElements)
    f.recklessnessCheck:SetChecked(settings.allowRecklessnessAutoAssign)
--@do-not-package@
    f.newerVersionTestCheck:SetChecked(settings.simulateNewerAddonVersion)
--@end-do-not-package@
    f.fakeRaidCheck:SetChecked(settings.populateFakeRaid)
    UIDropDownMenu_SetText(f.fakePaladinDD, tostring(settings.fakeRaidPaladinCount or 3))
end

-- Open the main window on the Settings tab, or close it if it is already there.
-- A section label opens straight to that section and never closes the window.
function WhoDoesWhat:OpenAddonSettingsView(section)
    if self:ShowMainTab("settings", section ~= nil) and section then
        settingsFrame.SelectSection(section)
    end
end

-- Open one check's cog options directly (WDW Status' shift-right-click on a
-- bar). Selecting the page closes any open options popup, so the popup opens
-- after the window is on the right page.
function WhoDoesWhat:OpenBuffTrackingOptions(key)
    if not self.StatusBarChecks[key] then return end
    self:OpenAddonSettingsView("Buff Tracking")
    OpenBuffOptions(settingsFrame, key)
end

function WhoDoesWhat:RefreshAddonSettingsLoggingCheck()
    if settingsFrame and settingsFrame.logSyncTrafficCheck then
        settingsFrame.logSyncTrafficCheck:SetChecked(self.LOG_SYNC)
    end
end
