local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- About, contact, and release notes. WoW cannot open arbitrary web links, so
-- link buttons place their value in one copy-ready field instead.

local aboutFrame

local FRAME_W = 500
local FRAME_H = 430
local MARGIN = 14

local LINKS = {
    { label = "Video", value = "https://www.youtube.com/watch?v=g-M2CQ5YFB4" },
    { label = "CurseForge", value = "https://www.curseforge.com/wow/addons/whodoeswhat" },
    { label = "GitHub", value = "https://github.com/WallHackJack/WhoDoesWhat" },
}

-- Newest first. Add one entry when cutting each tagged release; the first
-- entry is presented as the latest release in the window.
local RELEASES = {
    {
        version = "1.0.10",
        date = "2026-08-06",
        notes = {
            "WhoDoesWhat no longer changes anyone's Blizzard group role on its own.",
            "Added the Action Items window: group roles that don't match, and tanks not promoted to Main Tank.",
            "Added an Actions button to the main window that glows when something needs fixing.",
            "Added a setting to stop WhoDoesWhat touching Blizzard group roles entirely.",
            "Main tanks are no longer demoted during a fight.",
            "Custom roles now require a name, a class, and a group role.",
            "Show WhoDoesWhat roles in Blizzard unit tooltips, with optional class details.",
            "Added a paladin blessing-spread overview to the PallyPower Differences window.",
            "Added aura and Righteous Fury helpers to the Paladin Bar.",
            "Added right-click shortcuts, tooltips, and per-row options to the status bars.",
            "Added a settings cog to the Buffing Grid, and retired its Rescan button.",
            "Fixed debuff bars hiding at full saturation.",
        },
    },
    {
        version = "1.0.9",
        date = "2026-08-03",
        notes = {
            "Added support for improved thorns.",
            "Added Minimap Button with shortcuts.",
            "Improve Buff Tracking options for status bars + Grid.",
            "Respect PallyPower Free Assignment permissions.",
            "Improved PP buff-source mode, and diffs page.",
            "Added About section with Update Notes.",
            "Count only meaningful PallyPower blessing optimizations.",
            "Use PallyPower talent data for unknown paladins.",
        },
    },
    {
        version = "1.0.8",
        date = "2026-08-01",
        notes = {
            "Added WDW and PallyPower assignment-source modes.",
            "Added PallyPower synchronization without requiring PallyPower locally.",
            "Improved the main board, read-only views, and live buff-status whispers.",
        },
    },
    {
        version = "1.0.7",
        date = "2026-07-30",
        notes = {
            "Added the observed PallyPower mirror and Buffing Grid source comparison.",
            "Synchronized Paladin buff strategies and direct talent observations.",
            "Added configurable status checks and improved buffing priority.",
        },
    },
    {
        version = "1.0.6",
        date = "2026-07-29",
        notes = {
            "Added live core raid-buff coverage and expanded status bars.",
            "Improved Paladin coverage controls, pet blessings, and buffing menus.",
            "Added clearer addon-presence and version information to raid roles.",
        },
    },
}

local function SetPanelBackdrop(frame)
    frame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.16, 0.16, 0.18, 0.9)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4)
end

local function SetCopyValue(f, label, value)
    f.copyLabel:SetText(label .. ":")
    f.copyEdit:SetText(value)
    f.copyEdit:SetFocus()
    f.copyEdit:HighlightText()
end

local function SelectRelease(f, release)
    f.selectedRelease = release
    UIDropDownMenu_SetSelectedValue(f.releaseDD, release.version)
    UIDropDownMenu_SetText(f.releaseDD, "v" .. release.version)
    f.releaseDate:SetText(release.date)

    local lines = {}
    for _, note in ipairs(release.notes) do
        lines[#lines + 1] = "|cffd8d8d8- " .. note .. "|r"
    end
    f.releaseNotes:SetText(table.concat(lines, "\n\n"))
end

local function EnsureAboutFrame()
    if aboutFrame then return aboutFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatAboutFrame", FRAME_W,
        FRAME_H, "WhoDoesWhat - About & Updates")
    local y = f.titleBarHeight + 16

    local name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    name:SetPoint("TOPLEFT", MARGIN, -y)
    name:SetText("WhoDoesWhat")

    local installed = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    installed:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -5)
    f.installedVersion = installed

    local latest = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    latest:SetPoint("TOPLEFT", installed, "BOTTOMLEFT", 0, -5)
    latest:SetText("Latest release notes: v" .. RELEASES[1].version
        .. " (" .. RELEASES[1].date .. ")")

    local tagline = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tagline:SetPoint("TOPLEFT", latest, "BOTTOMLEFT", 0, -8)
    tagline:SetPoint("RIGHT", f, "RIGHT", -MARGIN, 0)
    tagline:SetJustifyH("LEFT")
    tagline:SetText("Raid roles and assignments, with instant fixes for Paladin buff assignments.")

    local linksBox = CreateFrame("Frame", nil, f, "BackdropTemplate")
    linksBox:SetPoint("TOPLEFT", MARGIN, -(y + 88))
    linksBox:SetPoint("TOPRIGHT", -MARGIN, -(y + 88))
    linksBox:SetHeight(112)
    SetPanelBackdrop(linksBox)

    local linksTitle = linksBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    linksTitle:SetPoint("TOPLEFT", 10, -9)
    linksTitle:SetText("Links & Contact")

    local instruction = linksBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instruction:SetPoint("LEFT", linksTitle, "RIGHT", 10, 0)
    instruction:SetText("Choose a link, then press Ctrl+C.")
    instruction:SetTextColor(0.65, 0.65, 0.65)

    local prior
    for _, link in ipairs(LINKS) do
        local selected = link
        local button = CreateFrame("Button", nil, linksBox, "UIPanelButtonTemplate")
        -- Five fit on this row, leaving room for the planned support link.
        button:SetSize(82, 21)
        if prior then
            button:SetPoint("LEFT", prior, "RIGHT", 6, 0)
        else
            button:SetPoint("TOPLEFT", 10, -32)
        end
        button:SetText(selected.label)
        button:SetScript("OnClick", function()
            SetCopyValue(f, selected.label, selected.value)
        end)
        prior = button
    end

    local copyLabel = linksBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    copyLabel:SetPoint("TOPLEFT", 12, -64)
    copyLabel:SetWidth(70)
    copyLabel:SetJustifyH("LEFT")
    f.copyLabel = copyLabel

    local copyEdit = CreateFrame("EditBox", nil, linksBox, "InputBoxTemplate")
    copyEdit:SetPoint("LEFT", copyLabel, "RIGHT", -2, 0)
    copyEdit:SetPoint("RIGHT", linksBox, "RIGHT", -12, 0)
    copyEdit:SetHeight(20)
    copyEdit:SetAutoFocus(false)
    copyEdit:SetMaxLetters(512)
    copyEdit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    copyEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    copyEdit:SetScript("OnEnterPressed", function(self) self:HighlightText() end)
    f.copyEdit = copyEdit

    local contact = linksBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    contact:SetPoint("BOTTOMLEFT", 12, 10)
    contact:SetText("Questions or feedback? Message |cff40c7ebwallhackjack|r on Discord.")

    local copyName = CreateFrame("Button", nil, linksBox, "UIPanelButtonTemplate")
    copyName:SetSize(82, 18)
    copyName:SetPoint("BOTTOMRIGHT", -10, 7)
    copyName:SetText("Copy name")
    copyName:SetScript("OnClick", function()
        SetCopyValue(f, "Discord", "wallhackjack")
    end)

    local updatesBox = CreateFrame("Frame", nil, f, "BackdropTemplate")
    updatesBox:SetPoint("TOPLEFT", linksBox, "BOTTOMLEFT", 0, -10)
    updatesBox:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -MARGIN, MARGIN)
    SetPanelBackdrop(updatesBox)

    local updatesTitle = updatesBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    updatesTitle:SetPoint("TOPLEFT", 10, -11)
    updatesTitle:SetText("Update Log")

    local versionLabel = updatesBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    versionLabel:SetPoint("LEFT", updatesTitle, "RIGHT", 18, 0)
    versionLabel:SetText("Version:")

    local releaseDD = CreateFrame("Frame", "WhoDoesWhatAboutReleaseDD", updatesBox,
        "UIDropDownMenuTemplate")
    releaseDD:SetPoint("LEFT", versionLabel, "RIGHT", -11, -2)
    UIDropDownMenu_SetWidth(releaseDD, 82)
    WhoDoesWhat:StyleDropdown(releaseDD, true)
    UIDropDownMenu_Initialize(releaseDD, function(_, level)
        for _, release in ipairs(RELEASES) do
            local selected = release
            local info = UIDropDownMenu_CreateInfo()
            info.text = "v" .. selected.version
            info.value = selected.version
            info.checked = f.selectedRelease == selected
            info.func = function() SelectRelease(f, selected) end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.releaseDD = releaseDD

    local releaseDate = updatesBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    releaseDate:SetPoint("TOPRIGHT", -12, -13)
    releaseDate:SetTextColor(0.65, 0.65, 0.65)
    f.releaseDate = releaseDate

    local releaseNotes = updatesBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    releaseNotes:SetPoint("TOPLEFT", 12, -46)
    releaseNotes:SetPoint("BOTTOMRIGHT", -12, 12)
    releaseNotes:SetJustifyH("LEFT")
    releaseNotes:SetJustifyV("TOP")
    f.releaseNotes = releaseNotes

    SetCopyValue(f, LINKS[1].label, LINKS[1].value)
    copyEdit:ClearFocus()
    SelectRelease(f, RELEASES[1])

    aboutFrame = f
    return f
end

function WhoDoesWhat:OpenAboutView()
    local f = EnsureAboutFrame()
    if f:IsShown() then
        f:Hide()
        return
    end

    f.installedVersion:SetText("Installed version: v" .. tostring(self.VERSION or "?"))
    f:Show()
    f:Raise()
end
