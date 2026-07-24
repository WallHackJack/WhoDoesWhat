local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Client-flavor differences live here so shared data and views stay free of
-- scattered version checks. Classic Era is the 1.x client family.
local isClassicEra = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC

WhoDoesWhat.ClientFeatures = {
    misdirectAssignments = not isClassicEra,

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
