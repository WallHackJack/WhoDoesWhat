local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local L = select(2, ...).L
local Locale = select(2, ...).Locale
local S = WhoDoesWhat.SettingsKit

-- Settings > General: the two languages, the minimap button, tooltips, raid
-- frames, group roles and the warlock curse auto-assign rules, plus Reset ALL
-- Defaults. The minimap button itself lives here too, since this page is what
-- switches it.

local PAGE_X = S.PAGE_X
local AddCompactCheckboxRow = S.AddCompactCheckboxRow
local SetOptionAvailable = S.SetOptionAvailable
local AddPageDivider = S.AddPageDivider
local AddNextPageDivider = S.AddNextPageDivider
local AddDropdownRow = S.AddDropdownRow
local IS_CLASSIC_ERA = WhoDoesWhat.ClientFeatures.isClassicEra

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
    UI.AddTooltipHint(tooltip, L.MINIMAP_LEFT_CLICK, L.MINIMAP_ASSIGNMENTS)
    UI.AddTooltipHint(tooltip, L.MINIMAP_RIGHT_CLICK, L.MINIMAP_BUFFING_GRID)
    UI.AddTooltipHint(tooltip, L.MINIMAP_SHIFT_LEFT_CLICK, L.MINIMAP_MEMBERS)
    UI.AddTooltipHint(tooltip, L.MINIMAP_SHIFT_RIGHT_CLICK, L.MINIMAP_SETTINGS)
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

-- The raid-frame master switch owns the style and combat rows under it: with
-- it off we touch Blizzard's frames at all, so neither has anything to say.
local function RefreshRaidFrameOptionStates(f)
    local settings = WhoDoesWhat.db.profile.settings
    local on = settings.raidFrameRoleIcons ~= false
    SetOptionAvailable(f.raidFrameCombatCheck, f.raidFrameCombatLabel, on)
    -- The outlines edge the corner icon and the two opaque bands; a faded band
    -- has no edge to draw them on.
    local style = settings.raidFrameRoleIconStyle or "corner"
    local outlined = on and (style == "corner" or style == "band"
        or style == "bandRight")
    SetOptionAvailable(f.raidFrameOutlineCheck, f.raidFrameOutlineLabel, outlined)
    SetOptionAvailable(f.raidFrameOutlineDpsCheck, f.raidFrameOutlineDpsLabel,
        outlined and settings.raidFrameRoleOutline and true or false)
    local shade = on and 1 or 0.45
    f.raidStyleLabel:SetTextColor(shade, shade, shade)
    if on then
        UIDropDownMenu_EnableDropDown(f.raidStyleDD)
    else
        UIDropDownMenu_DisableDropDown(f.raidStyleDD)
    end
end

local RESET_GENERAL = {
    "unitTooltipRole", "unitTooltipStrangers", "unitTooltipDetail", "tooltipIds",
    "raidFrameRoleIcons",
    "raidFrameRoleIconsInCombat", "raidFrameRoleIconStyle",
    "announceRoleChanges", "manageBlizzardRoles",
    "autoAssignAfflictionElements", "allowRecklessnessAutoAssign",
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

-- ---------------------------------------------------------------------------
-- Language
-- ---------------------------------------------------------------------------

-- A Language choice as the dropdown shows it: "auto" names the language it
-- lands on, and every language is called by its own name ("Deutsch").
local function LanguageText(code)
    if code == "auto" then
        return L.LANGUAGE_AUTOMATIC:format(Locale:Name(Locale:GameLanguage()))
    end
    return Locale:Name(code) or code
end

-- A Message language choice: "primary" follows the Language.
local function MessageLanguageText(code)
    if code == "primary" then return L.MESSAGE_LANGUAGE_SAME end
    return LanguageText(code)
end

-- The on-screen strings are fixed as each window is built, so a new Language
-- takes a reload. `data` is the choice, saved only if the player accepts.
StaticPopupDialogs["WHODOESWHAT_LANGUAGE_RELOAD"] = {
    text = "%s",
    OnAccept = function(self)
        WhoDoesWhat.db.global.language = self.data
        ReloadUI()
    end,
    timeout = 0,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function ChooseLanguage(code)
    local db = WhoDoesWhat.db.global
    if code == db.language then return end
    -- The same strings under another name ("auto" on an English client, say):
    -- nothing on screen would change, so there is nothing to reload for.
    if Locale:Resolve(code) == Locale.primary then
        db.language = code
        return
    end
    local dialog = StaticPopupDialogs["WHODOESWHAT_LANGUAGE_RELOAD"]
    dialog.button1, dialog.button2 = L.LANGUAGE_RELOAD, L.COMMON_CANCEL
    StaticPopup_Show("WHODOESWHAT_LANGUAGE_RELOAD",
        L.LANGUAGE_RELOAD_PROMPT:format(LanguageText(code)), nil, code)
end

-- A dropdown of `first` and then every language WDW has, saved to
-- db.global[key]. `Choose` runs on a pick; `Text` names a choice.
local function InitLanguageDropdown(dd, key, first, Text, Choose)
    UIDropDownMenu_Initialize(dd, function(_, level)
        local saved = WhoDoesWhat.db.global[key]
        local choices = { first }
        for _, code in ipairs(Locale:Codes()) do choices[#choices + 1] = code end
        for _, code in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = Text(code)
            info.checked = saved == code
            info.func = function() Choose(code) end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
end

local function BuildGeneralPage(f, page)
    local generalPage = page
    local yL = AddPageDivider(generalPage, S.PAGE_TOP, L.LANGUAGE_SECTION)
    local languageLabel, languageDD
    languageLabel, languageDD, yL = AddDropdownRow(generalPage, yL,
        L.LANGUAGE_LABEL, "WhoDoesWhatLanguageDD")
    InitLanguageDropdown(languageDD, "language", "auto", LanguageText,
        function(code)
            ChooseLanguage(code)
            -- The saved choice: one waiting on the reload prompt is not yet.
            UIDropDownMenu_SetText(languageDD,
                LanguageText(WhoDoesWhat.db.global.language))
        end)
    UI.AddDropdownTooltip(languageDD, languageLabel, L.LANGUAGE_SECTION,
        L.LANGUAGE_TIP)
    f.languageDD = languageDD

    local messageLabel, messageDD
    messageLabel, messageDD, yL = AddDropdownRow(generalPage, yL,
        L.MESSAGE_LANGUAGE_LABEL, "WhoDoesWhatMessageLanguageDD")
    InitLanguageDropdown(messageDD, "messageLanguage", "primary",
        MessageLanguageText, function(code)
            WhoDoesWhat.db.global.messageLanguage = code
            UIDropDownMenu_SetText(messageDD, MessageLanguageText(code))
        end)
    UI.AddDropdownTooltip(messageDD, messageLabel, L.MESSAGE_LANGUAGE,
        L.MESSAGE_LANGUAGE_TIP)
    f.messageLanguageDD = messageDD

    yL = AddNextPageDivider(generalPage, yL, L.GENERAL_SECTION_MINIMAP_TOOLTIPS)
    f.minimapCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        L.GENERAL_MINIMAP_BUTTON,
        L.GENERAL_MINIMAP_BUTTON_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.minimapButton.hide = not value
            WhoDoesWhat:UpdateMinimapButtonVisibility()
        end)
    f.unitTooltipCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        L.GENERAL_UNIT_TOOLTIP_ROLE, L.GENERAL_UNIT_TOOLTIP_ROLE_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.unitTooltipRole = value
            SetOptionAvailable(f.unitTooltipStrangersCheck,
                f.unitTooltipStrangersLabel, value)
        end)
    f.unitTooltipStrangersCheck, yL, f.unitTooltipStrangersLabel =
        AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        L.GENERAL_UNIT_TOOLTIP_STRANGERS,
        WhoDoesWhat.ClientFeatures.isForever
            and L.GENERAL_UNIT_TOOLTIP_STRANGERS_TIP
            or L.GENERAL_UNIT_TOOLTIP_STRANGERS_RANGE_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.unitTooltipStrangers = value
        end)
    f.unitTooltipDetailCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        L.GENERAL_UNIT_TOOLTIP_DETAIL,
        WhoDoesWhat.ClientFeatures.buffTalents
            and (WhoDoesWhat.WarlockHealthstone
                and L.GENERAL_UNIT_TOOLTIP_DETAIL_TALENTS_WARLOCK_TIP
                or L.GENERAL_UNIT_TOOLTIP_DETAIL_TALENTS_TIP)
            or (WhoDoesWhat.WarlockHealthstone
                and L.GENERAL_UNIT_TOOLTIP_DETAIL_WARLOCK_TIP
                or L.GENERAL_UNIT_TOOLTIP_DETAIL_TIP),
        function(value)
            WhoDoesWhat.db.profile.settings.unitTooltipDetail = value
        end)
    f.tooltipIdsCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        L.GENERAL_TOOLTIP_IDS, L.GENERAL_TOOLTIP_IDS_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.tooltipIds = value
        end)
    yL = AddNextPageDivider(generalPage, yL, L.GENERAL_SECTION_RAID_FRAMES)
    f.raidFrameRoleCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        L.GENERAL_RAID_FRAME_ROLES, L.GENERAL_RAID_FRAME_ROLES_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.raidFrameRoleIcons = value
            WhoDoesWhat:LogUiBuilding("Raid frame role icons "
                .. (value and "enabled." or "disabled."))
            RefreshRaidFrameOptionStates(f)
            WhoDoesWhat:RefreshRaidFrameRoleIcons()
        end)

    local raidStyleLabel, raidStyleDD
    raidStyleLabel, raidStyleDD, yL = AddDropdownRow(generalPage, yL,
        L.GENERAL_RAID_FRAME_STYLE, "WhoDoesWhatRaidFrameStyleDD")
    local raidStyleLabels = {
        corner = L.GENERAL_RAID_FRAME_STYLE_CORNER,
        band = L.GENERAL_RAID_FRAME_STYLE_BAND,
        bandFaded = L.GENERAL_RAID_FRAME_STYLE_BAND_FADED,
        bandRight = L.GENERAL_RAID_FRAME_STYLE_BAND_RIGHT,
        bandRightFaded = L.GENERAL_RAID_FRAME_STYLE_BAND_RIGHT_FADED,
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
                RefreshRaidFrameOptionStates(f)
                WhoDoesWhat:RefreshRaidFrameRoleIcons()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.raidStyleDD = raidStyleDD
    f.raidStyleLabel = raidStyleLabel

    f.raidFrameOutlineCheck, yL, f.raidFrameOutlineLabel = AddCompactCheckboxRow(
        generalPage, PAGE_X, yL,
        L.GENERAL_RAID_FRAME_OUTLINE, L.GENERAL_RAID_FRAME_OUTLINE_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.raidFrameRoleOutline = value
            RefreshRaidFrameOptionStates(f)
            WhoDoesWhat:RefreshRaidFrameRoleIcons()
        end)
    f.raidFrameOutlineDpsCheck, yL, f.raidFrameOutlineDpsLabel = AddCompactCheckboxRow(
        generalPage, PAGE_X, yL,
        L.GENERAL_RAID_FRAME_OUTLINE_DPS, L.GENERAL_RAID_FRAME_OUTLINE_DPS_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.raidFrameRoleOutlineDps = value
            WhoDoesWhat:RefreshRaidFrameRoleIcons()
        end)

    f.raidFrameCombatCheck, yL, f.raidFrameCombatLabel = AddCompactCheckboxRow(
        generalPage, PAGE_X, yL,
        L.GENERAL_RAID_FRAME_COMBAT, L.GENERAL_RAID_FRAME_COMBAT_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.raidFrameRoleIconsInCombat = value
            WhoDoesWhat:LogUiBuilding("Raid frame role icons in combat "
                .. (value and "enabled." or "disabled."))
            WhoDoesWhat:RefreshRaidFrameRoleIcons()
        end)
    yL = AddNextPageDivider(generalPage, yL, L.GENERAL_SECTION_GROUP_ROLES)
    f.announceRoleCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        L.GENERAL_ANNOUNCE_ROLES, L.GENERAL_ANNOUNCE_ROLES_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.announceRoleChanges = value
            WhoDoesWhat:LogUiBuilding("Announce role changes " .. (value and "enabled." or "disabled."))
        end)
    f.manageBlizzRolesCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        L.GENERAL_BLIZZARD_ROLES, L.GENERAL_BLIZZARD_ROLES_TIP,
        function(value)
            WhoDoesWhat.db.profile.settings.manageBlizzardRoles = value
            WhoDoesWhat:LogUiBuilding("Blizzard group roles "
                .. (value and "managed." or "left alone."))
            -- Turning it back on should catch the group up rather than wait for
            -- the next role change or roster event.
            if value then WhoDoesWhat:ReconcileBlizzardRoles() end
        end)

    -- In the warlock class colour, like the Warlock Curses section it tunes.
    yL = AddNextPageDivider(generalPage, yL, L.GENERAL_SECTION_WARLOCK_CURSES,
        { 0.72, 0.45, 1 })
    local magicCurseLabel = IS_CLASSIC_ERA and L.GENERAL_AUTO_ELEMENTS_SHADOW
        or L.GENERAL_AUTO_AFFLICTION_ELEMENTS
    local magicCurseDescription = IS_CLASSIC_ERA
        and L.GENERAL_AUTO_ELEMENTS_SHADOW_TIP
        or L.GENERAL_AUTO_AFFLICTION_ELEMENTS_TIP
    f.afflElementsCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL, magicCurseLabel,
        magicCurseDescription,
        function(value)
            WhoDoesWhat.db.profile.settings.autoAssignAfflictionElements = value
            local settingName = IS_CLASSIC_ERA and "Magic curse auto-assign"
                or "Auto-assign Affliction to Elements"
            WhoDoesWhat:LogUiBuilding(settingName .. " "
                .. (value and "enabled." or "disabled."))
        end)
    f.recklessnessCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        L.GENERAL_AUTO_RECKLESSNESS, L.GENERAL_AUTO_RECKLESSNESS_TIP,
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
    resetAll:SetText(L.GENERAL_RESET_ALL)
    resetAll:SetScript("OnClick", function()
        S.ConfirmReset(L.GENERAL_RESET_ALL_PROMPT:format(L.GENERAL_RESET_ALL_TIP),
            function() S.ResetAllPages(f) end)
    end)
    UI.AddTooltip(resetAll, L.GENERAL_RESET_ALL, L.GENERAL_RESET_ALL_TIP)
end

local function RefreshGeneralPage(f)
    local global = WhoDoesWhat.db.global
    UIDropDownMenu_SetText(f.languageDD, LanguageText(global.language))
    UIDropDownMenu_SetText(f.messageLanguageDD,
        MessageLanguageText(global.messageLanguage))
    local settings = WhoDoesWhat.db.profile.settings
    f.minimapCheck:SetChecked(not settings.minimapButton.hide)
    f.unitTooltipCheck:SetChecked(settings.unitTooltipRole ~= false)
    f.unitTooltipStrangersCheck:SetChecked(settings.unitTooltipStrangers)
    SetOptionAvailable(f.unitTooltipStrangersCheck, f.unitTooltipStrangersLabel,
        settings.unitTooltipRole ~= false)
    f.unitTooltipDetailCheck:SetChecked(settings.unitTooltipDetail)
    -- Unset means the client decides, so the box shows what is actually
    -- happening rather than an unchecked box beside id lines on every tooltip.
    f.tooltipIdsCheck:SetChecked(WhoDoesWhat:ShowTooltipIds())
    f.raidFrameRoleCheck:SetChecked(settings.raidFrameRoleIcons ~= false)
    f.raidFrameCombatCheck:SetChecked(settings.raidFrameRoleIconsInCombat ~= false)
    f.raidFrameOutlineCheck:SetChecked(settings.raidFrameRoleOutline)
    f.raidFrameOutlineDpsCheck:SetChecked(settings.raidFrameRoleOutlineDps)
    UIDropDownMenu_SetText(f.raidStyleDD,
        f.raidStyleLabels[settings.raidFrameRoleIconStyle or "corner"]
            or f.raidStyleLabels.corner)
    RefreshRaidFrameOptionStates(f)
    f.announceRoleCheck:SetChecked(settings.announceRoleChanges)
    f.manageBlizzRolesCheck:SetChecked(settings.manageBlizzardRoles ~= false)
    f.afflElementsCheck:SetChecked(settings.autoAssignAfflictionElements)
    f.recklessnessCheck:SetChecked(settings.allowRecklessnessAutoAssign)
end

S.RegisterPage({
    id = "General", labelKey = "SETTINGS_GENERAL",
    descriptionKey = "SETTINGS_GENERAL_RESET",
    Build = BuildGeneralPage,
    Refresh = RefreshGeneralPage,
    Reset = ResetGeneral,
})
