local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local S = WhoDoesWhat.SettingsKit

-- Settings > General: the minimap button, tooltips, raid frames, group roles
-- and the warlock curse auto-assign rules, plus Reset ALL Defaults. The minimap
-- button itself lives here too, since this page is what switches it.

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
    "unitTooltipRole", "unitTooltipDetail", "tooltipIds",
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

local function BuildGeneralPage(f, page)
    local generalPage = page
    local yL = AddPageDivider(generalPage, S.PAGE_TOP, "Minimap & Tooltips")
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
            .. (WhoDoesWhat.ClientFeatures.buffTalents
                and "blessing talents and addon status" or "addon status")
            .. (WhoDoesWhat.WarlockHealthstone
                and ", or a Warlock's Improved Healthstone. Only Paladins and"
                    .. " Warlocks add anything."
                or ". Only Paladins add anything."),
        function(value)
            WhoDoesWhat.db.profile.settings.unitTooltipDetail = value
        end)
    f.tooltipIdsCheck, yL = AddCompactCheckboxRow(generalPage, PAGE_X, yL,
        "Show spell and item ids on tooltips",
        "Add the id to item, spell and buff tooltips. For looking up what to "
            .. "tell the addon about a consumable it doesn't know yet; on by "
            .. "default on WoW Forever, off elsewhere.",
        function(value)
            WhoDoesWhat.db.profile.settings.tooltipIds = value
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
        "Add outline by role",
        "Edge each raid frame role icon in its role colour: blue for tanks, "
            .. "green for healers. DPS get theirs from the option below."
            .. "\n\nReplace WoW Icon, Left band and Right band styles only.",
        function(value)
            WhoDoesWhat.db.profile.settings.raidFrameRoleOutline = value
            RefreshRaidFrameOptionStates(f)
            WhoDoesWhat:RefreshRaidFrameRoleIcons()
        end)
    f.raidFrameOutlineDpsCheck, yL, f.raidFrameOutlineDpsLabel = AddCompactCheckboxRow(
        generalPage, PAGE_X, yL,
        "Add outline to DPS",
        "Also edge DPS role icons, in red. Needs Add outline by role."
            .. "\n\nReplace WoW Icon, Left band and Right band styles only.",
        function(value)
            WhoDoesWhat.db.profile.settings.raidFrameRoleOutlineDps = value
            WhoDoesWhat:RefreshRaidFrameRoleIcons()
        end)

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
            nil, function() S.ResetAllPages(f) end)
    end)
    UI.AddTooltip(resetAll, "Reset ALL Defaults", RESET_ALL_DESCRIPTION)
end

local function RefreshGeneralPage(f)
    local settings = WhoDoesWhat.db.profile.settings
    f.minimapCheck:SetChecked(not settings.minimapButton.hide)
    f.unitTooltipCheck:SetChecked(settings.unitTooltipRole ~= false)
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
    label = "General", title = "General",
    description = "Puts every option on this page back and returns the"
        .. " minimap button to its default spot.",
    Build = BuildGeneralPage,
    Refresh = RefreshGeneralPage,
    Reset = ResetGeneral,
})
