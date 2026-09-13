local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Client-flavor differences live here so shared data and views stay free of
-- scattered version checks. Classic Era is the 1.x client family.
--
-- World of Warcraft: Forever starts from the Classic Era baseline, so it counts
-- as Era for everything below unless a Forever-specific flag says otherwise.
-- Its project id is unconfirmed until the beta client can be checked; this is
-- the one line to correct then.
local isForever = WOW_PROJECT_FOREVER ~= nil and WOW_PROJECT_ID == WOW_PROJECT_FOREVER
local isClassicEra = isForever or WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
-- Forever removed every talent that grants or improves a raid buff: Kings is
-- baseline for every paladin, Sanctuary is gone, and nothing improves Might,
-- Wisdom, Fortitude, Mark of the Wild or Thorns.
local buffTalents = not isForever

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
    -- False where no talent affects a raid buff: nothing about buff talents is
    -- scanned, shared, weighed or shown on that client.
    buffTalents = buffTalents,
    misdirectAssignments = not isClassicEra,
    paladinBuffTalents = not buffTalents and {}
        or isClassicEra and PALADIN_BUFF_TALENTS_CLASSIC
        or PALADIN_BUFF_TALENTS_TBC,
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
