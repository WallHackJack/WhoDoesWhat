local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- The Paladin Buffing Bar: a movable Nova-style strip of one button per CLASS
-- the local paladin is assigned to buff (WhoDoesWhat.Assign.GetPaladinBuffJobs),
-- each showing the class icon and a coloured "buffed/total" count. Left-click
-- casts the class's Greater Blessing on a class member (buffs the whole class);
-- right-click cycles every assigned member's planned Lesser Blessing, with
-- missing/lowest-timer targets first -- see the secure-casting section below.
-- Hovering a class button opens a secure
-- per-player menu: left-click casts the class Greater for majority-assigned
-- players; both clicks cast the planned Normal blessing for exceptions.
--
-- Whose jobs it renders (ResolveBarPaladin): normally the local player when
-- they're a paladin; in test mode, the paladin picked in the settings dropdown
-- (real or fake), so you can preview the bar as any raid paladin.
--
-- Styled like the other WDW windows (dark backdrop, tooltip border, a "WDW
-- Buffs" title strip). Moved by Alt-dragging; grows left or right per the
-- settings option; a pulsing red frame alerts when any assigned raider is
-- missing a blessing.

local bar = nil

local INSET = 3        -- backdrop edge inset
local PAD = 3          -- inner padding around the button row
local TITLE_H = 12     -- title strip height
local BTN_SIZE = 28
local BTN_GAP = 3
local COUNT_H = 10     -- room under a button for its count text
local PLAYER_MENU_W = 180
local PLAYER_HEADER_H = 24
local PLAYER_W = PLAYER_MENU_W - INSET * 2
local PLAYER_H = 22
local PLAYER_GAP = 0
local MISSING_ICON = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local MISSING_GLOW_COLOR = { 1, 0.05, 0.05, 1 }
local GetBuffDataByIndex = C_UnitAuras and C_UnitAuras.GetBuffDataByIndex

-- y from the bar's top down to where the button row begins.
local CONTENT_TOP = INSET + TITLE_H + 2

-- ---------------------------------------------------------------------------
-- Which paladin to render
-- ---------------------------------------------------------------------------

-- Stable key for the local player, matching the plan's raider keys.
local function LocalPlayerKey()
    local name, realm = UnitName("player")
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- Strict list of paladin names in the group (real + fake), for the settings
-- dropdown and the test-mode fallback.
function WhoDoesWhat:GetBuffingBarPaladins()
    return self.Assign.MembersOfClass("Paladin")
end

-- Resolve the test selection against the current roster. A departed paladin
-- clears the saved override so test mode falls back to the first paladin.
function WhoDoesWhat:GetBuffingBarTestPaladin()
    local paladins = self:GetBuffingBarPaladins()
    local settings = self.db.profile.settings
    local saved = settings.buffingBarTestPaladin
    if saved then
        for _, name in ipairs(paladins) do
            if name == saved then return saved end
        end
        settings.buffingBarTestPaladin = nil
    end
    return paladins[1]
end

-- The paladin whose jobs the bar should show, or nil when it shouldn't show at
-- all: master toggle off, or the local player isn't a paladin and test mode is
-- off.
local function ResolveBarPaladin()
    local s = WhoDoesWhat.db.profile.settings
    -- Dev test mode is an independent override: render as the picked paladin
    -- even if the master toggle is off and the local player isn't a paladin.
    if s.buffingBarTestMode then
        return WhoDoesWhat:GetBuffingBarTestPaladin()
    end
    if not s.buffingBarEnabled then return nil end
    local _, class = UnitClass("player")
    if class == "PALADIN" then return LocalPlayerKey() end
    return nil
end

-- ---------------------------------------------------------------------------
-- Position (Alt-drag) + growth direction
-- ---------------------------------------------------------------------------

-- Save the current on-screen rect, anchoring by the edge the bar grows away
-- from: left edge for RIGHT growth, right edge for LEFT growth, so adding
-- buttons never shifts the anchored side.
local function SavePosition()
    if not bar then return end
    local grow = WhoDoesWhat.db.profile.settings.buffingBarGrow or "RIGHT"
    local point = (grow == "LEFT") and "TOPRIGHT" or "TOPLEFT"
    local x = (grow == "LEFT") and bar:GetRight() or bar:GetLeft()
    local y = bar:GetTop()
    if not x or not y then return end
    WhoDoesWhat.db.profile.settings.buffingBarPos = { point = point, x = x, y = y }
end

local function LoadPosition()
    local p = WhoDoesWhat.db.profile.settings.buffingBarPos
    bar:ClearAllPoints()
    if p and p.x and p.y then
        bar:SetPoint(p.point or "TOPLEFT", UIParent, "BOTTOMLEFT", p.x, p.y)
    else
        bar:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
    end
end

-- Attach Alt-gated dragging to a mouse region that moves the whole bar.
local function AttachAltDrag(region)
    region:EnableMouse(true)
    region:RegisterForDrag("LeftButton")
    region:SetScript("OnDragStart", function()
        if IsAltKeyDown() then bar:StartMoving() end
    end)
    region:SetScript("OnDragStop", function()
        bar:StopMovingOrSizing()
        -- Save, then re-anchor to the growth corner so the next resize grows
        -- the chosen way (StartMoving may have left a different anchor).
        SavePosition()
        LoadPosition()
        WhoDoesWhat:RefreshPaladinBuffingBar()
    end)
end

-- Re-anchor to the growth-appropriate edge without visually moving the bar,
-- then repaint. Called from the settings dropdown.
function WhoDoesWhat:SetBuffingBarGrow(mode)
    self.db.profile.settings.buffingBarGrow = mode
    if bar and bar:GetLeft() then
        SavePosition()
        LoadPosition()
    end
    self:RefreshPaladinBuffingBar()
end

function WhoDoesWhat:SetBuffingMenuGrow(mode)
    self.db.profile.settings.buffingMenuGrow = mode
    self:RefreshPaladinBuffingBar()
end

-- ---------------------------------------------------------------------------
-- Range + "ready" glow (LibCustomGlow, same as NovaConsumesHelper)
-- ---------------------------------------------------------------------------

local LCG = LibStub("LibCustomGlow-1.0", true)

-- raider name -> group unit token, rebuilt each refresh (matches the plan's
-- Name / Name-Realm keys via GetUnitName's showServerName).
local function BuildNameToUnit()
    local map = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local u = "raid" .. i
            local nm = GetUnitName(u, true)
            if nm then map[nm] = u end
        end
    else
        local me = GetUnitName("player", true) or UnitName("player")
        if me then map[me] = "player" end
        for i = 1, GetNumSubgroupMembers() do
            local u = "party" .. i
            local nm = GetUnitName(u, true)
            if nm then map[nm] = u end
        end
    end
    return map
end

-- Is a target reachable for this blessing right now? A resolved unit is checked
-- by spell range (falling back to generic unit range); an unresolved name -- a
-- fake raider, or someone not in our group -- is assumed in range so the
-- preview still lights up.
local function TargetInRange(unit, spellId)
    if not unit then return true end
    if C_Spell and C_Spell.IsSpellInRange then
        local r = C_Spell.IsSpellInRange(spellId, unit)
        if r ~= nil then return r and true or false end
    end
    local inRange, checked = UnitInRange(unit)
    if checked then return inRange and true or false end
    return true
end

-- The unit token to target for a member: a pet's own unit, else the raider's
-- resolved group unit. Both work as [@unit] in a cast macro and for range.
local function CastUnit(member, nameToUnit)
    if member.isPet then return member.petUnit end
    return nameToUnit[member.name]
end

-- Does this class job have at least one still-missing member in range -- i.e.
-- is there anything to cast right now? Drives both the glow and the range-grey.
local function JobIsReady(job, nameToUnit)
    for _, r in ipairs(job.raiders) do
        if r.has ~= true then
            local meta = WhoDoesWhat.PaladinBuffs[r.key]
            if TargetInRange(CastUnit(r, nameToUnit), meta and meta.spellId) then
                return true
            end
        end
    end
    return false
end

-- Wide rows pulse their existing 1px outline; square class buttons keep the
-- Nova-style pixel glow. Track state so refreshes don't restart animations.
local function SetButtonGlow(btn, on, color, inset)
    if btn.outlinePulse then
        if on and not btn.glowing then
            btn.outlinePulse:Play()
            btn.glowing = true
        elseif not on and btn.glowing then
            btn.outlinePulse:Stop()
            btn.outline:SetAlpha(1)
            btn.glowing = false
        end
        return
    end
    if not LCG then return end
    if on then
        if not btn.glowing then
            local offset, border = nil, true
            if inset then offset, border = -inset, false end
            LCG.PixelGlow_Start(btn, color, 16, nil, 3, nil,
                offset, offset, border, nil, 4)
            btn.glowing = true
        end
    elseif btn.glowing then
        LCG.PixelGlow_Stop(btn)
        btn.glowing = false
    end
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

-- Colour for a covered/total count: green all, red none, yellow partial, gray
-- when there's nothing to cover.
local function CountColor(covered, total)
    if total == 0 then return 0.6, 0.6, 0.6 end
    if covered >= total then return 0.3, 1, 0.3 end
    if covered == 0 then return 1, 0.3, 0.3 end
    return 1, 0.82, 0.2
end

-- Combat-safe state for an existing class button. Secure spell/target
-- attributes and button layout remain untouched until combat ends.
local function UpdateButtonStatus(btn, job, nameToUnit)
    btn.visualJob = job
    if not job then
        btn.count:SetText("0/0")
        btn.count:SetTextColor(CountColor(0, 0))
        btn.icon:SetDesaturated(true)
        SetButtonGlow(btn, false)
        return
    end

    if job.hasPets and not job.hasNonPets and WhoDoesWhat.HunterPetRole then
        btn.icon:SetTexture(WhoDoesWhat.HunterPetRole.icon)
    else
        btn.icon:SetTexture(job.classInfo.classIcon)
    end
    btn.petBadge:SetShown(job.hasPets and job.hasNonPets)
    btn.count:SetText(job.covered .. "/" .. job.total)
    btn.count:SetTextColor(CountColor(job.covered, job.total))
    local ready = JobIsReady(job, nameToUnit)
    btn.icon:SetDesaturated(not ready)
    SetButtonGlow(btn, ready)
end

local function FindBlessing(unit, greaterName, normalName)
    if not unit then return nil, false end
    local i = 1
    if GetBuffDataByIndex then
        while true do
            local aura = GetBuffDataByIndex(unit, i)
            if not aura then break end
            if aura.name == greaterName or aura.name == normalName then
                return aura.expirationTime, true
            end
            i = i + 1
        end
    else
        while true do
            local name, _, _, _, _, expirationTime = UnitBuff(unit, i)
            if not name then break end
            if name == greaterName or name == normalName then
                return expirationTime, true
            end
            i = i + 1
        end
    end
    return nil, false
end

local function FindPlayerBlessing(p)
    return FindBlessing(p.castUnit, p.greaterName, p.normalName)
end

local function UpdatePlayerAura(p)
    local expirationTime, found = FindPlayerBlessing(p)
    local missing = p.castUnit and not found
    local inRange = not p.castUnit or TargetInRange(p.castUnit, p.normalSpellId)
    local remaining = found and expirationTime and expirationTime > 0
        and math.max(expirationTime - GetTime(), 0) or nil
    p.missing:SetShown(missing)
    SetButtonGlow(p, missing and inRange and p:GetParent():IsShown(), MISSING_GLOW_COLOR, 1)
    if not inRange then
        p.bg:SetColorTexture(0.14, 0.09, 0.09, 0.96)
        p.outline:SetColorTexture(0.055, 0.035, 0.035, 1)
    elseif found or not p.castUnit then
        if remaining and remaining < 300
            and WhoDoesWhat.db.profile.settings.buffingMenuWarnExpiring then
            p.bg:SetColorTexture(0.38, 0.29, 0.03, 0.96)
            p.outline:SetColorTexture(0.16, 0.11, 0.01, 1)
        else
            p.bg:SetColorTexture(0.08, 0.28, 0.08, 0.96)
            p.outline:SetColorTexture(0.02, 0.11, 0.02, 1)
        end
    else
        p.bg:SetColorTexture(0.34, 0.07, 0.07, 0.96)
        p.outline:SetColorTexture(1, 0.45, 0.04, 1)
    end
    p.icon:SetDesaturated(not inRange)
    p.specIcon:SetDesaturated(not inRange)
    local textShade = inRange and 1 or 0.6
    local color = p.nameColor
    p.name:SetTextColor(color.r * textShade, color.g * textShade, color.b * textShade)
    p.timer:SetTextColor(textShade, textShade, textShade)
    if remaining then
        local minutes = math.floor(remaining / 60)
        p.timer:SetFormattedText("%d:%02d", minutes, math.floor(remaining - minutes * 60))
    else
        p.timer:SetText("")
    end
end

-- Repaint one existing player row from the current plan. The caller handles
-- protected spell attributes separately so this remains safe during combat.
local function UpdatePlayerStatus(p, member, job, unit)
    local normalMeta = WhoDoesWhat.PaladinBuffs[member.key]
    local greater = job.greaterBuff and GetSpellInfo(job.greaterBuff.spellId)
    local plannedGreater = normalMeta and GetSpellInfo(normalMeta.spellId)
    local normal = normalMeta and GetSpellInfo(normalMeta.normalSpellId)

    p.member, p.job, p.castUnit = member, job, unit
    p.greaterName, p.normalName = plannedGreater, normal
    p.normalSpellId = normalMeta and normalMeta.normalSpellId
    p.icon:SetTexture(member.isGreater and job.greaterBuff.icon
        or (normalMeta and normalMeta.normalIcon))
    if member.isPet then
        p.specIcon:SetTexture(WhoDoesWhat.HunterPetRole.icon)
    else
        local roleId = WhoDoesWhat:GetAssignedRole(member.name)
        local role = roleId and select(2, WhoDoesWhat:FindRoleById(roleId))
        p.specIcon:SetTexture((role and role.icon) or job.classInfo.classIcon)
    end
    p.name:SetText(member.name:gsub("%-.*$", ""))
    p.nameColor = (member.classInfo or job.classInfo).colorRGB
    UpdatePlayerAura(p)
    return member.isGreater and greater or normal, normal
end

local function CreatePlayerButton(btn, index)
    local p = CreateFrame("Button", btn:GetName() .. "Player" .. index, btn.playerMenu,
        "SecureActionButtonTemplate")
    p:RegisterForClicks("AnyUp", "AnyDown")
    p:SetSize(PLAYER_W, PLAYER_H)

    local outline = p:CreateTexture(nil, "BACKGROUND", nil, 0)
    outline:SetAllPoints()
    p.outline = outline

    local outlinePulse = outline:CreateAnimationGroup()
    outlinePulse:SetLooping("BOUNCE")
    local pulseAlpha = outlinePulse:CreateAnimation("Alpha")
    pulseAlpha:SetFromAlpha(0.35)
    pulseAlpha:SetToAlpha(1)
    pulseAlpha:SetDuration(0.9)
    p.outlinePulse = outlinePulse

    local bg = p:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    p.bg = bg

    local icon = p:CreateTexture(nil, "ARTWORK")
    icon:SetSize(PLAYER_H - 4, PLAYER_H - 4)
    icon:SetPoint("LEFT", 2, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    p.icon = icon

    local specIcon = p:CreateTexture(nil, "ARTWORK")
    specIcon:SetSize(PLAYER_H - 4, PLAYER_H - 4)
    specIcon:SetPoint("LEFT", icon, "RIGHT", 3, 0)
    specIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    p.specIcon = specIcon

    local name = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("LEFT", specIcon, "RIGHT", 5, 0)
    name:SetPoint("RIGHT", -55, 0)
    name:SetJustifyH("LEFT")
    local font, size = name:GetFont()
    if font then name:SetFont(font, size, "OUTLINE") end
    p.name = name

    local timer = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timer:SetPoint("RIGHT", -2, 0)
    timer:SetWidth(36)
    timer:SetJustifyH("RIGHT")
    p.timer = timer

    local missing = p:CreateTexture(nil, "OVERLAY")
    missing:SetSize(16, 16)
    missing:SetPoint("RIGHT", -2, 0)
    missing:SetTexture(MISSING_ICON)
    missing:Hide()
    p.missing = missing

    local highlight = p:CreateTexture(nil, "BACKGROUND", nil, 2)
    highlight:SetPoint("TOPLEFT", 1, -1)
    highlight:SetPoint("BOTTOMRIGHT", -1, 1)
    highlight:SetColorTexture(1, 1, 1, 0.1)
    p:SetHighlightTexture(highlight)
    p:SetScript("PostClick", function(self, mouseButton)
        if not WhoDoesWhat.db.profile.settings.logBuffingBarClicks or not self.member then return end
        WhoDoesWhat:Print("Buffing bar player click: " .. tostring(mouseButton)
            .. " -> " .. self.member.name .. ".")
    end)
    btn.playerButtons[index] = p
    return p
end

local function ConfigurePlayerMenu(btn, job, nameToUnit)
    local menu = btn.playerMenu
    local shown, covered = 0, 0
    local color = job.classInfo.colorRGB
    menu:SetBackdropColor(0.04 + color.r * 0.18,
        0.04 + color.g * 0.18, 0.04 + color.b * 0.18, 0.97)
    menu.headerBg:SetColorTexture(0.02 + color.r * 0.16,
        0.02 + color.g * 0.16, 0.02 + color.b * 0.16, 1)
    local members = {}
    for i, member in ipairs(job.raiders) do members[i] = member end
    table.sort(members, function(a, b)
        if (a.isPet or false) ~= (b.isPet or false) then return not a.isPet end
        if a.isGreater ~= b.isGreater then return a.isGreater end
        local ac = (a.classInfo or job.classInfo).name
        local bc = (b.classInfo or job.classInfo).name
        if ac ~= bc then return ac < bc end
        local ar = a.isPet and math.huge or WhoDoesWhat:RoleSortRank(a.name)
        local br = b.isPet and math.huge or WhoDoesWhat:RoleSortRank(b.name)
        if ar ~= br then return ar < br end
        return a.name < b.name
    end)
    for _, member in ipairs(members) do
        local unit = CastUnit(member, nameToUnit)
        local connectionUnit = member.isPet and nameToUnit[member.owner] or unit
        if not connectionUnit or UnitIsConnected(connectionUnit) ~= false then
            shown = shown + 1
            if member.has == true then covered = covered + 1 end
            local p = btn.playerButtons[shown] or CreatePlayerButton(btn, shown)
            local left, normal = UpdatePlayerStatus(p, member, job, unit)
            p:SetAlpha(1)
            p:SetAttribute("type1", unit and left and "spell" or nil)
            p:SetAttribute("spell1", unit and left or nil)
            p:SetAttribute("unit1", unit)
            p:SetAttribute("type2", unit and normal and "spell" or nil)
            p:SetAttribute("spell2", unit and normal or nil)
            p:SetAttribute("unit2", unit)
            p:Show()
        end
    end
    menu:SetAttribute("Display", shown > 0 and 1 or 0)
    menu:SetSize(PLAYER_MENU_W, INSET * 2 + PLAYER_HEADER_H + PLAYER_GAP
        + math.max(shown, 1) * PLAYER_H + math.max(shown - 1, 0) * PLAYER_GAP)
    menu.count:SetText(covered .. "/" .. shown)
    menu.count:SetTextColor(CountColor(covered, shown))
    for i = shown + 1, #btn.playerButtons do
        local p = btn.playerButtons[i]
        SetButtonGlow(p, false)
        p:Hide()
        p.member, p.job, p.castUnit = nil, nil, nil
        p.greaterName, p.normalName = nil, nil
        p.normalSpellId = nil
        p.nameColor = nil
        p:SetAttribute("type1", nil)
        p:SetAttribute("type2", nil)
    end
end

-- Role/plan changes can repaint existing rows in combat, but protected click
-- attributes and row ordering remain baked until PLAYER_REGEN_ENABLED.
local function UpdatePlayerMenuStatus(btn, job, nameToUnit)
    local byName = {}
    for _, member in ipairs(job.raiders) do byName[member.name] = member end
    local shown, covered = 0, 0
    for _, p in ipairs(btn.playerButtons) do
        local member = p:IsShown() and p.member and byName[p.member.name]
        if member then
            shown = shown + 1
            if member.has == true then covered = covered + 1 end
            UpdatePlayerStatus(p, member, job, CastUnit(member, nameToUnit))
        end
    end
    btn.playerMenu.count:SetText(covered .. "/" .. shown)
    btn.playerMenu.count:SetTextColor(CountColor(covered, shown))
end

-- Use the saved direction when it fits; otherwise use the roomier side. The
-- popup is also clamped for unusually short screens or very large class pools.
local function PositionPlayerMenu(btn)
    local menu = btn.playerMenu
    local preferred = WhoDoesWhat.db.profile.settings.buffingMenuGrow or "DOWN"
    local screenTop = UIParent:GetTop() or UIParent:GetHeight()
    local screenBottom = UIParent:GetBottom() or 0
    local above = screenTop - (btn:GetTop() or screenTop)
    local below = (btn:GetBottom() or screenBottom) - screenBottom
    local needed = menu:GetHeight()
    local direction = preferred
    if preferred == "UP" and above < needed and below > above then
        direction = "DOWN"
    elseif preferred == "DOWN" and below < needed and above > below then
        direction = "UP"
    end

    menu:ClearAllPoints()
    if direction == "UP" then
        menu:SetPoint("BOTTOMLEFT", btn, "TOPLEFT", 0, 0)
    else
        menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, 0)
    end
    for i, p in ipairs(btn.playerButtons) do
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", menu, "TOPLEFT", INSET,
            -(INSET + PLAYER_HEADER_H + PLAYER_GAP
                + (i - 1) * (PLAYER_H + PLAYER_GAP)))
    end
end

local function WirePlayerMenus()
    if bar.menusWired == #bar.buttons then return end
    for _, btn in ipairs(bar.buttons) do
        btn:Execute("otherMenus = newtable()")
        for _, other in ipairs(bar.buttons) do
            if other ~= btn then
                SecureHandlerSetFrameRef(btn, "otherMenu", other.playerMenu)
                btn:Execute([[
                    local menu = self:GetFrameRef("otherMenu")
                    otherMenus[#otherMenus + 1] = menu
                ]])
            end
        end
    end
    bar.menusWired = #bar.buttons
end

-- Pooled button #index; RefreshBar fills .job and positions it. Secure so it
-- can cast blessings on click: the SecureHandler template supplies Execute /
-- WrapScript (ConfigureButtonCast), SecureActionButtonTemplate the macro cast.
local function CreateButton(index)
    local btn = CreateFrame("Button", "WhoDoesWhatBuffingBarButton" .. index, bar,
        "SecureHandlerShowHideTemplate, SecureHandlerEnterLeaveTemplate, "
        .. "SecureHandlerStateTemplate, SecureActionButtonTemplate")
    -- Secure action buttons obey ActionButtonUseKeyDown. Register both so the
    -- cast works with either client setting (PallyPower does the same).
    btn:RegisterForClicks("AnyUp", "AnyDown")
    btn:SetSize(BTN_SIZE, BTN_SIZE)

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 0.9)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- trim the default icon border
    btn.icon = icon

    -- Small hunter-pet badge tucked into the bottom-right corner (inside the
    -- button), shown when a class button also carries pets (Warrior + pets). A
    -- 1px black frame matches the main icon's border; same icon-trim TexCoord.
    local petBadge = CreateFrame("Frame", nil, btn)
    petBadge:SetSize(BTN_SIZE * 0.44, BTN_SIZE * 0.44)
    petBadge:SetPoint("BOTTOMRIGHT", -1, 1)
    local badgeBorder = petBadge:CreateTexture(nil, "OVERLAY", nil, 1)
    badgeBorder:SetPoint("TOPLEFT", -1, 1)
    badgeBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    badgeBorder:SetColorTexture(0, 0, 0, 0.9)
    local badgeIcon = petBadge:CreateTexture(nil, "OVERLAY", nil, 2)
    badgeIcon:SetAllPoints()
    badgeIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    badgeIcon:SetTexture(WhoDoesWhat.HunterPetRole and WhoDoesWhat.HunterPetRole.icon)
    petBadge:Hide()
    btn.petBadge = petBadge

    local count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("TOP", btn, "BOTTOM", 0, -1)
    btn.count = count

    local playerMenu = CreateFrame("Frame", btn:GetName() .. "PlayerMenu", btn,
        "SecureHandlerShowHideTemplate, BackdropTemplate")
    playerMenu:SetFrameStrata("DIALOG")
    playerMenu:SetClampedToScreen(true)
    playerMenu:EnableMouse(true)
    playerMenu:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = INSET, right = INSET, top = INSET, bottom = INSET },
    })
    playerMenu:SetBackdropColor(0.14, 0.14, 0.16, 0.97)
    playerMenu:SetBackdropBorderColor(0.4, 0.4, 0.4)

    local headerBg = playerMenu:CreateTexture(nil, "ARTWORK")
    headerBg:SetPoint("TOPLEFT", INSET, -INSET)
    headerBg:SetPoint("TOPRIGHT", -INSET, -INSET)
    headerBg:SetHeight(PLAYER_HEADER_H)
    headerBg:SetColorTexture(0.09, 0.09, 0.11, 1)
    playerMenu.headerBg = headerBg

    local clickHint = playerMenu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    clickHint:SetPoint("TOPLEFT", headerBg, "TOPLEFT", 4, -2)
    clickHint:SetText("Left-click = shown buff\nRight-click = Lesser")
    clickHint:SetTextColor(0.4, 0.7, 1)
    clickHint:SetJustifyH("LEFT")

    local menuCount = playerMenu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    menuCount:SetPoint("RIGHT", headerBg, "RIGHT", -4, 0)
    playerMenu.count = menuCount

    playerMenu:Hide()
    btn.playerMenu = playerMenu
    btn.playerButtons = {}
    playerMenu:HookScript("OnShow", function()
        for _, p in ipairs(btn.playerButtons) do
            if p:IsShown() then UpdatePlayerAura(p) end
        end
    end)
    playerMenu:HookScript("OnHide", function()
        for _, p in ipairs(btn.playerButtons) do SetButtonGlow(p, false) end
    end)
    SecureHandlerSetFrameRef(btn, "playerMenu", playerMenu)
    btn:Execute("otherMenus = newtable()")
    btn:SetAttribute("_onenter", [[
        for _, menu in ipairs(otherMenus) do menu:Hide() end
        local menu = self:GetFrameRef("playerMenu")
        if menu:GetAttribute("Display") == 1 then
            menu:Show()
            menu:RegisterAutoHide(0.25)
            menu:AddToAutoHide(self)
        end
    ]])

    btn:SetScript("PostClick", function(self, mouseButton)
        if not WhoDoesWhat.db.profile.settings.logBuffingBarClicks then return end
        local job = self.job
        if not job then
            WhoDoesWhat:Print("Buffing bar click: " .. tostring(mouseButton)
                .. " (no job configured).")
            return
        end

        local action, choices
        if mouseButton == "LeftButton" then
            action = job.greaterBuff
                and ("Greater Blessing of " .. job.greaterBuff.name_long)
                or "no Greater Blessing"
            choices = self.gCastCount or 0
        elseif mouseButton == "RightButton" then
            action = "individual blessing"
            choices = self.nCastCount or 0
        else
            action = "unmapped input"
            choices = 0
        end

        local test = WhoDoesWhat.db.profile.settings.buffingBarTestMode
            and " [test mode]" or ""
        WhoDoesWhat:Print("Buffing bar click: " .. tostring(mouseButton) .. " -> "
            .. job.classInfo.name .. " " .. action .. " (" .. choices
            .. " castable target" .. (choices == 1 and "" or "s") .. ")." .. test)
    end)

    bar.buttons[index] = btn
    return btn
end

-- ---------------------------------------------------------------------------
-- Secure casting (rotate through targets) -- PallyPower's proven pattern
-- ---------------------------------------------------------------------------

-- The wrapped OnClick runs in the button's restricted environment. Left-click
-- casts the class Greater (gSpell) on the next class member (gNames); right
-- click cycles every assigned member's planned Lesser (nNames/nSpells). The
-- Lesser list is baked missing-first, then by shortest remaining duration.
-- Each side rotates its own step and points its macrotext at a live friendly
-- target before the matching macro fires. Set up out of combat; rotation works
-- during combat off the baked-in lists.
local ROTATE_SNIPPET = [==[
    if button == "LeftButton" then
        local n = table.maxn(gNames)
        if n > 0 and gSpell ~= "" then
            local step = self:GetAttribute("gstep") or 1
            if step > n then step = 1 end
            local name = gNames[step]
            if name and SecureCmdOptionParse("[@" .. name .. ",help,nodead]") then
                self:SetAttribute("macrotext1", "/cast [@" .. name .. ",help,nodead] " .. gSpell)
            end
            self:SetAttribute("gstep", step + 1)
        end
    elseif button == "RightButton" then
        local n = table.maxn(nNames)
        if n > 0 then
            local step = self:GetAttribute("nstep") or 1
            if step > n then step = 1 end
            local name = nNames[step]
            local spell = nSpells[step]
            if name and spell and SecureCmdOptionParse("[@" .. name .. ",help,nodead]") then
                self:SetAttribute("macrotext2", "/cast [@" .. name .. ",help,nodead] " .. spell)
            end
            self:SetAttribute("nstep", step + 1)
        end
    end
]==]

-- newtable(...) from a list of strings ("" -> empty), inside [=[ ]=] so spaces
-- and realm suffixes survive.
local function NewTable(list)
    if #list == 0 then return "newtable()" end
    return "newtable([=[" .. table.concat(list, "]=],[=[") .. "]=])"
end

-- Bake a button's two cast rotations from its class job. Secure attribute writes
-- are combat-locked, so this no-ops in combat and re-runs on the next
-- out-of-combat refresh (roster/aura changes and PLAYER_REGEN_ENABLED).
-- Fake/unresolved names are skipped -- nothing castable there. Rank-less spell
-- names cast the highest rank the paladin knows.
local function ConfigureButtonCast(btn, job, nameToUnit)
    if InCombatLockdown() then return end
    local gSpell = (job.greaterBuff and GetSpellInfo(job.greaterBuff.spellId)) or ""

    -- Left: any resolvable class member is a valid Greater target (non-pets
    -- come first, so a warrior is preferred over a pet when both are present).
    local gNames = {}
    for _, m in ipairs(job.raiders) do
        local unit = CastUnit(m, nameToUnit)
        if unit then gNames[#gNames + 1] = unit end
    end
    -- Right: every member's planned Lesser, not just exceptions to the class
    -- Greater. Missing buffs lead, followed by the soonest expiration, so the
    -- baked combat rotation naturally services the targets most in need first.
    local normalTargets = {}
    for _, member in ipairs(job.raiders) do
        local unit = CastUnit(member, nameToUnit)
        local meta = WhoDoesWhat.PaladinBuffs[member.key]
        local greater = meta and GetSpellInfo(meta.spellId)
        local normal = meta and GetSpellInfo(meta.normalSpellId)
        if unit and normal then
            local expiration, found = FindBlessing(unit, greater, normal)
            local remaining = found and expiration and expiration > 0
                and math.max(expiration - GetTime(), 0) or math.huge
            normalTargets[#normalTargets + 1] = {
                unit = unit, spell = normal,
                remaining = found and remaining or -1,
                name = member.name,
            }
        end
    end
    table.sort(normalTargets, function(a, b)
        if a.remaining ~= b.remaining then return a.remaining < b.remaining end
        return a.name < b.name
    end)
    local nNames, nSpells = {}, {}
    for _, target in ipairs(normalTargets) do
        nNames[#nNames + 1] = target.unit
        nSpells[#nSpells + 1] = target.spell
    end
    btn.gCastCount = #gNames
    btn.nCastCount = #nNames

    btn:SetAttribute("type1", "macro")
    btn:SetAttribute("type2", "macro")
    btn:SetAttribute("nstep", 1)
    btn:Execute("gSpell = [=[" .. gSpell .. "]=]\n"
        .. "gNames = " .. NewTable(gNames) .. "\n"
        .. "nNames = " .. NewTable(nNames) .. "\n"
        .. "nSpells = " .. NewTable(nSpells) .. "\n")
    if not btn.castWrapped then
        btn:SetAttribute("gstep", 1)
        btn:WrapScript(btn, "OnClick", ROTATE_SNIPPET)
        btn.castWrapped = true
    end
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

local function EnsureBar()
    if bar then return bar end

    bar = CreateFrame("Frame", "WhoDoesWhatBuffingBar", UIParent, "BackdropTemplate")
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    -- Match the other WDW windows: dark fill, thin tooltip border.
    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = INSET, right = INSET, top = INSET, bottom = INSET },
    })
    bar:SetBackdropColor(0, 0, 0, 0.95)
    bar:SetBackdropBorderColor(0.4, 0.4, 0.4)
    AttachAltDrag(bar)

    -- Title strip ("WDW Buffs"), also a drag handle; hover explains Alt-drag.
    local title = CreateFrame("Frame", nil, bar)
    title:SetHeight(TITLE_H)
    title:SetPoint("TOPLEFT", INSET, -INSET)
    title:SetPoint("TOPRIGHT", -INSET, -INSET)
    local titleBg = title:CreateTexture(nil, "ARTWORK")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(0.12, 0.12, 0.15, 1)
    local titleText = title:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleText:SetPoint("LEFT", 5, 0)
    titleText:SetText("WDW Buffs")
    AttachAltDrag(title)
    title:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("WDW Buffs", 1, 1, 1)
        GameTooltip:AddLine("Alt-drag to move.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    title:SetScript("OnLeave", function() GameTooltip:Hide() end)
    bar.title = title

    -- Shown when the resolved paladin has no assigned blessings.
    local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOP", 0, -CONTENT_TOP)
    hint:SetTextColor(0.6, 0.6, 0.6)
    bar.hint = hint

    bar.buttons = {}
    LoadPosition()

    -- Roster changes shift the plan; leaving combat lets us (re)bake the secure
    -- cast rotations we couldn't touch mid-fight. Repaint on both.
    bar:RegisterEvent("GROUP_ROSTER_UPDATE")
    bar:RegisterEvent("PLAYER_REGEN_ENABLED")
    bar:SetScript("OnEvent", function(self)
        if self:IsShown() then WhoDoesWhat:RefreshPaladinBuffingBar() end
    end)

    -- Range shifts as people (and you) move, which fires no events, so
    -- re-evaluate the grey/glow of the current visual jobs on a light throttle.
    -- Coverage and the plan itself still recompute on the refresh path.
    bar.rangeTick = 0
    bar:SetScript("OnUpdate", function(self, elapsed)
        self.rangeTick = self.rangeTick + elapsed
        if self.rangeTick < 0.5 then return end
        self.rangeTick = 0
        local nameToUnit = BuildNameToUnit()
        for _, btn in ipairs(self.buttons) do
            local job = btn.visualJob
            if job and btn:IsShown() then
                local ready = JobIsReady(job, nameToUnit)
                btn.icon:SetDesaturated(not ready)
                SetButtonGlow(btn, ready)
                if btn.playerMenu:IsShown() then
                    for _, p in ipairs(btn.playerButtons) do
                        if p:IsShown() then UpdatePlayerAura(p) end
                    end
                end
            end
        end
    end)

    return bar
end

-- ---------------------------------------------------------------------------
-- Refresh + visibility
-- ---------------------------------------------------------------------------

-- Repaint the bar's buttons from the resolved paladin's jobs. Only touches the
-- widgets; visibility is handled by UpdatePaladinBuffingBarVisibility.
function WhoDoesWhat:RefreshPaladinBuffingBar()
    if not bar or not bar:IsShown() then return end
    local paladin = ResolveBarPaladin()
    local allJobs = paladin and self.Assign.GetPaladinBuffJobs(paladin) or {}
    -- Drop classes with no real raiders to buff (read 0/0) -- nothing to show.
    local jobs = {}
    for _, job in ipairs(allJobs) do
        if job.total > 0 then jobs[#jobs + 1] = job end
    end
    local nameToUnit = BuildNameToUnit()

    -- Existing secure buttons may repaint in combat, but cannot be created,
    -- shown, hidden, moved, or assigned new spells/targets. Match by class so
    -- a changed job never paints over a button whose baked click action belongs
    -- to another class; PLAYER_REGEN_ENABLED performs the full rebuild later.
    if InCombatLockdown() then
        local jobsByClass = {}
        for _, job in ipairs(jobs) do jobsByClass[job.classInfo.name] = job end
        for _, btn in ipairs(bar.buttons) do
            if btn:IsShown() then
                local className = btn.job and btn.job.classInfo.name
                local job = className and jobsByClass[className]
                UpdateButtonStatus(btn, job, nameToUnit)
                if job then UpdatePlayerMenuStatus(btn, job, nameToUnit) end
            end
        end
        return
    end

    for i, job in ipairs(jobs) do
        local btn = bar.buttons[i]
        if not btn then
            btn = CreateButton(i)
        end
        btn.job = job
        ConfigureButtonCast(btn, job, nameToUnit)
        ConfigurePlayerMenu(btn, job, nameToUnit)
        UpdateButtonStatus(btn, job, nameToUnit)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", bar, "TOPLEFT",
            INSET + PAD + (i - 1) * (BTN_SIZE + BTN_GAP), -CONTENT_TOP)
        btn:Show()
    end
    for i = #jobs + 1, #bar.buttons do
        SetButtonGlow(bar.buttons[i], false)
        bar.buttons[i].playerMenu:SetAttribute("Display", 0)
        bar.buttons[i].playerMenu:Hide()
        bar.buttons[i]:Hide()
        bar.buttons[i].job = nil
        bar.buttons[i].visualJob = nil
    end

    local n = #jobs
    bar.hint:SetShown(n == 0)
    if n == 0 then
        bar.hint:SetText(paladin
            and (paladin .. " has no assigned blessings.")
            or "No Paladin selected for testing.")
        bar:SetSize(200, CONTENT_TOP + 18 + INSET)
    else
        bar:SetSize(INSET * 2 + PAD * 2 + n * BTN_SIZE + (n - 1) * BTN_GAP,
            CONTENT_TOP + BTN_SIZE + COUNT_H + INSET + 1)
    end
    WirePlayerMenus()
    for i = 1, n do PositionPlayerMenu(bar.buttons[i]) end
end

-- Show or hide the whole bar based on the master/test toggles, then repaint.
-- Test mode stays visible without a paladin so roster updates can fill it in.
function WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
    local paladin = ResolveBarPaladin()
    if not paladin and not self.db.profile.settings.buffingBarTestMode then
        if bar then
            for _, b in ipairs(bar.buttons) do SetButtonGlow(b, false) end
            bar:Hide()
        end
        return
    end
    local f = EnsureBar()
    f:Show()
    self:RefreshPaladinBuffingBar()
end

-- Bring the bar up immediately on login/reload if it was left enabled, then
-- repaint once more after the roster and synced plan have had time to arrive.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function()
    WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
    C_Timer.After(2, function() WhoDoesWhat:UpdatePaladinBuffingBarVisibility() end)
end)
