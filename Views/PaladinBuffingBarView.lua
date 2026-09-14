local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI

-- Developer timing (Profiling.lua); both are no-ops unless /wdw perf on.
local PBegin, PEnd = WhoDoesWhat.Profiling.Begin, WhoDoesWhat.Profiling.End

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
-- casts whichever one it is currently offering, and picking one out of the
-- list casts it too) and,
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
-- Buffs" title strip). Moved by Alt-dragging; laid out as a row or a column
-- and growing whichever way along that axis the settings option picks; a
-- pulsing red frame alerts when any assigned raider is missing a blessing.

local bar = nil

local INSET = 3        -- backdrop edge inset
local PAD = 3          -- inner padding around the button row
local TITLE_H = 12     -- title strip height
-- Icon size is a setting, and the bar measures a couple of dozen things off
-- it. Rather than ask for it at each of those, the layout pass reads it once
-- into these two upvalues (ReadIconSize) and everything downstream keeps
-- using them -- so one repaint can never draw half the bar at the old size.
local BTN_SIZE = 28
local COUNT_H = 10     -- room under a button for its count text (row layout)
local COUNT_DROP = 3   -- icon bottom to its count (row layout); the bar grows to fit
local BTN_GAP = 4
local MIN_BUTTONS_WIDE = 3
-- Kept in proportion to the icon so the count sits the same distance under a
-- 48px button as it does under a 28px one, and stays readable there.
local COUNT_H_RATIO = 10 / 28
local COUNT_FONT_RATIO = 13 / 28
local BADGE_RATIO = 0.44
WhoDoesWhat.BUFFING_BAR_ICON_SIZE = { min = 16, max = 64, default = 28 }

function WhoDoesWhat:GetBuffingBarIconSize()
    local range = self.BUFFING_BAR_ICON_SIZE
    local size = tonumber(self.db.profile.settings.buffingBarIconSize)
        or range.default
    return math.floor(math.max(range.min, math.min(range.max, size)) + 0.5)
end

local function ReadIconSize()
    BTN_SIZE = WhoDoesWhat:GetBuffingBarIconSize()
    COUNT_H = math.floor(BTN_SIZE * COUNT_H_RATIO + 0.5)
end

-- Bring a pooled button up to the current icon size. A no-op on every repaint
-- but the first one after the setting moves. Only ever reached from a layout
-- pass, which waits for combat to end -- a secure button cannot be resized
-- mid-fight any more than it can be moved.
local function SizeButton(btn)
    if btn.sizedAt == BTN_SIZE then return end
    btn.sizedAt = BTN_SIZE
    btn:SetSize(BTN_SIZE, BTN_SIZE)
    if btn.petBadge then
        btn.petBadge:SetSize(BTN_SIZE * BADGE_RATIO, BTN_SIZE * BADGE_RATIO)
    end
end
local PLAYER_MENU_W = 180
local PLAYER_HEADER_H = 24
local PLAYER_W = PLAYER_MENU_W - INSET * 2
local PLAYER_H = 22
local PLAYER_GAP = 0
local AURA_MENU_LABEL_H = 12 -- row caption above each block of aura icons
local AURA_MENU_ROW_GAP = 4
-- The picker's own header: one line of hint, unlike the player menus' two, so
-- it doesn't need their strip height.
local AURA_HEADER_H = 15
local AURA_PAD = 5 -- breathing room between the panel's edge and its contents
local MISSING_ICON = "Interface\\RaidFrame\\ReadyCheck-NotReady"
-- The bar's two glow colours are settings; these are only reached if one has
-- gone missing from the profile. "Missing" is work outstanding -- a class with
-- somebody still unbuffed, a self-buff that is down -- and "expiring" is a
-- self-buff inside its warning window.
local MISSING_GLOW_COLOR = { r = 0.949, g = 0.71, b = 0 }
local EXPIRING_GLOW_COLOR = { r = 0.157, g = 0.561, b = 1 }
local PP_GEAR_ICON = "Interface\\Icons\\Trade_Engineering"
-- The gear is a complaint about configuration rather than about a blessing, so
-- it stays its own grey and out of the two colours above.
local PP_GLOW_COLOR = { r = 0.55, g = 0.55, b = 0.55 }

function WhoDoesWhat:GetBuffingBarGlowColor(which)
    local settings = self.db.profile.settings
    if which == "expiring" then
        return settings.buffingBarGlowExpiringColor or EXPIRING_GLOW_COLOR
    elseif which == "pallyPower" then
        return PP_GLOW_COLOR
    end
    return settings.buffingBarGlowMissingColor or MISSING_GLOW_COLOR
end

-- Named rather than left nil: an unset style would otherwise fall through to
-- whatever the status bars are set to, and this bar's style is its own.
local DEFAULT_GLOW_STYLE = "flash"

function WhoDoesWhat:GetBuffingBarGlowStyle()
    return self.db.profile.settings.buffingBarGlowStyle or DEFAULT_GLOW_STYLE
end
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
-- Orientation
-- ---------------------------------------------------------------------------
--
-- The bar lays its buttons out along one axis, chosen in the settings: a row
-- growing sideways (the original), or a column growing up/down. Everything
-- that has a direction follows suit -- which way the bar grows, which edge a
-- saved position is anchored by, which side the popout menus and tooltips open
-- on, and whether a button's count sits under it or beside it.

-- The two grow settings speak the axis they're on, so flipping the bar
-- translates a saved choice instead of discarding it (a bar that grew right
-- now grows down, and flipping back restores "right").
local GROW_FLIP = { RIGHT = "DOWN", LEFT = "UP", CENTER = "CENTER",
    DOWN = "RIGHT", UP = "LEFT" }
local MENU_FLIP = { DOWN = "RIGHT", UP = "LEFT", RIGHT = "DOWN", LEFT = "UP" }
local BAR_GROWS = {
    HORIZONTAL = { RIGHT = true, LEFT = true, CENTER = true },
    VERTICAL = { DOWN = true, UP = true, CENTER = true },
}
local MENU_GROWS = {
    HORIZONTAL = { DOWN = true, UP = true },
    VERTICAL = { RIGHT = true, LEFT = true },
}

local function Vertical()
    return WhoDoesWhat.db.profile.settings.buffingBarOrientation == "VERTICAL"
end

-- Both readers coerce a value left over from the other orientation, so a
-- half-migrated profile lays out sanely instead of falling back to nothing.
local function BarGrow()
    local axis = Vertical() and "VERTICAL" or "HORIZONTAL"
    local saved = WhoDoesWhat.db.profile.settings.buffingBarGrow
    if saved and BAR_GROWS[axis][saved] then return saved end
    if saved and BAR_GROWS[axis][GROW_FLIP[saved] or ""] then return GROW_FLIP[saved] end
    return Vertical() and "DOWN" or "RIGHT"
end

local function MenuGrow()
    local axis = Vertical() and "VERTICAL" or "HORIZONTAL"
    local saved = WhoDoesWhat.db.profile.settings.buffingMenuGrow
    if saved and MENU_GROWS[axis][saved] then return saved end
    if saved and MENU_GROWS[axis][MENU_FLIP[saved] or ""] then return MENU_FLIP[saved] end
    return Vertical() and "RIGHT" or "DOWN"
end

-- The settings view asks for these so its dropdowns offer the right words.
function WhoDoesWhat:GetBuffingBarGrow() return BarGrow() end
function WhoDoesWhat:GetBuffingMenuGrow() return MenuGrow() end

-- ---------------------------------------------------------------------------
-- Expiry warning
-- ---------------------------------------------------------------------------

-- How close to lapsing a blessing gets before the bar starts saying so, in
-- whole minutes. One number drives both tells: the countdown over a class
-- button and the yellow player row underneath it.
WhoDoesWhat.BuffingWarnMinutes = { 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 }

function WhoDoesWhat:GetBuffingWarnMinutes()
    local saved = self.db.profile.settings.buffingMenuWarnMinutes
    for _, minutes in ipairs(self.BuffingWarnMinutes) do
        if saved == minutes then return minutes end
    end
    return 6
end

local function WarnSeconds()
    return WhoDoesWhat:GetBuffingWarnMinutes() * 60
end

-- Minutes while there is more than one left, seconds for the last of them.
-- Minutes round UP, so the number is what you still have rather than what you
-- have lost -- which is also why "1m" never appears: at 60 seconds and under
-- the countdown is already speaking seconds.
local function FormatCountdown(remaining)
    if remaining > 60 then
        return string.format("%dm", math.ceil(remaining / 60))
    end
    return string.format("%ds", math.ceil(remaining))
end

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
-- hold still as buttons come and go: for a row, the left edge for RIGHT growth,
-- the right edge for LEFT and the horizontal midpoint for CENTER (which then
-- spreads both ways); for a column, the top edge for DOWN, the bottom edge for
-- UP and the vertical midpoint for CENTER. The anchor point encodes the
-- choice, so a saved position is self-describing and a mode change -- growth or
-- orientation -- just re-derives it from the current rect.
local GROW_POINTS = {
    HORIZONTAL = { RIGHT = "TOPLEFT", LEFT = "TOPRIGHT", CENTER = "TOP" },
    VERTICAL = { DOWN = "TOPLEFT", UP = "BOTTOMLEFT", CENTER = "LEFT" },
}
local VALID_POINTS = {
    TOPLEFT = true, TOPRIGHT = true, TOP = true, BOTTOMLEFT = true, LEFT = true,
}

local function SavePosition()
    if not bar then return end
    local axis = Vertical() and "VERTICAL" or "HORIZONTAL"
    local pos = UI.SavePoint(bar, GROW_POINTS[axis][BarGrow()] or "TOPLEFT")
    if pos then WhoDoesWhat.db.profile.settings.buffingBarPos = pos end
end

local function LoadPosition()
    local p = WhoDoesWhat.db.profile.settings.buffingBarPos
    if p then p.point = VALID_POINTS[p.point] and p.point or "TOPLEFT" end
    UI.RestorePoint(bar, p, 160)
end

-- Dark fill and a thin tooltip border, matching the other WDW windows.
--
-- The border draws a corner piece edgeSize across, so a frame shorter than two
-- of them stacks corner on corner and frays -- which is what the collapsed
-- strip did at 18px tall wearing the windows' usual 16. It gets an edge sized
-- to what it actually is instead; everything taller keeps the house one. Reapplied
-- only on a change, since a repaint can run at 10Hz.
local BAR_EDGE = 16
local COLLAPSED_EDGE = 8

local function ApplyBackdrop(edgeSize)
    if bar.backdropEdge == edgeSize then return end
    bar.backdropEdge = edgeSize
    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = edgeSize,
        insets = { left = INSET, right = INSET, top = INSET, bottom = INSET },
    })
    local fill, edge = WhoDoesWhat.Theme.paladinBarFill, WhoDoesWhat.Theme.mainBorder
    bar:SetBackdropColor(fill[1], fill[2], fill[3], fill[4])
    bar:SetBackdropBorderColor(edge[1], edge[2], edge[3])
end

-- Everything the bar pops out, shut at once. Dragging starts from anywhere on
-- the bar, buttons included, so a menu opened by hovering that button is left
-- riding along on top of wherever you are trying to put the bar. Combat-guarded
-- because these hang off secure buttons.
local function CloseAllPopouts()
    if not bar or InCombatLockdown() then return end
    GameTooltip:Hide()
    for _, btn in ipairs(bar.buttons) do btn.playerMenu:Hide() end
    if bar.auraButton then bar.auraButton.auraMenu:Hide() end
end

-- Alt-gated dragging for the whole bar. Every button gets it as well as the
-- frame and its title strip: the buttons cover most of the bar, and a column
-- leaves barely anything else to grab.
local function AttachAltDrag(region)
    UI.AttachDrag(region, bar)
end

-- Re-anchor by the edge the new mode holds still, reading it off the rect the
-- bar occupies right now, then let the repaint grow the other way from there.
local function ReanchorAndRefresh()
    if bar and bar:GetLeft() then
        SavePosition()
        LoadPosition()
    end
    WhoDoesWhat:RefreshPaladinBuffingBar()
end

function WhoDoesWhat:SetBuffingBarGrow(mode)
    self.db.profile.settings.buffingBarGrow = mode
    ReanchorAndRefresh()
end

function WhoDoesWhat:SetBuffingMenuGrow(mode)
    self.db.profile.settings.buffingMenuGrow = mode
    self:RefreshPaladinBuffingBar()
end

-- Turning the bar also turns both grow settings, so the saved choices stay on
-- the axis they describe and the settings dropdowns have something to show.
function WhoDoesWhat:SetBuffingBarOrientation(mode)
    local s = self.db.profile.settings
    if s.buffingBarOrientation == mode then return end
    s.buffingBarOrientation = mode
    s.buffingBarGrow = GROW_FLIP[s.buffingBarGrow or ""] or BarGrow()
    s.buffingMenuGrow = MENU_FLIP[s.buffingMenuGrow or ""] or MenuGrow()
    ReanchorAndRefresh()
end

-- ---------------------------------------------------------------------------
-- Range + "ready" glow (the status bars' shared highlight styles)
-- ---------------------------------------------------------------------------

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

-- Wide player rows pulse their existing 1px outline -- the highlight styles
-- are drawn around a square icon and have nothing to say on a row that is
-- mostly name. Every square button takes the status bars' shared styles
-- instead, in whichever of the bar's colours the state calls for: `which` is
-- "missing", "expiring", "pallyPower", or nil for off. ApplyStatusBarHighlight
-- tracks what is running, so a self-buff switching between two colours in
-- place restarts the effect rather than keeping the one it started in.
local function SetButtonGlow(btn, on, which)
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
    WhoDoesWhat:ApplyStatusBarHighlight(btn.highlightHost or btn, on and true or false,
        WhoDoesWhat:GetBuffingBarGlowStyle(),
        on and WhoDoesWhat:GetBuffingBarGlowColor(which) or nil)
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

-- Colour for a covered/total count: green all, gray when there's nothing to
-- cover, and otherwise the bar's own glow colours -- missing for none, expiring
-- for part-way -- so the number and the glow never disagree.
local function CountColor(covered, total)
    if total == 0 then return 0.6, 0.6, 0.6 end
    if covered >= total then return 0.3, 1, 0.3 end
    local c = WhoDoesWhat:GetBuffingBarGlowColor(covered == 0 and "missing" or "expiring")
    return c.r, c.g, c.b
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

-- The countdown over a class button: how long until the first of its buffed
-- members loses their blessing, shown only once that is inside the warning
-- window. Kept apart from the repaint below because it has to tick between
-- repaints -- the bar's OnUpdate calls it off the stored expiry rather than by
-- re-reading anybody's auras.
local function UpdateJobTimer(btn)
    local remaining = btn.expiresAt and (btn.expiresAt - GetTime())
    if remaining and remaining > 0 and remaining < WarnSeconds() then
        btn.timer:SetText(FormatCountdown(remaining))
        local c = WhoDoesWhat:GetBuffingBarGlowColor("expiring")
        btn.timer:SetTextColor(c.r, c.g, c.b)
        btn.timer:Show()
    else
        btn.timer:Hide()
    end
end

-- Combat-safe state for an existing class button. Secure spell/target
-- attributes and button layout remain untouched until combat ends.
local function UpdateButtonStatus(btn, job, nameToUnit)
    btn.visualJob = job
    btn.expiresAt = job and job.soonest and (GetTime() + job.soonest) or nil
    UpdateJobTimer(btn)
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
    SetButtonGlow(btn, ready, "missing")
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
    SetButtonGlow(p, missing and inRange and p:GetParent():IsShown(),
        "missing")
    if not inRange then
        p.bg:SetColorTexture(0.14, 0.09, 0.09, 0.96)
        p.outline:SetColorTexture(0.055, 0.035, 0.035, 1)
    elseif found or not p.castUnit then
        if remaining and remaining < WarnSeconds() then
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
        WhoDoesWhat:SetRoleIconTexture(p.specIcon,
            (role and role.icon) or job.classInfo.classIcon)
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
-- it fits, otherwise the roomier side. A row's popouts open above or below the
-- bar, a column's to one side of it, so the caller passes what the popout needs
-- on both axes and only the live one is measured. Shared by the class buttons'
-- player menus and the self-buff tooltips, so everything the bar pops out
-- follows the one setting and clamps the same way on cramped screens.
local function PopoutDirection(btn, needW, needH)
    local preferred = MenuGrow()
    if Vertical() then
        -- A column's popouts hang off the bar's edges, so that is the room
        -- worth measuring -- the button sits inside them.
        local screenLeft = UIParent:GetLeft() or 0
        local screenRight = UIParent:GetRight() or UIParent:GetWidth()
        local left = (bar:GetLeft() or screenLeft) - screenLeft
        local right = screenRight - (bar:GetRight() or screenRight)
        if preferred == "LEFT" and left < needW and right > left then
            return "RIGHT"
        elseif preferred == "RIGHT" and right < needW and left > right then
            return "LEFT"
        end
        return preferred
    end
    local screenTop = UIParent:GetTop() or UIParent:GetHeight()
    local screenBottom = UIParent:GetBottom() or 0
    local above = screenTop - (btn:GetTop() or screenTop)
    local below = (btn:GetBottom() or screenBottom) - screenBottom
    if preferred == "UP" and above < needH and below > above then
        return "DOWN"
    elseif preferred == "DOWN" and below < needH and above > below then
        return "UP"
    end
    return preferred
end

-- Hang `region` (a menu frame, or the game tooltip) off `btn` on the resolved
-- side, sharing the near corner so the popout lines up with the button. A
-- sideways popout steps out to the bar's own edge instead of the button's, so
-- it clears the counts a column keeps beside its icons rather than covering
-- them; things already anchored to the whole bar get no step at all.
local function EdgeStep(btn, side)
    if btn == bar then return 0 end
    local barEdge = side == "RIGHT" and bar:GetRight() or bar:GetLeft()
    local btnEdge = side == "RIGHT" and btn:GetRight() or btn:GetLeft()
    if not barEdge or not btnEdge then return 0 end
    return barEdge - btnEdge
end

local function AnchorPopout(region, btn, direction)
    region:ClearAllPoints()
    if direction == "UP" then
        region:SetPoint("BOTTOMLEFT", btn, "TOPLEFT", 0, 0)
    elseif direction == "RIGHT" then
        region:SetPoint("TOPLEFT", btn, "TOPRIGHT", EdgeStep(btn, "RIGHT"), 0)
    elseif direction == "LEFT" then
        region:SetPoint("TOPRIGHT", btn, "TOPLEFT", EdgeStep(btn, "LEFT"), 0)
    else
        region:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, 0)
    end
end

local function PositionPlayerMenu(btn)
    local menu = btn.playerMenu
    AnchorPopout(menu, btn,
        PopoutDirection(btn, menu:GetWidth(), menu:GetHeight()))
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
    -- Drawn on for the glow styles, so they sit under the icon (StatusBarsView).
    WhoDoesWhat:CreateIconHighlightHost(btn)

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetPoint("BOTTOMRIGHT", 0, 0)
    border:SetColorTexture(0, 0, 0, 0.9)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    -- A pixel inside the button all round, its border on the button's edge: the
    -- glows drawn around that box then stay inside the bar.
    icon:SetPoint("TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- trim the default icon border
    btn.icon = icon

    -- Small hunter-pet badge tucked into the bottom-right corner (inside the
    -- button), shown when a class button also carries pets (Warrior + pets). A
    -- 1px black frame matches the main icon's border; same icon-trim TexCoord.
    local petBadge = CreateFrame("Frame", nil, btn)
    petBadge:SetSize(BTN_SIZE * 0.44, BTN_SIZE * 0.44)
    petBadge:SetPoint("BOTTOMRIGHT", -2, 2)
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

    -- The expiry countdown, over the icon rather than under it (the shout bar's
    -- trick): it is about the blessing itself, not about who has it, and it
    -- only shows near the end -- when it wants to be the thing you see.
    -- Outlined so it reads over a busy spell icon, and small enough that a
    -- "10m" still fits inside one; the face follows the client's own.
    local timer = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    timer:SetPoint("CENTER")
    local timerFont = GameFontNormal:GetFont()
    timer:SetFont(timerFont or "Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    timer:SetTextColor(1, 0.82, 0.2)
    timer:Hide()
    btn.timer = timer

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
    -- Alt is the drag modifier, and dragging starts on the buttons too, so a
    -- held Alt means "I am moving the bar" rather than "show me this class":
    -- close what is open and open nothing.
    btn:SetAttribute("_onenter", [[
        for _, menu in ipairs(otherMenus) do menu:Hide() end
        if IsAltKeyDown() then return end
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

    AttachAltDrag(btn)
    bar.buttons[index] = btn
    return btn
end

local function CreatePallyPowerButton()
    local btn = CreateFrame("Button", "WhoDoesWhatBuffingBarPallyPowerButton", bar)
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetSize(BTN_SIZE, BTN_SIZE)
    -- Drawn on for the glow styles, so they sit under the icon (StatusBarsView).
    WhoDoesWhat:CreateIconHighlightHost(btn)

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetPoint("BOTTOMRIGHT", 0, 0)
    border:SetColorTexture(0, 0, 0, 0.9)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    -- A pixel inside the button all round, its border on the button's edge: the
    -- glows drawn around that box then stay inside the bar.
    icon:SetPoint("TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", -1, 1)
    icon:SetTexture(PP_GEAR_ICON)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetDesaturated(true)
    icon:SetVertexColor(0.65, 0.65, 0.65)
    btn.icon = icon

    local count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("TOP", btn, "BOTTOM", 0, -1)
    count:SetTextColor(0.65, 0.65, 0.65)
    btn.count = count

    UI.AddTooltip(btn, function(self)
        local unassigned = self.unassignedCount or 0
        GameTooltip:SetText("PallyPower Blessings", unpack(UI.TOOLTIP_TITLE))
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
        return true
    end)
    AttachAltDrag(btn)
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
    SetButtonGlow(btn, true, "pallyPower")
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

-- Is a talent-granted aura actually granted? The client's spell database
-- resolves Sanctity Aura for every paladin, talented or not, which is how it
-- kept turning up in the picker for one who never took the Retribution talent
-- that grants it. So the talent tree is asked, and asked BY NAME: the talent
-- that grants a spell carries that spell's name, both strings come from this
-- client, and unlike a grid coordinate it cannot be quietly wrong about where
-- a tree puts things. No talent of that name at all means this client doesn't
-- have one, which should not silently delete an aura -- so it shows.
--
-- Remembered until the spellbook changes: the answer only moves on a respec,
-- and this sits on a repaint path that can run at 10Hz.
local talentAuraGrants = {}

local function ClearTalentAuraCache()
    for k in pairs(talentAuraGrants) do talentAuraGrants[k] = nil end
end

local function TalentGrantsAura(aura)
    if not aura.talent then return true end
    local cached = talentAuraGrants[aura.key]
    if cached ~= nil then return cached end
    local rank, found = WhoDoesWhat:GetOwnTalentRankByName(aura.name)
    local granted = (not found) or rank > 0
    talentAuraGrants[aura.key] = granted
    return granted
end

-- Auras this paladin can actually cast: known to the client (which is what
-- keeps Crusader Aura out before level 62) and, for the talent auras, actually
-- talented into.
--
-- Test mode falls back to the whole client list only for a NON-paladin, where
-- there is no spellbook to ask and the buttons are pure layout preview. A real
-- paladin previewing someone else's assignments keeps their own list: these two
-- buttons cast for YOU whoever the bar is rendering, so offering an aura you
-- cannot cast would be a lie -- and that blanket return was quietly hiding
-- every filter below it from the one person able to notice.
local function CastableAuras()
    local _, class = UnitClass("player")
    if WhoDoesWhat.db.profile.settings.buffingBarTestMode and class ~= "PALADIN" then
        return AURAS
    end
    local out = {}
    for _, aura in ipairs(AURAS) do
        if GetSpellInfo(aura.name) and TalentGrantsAura(aura) then
            out[#out + 1] = aura
        end
    end
    return out
end

-- The same filter for the Buff Checklist's aura swapper, without test mode:
-- the checklist only ever offers one to a real paladin.
function WhoDoesWhat:GetKnownPaladinAuras()
    local out = {}
    for _, aura in ipairs(AURAS) do
        if GetSpellInfo(aura.name) and TalentGrantsAura(aura) then
            out[#out + 1] = aura
        end
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
-- A held Alt means the bar is being dragged, so the picker stands aside the
-- same way the class buttons' player menus do.
local AURA_ENTER_SNIPPET = [==[
    for _, menu in ipairs(otherMenus) do menu:Hide() end
    if IsAltKeyDown() then return end
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
-- option itself, so the swapper's offered aura can change mid-combat. The
-- writes are idempotent, so this runs on either click edge without a guard.
local AURA_OPTION_SNIPPET = [==[
    local swapper = self:GetFrameRef("auraButton")
    swapper:SetAttribute("astep", self:GetAttribute("astep"))
    swapper:SetAttribute("macrotext1", self:GetAttribute("auraMacro"))
]==]

-- Closing the picker is a POST body, and this is the whole reason the option
-- casts at all: a pre body hides the option along with its parent before the
-- button's own click handler ever runs, and a hidden button casts nothing --
-- which is what made picking an aura merely select it. Post runs after that
-- handler, so the cast lands first and the menu closes behind it.
--
-- Gated on the release for the same reason: hiding on the press takes the
-- button away before a key-up client reaches its cast. Compared against false
-- rather than tested for truth on purpose -- if a build ever stopped handing
-- the snippet its `down`, the picker would linger until its own auto-hide
-- instead of going back to eating casts.
local AURA_OPTION_POST_SNIPPET = [==[
    if down == false then
        self:GetParent():Hide()
    end
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
    AnchorPopout(GameTooltip, anchor,
        PopoutDirection(anchor, GameTooltip:GetWidth() or 0,
            GameTooltip:GetHeight() or 0))
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
    -- Drawn on for the glow styles, so they sit under the icon (StatusBarsView).
    WhoDoesWhat:CreateIconHighlightHost(btn)

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetPoint("BOTTOMRIGHT", 0, 0)
    border:SetColorTexture(0, 0, 0, 0.9)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    -- A pixel inside the button all round, its border on the button's edge: the
    -- glows drawn around that box then stay inside the bar.
    icon:SetPoint("TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn.icon = icon

    local count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("TOP", btn, "BOTTOM", 0, -1)
    btn.count = count

    -- Hooked, not set: these carry secure enter/leave handlers from their
    -- templates, and SetScript would throw them away. Drag is its own script
    -- pair, untouched by those templates, so AttachAltDrag can set as usual.
    btn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    AttachAltDrag(btn)
    btn:Hide()
    return btn
end

-- Repaint the picker's icons: gold border on the offered aura, full colour on
-- whichever one is actually running (the same "desaturated means not up"
-- language the swapper itself uses). Safe in combat -- no secure writes.
-- The gold border marks the offered aura, matched on the option's own step --
-- its index into the castable list -- and NOT on its position in the panel.
-- The two part company as soon as the resistance row splits the list: the
-- panel shows the non-resist auras first, so option 4 is whatever follows the
-- resistances, and the border was landing three icons early.
local function UpdateAuraMenu(btn)
    local menu = btn.auraMenu
    if not menu then return end
    local step = btn:GetAttribute("astep") or 1
    local running = btn.activeName
    for _, option in ipairs(menu.options) do
        if option:IsShown() then
            option.icon:SetDesaturated(option.aura.name ~= running)
            if option.step == step then
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
    SetButtonGlow(btn, not running, "missing")
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
    headerBg:SetHeight(AURA_HEADER_H)
    headerBg:SetColorTexture(0.09, 0.09, 0.11, 1)

    -- One line, because there is only one thing to say now: every icon here
    -- both swaps and casts, and so does the swapper itself. Centred in a strip
    -- cut down to fit it, rather than hung from the top of the player menus'
    -- two-line one.
    local clickHint = menu:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    clickHint:SetPoint("LEFT", headerBg, "LEFT", AURA_PAD, 0)
    clickHint:SetText("Left-click = Swap + Cast")
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

-- Picking an aura casts it as well as selecting it: the click you make to
-- choose one is the click that puts it up, and having to press the swapper
-- again afterwards was a second step for something you had already asked for.
-- That makes every option a cast button in its own right, hence the action
-- template and both click edges (secure buttons obey ActionButtonUseKeyDown;
-- an up-only registration never fires on a client set to act on key down).
--
-- The templates are the class buttons' pairing, and the order is load-bearing:
-- SecureHandlerClickTemplate owns an OnClick of its own, so listing it after
-- the action template REPLACES SecureActionButton_OnClick and the button
-- silently stops casting -- which is exactly what happened here. State carries
-- the same handler machinery (Execute/WrapScript/frame refs) and hooks no
-- OnClick, so the action handler survives and the wrap still lands on it.
local function CreateAuraOption(menu, index)
    local option = CreateFrame("Button", menu:GetName() .. "Option" .. index, menu,
        "SecureHandlerStateTemplate, SecureActionButtonTemplate")
    option:SetSize(BTN_SIZE, BTN_SIZE)
    option:RegisterForClicks("AnyUp", "AnyDown")
    option:SetAttribute("type1", "macro")

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
    UI.AddTooltip(option, function(self)
        if not self.aura then return end
        if not self.spellId then
            GameTooltip:SetText(self.aura.name, unpack(UI.TOOLTIP_TITLE))
        elseif GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(self.spellId)
        else
            GameTooltip:SetHyperlink("spell:" .. self.spellId)
        end
        if menu.owner.activeName == self.aura.name then
            GameTooltip:AddLine("Running.", 0.3, 1, 0.3)
        end
        return true
    end)
    -- The pick lands inside AURA_OPTION_SNIPPET and the cast in the button's
    -- own macro; insecure code only persists it and repaints, exactly as the
    -- old right-click rotation did.
    option:SetScript("PostClick", function(self, _, down)
        -- Both click edges are registered above, so this fires twice; one pass.
        if down == true then return end
        local swapper = menu.owner
        if self.aura then
            WhoDoesWhat.db.profile.settings.buffingBarAura = self.aura.key
        end
        UpdateAuraButton(swapper)
        -- Belt and braces on closing the picker: this runs after the cast has
        -- already gone out, so out of combat -- where hiding the panel is ours
        -- to do -- the close doesn't depend on the snippet's `down` reaching
        -- it. In combat the secure post body is the only one that may.
        if not InCombatLockdown() then menu:Hide() end
        if WhoDoesWhat.db.profile.settings.logBuffingBarClicks then
            WhoDoesWhat:Print("Buffing bar aura picked: "
                .. (self.aura and self.aura.name or "nothing") .. ".")
        end
    end)
    SecureHandlerSetFrameRef(option, "auraButton", menu.owner)
    option:WrapScript(option, "OnClick", AURA_OPTION_SNIPPET,
        AURA_OPTION_POST_SNIPPET)
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

    -- Floor the panel at the player menus' width so the header hint has room;
    -- the icon rows are narrower than that anyway, which is where the padding
    -- below comes from -- it insets the contents rather than widening the
    -- panel, and only a row that outgrows the floor pushes past it.
    local shown, rowCount = 0, 0
    local widest = PLAYER_MENU_W - INSET * 2
    local y = INSET + AURA_HEADER_H + AURA_PAD
    for _, row in ipairs(rows) do
        if #row.auras > 0 then
            rowCount = rowCount + 1
            if rowCount > 1 then y = y + AURA_MENU_ROW_GAP end
            local label = menu.labels[rowCount] or CreateAuraMenuLabel(menu, rowCount)
            label:SetText(row.label)
            label:ClearAllPoints()
            label:SetPoint("TOPLEFT", menu, "TOPLEFT", INSET + AURA_PAD, -y)
            label:Show()
            y = y + AURA_MENU_LABEL_H
            for column, entry in ipairs(row.auras) do
                shown = shown + 1
                local option = menu.options[shown] or CreateAuraOption(menu, shown)
                SizeButton(option)
                option.aura = entry.aura
                -- Rank-less name lookup lands on the highest rank the paladin
                -- knows, which is the one a click would cast; the base-rank id
                -- covers test mode, where nothing is in the spellbook.
                option.spellId = select(7, GetSpellInfo(entry.aura.name))
                    or entry.aura.spellId
                option.icon:SetTexture(entry.aura.icon)
                option.step = entry.step
                option:SetAttribute("astep", entry.step)
                -- One macro, two jobs: the option casts it on click, and the
                -- snippet hands the same string to the swapper as its new
                -- offering.
                local macro = "/cast " .. entry.aura.name
                option:SetAttribute("auraMacro", macro)
                option:SetAttribute("macrotext1", macro)
                option:ClearAllPoints()
                option:SetPoint("TOPLEFT", menu, "TOPLEFT",
                    INSET + AURA_PAD + (column - 1) * (BTN_SIZE + BTN_GAP), -y)
                option:Show()
            end
            -- Widen for a caption that outruns its own row of icons. Both
            -- candidates carry the padding on each side, so a row that does
            -- push past the floor still isn't flush against the edge.
            widest = math.max(widest,
                #row.auras * BTN_SIZE + (#row.auras - 1) * BTN_GAP
                    + AURA_PAD * 2,
                math.ceil(label:GetStringWidth()) + AURA_PAD * 2)
            y = y + BTN_SIZE
        end
    end
    for i = shown + 1, #menu.options do
        menu.options[i]:Hide()
        menu.options[i].aura, menu.options[i].spellId = nil, nil
        menu.options[i].step = nil
    end
    for i = rowCount + 1, #menu.labels do menu.labels[i]:Hide() end

    menu:SetAttribute("Display", shown > 0 and 1 or 0)
    menu:SetSize(INSET * 2 + widest, y + AURA_PAD + INSET)
    menu:Hide()
end

-- Anchored at the end of the refresh, once the swapper itself has been laid
-- out, since which way it opens is read off its on-screen position.
local function PositionAuraMenu(btn)
    local menu = btn.auraMenu
    AnchorPopout(menu, btn,
        PopoutDirection(btn, menu:GetWidth(), menu:GetHeight()))
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
        SetButtonGlow(btn, true, "missing")
        btn.count:SetText("")
    elseif remaining and remaining < RIGHTEOUS_FURY_WARN then
        SetButtonGlow(btn, true, "expiring")
        local minutes = math.floor(remaining / 60)
        btn.count:SetFormattedText("%d:%02d", minutes,
            math.floor(remaining - minutes * 60))
        local c = WhoDoesWhat:GetBuffingBarGlowColor("expiring")
        btn.count:SetTextColor(c.r, c.g, c.b)
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
    ApplyBackdrop(BAR_EDGE)
    UI.MakeMovable(bar, {
        OnStart = CloseAllPopouts,
        -- Save, then re-anchor to the growth corner so the next resize grows
        -- the chosen way (StartMoving may have left a different anchor).
        OnStop = function()
            SavePosition()
            LoadPosition()
            WhoDoesWhat:RefreshPaladinBuffingBar()
        end,
    })

    -- Source-aware title strip, also a drag handle; hover explains Alt-drag.
    local title = CreateFrame("Frame", nil, bar)
    title:SetHeight(TITLE_H)
    title:SetPoint("TOPLEFT", INSET, -INSET)
    title:SetPoint("TOPRIGHT", -INSET, -INSET)
    -- The fill is the bar's, not the strip's: a child frame draws above its
    -- parent's backdrop, which laid the header over the gold edge. On the
    -- bar's BACKGROUND it sits over the fill and under the edge (BORDER).
    local titleBg = bar:CreateTexture(nil, "BACKGROUND", nil, 1)
    titleBg:SetAllPoints(title)
    titleBg:SetColorTexture(unpack(WhoDoesWhat.Theme.window.titleBarColor))
    local titleText = title:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleText:SetPoint("LEFT", 5, 0)
    titleText:SetText("Paladin Bar")
    -- Kept so a column can drop a couple of points off this same face and the
    -- row can put it straight back.
    bar.titleFont, bar.titleFontSize, bar.titleFontFlags = titleText:GetFont()

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
        -- Signed with the addon's own icon and full name: the bar sits loose on
        -- the screen next to whatever else the paladin runs, so its tooltip is
        -- the one place that can say whose it is.
        GameTooltip:SetText("|T" .. WhoDoesWhat.ADDON_ICON .. ":16:16:0:0|t "
            .. "WhoDoesWhat Paladin Bar", 1, 1, 1)
        -- Test mode renders somebody else's jobs, and everything downstream
        -- follows them -- which class buttons appear, and whether the Righteous
        -- Fury button does, since that reads the RENDERED paladin's tank role.
        -- A fake raid can quietly hand the preview to a paladin who isn't a
        -- tank, and a button vanishing then reads as a bug rather than as the
        -- preview doing its job. So the tooltip says whose bar this is.
        if WhoDoesWhat.db.profile.settings.buffingBarTestMode then
            local previewing = WhoDoesWhat:GetBuffingBarTestPaladin()
            GameTooltip:AddLine("|T" .. WhoDoesWhat.WARNING_ICON .. ":14:14:0:0|t"
                .. " Previewing Bar for: "
                .. (previewing and WhoDoesWhat:DisplayName(previewing)
                    or "nobody"),
                1, 0.25, 0.25, true)
        end
        -- Where the buffing data comes from is a fact about a bar that is
        -- drawing something. Stood down it is drawing nothing, so it says that
        -- instead -- one line, not two contradicting each other.
        local standingDown = WhoDoesWhat:PallyPowerIsEnabled()
        if standingDown then
            GameTooltip:AddLine("PallyPower is switched on, so this bar has"
                .. " stood down to stay out of its way.", 1, 0.25, 0.25, true)
        else
            GameTooltip:AddLine(
                WhoDoesWhat.db.profile.settings.pallyBuffSource == "pallypower"
                    and "Buffing data is powered by PallyPower assignments."
                    or "Buffing data is powered by WDW.",
                0.6, 0.6, 0.6, true)
        end
        GameTooltip:AddLine(" ")
        UI.AddTooltipHint(GameTooltip, "Alt-Drag:", "Move")
        -- The switch, and then a gap: it belongs with the move as something
        -- that acts on the bar itself, not with the two that open a window.
        -- It names the RESULT of the click rather than the mechanism, and
        -- colours it accordingly, so there is no working out which way the
        -- switch currently sits before pressing it.
        if WhoDoesWhat:PallyPowerInstalled() then
            local label, r, g, b = "Disable for PP", 1, 0.3, 0.3
            if standingDown then
                label, r, g, b = "Enable WhoDoesWhat", 0.3, 1, 0.3
            end
            UI.AddTooltipHint(GameTooltip, "Alt-Right-Click:", label,
                r, g, b)
            GameTooltip:AddLine(" ")
        end
        UI.AddTooltipHint(GameTooltip, "Shift-Left-Click:",
            "Buffing Grid")
        UI.AddTooltipHint(GameTooltip, "Shift-Right-Click:",
            "Paladin Bar Settings")
    end
    title:SetScript("OnEnter", ShowBarTooltip)
    title:SetScript("OnLeave", function() GameTooltip:Hide() end)
    title:SetScript("OnMouseUp", function(_, button)
        -- Alt is the bar's own modifier (it drags), so the switch rides it too.
        -- Silent without PallyPower: there is nothing to toggle, and the
        -- tooltip doesn't offer it either.
        if IsAltKeyDown() then
            if button == "RightButton" and WhoDoesWhat:PallyPowerInstalled() then
                WhoDoesWhat:TogglePallyPower()
                RefreshBarTooltip(title)
            end
            return
        end
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

    -- A column is one icon wide, too narrow for the hint's sentence, so with
    -- nobody to preview it shows this X and keeps the sentence for the hover.
    local noPaladin = CreateFrame("Frame", nil, bar)
    noPaladin:SetPoint("TOP", 0, -CONTENT_TOP)
    local noPaladinIcon = noPaladin:CreateTexture(nil, "ARTWORK")
    noPaladinIcon:SetAllPoints()
    noPaladinIcon:SetTexture(MISSING_ICON)
    noPaladin.tooltipAnchor = bar
    noPaladin.FillTooltip = function()
        GameTooltip:SetText("No Paladin selected for testing.", 1, 1, 1)
    end
    noPaladin:SetScript("OnEnter", ShowBarTooltip)
    noPaladin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    noPaladin:Hide()
    bar.noPaladin = noPaladin

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
        -- Times the whole 2Hz tick, not the per-button work inside it: at this
        -- rate the question is what one tick costs, and instrumenting the
        -- inner loop would cost more than it measured.
        PBegin("view.pallybar.tick")
        UpdateSelfBuffButtons()
        local nameToUnit = BuildNameToUnit()
        for _, btn in ipairs(self.buttons) do
            local job = btn.visualJob
            if job and btn:IsShown() then
                local ready = JobIsReady(job, nameToUnit)
                btn.icon:SetDesaturated(not ready)
                SetButtonGlow(btn, ready, "missing")
                -- The countdown is the one thing here that changes without an
                -- event to hang it on, so it rides this tick.
                UpdateJobTimer(btn)
                if btn.playerMenu:IsShown() then
                    for _, p in ipairs(btn.playerButtons) do
                        if p:IsShown() then UpdatePlayerAura(p) end
                    end
                end
            end
        end
        PEnd("view.pallybar.tick")
    end)

    return bar
end

-- ---------------------------------------------------------------------------
-- Refresh + visibility
-- ---------------------------------------------------------------------------

-- Buttons are laid out by how far along the bar's axis they sit, so the row and
-- the column share one set of offsets and only these two helpers know which way
-- that axis runs. The cross axis is always the top-left corner of the content
-- area, which is where the text slots go: a row hangs each one under its icon,
-- in height it is already paying for, while a column has no room for that and
-- stays exactly one icon wide.
local function PlaceButton(region, offset)
    region:ClearAllPoints()
    if Vertical() then
        region:SetPoint("TOPLEFT", bar, "TOPLEFT", INSET + PAD,
            -(CONTENT_TOP + offset))
    else
        region:SetPoint("TOPLEFT", bar, "TOPLEFT", INSET + PAD + offset,
            -CONTENT_TOP)
    end
end

-- So in a column the class buttons' x/y counts drop out -- the coverage is a
-- hover away in the player menu's header -- while a countdown, which is the one
-- thing here worth reading at a glance, moves ON to its icon, outlined, the way
-- the shout bar's does. Only the self-buff buttons pass keepInColumn.
--
-- Every button the layout places passes through here, so this is also where
-- each one is brought up to the current icon size.
local function AnchorCount(btn, keepInColumn)
    SizeButton(btn)
    local count = btn.count
    count:ClearAllPoints()
    if not Vertical() then
        -- The font object first for its face and colour, then the size off the
        -- icon: a row's count sits in height the bar is already paying for
        -- (COUNT_H), which grows with the button above it.
        count:SetFontObject(GameFontNormalSmall)
        local face, _, flags = count:GetFont()
        count:SetFont(face or "Fonts\\FRIZQT__.TTF",
            math.max(7, math.floor(BTN_SIZE * COUNT_H_RATIO + 0.5)), flags)
        count:SetPoint("TOP", btn, "BOTTOM", 0, -COUNT_DROP)
        count:Show()
    elseif keepInColumn then
        -- Small enough for a "9:59" to sit inside the icon, outlined so it
        -- reads over one; the face follows whatever the client is using, and
        -- the size follows the icon it has to fit inside.
        local font = GameFontNormal:GetFont()
        count:SetFont(font or "Fonts\\FRIZQT__.TTF",
            math.max(8, math.floor(BTN_SIZE * COUNT_FONT_RATIO + 0.5)),
            "OUTLINE")
        count:SetPoint("CENTER", btn, "CENTER", 0, 0)
        count:Show()
    else
        count:Hide()
    end
end

-- PallyPower's own bar does this job whenever its master switch is on, so ours
-- stands down rather than sitting beside it as a second, contradictory set of
-- blessing buttons. Everything but the title strip goes, leaving a red-lettered
-- handle that says why and carries the way back (Alt-Right-Click on it). Only
-- reachable with PallyPower installed, so a paladin without it never lands
-- here, and only out of combat, where hiding secure buttons is allowed.
local function CollapseForPallyPower()
    for _, btn in ipairs(bar.buttons) do
        SetButtonGlow(btn, false)
        btn.playerMenu:SetAttribute("Display", 0)
        btn.playerMenu:Hide()
        btn:Hide()
        btn.job, btn.visualJob = nil, nil
    end
    SetButtonGlow(bar.ppButton, false)
    bar.ppButton:Hide()
    SetButtonGlow(bar.auraButton, false)
    bar.auraButton.auraMenu:Hide()
    bar.auraButton:Hide()
    SetButtonGlow(bar.rfButton, false)
    bar.rfButton:Hide()
    bar.divider:Hide()
    bar.hint:Hide()
    bar.noPaladin:Hide()
    -- A column keeps its width so the strip doesn't jump around when the switch
    -- flips; a row shrinks to the words it is still showing.
    local width = INSET * 2 + PAD * 2
    if Vertical() then
        width = width + BTN_SIZE
    else
        width = width + math.ceil(bar.titleText:GetStringWidth()
            + bar.sourceText:GetStringWidth()) + 16
    end
    -- Exactly the strip, not CONTENT_TOP: that carries the 2px the button row
    -- would have started after, which with nothing under it read as a thin
    -- black line of leftover window body below the title.
    ApplyBackdrop(COLLAPSED_EDGE)
    bar:SetSize(width, INSET * 2 + TITLE_H)
end

-- Has this class got anything left to say? Somebody still without their
-- blessing, or a countdown running on the first one due to lapse. A warning is
-- work, so a class showing one is not finished no matter what its count reads
-- -- which is what keeps a class from hiding on the way out and reappearing
-- seconds later with its blessing gone.
local function JobIsDone(job)
    if job.covered < job.total then return false end
    return not (job.soonest and job.soonest < WarnSeconds())
end

-- Repaint the bar's buttons from the resolved paladin's jobs. Only touches the
-- widgets; visibility is handled by UpdatePaladinBuffingBarVisibility.
function WhoDoesWhat:RefreshPaladinBuffingBar()
    if not bar or not bar:IsShown() then return end
    -- Before anything is measured, and before the combat branch: the sizes the
    -- rest of this pass works in are read once, here.
    ReadIconSize()
    local paladin = ResolveBarPaladin()
    local buffPlan = self.Assign.GetActivePaladinBuffPlan()
    local allJobs = paladin and self.Assign.GetPaladinBuffJobs(paladin, buffPlan) or {}
    -- Drop classes with no real raiders to buff (read 0/0) -- nothing to show --
    -- and, if asked, the ones with nothing left to do, leaving a bar that is
    -- only the work still outstanding. A class comes back the moment its
    -- blessing runs down into the warning window, though not until combat ends:
    -- adding a button is a layout change.
    local hideCompleted = self.db.profile.settings.buffingBarHideCompleted
    local jobs, hidden = {}, 0
    for _, job in ipairs(allJobs) do
        if job.total > 0 then
            if hideCompleted and JobIsDone(job) then
                hidden = hidden + 1
            else
                jobs[#jobs + 1] = job
            end
        end
    end
    local nameToUnit = BuildNameToUnit()
    local pallyPowerMode = self.db.profile.settings.pallyBuffSource == "pallypower"
    local sourceLabel = pallyPowerMode and SOURCE_LABELS.pallypower
        or SOURCE_LABELS.wdw
    local vertical = Vertical()
    -- A column is one button wide, so its strip drops the name and centres the
    -- source token -- the part that changes -- in the space that leaves. A
    -- point smaller as well: at full size a "WDW" was wider than a button and
    -- the whole bar had to widen around it, which is why the same column looked
    -- thinner in PP mode. Sizing the token to the strip instead of the strip to
    -- the token keeps every column exactly one icon wide whatever it says --
    -- one point down is as far as that has to go, and two was hard to read.
    bar.titleText:SetText(vertical and sourceLabel or "Paladin Bar")
    bar.sourceText:SetText(vertical and "" or sourceLabel)
    -- Red is the whole tell in the collapsed state: the strip is all that's
    -- left of the bar, so it has to carry "this is off on purpose".
    local ppRunning = self:PallyPowerIsEnabled()
    if ppRunning then
        bar.titleText:SetTextColor(1, 0.25, 0.25)
    else
        bar.titleText:SetTextColor(1, 0.82, 0)
    end
    bar.titleText:ClearAllPoints()
    if vertical then
        bar.titleText:SetFont(bar.titleFont, bar.titleFontSize - 1,
            bar.titleFontFlags)
        bar.titleText:SetPoint("CENTER", bar.title, "CENTER", 0, 0)
    else
        bar.titleText:SetFont(bar.titleFont, bar.titleFontSize,
            bar.titleFontFlags)
        bar.titleText:SetPoint("LEFT", bar.title, "LEFT", 5, 0)
    end

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

    -- Below the combat branch on purpose: standing down empties the bar, and
    -- emptying it is a layout change like any other.
    if ppRunning then
        CollapseForPallyPower()
        if not bar.moving then LoadPosition() end
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
        AnchorCount(btn, true)
        PlaceButton(btn, (i - 1) * (BTN_SIZE + BTN_GAP))
        btn:Show()
    end
    UpdateSelfBuffButtons()

    -- Class buttons start past the self-buff block and its divider gap.
    local classStart = leadW + (leadW > 0 and DIVIDER_GAP or 0)
    for i, job in ipairs(jobs) do
        local btn = bar.buttons[i]
        if not btn then
            btn = CreateButton(i)
        end
        btn.job = job
        ConfigureButtonCast(btn, job, nameToUnit)
        ConfigurePlayerMenu(btn, job, nameToUnit)
        UpdateButtonStatus(btn, job, nameToUnit)
        AnchorCount(btn)
        PlaceButton(btn, classStart + (i - 1) * (BTN_SIZE + BTN_GAP))
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

    -- The gear is a complaint -- these classes have no PallyPower assignment --
    -- so with nothing to complain about it earns no space on the bar.
    local n = #jobs
    local ppShown = false
    if pallyPowerMode then
        UpdatePallyPowerButton(bar.ppButton, paladin, buffPlan)
        ppShown = (bar.ppButton.unassignedCount or 0) > 0
    end
    if ppShown then
        AnchorCount(bar.ppButton)
        PlaceButton(bar.ppButton, classStart + n * (BTN_SIZE + BTN_GAP))
        bar.ppButton:Show()
    else
        SetButtonGlow(bar.ppButton, false)
        bar.ppButton:Hide()
    end

    -- The divider only earns its place when there is a class row on the other
    -- side of it. It lies across the bar, so it turns with everything else.
    local classCount = n + (ppShown and 1 or 0)
    bar.divider:SetShown(leadW > 0 and classCount > 0)
    if bar.divider:IsShown() then
        bar.divider:SetSize(vertical and BTN_SIZE or DIVIDER_W,
            vertical and DIVIDER_W or BTN_SIZE)
        PlaceButton(bar.divider, leadW + (DIVIDER_GAP - DIVIDER_W) / 2)
    end

    local classW = 0
    if classCount > 0 then
        classW = classCount * BTN_SIZE + (classCount - 1) * BTN_GAP
            + (leadW > 0 and DIVIDER_GAP or 0)
    end
    ApplyBackdrop(BAR_EDGE)
    local empty = leadW + classW == 0
    local noPaladinX = empty and vertical and not paladin and hidden == 0
    bar.hint:SetShown(empty and not noPaladinX)
    bar.noPaladin:SetShown(noPaladinX)
    if noPaladinX then
        bar.noPaladin:SetSize(BTN_SIZE, BTN_SIZE)
        bar:SetSize(INSET * 2 + PAD * 2 + BTN_SIZE,
            CONTENT_TOP + BTN_SIZE + INSET + 1)
    elseif empty then
        -- The empty state is a sentence either way, so it keeps the row's shape
        -- rather than wrapping into a column one word wide. An empty bar means
        -- something different once completed classes are being hidden: the work
        -- is done, not missing.
        bar.hint:SetText((hidden > 0 and "All assigned blessings are up.")
            or (paladin and (paladin .. " has no assigned blessings."))
            or "No Paladin selected for testing.")
        bar:SetSize(200, CONTENT_TOP + 18 + INSET)
    elseif vertical then
        -- Exactly one icon wide, with nothing left to pad it out past them: no
        -- counts, and a source token sized to fit the strip rather than the
        -- strip sized to fit it.
        bar:SetSize(INSET * 2 + PAD * 2 + BTN_SIZE,
            CONTENT_TOP + leadW + classW + INSET + 1)
    else
        local minW = MIN_BUTTONS_WIDE * BTN_SIZE + (MIN_BUTTONS_WIDE - 1) * BTN_GAP
        -- The strip carries a name at one end and a source token at the other,
        -- so it can outgrow three buttons; keep the two from colliding.
        minW = math.max(minW, math.ceil(bar.titleText:GetStringWidth()
            + bar.sourceText:GetStringWidth()) + 16)
        bar:SetSize(INSET * 2 + PAD * 2 + math.max(leadW + classW, minW),
            CONTENT_TOP + BTN_SIZE + COUNT_H + COUNT_DROP + INSET + 1)
    end
    if not bar.moving then LoadPosition() end
    WirePopoutMenus()
    for i = 1, n do PositionPlayerMenu(bar.buttons[i]) end
    if bar.auraButton:IsShown() then PositionAuraMenu(bar.auraButton) end
end

-- Everything the Paladin Bar settings page owns. The Developer page's test
-- mode and its paladin pick are not this page's to undo, and neither is the
-- aura the swapper happens to be offering -- that is live state, not a setting.
local RESET_SETTINGS = {
    "buffingBarEnabled", "buffingBarAuraButton", "buffingBarRighteousFury",
    "buffingBarHideCompleted", "buffingBarOrientation", "buffingBarGrow",
    "buffingMenuGrow", "buffingMenuWarnMinutes", "buffingBarIconSize",
    "buffingBarGlowStyle", "buffingBarGlowMissingColor",
    "buffingBarGlowExpiringColor",
}

function WhoDoesWhat:ResetPaladinBarSettings()
    local settings = self.db.profile.settings
    self:RestoreDefaultSettings(RESET_SETTINGS)
    -- Dropped rather than placed by hand: with no saved position LoadPosition
    -- puts the bar where a fresh install finds it, which is what the button
    -- promises.
    settings.buffingBarPos = nil
    if bar then LoadPosition() end
    self:UpdatePaladinBuffingBarVisibility()
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
--
-- SPELLS_CHANGED is the respec/level-up signal: it retires the remembered
-- talent answers behind the aura list. It lives on the loader rather than the
-- bar's own frame because the bar's handler is gated on being shown, and a
-- paladin who respecs with the bar hidden would come back to a stale list.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("SPELLS_CHANGED")
loader:SetScript("OnEvent", function(_, event)
    ClearTalentAuraCache()
    WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
    if event ~= "PLAYER_ENTERING_WORLD" then return end
    C_Timer.After(2, function() WhoDoesWhat:UpdatePaladinBuffingBarVisibility() end)
end)
