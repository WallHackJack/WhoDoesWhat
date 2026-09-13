local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI

-- About, contact, and release notes. WoW cannot open arbitrary web links, so
-- link buttons place their value in one copy-ready field instead.

local aboutFrame

local FRAME_W = 500
local FRAME_H = 430
local MARGIN = 14
-- Same gutter the main window and Members reserve for their scrollbars.
local SCROLLBAR_W = UI.SCROLLBAR_W
-- Padding between the notes well's edge and the text inside it.
local WELL_PAD = 8
-- The notes column: the box spans the window inside its margins, the well sits
-- inside that by 12 a side, and the text inside the well by WELL_PAD a side --
-- less the gutter the scrollbar keeps whether or not it is showing.
local NOTES_W = FRAME_W - MARGIN * 2 - 24 - WELL_PAD * 2 - SCROLLBAR_W

-- Newest first, from Releases.lua. This file draws them and owns none of them.
local RELEASES = WhoDoesWhat.Releases

local LINKS = {
    { label = "Video", value = "https://www.youtube.com/watch?v=g-M2CQ5YFB4" },
    { label = "CurseForge", value = "https://www.curseforge.com/wow/addons/whodoeswhat" },
    { label = "GitHub", value = "https://github.com/WallHackJack/WhoDoesWhat" },
    { label = "Donate", value = "https://ko-fi.com/wallhackjack" },
}

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
    -- The scroll child is only ever as tall as the notes it holds, so the bar
    -- drops away entirely on a short release. A new release starts at its
    -- first line rather than wherever the last one was left.
    UI.SetScrollHeight(f.releaseScroll, f.releaseNotes:GetStringHeight() + 4)
    f.releaseScroll:SetVerticalScroll(0)
end

local function EnsureAboutFrame()
    if aboutFrame then return aboutFrame end

    local f = UI.CreateWindow("WhoDoesWhatAboutFrame", FRAME_W,
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
    UI.StylePanel(linksBox)

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
    UI.StylePanel(updatesBox)

    local updatesTitle = updatesBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    updatesTitle:SetPoint("TOPLEFT", 10, -11)
    updatesTitle:SetText("Update Log")

    local versionLabel = updatesBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    versionLabel:SetPoint("LEFT", updatesTitle, "RIGHT", 18, 0)
    versionLabel:SetText("Version:")

    local releaseDD = UI.CreateMenuDropdown(updatesBox, "WhoDoesWhatAboutReleaseDD", 82)
    releaseDD:SetPoint("LEFT", versionLabel, "RIGHT", -11, -2)
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

    -- A dozen notes runs off the bottom of this box, and how long a release
    -- is not something this window gets to decide -- so the notes scroll. The
    -- gutter is reserved whether or not the bar is showing, so the text does
    -- not reflow as releases are picked.
    local notesWell = CreateFrame("Frame", nil, updatesBox, "BackdropTemplate")
    notesWell:SetPoint("TOPLEFT", 12, -42)
    notesWell:SetPoint("BOTTOMRIGHT", -12, 10)
    UI.StylePanel(notesWell, "sunken")

    local scroll, content = UI.CreateScroll(notesWell, "WhoDoesWhatAboutNotesScroll", true)
    scroll:SetPoint("TOPLEFT", WELL_PAD, -WELL_PAD)
    scroll:SetPoint("BOTTOMRIGHT", -(WELL_PAD + SCROLLBAR_W), WELL_PAD)
    content:SetWidth(NOTES_W)
    f.releaseScroll = scroll
    f.releaseContent = content

    local releaseNotes = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    releaseNotes:SetPoint("TOPLEFT")
    releaseNotes:SetWidth(NOTES_W)
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
    -- Re-measure the notes now the window is up: a wrapped string built while
    -- the frame was hidden can report no height, which would leave the scroll
    -- child too short to reach the bottom of a long release.
    SelectRelease(f, f.selectedRelease)
end
