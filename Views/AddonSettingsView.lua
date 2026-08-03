local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

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
--@do-not-package@
FRAME_H = 594
--@end-do-not-package@
local CHECKBOX_ROW_H = 52
local FIRST_PALADIN_LABEL = "(use first paladin)"
local IS_CLASSIC_ERA = WhoDoesWhat.ClientFeatures.isClassicEra
local STATUS_SCOPE_LABELS = {
    always = "Always", raid = "Raid Only", party = "Party Only",
}
local STATUS_DISPLAY_LABELS = { percent = "Percent", missing = "Missing Count" }
local OPTIONS_BUTTON = "Interface\\AddOns\\WhoDoesWhat\\Media\\UI-Panel-OptionsButton-"

local function RefreshBuffingTestPaladinDropdown(f)
    WhoDoesWhat:GetBuffingBarTestPaladin()
    if f.buffingTestDD then
        UIDropDownMenu_SetText(f.buffingTestDD,
            WhoDoesWhat.db.profile.settings.buffingBarTestPaladin or FIRST_PALADIN_LABEL)
    end
end

-- Checkbox at column origin `x`, label beside it, gray wrapped description
-- underneath. `apply` writes the new boolean. Returns the checkbox and the y
-- below the row; long descriptions (3+ lines) pass `extra` to reserve room.
local function AddCheckboxRow(f, x, y, labelText, descText, apply, extra)
    local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("TOPLEFT", x, -y)
    check:SetScript("OnClick", function(self)
        apply(self:GetChecked() and true or false)
    end)

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", check, "RIGHT", 2, 0)
    label:SetText(labelText)

    local desc = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", check, "BOTTOMLEFT", 26, 2)
    desc:SetWidth(CONTENT_W - 26 - (x - CONTENT_X))
    desc:SetJustifyH("LEFT")
    desc:SetTextColor(0.6, 0.6, 0.6)
    desc:SetText(descText)

    return check, y + CHECKBOX_ROW_H + (extra or 0)
end

-- Section heading at column origin `x`. Returns the y below it.
local function AddHeading(f, x, y, text, r, g, b)
    local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    h:SetPoint("TOPLEFT", x, -y)
    h:SetText(text)
    if r then h:SetTextColor(r, g, b) end
    return y + 28
end

local function RefreshStatusBuffRows(f)
    for key, row in pairs(f.statusBuffRows or {}) do
        local options = WhoDoesWhat:GetStatusBarCheckOptions(key)
        row.bar:SetChecked(options.bar)
        row.grid:SetChecked(options.grid)
        row.grid:SetEnabled(not WhoDoesWhat.StatusBarChecks[key].gridOptionDisabled)
    end
end

local function SetStatusBuffOption(f, key, option, value)
    local settings = WhoDoesWhat.db.profile.settings
    settings.statusBarChecks = settings.statusBarChecks or {}
    settings.statusBarChecks[key] = settings.statusBarChecks[key] or {}
    settings.statusBarChecks[key][option] = value
    RefreshStatusBuffRows(f)
    WhoDoesWhat:RefreshBuffingGridView()
end

local function SetOptionAvailable(check, label, available)
    check:SetEnabled(available)
    label:SetTextColor(available and 1 or 0.45,
        available and 1 or 0.45, available and 1 or 0.45)
end

local function RefreshBuffOptionsFrame()
    local f = buffOptionsFrame
    if not f or not f.buffKey then return end
    local definition = WhoDoesWhat.StatusBarChecks[f.buffKey]
    local options = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey)
    f.titleText:SetText("Buff Tracking - " .. definition.name)
    f.buffIcon:SetTexture(definition.icon)
    f.buffName:SetText(definition.name)
    UIDropDownMenu_SetText(f.scopeDD,
        STATUS_SCOPE_LABELS[options.scope] or STATUS_SCOPE_LABELS.always)
    UIDropDownMenu_SetText(f.displayDD,
        STATUS_DISPLAY_LABELS[options.display] or STATUS_DISPLAY_LABELS.percent)
    UIDropDownMenu_SetText(f.backgroundDD,
        WhoDoesWhat.StatusBarBackgrounds[options.background].name)
    for option, check in pairs(f.optionChecks) do
        check:SetChecked(options[option])
    end
    SetOptionAvailable(f.optionChecks.negative,
        f.optionLabels.negative, not definition.gridOptionDisabled)
    SetOptionAvailable(f.optionChecks.includeUnimproved,
        f.optionLabels.includeUnimproved, definition.improvedTalent ~= nil)
    SetOptionAvailable(f.optionChecks.hunterPets,
        f.optionLabels.hunterPets, not definition.hunterPetsOptionDisabled)
end

local function EnsureBuffOptionsFrame(owner)
    if buffOptionsFrame then return buffOptionsFrame end
    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatBuffTrackingOptionsFrame",
        360, 400, "Buff Tracking")
    f:ClearAllPoints()
    f:SetPoint("CENTER", owner, "CENTER", 90, 0)

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28)
    icon:SetPoint("TOPLEFT", 20, -(f.titleBarHeight + 18))
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.buffIcon = icon
    local name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    f.buffName = name

    local scopeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    scopeLabel:SetPoint("TOPLEFT", 24, -(f.titleBarHeight + 67))
    scopeLabel:SetText("Show in")
    local scopeDD = CreateFrame("Frame", "WhoDoesWhatBuffTrackingScopeDD", f,
        "UIDropDownMenuTemplate")
    scopeDD:SetPoint("LEFT", scopeLabel, "RIGHT", 14, -2)
    UIDropDownMenu_SetWidth(scopeDD, 120)
    WhoDoesWhat:StyleDropdown(scopeDD)
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

    local displayLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    displayLabel:SetPoint("TOPLEFT", 24, -(f.titleBarHeight + 103))
    displayLabel:SetText("Display")
    local displayDD = CreateFrame("Frame", "WhoDoesWhatBuffTrackingDisplayDD", f,
        "UIDropDownMenuTemplate")
    displayDD:SetPoint("LEFT", displayLabel, "RIGHT", 16, -2)
    UIDropDownMenu_SetWidth(displayDD, 120)
    WhoDoesWhat:StyleDropdown(displayDD)
    UIDropDownMenu_Initialize(displayDD, function(_, level)
        local saved = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey).display
        for _, display in ipairs({ "percent", "missing" }) do
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

    local backgroundLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    backgroundLabel:SetPoint("TOPLEFT", 24, -(f.titleBarHeight + 139))
    backgroundLabel:SetText("Background color")
    local backgroundDD = CreateFrame("Frame", "WhoDoesWhatBuffTrackingBackgroundDD", f,
        "UIDropDownMenuTemplate")
    backgroundDD:SetPoint("LEFT", backgroundLabel, "RIGHT", 10, -2)
    UIDropDownMenu_SetWidth(backgroundDD, 120)
    WhoDoesWhat:StyleDropdown(backgroundDD)
    UIDropDownMenu_Initialize(backgroundDD, function(_, level)
        local saved = WhoDoesWhat:GetStatusBarCheckOptions(f.buffKey).background
        for _, background in ipairs(WhoDoesWhat.StatusBarBackgroundOrder) do
            local backgroundName = background
            local info = UIDropDownMenu_CreateInfo()
            info.text = WhoDoesWhat.StatusBarBackgrounds[backgroundName].name
            info.checked = saved == backgroundName
            info.func = function()
                SetStatusBuffOption(owner, f.buffKey, "background", backgroundName)
                RefreshBuffOptionsFrame()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.backgroundDD = backgroundDD

    f.optionChecks, f.optionLabels = {}, {}
    local checkboxOptions = {
        { "negative", "Negative debuff" },
        { "hideComplete", "Hide Bar when complete" },
        { "includeUnimproved", "Include unimproved in progress" },
        { "onlyManaUsers", "Only for mana-users" },
        { "onlyTanks", "Only for tanks" },
        { "hunterPets", "Used by hunter pets" },
    }
    for index, entry in ipairs(checkboxOptions) do
        local option, labelText = entry[1], entry[2]
        local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        check:SetSize(24, 24)
        check:SetPoint("TOPLEFT", 20,
            -(f.titleBarHeight + 173 + (index - 1) * 31))
        check:SetScript("OnClick", function(self)
            SetStatusBuffOption(owner, f.buffKey, option,
                self:GetChecked() and true or false)
            RefreshBuffOptionsFrame()
        end)
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", check, "RIGHT", 3, 0)
        label:SetText(labelText)
        f.optionChecks[option] = check
        f.optionLabels[option] = label
    end

    buffOptionsFrame = f
    return f
end

local function OpenBuffOptions(owner, key)
    local f = EnsureBuffOptionsFrame(owner)
    f.buffKey = key
    RefreshBuffOptionsFrame()
    f:Show()
    f:Raise()
end

local function ResetBuffTrackingPage(f)
    wipe(WhoDoesWhat.db.profile.settings.statusBarChecks)
    RefreshStatusBuffRows(f)
    RefreshBuffOptionsFrame()
    WhoDoesWhat:RefreshBuffingGridView()
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
        for i, page in ipairs(pages) do
            if i == index then page:Show() else page:Hide() end
            if i == index then buttons[i]:LockHighlight() else buttons[i]:UnlockHighlight() end
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
    f.announceRoleCheck, yL = AddCheckboxRow(generalPage, CONTENT_X, yL, "Announce role changes in chat",
        "Post to raid/party chat when someone's role is changed. Turn off to keep role edits silent.",
        function(value)
            WhoDoesWhat.db.profile.settings.announceRoleChanges = value
            WhoDoesWhat:LogUiBuilding("Announce role changes " .. (value and "enabled." or "disabled."))
        end)

    -- ---- Status Bars ----
    local statusPage = pages[2]
    yL = y0
    yL = AddHeading(statusPage, CONTENT_X, yL, "Status Bars", 0.96, 0.55, 0.73)
    f.overviewCheck, yL = AddCheckboxRow(statusPage, CONTENT_X, yL, "Enable WDW Status",
        "Show live paladin and core raid-buff coverage. Alt-drag to move; Alt-drag its marked edge to resize.",
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
    WhoDoesWhat:StyleDropdown(anchorDD)
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
    local anchorDesc = statusPage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    anchorDesc:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 28))
    anchorDesc:SetWidth(CONTENT_W - 4)
    anchorDesc:SetJustifyH("LEFT")
    anchorDesc:SetTextColor(0.6, 0.6, 0.6)
    anchorDesc:SetText("The window grows away from this corner as rows or width change.")
    f.overviewAnchorDD = anchorDD
    f.overviewAnchorLabels = anchorLabels
    yL = yL + 58
    f.overviewPallyPowerCheck, yL = AddCheckboxRow(statusPage, CONTENT_X, yL,
        "Show PallyPower desync row",
        "Show PallyPower sync status and its Diff/Fix actions at the top of WDW Status.",
        function(value)
            WhoDoesWhat.db.profile.settings.overviewShowPallyPower = value
            f.overviewPallyPowerOnlyDesyncedCheck:SetEnabled(value)
            WhoDoesWhat:RefreshStatusBarsView()
        end)
    f.overviewPallyPowerOnlyDesyncedCheck, yL = AddCheckboxRow(statusPage,
        CONTENT_X + 24, yL, "Only while desynced",
        "Hide the PallyPower row while it is synced or inactive; show it when differences need attention.",
        function(value)
            WhoDoesWhat.db.profile.settings.overviewPallyPowerOnlyDesynced = value
            WhoDoesWhat:RefreshStatusBarsView()
        end)
    f.overviewHideCompletedCheck, yL = AddCheckboxRow(statusPage, CONTENT_X, yL,
        "Hide completed paladin bars",
        "Hide a paladin's status row once all of their assigned buffs are active.",
        function(value)
            WhoDoesWhat.db.profile.settings.overviewHideCompleted = value
            WhoDoesWhat:RefreshStatusBarsView()
        end)

    -- ---- Buff Tracking ----
    local statusBuffPage = pages[3]
    yL = y0
    yL = AddHeading(statusBuffPage, CONTENT_X, yL, "Buff Tracking", 0.96, 0.55, 0.73)
    local resetBuffs = CreateFrame("Button", nil, statusBuffPage, "UIPanelButtonTemplate")
    resetBuffs:SetSize(100, 22)
    resetBuffs:SetPoint("TOPRIGHT", statusBuffPage, "TOPRIGHT", -16, -(y0 - 2))
    resetBuffs:SetText("Reset Defaults")
    resetBuffs:SetScript("OnClick", function() ResetBuffTrackingPage(f) end)
    local statusBuffDesc = statusBuffPage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusBuffDesc:SetPoint("TOPLEFT", CONTENT_X + 4, -yL)
    statusBuffDesc:SetWidth(CONTENT_W - 4)
    statusBuffDesc:SetJustifyH("LEFT")
    statusBuffDesc:SetTextColor(0.6, 0.6, 0.6)
    statusBuffDesc:SetText("Choose where each check appears. Use the cog for display, scope, and target options.")
    yL = yL + 38

    local headers = {
        { "Buff", 4, 235 }, { "Bars", 250, 44 },
        { "Buff Grid", 298, 62 }, { "Options", 364, 46 },
    }
    for _, header in ipairs(headers) do
        local text = statusBuffPage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("TOPLEFT", CONTENT_X + header[2], -yL)
        text:SetSize(header[3], 26)
        text:SetJustifyH(header[1] == "Buff" and "LEFT" or "CENTER")
        text:SetText(header[1])
    end
    yL = yL + 28
    f.statusBuffRows = {}
    for rowIndex, key in ipairs(WhoDoesWhat.StatusBarCheckOrder) do
        local rowKey = key
        local definition = WhoDoesWhat.StatusBarChecks[rowKey]
        local row = CreateFrame("Frame", nil, statusBuffPage)
        row:SetPoint("TOPLEFT", CONTENT_X, -yL)
        row:SetSize(CONTENT_W, 26)
        f.statusBuffRows[rowKey] = row

        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        local shade = rowIndex % 2 == 1 and 0.18 or 0.10
        stripe:SetColorTexture(shade, shade, shade + 0.02, 0.72)

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", 5, 0)
        icon:SetTexture(definition.icon)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", icon, "RIGHT", 7, 0)
        name:SetWidth(210)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)
        name:SetText(definition.name)

        row.bar = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.bar:SetSize(24, 24)
        row.bar:SetPoint("CENTER", row, "LEFT", 272, 0)
        row.bar:SetScript("OnClick", function(self)
            SetStatusBuffOption(f, rowKey, "bar", self:GetChecked() and true or false)
        end)
        row.grid = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.grid:SetSize(24, 24)
        row.grid:SetPoint("CENTER", row, "LEFT", 329, 0)
        row.grid:SetScript("OnClick", function(self)
            SetStatusBuffOption(f, rowKey, "grid", self:GetChecked() and true or false)
        end)
        local options = CreateFrame("Button", nil, row)
        options:SetSize(24, 24)
        options:SetPoint("CENTER", row, "LEFT", 387, 0)
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
            GameTooltip:Show()
        end)
        options:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.options = options
        yL = yL + 26
    end
    RefreshStatusBuffRows(f)

    -- ---- Paladin ----
    local paladinPage = pages[4]
    yL = y0
    yL = AddHeading(paladinPage, CONTENT_X, yL, "Paladin Buffing Bar", 0.96, 0.55, 0.73)

    f.buffingBarCheck, yL = AddCheckboxRow(paladinPage, CONTENT_X, yL, "Enable Paladin Buffing Bar",
        "Show a movable, clickable bar of your assigned blessings - a Nova-style alternative to PallyPower. Appears only when you're a paladin, unless test mode is on.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarEnabled = value
            WhoDoesWhat:LogUiBuilding("Paladin Buffing Bar " .. (value and "enabled." or "disabled."))
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end, 14)

    local growLabel = paladinPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    growLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yL + 4))
    growLabel:SetText("Bar grows:")
    local growLabels = { RIGHT = "Right", LEFT = "Left" }
    local growDD = CreateFrame("Frame", "WhoDoesWhatBuffingGrowDD", paladinPage, "UIDropDownMenuTemplate")
    growDD:SetPoint("LEFT", growLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(growDD, 80)
    WhoDoesWhat:StyleDropdown(growDD)
    UIDropDownMenu_Initialize(growDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.buffingBarGrow or "RIGHT"
        for _, mode in ipairs({ "RIGHT", "LEFT" }) do
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
    WhoDoesWhat:StyleDropdown(menuGrowDD)
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

    f.buffingMenuExpiringCheck, yL = AddCheckboxRow(paladinPage, CONTENT_X, yL + 68,
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
    f.afflElementsCheck, yL = AddCheckboxRow(warlockPage, CONTENT_X, yL, magicCurseLabel,
        magicCurseDescription,
        function(value)
            WhoDoesWhat.db.profile.settings.autoAssignAfflictionElements = value
            local settingName = IS_CLASSIC_ERA and "Magic curse auto-assign"
                or "Auto-assign Affliction to Elements"
            WhoDoesWhat:LogUiBuilding(settingName .. " "
                .. (value and "enabled." or "disabled."))
        end)
    f.recklessnessCheck, yL = AddCheckboxRow(warlockPage, CONTENT_X, yL, "Allow recklessness auto-assign",
        "Let auto-assign fill Curse of Recklessness. It raises the boss's damage, so it can be risky.",
        function(value)
            WhoDoesWhat.db.profile.settings.allowRecklessnessAutoAssign = value
            WhoDoesWhat:LogUiBuilding("Recklessness auto-assign " .. (value and "enabled." or "disabled."))
        end)

    -- ---- Developer ----
    local developerPage = pages[7]
    local yR = y0
    yR = AddHeading(developerPage, CONTENT_X, yR, "Developer Options")
    f.devModeCheck, yR = AddCheckboxRow(developerPage, CONTENT_X, yR, "Developer Mode",
        "Assignment dropdowns list every group member, not just the eligible class.",
        function(value)
            WhoDoesWhat.db.profile.settings.developerMode = value
            WhoDoesWhat:LogUiBuilding("Developer Mode " .. (value and "enabled." or "disabled."))
        end)
    f.showLogsCheck, yR = AddCheckboxRow(developerPage, CONTENT_X, yR, "Show Logs button",
        "Show the combined WhoDoesWhat and PallyPower traffic-log button on the assignment window.",
        function(value)
            WhoDoesWhat.db.profile.settings.showLogsButton = value
            WhoDoesWhat:RefreshMainAssignmentsView()
        end)
    f.logUiCheck, yR = AddCheckboxRow(developerPage, CONTENT_X, yR, "Log UI Updates",
        "Print verbose UI build and layout logging to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logUiUpdates = value
            WhoDoesWhat.LOG_UI_BUILDING = value
            WhoDoesWhat:LogUiBuilding("Log UI Updates " .. (value and "enabled." or "disabled."))
        end)
    f.logOperationsCheck, yR = AddCheckboxRow(developerPage, CONTENT_X, yR, "Log Operations",
        "Print routine assignment, reset, auto-assign, role, and whisper confirmations to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logOperations = value
            WhoDoesWhat.LOG_OPERATIONS = value
            WhoDoesWhat:LogUiBuilding("Log Operations " .. (value and "enabled." or "disabled."))
        end)
    f.logSyncStatusCheck, yR = AddCheckboxRow(developerPage, CONTENT_X, yR, "Log sync status",
        "Print automatic board updates, role syncs, and group-clear notices to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logSyncStatus = value
            WhoDoesWhat:LogUiBuilding("Log sync status " .. (value and "enabled." or "disabled."))
        end)
    f.logSyncTrafficCheck, yR = AddCheckboxRow(developerPage, CONTENT_X, yR, "Log sync details",
        "Capture WDW/PallyPower traffic and print WDW sync diagnostics to chat. Session-only; resets off on reload.",
        function(value)
            WhoDoesWhat:SetSyncLoggingEnabled(value)
            WhoDoesWhat:LogUiBuilding("Log sync details " .. (value and "enabled." or "disabled."))
        end, 14)
    f.logBuffingClicksCheck, yR = AddCheckboxRow(developerPage, CONTENT_X, yR, "Log buffing bar clicks",
        "Print each recognized left/right buffing-bar click and its castable target count.",
        function(value)
            WhoDoesWhat.db.profile.settings.logBuffingBarClicks = value
            WhoDoesWhat:LogUiBuilding("Log buffing bar clicks "
                .. (value and "enabled." or "disabled."))
        end)
    f.logRolePromotionCheck, yR = AddCheckboxRow(developerPage, CONTENT_X, yR, "Log role/promotion flow",
        "Trace role picks, Blizzard role writes, promotion gating, Raid-tab opening, and row highlighting.",
        function(value)
            WhoDoesWhat.db.profile.settings.logRolePromotion = value
            WhoDoesWhat:LogUiBuilding("Log role/promotion flow "
                .. (value and "enabled." or "disabled."))
        end, 14)
--@do-not-package@
    f.newerVersionTestCheck, yR = AddCheckboxRow(developerPage, CONTENT_X, yR,
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
    f.fakeRaidCheck, yR = AddCheckboxRow(testingPage, CONTENT_X, yR, "Populate Fake Raid",
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
    WhoDoesWhat:StyleDropdown(palDD)
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

    f.buffingTestCheck, yR = AddCheckboxRow(testingPage, CONTENT_X, yR, "Show buffing bar as non-paladin",
        "Render the Paladin Buffing Bar even when you're not a paladin, as the paladin picked below (real or fake). Preview only.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarTestMode = value
            WhoDoesWhat:LogUiBuilding("Buffing bar test mode " .. (value and "enabled." or "disabled."))
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end, 14)

    local testLabel = testingPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    testLabel:SetPoint("TOPLEFT", CONTENT_X + 4, -(yR + 6))
    testLabel:SetText("Test as paladin:")
    local testDD = CreateFrame("Frame", "WhoDoesWhatBuffingTestPaladinDD", testingPage, "UIDropDownMenuTemplate")
    testDD:SetPoint("LEFT", testLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(testDD, 120)
    WhoDoesWhat:StyleDropdown(testDD)
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
    settingsFrame = f
    return f
end

-- Toggle the settings window open/closed, loading checkbox state from the DB.
function WhoDoesWhat:OpenAddonSettingsView()
    local f = EnsureSettingsFrame()

    if f:IsShown() then
        self:LogUiBuilding("Addon Settings View open, closing it.")
        f:Hide()
        return
    end

    local settings = self.db.profile.settings
    f.buffingBarCheck:SetChecked(settings.buffingBarEnabled)
    UIDropDownMenu_SetText(f.buffingGrowDD, settings.buffingBarGrow == "LEFT" and "Left" or "Right")
    UIDropDownMenu_SetText(f.buffingMenuGrowDD,
        settings.buffingMenuGrow == "UP" and "Up" or "Down")
    f.buffingMenuExpiringCheck:SetChecked(settings.buffingMenuWarnExpiring)
    f.buffingTestCheck:SetChecked(settings.buffingBarTestMode)
    RefreshBuffingTestPaladinDropdown(f)
    f.announceRoleCheck:SetChecked(settings.announceRoleChanges)
    f.overviewCheck:SetChecked(settings.overviewEnabled)
    local overviewAnchor = settings.overviewAnchor or "TOPLEFT"
    UIDropDownMenu_SetText(f.overviewAnchorDD,
        f.overviewAnchorLabels[overviewAnchor] or f.overviewAnchorLabels.TOPLEFT)
    f.overviewPallyPowerCheck:SetChecked(settings.overviewShowPallyPower)
    f.overviewPallyPowerOnlyDesyncedCheck:SetChecked(
        settings.overviewPallyPowerOnlyDesynced)
    f.overviewPallyPowerOnlyDesyncedCheck:SetEnabled(
        settings.overviewShowPallyPower ~= false)
    f.overviewHideCompletedCheck:SetChecked(settings.overviewHideCompleted)
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

    self:LogUiBuilding("Opening Addon Settings View...")
    f:Show()
    f:Raise()
end

function WhoDoesWhat:RefreshAddonSettingsLoggingCheck()
    if settingsFrame and settingsFrame.logSyncTrafficCheck then
        settingsFrame.logSyncTrafficCheck:SetChecked(self.LOG_SYNC)
    end
end
