local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local S = WhoDoesWhat.SettingsKit

-- Settings > Test + Dev: Fake Raid, the buffing bar preview, Developer Mode and
-- the logging switches.

local PAGE_X = S.PAGE_X
local AddCompactCheckboxRow = S.AddCompactCheckboxRow
local AddPageDivider = S.AddPageDivider
local AddNextPageDivider = S.AddNextPageDivider
local FIRST_PALADIN_LABEL = "(use first paladin)"
local RESET_TESTING = { "buffingBarTestMode", "buffingBarTestPaladin" }
local RESET_DEVELOPER = {
    "developerMode", "showLogsButton", "logUiUpdates", "logOperations",
    "logSyncStatus", "logBuffingBarClicks", "logRolePromotion",
    "simulateNewerAddonVersion",
}

-- The Settings frame the page was built into, for the sync-logging box.
local settingsFrame = nil

local function RefreshBuffingTestPaladinDropdown(f)
    WhoDoesWhat:GetBuffingBarTestPaladin()
    if f.buffingTestDD then
        UIDropDownMenu_SetText(f.buffingTestDD,
            WhoDoesWhat.db.profile.settings.buffingBarTestPaladin or FIRST_PALADIN_LABEL)
    end
end

-- Fake raid off first: that is what wipes the board, and with it off the
-- paladin count and size change without wiping it a second time.
local function ResetTesting()
    if WhoDoesWhat:IsFakeRaidEnabled() then WhoDoesWhat:SetFakeRaidEnabled(false) end
    WhoDoesWhat:SetFakeRaidPaladinCount(
        WhoDoesWhat.db.defaults.profile.settings.fakeRaidPaladinCount)
    WhoDoesWhat:SetFakeRaidSize(WhoDoesWhat.db.defaults.profile.settings.fakeRaidSize)
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

local function BuildTestDevPage(f, page)
    settingsFrame = f
    local testDevPage = page
    local yR = AddPageDivider(testDevPage, S.PAGE_TOP, "Testing")
    f.fakeRaidCheck, yR = AddCompactCheckboxRow(testDevPage, PAGE_X, yR, "Populate Fake Raid",
        "Fill the roster with fake raiders to develop buff strategies solo. Wipes the assignment board on toggle.",
        function(value)
            WhoDoesWhat:SetFakeRaidEnabled(value)
            RefreshBuffingTestPaladinDropdown(f)
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end)

    local sizeLabel = testDevPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sizeLabel:SetPoint("TOPLEFT", PAGE_X + 4, -(yR + 6))
    sizeLabel:SetText("Fake raiders:")
    local sizeDD = UI.CreateMenuDropdown(testDevPage, "WhoDoesWhatFakeRaidSizeDD", 40)
    sizeDD:SetPoint("LEFT", sizeLabel, "RIGHT", -8, -2)
    UIDropDownMenu_Initialize(sizeDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.fakeRaidSize
        for _, n in ipairs(WhoDoesWhat.FakeRaid.SIZES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = tostring(n)
            info.checked = (saved == n)
            info.func = function()
                WhoDoesWhat:SetFakeRaidSize(n)
                UIDropDownMenu_SetText(sizeDD, tostring(n))
                RefreshBuffingTestPaladinDropdown(f)
                WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.fakeRaidSizeDD = sizeDD
    yR = yR + 40

    local palLabel = testDevPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    palLabel:SetPoint("TOPLEFT", PAGE_X + 4, -(yR + 6))
    palLabel:SetText("Fake paladins:")
    local palDD = UI.CreateMenuDropdown(testDevPage, "WhoDoesWhatFakePaladinCountDD", 40)
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

    f.buffingTestCheck, yR = AddCompactCheckboxRow(testDevPage, PAGE_X, yR, "Show buffing bar as non-paladin",
        "Render the Paladin Buffing Bar even when you're not a paladin, as the paladin picked below (real or fake). Preview only.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarTestMode = value
            WhoDoesWhat:LogUiBuilding("Buffing bar test mode " .. (value and "enabled." or "disabled."))
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end)

    local testLabel = testDevPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    testLabel:SetPoint("TOPLEFT", PAGE_X + 4, -(yR + 6))
    testLabel:SetText("Test as paladin:")
    local testDD = UI.CreateMenuDropdown(testDevPage, "WhoDoesWhatBuffingTestPaladinDD", 120)
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
    yR = yR + 40

    yR = AddNextPageDivider(testDevPage, yR, "Developer")
    f.devModeCheck, yR = AddCompactCheckboxRow(testDevPage, PAGE_X, yR, "Developer Mode",
        "Assignment dropdowns list every group member, not just the eligible class.",
        function(value)
            WhoDoesWhat.db.profile.settings.developerMode = value
            WhoDoesWhat:LogUiBuilding("Developer Mode " .. (value and "enabled." or "disabled."))
        end)
    f.showLogsCheck, yR = AddCompactCheckboxRow(testDevPage, PAGE_X, yR, "Show Logs tab",
        "Show the combined WhoDoesWhat and PallyPower traffic logs as a tab in the main window.",
        function(value)
            WhoDoesWhat.db.profile.settings.showLogsButton = value
            WhoDoesWhat:RefreshMainAssignmentsView()
        end)
    f.logUiCheck, yR = AddCompactCheckboxRow(testDevPage, PAGE_X, yR, "Log UI Updates",
        "Print verbose UI build and layout logging to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logUiUpdates = value
            WhoDoesWhat.LOG_UI_BUILDING = value
            WhoDoesWhat:LogUiBuilding("Log UI Updates " .. (value and "enabled." or "disabled."))
        end)
    f.logOperationsCheck, yR = AddCompactCheckboxRow(testDevPage, PAGE_X, yR, "Log Operations",
        "Print routine assignment, reset, auto-assign, role, and whisper confirmations to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logOperations = value
            WhoDoesWhat.LOG_OPERATIONS = value
            WhoDoesWhat:LogUiBuilding("Log Operations " .. (value and "enabled." or "disabled."))
        end)
    f.logSyncStatusCheck, yR = AddCompactCheckboxRow(testDevPage, PAGE_X, yR, "Log sync status",
        "Print automatic board updates, role syncs, and group-clear notices to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logSyncStatus = value
            WhoDoesWhat:LogUiBuilding("Log sync status " .. (value and "enabled." or "disabled."))
        end)
    f.logSyncTrafficCheck, yR = AddCompactCheckboxRow(testDevPage, PAGE_X, yR, "Log sync details",
        "Capture WDW/PallyPower traffic and print WDW sync diagnostics to chat. Session-only; resets off on reload.",
        function(value)
            WhoDoesWhat:SetSyncLoggingEnabled(value)
            WhoDoesWhat:LogUiBuilding("Log sync details " .. (value and "enabled." or "disabled."))
        end)
    f.logBuffingClicksCheck, yR = AddCompactCheckboxRow(testDevPage, PAGE_X, yR, "Log buffing bar clicks",
        "Print each recognized left/right buffing-bar click and its castable target count.",
        function(value)
            WhoDoesWhat.db.profile.settings.logBuffingBarClicks = value
            WhoDoesWhat:LogUiBuilding("Log buffing bar clicks "
                .. (value and "enabled." or "disabled."))
        end)
    f.logRolePromotionCheck, yR = AddCompactCheckboxRow(testDevPage, PAGE_X, yR, "Log role/promotion flow",
        "Trace role picks, Blizzard role writes, promotion gating, Raid-tab opening, and row highlighting.",
        function(value)
            WhoDoesWhat.db.profile.settings.logRolePromotion = value
            WhoDoesWhat:LogUiBuilding("Log role/promotion flow "
                .. (value and "enabled." or "disabled."))
        end)
--@do-not-package@
    f.newerVersionTestCheck, yR = AddCompactCheckboxRow(testDevPage, PAGE_X, yR,
        "|cffff2020Simulate newer addon version|r",
        "|cffff2020WARNING: This feature should never be turned on. It falsely reports the next addon version to your group.|r",
        function(value)
            WhoDoesWhat.db.profile.settings.simulateNewerAddonVersion = value
            WhoDoesWhat:RefreshMainAssignmentsView()
            WhoDoesWhat:LogUiBuilding("Addon version simulation "
                .. (value and "enabled." or "disabled."))
        end)
--@end-do-not-package@
end

local function RefreshTestDevPage(f)
    local self = WhoDoesWhat
    local settings = self.db.profile.settings
    f.buffingTestCheck:SetChecked(settings.buffingBarTestMode)
    RefreshBuffingTestPaladinDropdown(f)
    f.devModeCheck:SetChecked(settings.developerMode)
    f.showLogsCheck:SetChecked(settings.showLogsButton)
    f.logUiCheck:SetChecked(settings.logUiUpdates)
    f.logOperationsCheck:SetChecked(settings.logOperations)
    f.logSyncStatusCheck:SetChecked(settings.logSyncStatus)
    f.logSyncTrafficCheck:SetChecked(self.LOG_SYNC)
    f.logBuffingClicksCheck:SetChecked(settings.logBuffingBarClicks)
    f.logRolePromotionCheck:SetChecked(settings.logRolePromotion)
--@do-not-package@
    f.newerVersionTestCheck:SetChecked(settings.simulateNewerAddonVersion)
--@end-do-not-package@
    f.fakeRaidCheck:SetChecked(settings.populateFakeRaid)
    UIDropDownMenu_SetText(f.fakeRaidSizeDD, tostring(settings.fakeRaidSize))
    UIDropDownMenu_SetText(f.fakePaladinDD, tostring(settings.fakeRaidPaladinCount or 3))
end

S.RegisterPage({
    label = "Test + Dev", title = "Test + Dev", right = true,
    description = "Turns the fake raid and the buffing bar preview off,"
        .. " and Developer Mode, the Logs tab and every logging option"
        .. " with them.",
    Build = BuildTestDevPage,
    Refresh = RefreshTestDevPage,
    Reset = function()
        ResetTesting()
        ResetDeveloper()
    end,
})

function WhoDoesWhat:RefreshAddonSettingsLoggingCheck()
    if settingsFrame and settingsFrame.logSyncTrafficCheck then
        settingsFrame.logSyncTrafficCheck:SetChecked(self.LOG_SYNC)
    end
end
