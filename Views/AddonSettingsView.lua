local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Addon settings window. A stub for now: just the Developer Options section.
-- Checkbox state persists in db.profile.settings; "Log UI Updates" also
-- mirrors into WhoDoesWhat.LOG_UI_BUILDING immediately so logging reacts
-- without a reload.

local settingsFrame = nil

local MARGIN = 14
local COL_W = 290           -- content width of one column
local COL_GAP = 14
local COL_L = MARGIN
local COL_R = MARGIN + COL_W + COL_GAP
local FRAME_W = COL_R + COL_W + MARGIN
local FRAME_H = 480
local CHECKBOX_ROW_H = 52

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
    desc:SetWidth(COL_W - 26)
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

-- Build the settings window once and reuse it. Two columns: left holds Buffing
-- Bar / General / Warlock Curses, right holds Developer Options.
local function EnsureSettingsFrame()
    if settingsFrame then return settingsFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatSettingsFrame", FRAME_W, FRAME_H, "WhoDoesWhat - Settings")
    local y0 = f.titleBarHeight + 14

    -- ---- Left column ----
    local yL = y0
    yL = AddHeading(f, COL_L, yL, "Paladin Buffing Bar", 0.96, 0.55, 0.73)

    f.buffingBarCheck, yL = AddCheckboxRow(f, COL_L, yL, "Enable Paladin Buffing Bar",
        "Show a movable, clickable bar of your assigned blessings - a Nova-style alternative to PallyPower. Appears only when you're a paladin, unless test mode is on.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarEnabled = value
            WhoDoesWhat:Print("Paladin Buffing Bar " .. (value and "enabled." or "disabled."))
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end, 14)

    local growLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    growLabel:SetPoint("TOPLEFT", COL_L + 4, -(yL + 4))
    growLabel:SetText("Bar grows:")
    local GROW_LABELS = { RIGHT = "Right", LEFT = "Left" }
    local growDD = CreateFrame("Frame", "WhoDoesWhatBuffingGrowDD", f, "UIDropDownMenuTemplate")
    growDD:SetPoint("LEFT", growLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(growDD, 80)
    UIDropDownMenu_Initialize(growDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.buffingBarGrow or "RIGHT"
        for _, mode in ipairs({ "RIGHT", "LEFT" }) do
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
    yL = yL + 40

    yL = AddHeading(f, COL_L, yL, "General")
    f.announceRoleCheck, yL = AddCheckboxRow(f, COL_L, yL, "Announce role changes in chat",
        "Post to raid/party chat when someone's role is changed. Turn off to keep role edits silent.",
        function(value)
            WhoDoesWhat.db.profile.settings.announceRoleChanges = value
            WhoDoesWhat:Print("Announce role changes " .. (value and "enabled." or "disabled."))
        end)
    f.paladinOnlyCheck, yL = AddCheckboxRow(f, COL_L, yL, "Prefer Paladin-only view",
        "Show only the Paladin Buffs section in the main window. The full board still appears while there are active assignments.",
        function(value)
            WhoDoesWhat.db.profile.settings.paladinOnlyView = value
            WhoDoesWhat:Print("Paladin-only view " .. (value and "enabled." or "disabled."))
            WhoDoesWhat:RefreshMainAssignmentsView()
        end, 14)

    yL = AddHeading(f, COL_L, yL, "Warlock Curses", 0.72, 0.45, 1)
    f.afflElementsCheck, yL = AddCheckboxRow(f, COL_L, yL, "Auto assign Affliction to elements",
        "Auto-place Curse of the Elements on an Affliction warlock - on spec detection and via the Auto button.",
        function(value)
            WhoDoesWhat.db.profile.settings.autoAssignAfflictionElements = value
            WhoDoesWhat:Print("Auto-assign Affliction to Elements " .. (value and "enabled." or "disabled."))
        end)
    f.recklessnessCheck, yL = AddCheckboxRow(f, COL_L, yL, "Allow recklessness auto-assign",
        "Let auto-assign fill Curse of Recklessness. It raises the boss's damage, so it can be risky.",
        function(value)
            WhoDoesWhat.db.profile.settings.allowRecklessnessAutoAssign = value
            WhoDoesWhat:Print("Recklessness auto-assign " .. (value and "enabled." or "disabled."))
        end)

    -- ---- Right column ----
    local yR = y0
    yR = AddHeading(f, COL_R, yR, "Developer Options")
    f.devModeCheck, yR = AddCheckboxRow(f, COL_R, yR, "Developer Mode",
        "Assignment dropdowns list every group member, not just the eligible class.",
        function(value)
            WhoDoesWhat.db.profile.settings.developerMode = value
            WhoDoesWhat:Print("Developer Mode " .. (value and "enabled." or "disabled."))
        end)
    f.logUiCheck, yR = AddCheckboxRow(f, COL_R, yR, "Log UI Updates",
        "Print verbose UI build and layout logging to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logUiUpdates = value
            WhoDoesWhat.LOG_UI_BUILDING = value
            WhoDoesWhat:Print("Log UI Updates " .. (value and "enabled." or "disabled."))
        end)
    f.logBuffingClicksCheck, yR = AddCheckboxRow(f, COL_R, yR, "Log buffing bar clicks",
        "Print each recognized left/right buffing-bar click and its castable target count.",
        function(value)
            WhoDoesWhat.db.profile.settings.logBuffingBarClicks = value
            WhoDoesWhat:Print("Log buffing bar clicks "
                .. (value and "enabled." or "disabled."))
        end)
    f.fakeRaidCheck, yR = AddCheckboxRow(f, COL_R, yR, "Populate Fake Raid",
        "Fill the roster with 23 fake raiders to develop buff strategies solo. Wipes the assignment board on toggle.",
        function(value)
            WhoDoesWhat:SetFakeRaidEnabled(value)
        end)

    local palLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    palLabel:SetPoint("TOPLEFT", COL_R + 4, -(yR + 6))
    palLabel:SetText("Fake paladins:")
    local palDD = CreateFrame("Frame", "WhoDoesWhatFakePaladinCountDD", f, "UIDropDownMenuTemplate")
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
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.fakePaladinDD = palDD
    yR = yR + 40

    f.buffingTestCheck, yR = AddCheckboxRow(f, COL_R, yR, "Show buffing bar as non-paladin",
        "Render the Paladin Buffing Bar even when you're not a paladin, as the paladin picked below (real or fake). Preview only.",
        function(value)
            WhoDoesWhat.db.profile.settings.buffingBarTestMode = value
            WhoDoesWhat:Print("Buffing bar test mode " .. (value and "enabled." or "disabled."))
            WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
        end, 14)

    local testLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    testLabel:SetPoint("TOPLEFT", COL_R + 4, -(yR + 6))
    testLabel:SetText("Test as paladin:")
    local testDD = CreateFrame("Frame", "WhoDoesWhatBuffingTestPaladinDD", f, "UIDropDownMenuTemplate")
    testDD:SetPoint("LEFT", testLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(testDD, 120)
    UIDropDownMenu_Initialize(testDD, function(_, level)
        local saved = WhoDoesWhat.db.profile.settings.buffingBarTestPaladin
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
    f.buffingTestCheck:SetChecked(settings.buffingBarTestMode)
    UIDropDownMenu_SetText(f.buffingTestDD, settings.buffingBarTestPaladin or "(first paladin)")
    f.announceRoleCheck:SetChecked(settings.announceRoleChanges)
    f.paladinOnlyCheck:SetChecked(settings.paladinOnlyView)
    f.devModeCheck:SetChecked(settings.developerMode)
    f.logUiCheck:SetChecked(settings.logUiUpdates)
    f.logBuffingClicksCheck:SetChecked(settings.logBuffingBarClicks)
    f.afflElementsCheck:SetChecked(settings.autoAssignAfflictionElements)
    f.recklessnessCheck:SetChecked(settings.allowRecklessnessAutoAssign)
    f.fakeRaidCheck:SetChecked(settings.populateFakeRaid)
    UIDropDownMenu_SetText(f.fakePaladinDD, tostring(settings.fakeRaidPaladinCount or 3))

    self:LogUiBuilding("Opening Addon Settings View...")
    f:Show()
    f:Raise()
end
