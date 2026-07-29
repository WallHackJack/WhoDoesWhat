local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Client-flavor differences live here so shared data and views stay free of
-- scattered version checks. Classic Era is the 1.x client family.
local isClassicEra = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC

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
    misdirectAssignments = not isClassicEra,
    paladinBuffTalents = isClassicEra
        and PALADIN_BUFF_TALENTS_CLASSIC
        or PALADIN_BUFF_TALENTS_TBC,
    warlockHealthstone = isClassicEra and {
        name = "Major Healthstone",
        lifeByTalentRank = { [0] = 1200, [1] = 1320, [2] = 1440 },
    } or {
        name = "Master Healthstone",
        lifeByTalentRank = { [0] = 2080, [1] = 2288, [2] = 2496 },
    },
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
