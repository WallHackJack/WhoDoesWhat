local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Client-flavor differences live here so shared data and views stay free of
-- scattered version checks. Classic Era is the 1.x client family.
--
-- World of Warcraft: Forever starts from the Classic Era baseline, so it counts
-- as Era for everything below unless a Forever-specific flag says otherwise.
--
-- It has no project id of its own: the 1.60.1 beta reports WOW_PROJECT_MAINLINE
-- and there is no WOW_PROJECT_FOREVER, so it is told apart by interface
-- version. Forever numbers from 16001 (1.60.1) while retail is past 120000, so
-- anything mainline below 20000 is Forever.
local interfaceVersion = select(4, GetBuildInfo())
local isForever = WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
    and interfaceVersion >= 16000 and interfaceVersion < 20000
local isClassicEra = isForever or WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
-- Forever removed every talent that grants or improves a raid buff: Kings is
-- baseline for every paladin, Sanctuary is gone, and nothing improves Might,
-- Wisdom, Fortitude, Mark of the Wild or Thorns.
local buffTalents = not isForever

-- Whether aura reads are hidden from addons right now. Under the Midnight
-- restrictions (Retail, and WoW Forever) they return secret values or nil, and
-- the server decides when -- combat, instances, encounters -- so this asks the
-- client each time instead of guessing from combat state. Always false on a
-- client without C_Secrets.
local ShouldAurasBeSecret = C_Secrets and C_Secrets.ShouldAurasBeSecret
function WhoDoesWhat:AurasSecret()
    return ShouldAurasBeSecret ~= nil and ShouldAurasBeSecret() == true
end

-- Cooldowns have their own switch, and it is the one the item-cooldown reads
-- care about.
local ShouldCooldownsBeSecret = C_Secrets and C_Secrets.ShouldCooldownsBeSecret
function WhoDoesWhat:CooldownsSecret()
    return ShouldCooldownsBeSecret ~= nil and ShouldCooldownsBeSecret() == true
end

-- Is the client hiding combat data right now? For paths that read something
-- without a switch of its own -- range, which the bars grey and glow from --
-- and so have to go on whether we are in the restricted state at all.
--
-- NOT C_Secrets.HasSecretRestrictions(): that answers "is this a client that
-- can restrict", which on Forever is true in an empty field out of combat. It
-- would have greyed every range check on the bars permanently. The honest
-- signal is the switches that actually flip.
function WhoDoesWhat:CombatDataSecret()
    return self:AurasSecret() or self:CooldownsSecret()
end

-- Can this client compile secure snippets at all?
--
-- The 1.60.1 Forever beta ships a Blizzard_RestrictedAddOnEnvironment whose
-- RestrictedExecution calls `loadstring_untainted`, which does not exist in
-- that build: every Execute, WrapScript and _onenter body -- in any addon --
-- errors before a line of it runs. Where that is the case the views wire up
-- plain handlers instead, which cost the in-combat behaviour the snippets were
-- there for and nothing else.
--
-- Asked once, and by looking for the missing piece rather than by version:
-- this is a bug to be fixed, not a property of the client, and the day the
-- build is fixed this passes and the secure paths come back untouched.
--
-- `loadstring_untainted` is exactly what RestrictedExecution reaches for and
-- does not find, so its absence IS the broken state. Tested rather than
-- running a snippet because a failed snippet prints its error from inside
-- Blizzard's secure path, where our pcall catches the failure but cannot stop
-- the client reporting it -- a probe that works would announce itself as a bug
-- every session.
local snippetsWork

function WhoDoesWhat:SecureSnippetsWork()
    if snippetsWork == nil then
        -- Scoped to Forever on purpose: a client that has never had this
        -- global and compiles snippets perfectly well (any Classic build)
        -- must not be dragged onto the fallback path by its absence.
        snippetsWork = not isForever or loadstring_untainted ~= nil
    end
    return snippetsWork
end

-- Is this particular value one the client will not let us look at? The switches
-- above say what is hidden in general; this asks about the value in hand, which
-- is the only reliable question for an API whose secrecy follows no switch we
-- can see. UnitInRange on Forever is the case in point: it hands back secret
-- booleans in an empty field, out of combat, with nothing forced -- and merely
-- testing one for truth is the error.
local issecretvalue = issecretvalue
function WhoDoesWhat:IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end

-- Has this paladin trained a blessing yet? `greater` asks about the Greater
-- version instead of the single-target one.
--
-- Inferred from their level rather than shared over the addon channel: the
-- level is on the roster for everyone in the group, and a paladin running no
-- addon at all is exactly the case this has to get right.
--
-- Anything unknown answers true -- no level data for this client, a paladin we
-- hold no unit for (someone out of the group, a fake raider), or a level the
-- client will not let us read. An unknown is not a "cannot", and refusing to
-- plan a blessing on a guess would be worse than planning one that fizzles.
-- Memoised: the plan asks this for every paladin against every blessing, and
-- UnitForPlayer walks the roster to answer. Levels only move on a ding or a
-- roster change, which is what clears it.
local levelCache = {}

function WhoDoesWhat:PaladinLevel(name)
    local cached = levelCache[name]
    if cached ~= nil then return cached or nil end
    local unit = name and self:UnitForPlayer(name)
    local level = unit and UnitLevel(unit)
    if self:IsSecret(level) or not level or level <= 0 then level = nil end
    levelCache[name] = level or false
    return level
end

local levelWatcher = CreateFrame("Frame")
levelWatcher:RegisterEvent("GROUP_ROSTER_UPDATE")
levelWatcher:RegisterEvent("UNIT_LEVEL")
levelWatcher:RegisterEvent("PLAYER_LEVEL_UP")
levelWatcher:SetScript("OnEvent", function()
    if next(levelCache) then levelCache = {} end
end)

function WhoDoesWhat:PaladinKnowsBuff(name, key, greater)
    local levels = self.ClientFeatures.paladinBuffLevels
    local needed = levels and levels[key]
        and (greater and levels[key].greater or levels[key].normal)
    if not needed then return true end
    local level = self:PaladinLevel(name)
    if not level then return true end
    return level >= needed
end

-- Should tooltips carry the spell and item ids (ItemTooltipExtensions.lua)?
-- On by default on Forever, where its data tables are still being filled in and
-- every unfamiliar consumable needs both ids looked up; off everywhere else,
-- where they are just noise on a tooltip. The setting is tri-state on purpose:
-- unset means "whatever suits this client", and the checkbox writes an explicit
-- true or false that then holds on either.
function WhoDoesWhat:ShowTooltipIds()
    local setting = self.db and self.db.profile.settings.tooltipIds
    if setting == nil then return isForever end
    return setting == true
end

local PALADIN_BUFF_TALENTS_TBC = {
    { key = "might",     tab = 3, tier = 1, column = 2 },
    { key = "wisdom",    tab = 1, tier = 4, column = 3 },
    { key = "kings",     tab = 2, tier = 3, column = 1 },
    { key = "sanctuary", tab = 2, tier = 5, column = 2 },
}

local PALADIN_BUFF_TALENTS_CLASSIC = {
    { key = "wisdom",    tab = 1, tier = 4, column = 3 },
    { key = "kings",     tab = 2, tier = 3, column = 1 },
    { key = "sanctuary", tab = 2, tier = 5, column = 2 },
    { key = "might",     tab = 3, tier = 1, column = 2 },
}

WhoDoesWhat.ClientFeatures = {
    isClassicEra = isClassicEra,
    isForever = isForever,
    -- Forever brings over Retail's in-combat addon restrictions: combat data
    -- reads come back hidden mid-fight, so views built on it step aside rather
    -- than show a pre-pull snapshot as if it were live.
    combatRestrictions = isForever,
    -- Characters have a first and a last name, which UnitName hands back in
    -- the realm slot: a player key reads "First-Last" rather than
    -- "Name-Realm" (Core.lua's ShortName).
    twoPartNames = isForever,
    -- False where no talent affects a raid buff: nothing about buff talents is
    -- scanned, shared, weighed or shown on that client.
    buffTalents = buffTalents,
    misdirectAssignments = not isClassicEra,
    paladinBuffTalents = not buffTalents and {}
        or isClassicEra and PALADIN_BUFF_TALENTS_CLASSIC
        or PALADIN_BUFF_TALENTS_TBC,
    -- The level each blessing is trained at, by Data.lua's blessing key, so a
    -- paladin is never handed one they cannot cast yet. `greater` is the
    -- Greater (raid-wide) version. A missing entry means "no idea", which gates
    -- nothing -- the same rule the buff tracking uses for unknowns.
    --
    -- Forever only for now. Classic and TBC want the same treatment and their
    -- numbers are not in here yet; until they are, those clients gate on
    -- talents alone, exactly as they did before.
    paladinBuffLevels = isForever and {
        might = { normal = 4, greater = 52 },
        wisdom = { normal = 14, greater = 54 },
        kings = { normal = 20, greater = 60 },
        salv = { normal = 26 },
        light = { normal = 40, greater = 60 },
    } or nil,
    -- Paladin blessing keys from Data.lua that this client does not have.
    removedPaladinBuffs = isForever and {
        sanctuary = true,
    } or {},
    -- nil on Forever: Improved Healthstone is gone, so there are no ranks to
    -- scan, share or show.
    warlockHealthstone = not isForever and (isClassicEra and {
        name = "Major Healthstone",
        lifeByTalentRank = { [0] = 1200, [1] = 1320, [2] = 1440 },
        -- Each Improved Healthstone rank conjures a distinct item.
        talentRankByItemId = { [9421] = 0, [19012] = 1, [19013] = 2 },
    } or {
        name = "Master Healthstone",
        lifeByTalentRank = { [0] = 2080, [1] = 2288, [2] = 2496 },
        talentRankByItemId = { [22103] = 0, [22104] = 1, [22105] = 2 },
    }) or nil,
    warlockCurseSpellIds = isClassicEra and {
        reck = 11717,     -- Curse of Recklessness (Rank 4)
        elements = 11722, -- Curse of the Elements (Rank 3)
        shadow = 17937,   -- Curse of Shadow (Rank 2)
    } or {
        reck = 27226,     -- Curse of Recklessness (Rank 5)
        elements = 27228, -- Curse of the Elements (Rank 4)
    },

    -- Highest Greater Blessing ranks available in Classic Era.
    paladinBuffSpellIds = isClassicEra and {
        might = 25916,
        light = 25890,
        wisdom = 25918,
        sanctuary = 25899,
    } or {},
    -- Highest single-target Blessing ranks available in Classic Era.
    paladinNormalBuffSpellIds = isClassicEra and {
        might = 25291,
        light = 19979,
        wisdom = 25290,
        sanctuary = 20914,
    } or {},

    -- Stable CC keys from Data.lua that this client does not have.
    excludedCCSpells = isClassicEra and {
        cyclone = true,
    } or {},

    -- Use the highest rank known to this client for icons and tooltips.
    ccSpellIds = isClassicEra and {
        roots = 9853,   -- Entangling Roots (Rank 6)
        wyvern = 24133, -- Wyvern Sting (Rank 3)
    } or {},
}
