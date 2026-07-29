local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Addon settings window. Checkbox state persists in db.profile.settings;
-- chat-log toggles also mirror into their runtime flags immediately so
-- logging reacts without a reload.

local settingsFrame = nil

local NAV_X = 14
local NAV_W = 104
local CONTENT_X = 134
local CONTENT_W = 410
local FRAME_W = 560
local FRAME_H = 512
--@do-not-package@
FRAME_H = 542
--@end-do-not-package@
local CHECKBOX_ROW_H = 52
local FIRST_PALADIN_LABEL = "(use first paladin)"
local IS_CLASSIC_ERA = WhoDoesWhat.ClientFeatures.isClassicEra
local STATUS_SCOPE_LABELS = {
    always = "Always", raid = "Raid Only", party = "Party Only",
}

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
        local enabled, neverHide, scope = WhoDoesWhat:GetStatusBarCheckOptions(key)
        row.enabled:SetChecked(enabled)
        row.neverHide:SetChecked(neverHide)
        UIDropDownMenu_SetText(row.scopeDD,
            STATUS_SCOPE_LABELS[scope] or STATUS_SCOPE_LABELS.always)
    end
end

local function SetStatusBuffOption(f, key, option, value)
    local settings = WhoDoesWhat.db.profile.settings
    settings.statusBarChecks = settings.statusBarChecks or {}
    settings.statusBarChecks[key] = settings.statusBarChecks[key] or {}
    settings.statusBarChecks[key][option] = value
    RefreshStatusBuffRows(f)
    WhoDoesWhat:RefreshStatusBarsView()
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
        "General", "Status Bars", "Status Buffs", "Paladin Bar",
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
        "Hide completed buffs",
        "Hide a status row once all of its required buffs are active.",
        function(value)
            WhoDoesWhat.db.profile.settings.overviewHideCompleted = value
            WhoDoesWhat:RefreshStatusBarsView()
        end)
    f.overviewRequireMaxRankCheck, yL = AddCheckboxRow(statusPage, CONTENT_X, yL,
        "Require max-ranked improved buffs",
        "Require the maximum improvement rank when any provider may have it. If every provider is confirmed untalented, the regular buff counts.",
        function(value)
            WhoDoesWhat.db.profile.settings.overviewRequireMaxRank = value
            WhoDoesWhat:RefreshStatusBarsView()
        end, 14)

    -- ---- Status Buffs ----
    local statusBuffPage = pages[3]
    yL = y0
    yL = AddHeading(statusBuffPage, CONTENT_X, yL, "Status Buffs", 0.96, 0.55, 0.73)
    local statusBuffDesc = statusBuffPage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusBuffDesc:SetPoint("TOPLEFT", CONTENT_X + 4, -yL)
    statusBuffDesc:SetWidth(CONTENT_W - 4)
    statusBuffDesc:SetJustifyH("LEFT")
    statusBuffDesc:SetTextColor(0.6, 0.6, 0.6)
    statusBuffDesc:SetText("Pick checks for WDW Status. Never Hide overrides Hide completed buffs; choose one group scope per row.")
    yL = yL + 38

    local headers = {
        { "Buff", 0, 160 }, { "Status Bars", 165, 60 },
        { "Never Hide", 225, 65 }, { "Show In", 296, 100 },
    }
    for _, header in ipairs(headers) do
        local text = statusBuffPage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("TOPLEFT", CONTENT_X + header[2], -yL)
        text:SetSize(header[3], 26)
        text:SetJustifyH(header[2] == 0 and "LEFT" or "CENTER")
        text:SetText(header[1])
    end
    yL = yL + 28
    f.statusBuffRows = {}
    for rowIndex, key in ipairs(WhoDoesWhat.StatusBarCheckOrder) do
        local rowKey = key
        local definition = WhoDoesWhat.StatusBarChecks[rowKey]
        local row = {}
        f.statusBuffRows[rowKey] = row

        local icon = statusBuffPage:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("TOPLEFT", CONTENT_X, -(yL + 3))
        icon:SetTexture(definition.icon)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        local name = statusBuffPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", icon, "RIGHT", 3, 0)
        name:SetWidth(150)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)
        name:SetText(definition.name)

        row.enabled = CreateFrame("CheckButton", nil, statusBuffPage, "UICheckButtonTemplate")
        row.enabled:SetSize(24, 24)
        row.enabled:SetPoint("TOPLEFT", CONTENT_X + 183, -yL)
        row.enabled:SetScript("OnClick", function(self)
            SetStatusBuffOption(f, rowKey, "enabled", self:GetChecked() and true or false)
        end)
        row.neverHide = CreateFrame("CheckButton", nil, statusBuffPage, "UICheckButtonTemplate")
        row.neverHide:SetSize(24, 24)
        row.neverHide:SetPoint("TOPLEFT", CONTENT_X + 246, -yL)
        row.neverHide:SetScript("OnClick", function(self)
            SetStatusBuffOption(f, rowKey, "neverHide", self:GetChecked() and true or false)
        end)
        row.scopeDD = CreateFrame("Frame", "WhoDoesWhatStatusBuffScopeDD" .. rowIndex,
            statusBuffPage, "UIDropDownMenuTemplate")
        row.scopeDD:SetPoint("LEFT", row.neverHide, "RIGHT", 8, 0)
        UIDropDownMenu_SetWidth(row.scopeDD, 100)
        UIDropDownMenu_Initialize(row.scopeDD, function(_, level)
            local _, _, saved = WhoDoesWhat:GetStatusBarCheckOptions(rowKey)
            for _, scope in ipairs({ "always", "raid", "party" }) do
                local scopeName = scope
                local info = UIDropDownMenu_CreateInfo()
                info.text = STATUS_SCOPE_LABELS[scopeName]
                info.checked = saved == scopeName
                info.func = function()
                    SetStatusBuffOption(f, rowKey, "scope", scopeName)
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        yL = yL + 32
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
        "Print detailed WhoDoesWhat addon-message diagnostics to chat. Traffic is always retained in Logs.",
        function(value)
            WhoDoesWhat.db.profile.settings.logSyncTraffic = value
            WhoDoesWhat.LOG_SYNC = value
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
    f.overviewRequireMaxRankCheck:SetChecked(settings.overviewRequireMaxRank)
    RefreshStatusBuffRows(f)
    f.devModeCheck:SetChecked(settings.developerMode)
    f.logUiCheck:SetChecked(settings.logUiUpdates)
    f.logOperationsCheck:SetChecked(settings.logOperations)
    f.logSyncStatusCheck:SetChecked(settings.logSyncStatus)
    f.logSyncTrafficCheck:SetChecked(settings.logSyncTraffic)
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
