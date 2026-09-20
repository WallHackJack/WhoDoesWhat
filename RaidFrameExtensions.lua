local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Draws a raider's WDW spec icon onto Blizzard's compact raid (and raid-style
-- party) frames, standing in for the group icon the client draws there -- the
-- main-tank / main-assist marker, or the tank/healer/damager symbol.
--
-- Display only, and deliberately quiet: a player whose spec has neither been
-- chosen on the board nor scanned from their talents gets nothing from us.
--
-- ---------------------------------------------------------------------------
-- We draw into a texture of our OWN and hide the client's behind it, and the
-- only thing we ever change on the client's side is that texture's ALPHA.
--
-- The first version of this repainted the client's `roleIcon` in place, which
-- meant borrowing its size, anchor, coordinates and gradient and owing every
-- one of them back. Each was a way to strand the client's icon somewhere it
-- could not recover from: a leftover band mask rendered its role icon as a
-- zoomed slice of itself, and a restore that put back a size but never a Show
-- left the corner empty until a reload built the frames again. There is no
-- amount of care that makes borrowing safe, because handing it back means
-- reproducing a decision -- shown, sized and atlased from the unit -- that is
-- the client's to make and ours only to guess at.
--
-- Alpha is the whole of the bargain now. The client keeps its own geometry, so
-- nothing of ours can distort it; it goes on drawing its icon at full size
-- underneath, invisibly, and putting the corner back is SetAlpha(1) on a
-- texture that never stopped being correct. Nothing in the client writes alpha
-- on this texture, so it stays put between our passes without a fight.
--
-- It also gets the text right for free. The client anchors the name to the
-- role icon's edge, so every attempt to resize that icon dragged the name
-- around and had to be corrected back -- the source of the indented and
-- floating names. An icon that keeps its size does not move the name at all,
-- so every style now leaves the client's own text layout untouched.
--
-- What we do NOT leave alone is the raid profile's own show/hide of that
-- corner: a known spec draws even where the profile has role icons switched
-- off, and over the vehicle icon. Our setting is the switch for this, and a
-- feature that silently drew nothing because of a checkbox in a different
-- window would just read as broken.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Styles
--
-- "corner" stands in for the client's own icon where it draws it: a round one,
-- masked and ringed, at 0.78 of the size it uses (17px in the default profile,
-- so 13) and centred on the spot its own icon occupies. Being a replacement
-- rather than an addition, it is also the one style that draws NOTHING for a
-- player the board has no role for -- it simply stands down, and the client's
-- own group role icon is there already, at full alpha, needing nothing from us.
--
-- The band styles instead run the icon down an edge of the health bar, from
-- the top corner to just above the power bar. The health bar is the right
-- thing to measure against rather than the frame: the client anchors it from
-- the frame's top-left down to exactly where the power bar starts, so its edge
-- already IS that span -- no power-bar arithmetic here, and a profile with the
-- power bar switched off lengthens the band on its own.
--
-- "band" ends on a dark hairline, so it stays narrow enough to read as a
-- stripe. "bandFaded" dissolves inward instead, and that is what pays for its
-- width: a tail that costs nothing visually can run out to square. Both
-- mirror onto the bar's other edge as the "Right" pair.
--
-- These are whole pixels on purpose. The offsets are UI units, not device
-- pixels, so a fractional one lands mid-pixel and softens the icon's edge
-- instead of moving it -- there is no half step here worth having.
-- ---------------------------------------------------------------------------

local ICON_SCALE = 0.78

-- Where the name goes once a band has taken over the corner. The client's icon
-- is invisible under our stand-in but still 17px wide, and the name is anchored
-- off its edge, so left to itself the name keeps an indent for an icon nobody
-- can see -- which is a lot of daylight on a 72px frame.
--
-- Given as an absolute inset from the frame rather than a nudge, so it says
-- where the name lands rather than how far it moved, and re-stated as the
-- client's own no-icon spot (its 3px inset plus the 1px a hidden icon collapses
-- to) when there is nothing in the way at all. A band that fades has nothing in
-- the way; an opaque one wants clearing by a couple of pixels.
local NAME_CLEAR_X = 4
local NAME_TOP_Y = -3

-- What a band draws for a player the board says nothing about: the question
-- mark this addon already uses for "unknown" everywhere else (Assignments.lua's
-- custom target, SectionKit, the role customizer, Data.lua's icon fallback).
-- Ordinary icon art at icon proportions, so it takes the same trim and mask as
-- the spec icons beside it, and it says the honest thing -- not "this raider is
-- damage" but "we do not know yet".
--
-- The corner style deliberately has no equivalent: see STYLES below.
local UNKNOWN_ICON = 134400 -- INV_Misc_QuestionMark

-- `width`     strip width, and the mark of a band style; absent means corner.
-- `side`      which edge of the health bar it runs down; LEFT when absent.
-- `edge`      finish with the dark hairline on the strip's inner side.
-- `fadeFrom`  gradient alpha at the strip's outer edge, fading to `fadeTo` at
--             its inner one. Absent means flat.
-- `circle`    mask the icon round and ring it, for the corner.
-- `unknown`   what to draw for a player with no board role. Absent means draw
--             NOTHING for them -- which for the corner style is the whole
--             point: it replaces the client's icon, so standing down is what
--             lets the client's own group role show through untouched. We
--             never have to reproduce that icon or reason about drawing over
--             it, because the one we would be covering is simply left alone.
-- `nameLeft`  absolute inset for the name's left anchor; absent leaves it.
-- `nameRight` the same for its right anchor, to keep a name off an opaque
--             strip running down that side.
-- `nameCenter` centre the name between those insets: the middle of the frame
--             under a faded band, which washes under the text, and the middle
--             of the free area beside an opaque one.
-- `outline`   honours the role outline settings.
local STYLES = {
    corner = { circle = true, outline = true },
    band = { width = 12, edge = true, outline = true,
        unknown = UNKNOWN_ICON, nameLeft = 15, nameRight = -NAME_CLEAR_X,
        nameCenter = true },
    bandFaded = { width = 30, fadeFrom = 0.6, fadeTo = 0,
        unknown = UNKNOWN_ICON, nameLeft = NAME_CLEAR_X,
        nameRight = -NAME_CLEAR_X, nameCenter = true },
    bandRight = { width = 12, side = "RIGHT", edge = true, outline = true,
        unknown = UNKNOWN_ICON, nameLeft = NAME_CLEAR_X, nameRight = -15,
        nameCenter = true },
    bandRightFaded = {
        width = 30, side = "RIGHT", fadeFrom = 0.6, fadeTo = 0,
        unknown = UNKNOWN_ICON, nameLeft = NAME_CLEAR_X,
        nameRight = -NAME_CLEAR_X, nameCenter = true,
    },
}

-- Where our corner icon goes, given the offset and size the client uses for
-- its own. We CENTRE on it rather than padding off the corner: a square could
-- sit tight into the angle and look deliberate, but a disc with a ring around
-- it reads as hanging off the frame there -- too high and too far out on both
-- axes at once, since a circle's corner is empty. The client's icon is the
-- spot the eye already expects, so the honest answer is to occupy it.
--
-- Sign-aware, so it works from whichever corner the layout chose: the offset
-- always points inward from that corner, so nudging it further from zero is
-- always "further into the frame".
--
-- `offset`/`theirSize` describe the client's icon, `iconSize`/`ring` ours.
-- Centres the icon-plus-ring box on theirs, then steps in past the ring so the
-- answer is where the ICON goes -- the ring is anchored to the icon, so it has
-- to be counted here or the disc hangs a pixel further out than the circle
-- inside it looks like it should.
local function CornerOffset(offset, theirSize, iconSize, ring)
    local inset = (theirSize - (iconSize + ring * 2)) / 2 + ring
    if offset < 0 then return offset - inset end
    return offset + inset
end

-- Which style to draw, and whether this frame can carry it. A band needs a
-- measurable health bar to run down; without one there is nothing to anchor a
-- strip to, so that frame quietly keeps the corner.
local function StyleFor(frame)
    local db = WhoDoesWhat.db
    -- Same fallback the settings dropdown falls back to, so a missing saved
    -- value can never draw one style while the window ticks another.
    local key = db and db.profile.settings.raidFrameRoleIconStyle or "corner"
    local style = STYLES[key]
    if not (style and style.width) then return "corner", STYLES.corner end
    local bar = frame.healthBar
    local height = bar and bar:GetHeight() or 0
    if height <= 0 then return "corner", STYLES.corner end
    return key, style, height
end

-- ---------------------------------------------------------------------------
-- Painting one texture: trim, mask, fade
-- ---------------------------------------------------------------------------

-- Ability icons carry a rounded bevel baked into the art, so a texture drawn
-- at its full coordinates shows that border instead of filling with the symbol
-- -- worse the smaller it is drawn, and a band is mostly border.
--
-- Trimmed by the same 7% the rest of the addon trims its icons by (Data.lua's
-- ApplyStatusCheckIcon, and every icon row under Views/), so these match the
-- icons in our own windows. That is the ~116% zoom rather than the 110% one:
-- the bevel really is about a fifteenth of the art per side, and 110% leaves a
-- sliver of it lit along the edge. ICON_TRIM is the knob -- 0.045 is 110%.
--
-- File icons only. A custom role wearing one of the client's micro role
-- ATLASES is already-trimmed art inside a shared sheet, and insetting that
-- eats the symbol rather than a border, so ask the texture what it actually
-- ended up holding rather than guessing from the role's icon id.
local ICON_TRIM = 0.07

local function TrimIconBorder(texture)
    if texture.GetAtlas and texture:GetAtlas() then return end
    local ulX, ulY, llX, llY, urX = texture:GetTexCoord()
    if not (ulX and urX) then return end
    local across, down = urX - ulX, llY - ulY
    texture:SetTexCoord(
        ulX + across * ICON_TRIM, urX - across * ICON_TRIM,
        ulY + down * ICON_TRIM, llY - down * ICON_TRIM)
end

-- Show only the middle slice of the icon, as wide as the strip is relative to
-- its height: the art is square, so drawing it at the band's height would make
-- it the band's height WIDE too, and everything past the strip has to be
-- masked off rather than squashed in. Cropping the coordinates the texture
-- already carries -- rather than computing a rect from scratch -- is what
-- keeps this working for a custom role wearing a micro role ATLAS, whose
-- coordinates address a sub-rect of a shared sheet and not a whole file.
--
-- Never called with a width past the height: a band is clamped square, so the
-- widest it ever gets is the whole icon at its own aspect, uncropped.
local function MaskToWidth(texture, width, height)
    if width >= height then return end
    local ulX, ulY, llX, llY, urX = texture:GetTexCoord()
    if not (ulX and urX) then return end
    local middle = (ulX + urX) / 2
    local half = (urX - ulX) * (width / height) / 2
    texture:SetTexCoord(middle - half, middle + half, ulY, llY)
end

-- Fade a band out towards the middle of the frame, or leave it flat. Colour
-- objects are cached rather than built per call: this runs per frame per
-- repaint, and fresh tables at that rate are exactly the litter the repaint
-- budget was cleaned up to avoid.
local colors = {}

local function Alpha(a)
    local color = colors[a]
    if not color then
        color = CreateColor(1, 1, 1, a)
        colors[a] = color
    end
    return color
end

local function SetFade(texture, style)
    if not (texture.SetGradient and CreateColor) then return end
    local from = style.fadeFrom
    if not from then
        -- Stated flat rather than skipped: this texture is ours and it is
        -- pooled, so it may be carrying the last style's gradient.
        texture:SetGradient("HORIZONTAL", Alpha(1), Alpha(1))
        return
    end
    -- The gradient runs outer-edge-inward, so which end holds the solid alpha
    -- depends on the side the strip is on.
    local outer, inner = Alpha(from), Alpha(style.fadeTo or 0)
    if style.side == "RIGHT" then outer, inner = inner, outer end
    texture:SetGradient("HORIZONTAL", outer, inner)
end

-- ---------------------------------------------------------------------------
-- Our regions
--
-- Two textures per frame, both created on demand and then reused and hidden
-- rather than made again -- these frames outlive any one raid. Kept in tables
-- of ours rather than stamped onto the client's frame.
-- ---------------------------------------------------------------------------

local icons = {} -- frame -> the texture we draw the spec icon into
local rings = {} -- frame -> the dark disc behind a circled corner icon
local outlines = {} -- frame -> the black disc behind a role-coloured ring
local edges = {} -- frame -> the hairline down a narrow band's inner side
local bandBacks = {} -- frame -> the black plate under an outlined band
local bandOutlines = {} -- frame -> the role-coloured plate just inside that
local taken = {} -- frame -> true while our stand-in is up
local shown = {} -- frame -> the icon we last drew there
local outlined = {} -- frame -> the outline role we last drew there, if any

local hosts = {} -- frame -> the overlay of ours everything is drawn into

-- Everything we draw lives on an overlay of our own, parented to UIParent and
-- ANCHORED to the compact frame rather than parented to it.
--
-- The distinction is the whole reason this file works on WoW Forever. A region
-- created on one of Blizzard's frames marks that frame as ours, and their own
-- update code then runs tainted -- which on that client may not so much as
-- compare the health it just read, so their frame errors on their own line,
-- every frame (Edit Mode makes it thousands). Anchoring only reads their frame;
-- nothing of ours is ever attached to it.
--
-- One overlay per compact frame, at most one per raid slot, reused as the
-- client reuses the frame beneath it.
local function Host(frame)
    local host = hosts[frame]
    if not host then
        host = CreateFrame("Frame", nil, UIParent)
        host:SetAllPoints(frame)
        hosts[frame] = host
    end
    -- Re-read each time: the client moves compact frames between strata and
    -- levels as groups are built, and an overlay left behind draws underneath.
    --
    -- Measured against the HEALTH BAR as well as the frame. The bar is a child
    -- with a level of its own, and on some clients it outranks its parent by
    -- more than a step -- which is how a band ends up behind the health fill it
    -- is supposed to run down, reading as washed out rather than drawn over.
    local level = frame:GetFrameLevel()
    local healthBar = frame.healthBar
    if healthBar and healthBar.GetFrameLevel then
        level = math.max(level, healthBar:GetFrameLevel())
    end
    host:SetFrameStrata(frame:GetFrameStrata())
    host:SetFrameLevel(level + 5)
    host:Show()
    return host
end

local BAND_EDGE_WIDTH = 1
local BAND_EDGE_COLOR = { 0.15, 0.15, 0.15, 1 }

-- The corner icon is masked round, and its border is not a ring texture but a
-- dark disc behind it, a pixel wider all round -- the part that sticks out IS
-- the ring. A drawn ring would need art at exactly our size to stay even; a
-- disc is one colour and stays a hairline at any size.
--
-- Both discs use the client's portrait alpha mask, the same one the round unit
-- portraits are cut with, so the two circles are concentric by construction.
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local RING_WIDTH = 1
local RING_COLOR = { 0.15, 0.15, 0.15, 1 }

-- The optional role outline turns the ring into two concentric hairlines: the
-- inner one takes the role's colour, and a black one a pixel wider sits a
-- sublevel under it, so the colour has something to contrast against whatever
-- the frame behind is. Styles marked `outline` only (the corner and the two
-- opaque bands; see SetBandEdge for theirs); the two settings split it so a
-- raid can outline tanks and healers without painting every DPS red.
local OUTLINE_WIDTH = 1
local OUTLINE_EDGE_COLOR = { 0, 0, 0, 1 }
local OUTLINE_COLORS = {
    tank = { 0.31, 0.55, 0.91, 1 },
    healer = { 0.31, 0.83, 0.35, 1 },
    dps = { 0.87, 0.27, 0.27, 1 },
}

-- Which outline this role gets under the current settings, or nil for the
-- plain dark ring.
local function OutlineFor(wowRole)
    if not (wowRole and OUTLINE_COLORS[wowRole]) then return nil end
    local settings = WhoDoesWhat.db.profile.settings
    if not settings.raidFrameRoleOutline then return nil end
    -- DPS is an extension of the role outline, not a switch of its own.
    if wowRole == "dps" and not settings.raidFrameRoleOutlineDps then
        return nil
    end
    return wowRole
end

-- Masks are per-texture, since each one is sized to the texture it cuts, and a
-- pooled texture switching to a band style has to put the square back.
local function SetCircleMask(texture, wanted)
    if not (texture.AddMaskTexture and texture.RemoveMaskTexture) then return end
    local mask = texture.wdwCircleMask
    if not wanted then
        if mask and texture.wdwMasked then
            texture:RemoveMaskTexture(mask)
            texture.wdwMasked = false
        end
        return
    end
    if not mask then
        local parent = texture:GetParent()
        if not parent.CreateMaskTexture then return end
        mask = parent:CreateMaskTexture()
        -- Clamped to black on both axes, or the mask tiles and the corners of
        -- the square come back.
        mask:SetTexture(CIRCLE_MASK,
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        texture.wdwCircleMask = mask
    end
    mask:ClearAllPoints()
    mask:SetAllPoints(texture)
    if not texture.wdwMasked then
        texture:AddMaskTexture(mask)
        texture.wdwMasked = true
    end
end

-- One masked disc of `width` past the icon on each side, created on demand.
local function Disc(pool, frame, icon, size, width, subLevel, color)
    local disc = pool[frame]
    if not disc then
        disc = Host(frame):CreateTexture(nil, "ARTWORK", nil, subLevel)
        disc:SetTexture("Interface\\Buttons\\WHITE8X8")
        pool[frame] = disc
    end
    disc:SetVertexColor(unpack(color))
    disc:ClearAllPoints()
    disc:SetPoint("CENTER", icon, "CENTER", 0, 0)
    disc:SetSize(size + width * 2, size + width * 2)
    SetCircleMask(disc, true)
    disc:Show()
end

local function SetCornerRing(frame, style, icon, size, outline)
    if not (style.circle and size) then
        if rings[frame] then rings[frame]:Hide() end
        if outlines[frame] then outlines[frame]:Hide() end
        return
    end
    -- Sublevels below the icon: same layer, so they track it, but behind.
    Disc(rings, frame, icon, size, RING_WIDTH, 0,
        outline and OUTLINE_COLORS[outline] or RING_COLOR)
    if outline then
        Disc(outlines, frame, icon, size, RING_WIDTH + OUTLINE_WIDTH, -1,
            OUTLINE_EDGE_COLOR)
    elseif outlines[frame] then
        outlines[frame]:Hide()
    end
end

-- ARTWORK one sublevel up: the same layer the client's own role icon and name
-- live in, drawn just above them, which is where its role icon already sat.
local function IconTexture(frame)
    local texture = icons[frame]
    if not texture then
        texture = Host(frame):CreateTexture(nil, "ARTWORK", nil, 1)
        icons[frame] = texture
    end
    return texture
end

-- A one-pixel line down a band's inner side, created on demand. OVERLAY, a
-- layer above the icon it edges: the same layer would leave which one wins to
-- draw order, and the point of a line is that nothing covers it.
local function BandLine(pool, frame, icon, point, relativePoint, color)
    local line = pool[frame]
    if not line then
        line = Host(frame):CreateTexture(nil, "OVERLAY")
        line:SetTexture("Interface\\Buttons\\WHITE8X8")
        pool[frame] = line
    end
    line:SetVertexColor(unpack(color))
    line:ClearAllPoints()
    line:SetPoint("TOP" .. point, icon, "TOP" .. relativePoint, 0, 0)
    line:SetPoint("BOTTOM" .. point, icon, "BOTTOM" .. relativePoint, 0, 0)
    line:SetWidth(BAND_EDGE_WIDTH)
    line:Show()
end

-- A flat rectangle `grow` pixels past the icon on every side, under it.
local function BandPlate(pool, frame, icon, grow, subLevel, color)
    local plate = pool[frame]
    if not plate then
        plate = Host(frame):CreateTexture(nil, "ARTWORK", nil, subLevel)
        plate:SetTexture("Interface\\Buttons\\WHITE8X8")
        pool[frame] = plate
    end
    plate:SetVertexColor(unpack(color))
    plate:ClearAllPoints()
    plate:SetPoint("TOPLEFT", icon, "TOPLEFT", -grow, grow)
    plate:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", grow, -grow)
    plate:Show()
end

-- The band's version of the dual ring: two plates under the icon, a black one
-- filling the band's whole footprint and the role colour a pixel inside it,
-- with the icon shrunk (in Draw) to show both. Every side is wrapped, so it
-- reads as a framed square rather than a stripe with a line beside it, and the
-- band takes no more room than a plain one. The plain band's own hairline
-- stands down for it -- the black plate is that edge now.
local function SetBandEdge(frame, style, outline)
    local band = style and style.width and style.edge
    if not (band and outline) then
        if bandBacks[frame] then bandBacks[frame]:Hide() end
        if bandOutlines[frame] then bandOutlines[frame]:Hide() end
    end
    if not band or outline then
        if edges[frame] then edges[frame]:Hide() end
    end
    if not band then return end
    local icon = icons[frame]
    if outline then
        BandPlate(bandBacks, frame, icon, OUTLINE_WIDTH * 2, -1,
            OUTLINE_EDGE_COLOR)
        BandPlate(bandOutlines, frame, icon, OUTLINE_WIDTH, 0,
            OUTLINE_COLORS[outline])
        return
    end
    -- Always the strip's inner side, the one facing the middle of the frame.
    local mine, theirs = "LEFT", "RIGHT"
    if style.side == "RIGHT" then mine, theirs = "RIGHT", "LEFT" end
    BandLine(edges, frame, icon, mine, theirs, BAND_EDGE_COLOR)
end

-- ---------------------------------------------------------------------------
-- The name
--
-- The one thing we still move on the client's side, and the only one it cannot
-- work out for itself: its icon is invisible but still occupies the corner, so
-- the name has no way of knowing the indent it is keeping is for nothing.
--
-- Captured before the first move and re-applied verbatim on release, and only
-- ever a re-anchor -- nothing here resizes anything, so the worst a mistake
-- can do is put a name in the wrong place, not lose one.
--
-- Anchors that name neither edge are left alone, which keeps the centred name
-- of the buffs-top layout centred rather than dragging it sideways.
-- ---------------------------------------------------------------------------

local namePoints = {} -- frame -> the client's own anchors for frame.name
local nameStyle = {}  -- frame -> the style key those anchors are laid out for
local nameJustify = {} -- frame -> the client's own horizontal justification

-- Is the name currently hung off the role icon? That is the client's own
-- doing and nothing else's -- we only ever anchor it to the frame -- which
-- makes it an exact answer to "has the client re-laid-this-out since we last
-- touched it", with no state of ours to go stale.
--
-- It re-lays it out more often than is obvious: building the frames for a
-- group that is still forming, and reflowing the container when a role change
-- re-sorts it. A cached "already done" misses both, which is why one player
-- changing role used to un-indent every name in the raid at once, and why a
-- freshly formed group left your own name behind.
local function NameHangsOffIcon(frame)
    local name = frame.name
    for i = 1, name:GetNumPoints() do
        local _, relativeTo = name:GetPoint(i)
        if relativeTo == frame.roleIcon then return true end
    end
    return false
end

local function ApplyNamePoints(frame, points, style)
    local name = frame.name
    name:ClearAllPoints()
    for _, p in ipairs(points) do
        local point, relativeTo, relativePoint, x, y = p[1], p[2], p[3], p[4], p[5]
        local inset = style and (
            (point:find("LEFT", 1, true) and style.nameLeft)
            or (point:find("RIGHT", 1, true) and style.nameRight))
        if inset then
            -- Re-anchored onto the frame, so the y has to be re-stated too:
            -- the captured one is measured from the ICON's top, and the icon
            -- already sits 2px below the frame's. Carrying it across unchanged
            -- is what floats the name high.
            relativeTo, relativePoint, x, y = frame, point, inset, NAME_TOP_Y
        end
        name:SetPoint(point, relativeTo, relativePoint, x, y)
    end
    local justify = style and style.nameCenter and "CENTER" or nameJustify[frame]
    if justify then name:SetJustifyH(justify) end
end

local function SetNameLayout(frame, key, style)
    local name = frame.name
    if not name then return end
    local wants = style and (style.nameLeft or style.nameRight)

    if not wants then
        -- Nothing to move. Put back anything we moved before, once, and then
        -- leave the client's own layout entirely alone.
        local points = namePoints[frame]
        if points and nameStyle[frame] ~= key then
            ApplyNamePoints(frame, points, nil)
        end
        nameStyle[frame] = key
        return
    end

    -- Whatever the client last laid out is the baseline we owe back, so a
    -- re-layout is re-captured rather than fought.
    local fresh = NameHangsOffIcon(frame)
    if fresh then
        if name:GetNumPoints() == 0 then return end
        -- Justification is captured once, not on every re-layout: the client
        -- re-anchors without re-justifying, so a later read could be our own
        -- CENTER coming back.
        if not nameJustify[frame] then nameJustify[frame] = name:GetJustifyH() end
        local points = {}
        for i = 1, name:GetNumPoints() do
            local point, relativeTo, relativePoint, x, y = name:GetPoint(i)
            points[i] = { point, relativeTo or frame, relativePoint, x, y }
        end
        namePoints[frame] = points
    end
    local points = namePoints[frame]
    if not points then return end
    if fresh or nameStyle[frame] ~= key then
        ApplyNamePoints(frame, points, style)
        nameStyle[frame] = key
    end
end

-- ---------------------------------------------------------------------------
-- What to draw, and for whom
-- ---------------------------------------------------------------------------

-- Both switches, asked together because every draw decision needs both. The
-- combat one is not a restriction we are working around -- a texture carries
-- no protected state, and the client repaints this same corner mid-fight
-- itself -- it is a preference about how busy the frames get during a pull.
local function Enabled()
    local db = WhoDoesWhat.db
    if not db then return false end
    local settings = db.profile.settings
    if settings.raidFrameRoleIcons == false then return false end
    if settings.raidFrameRoleIconsInCombat == false and InCombatLockdown() then
        return false
    end
    return true
end

-- Same "Name" / "Name-Realm" keying db.profile.assignments uses.
local function UnitKey(unit)
    local name, realm = UnitName(unit)
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

-- The role icon for a frame's unit, or nil when we have nothing to say about
-- them: no unit, not a player, no role, or a saved role id that no longer
-- resolves. Second return is the role's wow role ("tank"/"healer"/"dps"), for
-- the outline. Auto-assignment writes a scanned spec into the same store a hand
-- pick uses (TalentScanning.lua), so both arrive here as one lookup.
local function RoleIconFor(unit, style)
    if not (unit and UnitExists(unit) and UnitIsPlayer(unit)) then return nil end
    -- Never on a target or target-of-target frame. The raid container can show
    -- the main tanks' and assists' targets alongside the roster, and those are
    -- the same raiders a second time: a badge there is a duplicate of one
    -- already on the list, and the name shifting under it is worse. Any unit
    -- token with "target" in it is derived from somebody else's target, so one
    -- test covers maintank1target and targettarget alike.
    if unit:find("target", 1, true) then return nil end
    local key = UnitKey(unit)
    local roleId = key and WhoDoesWhat:GetAssignedRole(key)
    if roleId then
        local _, role = WhoDoesWhat:FindRoleById(roleId)
        if role and role.icon then return role.icon, role.wowRole end
    end
    -- Nothing on the board for them -- a raider without the addon, or one
    -- nobody has placed yet. A band marks them unknown; the corner style stands
    -- down entirely and lets the client's own role icon have the spot back.
    return style and style.unknown or nil
end

-- ---------------------------------------------------------------------------
-- Draw and release
-- ---------------------------------------------------------------------------

local function Draw(frame, icon, key, style, bandHeight, outline)
    local roleIcon = frame.roleIcon
    -- Before the textures, and on every draw rather than only the first: this
    -- shows an overlay a Release hid, and re-reads the strata and level of a
    -- compact frame the client may have rebuilt underneath us.
    Host(frame)
    local texture = IconTexture(frame)
    local cornerSize

    texture:ClearAllPoints()
    if style.width then
        -- Never wider than it is tall. A band past square would have to
        -- stretch the art sideways or crop it top and bottom, and both are
        -- worse than simply stopping at the whole icon.
        local width = math.min(style.width, bandHeight)
        local corner = style.side == "RIGHT" and "TOPRIGHT" or "TOPLEFT"
        -- An outline wraps the band from inside its own footprint: the icon
        -- steps in by both hairlines on every side, and SetBandEdge fills the
        -- gap it leaves.
        local inset = outline and OUTLINE_WIDTH * 2 or 0
        local height = bandHeight - inset * 2
        width = width - inset * 2
        texture:SetPoint(corner, frame.healthBar, corner,
            corner == "TOPRIGHT" and -inset or inset, -inset)
        texture:SetSize(width, height)
        WhoDoesWhat:SetRoleIconTexture(texture, icon)
        -- Trim first, mask second: the mask narrows whatever rect it finds, so
        -- the other way round would crop the band out of the bevel.
        TrimIconBorder(texture)
        MaskToWidth(texture, width, height)
    else
        -- Sit where the client put its own icon, at our scale. Read, never
        -- written: its geometry stays its own, which is what makes these
        -- numbers trustworthy every single pass rather than something we had
        -- to record before we spoilt it.
        --
        local point, relativeTo, relativePoint, x, y = roleIcon:GetPoint(1)
        local theirSize = roleIcon:GetHeight()
        local size = math.floor(theirSize * ICON_SCALE + 0.5)
        if not (point and size > 0) then
            texture:Hide()
            return
        end
        local ring = style.circle
            and (RING_WIDTH + (outline and OUTLINE_WIDTH or 0)) or 0
        texture:SetPoint(point, relativeTo or frame, relativePoint,
            CornerOffset(x, theirSize, size, ring),
            CornerOffset(y, theirSize, size, ring))
        texture:SetSize(size, size)
        WhoDoesWhat:SetRoleIconTexture(texture, icon)
        TrimIconBorder(texture)
        cornerSize = size
    end

    -- The round cut goes on last of the texture work: it is a mask, not a
    -- coordinate, so it survives the texture and trim above rather than being
    -- undone by them -- but it has to be taken off again for a band, since
    -- this texture is pooled across styles.
    SetCircleMask(texture, style.circle and true or false)
    SetCornerRing(frame, style, texture, cornerSize, outline)
    SetFade(texture, style)
    SetBandEdge(frame, style, outline)
    SetNameLayout(frame, key, style)
    texture:Show()
    -- The client's icon goes invisible, not away: it keeps its size, its
    -- anchor and the name hanging off it, and every one of those stays right
    -- without us touching it.
    roleIcon:SetAlpha(0)
    taken[frame] = true
    shown[frame] = icon
    outlined[frame] = outline
end

-- Give the corner straight back. Nothing here depends on the client redrawing
-- anything, which is the point: an alpha we set is an alpha we can unset, so
-- this lands the moment the setting changes rather than at the next reload.
local function Release(frame)
    if not taken[frame] then return end
    taken[frame] = nil
    shown[frame] = nil
    outlined[frame] = nil
    local texture = icons[frame]
    if texture then texture:Hide() end
    local ring = rings[frame]
    if ring then ring:Hide() end
    local outline = outlines[frame]
    if outline then outline:Hide() end
    SetBandEdge(frame, nil)
    SetNameLayout(frame, "corner", nil)
    if frame.roleIcon then frame.roleIcon:SetAlpha(1) end
    -- The overlay goes with it. Hidden rather than released: the client reuses
    -- these frames constantly, and so do we.
    local host = hosts[frame]
    if host then host:Hide() end
end

-- ---------------------------------------------------------------------------
-- Staying current
-- ---------------------------------------------------------------------------

local frames = {}  -- every compact frame our hook has run for
local styleOf = {} -- frame -> the style key we last drew there

-- The client re-runs its role-icon update on every event that can change this
-- corner -- roster changes, role flags, a frame being reused for a different
-- unit -- so hooking it is what keeps us current without a ticker. We no
-- longer need what it draws, only the news that something moved.
local function OnUpdateRoleIcon(frame)
    if not (frame and frame.roleIcon) then return end
    frames[frame] = true
    local key, style, bandHeight = StyleFor(frame)
    local icon, wowRole
    if Enabled() then icon, wowRole = RoleIconFor(frame.unit, style) end
    if icon then
        Draw(frame, icon, key, style, bandHeight,
            style.outline and OutlineFor(wowRole) or nil)
        styleOf[frame] = key
    else
        Release(frame)
        styleOf[frame] = nil
    end
end

-- ---------------------------------------------------------------------------
-- Board-driven repaints
--
-- Nothing on the client's side moves when OUR board does, so a role edit, an
-- arriving talent scan, a sync or a settings change has to push. Leading edge,
-- like RequestFullRefresh: the first push after a quiet spell lands
-- immediately and everything inside the interval collapses into one catch-up
-- -- this hangs off RefreshBoardViews, which live buff tracking fires at up to
-- 10Hz. Frames whose icon and style are unchanged cost two table lookups.
-- ---------------------------------------------------------------------------

local REFRESH_INTERVAL = 0.2
local pending, lastRefresh = false, 0

local function Sweep()
    lastRefresh = GetTime()
    local enabled = Enabled()
    for frame in pairs(frames) do
        if frame.roleIcon and frame.unit and frame:IsVisible() then
            local key, style, bandHeight = StyleFor(frame)
            local icon, wowRole
            if enabled then icon, wowRole = RoleIconFor(frame.unit, style) end
            local outline = icon and style.outline and OutlineFor(wowRole) or nil
            -- The style counts as a change too. Comparing the icon alone meant
            -- switching style repainted nothing at all: the same player still
            -- resolves to the same icon, so every frame looked untouched. The
            -- outline likewise, for a toggled outline setting or a role swap
            -- that keeps the same icon.
            if icon ~= shown[frame] or (icon and key or nil) ~= styleOf[frame]
                or outline ~= outlined[frame] then
                if icon then
                    Draw(frame, icon, key, style, bandHeight, outline)
                    styleOf[frame] = key
                else
                    Release(frame)
                    styleOf[frame] = nil
                end
            end
        end
    end
end

function WhoDoesWhat:RefreshRaidFrameRoleIcons()
    if pending or not next(frames) then return end
    local elapsed = GetTime() - lastRefresh
    if elapsed >= REFRESH_INTERVAL then
        Sweep()
        return
    end
    pending = true
    C_Timer.After(REFRESH_INTERVAL - elapsed, function()
        pending = false
        Sweep()
    end)
end

-- The two edges of a fight are just another reason to sweep, for the raiders
-- whose corner the combat setting hands back and forth. Registered even when
-- the hook below never installs: the sweep has nothing to walk then and costs
-- a table lookup.
-- An overlay parented to UIParent does not hide when the frame it sits on does,
-- and the client hides these constantly -- a raid shrinking, a group emptying,
-- the profile switching between party and raid frames. Nothing tells us, so the
-- overlays are matched to their frames on a slow tick.
--
-- Cheap by construction: it returns on the first line until something is drawn,
-- and then costs one IsVisible per raid slot twice a second. The alternative --
-- hooking each frame's Hide -- would write to their frame table, which is the
-- taint this whole overlay exists to avoid.
C_Timer.NewTicker(0.5, function()
    if not next(hosts) then return end
    for frame, host in pairs(hosts) do
        local wanted = taken[frame] and frame:IsVisible() and true or false
        if host:IsShown() ~= wanted then host:SetShown(wanted) end
    end
end)

local combatWatcher = CreateFrame("Frame")
combatWatcher:RegisterEvent("PLAYER_REGEN_DISABLED")
combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
combatWatcher:SetScript("OnEvent", function()
    WhoDoesWhat:RefreshRaidFrameRoleIcons()
end)

-- The compact frames live in the Blizzard_UnitFrame addon rather than in
-- FrameXML, so the function is normally already there when we load but isn't
-- guaranteed to be -- hence the second look at login. A client that never
-- provides it has no such corner to draw in, and the refresh above then has
-- nothing registered and stays a no-op.
local function InstallHook()
    if type(CompactUnitFrame_UpdateRoleIcon) ~= "function" then return false end
    hooksecurefunc("CompactUnitFrame_UpdateRoleIcon", OnUpdateRoleIcon)
    return true
end

if not InstallHook() then
    local waiter = CreateFrame("Frame")
    waiter:RegisterEvent("PLAYER_LOGIN")
    waiter:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        if not InstallHook() then
            WhoDoesWhat:LogUiBuilding("Raid frame role icons: this client has "
                .. "no CompactUnitFrame_UpdateRoleIcon; nothing to draw on.")
        end
    end)
end
