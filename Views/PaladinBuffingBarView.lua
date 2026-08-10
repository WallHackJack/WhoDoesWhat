local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- The Paladin Buffing Bar: a movable Nova-style strip of one button per CLASS
-- the active WDW/PallyPower source assigns to the local paladin
-- (WhoDoesWhat.Assign.GetPaladinBuffJobs),
-- each showing the class icon and a coloured "buffed/total" count. Left-click
-- casts the class's Greater Blessing on a class member (buffs the whole class);
-- right-click cycles every assigned member's planned Lesser Blessing, with
-- missing/lowest-timer targets first -- see the secure-casting section below.
-- Hovering a class button opens a secure
-- per-player menu: left-click casts the class Greater for majority-assigned
-- players; both clicks cast the planned Normal blessing for exceptions.
--
-- Two optional self-buff buttons lead the row, split off by a hairline: an
-- aura swapper (hovering opens a picker of every castable aura, left-click
-- casts whichever one it is currently offering) and,
-- while the paladin holds a tank role, a Righteous Fury refresher. Unlike the
-- class buttons these are about the LOCAL player, and neither carries a
-- coverage count -- just a red glow when the buff is missing, yellow with a
-- countdown when Righteous Fury is nearly out.
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
local MIN_BUTTONS_WIDE = 3
local COUNT_H = 10     -- room under a button for its count text
local PLAYER_MENU_W = 180
local PLAYER_HEADER_H = 24
local PLAYER_W = PLAYER_MENU_W - INSET * 2
local PLAYER_H = 22
local PLAYER_GAP = 0
local AURA_MENU_LABEL_H = 12 -- row caption above each block of aura icons
local AURA_MENU_ROW_GAP = 4
local MISSING_ICON = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local MISSING_GLOW_COLOR = { 1, 0.05, 0.05, 1 }
local EXPIRING_GLOW_COLOR = { 1, 0.82, 0.2, 1 }
local PP_GEAR_ICON = "Interface\\Icons\\Trade_Engineering"
local PP_GLOW_COLOR = { 0.55, 0.55, 0.55, 1 }
local DIVIDER_GAP = 9  -- gap holding the self-buff/class-button divider
local DIVIDER_W = 1
local RIGHTEOUS_FURY_WARN = 600 -- seconds left before the timer turns yellow
-- Title strip: which board the bar is casting off, shown as its own small grey
-- token at the right end of the strip.
local SOURCE_LABELS = { wdw = "WDW", pallypower = "PP" }
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

-- Save the current on-screen rect, anchoring by the part of the bar that must
-- hold still as buttons come and go: the left edge for RIGHT growth, the right
-- edge for LEFT, and the horizontal midpoint for CENTER (which then spreads
-- both ways). The anchor point encodes the choice, so a saved position is
-- self-describing and a mode change just re-derives it from the current rect.
local GROW_POINTS = { RIGHT = "TOPLEFT", LEFT = "TOPRIGHT", CENTER = "TOP" }

local function ClampPosition(x, y, point)
    local parentW, parentH = UIParent:GetWidth(), UIParent:GetHeight()
    local width = bar:GetWidth()
    if point == "TOPRIGHT" then
        x = math.max(math.min(width, parentW), math.min(x, parentW))
    elseif point == "TOP" then
        -- x is the midpoint, so both halves have to stay on screen.
        local half = math.min(width / 2, parentW / 2)
        x = math.max(half, math.min(x, parentW - half))
    else
        x = math.max(0, math.min(x, math.max(0, parentW - width)))
    end
    y = math.max(math.min(bar:GetHeight(), parentH), math.min(y, parentH))
    return x, y
end

local function SavePosition()
    if not bar then return end
    local grow = WhoDoesWhat.db.profile.settings.buffingBarGrow or "RIGHT"
    local point = GROW_POINTS[grow] or GROW_POINTS.RIGHT
    local x
    if point == "TOPRIGHT" then
        x = bar:GetRight()
    elseif point == "TOP" then
        x = bar:GetCenter()
    else
        x = bar:GetLeft()
    end
    local y = bar:GetTop()
    if not x or not y then return end
    x, y = ClampPosition(x, y, point)
    WhoDoesWhat.db.profile.settings.buffingBarPos = { point = point, x = x, y = y }
end

local function LoadPosition()
    local p = WhoDoesWhat.db.profile.settings.buffingBarPos
    bar:ClearAllPoints()
    if p and p.x and p.y then
        local point = (p.point == "TOPRIGHT" or p.point == "TOP")
            and p.point or "TOPLEFT"
        p.point = point
        p.x, p.y = ClampPosition(p.x, p.y, point)
        bar:SetPoint(point, UIParent, "BOTTOMLEFT", p.x, p.y)
    else
        bar:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
    end
end

-- Attach Alt-gated dragging to a mouse region that moves the whole bar.
local function AttachAltDrag(region)
    region:EnableMouse(true)
    region:RegisterForDrag("LeftButton")
    region:SetScript("OnDragStart", function()
        if not IsAltKeyDown() then return end
        bar.moving = true
        bar:StartMoving()
    end)
    region:SetScript("OnDragStop", function()
        if not bar.moving then return end
        bar.moving = nil
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
-- Nova-style pixel glow. Track state so refreshes don't restart animations --
-- including the colour, since the self-buff buttons switch between the red
-- "missing" and yellow "expiring soon" glows in place.
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
        -- Colours are module constants, so identity is the whole comparison.
        if not btn.glowing or btn.glowColor ~= color then
            if btn.glowing then LCG.PixelGlow_Stop(btn) end
            local offset, border = nil, true
            if inset then offset, border = -inset, false end
            LCG.PixelGlow_Start(btn, color, 16, nil, 3, nil,
                offset, offset, border, nil, 4)
            btn.glowing, btn.glowColor = true, color
        end
    elseif btn.glowing then
        LCG.PixelGlow_Stop(btn)
        btn.glowing, btn.glowColor = false, nil
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

local function CountUnassignedClassBuffs(paladin, buffPlan, members)
    if not paladin then return 0 end
    local activeClasses = {}
    for _, member in ipairs(members or WhoDoesWhat:GetGroupMembers(nil)) do
        if not member.isFake and not WhoDoesWhat:IsNonRaider(member.name) then
            activeClasses[member.classInfo.name] = true
        end
    end
    local assigned = buffPlan and buffPlan.greaterByPaladin
        and buffPlan.greaterByPaladin[paladin] or {}
    local unassigned = 0
    for className in pairs(activeClasses) do
        if not assigned[className] then unassigned = unassigned + 1 end
    end
    return unassigned
end

-- Small in-game check for the PP companion count: duplicate raiders count as
-- one class, and fake development members never contribute.
function WhoDoesWhat:TestPallyPowerBuffButtonCount()
    local paladin = "__WDWTestPaladin"
    local warrior = { name = "__WDWTestWarrior", classInfo = { name = "Warrior" } }
    local mage = { name = "__WDWTestMage", classInfo = { name = "Mage" } }
    local plan = { greaterByPaladin = { [paladin] = { Warrior = "might" } } }
    assert(CountUnassignedClassBuffs(paladin, plan,
        { warrior, mage, { name = "__WDWTestMageTwo", classInfo = mage.classInfo } }) == 1)
    plan.greaterByPaladin[paladin].Mage = "wisdom"
    assert(CountUnassignedClassBuffs(paladin, plan,
        { warrior, mage, { name = "Fake", classInfo = { name = "Priest" }, isFake = true } }) == 0)
    self:Print("PallyPower buff-button count check passed.")
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

-- Which way something hanging off `btn` should open: the saved direction when
-- it fits, otherwise the roomier side. Shared by the class buttons' player
-- menus and the self-buff tooltips, so everything the bar pops out follows the
-- one setting and clamps the same way on short screens.
local function PopoutDirection(btn, needed)
    local preferred = WhoDoesWhat.db.profile.settings.buffingMenuGrow or "DOWN"
    local screenTop = UIParent:GetTop() or UIParent:GetHeight()
    local screenBottom = UIParent:GetBottom() or 0
    local above = screenTop - (btn:GetTop() or screenTop)
    local below = (btn:GetBottom() or screenBottom) - screenBottom
    if preferred == "UP" and above < needed and below > above then
        return "DOWN"
    elseif preferred == "DOWN" and below < needed and above > below then
        return "UP"
    end
    return preferred
end

local function PositionPlayerMenu(btn)
    local menu = btn.playerMenu
    local direction = PopoutDirection(btn, menu:GetHeight())

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

-- Give every hoverable button the list of popouts it must close on the way in,
-- so moving along the row swaps menus at once instead of waiting out the
-- previous one's auto-hide. The self-buff buttons join the class buttons here:
-- the aura swapper owns a popout of its own, Righteous Fury owns none and only
-- does the closing.
local function WirePopoutMenus()
    if bar.menusWired == #bar.buttons then return end
    local owners = {}
    for _, btn in ipairs(bar.buttons) do
        owners[#owners + 1] = { btn = btn, menu = btn.playerMenu }
    end
    owners[#owners + 1] = { btn = bar.auraButton, menu = bar.auraButton.auraMenu }
    owners[#owners + 1] = { btn = bar.rfButton }
    for _, owner in ipairs(owners) do
        owner.btn:Execute("otherMenus = newtable()")
        for _, other in ipairs(owners) do
            if other ~= owner and other.menu then
                SecureHandlerSetFrameRef(owner.btn, "otherMenu", other.menu)
                owner.btn:Execute([[
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

local function CreatePallyPowerButton()
    local btn = CreateFrame("Button", "WhoDoesWhatBuffingBarPallyPowerButton", bar)
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetSize(BTN_SIZE, BTN_SIZE)

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 0.9)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(PP_GEAR_ICON)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetDesaturated(true)
    icon:SetVertexColor(0.65, 0.65, 0.65)
    btn.icon = icon

    local count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("TOP", btn, "BOTTOM", 0, -1)
    count:SetTextColor(0.65, 0.65, 0.65)
    btn.count = count

    btn:SetScript("OnEnter", function(self)
        local unassigned = self.unassignedCount or 0
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("PallyPower Blessings", 1, 1, 1)
        GameTooltip:AddLine(unassigned .. " active raid class"
            .. (unassigned == 1 and " has" or "es have")
            .. " no blessing assignment for this paladin."
            .. " Pets and Non-raiders are excluded.",
            0.8, 0.8, 0.8, true)
        if _G.PallyPower and type(_G.PallyPowerBlessings_Toggle) == "function" then
            GameTooltip:AddLine("Click to open /pp blessings.", 0.4, 0.7, 1, true)
        else
            GameTooltip:AddLine("PallyPower is not installed; assignments are"
                .. " coming from observed PallyPower traffic.", 1, 0.82, 0, true)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btn:SetScript("OnClick", function()
        if not (_G.PallyPower
            and type(_G.PallyPowerBlessings_Toggle) == "function") then
            WhoDoesWhat:Print("PallyPower is not installed; its Blessings window is unavailable.")
        elseif InCombatLockdown() then
            WhoDoesWhat:Print("PallyPower Blessings cannot be opened during combat.")
        else
            _G.PallyPowerBlessings_Toggle()
        end
    end)
    btn:Hide()
    return btn
end

local function UpdatePallyPowerButton(btn, paladin, buffPlan)
    btn.unassignedCount = CountUnassignedClassBuffs(paladin, buffPlan)
    btn.count:SetText(btn.unassignedCount)
    SetButtonGlow(btn, true, PP_GLOW_COLOR)
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
-- Self-buff buttons (aura swapper, Righteous Fury)
-- ---------------------------------------------------------------------------

-- These two sit at the left end of the row, split from the class buttons by a
-- hairline, and are the only part of the bar that is about the LOCAL player
-- rather than the plan: both cast on yourself. Test mode still renders them so
-- the layout can be previewed from a non-paladin, but only a real paladin has
-- anything to cast.

local AURAS = WhoDoesWhat.PaladinAuras
local RIGHTEOUS_FURY = WhoDoesWhat.RighteousFury

-- Name sets for the self-buff scan below.
local AURA_NAMES = {}
for _, aura in ipairs(AURAS) do AURA_NAMES[aura.name] = true end
local RIGHTEOUS_FURY_NAMES = { [RIGHTEOUS_FURY.name] = true }

-- The first of `wanted` (a set of spell names) currently up on the player,
-- with its expiration time. Auras and Righteous Fury are self-buffs, so
-- "player" is the only unit these two buttons ever look at.
local function FindOwnBuff(wanted)
    local i = 1
    while true do
        local name, expiration
        if GetBuffDataByIndex then
            local aura = GetBuffDataByIndex("player", i)
            if not aura then return nil end
            name, expiration = aura.name, aura.expirationTime
        else
            local buffName, _, _, _, _, expirationTime = UnitBuff("player", i)
            if not buffName then return nil end
            name, expiration = buffName, expirationTime
        end
        if wanted[name] then return name, expiration end
        i = i + 1
    end
end

-- Auras this paladin can actually cast. GetSpellInfo(name) only resolves for
-- spells in the player's own spellbook, which is what filters out the talent
-- auras (Concentration, Sanctity) and Crusader Aura before level 62. Test mode
-- keeps the full client list so the button previews sensibly on a non-paladin.
local function CastableAuras()
    if WhoDoesWhat.db.profile.settings.buffingBarTestMode then return AURAS end
    local out = {}
    for _, aura in ipairs(AURAS) do
        if GetSpellInfo(aura.name) then out[#out + 1] = aura end
    end
    return out
end

-- Where the saved choice lands in the current castable list. A respec or a
-- level-up reorders it, and a no-longer-known aura falls back to the first.
local function SelectedAuraStep(auras)
    local saved = WhoDoesWhat.db.profile.settings.buffingBarAura
    -- Nothing picked yet: adopt whatever the paladin is already running, so a
    -- first login doesn't open on a false "wrong aura" alarm.
    if not saved then
        local running = FindOwnBuff(AURA_NAMES)
        for i, aura in ipairs(auras) do
            if aura.name == running then return i end
        end
    end
    for i, aura in ipairs(auras) do
        if aura.key == saved then return i end
    end
    return 1
end

-- Hovering opens the aura picker, exactly as hovering a class button opens its
-- player menu -- including closing every other popout the bar owns on the way
-- in, so moving between buttons swaps menus with no auto-hide delay. Left-click
-- still casts whatever aura the button is offering.
local AURA_ENTER_SNIPPET = [==[
    for _, menu in ipairs(otherMenus) do menu:Hide() end
    local menu = self:GetFrameRef("auraMenu")
    if menu:GetAttribute("Display") == 1 then
        menu:Show()
        menu:RegisterAutoHide(0.25)
        menu:AddToAutoHide(self)
    end
]==]

-- Righteous Fury owns no popout, but sits right next to the swapper, so it
-- closes the others on the way in rather than leaving one hanging.
local CLOSE_MENUS_SNIPPET = [==[
    for _, menu in ipairs(otherMenus) do menu:Hide() end
]==]

-- One aura icon in the picker. Everything the click needs is baked onto the
-- option itself, so the swapper's offered aura can change mid-combat.
local AURA_OPTION_SNIPPET = [==[
    local swapper = self:GetFrameRef("auraButton")
    swapper:SetAttribute("astep", self:GetAttribute("astep"))
    swapper:SetAttribute("macrotext1", self:GetAttribute("auraMacro"))
    self:GetParent():Hide()
]==]

-- Every tooltip the bar owns -- the self-buff buttons and the title strip --
-- opens where the class buttons' player menus do rather than at Blizzard's
-- default anchor, so nothing on the bar ends up underneath it. The frame owns
-- a FillTooltip that writes its current state, and an optional tooltipAnchor
-- to hang off something other than itself (the title strip uses the whole bar,
-- which is what keeps the tooltip clear of the button row). GameTooltip only
-- knows its height once it's populated, so the final anchor lands after Show.
local function ShowBarTooltip(frame)
    local anchor = frame.tooltipAnchor or frame
    GameTooltip:SetOwner(frame, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, 0)
    frame:FillTooltip()
    GameTooltip:Show()
    GameTooltip:ClearAllPoints()
    if PopoutDirection(anchor, GameTooltip:GetHeight() or 0) == "UP" then
        GameTooltip:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 0)
    else
        GameTooltip:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, 0)
    end
end

-- Rebuild in place while the mouse is still on the frame, so a rotated aura,
-- a landed cast and a ticking Righteous Fury are all reflected without having
-- to leave and come back. Every repaint path calls this; it's a no-op unless
-- this frame owns the tooltip right now.
local function RefreshBarTooltip(frame)
    if GameTooltip:IsShown() and GameTooltip:GetOwner() == frame then
        ShowBarTooltip(frame)
    end
end

-- Shared chrome: a class-button-sized square with the same border, icon and
-- under-button text slot. That slot carries a countdown when one is worth
-- showing and stays empty otherwise -- there is no x/y coverage to report here.
local function CreateSelfBuffButton(name, template)
    local btn = CreateFrame("Button", name, bar, template)
    btn:SetSize(BTN_SIZE, BTN_SIZE)

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 0.9)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn.icon = icon

    local count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("TOP", btn, "BOTTOM", 0, -1)
    btn.count = count

    -- Hooked, not set: these carry secure enter/leave handlers from their
    -- templates, and SetScript would throw them away.
    btn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    btn:Hide()
    return btn
end

-- Repaint the picker's icons: gold border on the offered aura, full colour on
-- whichever one is actually running (the same "desaturated means not up"
-- language the swapper itself uses). Safe in combat -- no secure writes.
local function UpdateAuraMenu(btn)
    local menu = btn.auraMenu
    if not menu then return end
    local step = btn:GetAttribute("astep") or 1
    local running = btn.activeName
    for i, option in ipairs(menu.options) do
        if option:IsShown() then
            option.icon:SetDesaturated(option.aura.name ~= running)
            if i == step then
                option.border:SetColorTexture(1, 0.82, 0.2, 1)
            else
                option.border:SetColorTexture(0, 0, 0, 0.9)
            end
        end
    end
end

-- Repaint from the player's own buffs. Safe in combat: no secure attribute or
-- layout writes here.
local function UpdateAuraButton(btn)
    local auras = btn.auras or {}
    local selected = auras[btn:GetAttribute("astep") or 1]
    btn.selected = selected
    btn.activeName = FindOwnBuff(AURA_NAMES)
    btn.count:SetText("")
    if not selected then
        SetButtonGlow(btn, false)
        return
    end
    btn.icon:SetTexture(selected.icon)
    local running = (btn.activeName == selected.name)
    btn.icon:SetDesaturated(not running)
    SetButtonGlow(btn, not running, MISSING_GLOW_COLOR)
    UpdateAuraMenu(btn)
end

-- The picker itself: a small panel of aura icons hanging off the swapper, laid
-- out as captioned rows (the auras you actually run, then the situational
-- resistance ones). Built like the class buttons' player menus -- a protected
-- frame the secure snippet can show, closing itself on mouse-out.
local function CreateAuraMenu(btn)
    local menu = CreateFrame("Frame", btn:GetName() .. "Menu", btn,
        "SecureHandlerShowHideTemplate, BackdropTemplate")
    menu:SetFrameStrata("DIALOG")
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    menu:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = INSET, right = INSET, top = INSET, bottom = INSET },
    })
    menu:SetBackdropColor(0.14, 0.14, 0.16, 0.97)
    menu:SetBackdropBorderColor(0.4, 0.4, 0.4)

    -- Same header strip the class buttons' player menus carry, down to the
    -- geometry and colours: it stands in for the tooltip the swapper gave up.
    local headerBg = menu:CreateTexture(nil, "ARTWORK")
    headerBg:SetPoint("TOPLEFT", INSET, -INSET)
    headerBg:SetPoint("TOPRIGHT", -INSET, -INSET)
    headerBg:SetHeight(PLAYER_HEADER_H)
    headerBg:SetColorTexture(0.09, 0.09, 0.11, 1)

    local clickHint = menu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    clickHint:SetPoint("TOPLEFT", headerBg, "TOPLEFT", 4, -2)
    clickHint:SetText("Left-click = cast shown aura\nClick an icon = swap aura")
    clickHint:SetTextColor(0.4, 0.7, 1)
    clickHint:SetJustifyH("LEFT")

    menu:Hide()
    menu.options = {}
    menu.labels = {}
    menu.owner = btn
    btn.auraMenu = menu
    SecureHandlerSetFrameRef(btn, "auraMenu", menu)
    return menu
end

local function CreateAuraMenuLabel(menu, index)
    local label = menu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetJustifyH("LEFT")
    label:SetTextColor(0.7, 0.7, 0.7)
    menu.labels[index] = label
    return label
end

local function CreateAuraOption(menu, index)
    local option = CreateFrame("Button", menu:GetName() .. "Option" .. index, menu,
        "SecureHandlerClickTemplate")
    option:SetSize(BTN_SIZE, BTN_SIZE)
    option:RegisterForClicks("AnyUp")

    local border = option:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 0.9)
    option.border = border

    local icon = option:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    option.icon = icon

    local highlight = option:CreateTexture(nil, "OVERLAY")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.2)
    option:SetHighlightTexture(highlight)

    -- The client's own spell tooltip, so each icon reads exactly as it does in
    -- the spellbook (resistance amounts, mana drain, the lot). ConfigureAuraMenu
    -- resolves the rank actually known; SetSpellByID is missing on some Classic
    -- builds, where the spell hyperlink gets the same tooltip.
    option:SetScript("OnEnter", function(self)
        if not self.aura then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if not self.spellId then
            GameTooltip:SetText(self.aura.name, 1, 1, 1)
        elseif GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(self.spellId)
        else
            GameTooltip:SetHyperlink("spell:" .. self.spellId)
        end
        if menu.owner.activeName == self.aura.name then
            GameTooltip:AddLine("Running.", 0.3, 1, 0.3)
        end
        GameTooltip:Show()
    end)
    option:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- The pick lands inside AURA_OPTION_SNIPPET; insecure code only persists it
    -- and repaints, exactly as the old right-click rotation did.
    option:SetScript("PostClick", function(self)
        local swapper = menu.owner
        if self.aura then
            WhoDoesWhat.db.profile.settings.buffingBarAura = self.aura.key
        end
        UpdateAuraButton(swapper)
        if WhoDoesWhat.db.profile.settings.logBuffingBarClicks then
            WhoDoesWhat:Print("Buffing bar aura picked: "
                .. (self.aura and self.aura.name or "nothing") .. ".")
        end
    end)
    SecureHandlerSetFrameRef(option, "auraButton", menu.owner)
    option:WrapScript(option, "OnClick", AURA_OPTION_SNIPPET)
    menu.options[index] = option
    return option
end

-- Lay the castable auras out in rows and bake each icon's pick into its secure
-- attributes. Combat-locked like every other secure write on the bar, so it
-- no-ops mid-fight and re-runs on the next out-of-combat refresh.
local function ConfigureAuraMenu(btn)
    local menu = btn.auraMenu
    local rows = {
        { label = "Auras", auras = {} },
        { label = "Resistances", auras = {} },
    }
    for i, aura in ipairs(btn.auras) do
        local row = rows[aura.resist and 2 or 1]
        row.auras[#row.auras + 1] = { step = i, aura = aura }
    end

    -- Floor the panel at the player menus' width so the shared header hint has
    -- the room it has over there; the icon rows are narrower than that anyway.
    local shown, rowCount = 0, 0
    local widest = PLAYER_MENU_W - INSET * 2
    local y = INSET + PLAYER_HEADER_H + PLAYER_GAP
    for _, row in ipairs(rows) do
        if #row.auras > 0 then
            rowCount = rowCount + 1
            if rowCount > 1 then y = y + AURA_MENU_ROW_GAP end
            local label = menu.labels[rowCount] or CreateAuraMenuLabel(menu, rowCount)
            label:SetText(row.label)
            label:ClearAllPoints()
            label:SetPoint("TOPLEFT", menu, "TOPLEFT", INSET, -y)
            label:Show()
            y = y + AURA_MENU_LABEL_H
            for column, entry in ipairs(row.auras) do
                shown = shown + 1
                local option = menu.options[shown] or CreateAuraOption(menu, shown)
                option.aura = entry.aura
                -- Rank-less name lookup lands on the highest rank the paladin
                -- knows, which is the one a click would cast; the base-rank id
                -- covers test mode, where nothing is in the spellbook.
                option.spellId = select(7, GetSpellInfo(entry.aura.name))
                    or entry.aura.spellId
                option.icon:SetTexture(entry.aura.icon)
                option:SetAttribute("astep", entry.step)
                option:SetAttribute("auraMacro", "/cast " .. entry.aura.name)
                option:ClearAllPoints()
                option:SetPoint("TOPLEFT", menu, "TOPLEFT",
                    INSET + (column - 1) * (BTN_SIZE + BTN_GAP), -y)
                option:Show()
            end
            -- Widen for a caption that outruns its own row of icons.
            widest = math.max(widest,
                #row.auras * BTN_SIZE + (#row.auras - 1) * BTN_GAP,
                math.ceil(label:GetStringWidth()))
            y = y + BTN_SIZE
        end
    end
    for i = shown + 1, #menu.options do
        menu.options[i]:Hide()
        menu.options[i].aura, menu.options[i].spellId = nil, nil
    end
    for i = rowCount + 1, #menu.labels do menu.labels[i]:Hide() end

    menu:SetAttribute("Display", shown > 0 and 1 or 0)
    menu:SetSize(INSET * 2 + widest, y + INSET)
    menu:Hide()
end

-- Anchored at the end of the refresh, once the swapper itself has been laid
-- out, since which way it opens is read off its on-screen position.
local function PositionAuraMenu(btn)
    local menu = btn.auraMenu
    menu:ClearAllPoints()
    if PopoutDirection(btn, menu:GetHeight()) == "UP" then
        menu:SetPoint("BOTTOMLEFT", btn, "TOPLEFT", 0, 0)
    else
        menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, 0)
    end
end

-- No tooltip of its own: the picker opens on hover in its place, and says
-- everything the tooltip did -- which aura is offered, which is running, and
-- what the alternatives are -- as icons instead of lines.
local function CreateAuraButton()
    local btn = CreateSelfBuffButton("WhoDoesWhatBuffingBarAuraButton",
        "SecureHandlerEnterLeaveTemplate, SecureHandlerStateTemplate, "
        .. "SecureActionButtonTemplate")
    btn:RegisterForClicks("AnyUp", "AnyDown")
    CreateAuraMenu(btn)
    btn:Execute("otherMenus = newtable()")
    btn:SetAttribute("_onenter", AURA_ENTER_SNIPPET)

    btn:SetScript("PostClick", function(self, mouseButton, down)
        -- Secure action buttons obey ActionButtonUseKeyDown, so this fires on
        -- both edges; one pass per click.
        if down == true then return end
        UpdateAuraButton(self)
        if WhoDoesWhat.db.profile.settings.logBuffingBarClicks then
            WhoDoesWhat:Print("Buffing bar aura click: " .. tostring(mouseButton)
                .. " -> " .. (self.selected and self.selected.name or "no aura")
                .. " (" .. #(self.auras or {}) .. " castable).")
        end
    end)
    return btn
end

-- Bake the castable aura list onto the button and its picker. Secure attribute
-- writes are combat-locked, so this no-ops in combat and re-runs on the next
-- out-of-combat refresh, exactly like the class buttons.
local function ConfigureAuraButton(btn)
    if InCombatLockdown() then return end
    local auras = CastableAuras()
    btn.auras = auras
    local step = SelectedAuraStep(auras)
    local selected = auras[step]

    btn:SetAttribute("type1", "macro")
    btn:SetAttribute("astep", step)
    btn:SetAttribute("macrotext1", selected and ("/cast " .. selected.name) or "")
    ConfigureAuraMenu(btn)
end

-- Red glow while it's down, yellow with a countdown in its last ten minutes,
-- and nothing at all the rest of its half hour.
local function UpdateRighteousFuryButton(btn)
    local name, expiration = FindOwnBuff(RIGHTEOUS_FURY_NAMES)
    local remaining = name and expiration and expiration > 0
        and math.max(expiration - GetTime(), 0) or nil
    btn.remaining = remaining
    btn.active = name and true or false
    btn.icon:SetDesaturated(not name)
    if not name then
        SetButtonGlow(btn, true, MISSING_GLOW_COLOR)
        btn.count:SetText("")
    elseif remaining and remaining < RIGHTEOUS_FURY_WARN then
        SetButtonGlow(btn, true, EXPIRING_GLOW_COLOR)
        local minutes = math.floor(remaining / 60)
        btn.count:SetFormattedText("%d:%02d", minutes,
            math.floor(remaining - minutes * 60))
        btn.count:SetTextColor(1, 0.82, 0.2)
    else
        SetButtonGlow(btn, false)
        btn.count:SetText("")
    end
    RefreshBarTooltip(btn)
end

-- One fixed self-cast, so the secure attributes are set once at creation (out
-- of combat by definition) and never need rebaking.
local function CreateRighteousFuryButton()
    local btn = CreateSelfBuffButton("WhoDoesWhatBuffingBarRighteousFuryButton",
        "SecureHandlerEnterLeaveTemplate, SecureActionButtonTemplate")
    btn:RegisterForClicks("AnyUp", "AnyDown")
    btn:Execute("otherMenus = newtable()")
    btn:SetAttribute("_onenter", CLOSE_MENUS_SNIPPET)
    btn.icon:SetTexture(RIGHTEOUS_FURY.icon)
    btn:SetAttribute("type1", "spell")
    btn:SetAttribute("spell1", RIGHTEOUS_FURY.name)
    btn:SetAttribute("unit1", "player")

    btn.FillTooltip = function(self)
        GameTooltip:SetText(RIGHTEOUS_FURY.name, 1, 1, 1)
        if not self.active then
            GameTooltip:AddLine("Not active - your threat is missing its"
                .. " biggest multiplier.", 1, 0.3, 0.3, true)
        elseif not self.remaining then
            GameTooltip:AddLine("Active.", 0.3, 1, 0.3)
        else
            local minutes = math.floor(self.remaining / 60)
            local expiring = self.remaining < RIGHTEOUS_FURY_WARN
            GameTooltip:AddLine(string.format("%d:%02d remaining.", minutes,
                math.floor(self.remaining - minutes * 60)),
                expiring and 1 or 0.3, expiring and 0.82 or 1,
                expiring and 0.2 or 0.3)
        end
        GameTooltip:AddLine("Left-click to refresh it.", 0.4, 0.7, 1)
        GameTooltip:AddLine("Shown because you hold a tank role.", 0.7, 0.7, 0.7)
    end
    -- Hooked so the template's secure _onenter dispatch survives.
    btn:HookScript("OnEnter", ShowBarTooltip)
    return btn
end

-- Master gates. Both hang off a RESOLVED paladin, which is the whole class
-- check: outside test mode ResolveBarPaladin only returns a name when the local
-- player is a paladin, and inside it only when one is actually picked in the
-- dropdown. With nothing resolved the bar falls back to its "No Paladin
-- selected for testing." hint rather than offering buttons for nobody.
-- Righteous Fury additionally waits for a tank role -- which is how a prot
-- paladin's talents reach here, since role auto-detection already reads the
-- talent trees (TalentScanning.lua).
local function WantsAuraButton(paladin)
    if not paladin then return false end
    return WhoDoesWhat.db.profile.settings.buffingBarAuraButton and true or false
end

local function WantsRighteousFuryButton(paladin)
    if not paladin then return false end
    if not WhoDoesWhat.db.profile.settings.buffingBarRighteousFury then
        return false
    end
    return WhoDoesWhat:IsMarkedTank(paladin)
end

-- Repaint whichever self-buff buttons are currently up. Called from the
-- refresh path and from the bar's own tick, so a lapsing Righteous Fury and an
-- aura swapped from elsewhere both land within half a second.
local function UpdateSelfBuffButtons()
    if bar.auraButton:IsShown() then UpdateAuraButton(bar.auraButton) end
    if bar.rfButton:IsShown() then UpdateRighteousFuryButton(bar.rfButton) end
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

    -- Source-aware title strip, also a drag handle; hover explains Alt-drag.
    local title = CreateFrame("Frame", nil, bar)
    title:SetHeight(TITLE_H)
    title:SetPoint("TOPLEFT", INSET, -INSET)
    title:SetPoint("TOPRIGHT", -INSET, -INSET)
    local titleBg = title:CreateTexture(nil, "ARTWORK")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(0.12, 0.12, 0.15, 1)
    local titleText = title:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleText:SetPoint("LEFT", 5, 0)
    titleText:SetText("Paladin Bar")

    -- The source token rides the far end of the strip, a size down and greyed,
    -- so the bar's name reads first and the source is a glance rather than a
    -- label competing with it.
    local sourceText = title:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sourceText:SetPoint("RIGHT", -5, 0)
    sourceText:SetTextColor(0.62, 0.62, 0.62)
    local sourceFont, sourceSize = sourceText:GetFont()
    if sourceFont then sourceText:SetFont(sourceFont, sourceSize - 1) end
    sourceText:SetText(SOURCE_LABELS.wdw)

    AttachAltDrag(title)
    -- Hangs off the whole bar rather than the strip, so it opens clear of the
    -- button row instead of on top of it, and follows the same grow setting as
    -- everything else the bar pops out.
    title.tooltipAnchor = bar
    title.FillTooltip = function()
        GameTooltip:SetText("Paladin Bar", 1, 1, 1)
        GameTooltip:AddLine(
            WhoDoesWhat.db.profile.settings.pallyBuffSource == "pallypower"
                and "Buffing data is powered by PallyPower assignments."
                or "Buffing data is powered by WDW.",
            0.6, 0.6, 0.6, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Alt-Drag:", "Move",
            1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Shift-Left-Click:", "Buffing Grid",
            1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Shift-Right-Click:", "Paladin Bar Settings",
            1, 0.82, 0, 1, 1, 1)
    end
    title:SetScript("OnEnter", ShowBarTooltip)
    title:SetScript("OnLeave", function() GameTooltip:Hide() end)
    title:SetScript("OnMouseUp", function(_, button)
        if not IsShiftKeyDown() then return end
        if button == "RightButton" then
            WhoDoesWhat:OpenAddonSettingsView("Paladin Bar")
        elseif button == "LeftButton" then
            WhoDoesWhat:OpenBuffingGridView()
        end
    end)
    bar.title = title
    bar.titleText = titleText
    bar.sourceText = sourceText

    -- Shown when the resolved paladin has no assigned blessings.
    local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOP", 0, -CONTENT_TOP)
    hint:SetTextColor(0.6, 0.6, 0.6)
    bar.hint = hint

    -- Hairline between the left-anchored self-buff buttons and the class row.
    local divider = bar:CreateTexture(nil, "ARTWORK")
    divider:SetSize(DIVIDER_W, BTN_SIZE)
    divider:SetColorTexture(0.35, 0.35, 0.35, 0.8)
    divider:Hide()
    bar.divider = divider

    bar.buttons = {}
    bar.ppButton = CreatePallyPowerButton()
    bar.auraButton = CreateAuraButton()
    bar.rfButton = CreateRighteousFuryButton()
    LoadPosition()

    -- Roster changes shift the plan; leaving combat lets us (re)bake the secure
    -- cast rotations we couldn't touch mid-fight. Repaint on both. Our own
    -- UNIT_AURA is much narrower -- it can only move the two self-buff buttons,
    -- so it skips the full repaint and just lands a cast on them at once
    -- instead of up to half a tick later.
    bar:RegisterEvent("GROUP_ROSTER_UPDATE")
    bar:RegisterEvent("PLAYER_REGEN_ENABLED")
    bar:RegisterEvent("UNIT_AURA")
    bar:SetScript("OnEvent", function(self, event, unit)
        if not self:IsShown() then return end
        if event == "UNIT_AURA" then
            if unit == "player" then UpdateSelfBuffButtons() end
            return
        end
        WhoDoesWhat:RefreshPaladinBuffingBar()
    end)

    -- Range shifts as people (and you) move, which fires no events, so
    -- re-evaluate the grey/glow of the current visual jobs on a light throttle.
    -- Coverage and the plan itself still recompute on the refresh path.
    bar.rangeTick = 0
    bar:SetScript("OnUpdate", function(self, elapsed)
        self.rangeTick = self.rangeTick + elapsed
        if self.rangeTick < 0.5 then return end
        self.rangeTick = 0
        UpdateSelfBuffButtons()
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
    local buffPlan = self.Assign.GetActivePaladinBuffPlan()
    local allJobs = paladin and self.Assign.GetPaladinBuffJobs(paladin, buffPlan) or {}
    -- Drop classes with no real raiders to buff (read 0/0) -- nothing to show.
    local jobs = {}
    for _, job in ipairs(allJobs) do
        if job.total > 0 then jobs[#jobs + 1] = job end
    end
    local nameToUnit = BuildNameToUnit()
    local pallyPowerMode = self.db.profile.settings.pallyBuffSource == "pallypower"
    bar.sourceText:SetText(pallyPowerMode and SOURCE_LABELS.pallypower
        or SOURCE_LABELS.wdw)

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
        if pallyPowerMode and bar.ppButton:IsShown() then
            UpdatePallyPowerButton(bar.ppButton, paladin, buffPlan)
        end
        UpdateSelfBuffButtons()
        return
    end

    -- Self-buff buttons lead the row, so lay them out first and shift the class
    -- buttons past them and the divider.
    local selfBuffs = {}
    if WantsAuraButton(paladin) then
        ConfigureAuraButton(bar.auraButton)
        selfBuffs[#selfBuffs + 1] = bar.auraButton
    else
        SetButtonGlow(bar.auraButton, false)
        bar.auraButton:Hide()
    end
    if WantsRighteousFuryButton(paladin) then
        selfBuffs[#selfBuffs + 1] = bar.rfButton
    else
        SetButtonGlow(bar.rfButton, false)
        bar.rfButton:Hide()
    end
    local leadW = 0
    if #selfBuffs > 0 then
        leadW = #selfBuffs * BTN_SIZE + (#selfBuffs - 1) * BTN_GAP
    end
    for i, btn in ipairs(selfBuffs) do
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", bar, "TOPLEFT",
            INSET + PAD + (i - 1) * (BTN_SIZE + BTN_GAP), -CONTENT_TOP)
        btn:Show()
    end
    UpdateSelfBuffButtons()

    -- Class buttons start past the self-buff block and its divider gap.
    local classX = INSET + PAD + leadW + (leadW > 0 and DIVIDER_GAP or 0)
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
            classX + (i - 1) * (BTN_SIZE + BTN_GAP), -CONTENT_TOP)
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
    if pallyPowerMode then
        UpdatePallyPowerButton(bar.ppButton, paladin, buffPlan)
        bar.ppButton:ClearAllPoints()
        bar.ppButton:SetPoint("TOPLEFT", bar, "TOPLEFT",
            classX + n * (BTN_SIZE + BTN_GAP), -CONTENT_TOP)
        bar.ppButton:Show()
    else
        SetButtonGlow(bar.ppButton, false)
        bar.ppButton:Hide()
    end

    -- The divider only earns its place when there is a class row on the other
    -- side of it.
    local classCount = n + (pallyPowerMode and 1 or 0)
    bar.divider:SetShown(leadW > 0 and classCount > 0)
    if bar.divider:IsShown() then
        bar.divider:ClearAllPoints()
        bar.divider:SetPoint("TOPLEFT", bar, "TOPLEFT",
            INSET + PAD + leadW + (DIVIDER_GAP - DIVIDER_W) / 2, -CONTENT_TOP)
    end

    local classW = 0
    if classCount > 0 then
        classW = classCount * BTN_SIZE + (classCount - 1) * BTN_GAP
            + (leadW > 0 and DIVIDER_GAP or 0)
    end
    bar.hint:SetShown(leadW + classW == 0)
    if leadW + classW == 0 then
        bar.hint:SetText(paladin
            and (paladin .. " has no assigned blessings.")
            or "No Paladin selected for testing.")
        bar:SetSize(200, CONTENT_TOP + 18 + INSET)
    else
        local minW = MIN_BUTTONS_WIDE * BTN_SIZE + (MIN_BUTTONS_WIDE - 1) * BTN_GAP
        -- The strip carries a name at one end and a source token at the other,
        -- so it can outgrow three buttons; keep the two from colliding.
        minW = math.max(minW, math.ceil(bar.titleText:GetStringWidth()
            + bar.sourceText:GetStringWidth()) + 16)
        bar:SetSize(INSET * 2 + PAD * 2 + math.max(leadW + classW, minW),
            CONTENT_TOP + BTN_SIZE + COUNT_H + INSET + 1)
    end
    if not bar.moving then LoadPosition() end
    WirePopoutMenus()
    for i = 1, n do PositionPlayerMenu(bar.buttons[i]) end
    if bar.auraButton:IsShown() then PositionAuraMenu(bar.auraButton) end
end

-- Show or hide the whole bar based on the master/test toggles, then repaint.
-- Test mode stays visible without a paladin so roster updates can fill it in.
function WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
    local paladin = ResolveBarPaladin()
    if not paladin and not self.db.profile.settings.buffingBarTestMode then
        if bar then
            for _, b in ipairs(bar.buttons) do SetButtonGlow(b, false) end
            SetButtonGlow(bar.ppButton, false)
            SetButtonGlow(bar.auraButton, false)
            SetButtonGlow(bar.rfButton, false)
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
