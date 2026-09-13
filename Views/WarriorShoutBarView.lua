local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local Assign = WhoDoesWhat.Assign

-- The Warrior Shout Bar: a small movable strip of one icon per warrior shout
-- (Battle Shout always, Commanding Shout on TBC), each glowing while anybody
-- in the PARTY who wants that shout is missing it -- red on nobody, yellow
-- part-way through. The paladin's
-- Buffing Bar answers "what do I still have to cast"; this answers the much
-- smaller warrior version of the same question, which is "is my shout up".
--
-- A shout reaches the caster's party and no further, so every number on this
-- bar is scoped to the local player's subgroup (PartyNames below) -- the
-- coverage counts and the warrior count alike. A raid-wide count would report
-- a gap in group 5 that nothing this warrior does can close.
--
-- Who counts as missing it, within that party:
--   Battle Shout      the roles that want it (WhoDoesWhat:WantsBattleShout,
--                     Data.lua) plus hunter pets, who are standing on the boss
--                     even when their hunter isn't.
--   Commanding Shout  everyone, pets included -- it is health, and nobody in
--                     the party turns that down.
-- Fake raiders, non-raiders, the disconnected and the dead are all out, as is
-- anybody nowhere near you once the range option is on.
--
-- How many icons: one warrior can only keep one shout up, so a party with a
-- lone warrior gets one icon -- right-click it to choose which shout that is.
-- Two or more warriors, and the second shout is somebody's job, so both show.
--
-- Left-click a button to cast its shout. Each one's spell never changes, so
-- unlike the paladin bar there is no rotation to rebake -- the secure
-- attributes are set once at creation and never touched again. What the secure
-- template does cost is the combat-lockdown discipline around LAYOUT: a
-- protected button cannot be created, shown, hidden or moved mid-fight, and
-- neither can the bar that parents it. So in combat this file repaints counts
-- and glows only, and PLAYER_REGEN_ENABLED settles anything the fight changed.
--
-- Chrome is optional throughout: the backdrop, the counts, and each icon in
-- turn can all be switched off (the last one only while ITS shout is up, and
-- it comes straight back when that shout lapses -- see ApplyIdleFade).
--
-- Styled like the Paladin Bar (dark backdrop, tooltip border) but with no
-- title strip: at one icon wide there is no room for a caption, and the strip
-- was the only reason the bar was ever wider than its icons. Alt-drag anywhere
-- on it to move it; shift-right-click any button for its settings.

local bar = nil

local INSET = 3    -- backdrop edge inset
local PAD = 3      -- inner padding around the button row
local BTN_GAP = 3
-- Icon size is a setting rather than a constant, so anything measured off it
-- is asked for per repaint. The bounds are what the bar still reads as at
-- either end: below 16 the count under the icon is unreadable, and past 64 a
-- two-icon strip is a banner.
WhoDoesWhat.SHOUT_BAR_ICON_SIZE = { min = 16, max = 64, default = 28 }

function WhoDoesWhat:GetShoutBarIconSize()
    local range = self.SHOUT_BAR_ICON_SIZE
    local size = tonumber(self.db.profile.settings.shoutBarIconSize)
        or range.default
    return math.floor(math.max(range.min, math.min(range.max, size)) + 0.5)
end

-- Room under a button for its covered/total count, at the icon size the bar
-- was drawn at. Kept in proportion so the number sits the same distance under
-- a 48px icon as it does under a 28px one.
local COUNT_H_RATIO = 10 / 28
local function CountHeight(size)
    return math.floor(size * COUNT_H_RATIO + 0.5)
end

-- Red when the shout is on nobody, yellow once it is on some of the party but
-- not all -- the same "started but unfinished" yellow the count under the icon
-- uses, so the glow and the number always agree. Both are settings now; these
-- are only reached if one has somehow gone missing from the profile.
local MISSING_GLOW_COLOR = { r = 1, g = 0.05, b = 0.05 }
local PARTIAL_GLOW_COLOR = { r = 1, g = 0.82, b = 0.2 }

function WhoDoesWhat:GetShoutBarGlowColor(which)
    local settings = self.db.profile.settings
    if which == "partial" then
        return settings.shoutBarGlowPartialColor or PARTIAL_GLOW_COLOR
    end
    return settings.shoutBarGlowMissingColor or MISSING_GLOW_COLOR
end

-- Named rather than left nil: an unset style would otherwise fall through to
-- whatever the status bars are set to, and this bar's style is its own.
local DEFAULT_GLOW_STYLE = "spin"

function WhoDoesWhat:GetShoutBarGlowStyle()
    return self.db.profile.settings.shoutBarGlowStyle or DEFAULT_GLOW_STYLE
end

-- Names a tooltip lists before the rest collapse into a count.
local TOOLTIP_NAMES = 6
-- How close to lapsing the soonest shout gets before its countdown appears.
-- 0 is Off -- no countdown at any point.
WhoDoesWhat.ShoutBarTimerSeconds = { 30, 15, 10, 0 }
WhoDoesWhat.SHOUT_BAR_DEFAULT_TIMER = 30

function WhoDoesWhat:GetShoutBarTimerSeconds()
    local saved = self.db.profile.settings.shoutBarTimerSeconds
    for _, seconds in ipairs(self.ShoutBarTimerSeconds) do
        if seconds == saved then return saved end
    end
    return self.SHOUT_BAR_DEFAULT_TIMER
end

function WhoDoesWhat:GetShoutBarTimerLabel(seconds)
    return seconds == 0 and "Off" or (seconds .. "s")
end

-- y from the bar's top down to where the button row begins. With no title
-- strip that is just the backdrop inset and the padding under it.
local CONTENT_TOP = INSET + PAD

-- ---------------------------------------------------------------------------
-- Party scope
-- ---------------------------------------------------------------------------

-- A shout reaches the caster's PARTY, not the raid, so every count on this bar
-- is scoped to the local player's subgroup: who is missing it, who wants it,
-- and how many warriors are around to divide the shouts between.
--
-- Returns a name lookup, or nil meaning "nothing to narrow" -- a party or solo,
-- where the group already is the party. Raid subgroups come off
-- GetRaidRosterInfo's third return, and its names already follow our keying
-- (same note as Sync.lua). The local player is found with UnitIsUnit rather
-- than by matching that name, which sidesteps the realm-suffix question
-- entirely.
local function PartyNames()
    if not IsInRaid() then return nil end
    local rows, mine = {}, nil
    for i = 1, GetNumGroupMembers() do
        local name, _, subgroup = GetRaidRosterInfo(i)
        if name then
            rows[#rows + 1] = { name = name, subgroup = subgroup }
            if UnitIsUnit("raid" .. i, "player") then mine = subgroup end
        end
    end
    -- No subgroup for ourselves means the roster is mid-change; count nobody
    -- out rather than reporting an empty party.
    if not mine then return nil end
    local names = {}
    for _, row in ipairs(rows) do
        if row.subgroup == mine then names[row.name] = true end
    end
    return names
end

-- Is this roster member in the shout's radius? A hunter pet is wherever its
-- owner is, so it is asked about by owner.
local function InParty(party, m)
    if not party then return true end
    return party[m.owner or m.name] and true or false
end

-- ---------------------------------------------------------------------------
-- Which shout a lone warrior is covering
-- ---------------------------------------------------------------------------

-- With one warrior in the party the bar shows one icon, because one warrior
-- can only keep one shout up. WHICH one is the warrior's call and nobody
-- else's -- a lone warrior on a caster-heavy party may well be the Commanding
-- Shout -- so it is a right-click on the icon rather than a setting anybody
-- has to go looking for. The choice is remembered, so a second warrior joining
-- and leaving again hands the icon back the way it was.
function WhoDoesWhat:GetSoloShout()
    local saved = self.db.profile.settings.shoutBarSoloShout
    for _, shout in ipairs(self.WarriorShouts) do
        if shout.key == saved then return shout end
    end
    return self.WarriorShouts[1]
end

-- Swap the lone icon to the other shout. Out of combat only: the swap rewrites
-- the button's secure spell attribute, which is exactly what a fight forbids
-- -- and picking which shout you are covering is a between-pulls decision
-- anyway. Classic Era has one shout and nothing to swap to.
function WhoDoesWhat:ToggleSoloShout()
    if InCombatLockdown() or #self.WarriorShouts < 2 then return false end
    local current = self:GetSoloShout()
    for _, shout in ipairs(self.WarriorShouts) do
        if shout ~= current then
            self.db.profile.settings.shoutBarSoloShout = shout.key
            self:LogUiBuilding("Shout bar solo icon swapped to "
                .. tostring(shout.name) .. ".")
            self:RefreshWarriorShoutBar()
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Visibility mode
-- ---------------------------------------------------------------------------

-- The four answers the settings dropdown offers, and what each one means.
-- Every mode but "always" wants a warrior in the group: a shout bar in a
-- warriorless group is glowing at something nobody present can cast.
WhoDoesWhat.ShoutBarModes = {
    { key = "warriorOnly", label = "Warriors only" },
    { key = "withWarrior", label = "With a warrior" },
    { key = "always", label = "Always" },
    { key = "never", label = "Never" },
}
WhoDoesWhat.SHOUT_BAR_DEFAULT_MODE = "warriorOnly"

function WhoDoesWhat:GetShoutBarMode()
    local mode = self.db.profile.settings.shoutBarShow
    for _, entry in ipairs(self.ShoutBarModes) do
        if entry.key == mode then return mode end
    end
    return self.SHOUT_BAR_DEFAULT_MODE
end

function WhoDoesWhat:GetShoutBarModeLabel(mode)
    for _, entry in ipairs(self.ShoutBarModes) do
        if entry.key == mode then return entry.label end
    end
end

-- Should the bar be up, and how many warriors are here to divide the shouts
-- between? The count is returned even when it is zero, because "always" mode
-- shows the bar anyway and still wants to lay it out.
local function ResolveShoutBar()
    local mode = WhoDoesWhat:GetShoutBarMode()
    if mode == "never" then return false, 0 end
    -- Warriors in OUR party: a warrior two subgroups over shouts for their own
    -- party, not ours, so they neither keep the bar up nor take one of its
    -- shouts off our hands.
    local party = PartyNames()
    local warriors = 0
    for _, name in ipairs(Assign.MembersOfClass("Warrior")) do
        if not party or party[name] then warriors = warriors + 1 end
    end
    if mode == "warriorOnly" then
        local _, class = UnitClass("player")
        if class ~= "WARRIOR" then return false, warriors end
    end
    if mode ~= "always" and warriors == 0 then return false, warriors end
    return true, warriors
end

-- ---------------------------------------------------------------------------
-- Position (Alt-drag) + anchor
-- ---------------------------------------------------------------------------

-- Which edge holds still as the bar changes width -- which it does whenever a
-- second warrior joins or leaves the party and the second icon comes or goes.
-- The choice is encoded as the saved anchor point, so a stored position is
-- self-describing and switching the setting just re-derives it from wherever
-- the bar currently sits (see SetShoutBarAnchor). Same design as the paladin
-- bar's grow setting, named for the edge that stays put rather than the
-- direction the bar spills.
local ANCHOR_POINTS = { LEFT = "TOPLEFT", CENTER = "TOP", RIGHT = "TOPRIGHT" }
WhoDoesWhat.ShoutBarAnchors = {
    { key = "LEFT", label = "Left" },
    { key = "CENTER", label = "Center" },
    { key = "RIGHT", label = "Right" },
}
WhoDoesWhat.SHOUT_BAR_DEFAULT_ANCHOR = "CENTER"

function WhoDoesWhat:GetShoutBarAnchor()
    local anchor = self.db.profile.settings.shoutBarAnchor
    return ANCHOR_POINTS[anchor] and anchor or self.SHOUT_BAR_DEFAULT_ANCHOR
end

function WhoDoesWhat:GetShoutBarAnchorLabel(anchor)
    for _, entry in ipairs(self.ShoutBarAnchors) do
        if entry.key == anchor then return entry.label end
    end
end

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

-- Record the rect by whichever edge the anchor setting says to keep.
local function SavePosition()
    if not bar then return end
    local point = ANCHOR_POINTS[WhoDoesWhat:GetShoutBarAnchor()]
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
    WhoDoesWhat.db.profile.settings.shoutBarPos = { point = point, x = x, y = y }
end

-- Anchored by the point the position was SAVED under, not the current setting:
-- the two differ only between a setting change and the SavePosition that
-- follows it, and re-reading the saved point is what makes a stored position
-- stand on its own.
local function LoadPosition()
    local p = WhoDoesWhat.db.profile.settings.shoutBarPos
    bar:ClearAllPoints()
    if p and p.x and p.y then
        local point = (p.point == "TOPRIGHT" or p.point == "TOP")
            and p.point or "TOPLEFT"
        p.point = point
        p.x, p.y = ClampPosition(p.x, p.y, point)
        bar:SetPoint(point, UIParent, "BOTTOMLEFT", p.x, p.y)
    else
        -- Dead centre until it is Alt-dragged somewhere: the one spot on any
        -- screen resolution that is certainly not behind something.
        bar:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

-- Re-anchor to the newly chosen edge without visually moving the bar: save the
-- current rect under the new point, then load it straight back.
function WhoDoesWhat:SetShoutBarAnchor(anchor)
    self.db.profile.settings.shoutBarAnchor = anchor
    if bar and bar:GetLeft() then
        SavePosition()
        LoadPosition()
    end
    self:RefreshWarriorShoutBar()
end

-- Attach Alt-gated dragging to a mouse region that moves the whole bar. The
-- bar parents secure buttons, so moving it mid-fight is forbidden -- the drag
-- simply doesn't start in combat.
local function AttachAltDrag(region)
    region:EnableMouse(true)
    region:RegisterForDrag("LeftButton")
    region:SetScript("OnDragStart", function()
        if not IsAltKeyDown() or InCombatLockdown() then return end
        bar.moving = true
        bar:StartMoving()
    end)
    region:SetScript("OnDragStop", function()
        if not bar.moving then return end
        bar.moving = nil
        bar:StopMovingOrSizing()
        -- Save, then re-anchor off the saved corner: StartMoving may have left
        -- the frame on a different one.
        SavePosition()
        LoadPosition()
    end)
end

-- ---------------------------------------------------------------------------
-- Tooltip lines
-- ---------------------------------------------------------------------------

-- These four mirror the same-named helpers in StatusBarsView.lua so a name
-- reads identically wherever WDW lists one. They are small enough to restate
-- and awkward to share -- StatusBarsView keeps them local -- but if a third
-- view ever wants them they belong somewhere common instead of a third copy.

-- Tooltip icon size, shared by the role icon and the pet marker so every line
-- is one strip of icons at one size.
local TOOLTIP_ICON = 14

-- The icon leading a line: the member's assigned role, the hunter-pet role for
-- a pet, and their class as the fallback so a player whose role nobody has set
-- still lines up with everyone else instead of starting flush left.
local function LineIcon(m)
    if m.isPet then
        local role = WhoDoesWhat.HunterPetRole
        return role and (WhoDoesWhat:RoleIconMarkup(role.icon, TOOLTIP_ICON)
            .. " ") or ""
    end
    local markup = Assign.RoleIconMarkup(m.name, TOOLTIP_ICON)
    if markup ~= "" then return markup end
    local classIcon = m.classInfo and m.classInfo.classIcon
    return classIcon
        and (WhoDoesWhat:RoleIconMarkup(classIcon, TOOLTIP_ICON) .. " ") or ""
end

-- Class-coloured, realm-suffix-free, and a pet by its own name with its owner
-- behind it (WhoDoesWhat:DisplayName). A pet wears its owner's class colour,
-- which is why the pet icon above has to be the thing that says "pet".
local function ColoredName(m)
    return "|cff" .. ((m.classInfo and m.classInfo.colorHex) or "FFFFFF")
        .. WhoDoesWhat:DisplayName(m.name) .. "|r"
end

local function IsLocalPlayerEntry(m)
    local owner = m.name:match("^(.+)'s Pet$") or m.name
    return (owner:match("^([^%-]+)") or owner) == UnitName("player")
end

-- You first. It is your bar, and your own missing shout is the one line you
-- can act on without asking anybody -- so it should never be the entry that
-- got cut off by the name limit. Your pet follows you; everyone else keeps
-- the order they came in.
local function SelfFirst(entries)
    local mine, rest = {}, {}
    for _, m in ipairs(entries) do
        local bucket = IsLocalPlayerEntry(m) and mine or rest
        bucket[#bucket + 1] = m
    end
    if #mine == 0 then return entries end
    table.sort(mine, function(a, b) return not a.isPet and b.isPet == true end)
    for _, m in ipairs(rest) do mine[#mine + 1] = m end
    return mine
end

-- ---------------------------------------------------------------------------
-- Coverage
-- ---------------------------------------------------------------------------

-- A corpse is never a target. The raid-buff checks in Assignments.lua keep the
-- dead on their lists out of combat on purpose -- they are about to be
-- resurrected and rebuffed, and that gap is what those bars exist to show --
-- but a shout is not something you queue up for later: it is cast on whoever
-- is standing there when you press it, and a dead raider is not.
local function IsDeadTarget(name)
    return WhoDoesWhat:HasBuff(name, "dead") == true
end

-- The units to range-check against, by the same keys the roster uses. Built
-- once per pass rather than resolving each member separately, which would walk
-- the whole raid per name.
local function BuildNameToUnit()
    local map = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name = GetUnitName("raid" .. i, true)
            if name then map[name] = "raid" .. i end
        end
    else
        local me = GetUnitName("player", true) or UnitName("player")
        if me then map[me] = "player" end
        for i = 1, GetNumSubgroupMembers() do
            local name = GetUnitName("party" .. i, true)
            if name then map[name] = "party" .. i end
        end
    end
    return map
end

-- Range test for the "ignore players far out of range" option. UnitInRange is
-- the standard ~40 yard "are they anywhere near me" check, deliberately wider
-- than a shout's own radius: this is meant to drop the raider who ran off to
-- another wing, not the one standing a step too far back -- who you do still
-- want counted, because stepping in is the fix.
--
-- A pet is wherever its owner is, so it is asked about by owner. Anything the
-- check can't answer -- an unresolved name, a fake raider, a client that
-- declines -- counts as in range, so an unknown never quietly shrinks the
-- total.
local function InShoutRange(m, nameToUnit)
    local unit = nameToUnit[m.owner or m.name]
    if not unit then return true end
    local inRange, checked = UnitInRange(unit)
    if checked then return inRange and true or false end
    return true
end

-- Everyone this shout is for who is confirmed to be without it, by name.
-- Unknown (never scanned) is not missing -- it is unknown, and flagging it
-- would leave the bar glowing at a raider nobody can see yet.
local function MissingFor(shout)
    local disconnected = Assign.DisconnectedGroupTargets()
    local party = PartyNames()
    local checkRange = WhoDoesWhat.db.profile.settings.shoutBarIgnoreOutOfRange
    local nameToUnit = checkRange and BuildNameToUnit() or nil
    local targets = {}
    for _, m in ipairs(Assign.GetEligibleMembers(nil)) do
        targets[#targets + 1] = m
    end
    for _, pet in ipairs(Assign.GetPetMembers()) do
        -- No tracked state means no pet out; only a summoned one is a target.
        if WhoDoesWhat:HasBuff(pet.name, shout.key) ~= nil then
            targets[#targets + 1] = pet
        end
    end

    local missing, total, soonest = {}, 0, nil
    for _, m in ipairs(targets) do
        if not m.isFake and not WhoDoesWhat:IsNonRaider(m.name)
            and InParty(party, m)
            and not disconnected[m.name]
            and not IsDeadTarget(m.name)
            and (not checkRange or InShoutRange(m, nameToUnit))
            and (shout.everyone or WhoDoesWhat:WantsBattleShout(m)) then
            total = total + 1
            if WhoDoesWhat:HasBuff(m.name, shout.key) == false then
                -- The roster member itself, not just its name: the tooltip
                -- needs the class for its colour and the pet flag for its
                -- icon. Read-only -- these tables are shared (Assignments.lua).
                missing[#missing + 1] = m
            else
                -- Whoever loses it first is when this shout next needs
                -- casting, so that is the only duration worth a number.
                local remaining = WhoDoesWhat:GetBuffTimeRemaining(m.name,
                    shout.key)
                if remaining and (not soonest or remaining < soonest) then
                    soonest = remaining
                end
            end
        end
    end
    table.sort(missing, function(a, b)
        return WhoDoesWhat:DisplayName(a.name) < WhoDoesWhat:DisplayName(b.name)
    end)
    return SelfFirst(missing), total, soonest
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

-- `which` is "missing", "partial", or nil to turn the glow off. The look comes
-- from the status bars' shared set of highlight styles, in whichever of the
-- bar's two colours the state calls for; ApplyStatusBarHighlight tracks what
-- is running, so a button switching between the two colours in place -- which
-- is exactly what a shout going from nobody to part of the party does --
-- restarts the effect rather than leaving it in the old colour.
local function SetButtonGlow(btn, which)
    WhoDoesWhat:ApplyStatusBarHighlight(btn, which ~= nil,
        WhoDoesWhat:GetShoutBarGlowStyle(),
        which and WhoDoesWhat:GetShoutBarGlowColor(which) or nil)
end

local function ShowShoutTooltip(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, 0)
    GameTooltip:SetText(btn.shout.name, 1, 1, 1)
    local missing, total = btn.missing or {}, btn.total or 0
    if total == 0 then
        GameTooltip:AddLine("Nobody in your party wants it.", 0.6, 0.6, 0.6)
    elseif #missing == 0 then
        GameTooltip:AddLine("All " .. total .. " in your party covered.",
            0.3, 1, 0.3)
    else
        GameTooltip:AddLine(#missing .. " of " .. total .. " missing it:",
            1, 0.3, 0.3)
        for i = 1, math.min(#missing, TOOLTIP_NAMES) do
            local m = missing[i]
            GameTooltip:AddLine(LineIcon(m) .. ColoredName(m), 1, 1, 1)
        end
        if #missing > TOOLTIP_NAMES then
            GameTooltip:AddLine("... and " .. (#missing - TOOLTIP_NAMES)
                .. " more", 0.6, 0.6, 0.6)
        end
    end
    -- The bar has no title strip to hang these off any more, so every button
    -- carries them.
    GameTooltip:AddLine(" ")
    UI.AddTooltipHint(GameTooltip, "Left-Click:", "Shout")
    if btn.isSoloIcon then
        UI.AddTooltipHint(GameTooltip, "Right-Click:", "Swap shout")
    end
    UI.AddTooltipHint(GameTooltip, "Alt-Drag:", "Move")
    UI.AddTooltipHint(GameTooltip, "Shift-Right-Click:",
        "Shout Bar Settings")
    GameTooltip:Show()
end

-- Everything on a button that is measured in pixels, re-read from the icon
-- size. Both fonts scale with it: the count is unreadable under a big icon at
-- its old size, and the countdown is meant to be the thing you see. Called
-- from the layout pass, which only ever runs out of combat -- resizing a
-- secure button mid-fight is forbidden.
local COUNT_FONT_RATIO = 10 / 28
local TIMER_FONT_RATIO = 18 / 28
local FALLBACK_FONT = "Fonts\\FRIZQT__.TTF"

local function SizeShoutButton(btn, size)
    if btn.sizedAt == size then return end
    btn.sizedAt = size
    btn:SetSize(size, size)
    -- A font string built off a font object can hand back nothing for its face
    -- until it has drawn, so the fallback is the client's own default rather
    -- than a nil straight into SetFont.
    local face, _, flags = btn.count:GetFont()
    btn.count:SetFont(face or FALLBACK_FONT,
        math.max(7, math.floor(size * COUNT_FONT_RATIO + 0.5)), flags)
    local timerFace, _, timerFlags = btn.timer:GetFont()
    btn.timer:SetFont(timerFace or FALLBACK_FONT,
        math.max(10, math.floor(size * TIMER_FONT_RATIO + 0.5)), timerFlags)
end

local function CreateShoutButton(index)
    local btn = CreateFrame("Button", nil, bar, "SecureActionButtonTemplate")
    btn:SetSize(WhoDoesWhat:GetShoutBarIconSize(),
        WhoDoesWhat:GetShoutBarIconSize())
    -- Secure action buttons obey ActionButtonUseKeyDown, so the edge they act
    -- on is the client's choice, not ours. Register both -- exactly what the
    -- paladin bar and PallyPower do. Registering only "AnyUp" looks tidier and
    -- is simply broken on a client set to act on key down: the cast never
    -- fires at all. The cost is that PostClick runs twice per click, which the
    -- handler below drops.
    btn:RegisterForClicks("AnyUp", "AnyDown")

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 0.9)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn.icon = icon

    -- The covered/total count under the icon, in the same slot -- and the same
    -- "x/y" language -- the paladin bar's class buttons carry theirs in.
    local count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("TOP", btn, "BOTTOM", 0, -1)
    btn.count = count

    -- The expiry countdown, over the icon rather than under it: it is about
    -- the shout itself, not about who has it, and it only ever appears in the
    -- last few seconds -- when it wants to be the thing you see.
    local timer = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    timer:SetPoint("CENTER")
    -- Big and outlined: it sits ON a busy spell icon, and it only ever shows
    -- in the last seconds before a shout drops, which is not a moment for
    -- squinting. The face is borrowed off a standard font object so it follows
    -- whatever the client is using.
    local timerFont = GameFontNormal:GetFont()
    timer:SetFont(timerFont or "Fonts\\FRIZQT__.TTF", 18, "OUTLINE")
    timer:SetTextColor(1, 0.82, 0.2)
    timer:Hide()
    btn.timer = timer

    btn:SetScript("OnEnter", ShowShoutTooltip)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Alt-drag has to work over the buttons too: they cover nearly the whole
    -- bar, so without this there is barely anything left to grab.
    AttachAltDrag(btn)
    -- Right-click casts nothing (no type2 is ever set), which leaves it free
    -- to carry the two things that aren't casting: shift for the settings
    -- page, plain for swapping which shout a lone icon covers. PostClick is an
    -- ordinary script, so neither taints anything.
    btn:SetScript("PostClick", function(self, mouseButton, down)
        -- Both click edges are registered above, so this fires twice per
        -- click. Act on the release only: two passes would open the settings
        -- window and immediately close it again, and swap the shout straight
        -- back to where it started.
        if down then return end
        if mouseButton ~= "RightButton" then return end
        if IsShiftKeyDown() then
            WhoDoesWhat:OpenAddonSettingsView("Warriors")
        elseif self.isSoloIcon then
            WhoDoesWhat:ToggleSoloShout()
        end
    end)
    btn:Hide()
    bar.buttons[index] = btn
    return btn
end

-- Colour for a covered/total count: green only when the shout is on everybody,
-- yellow the moment it isn't, grey when nobody in the party wants it. The
-- paladin bar splits "none" off as its own red, but here the glow is already
-- saying that at a much higher volume -- what the number adds is the plain
-- binary of done versus not done.
local function CountColor(covered, total)
    if total == 0 then return 0.6, 0.6, 0.6 end
    if covered >= total then return 0.3, 1, 0.3 end
    return 1, 0.82, 0.2
end

-- Point a button at a shout, including the secure attributes that make it
-- cast. Rank-less by name, so the client picks the highest rank known. Only
-- ever called out of combat (see the lockdown guard in the refresh), and only
-- writes when the shout actually changed -- which is rare, but does happen: a
-- lone icon right-clicked to the other shout, or a second warrior arriving and
-- handing button one its canonical shout back.
local function ConfigureShoutButton(btn, shout)
    if btn.shout == shout then return end
    btn.shout = shout
    btn:SetAttribute("type1", "spell")
    btn:SetAttribute("spell1", shout.name)
end

-- The countdown over the icon, shown only inside the configured window.
-- Kept apart from the repaint above because it has to tick between repaints:
-- the bar's OnUpdate calls this on its own, off the stored expiry rather than
-- by rescanning anybody's auras.
local function UpdateShoutTimer(btn)
    local warn = WhoDoesWhat:GetShoutBarTimerSeconds()
    local remaining = btn.expiresAt and (btn.expiresAt - GetTime())
    if warn > 0 and remaining and remaining > 0 and remaining < warn then
        btn.timer:SetFormattedText("%d", math.ceil(remaining))
        btn.timer:Show()
    else
        btn.timer:Hide()
    end
end

-- Has this one shout got anything to say? Somebody still missing it, or a
-- countdown running on it. Asked per button, so a Battle Shout that is fully
-- up goes quiet while a Commanding Shout somebody is missing stays put.
local function ButtonIsIdle(btn)
    if not WhoDoesWhat.db.profile.settings.shoutBarHideWhenBuffed then
        return false
    end
    return not ((btn.missing and #btn.missing > 0) or btn.timer:IsShown())
end

-- "Hide while everything is up": fade each icon out on its own once its shout
-- is on everybody, and bring it straight back the moment somebody loses it or
-- its countdown starts. The backdrop belongs to the row rather than to either
-- icon, so it only goes once nothing is left in it.
--
-- Fade, not Hide, and for two reasons. A hidden button stops being repainted
-- (the refresh and the tick both walk shown buttons only), so it could never
-- notice the shout that lapsed and would have no way back -- the same trap
-- that stops the bar itself being hidden. And alpha sidesteps the lockdown,
-- which matters because this flips mid-fight constantly, exactly when a
-- protected child forbids Show/Hide.
--
-- The cost of fading in place is that a faded icon keeps its slot: with one of
-- two shouts quiet you get an icon and a gap rather than a bar that shrinks
-- around the survivor. Repacking would mean moving a protected button, which
-- is the one thing combat forbids -- and combat is when this happens.
--
-- An alpha-0 frame still swallows mouse clicks, so the mouse comes off with
-- it. THAT part is lockdown-bound, so an icon that fades mid-fight keeps
-- catching clicks in its footprint until the fight ends.
local function ApplyIdleFade()
    if not bar then return end
    local combat = InCombatLockdown()
    local anyVisible = false
    for _, btn in ipairs(bar.buttons) do
        if btn:IsShown() then
            local idle = ButtonIsIdle(btn)
            btn:SetAlpha(idle and 0 or 1)
            if not combat then btn:EnableMouse(not idle) end
            if not idle then anyVisible = true end
        end
    end
    -- Alpha multiplies down, so the bar has to stay lit for any icon to show.
    bar:SetAlpha(anyVisible and 1 or 0)
    if not combat then bar:EnableMouse(anyVisible) end
end

local function UpdateShoutButton(btn)
    local missing, total, soonest = MissingFor(btn.shout)
    local covered = total - #missing
    -- Stored as an absolute moment so the tick can count it down without
    -- asking BuffTracking anything.
    btn.expiresAt = soonest and (GetTime() + soonest) or nil
    btn.missing, btn.total = missing, total
    btn.icon:SetTexture(btn.shout.icon)
    btn.icon:SetDesaturated(#missing == 0)
    if #missing == 0 then
        SetButtonGlow(btn, nil)
    else
        SetButtonGlow(btn, covered > 0 and "partial" or "missing")
    end
    btn.count:SetFormattedText("%d/%d", covered, total)
    btn.count:SetTextColor(CountColor(covered, total))
    UpdateShoutTimer(btn)
    if GameTooltip:IsShown() and GameTooltip:GetOwner() == btn then
        ShowShoutTooltip(btn)
    end
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

local function EnsureBar()
    if bar then return bar end

    bar = CreateFrame("Frame", "WhoDoesWhatShoutBar", UIParent, "BackdropTemplate")
    -- MEDIUM, the same strata the paladin bar sits at. This was briefly HIGH
    -- while a bar that came up invisible was being chased, but the culprit
    -- there was its default position, not its strata -- and HIGH is where the
    -- world map lives, so the bar drew straight over it.
    --
    -- The frame level is raised within MEDIUM instead: that keeps it clear of
    -- ordinary HUD frames sharing the strata without letting it climb over the
    -- map, since strata always wins over level.
    bar:SetFrameStrata("MEDIUM")
    bar:SetFrameLevel(20)
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = INSET, right = INSET, top = INSET, bottom = INSET },
    })
    bar:SetBackdropColor(0, 0, 0, 0.95)
    bar:SetBackdropBorderColor(0.4, 0.4, 0.4)
    bar.buttons = {}
    AttachAltDrag(bar)

    -- The countdown is the one thing here that changes without an event to
    -- hang off, so it gets its own light tick. Arithmetic on at most two
    -- buttons against a stored expiry -- no aura scans, no coverage math,
    -- which all still ride the refresh path.
    bar.timerTick = 0
    bar:SetScript("OnUpdate", function(self, elapsed)
        self.timerTick = self.timerTick + elapsed
        if self.timerTick < 0.25 then return end
        self.timerTick = 0
        for _, btn in ipairs(self.buttons) do
            if btn:IsShown() then UpdateShoutTimer(btn) end
        end
        -- A countdown starting or ending is one of the two things that can
        -- bring an idle-faded bar back, so it is re-decided on the same tick.
        ApplyIdleFade()
    end)

    LoadPosition()
    return bar
end

-- ---------------------------------------------------------------------------
-- Refresh + visibility
-- ---------------------------------------------------------------------------

-- Repaint the bar's icons. Only touches widgets; whether the bar is up at all
-- is UpdateWarriorShoutBarVisibility's call.
function WhoDoesWhat:RefreshWarriorShoutBar()
    if not bar or not bar:IsShown() then return end
    local _, warriors = ResolveShoutBar()

    -- Secure buttons cannot be created, shown, hidden or moved mid-fight, and
    -- neither can the bar parenting them. Counts and glows are ordinary
    -- widgets and repaint fine, so in combat that is all this does; the layout
    -- below waits for PLAYER_REGEN_ENABLED.
    if InCombatLockdown() then
        for _, btn in ipairs(bar.buttons) do
            if btn:IsShown() then UpdateShoutButton(btn) end
        end
        ApplyIdleFade()
        return
    end

    -- A single warrior has one shout to give, so only the first one is theirs
    -- to keep up. Classic Era has only Battle Shout to show either way.
    local shown = math.min((warriors == 1) and 1 or #self.WarriorShouts,
        #self.WarriorShouts)
    -- Chrome the user can switch off. The backdrop keeps its inset either way,
    -- so hiding it leaves the icons exactly where they were rather than
    -- shifting the whole bar under the cursor.
    local settings = self.db.profile.settings
    local hideBackground = settings.shoutBarHideBackground and true or false
    local hideNumbers = settings.shoutBarHideNumbers and true or false
    bar:SetBackdropColor(0, 0, 0, hideBackground and 0 or 0.95)
    bar:SetBackdropBorderColor(0.4, 0.4, 0.4, hideBackground and 0 or 1)

    -- One icon shows whichever shout the warrior picked; two show both in
    -- their own order.
    local soloIcon = shown == 1 and #self.WarriorShouts > 1
    local size = self:GetShoutBarIconSize()
    for i = 1, shown do
        local btn = bar.buttons[i] or CreateShoutButton(i)
        btn.isSoloIcon = soloIcon
        SizeShoutButton(btn, size)
        ConfigureShoutButton(btn,
            shown == 1 and self:GetSoloShout() or self.WarriorShouts[i])
        UpdateShoutButton(btn)
        btn.count:SetShown(not hideNumbers)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", bar, "TOPLEFT",
            INSET + PAD + (i - 1) * (size + BTN_GAP), -CONTENT_TOP)
        btn:Show()
    end
    for i = shown + 1, #bar.buttons do
        SetButtonGlow(bar.buttons[i], nil)
        bar.buttons[i]:Hide()
    end

    -- The bar is exactly as wide as its icons, with no caption left to pad it
    -- out past them.
    local rowW = shown * size + (shown - 1) * BTN_GAP
    bar:SetSize(INSET * 2 + PAD * 2 + rowW,
        CONTENT_TOP + size + (hideNumbers and 0 or CountHeight(size))
            + INSET + 1)
    if not bar.moving then LoadPosition() end
    ApplyIdleFade()
end

-- Show or hide the whole bar per the settings mode, then repaint.
function WhoDoesWhat:UpdateWarriorShoutBarVisibility()
    -- GROUP_ROSTER_UPDATE can beat AceDB's profile into existence at login.
    if not self.db then return end
    -- Showing or hiding a frame that parents secure buttons is forbidden in
    -- combat. Repaint what is already up and let PLAYER_REGEN_ENABLED settle
    -- the rest -- a warrior joining or leaving the party mid-pull is the only
    -- thing this defers, and it is not urgent.
    if InCombatLockdown() then
        if bar and bar:IsShown() then self:RefreshWarriorShoutBar() end
        return
    end
    if not ResolveShoutBar() then
        if bar then
            for _, btn in ipairs(bar.buttons) do SetButtonGlow(btn, nil) end
            bar:Hide()
        end
        return
    end
    local f = EnsureBar()
    f:Show()
    self:RefreshWarriorShoutBar()
end

-- Bring the bar up on login/reload, then again once the roster and the first
-- aura scan have had time to land.
--
-- The roster event hangs here rather than on the bar, because the bar may not
-- exist yet: in "with a warrior" mode a group without one has nothing on
-- screen, and a frame that was never created cannot notice the warrior who
-- walks in. Buff arrivals ride the buff-tracking notify instead
-- (RefreshBoardViews in Views/ViewRefresh.lua).
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("GROUP_ROSTER_UPDATE")
-- Leaving combat is when everything the lockdown deferred finally happens.
loader:RegisterEvent("PLAYER_REGEN_ENABLED")
loader:SetScript("OnEvent", function(_, event)
    WhoDoesWhat:UpdateWarriorShoutBarVisibility()
    if event ~= "PLAYER_ENTERING_WORLD" then return end
    C_Timer.After(2, function()
        WhoDoesWhat:UpdateWarriorShoutBarVisibility()
    end)
end)
