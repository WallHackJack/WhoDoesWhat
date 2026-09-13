local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local K = WhoDoesWhat.SectionKit

-- Addon settings (the main window's Settings tab). Checkbox state persists in db.profile.settings except
-- detailed sync logging, which is deliberately session-only and resets off.

local settingsFrame = nil
local buffOptionsFrame = nil

-- Each section scrolls on its own under its tab. Everything a section lays out
-- is measured from the left of its own scroll area, which is why CONTENT_X is
-- so small.
local CONTENT_X = 8
local CONTENT_W = 410
-- Most sections set their column in from the left so it sits near the middle of
-- the page. Buff Tracking's table is wide enough to want the room. A little
-- right of true centre: most rows are short checkbox labels, so the column's
-- visible weight sits well left of its full width.
local PAGE_X = CONTENT_X + 244
-- That column's width, which its section dividers span.
local PAGE_COLUMN_W = 400
-- Laid out like the Buff Tracking row options: a label at the column's left,
-- and every dropdown box and colour swatch starting this far to its right.
local PAGE_FIELD_OFFSET = 146
-- One width for every dropdown in the column, wide enough for the longest
-- choice any of them has ("Pulsing wings (right)").
local PAGE_DROPDOWN_W = 140
local PAGE_DROPDOWN_ROW_H = 32
-- Behind each section, inside the Settings tab's near-black: a dark navy well,
-- just light enough for its edge shadows to show.
local PAGE_WELL = { 0.045, 0.06, 0.10, 1 }
-- Around the header and those wells, inside the section tabs' border - a step
-- lighter, so each well reads as sunk into it.
local PANEL_SLATE = { 0.075, 0.095, 0.16, 1 }
-- The Buffs row options' title bar: a deep navy, darker and bluer than both,
-- so it stands apart without shouting over the options under it.
local OPTIONS_HEADER_BLUE = { 0.025, 0.035, 0.085, 1 }
-- Settings table rows, over the well: odd, even.
local ROW_STRIPES = { { 0.14, 0.17, 0.26 }, { 0.085, 0.10, 0.17 } }
-- The shared title and Reset Defaults strip above every section.
local HEADER_H = 34
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
local DROPDOWN_INSET = 17
-- One width for every dropdown there, wide enough for the longest choice.
local OPTIONS_DROPDOWN_W = 120
local OPTION_ROW_H = 22
local DROPDOWN_ROW_H = 28
local DIVIDER_GAP = 14
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

-- One confirm for every reset. The `data` passed to StaticPopup_Show is the
-- reset to run on Yes; the text is the whole question.
StaticPopupDialogs["WHODOESWHAT_RESET_SETTINGS"] = {
    text = "%s",
    button1 = "Reset",
    button2 = "Cancel",
    OnAccept = function(self) self.data() end,
    timeout = 0,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Put settings keys back to their profile defaults - straight from the defaults
-- rather than a second list of values, so a reset and a fresh install cannot
-- disagree. Tables are copied: handing out the defaults' own table would let the
-- next edit rewrite the default itself.
function WhoDoesWhat:RestoreDefaultSettings(keys)
    local settings = self.db.profile.settings
    local defaults = self.db.defaults.profile.settings
    for _, key in ipairs(keys) do
        local value = defaults[key]
        settings[key] = type(value) == "table" and CopyTable(value) or value
    end
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
    check:SetHitRectInsets(0, -(PAGE_COLUMN_W - 30 - (x - PAGE_X)), 0, 0)
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

-- Re-read the whole minimap button setting, position included.
function WhoDoesWhat:RefreshMinimapButton()
    if not minimapIcon then return end
    minimapIcon:Refresh(MINIMAP_NAME, self.db.profile.settings.minimapButton)
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

-- A 10px shadow for the edge of a scroll area, dark against the edge and clear
-- toward the content, drawn at `level` so content scrolls under it. `top` says
-- which edge; the caller anchors and sizes it across. On a client without
-- gradients it is an empty frame.
local function CreateEdgeShadow(parent, level, top)
    local edge = CreateFrame("Frame", nil, parent)
    edge:SetHeight(10)
    edge:SetFrameLevel(level)
    local shadow = edge:CreateTexture(nil, "BACKGROUND")
    if not (shadow.SetGradient and CreateColor) then return edge end
    shadow:SetAllPoints()
    shadow:SetColorTexture(1, 1, 1, 1)
    -- Vertical gradients run bottom to top.
    local clear, dark = CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.55)
    if top then
        shadow:SetGradient("VERTICAL", clear, dark)
    else
        shadow:SetGradient("VERTICAL", dark, clear)
    end
    return edge
end

-- `color` is { r, g, b }, gold when left out.
local function CreateMiniDivider(parent, text, color)
    local r, g, b = 0.8, 0.65, 0.12
    if color then r, g, b = color[1], color[2], color[3] end
    -- Width comes from where it is placed: it spans the options panel.
    local divider = CreateFrame("Frame", nil, parent)
    divider:SetHeight(10)
    -- Near the left end, a short rule before it and the long one after.
    local label = divider:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", 36, 0)
    label:SetText(text)
    label:SetTextColor(r, g, b)
    local left = divider:CreateTexture(nil, "ARTWORK")
    left:SetHeight(1)
    left:SetPoint("LEFT")
    left:SetPoint("RIGHT", label, "LEFT", -6, 0)
    left:SetColorTexture(r, g, b, 0.3)
    local right = divider:CreateTexture(nil, "ARTWORK")
    right:SetHeight(1)
    right:SetPoint("LEFT", label, "RIGHT", 6, 0)
    right:SetPoint("RIGHT")
    right:SetColorTexture(r, g, b, 0.3)
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
    f.buffNameGroup:SetWidth(33 + f.buffName:GetStringWidth())
    UIDropDownMenu_SetText(f.scopeDD,
        STATUS_SCOPE_LABELS[options.scope] or STATUS_SCOPE_LABELS.always)

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

    UIDropDownMenu_SetText(f.displayDD,
        STATUS_DISPLAY_LABELS[options.display] or STATUS_DISPLAY_LABELS.default)
    UIDropDownMenu_SetText(f.classDD, options.requiredClass or "None")
    UIDropDownMenu_SetText(f.saturatedDD,
        STATUS_SATURATED_LABELS[options.saturatedStyle]
            or STATUS_SATURATED_LABELS.check)
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
        and ("Only as " .. options.requiredClass)
        or "Only as the supplying class")
    y = PlaceOption("partialGlow", y)
    y = PlaceOption("partialGlowOnlyClass", y, 14)
    y = PlaceOption("hideBarUnavailable", y)
    y = PlaceOption("hideColumnUnavailable", y)

    y = PlaceDivider(f.completionDivider, true, y)
    y = PlaceOption("negative", y)
    f.optionLabels.hideComplete:SetText(options.negative
        and "Hide Bar when debuff missing" or "Hide Bar when complete")
    y = PlaceOption("hideComplete", y)
    local showSaturated = Shown("saturatedStyle")
    f.saturatedLabel:SetShown(showSaturated)
    f.saturatedDD:SetShown(showSaturated)
    if showSaturated then
        y = PlaceDropdown(f.saturatedLabel, f.saturatedDD, y)
    end
    f.optionLabels.hideColumnComplete:SetText(options.negative
        and "Hide grid column when debuff missing"
        or "Hide grid column when complete")
    y = PlaceOption("hideColumnComplete", y)

    y = PlaceDivider(f.targetsDivider, Shown("onlyManaUsers")
        or Shown("onlyTanks") or Shown("hunterPets"), y)
    y = PlaceOption("onlyManaUsers", y)
    y = PlaceOption("onlyTanks", y)
    -- A check that counts every class's pet says so; the rest are hunters-only.
    f.optionLabels.hunterPets:SetText(definition.allPets
        and "Used by pets" or "Used by hunter pets")
    y = PlaceOption("hunterPets", y)
    f:SetHeight(y + 7)
end

-- ---------------------------------------------------------------------------
-- Option widgets three pages share
-- ---------------------------------------------------------------------------

-- A Buff Tracking style divider across the column, heading the group of
-- options under it. `y` is where it goes; returns the y the group starts at.
local function AddPageDivider(parent, y, text, color)
    local divider = CreateMiniDivider(parent, text, color)
    divider:SetPoint("TOPLEFT", PAGE_X, -y)
    divider:SetWidth(PAGE_COLUMN_W)
    divider.isPageDivider = true
    return y + 18
end

-- The same, after the group above it, with the gap between groups first.
local function AddNextPageDivider(parent, y, text, color)
    return AddPageDivider(parent, y + DIVIDER_GAP, text, color)
end

-- A label at the column's left and a dropdown whose box starts at the column's
-- shared field x. Returns the label, the dropdown, and the y below the row.
-- A short grey paragraph at the top of the column saying what the page's
-- feature is. Returns the text and the y below it.
local function AddPageIntro(parent, y, text)
    local intro = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", PAGE_X + 4, -y)
    intro:SetWidth(PAGE_COLUMN_W - 8)
    intro:SetJustifyH("LEFT")
    intro:SetTextColor(0.7, 0.7, 0.7)
    intro:SetText(text)
    return intro, y + math.ceil(intro:GetStringHeight()) + 12
end

local function AddDropdownRow(parent, y, text, name)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", PAGE_X + 4, -(y + 4))
    label:SetText(text)
    local dd = UI.CreateMenuDropdown(parent, name, PAGE_DROPDOWN_W)
    dd:SetPoint("LEFT", label, "LEFT", PAGE_FIELD_OFFSET - DROPDOWN_INSET, -2)
    return label, dd, y + PAGE_DROPDOWN_ROW_H
end

-- For a page with a master switch: returns a function that greys out and
-- disables everything on the page except the dividers and what `keep` lists
-- (the switch itself, its label, any intro text). The page is re-read on every
-- call: the outline highlight styles add their frame to it the first time the
-- preview runs one.
local function PageControlSwitch(page, keep)
    local kept = {}
    for _, widget in ipairs(keep) do kept[widget] = true end
    return function(enabled)
        local controls = {}
        for _, child in ipairs({ page:GetChildren() }) do
            if not kept[child] and not child.isPageDivider then
                controls[#controls + 1] = child
            end
        end
        for _, region in ipairs({ page:GetRegions() }) do
            if not kept[region] then controls[#controls + 1] = region end
        end
        if not enabled then UI.CancelColorPicker() end
        for _, widget in ipairs(controls) do
            if widget.uiHousingStyled then
                if enabled then
                    UIDropDownMenu_EnableDropDown(widget)
                else
                    UIDropDownMenu_DisableDropDown(widget)
                end
            elseif widget.swatch then
                -- A colour field: the swatch button and the hex box inside it.
                widget.swatch:SetEnabled(enabled)
                widget.hex:EnableMouse(enabled)
                if not enabled then widget.hex:ClearFocus() end
            elseif widget:GetObjectType() == "EditBox" then
                widget:EnableMouse(enabled)
                if not enabled then widget:ClearFocus() end
            elseif widget.Enable and widget.Disable then
                if enabled then widget:Enable() else widget:Disable() end
            end
            widget:SetAlpha(enabled and 1 or 0.35)
        end
    end
end

-- The highlight-style dropdown, the box beside it showing that style running,
-- and one colour field per state the caller has. Three pages want exactly
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

    local dd = UI.CreateMenuDropdown(parent, spec.name, PAGE_DROPDOWN_W)
    dd:SetPoint("LEFT", styleLabel, "LEFT", PAGE_FIELD_OFFSET - DROPDOWN_INSET, -2)

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

    -- The colours go under the dropdown so the sample box beside it shows a
    -- colour change as it is dragged. Each swatch starts at the dropdown box's
    -- x, like every other field in the column.
    local fields = {}
    local rowY = y + 32
    local labels = {}
    for index, entry in ipairs(spec.colors) do
        local label = parent:CreateFontString(nil, "OVERLAY",
            "GameFontHighlight")
        label:SetPoint("TOPLEFT", x + 4, -(rowY + (index - 1) * 24 + 4))
        label:SetText(entry.label)
        UI.AddTooltip(label, entry.label, entry.tooltip)
        labels[index] = label
    end

    -- The picker's live preview: repaint the sample, then let whatever wears
    -- these colours pick the change up on the way past.
    local function ColorsChanged()
        ApplyPreview(SavedStyle())
        spec.OnChange()
    end

    for index, entry in ipairs(spec.colors) do
        local field = UI.CreateColorField(parent, {
            title = entry.label,
            -- nil is not "no colour": the profile default takes over again,
            -- which is what a reset means here.
            Get = entry.Get, Set = entry.Set,
            OnChange = ColorsChanged,
        })
        field:SetPoint("LEFT", labels[index], "LEFT", PAGE_FIELD_OFFSET, 0)
        fields[index] = field
    end
    rowY = rowY + #spec.colors * 24

    -- Every control here, read back out of the settings: the window opening,
    -- a page's Defaults button, or a different profile loading.
    local function Refresh()
        local styles = WhoDoesWhat:GetStatusBarHighlightStyles()
        UIDropDownMenu_SetText(dd, styles[SavedStyle()].label)
        for _, field in ipairs(fields) do field:Refresh() end
        ApplyPreview(SavedStyle())
    end

    return Refresh, rowY + 4
end

-- A whole number with two ways in: a slider to drag, and a box beside it to
-- type an exact value into. `spec` is { name, label, tooltip, min, max },
-- `Get` reads the saved number, `Set` writes one back, `OnChange` repaints.
local function AddSliderWithInput(parent, x, y, spec, Get, Set, OnChange)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", x + 4, -(y + 4))
    label:SetText(spec.label)

    -- On the label's row, starting at the column's shared field x.
    local slider, edit, Refresh = UI.CreateSliderWithInput(parent, spec, Get, Set, OnChange)
    slider:SetPoint("LEFT", label, "LEFT", PAGE_FIELD_OFFSET, 0)

    UI.AddTooltip(label, spec.label, spec.tooltip)
    UI.AddTooltip(edit, spec.label, spec.tooltip)

    return Refresh, y + PAGE_DROPDOWN_ROW_H
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
    local topEdge = CreateEdgeShadow(well, scroll:GetFrameLevel() + 20, true)
    topEdge:SetPoint("TOPLEFT", nameBar, "BOTTOMLEFT")
    topEdge:SetPoint("TOPRIGHT", nameBar, "BOTTOMRIGHT")
    -- The same shadow upside down along the panel's bottom edge, which the
    -- options scroll down under.
    local bottomEdge = CreateEdgeShadow(well, scroll:GetFrameLevel() + 20, false)
    bottomEdge:SetPoint("BOTTOMLEFT", well, "BOTTOMLEFT", BUFF_TABLE_W + BUFF_PANEL_GAP, 0)
    bottomEdge:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT")

    -- The template hangs the bar's arrow buttons right at the scroll area's
    -- ends, where they would poke into the heading bar and the bottom shadow.
    local bar = scroll.uiScrollBar
    if bar then
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, -28)
        bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 6, 28)
    end

    local nameGroup = CreateFrame("Frame", nil, nameBar)
    nameGroup:SetPoint("CENTER")
    nameGroup:SetHeight(26)
    f.buffNameGroup = nameGroup

    local RESET_DESCRIPTION = "Puts this row's options back. Whether it shows in"
        .. " Bars and the Buff Grid, and its place in the order, are kept."
    local resetRow = CreateFrame("Button", nil, nameBar, "UIPanelButtonTemplate")
    resetRow:SetSize(60, 22)
    resetRow:SetPoint("RIGHT", -8, 0)
    resetRow:SetText("Reset")
    resetRow:SetScript("OnClick", function()
        local rowKey = f.buffKey
        StaticPopup_Show("WHODOESWHAT_RESET_SETTINGS", "Reset "
            .. WhoDoesWhat.StatusBarChecks[rowKey].name .. " to defaults?\n\n"
            .. RESET_DESCRIPTION, nil, function() ResetBuffOptions(rowKey) end)
    end)
    UI.AddTooltip(resetRow, function()
        return "Reset " .. WhoDoesWhat.StatusBarChecks[f.buffKey].name, RESET_DESCRIPTION
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
    scopeLabel:SetText("Party type")
    local scopeDD = UI.CreateMenuDropdown(f, "WhoDoesWhatBuffTrackingScopeDD", OPTIONS_DROPDOWN_W)
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

    local displayLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    displayLabel:SetPoint("TOPLEFT", 190, -46)
    displayLabel:SetText("Text Mode")
    local displayDD = UI.CreateMenuDropdown(f, "WhoDoesWhatBuffTrackingDisplayDD", OPTIONS_DROPDOWN_W)
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

    local classLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    classLabel:SetPoint("TOPLEFT", 10, -77)
    classLabel:SetText("Requires Class:")
    local classDD = UI.CreateMenuDropdown(f, "WhoDoesWhatBuffTrackingClassDD", OPTIONS_DROPDOWN_W)
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

    local colorLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    colorLabel:SetPoint("TOPLEFT", 190, -77)
    colorLabel:SetText("Bar Color")
    local colorField = UI.CreateColorField(f, {
        title = "Bar color",
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
    UI.AddTooltip(colorLabel, "Bar color",
        "Choose the filled status-bar color. Right-click the swatch to reset it.")
    f.colorField = colorField
    f.colorLabel = colorLabel

    local saturatedLabel = f:CreateFontString(nil, "OVERLAY",
        "GameFontHighlight")
    saturatedLabel:SetText("Fully Debuffed Style:")
    local saturatedDD = UI.CreateMenuDropdown(f, "WhoDoesWhatBuffTrackingSaturatedStyleDD", OPTIONS_DROPDOWN_W)
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
        displayLabel, displayDD, classLabel, classDD, colorLabel, colorField,
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
            "Restrict that glow to the class that can actually cast it. Off,"
                .. " everybody sees the stragglers." },
    }
    for index, entry in ipairs(checkboxOptions) do
        local option, labelText, tooltip = entry[1], entry[2], entry[3]
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
    RefreshStatusBuffRows(owner)
    f:Show()
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

local LoadSettings -- defined after the page, which it reads the controls off

-- Build the page into the Settings tab: a second, indented row of tabs, one per
-- section, under one shared header, each over its own scroll area. Buff
-- Tracking keeps its row options in a second scroll area beside its table. A
-- section's scrollbar only appears if its content outgrows the tab.
function WhoDoesWhat:BuildAddonSettingsPage(tabPage)
    local f = CreateFrame("Frame", nil, tabPage)
    f:SetAllPoints(tabPage)
    f.titleBarHeight = 0
    local y0 = 10
    local pages, scrolls = {}, {}

    -- ---- Resets ----
    -- One per page, each followed by LoadSettings so every control catches up.
    -- The Status Bars, Paladin Bar and Warrior Shout resets live with their
    -- views, which own the frames they move back.
    local RESET_GENERAL = {
        "unitTooltipRole", "unitTooltipDetail", "raidFrameRoleIcons",
        "raidFrameRoleIconsInCombat", "raidFrameRoleIconStyle",
        "announceRoleChanges", "manageBlizzardRoles",
        "autoAssignAfflictionElements", "allowRecklessnessAutoAssign",
    }
    local RESET_TESTING = { "buffingBarTestMode", "buffingBarTestPaladin" }
    local RESET_DEVELOPER = {
        "developerMode", "showLogsButton", "logUiUpdates", "logOperations",
        "logSyncStatus", "logBuffingBarClicks", "logRolePromotion",
        "simulateNewerAddonVersion",
    }

    local function ResetGeneral()
        WhoDoesWhat:RestoreDefaultSettings(RESET_GENERAL)
        -- In place: LibDBIcon holds on to this very table.
        local minimap = WhoDoesWhat.db.profile.settings.minimapButton
        local defaultMinimap = WhoDoesWhat.db.defaults.profile.settings.minimapButton
        minimap.hide, minimap.minimapPos = defaultMinimap.hide, defaultMinimap.minimapPos
        WhoDoesWhat:RefreshMinimapButton()
        WhoDoesWhat:RefreshRaidFrameRoleIcons()
        if WhoDoesWhat.db.profile.settings.manageBlizzardRoles then
            WhoDoesWhat:ReconcileBlizzardRoles()
        end
    end

    local function ResetStatusBars()
        UI.CancelColorPicker()
        WhoDoesWhat:ResetStatusBarSettings()
    end

    -- Fake raid off first: that is what wipes the board, and with it off the
    -- paladin count changes without wiping it a second time.
    local function ResetTesting()
        if WhoDoesWhat:IsFakeRaidEnabled() then WhoDoesWhat:SetFakeRaidEnabled(false) end
        WhoDoesWhat:SetFakeRaidPaladinCount(
            WhoDoesWhat.db.defaults.profile.settings.fakeRaidPaladinCount)
        WhoDoesWhat:RestoreDefaultSettings(RESET_TESTING)
        WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
    end

    local function ResetDeveloper()
        WhoDoesWhat:RestoreDefaultSettings(RESET_DEVELOPER)
        local settings = WhoDoesWhat.db.profile.settings
        WhoDoesWhat.LOG_UI_BUILDING = settings.logUiUpdates
        WhoDoesWhat.LOG_OPERATIONS = settings.logOperations
        WhoDoesWhat:SetSyncLoggingEnabled(false)
        WhoDoesWhat:RefreshMainAssignmentsView()
    end

    local function WithReload(reset)
        return function()
            reset()
            LoadSettings(f)
        end
    end

    -- ---- Sections ----
    -- One entry per tab. `title` and `color` head the page, `description` says
    -- what its reset touches (tooltip and confirm both), `right` runs the tab
    -- from the right-hand end of the row, where the first listed is outermost.
    local sections = {
        { label = "General", title = "General",
            description = "Puts every option on this page back and returns the"
                .. " minimap button to its default spot.",
            reset = WithReload(ResetGeneral) },
        { label = "Roles", title = "Roles",
            tooltip = "Every role WDW knows, by class, plus your own custom"
                .. " ones. Click a role to see its blessing order.",
            description = "Deletes your custom role library. Custom roles already"
                .. " published to the raid, and who holds which role, are kept.",
            reset = function() WhoDoesWhat:ResetRolesSettingsPage() end,
            OnShow = function() WhoDoesWhat:RefreshRolesSettingsPage() end },
        { label = "Status Bars", title = "Status Bars",
            description = "Puts every option on this page back and moves the"
                .. " window to the middle of the screen. Per-check options on"
                .. " the Buffs page are left alone.",
            reset = WithReload(ResetStatusBars) },
        { label = "Buffs", title = "Buff Tracking",
            tooltip = "Use arrows to order Bars; disabled rows move below the"
                .. " divider. Use the cog for display and target options.",
            description = "Restores the default order, visibility, colors, and"
                .. " per-row options.",
            reset = function() ResetBuffTrackingPage(f) end },
        { label = "Paladin Bar", title = "Paladin Buffing Bar",
            color = { 0.96, 0.55, 0.73 },
            description = "Puts every option on this page back and moves the bar"
                .. " to where a fresh install finds it. Test mode on the Testing"
                .. " page is left alone.",
            reset = WithReload(function() WhoDoesWhat:ResetPaladinBarSettings() end) },
        { label = "Warrior Bar", title = "Warrior Shouts", color = { 0.78, 0.61, 0.43 },
            description = "Puts every option on this page back and re-centres the"
                .. " shout bar.",
            reset = WithReload(function() WhoDoesWhat:ResetShoutBarSettings() end) },
        { label = "Developer", title = "Developer Options", right = true,
            description = "Turns Developer Mode, the Logs tab and every logging"
                .. " option off.",
            reset = WithReload(ResetDeveloper) },
        { label = "Testing", title = "Testing", right = true,
            description = "Resets the testing settings to their defaults.",
            reset = WithReload(ResetTesting) },
    }

    local specs = {}
    for i, section in ipairs(sections) do
        specs[i] = { label = section.label, right = section.right }
    end
    -- The section panel, around the header and each section's well, in a
    -- lighter slate than the Settings tab's near-black: each well reads as sunk
    -- into it, and its edge shadows have something to fall away from.
    local sectionTabs = UI.AddTabs(f, specs,
        { colors = WhoDoesWhat.Theme.TabsWith({ panel = PANEL_SLATE },
            WhoDoesWhat.Theme.subTabs) })
    local panel = f.tabPanel

    -- One header for every section, above its content: the title, centred, and
    -- the Reset Defaults button hard right. Both read the section that is up.
    local header = CreateFrame("Frame", nil, panel)
    header:SetPoint("TOPLEFT", 10, -10)
    header:SetPoint("TOPRIGHT", -10, -10)
    header:SetHeight(HEADER_H)

    local title = CreateFrame("Frame", nil, header)
    title:SetPoint("CENTER", 0, 3)
    title.text = title:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title.text:SetPoint("CENTER")
    UI.AddTooltip(title, function()
        if f.section.tooltip then return f.section.title, f.section.tooltip end
    end)

    local resetButton = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
    resetButton:SetSize(110, 22)
    resetButton:SetPoint("RIGHT", 0, 4)
    resetButton:SetText("Reset Defaults")
    resetButton:SetScript("OnClick", function()
        StaticPopup_Show("WHODOESWHAT_RESET_SETTINGS", "Reset " .. f.section.title
            .. " to defaults?\n\n" .. f.section.description, nil, f.section.reset)
    end)
    UI.AddTooltip(resetButton, function()
        return "Reset " .. f.section.title, f.section.description
    end)

    -- Each section's content sits below the header in a well of its own,
    -- which is all its scroll area - and scrollbar - covers.
    for i in ipairs(sections) do
        local well = sectionTabs[i]
        well:ClearAllPoints()
        well:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -(10 + HEADER_H))
        well:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 10)
        local fill = well:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints()
        fill:SetColorTexture(PAGE_WELL[1], PAGE_WELL[2], PAGE_WELL[3], PAGE_WELL[4])
        well.fill = fill
        -- Flush with the grey on every side, bar the scrollbar's gutter. A
        -- shadow along the top and bottom edges shows the content scrolling
        -- under them. Buff Tracking re-anchors its own scroll below its
        -- column headings, so it keeps the shadows its options panel draws.
        local scroll, page = UI.CreateScroll(well, "WhoDoesWhatSettingsSection" .. i)
        scroll:SetPoint("TOPLEFT")
        scroll:SetPoint("BOTTOMRIGHT", -UI.SCROLLBAR_W, 0)
        if sections[i].label ~= "Buffs" then
            local level = scroll:GetFrameLevel() + 20
            local topEdge = CreateEdgeShadow(well, level, true)
            topEdge:SetPoint("TOPLEFT")
            topEdge:SetPoint("TOPRIGHT")
            local bottomEdge = CreateEdgeShadow(well, level, false)
            bottomEdge:SetPoint("BOTTOMLEFT")
            bottomEdge:SetPoint("BOTTOMRIGHT")
            -- Its arrows otherwise sit right at the ends, under the shadows.
            local bar = scroll.uiScrollBar
            if bar then
                bar:ClearAllPoints()
                bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, -28)
                bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 6, 28)
            end
        end
        -- By label as well: the pages below are found by name, not position.
        pages[i], scrolls[i] = page, scroll
        pages[sections[i].label], scrolls[sections[i].label] = page, scroll
    end

    -- A section always opens at its top, and is re-measured each time it comes
    -- up: what it shows can have changed since it was last looked at.
    f:OnTabSelected(function(index)
        UI.CancelColorPicker()
        local section = sections[index]
        f.section = section
        title.text:SetText(section.title)
        local color = section.color or { 1, 0.82, 0 }
        title.text:SetTextColor(color[1], color[2], color[3])
        title:SetSize(title.text:GetStringWidth(), title.text:GetStringHeight())
        f.currentScroll = scrolls[index]
        f.currentScroll:SetVerticalScroll(0)
        if section.OnShow then section.OnShow() end
        UI.FitScrollToContent(f.currentScroll)
    end)

    f.SelectSection = function(label)
        for i, section in ipairs(sections) do
            if section.label == label then f:SelectTab(i) return end
        end
    end

    -- ---- Roles ----
    -- Built by AllRolesView.lua, which owns the class list.
    WhoDoesWhat:BuildRolesSettingsPage(pages.Roles, scrolls.Roles)

    -- ---- General ----
    local generalPage = pages.General
    local yL = AddPageDivider(generalPage, y0, "Minimap & Tooltips")
    f.minimapCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        "Show minimap button",
        "Show a draggable WhoDoesWhat button on the minimap.",
        function(value)
            WhoDoesWhat.db.profile.settings.minimapButton.hide = not value
            WhoDoesWhat:UpdateMinimapButtonVisibility()
        end)
    f.unitTooltipCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        "Show roles in unit tooltips",
        "Add the player's assigned WhoDoesWhat role to Blizzard's unit tooltip "
            .. "when you hover a group member. Display only - nothing is "
            .. "scanned or sent.",
        function(value)
            WhoDoesWhat.db.profile.settings.unitTooltipRole = value
        end)
    f.unitTooltipDetailCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        "Show class details in unit tooltips",
        "Also append the summary the roster views show on hover: a Paladin's "
            .. "blessing talents and addon status, or a Warlock's Improved "
            .. "Healthstone. Only Paladins and Warlocks add anything.",
        function(value)
            WhoDoesWhat.db.profile.settings.unitTooltipDetail = value
        end)
    yL = AddNextPageDivider(generalPage, yL, "Raid Frames")
    f.raidFrameRoleCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
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

    local raidStyleLabel, raidStyleDD
    raidStyleLabel, raidStyleDD, yL = AddDropdownRow(generalPage, yL,
        "Raid frame style:", "WhoDoesWhatRaidFrameStyleDD")
    local raidStyleLabels = {
        corner = "Replace WoW Icon",
        band = "Left band",
        bandFaded = "Left band, faded",
        bandRight = "Right band",
        bandRightFaded = "Right band, faded",
    }
    f.raidStyleLabels = raidStyleLabels
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

    f.raidFrameCombatCheck, yL, f.raidFrameCombatLabel = AddCompactCheckboxRow(
        generalPage, PAGE_X, yL,
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
    yL = AddNextPageDivider(generalPage, yL, "Group Roles")
    f.announceRoleCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL, "Announce role changes in chat",
        "Post to raid/party chat when someone's role is changed. Turn off to keep role edits silent.",
        function(value)
            WhoDoesWhat.db.profile.settings.announceRoleChanges = value
            WhoDoesWhat:LogUiBuilding("Announce role changes " .. (value and "enabled." or "disabled."))
        end)
    f.manageBlizzRolesCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
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

    -- In the warlock class colour, like the Warlock Curses section it tunes.
    yL = AddNextPageDivider(generalPage, yL, "Warlock Curses", { 0.72, 0.45, 1 })
    local magicCurseLabel = IS_CLASSIC_ERA and "Auto assign elements and shadow"
        or "Auto assign Affliction to elements"
    local magicCurseDescription = IS_CLASSIC_ERA
        and "Let the Auto button fill Curse of the Elements and Curse of Shadow on separate warlocks."
        or "Auto-place Curse of the Elements on an Affliction warlock - on spec detection and via the Auto button."
    f.afflElementsCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL, magicCurseLabel,
        magicCurseDescription,
        function(value)
            WhoDoesWhat.db.profile.settings.autoAssignAfflictionElements = value
            local settingName = IS_CLASSIC_ERA and "Magic curse auto-assign"
                or "Auto-assign Affliction to Elements"
            WhoDoesWhat:LogUiBuilding(settingName .. " "
                .. (value and "enabled." or "disabled."))
        end)
    f.recklessnessCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL, "Allow recklessness auto-assign",
        "Let auto-assign fill Curse of Recklessness. It raises the boss's damage, so it can be risky.",
        function(value)
            WhoDoesWhat.db.profile.settings.allowRecklessnessAutoAssign = value
            WhoDoesWhat:LogUiBuilding("Recklessness auto-assign " .. (value and "enabled." or "disabled."))
        end)

    -- Every page's reset in one go, plus the custom role library. Roles already
    -- published to the raid and who holds which role are board state, not
    -- settings, so they stay.
    local resetAll = CreateFrame("Button", nil, generalPage, "UIPanelButtonTemplate")
    resetAll:SetSize(150, 22)
    resetAll:SetPoint("TOPLEFT", PAGE_X + 4, -(yL + 16))
    resetAll:SetText("Reset ALL Defaults")
    local RESET_ALL_DESCRIPTION = "Resets every settings page and deletes your"
        .. " custom role library. Custom roles already published to the raid, and"
        .. " who holds which role, are kept."
    resetAll:SetScript("OnClick", function()
        StaticPopup_Show("WHODOESWHAT_RESET_SETTINGS",
            "Reset ALL WhoDoesWhat settings to defaults?\n\n" .. RESET_ALL_DESCRIPTION,
            nil, function()
                ResetGeneral()
                WhoDoesWhat:ResetRolesSettingsPage()
                ResetStatusBars()
                ResetBuffTrackingPage(f)
                WhoDoesWhat:ResetPaladinBarSettings()
                WhoDoesWhat:ResetShoutBarSettings()
                ResetTesting()
                ResetDeveloper()
                WhoDoesWhat:RefreshMainAssignmentsView()
                WhoDoesWhat:RefreshBoardViews()
                LoadSettings(f)
            end)
    end)
    UI.AddTooltip(resetAll, "Reset ALL Defaults", RESET_ALL_DESCRIPTION)

    -- ---- Status Bars ----
    local statusPage = pages["Status Bars"]
    local statusIntro
    statusIntro, yL = AddPageIntro(statusPage, y0, "A compact window of bars"
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

    -- ---- Buff Tracking ----
    local statusBuffPage = pages.Buffs
    local buffScroll = scrolls.Buffs
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

    local headers = {
        { "Buff", 84, 155 }, { "Bars", 250, 44 },
        { "Buff Grid", 298, 62 }, { "Options", 364, 46 },
    }
    for _, header in ipairs(headers) do
        local text = buffWell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("TOPLEFT", CONTENT_X + header[2], -2)
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
    f.statusBuffListTop = 0
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
        row.up:SetScript("OnClick", function()
            MoveStatusBuff(f, rowKey, -1)
            OpenBuffOptions(f, rowKey)
        end)
        UI.AddTooltip(row.up, "Move up", "Move this row earlier in WDW Status.")
        row.down = UI.CreateArrowButton(row, "Down")
        row.down:SetPoint("LEFT", row.up, "RIGHT", 2, 0)
        row.down:SetScript("OnClick", function()
            MoveStatusBuff(f, rowKey, 1)
            OpenBuffOptions(f, rowKey)
        end)
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
        UI.AddTooltip(options, definition.name .. " options", "Show this row's options beside the table.")
        row.options = options
    end
    RefreshStatusBuffRows(f)
    -- The options view is part of the section, so it always shows a row: the
    -- first one until a cog picks another.
    f.buffTrackingWell = buffWell
    OpenBuffOptions(f, WhoDoesWhat:GetStatusBarCheckOrder()[1])

    -- ---- Paladin ----
    local paladinPage = pages["Paladin Bar"]
    local paladinIntro
    paladinIntro, yL = AddPageIntro(paladinPage, y0, "A clickable bar of your"
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

    -- ---- Warrior ----
    local warriorPage = pages["Warrior Bar"]
    local shoutIntro
    shoutIntro, yL = AddPageIntro(warriorPage, y0, "An efficient warrior"
        .. " buffing bar for shouts. Includes pets and ignores irrelevant party"
        .. " members based on WDW roles. Hover the bar and check the tooltips"
        .. " for additional info")

    yL = AddPageDivider(warriorPage, yL, "Bar")
    local shoutShowLabel, shoutShowDD
    shoutShowLabel, shoutShowDD, yL = AddDropdownRow(warriorPage, yL,
        "Show shout bar:", "WhoDoesWhatShoutBarShowDD")
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
                f.SetShoutControlsEnabled(mode.key ~= "never")
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
    -- Never is the shout bar's off switch.
    f.SetShoutControlsEnabled = PageControlSwitch(warriorPage,
        { shoutIntro, shoutShowLabel, shoutShowDD })

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
        "Countdown at:", "WhoDoesWhatShoutBarTimerDD")
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

    yL = AddNextPageDivider(warriorPage, yL, "Display")
    f.shoutHideBackgroundCheck, yL = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, "Hide background",
        "Leaves just the icons floating on your screen. Alt-drag still moves"
        .. " the bar.",
        function(value)
            WhoDoesWhat.db.profile.settings.shoutBarHideBackground = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    f.shoutHideNumbersCheck, yL = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, "Hide numbers",
        "Drops the count under each icon. The glow still tells you somebody is"
        .. " missing the shout, and the tooltip still names them.",
        function(value)
            WhoDoesWhat.db.profile.settings.shoutBarHideNumbers = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    f.shoutHideWhenBuffedCheck, yL = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, "Hide while everything is up",
        "Hides each icon while its own shout is on everybody, and brings it"
        .. " back the moment somebody loses it. Hidden icons can't be clicked"
        .. " or dragged, so place the bar before turning this on.",
        function(value)
            WhoDoesWhat.db.profile.settings.shoutBarHideWhenBuffed = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    f.shoutIgnoreRangeCheck, yL = AddCompactCheckboxRow(warriorPage,
        PAGE_X, yL, "Ignore players far out of range",
        "Stops counting party members who are nowhere near you. Anyone just a"
        .. " step too far back still counts, since stepping in is the fix.",
        function(value)
            WhoDoesWhat.db.profile.settings.shoutBarIgnoreOutOfRange = value
            WhoDoesWhat:RefreshWarriorShoutBar()
        end)

    local shoutSettings = WhoDoesWhat.db.profile.settings
    local shoutIconRange = WhoDoesWhat.SHOUT_BAR_ICON_SIZE
    f.RefreshShoutIconSize, yL = AddSliderWithInput(warriorPage, PAGE_X,
        yL, {
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
    yL = AddNextPageDivider(warriorPage, yL, "Highlight")
    f.RefreshShoutHighlight, yL = AddHighlightControls(warriorPage, PAGE_X,
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

    -- ---- Developer ----
    local developerPage = pages.Developer
    local yR = y0
    f.devModeCheck, yR = AddCompactCheckboxRow(developerPage, PAGE_X, yR, "Developer Mode",
        "Assignment dropdowns list every group member, not just the eligible class.",
        function(value)
            WhoDoesWhat.db.profile.settings.developerMode = value
            WhoDoesWhat:LogUiBuilding("Developer Mode " .. (value and "enabled." or "disabled."))
        end)
    f.showLogsCheck, yR = AddCompactCheckboxRow(developerPage, PAGE_X, yR, "Show Logs tab",
        "Show the combined WhoDoesWhat and PallyPower traffic logs as a tab in the main window.",
        function(value)
            WhoDoesWhat.db.profile.settings.showLogsButton = value
            WhoDoesWhat:RefreshMainAssignmentsView()
        end)
    f.logUiCheck, yR = AddCompactCheckboxRow(developerPage, PAGE_X, yR, "Log UI Updates",
        "Print verbose UI build and layout logging to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logUiUpdates = value
            WhoDoesWhat.LOG_UI_BUILDING = value
            WhoDoesWhat:LogUiBuilding("Log UI Updates " .. (value and "enabled." or "disabled."))
        end)
    f.logOperationsCheck, yR = AddCompactCheckboxRow(developerPage, PAGE_X, yR, "Log Operations",
        "Print routine assignment, reset, auto-assign, role, and whisper confirmations to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logOperations = value
            WhoDoesWhat.LOG_OPERATIONS = value
            WhoDoesWhat:LogUiBuilding("Log Operations " .. (value and "enabled." or "disabled."))
        end)
    f.logSyncStatusCheck, yR = AddCompactCheckboxRow(developerPage, PAGE_X, yR, "Log sync status",
        "Print automatic board updates, role syncs, and group-clear notices to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logSyncStatus = value
            WhoDoesWhat:LogUiBuilding("Log sync status " .. (value and "enabled." or "disabled."))
        end)
    f.logSyncTrafficCheck, yR = AddCompactCheckboxRow(developerPage, PAGE_X, yR, "Log sync details",
        "Capture WDW/PallyPower traffic and print WDW sync diagnostics to chat. Session-only; resets off on reload.",
        function(value)
            WhoDoesWhat:SetSyncLoggingEnabled(value)
            WhoDoesWhat:LogUiBuilding("Log sync details " .. (value and "enabled." or "disabled."))
        end)
    f.logBuffingClicksCheck, yR = AddCompactCheckboxRow(developerPage, PAGE_X, yR, "Log buffing bar clicks",
        "Print each recognized left/right buffing-bar click and its castable target count.",
        function(value)
            WhoDoesWhat.db.profile.settings.logBuffingBarClicks = value
            WhoDoesWhat:LogUiBuilding("Log buffing bar clicks "
                .. (value and "enabled." or "disabled."))
        end)
    f.logRolePromotionCheck, yR = AddCompactCheckboxRow(developerPage, PAGE_X, yR, "Log role/promotion flow",
        "Trace role picks, Blizzard role writes, promotion gating, Raid-tab opening, and row highlighting.",
        function(value)
            WhoDoesWhat.db.profile.settings.logRolePromotion = value
            WhoDoesWhat:LogUiBuilding("Log role/promotion flow "
                .. (value and "enabled." or "disabled."))
        end)
--@do-not-package@
    f.newerVersionTestCheck, yR = AddCompactCheckboxRow(developerPage, PAGE_X, yR,
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
    local testingPage = pages.Testing
    yR = y0
    f.fakeRaidCheck, yR = AddCompactCheckboxRow(testingPage, PAGE_X, yR, "Populate Fake Raid",
        "Fill the roster with 23 fake raiders to develop buff strategies solo. Wipes the assignment board on toggle.",
        function(value)
            WhoDoesWhat:SetFakeRaidEnabled(value)
            RefreshBuffingTestPaladinDropdown(f)
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end)

    local palLabel = testingPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    palLabel:SetPoint("TOPLEFT", PAGE_X + 4, -(yR + 6))
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

    f.buffingTestCheck, yR = AddCompactCheckboxRow(testingPage, PAGE_X, yR, "Show buffing bar as non-paladin",
        "Render the Paladin Buffing Bar even when you're not a paladin, as the paladin picked below (real or fake). Preview only.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarTestMode = value
            WhoDoesWhat:LogUiBuilding("Buffing bar test mode " .. (value and "enabled." or "disabled."))
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end)

    local testLabel = testingPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    testLabel:SetPoint("TOPLEFT", PAGE_X + 4, -(yR + 6))
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

    f:SelectTab(1)
    f:HookScript("OnHide", UI.CancelColorPicker)
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
    f.SetShoutControlsEnabled(shoutMode ~= "never")
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
-- bar). Selecting the page cancels any open colour picker, so the row is
-- picked after the window is on the right page.
function WhoDoesWhat:OpenBuffTrackingOptions(key)
    if not self.StatusBarChecks[key] then return end
    self:OpenAddonSettingsView("Buffs")
    OpenBuffOptions(settingsFrame, key)
end

function WhoDoesWhat:RefreshAddonSettingsLoggingCheck()
    if settingsFrame and settingsFrame.logSyncTrafficCheck then
        settingsFrame.logSyncTrafficCheck:SetChecked(self.LOG_SYNC)
    end
end
