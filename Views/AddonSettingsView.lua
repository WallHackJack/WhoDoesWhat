local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Addon settings window. A stub for now: just the Developer Options section.
-- Checkbox state persists in db.profile.settings; "Log UI Updates" also
-- mirrors into WhoDoesWhat.LOG_UI_BUILDING immediately so logging reacts
-- without a reload.

local settingsFrame = nil

local FRAME_W = 320
local FRAME_H = 450
local MARGIN = 14
local CHECKBOX_ROW_H = 50

-- Checkbox with a label beside it and a small gray description underneath.
-- `apply` receives the new boolean and writes it wherever it lives. Returns
-- the checkbox and the y offset below the row.
local function AddCheckboxRow(f, y, labelText, descText, apply)
    local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("TOPLEFT", MARGIN, -y)
    check:SetScript("OnClick", function(self)
        apply(self:GetChecked() and true or false)
    end)

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", check, "RIGHT", 2, 0)
    label:SetText(labelText)

    local desc = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", check, "BOTTOMLEFT", 26, 2)
    desc:SetWidth(FRAME_W - MARGIN * 2 - 26)
    desc:SetJustifyH("LEFT")
    desc:SetTextColor(0.6, 0.6, 0.6)
    desc:SetText(descText)

    return check, y + CHECKBOX_ROW_H
end

-- Build the settings window once and reuse it.
local function EnsureSettingsFrame()
    if settingsFrame then return settingsFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatSettingsFrame", FRAME_W, FRAME_H, "WhoDoesWhat - Settings")
    local y = f.titleBarHeight + 14

    local curseHeading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    curseHeading:SetPoint("TOPLEFT", MARGIN, -y)
    curseHeading:SetText("Warlock Curses")
    curseHeading:SetTextColor(0.72, 0.45, 1)
    y = y + 28

    f.afflElementsCheck, y = AddCheckboxRow(f, y, "Auto assign Affliction to elements",
        "Auto-place Curse of the Elements on an Affliction warlock - on spec detection and via the Auto button.",
        function(value)
            WhoDoesWhat.db.profile.settings.autoAssignAfflictionElements = value
            WhoDoesWhat:Print("Auto-assign Affliction to Elements " .. (value and "enabled." or "disabled."))
        end)

    f.recklessnessCheck, y = AddCheckboxRow(f, y, "Allow recklessness auto-assign",
        "Let auto-assign fill Curse of Recklessness. It raises the boss's damage, so it can be risky.",
        function(value)
            WhoDoesWhat.db.profile.settings.allowRecklessnessAutoAssign = value
            WhoDoesWhat:Print("Recklessness auto-assign " .. (value and "enabled." or "disabled."))
        end)

    y = y + 6
    local heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", MARGIN, -y)
    heading:SetText("Developer Options")
    y = y + 28

    f.devModeCheck, y = AddCheckboxRow(f, y, "Developer Mode",
        "Assignment dropdowns list every group member, not just the eligible class.",
        function(value)
            WhoDoesWhat.db.profile.settings.developerMode = value
            WhoDoesWhat:Print("Developer Mode " .. (value and "enabled." or "disabled."))
        end)

    f.logUiCheck, y = AddCheckboxRow(f, y, "Log UI Updates",
        "Print verbose UI build and layout logging to chat.",
        function(value)
            WhoDoesWhat.db.profile.settings.logUiUpdates = value
            WhoDoesWhat.LOG_UI_BUILDING = value
            WhoDoesWhat:Print("Log UI Updates " .. (value and "enabled." or "disabled."))
        end)

    f.fakeRaidCheck, y = AddCheckboxRow(f, y, "Populate Fake Raid",
        "Fill the roster with 23 fake raiders to develop buff strategies solo. Wipes the assignment board on toggle.",
        function(value)
            WhoDoesWhat:SetFakeRaidEnabled(value)
        end)

    -- Fake paladin count: prot always, then ret, holy, untalented ret.
    local palLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    palLabel:SetPoint("TOPLEFT", MARGIN + 4, -(y + 6))
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
    y = y + 38

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
    f.devModeCheck:SetChecked(settings.developerMode)
    f.logUiCheck:SetChecked(settings.logUiUpdates)
    f.afflElementsCheck:SetChecked(settings.autoAssignAfflictionElements)
    f.recklessnessCheck:SetChecked(settings.allowRecklessnessAutoAssign)
    f.fakeRaidCheck:SetChecked(settings.populateFakeRaid)
    UIDropDownMenu_SetText(f.fakePaladinDD, tostring(settings.fakeRaidPaladinCount or 3))

    self:LogUiBuilding("Opening Addon Settings View...")
    f:Show()
    f:Raise()
end
