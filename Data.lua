local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local features = WhoDoesWhat.ClientFeatures

WhoDoesWhat.DisconnectedGridRowColors = {
    { r = 0.48, g = 0.48, b = 0.48, a = 0.16 },
    { r = 0.30, g = 0.30, b = 0.30, a = 0.14 },
}

-- Define the structured TBC classes, their roles, and colors
-- Add this directly to your Roles.lua or where WhoDoesWhat.Classes is declared
WhoDoesWhat.Classes = {
    {
        name = "Warrior",
        classIcon = 135328, -- FileDataID for class_warrior
        colorHex = "C69B6D",
        colorRGB = { r = 0.78, g = 0.61, b = 0.43 },
        gridRowColors = {
            { r = 0.78, g = 0.61, b = 0.43, a = 0.12 },
            { r = 0.78, g = 0.61, b = 0.43, a = 0.06 },
        },
        roles = {
            { name = "Fury", icon = 132347, id = "warrior_fury", wowRole = "dps" },
            { name = "Arms", icon = 132333, id = "warrior_arms", wowRole = "dps" },
            { name = "Tank", icon = 132341, id = "warrior_prot", wowRole = "tank" }
        },
        categories = {
            { name = "DPS",  icon = 135328, id = "cat_warrior_dps",  allSubRoles = { "warrior_fury", "warrior_arms" } }, -- class icon
            { name = "Tank", icon = 132341, id = "cat_warrior_tank", allSubRoles = { "warrior_prot" } }
        }
    },
    {
        name = "Paladin",
        classIcon = 626003, -- FileDataID for ClassIcon_Paladin
        colorHex = "F48CBA",
        colorRGB = { r = 0.96, g = 0.55, b = 0.73 },
        gridRowColors = {
            { r = 0.96, g = 0.55, b = 0.73, a = 0.12 },
            { r = 0.96, g = 0.55, b = 0.73, a = 0.06 },
        },
        roles = {
            { name = "Tank", icon = 135893, id = "paladin_prot", wowRole = "tank" },
            { name = "Holy", icon = 135907, id = "paladin_holy", wowRole = "healer" },
            { name = "Retribution", icon = 135873, id = "paladin_ret", wowRole = "dps" }
        }
    },
    {
        name = "Hunter",
        classIcon = 626000, -- FileDataID for ClassIcon_Hunter
        colorHex = "AAD372",
        colorRGB = { r = 0.67, g = 0.83, b = 0.45 },
        gridRowColors = {
            { r = 0.67, g = 0.83, b = 0.45, a = 0.12 },
            { r = 0.67, g = 0.83, b = 0.45, a = 0.06 },
        },
        roles = {
            { name = "Beast Mastery", icon = 132164, id = "hunter_bm", wowRole = "dps" },
            { name = "Survival", icon = 132215, id = "hunter_surv", wowRole = "dps" },
            { name = "Marksmanship", icon = 132243, id = "hunter_mm", wowRole = "dps" }
        },
        categories = {
            { name = "DPS",  icon = 626000, id = "cat_hunter_dps",  allSubRoles = { "hunter_bm", "hunter_surv", "hunter_mm" } } -- class icon
        }
    },
    {
        name = "Rogue",
        classIcon = 626005, -- FileDataID for ClassIcon_Rogue
        colorHex = "FFF468",
        colorRGB = { r = 1.00, g = 0.96, b = 0.41 },
        gridRowColors = {
            { r = 1.00, g = 0.96, b = 0.41, a = 0.12 },
            { r = 1.00, g = 0.96, b = 0.41, a = 0.06 },
        },
        roles = {
            { name = "Combat", icon = 132306, id = "rogue_combat", wowRole = "dps" },          -- Ability_Rogue_SliceDice
            { name = "Assassination", icon = 132292, id = "rogue_assassin", wowRole = "dps" }, -- Ability_Rogue_Eviscerate
            { name = "Subtlety", icon = 132320, id = "rogue_sub", wowRole = "dps" }            -- Ability_Stealth
        },
        categories = {
            { name = "DPS", icon = 626005, id = "cat_rogue_dps", allSubRoles = { "rogue_combat", "rogue_assassin", "rogue_sub" } } -- class icon
        }
    },
    {
        name = "Priest",
        classIcon = 626004, -- FileDataID for ClassIcon_Priest
        colorHex = "FFFFFF",
        colorRGB = { r = 1.00, g = 1.00, b = 1.00 },
        gridRowColors = {
            { r = 1.00, g = 1.00, b = 1.00, a = 0.12 },
            { r = 1.00, g = 1.00, b = 1.00, a = 0.06 },
        },
        roles = {
            { name = "Discipline", icon = 135987, id = "priest_disc", wowRole = "healer" }, -- Spell_Holy_WordFortitude
            { name = "Holy", icon = 135920, id = "priest_holy", wowRole = "healer" },       -- Spell_Holy_HolyBolt
            { name = "Shadow", icon = 136207, id = "priest_shadow", wowRole = "dps" }    -- Spell_Shadow_ShadowWordPain
        }
    },
    {
        name = "Shaman",
        classIcon = 626006, -- FileDataID for ClassIcon_Shaman
        colorHex = "0070DD",
        colorRGB = { r = 0.00, g = 0.44, b = 0.87 },
        gridRowColors = {
            { r = 0.00, g = 0.44, b = 0.87, a = 0.12 },
            { r = 0.00, g = 0.44, b = 0.87, a = 0.06 },
        },
        roles = {
            { name = "Elemental", icon = 136048, id = "shaman_ele", wowRole = "dps" },    -- Spell_Nature_Lightning
            { name = "Enhancement", icon = 136051, id = "shaman_enh", wowRole = "dps" },  -- Spell_Nature_LightningShield
            { name = "Restoration", icon = 136043, id = "shaman_resto", wowRole = "healer" } -- Spell_Nature_HealingWaveGreater
        }
    },
    {
        name = "Mage",
        classIcon = 626001, -- FileDataID for ClassIcon_Mage
        colorHex = "3FC7EB",
        colorRGB = { r = 0.25, g = 0.78, b = 0.92 },
        gridRowColors = {
            { r = 0.25, g = 0.78, b = 0.92, a = 0.12 },
            { r = 0.25, g = 0.78, b = 0.92, a = 0.06 },
        },
        roles = {
            { name = "Arcane", icon = 135932, id = "mage_arcane", wowRole = "dps" }, -- Spell_Holy_MagicalSentry
            { name = "Fire", icon = 135810, id = "mage_fire", wowRole = "dps" },     -- Spell_Fire_FireBolt02
            { name = "Frost", icon = 135846, id = "mage_frost", wowRole = "dps" }    -- Spell_Frost_FrostBolt02
        },
        categories = {
            { name = "DPS", icon = 626001, id = "cat_mage_dps", allSubRoles = { "mage_arcane", "mage_fire", "mage_frost" } } -- class icon
        }
    },
    {
        name = "Warlock",
        classIcon = 626007, -- FileDataID for ClassIcon_Warlock
        colorHex = "8788EE",
        colorRGB = { r = 0.53, g = 0.53, b = 0.93 },
        gridRowColors = {
            { r = 0.53, g = 0.53, b = 0.93, a = 0.12 },
            { r = 0.53, g = 0.53, b = 0.93, a = 0.06 },
        },
        roles = {
            { name = "Affliction", icon = 136145, id = "warlock_affl", wowRole = "dps" },   -- Spell_Shadow_DeathCoil
            { name = "Demonology", icon = 136172, id = "warlock_demo", wowRole = "dps" },    -- Spell_Shadow_Metamorphosis
            { name = "Destruction", icon = 136186, id = "warlock_destro", wowRole = "dps" }, -- Spell_Shadow_RainOfFire
            { name = "Warlock Tank", icon = 135817, id = "warlock_firetank", wowRole = "tank" } -- Spell_Fire_Immolation
        },
        categories = {
            { name = "DPS",  icon = 626007, id = "cat_warlock_dps",  allSubRoles = { "warlock_affl", "warlock_demo", "warlock_destro" } }, -- class icon
            { name = "Tank", icon = 135817, id = "cat_warlock_tank", allSubRoles = { "warlock_firetank" } }
        }
    },
    {
        name = "Druid",
        classIcon = 625999, -- FileDataID for ClassIcon_Druid
        colorHex = "FF7C0A",
        colorRGB = { r = 1.00, g = 0.49, b = 0.04 },
        gridRowColors = {
            { r = 1.00, g = 0.49, b = 0.04, a = 0.12 },
            { r = 1.00, g = 0.49, b = 0.04, a = 0.06 },
        },
        roles = {
            { name = "Feral DPS", icon = 132115, id = "druid_feral_dps", wowRole = "dps" },  -- Ability_Druid_CatForm
            { name = "Feral Tank", icon = 132276, id = "druid_feral_tank", wowRole = "tank" }, -- Ability_Racial_BearForm
            { name = "Balance", icon = 136096, id = "druid_balance", wowRole = "dps" },       -- Spell_Nature_StarFall
            { name = "Restoration", icon = 136041, id = "druid_resto", wowRole = "healer" },     -- Spell_Nature_HealingTouch
            { name = "Dreamstate", icon = 132123, id = "druid_dreamstate", wowRole = "healer" }  -- Ability_Druid_Dreamstate
        }
    }
}

-- Additional tank roles live in the normal class metadata so every role
-- picker and lookup sees the same definitions. Only the three raid-encounter
-- roles are TBC-specific; the paladin tank split is shared.
for _, classInfo in ipairs(WhoDoesWhat.Classes) do
    if classInfo.name == "Paladin" then
        classInfo.roles[1].name = "Main Tank"
        table.insert(classInfo.roles, 2,
            { name = "Trash Tank", icon = 135893, id = "paladin_prot_trash", wowRole = "tank" })
    elseif not features.isClassicEra then
        if classInfo.name == "Hunter" then
            table.insert(classInfo.roles,
                { name = "Hunter Tank", icon = 132164, id = "hunter_tank", wowRole = "tank" })
        elseif classInfo.name == "Mage" then
            table.insert(classInfo.roles,
                { name = "Mage Tank", icon = 135846, id = "mage_tank", wowRole = "tank" })
        elseif classInfo.name == "Druid" then
            table.insert(classInfo.roles, 4,
                { name = "Boomkin Tank", icon = 136096, id = "druid_balance_tank", wowRole = "tank" })
        end
    end
end

-- Paladin Raid Buffs Metadata. spellId defaults to the TBC max-rank Greater
-- Blessing and is overridden below for clients with different ranks.
WhoDoesWhat.PaladinBuffs = {
    salv = {
        icon = "Interface\\Icons\\Spell_Holy_GreaterBlessingofSalvation",
        iconId = 135910,
        name_short = "Salv",
        name_long = "Salvation",
        spellId = 25895, -- Greater Blessing of Salvation
        normalSpellId = 1038 -- Blessing of Salvation
    },
    kings = {
        icon = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings",
        iconId = 135993,
        name_short = "Kings",
        name_long = "Kings",
        spellId = 25898, -- Greater Blessing of Kings
        normalSpellId = 20217 -- Blessing of Kings
    },
    might = {
        icon = 135908, -- Spell_Holy_GreaterBlessingofKings (Greater Might in this client)
        iconId = 135908,
        name_short = "Might",
        name_long = "Might",
        spellId = 27141, -- Greater Blessing of Might (Rank 3)
        normalSpellId = 27140 -- Blessing of Might (Rank 7)
    },
    light = {
        icon = "Interface\\Icons\\Spell_Holy_PrayerOfHealing02",
        iconId = 135943,
        name_short = "Light",
        name_long = "Light",
        spellId = 27145, -- Greater Blessing of Light (Rank 2)
        normalSpellId = 27144 -- Blessing of Light (Rank 4)
    },
    wisdom = {
        icon = 135912, -- Spell_Holy_GreaterBlessingofWisdom
        iconId = 135912,
        name_short = "Wisdom",
        name_long = "Wisdom",
        spellId = 27143, -- Greater Blessing of Wisdom (Rank 3)
        normalSpellId = 27142 -- Blessing of Wisdom (Rank 6)
    },
    sanctuary = {
        icon = "Interface\\Icons\\Spell_Nature_LightningShield",
        iconId = 136051,
        name_short = "Sanc",
        name_long = "Sanctuary",
        spellId = 27169, -- Greater Blessing of Sanctuary (Rank 2)
        normalSpellId = 27168 -- Blessing of Sanctuary (Rank 5)
    }
}

for key, spellId in pairs(features.paladinBuffSpellIds) do
    WhoDoesWhat.PaladinBuffs[key].spellId = spellId
end
for key, spellId in pairs(features.paladinNormalBuffSpellIds) do
    WhoDoesWhat.PaladinBuffs[key].normalSpellId = spellId
end
for _, buff in pairs(WhoDoesWhat.PaladinBuffs) do
    buff.normalIcon = GetSpellTexture(buff.normalSpellId) or buff.icon
end

-- The paladin's two self-buffs the Buffing Bar can drive: the aura they're
-- running and, while tanking, Righteous Fury. Display order is the order the
-- aura swapper's picker lays them out in, within each row.
--
-- Ids are the BASE rank of each spell, on purpose. Casts go out as rank-less
-- names so the client picks the highest rank known, and a base rank is the one
-- id that never changes between Classic Era and TBC; only the localized name
-- and icon are read off it. Concentration (Holy) and Sanctity (Retribution)
-- are talent-granted and Crusader Aura is TBC-only at level 62, so the view
-- filters this list down to what the paladin actually knows.
WhoDoesWhat.PaladinAuras = {
    { key = "devotion",      spellId = 465,   name_short = "Devo" },
    { key = "retribution",   spellId = 7294,  name_short = "Ret" },
    { key = "concentration", spellId = 19746, name_short = "Conc" },
    -- `resist` splits the situational school auras onto their own row in the
    -- buffing bar's aura picker.
    { key = "fireResist",    spellId = 19891, name_short = "Fire",   resist = true },
    { key = "frostResist",   spellId = 19888, name_short = "Frost",  resist = true },
    { key = "shadowResist",  spellId = 19876, name_short = "Shadow", resist = true },
    { key = "sanctity",      spellId = 20218, name_short = "Sanctity" },
}
if not features.isClassicEra then
    -- Crusader Aura arrived with TBC (level 62, mounted speed).
    table.insert(WhoDoesWhat.PaladinAuras,
        { key = "crusader", spellId = 32223, name_short = "Crusader" })
end
-- Resolve names and icons off the ids, dropping anything this client's spell
-- database doesn't know rather than carrying a nameless entry into the bar.
local knownAuras = {}
for _, aura in ipairs(WhoDoesWhat.PaladinAuras) do
    aura.name = GetSpellInfo(aura.spellId)
    aura.icon = GetSpellTexture(aura.spellId)
    if aura.name then knownAuras[#knownAuras + 1] = aura end
end
WhoDoesWhat.PaladinAuras = knownAuras

-- Righteous Fury: a 30 minute self-buff (not a toggle on these clients), so it
-- can quietly lapse mid-raid on a tanking paladin.
WhoDoesWhat.RighteousFury = {
    spellId = 25780,
    name = GetSpellInfo(25780) or "Righteous Fury",
    icon = GetSpellTexture(25780),
}

-- Raid-wide status bars beyond paladin blessings. Aura names are deliberately
-- rank-independent and include both the single-target and group versions.
-- Core coverage is players-only unless a check explicitly includes hunter
-- pets. Target filters are defaults that each check's cog options may change.
WhoDoesWhat.CoreRaidBuffOrder = {
    "gift", "fortitude", "intellect", "shadowProtection", "food",
}
WhoDoesWhat.ManaExcludedClasses = { Warrior = true, Rogue = true }
-- Legacy palette values remain readable so existing profiles migrate cleanly;
-- new color-picker choices are stored directly as RGB.
WhoDoesWhat.StatusBarBackgrounds = {
    default = { name = "Default" },
    red = { name = "Red", colorRGB = { r = 0.85, g = 0.15, b = 0.15 } },
    orange = { name = "Orange", colorRGB = { r = 0.95, g = 0.45, b = 0.10 } },
    yellow = { name = "Yellow", colorRGB = { r = 0.95, g = 0.80, b = 0.10 } },
    green = { name = "Green", colorRGB = { r = 0.15, g = 0.80, b = 0.25 } },
    blue = { name = "Blue", colorRGB = { r = 0.20, g = 0.50, b = 0.95 } },
    purple = { name = "Purple", colorRGB = { r = 0.65, g = 0.30, b = 0.90 } },
    gray = { name = "Gray", colorRGB = { r = 0.55, g = 0.55, b = 0.60 } },
}
WhoDoesWhat.CoreRaidBuffs = {
    fortitude = {
        name = "Fortitude",
        description = "Increases Stamina and maximum health.",
        icon = "Interface\\Icons\\Spell_Holy_PrayerOfFortitude",
        auraNames = { "Power Word: Fortitude", "Prayer of Fortitude" },
        className = "Priest",
        colorRGB = { r = 225 / 255, g = 1, b = 202 / 255 }, -- #E1FFCA
        includeHunterPets = true,
        improvedTalent = {
            name = "Improved Power Word: Fortitude",
            tab = 1, tier = 2, column = 2, maxRank = 2,
        },
    },
    gift = {
        name = "Gift of the Wild",
        gridName = "Mark / Gift of the Wild",
        description = "Increases armor, attributes, and resistances.",
        icon = "Interface\\Icons\\Spell_Nature_GiftoftheWild",
        auraNames = { "Mark of the Wild", "Gift of the Wild" },
        className = "Druid",
        includeHunterPets = true,
        improvedTalent = {
            name = "Improved Mark of the Wild",
            tab = 3, tier = 1, column = 2, maxRank = 5,
        },
    },
    food = {
        name = "Food Buff",
        gridName = "Well Fed",
        description = "Provides a Well Fed stat bonus from food.",
        icon = 136000, -- Spell_Misc_Food
        auraNames = { "Well Fed" },
        colorRGB = { r = 1, g = 0.82, b = 0 },
        includeHunterPets = not features.isClassicEra,
    },
    shadowProtection = {
        name = "Shadow",
        gridName = "Shadow Protection",
        description = "Increases Shadow resistance.",
        icon = "Interface\\Icons\\Spell_Shadow_AntiShadow",
        auraNames = { "Shadow Protection", "Prayer of Shadow Protection" },
        className = "Priest",
        colorRGB = { r = 109 / 255, g = 60 / 255, b = 129 / 255 }, -- #6D3C81
        defaultIncludeInTotal = false,
    },
    intellect = {
        name = "Intellect",
        gridName = "Arcane Intellect / Brilliance",
        description = "Increases Intellect, mana, and spell critical chance.",
        icon = "Interface\\Icons\\Spell_Holy_ArcaneIntellect",
        auraNames = { "Arcane Intellect", "Arcane Brilliance" },
        className = "Mage",
        excludedClasses = WhoDoesWhat.ManaExcludedClasses,
        defaultOnlyManaUsers = true,
    },
}

-- Every ordered tracking group available to WDW Status and the Buffing Grid.
WhoDoesWhat.StatusBarCheckOrder = {
    "actionItems", "pallyPower", "paladinBuffs", "gift",
    "fortitude", "intellect", "shadowProtection",
}
WhoDoesWhat.StatusBarChecks = {}
for _, key in ipairs(WhoDoesWhat.CoreRaidBuffOrder) do
    local buff = WhoDoesWhat.CoreRaidBuffs[key]
    WhoDoesWhat.StatusBarChecks[key] = buff
end
local paladinInfo, shamanInfo
for _, classInfo in ipairs(WhoDoesWhat.Classes) do
    if classInfo.name == "Paladin" then paladinInfo = classInfo end
    if classInfo.name == "Shaman" then shamanInfo = classInfo end
end
WhoDoesWhat.StatusBarChecks.paladinBuffs = {
    name = "Paladin Buff Progress",
    description = "Shows assigned blessing coverage for each Paladin.",
    icon = paladinInfo.classIcon,
    colorRGB = paladinInfo.colorRGB,
    className = "Paladin",
    customCoverage = true,
    includeHunterPets = true,
    gridOptionDisabled = true,
    hiddenOptions = {
        negative = true,
        bestAvailable = true,
        onlyManaUsers = true,
        onlyTanks = true,
        hideColumnUnavailable = true,
        hideColumnComplete = true,
    },
}
WhoDoesWhat.StatusBarChecks.pallyPower = {
    name = "Paladin Buff Notifications",
    description = "Shows whether the active blessing assignments match PallyPower.",
    customOptions = "pallyPower",
    gridOptionDisabled = true,
}
-- Not a buff at all: the count from the Action Items window (roles waiting to
-- be set, group roles that disagree, tanks not promoted). It rides the status
-- rows because it answers the same question they do -- "is anything left to do
-- before the pull" -- and it's the first thing you want answered, so it leads
-- the default order. Shown ON by default: an addon that quietly collects action
-- items nobody is told about isn't worth the pass over the roster.
WhoDoesWhat.StatusBarChecks.actionItems = {
    name = "Action Items",
    description = "Shows players still waiting on a role, group roles that "
        .. "disagree, and tanks not promoted to Main Tank.",
    -- The group-role tank shield, the same one the Action Items dropdowns
    -- draw. `icon` is the fallback for clients without the micro role atlas,
    -- spelled out rather than read from BasicWowRoles: that table is defined
    -- further down this file.
    wowRoleIcon = "tank",
    icon = "Interface\\Icons\\INV_Shield_06",
    customOptions = "actionItems",
    gridOptionDisabled = true,
    defaultEnabled = true,
}
WhoDoesWhat.StatusBarChecks.thorns = {
    name = "Thorns",
    description = "Deals Nature damage to attackers.",
    icon = "Interface\\Icons\\Spell_Nature_Thorns",
    auraNames = { "Thorns" },
    className = "Druid",
    colorRGB = { r = 129 / 255, g = 77 / 255, b = 24 / 255 }, -- #814D18
    defaultOnlyTanks = true,
    improvedTalent = {
        name = features.isClassicEra and "Improved Thorns" or "Brambles",
        tab = 1, tier = 3, column = 1, maxRank = 3,
    },
}
WhoDoesWhat.StatusBarChecks.dead = {
    name = "Dead",
    description = "Shows whether each raider is dead or a ghost.",
    icon = 132331,
    colorRGB = { r = 0.46, g = 0.48, b = 0.52 },
    -- The one check corpses don't drop out of mid-fight; counting them is the
    -- point of it (see IgnoredWhileDead in Assignments.lua).
    countsDead = true,
    defaultNegative = true,
    defaultHideComplete = true,
    defaultHideColumnComplete = true,
    defaultSaturatedStyle = "x",
    gridOptionDisabled = true,
    hunterPetsOptionDisabled = true,
    hiddenOptions = {
        hideColumnUnavailable = true,
        hideColumnComplete = true,
    },
}
if not features.isClassicEra then
    WhoDoesWhat.StatusBarChecks.sated = {
        name = "Sated (lust / hero)",
        description = "Shows Sated or Exhaustion after Bloodlust or Heroism.",
        icon = 136090, -- Spell_Nature_Sleep
        auraNames = { "Sated", "Exhaustion" },
        harmful = true,
        defaultNegative = true,
        defaultHideComplete = true,
        defaultHideColumnComplete = true,
        defaultSaturatedStyle = "check",
        colorRGB = shamanInfo.colorRGB,
        className = "Shaman",
        -- Bloodlust lands on pets too, and a shadowfiend summoned after the
        -- cast is exactly the kind of straggler the partial glow is for, so
        -- this check counts every pet rather than the hunters' alone.
        includeHunterPets = true,
        allPets = true,
        -- Out of combat the useful list is who is still Sated (nobody can lust
        -- them yet); mid-fight it's who the lust missed. See FlagsTheCovered.
        flagMissingInCombat = true,
        -- Being a shaman does not make you responsible for other people's
        -- Sated: the debuff is the cooldown, not a job left undone. What IS
        -- worth a shaman's attention is a lust that reached almost everybody
        -- (see partialGlow in StatusBarsView).
        partialGlow = true,
        hiddenOptions = { responsibleGlow = true },
    }
end
if not features.isClassicEra then
    WhoDoesWhat.StatusBarChecks.drumsUsed = {
        name = "Tinnitus (drums)",
        description = "Shows Tinnitus after a party receives a drums effect.",
        icon = 133854, -- INV_Misc_Ear_Human_01
        auraNames = { "Tinnitus" },
        harmful = true,
        defaultNegative = true,
        defaultHideComplete = true,
        defaultHideColumnComplete = true,
        defaultSaturatedStyle = "check",
        colorRGB = { r = 0.78, g = 0.14, b = 0.10 },
        hunterPetsOptionDisabled = true,
    }
end

WhoDoesWhat.StatusBarCheckOrder[#WhoDoesWhat.StatusBarCheckOrder + 1] = "thorns"
WhoDoesWhat.StatusBarCheckOrder[#WhoDoesWhat.StatusBarCheckOrder + 1] = "food"
if not features.isClassicEra then
    WhoDoesWhat.StatusBarCheckOrder[#WhoDoesWhat.StatusBarCheckOrder + 1] = "sated"
    WhoDoesWhat.StatusBarCheckOrder[#WhoDoesWhat.StatusBarCheckOrder + 1] = "drumsUsed"
end
WhoDoesWhat.StatusBarCheckOrder[#WhoDoesWhat.StatusBarCheckOrder + 1] = "dead"

for _, key in ipairs(WhoDoesWhat.StatusBarCheckOrder) do
    local definition = WhoDoesWhat.StatusBarChecks[key]
    if definition.defaultEnabled == nil then definition.defaultEnabled = true end
    definition.defaultGrid = not definition.gridOptionDisabled
end

-- Resolved check options per key, and the resolved order list.
--
-- Both are pure functions of saved settings plus the static definitions, but
-- resolving one set of options walks ~25 defaulting branches and loops
-- self.Classes to validate requiredClass -- and the status view asks for them
-- around twenty times per repaint, at up to 10Hz in a 40-man.
--
-- Invalidated explicitly rather than per frame, because there is exactly one
-- writer (StoreStatusBuffOption in AddonSettingsView) and a settings edit has
-- to show up in the same frame it is made. Anything that ever writes these
-- settings outside that funnel must call InvalidateStatusBarCheckCache.
--
-- Both are handed out shared, so callers must treat them as read-only. They
-- all do: every caller reads fields or iterates, none assigns or reorders.
local statusOptionsCache, statusOrderCache = {}, nil

function WhoDoesWhat:InvalidateStatusBarCheckCache()
    wipe(statusOptionsCache)
    statusOrderCache = nil
end

-- Saved order is a full list so newly-added checks can be appended safely.
function WhoDoesWhat:GetStatusBarCheckOrder()
    if statusOrderCache then return statusOrderCache end
    local saved = self.db.profile.settings.statusBarOrder
    local order, seen = {}, {}
    for _, key in ipairs(saved or {}) do
        if self.StatusBarChecks[key] and not seen[key] then
            order[#order + 1] = key
            seen[key] = true
        end
    end
    for _, key in ipairs(self.StatusBarCheckOrder) do
        if not seen[key] then order[#order + 1] = key end
    end
    statusOrderCache = order
    return order
end

function WhoDoesWhat:GetStatusBarCheckOptions(key)
    local cached = statusOptionsCache[key]
    if cached then return cached end
    local definition = self.StatusBarChecks[key]
    if not definition then return nil end
    local all = self.db.profile.settings.statusBarChecks
    local saved = all and all[key] or {}
    local bar = saved.bar
    if bar == nil then bar = saved.enabled end -- old settings-page key
    if bar == nil then bar = definition.defaultEnabled end
    local grid = saved.grid
    if grid == nil then grid = definition.defaultGrid == true end
    if definition.gridOptionDisabled then grid = false end
    local hunterPets = saved.hunterPets
    if hunterPets == nil then hunterPets = definition.includeHunterPets == true end
    local onlyManaUsers = saved.onlyManaUsers
    if onlyManaUsers == nil then
        onlyManaUsers = definition.defaultOnlyManaUsers == true
    end
    local onlyTanks = saved.onlyTanks
    if onlyTanks == nil then onlyTanks = definition.defaultOnlyTanks == true end
    local negative = saved.negative
    if negative == nil then negative = definition.defaultNegative == true end
    local includeInTotal = saved.includeInTotal
    if includeInTotal == nil then
        includeInTotal = definition.defaultIncludeInTotal ~= false
    end
    local bestAvailable = saved.bestAvailable
    if bestAvailable == nil and saved.includeUnimproved ~= nil then
        bestAvailable = not saved.includeUnimproved
    end
    if bestAvailable == nil then bestAvailable = true end
    -- Sub-option of "best available". Once the pull is under way -- or in a
    -- battleground, where the roster is strangers and rebuffing is a luxury --
    -- a weaker buff is the answer, so the check stops asking for the best one.
    local anyInCombat = saved.anyInCombat
    if anyInCombat == nil then anyInCombat = true end
    local requiredClass = saved.requiredClass
    if requiredClass == nil then requiredClass = definition.className or false end
    if requiredClass then
        local valid
        for _, classInfo in ipairs(self.Classes) do
            if classInfo.name == requiredClass then
                valid = true
                break
            end
        end
        if not valid then requiredClass = definition.className or false end
    end
    local barColor = saved.barColor
    if barColor == nil then barColor = saved.backgroundColor end
    if barColor == false then
        barColor = nil
    elseif type(barColor) ~= "table" or type(barColor.r) ~= "number"
        or type(barColor.g) ~= "number"
        or type(barColor.b) ~= "number" then
        barColor = nil
        local legacy = self.StatusBarBackgrounds[saved.background]
        if legacy then barColor = legacy.colorRGB end
    end
    local display = saved.display
    if display ~= "percent" and display ~= "missing" and display ~= "fraction"
        and display ~= "applied" then display = "default" end
    local hideBarUnavailable = requiredClass
        and saved.hideBarUnavailable ~= false or false
    local hideColumnUnavailable = requiredClass
        and saved.hideColumnUnavailable ~= false or false
    local hideComplete = saved.hideComplete
    if hideComplete == nil then
        hideComplete = definition.defaultHideComplete == true
    end
    local hideColumnComplete = saved.hideColumnComplete
    if hideColumnComplete == nil then
        hideColumnComplete = definition.defaultHideColumnComplete == true
    end
    local saturatedStyle = saved.saturatedStyle
    if saturatedStyle ~= "hide" and saturatedStyle ~= "x"
        and saturatedStyle ~= "check" then
        saturatedStyle = definition.defaultSaturatedStyle or "check"
    end
    local hideWhenSynced = saved.hideWhenSynced
    if hideWhenSynced == nil then
        hideWhenSynced = saved.onlyDesynced == true
    end
    local hideWhenInactive = saved.hideWhenInactive
    if hideWhenInactive == nil then hideWhenInactive = true end
    -- Action Items' pair, mirroring the two above: whether a clear list still
    -- gets a row, and whether the row survives being ungrouped (where there is
    -- nothing to check and never will be until you join something).
    local hideWhenClear = saved.hideWhenClear == true
    local hideWhenSolo = saved.hideWhenSolo
    if hideWhenSolo == nil then hideWhenSolo = true end
    -- Default ON: a raider with no rights over anyone's role but their own
    -- can't act on a list of other people's, so by default they aren't shown
    -- one. Off restores the honest-count-without-a-glow behaviour.
    local hideWhenNotYours = saved.hideWhenNotYours ~= false
    -- Only offered on class-based checks (see responsibleGlow in
    -- hiddenOptions); the status view still decides whether the local player
    -- is the one on the hook.
    local responsibleGlow = saved.responsibleGlow ~= false
    -- The other glow rule, offered only where a check opts in (`partialGlow`
    -- in this file): fires on the last few stragglers rather than on any gap
    -- at all. Its "only as <class>" sub-option is off by default -- everyone
    -- benefits from seeing that a lust missed people, only a shaman can fix
    -- it, and which of those you want is a matter of taste.
    local partialGlow = saved.partialGlow ~= false
    local partialGlowOnlyClass = saved.partialGlowOnlyClass == true
    -- Shared, so callers must treat it as read-only (they all do -- every one
    -- reads fields off it and none assigns).
    local options = {
        bar = bar,
        grid = grid,
        scope = saved.scope or "always",
        display = display,
        hideComplete = hideComplete,
        hideColumnComplete = hideColumnComplete,
        bestAvailable = bestAvailable,
        anyInCombat = anyInCombat,
        onlyManaUsers = onlyManaUsers,
        onlyTanks = onlyTanks,
        hunterPets = hunterPets,
        negative = negative,
        includeInTotal = includeInTotal,
        saturatedStyle = saturatedStyle,
        requiredClass = requiredClass,
        hideBarUnavailable = hideBarUnavailable,
        hideColumnUnavailable = hideColumnUnavailable,
        barColor = barColor,
        combinePaladinBars = saved.combinePaladinBars == true,
        responsibleGlow = responsibleGlow,
        partialGlow = partialGlow,
        partialGlowOnlyClass = partialGlowOnlyClass,
        hideWhenSynced = hideWhenSynced,
        hideWhenInactive = hideWhenInactive,
        assignmentIssuesGlow = saved.assignmentIssuesGlow ~= false,
        hideWhenClear = hideWhenClear,
        hideWhenSolo = hideWhenSolo,
        hideWhenNotYours = hideWhenNotYours,
        actionItemsGlow = saved.actionItemsGlow ~= false,
    }
    statusOptionsCache[key] = options
    return options
end

-- Warlock raid curses metadata, using the highest rank available on this
-- client. Classic Era keeps Curse of Shadow separate; TBC folds its schools
-- into Curse of the Elements.
local curseSpellIds = features.warlockCurseSpellIds
WhoDoesWhat.WarlockCurses = {
    reck = {
        icon = "Interface\\Icons\\Spell_Shadow_UnholyStrength",
        name_short = "Reck",
        name_long = "Curse of Recklessness",
        spellId = curseSpellIds.reck
    },
    elements = {
        icon = "Interface\\Icons\\Spell_Shadow_ChillTouch",
        name_short = "Elements",
        name_long = "Curse of the Elements",
        spellId = curseSpellIds.elements
    }
}
if curseSpellIds.shadow then
    WhoDoesWhat.WarlockCurses.shadow = {
        icon = "Interface\\Icons\\Spell_Shadow_CurseOfAchimonde",
        name_short = "Shadow",
        name_long = "Curse of Shadow",
        spellId = curseSpellIds.shadow,
    }
end

local healthstoneClient = WhoDoesWhat.ClientFeatures.warlockHealthstone
WhoDoesWhat.WarlockHealthstone = {
    icon = "Interface\\Icons\\INV_Stone_04",
    talent = "Improved Healthstone",
    maxRank = 2,
    name = healthstoneClient.name,
    lifeByTalentRank = healthstoneClient.lifeByTalentRank,
}

-- TBC crowd-control spells offered by the CC Assignments section, listed in
-- class order (the dropdown draws a divider on each class change). spellId is
-- the max TBC rank and is the single source of truth for a spell: it drives
-- both the hover tooltip and the icon (resolved at runtime via GetSpellIcon),
-- so a wrong id shows up as a "?" instead of a plausible-looking mistake.
-- `id` is the stable DB key -- renaming a spell must never orphan saved data.
--
-- Deliberately omitted: AoE fears (Psychic Scream, Howl of Terror,
-- Intimidating Shout) and short stuns/interrupts (Hammer of Justice, Gouge,
-- Counterspell) -- they're not the kind of thing you assign a target to.
-- Shamans have no assignable CC in TBC.
local ccSpells = {
    { id = "polymorph",   name = "Polymorph",       class = "Mage",    spellId = 12826 }, -- Rank 4
    { id = "banish",      name = "Banish",          class = "Warlock", spellId = 18647 }, -- Rank 2
    { id = "fear",        name = "Fear",            class = "Warlock", spellId = 6215 },  -- Rank 3
    { id = "seduction",   name = "Seduction",       class = "Warlock", spellId = 6358 },  -- Succubus pet ability
    { id = "enslave",     name = "Enslave Demon",   class = "Warlock", spellId = 11726 }, -- Rank 3
    { id = "shackle",     name = "Shackle Undead",  class = "Priest",  spellId = 10955 }, -- Rank 3
    { id = "mindcontrol", name = "Mind Control",    class = "Priest",  spellId = 10912 }, -- Rank 3
    { id = "cyclone",     name = "Cyclone",         class = "Druid",   spellId = 33786 },
    { id = "hibernate",   name = "Hibernate",       class = "Druid",   spellId = 18658 }, -- Rank 3
    { id = "roots",       name = "Entangling Roots", class = "Druid",  spellId = 26989 }, -- Rank 7
    { id = "freezetrap",  name = "Freezing Trap",   class = "Hunter",  spellId = 14311 }, -- Rank 3
    { id = "wyvern",      name = "Wyvern Sting",    class = "Hunter",  spellId = 27068 }, -- Rank 4
    { id = "scatter",     name = "Scatter Shot",    class = "Hunter",  spellId = 19503 },
    { id = "sap",         name = "Sap",             class = "Rogue",   spellId = 11297 }, -- Rank 3
    { id = "blind",       name = "Blind",           class = "Rogue",   spellId = 2094 },
    { id = "kidneyshot",  name = "Kidney Shot",     class = "Rogue",   spellId = 8643 },  -- Rank 2
    { id = "turnundead",  name = "Turn Undead",     class = "Paladin", spellId = 10326 }, -- Rank 3
    { id = "repentance",  name = "Repentance",      class = "Paladin", spellId = 20066 },
    { id = "disarm",      name = "Disarm",          class = "Warrior", spellId = 676 },
}

WhoDoesWhat.CCSpells = {}
for _, spell in ipairs(ccSpells) do
    if not features.excludedCCSpells[spell.id] then
        spell.spellId = features.ccSpellIds[spell.id] or spell.spellId
        WhoDoesWhat.CCSpells[#WhoDoesWhat.CCSpells + 1] = spell
    end
end

-- Fast lookup for a CC spell by its stable id. Built at load: the list never
-- changes at runtime, so this needs no init hook.
WhoDoesWhat.CCSpellsById = {}
for _, spell in ipairs(WhoDoesWhat.CCSpells) do
    WhoDoesWhat.CCSpellsById[spell.id] = spell
end

-- Icon for a spell id, taken from the client's own spell data so one id drives
-- both a row's icon and its tooltip. Returns the "?" icon when this client
-- doesn't know the id, which makes a bad id visible rather than silent.
function WhoDoesWhat:GetSpellIcon(spellId)
    local tex = spellId and GetSpellTexture and GetSpellTexture(spellId)
    return tex or 134400 -- INV_Misc_QuestionMark
end

-- Raid target markers in skull-first order (the order tanks usually claim
-- them). index is the client's raid target index (SetRaidTarget /
-- UI-RaidTargetingIcon_<index> texture).
WhoDoesWhat.RaidTargetMarkers = {
    { index = 8, name = "Skull" },
    { index = 7, name = "Cross" },
    { index = 6, name = "Square" },
    { index = 5, name = "Moon" },
    { index = 4, name = "Triangle" },
    { index = 3, name = "Diamond" },
    { index = 2, name = "Circle" },
    { index = 1, name = "Star" },
}

-- Basic WoW Roles Metadata with dual icon choices. blizzRole is the client's
-- role token (UnitGroupRolesAssigned / GetMicroIconForRole vocabulary).
WhoDoesWhat.BasicWowRoles = {
    dps = {
        name = "DPS",
        blizzRole = "DAMAGER",
        iconType1 = "Interface\\Icons\\INV_Sword_39",
        iconIdType1 = 132415,
        iconType2 = "Interface\\Icons\\Spell_Fire_Firebolt",
        iconIdType2 = 135804
    },
    tank = {
        name = "Tank",
        blizzRole = "TANK",
        iconType1 = "Interface\\Icons\\INV_Shield_06",
        iconIdType1 = 134944,
        iconType2 = "Interface\\Icons\\Ability_Warrior_DefensiveStance",
        iconIdType2 = 132341
    },
    healer = {
        name = "Healer",
        blizzRole = "HEALER",
        iconType1 = "Interface\\Icons\\Spell_Holy_LayOnHands",
        iconIdType1 = 135928,
        iconType2 = "Interface\\Icons\\Spell_Holy_HealingFocus",
        iconIdType2 = 135914
    }
}

-- Inline texture-escape markup for a wow role ("dps"/"tank"/"healer"): the
-- client's micro role atlas icons (shield/plus/sword, as seen in the default
-- Set Role menu). Falls back to our icon files if the atlas API is missing.
function WhoDoesWhat:GetWowRoleIconMarkup(key, size)
    local meta = self.BasicWowRoles[key]
    if not meta then return "" end
    size = size or 14
    if GetMicroIconForRole and CreateAtlasMarkup then
        return CreateAtlasMarkup(GetMicroIconForRole(meta.blizzRole), size, size)
    end
    return "|T" .. meta.iconType1 .. ":" .. size .. ":" .. size .. ":0:0|t"
end

-- Texture twin of GetWowRoleIconMarkup, for status checks that draw their icon
-- into a texture rather than a string. A check may name a `wowRoleIcon` to wear
-- the client's micro role atlas -- the same shield/plus/sword the group-role
-- dropdowns use -- instead of an icon file. Atlas art is already trimmed, so
-- only the file path takes the usual inset TexCoord; the reset matters because
-- one shared texture (the options panel's header) switches between checks.
function WhoDoesWhat:ApplyStatusCheckIcon(texture, definition)
    local meta = definition.wowRoleIcon
        and self.BasicWowRoles[definition.wowRoleIcon]
    if meta and GetMicroIconForRole and texture.SetAtlas then
        texture:SetAtlas(GetMicroIconForRole(meta.blizzRole))
        return
    end
    texture:SetTexture(definition.icon)
    texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
end

-- ---------------------------------------------------------------------------
-- Role icons
--
-- A role's `icon` is normally a texture (FileDataID or path). A custom role may
-- instead pick one of the client's micro role icons -- the same shield/plus/
-- sword the group-role dropdowns wear -- which are ATLASES, not files, and so
-- cannot be handed to SetTexture or to a |T...|t escape. Those are stored as
-- the string "role:tank" / "role:healer" / "role:dps" and resolved through the
-- two helpers below, which fall back to our own icon files on a client without
-- the atlas API (the same fallback GetWowRoleIconMarkup makes).
--
-- Anything that draws a role icon must go through these rather than touching
-- `icon` directly, or a role wearing a micro icon renders blank.
-- ---------------------------------------------------------------------------

local ROLE_ICON_PREFIX = "role:"

-- The wow-role key behind a "role:*" icon, or nil for an ordinary texture.
function WhoDoesWhat:RoleIconKey(icon)
    if type(icon) ~= "string" then return nil end
    local key = icon:match("^" .. ROLE_ICON_PREFIX .. "(%a+)$")
    return key and self.BasicWowRoles[key] and key or nil
end

function WhoDoesWhat:MakeRoleIcon(wowRoleKey)
    return ROLE_ICON_PREFIX .. wowRoleKey
end

-- Inline markup for a role icon, whichever kind it is.
function WhoDoesWhat:RoleIconMarkup(icon, size)
    if not icon then return "" end
    size = size or 14
    local key = self:RoleIconKey(icon)
    if key then return self:GetWowRoleIconMarkup(key, size) end
    return "|T" .. icon .. ":" .. size .. ":" .. size .. ":0:0|t"
end

-- Draw a role icon into a texture. Atlas art is already trimmed, so the usual
-- inset TexCoord is reset for it -- pooled row textures switch between kinds.
function WhoDoesWhat:SetRoleIconTexture(texture, icon)
    local key = self:RoleIconKey(icon)
    local meta = key and self.BasicWowRoles[key]
    if meta and GetMicroIconForRole and texture.SetAtlas then
        texture:SetAtlas(GetMicroIconForRole(meta.blizzRole))
        return
    end
    texture:SetTexCoord(0, 1, 0, 1)
    texture:SetTexture(meta and meta.iconIdType1 or icon)
end

-- Canonical full ordering of all six paladin buffs. Partial PaladinBuffDefaults
-- orders are backfilled from this before default bans move below the divider,
-- and the main assignments view lists its buff rows in this order.
WhoDoesWhat.CanonicalBuffOrder = { "salv", "kings", "might", "wisdom", "light", "sanctuary" }

-- Blessings placed below the role editor's END divider by default. Blizzard-
-- role bans also cover custom roles; role-id bans capture class/spec defaults.
-- Users can promote any of these above the divider in a saved customization.
WhoDoesWhat.PaladinBuffBansByWowRole = {
    tank = { salv = true },
}
WhoDoesWhat.PaladinBuffBansByRole = {
    warrior_fury = { wisdom = true },
    warrior_arms = { wisdom = true },
    warrior_prot = { wisdom = true },
    rogue_combat = { wisdom = true },
    rogue_assassin = { wisdom = true },
    rogue_sub = { wisdom = true },
    paladin_holy = { might = true },
    priest_disc = { might = true },
    priest_holy = { might = true },
    priest_shadow = { might = true },
    shaman_ele = { might = true },
    shaman_resto = { might = true },
    mage_arcane = { might = true },
    mage_fire = { might = true },
    mage_frost = { might = true },
    mage_tank = { might = true },
    warlock_affl = { might = true },
    warlock_demo = { might = true },
    warlock_destro = { might = true },
    warlock_firetank = { might = true },
    druid_balance = { might = true },
    druid_balance_tank = { might = true },
    druid_resto = { might = true },
    druid_dreamstate = { might = true },
}

WhoDoesWhat.HunterPetBuffOrder = { "might", "kings", "light" }

-- Default paladin buff priority orders, grouped so many roles can share one
-- order without repeating it. Nearly every role now spells out all six buffs
-- so the bottom slots are deliberate too: casters and healers end
-- ..Sanctuary, Might (Might dead last -- they swing a wand at best) and
-- tank defaults end ..Salvation, where role bans place it below the divider
-- and exclude it from assignment. Partial lists are still backfilled by
-- PopulateRolesAndCategories. Keyed by role id, since class+wowRole can't
-- disambiguate (e.g. Druid Balance vs Feral DPS are both dps but want
-- different orders). Applied into RolesAndCategories on init.
WhoDoesWhat.PaladinBuffDefaults = {
    {
        -- Melee: Light over Wisdom (no mana bar worth feeding).
        order = { "salv", "might", "kings", "light", "wisdom", "sanctuary" },
        roles = { "warrior_fury", "warrior_arms", "rogue_combat", "rogue_assassin", "rogue_sub" },
    },
    {
        -- Casters (Elemental included): Sanctuary 5th, Might last.
        order = { "salv", "kings", "wisdom", "light", "sanctuary", "might" },
        roles = { "mage_arcane", "mage_fire", "mage_frost", "warlock_affl", "warlock_demo",
            "warlock_destro", "druid_balance", "priest_shadow", "shaman_ele" },
    },
    {
        -- Physical-leaning mana hybrids: Might stays high.
        order = { "salv", "might", "kings", "wisdom", "light", "sanctuary" },
        roles = { "hunter_bm", "hunter_surv", "hunter_mm", "shaman_enh" },
    },
    {
        order = { "salv", "kings", "might", "wisdom", "light", "sanctuary" },
        roles = { "druid_feral_dps" },
    },
    {
        order = { "salv", "might", "kings", "wisdom", "light", "sanctuary" },
        roles = { "paladin_ret" },
    },
    -- Tanks: Salvation is listed last here, then removed by the role ban.
    {
        order = { "kings", "might", "light", "wisdom", "sanctuary", "salv" },
        roles = { "druid_feral_tank" },
    },
    {
        order = { "kings", "might", "light", "sanctuary", "wisdom", "salv" },
        roles = { "warrior_prot" },
    },
    {
        order = { "kings", "wisdom", "light", "sanctuary", "might", "salv" },
        roles = { "paladin_prot" },
    },
    {
        order = { "kings", "wisdom", "sanctuary", "light", "might", "salv" },
        roles = { "warlock_firetank" },
    },
    -- Healers: Sanctuary 5th, Might last (they don't swing anything).
    {
        order = { "kings", "wisdom", "salv", "light", "sanctuary", "might" },
        roles = { "paladin_holy", "priest_holy", "priest_disc", "druid_resto", "druid_dreamstate" },
    },
    {
        order = { "wisdom", "kings", "salv", "light", "sanctuary", "might" },
        roles = { "shaman_resto" },
    },
    -- Pets want the physical top-ups, then Light.
    {
        order = WhoDoesWhat.HunterPetBuffOrder,
        roles = { "hunter_pets" },
    },
}

if not features.isClassicEra then
    table.insert(WhoDoesWhat.PaladinBuffDefaults, {
        order = { "salv", "kings", "wisdom", "light", "sanctuary", "might" },
        roles = { "mage_tank", "druid_balance_tank" },
    })
    table.insert(WhoDoesWhat.PaladinBuffDefaults, {
        order = { "salv", "might", "kings", "wisdom", "light", "sanctuary" },
        roles = { "hunter_tank" },
    })
end

table.insert(WhoDoesWhat.PaladinBuffDefaults, {
    order = { "kings", "sanctuary", "wisdom", "light", "might", "salv" },
    roles = { "paladin_prot_trash" },
})

-- The hunter-pet pseudo-role: never assignable and never customizable --
-- every hunter's pet simply carries it. Assignments.lua derives one virtual
-- pet per hunter for the paladin-buff math (demand votes, grid rows, the
-- PallyPower bridge); there is nothing to set anywhere. Lives OUTSIDE the
-- Hunter role/category lists so no Set Role menu or Role Preferences page
-- ever offers it, but is registered in RolesAndCategories (like Non-raider
-- below) so a stale assignment synced from an old client still resolves to
-- an icon and a sane buff order.
WhoDoesWhat.HUNTER_PET_ROLE_ID = "hunter_pets"
WhoDoesWhat.HunterPetRole = {
    name = "Pets",
    icon = 132179, -- Ability_Hunter_MendPet
    id = WhoDoesWhat.HUNTER_PET_ROLE_ID,
    wowRole = "dps",
}

-- The Non-raider pseudo-role: marks a group member as sitting out (bench,
-- standby, carried alt). Assignable to ANY class from the unit right-click
-- menu; non-raiders drop out of the paladin-buff machinery -- no demand
-- votes, no buff dropdowns/pools (the class-filtered roster skips them), no
-- row in the buff grid. Its pseudo-class deliberately lives OUTSIDE
-- WhoDoesWhat.Classes: every loop over Classes (Role Preferences, the class
-- role lists, custom-role registration) never sees it.
WhoDoesWhat.NON_RAIDER_ROLE_ID = "non_raider"
WhoDoesWhat.NonRaiderClass = {
    name = "Non-raider",
    colorHex = "909090",
    roles = {},
}
WhoDoesWhat.NonRaiderRole = {
    name = "Non-raider",
    icon = 136090, -- Spell_Nature_Sleep ("zzz")
    id = WhoDoesWhat.NON_RAIDER_ROLE_ID,
    wowRole = false, -- no Blizzard role flag to sync
}

-- Fast lookup table populated on load
WhoDoesWhat.RolesAndCategories = {}

-- Expand a (possibly partial) buff order into all six buffs: keep the given order,
-- then append any buffs it omits in canonical (CanonicalBuffOrder) order.
function WhoDoesWhat:BackfillBuffOrder(partial)
    local seen, full = {}, {}
    for _, key in ipairs(partial or {}) do
        if self.PaladinBuffs[key] and not seen[key] then
            seen[key] = true
            full[#full + 1] = key
        end
    end
    for _, key in ipairs(self.CanonicalBuffOrder) do
        if not seen[key] then
            seen[key] = true
            full[#full + 1] = key
        end
    end
    return full
end

function WhoDoesWhat:PopulateRolesAndCategories()
    self.RolesAndCategories = {}
    for _, classInfo in ipairs(self.Classes) do
        for _, role in ipairs(classInfo.roles) do
            local entry = {}
            for k, v in pairs(role) do
                entry[k] = v
            end
            entry.classInfo = classInfo
            self.RolesAndCategories[role.id] = entry
        end
        if classInfo.categories then
            for _, cat in ipairs(classInfo.categories) do
                local entry = {}
                for k, v in pairs(cat) do
                    entry[k] = v
                end
                entry.classInfo = classInfo
                self.RolesAndCategories[cat.id] = entry
            end
        end
    end
    -- Register the hunter-pet pseudo-role for id lookups, before the buff
    -- defaults attach below so its pet-only order lands on it. Not in
    -- the Hunter role list, so no role menu ever sees it.
    for _, classInfo in ipairs(self.Classes) do
        if classInfo.name == "Hunter" then
            local petRole = {}
            for k, v in pairs(self.HunterPetRole) do
                petRole[k] = v
            end
            petRole.classInfo = classInfo
            self.RolesAndCategories[petRole.id] = petRole
        end
    end

    -- Attach the shared default buff orders onto their role entries, backfilled so
    -- each one lists all six buffs. The full order is built once per group and
    -- shared across its roles (the customizer copies before mutating).
    for _, group in ipairs(self.PaladinBuffDefaults) do
        local fullOrder = self:BackfillBuffOrder(group.order)
        for _, roleId in ipairs(group.roles) do
            local entry = self.RolesAndCategories[roleId]
            if entry then
                entry.buffOrder = fullOrder
            else
                self:LogUiBuilding("PaladinBuffDefaults: unknown role id " .. tostring(roleId))
            end
        end
    end

    -- Register the Non-raider pseudo-role for the id lookups (FindRoleById,
    -- role icons, Raider Roles rows). Not in Classes, so nothing above -- and
    -- no class role list -- ever offers it; the unit menu adds it by hand.
    local nonRaider = {}
    for k, v in pairs(self.NonRaiderRole) do
        nonRaider[k] = v
    end
    nonRaider.classInfo = self.NonRaiderClass
    self.RolesAndCategories[nonRaider.id] = nonRaider

    -- Register custom roles inside their assigned class's role list, appended
    -- after the regular roles and never collapsed into categories. They wear
    -- their class's icon -- a built-in role's icon says which spec it is, and a
    -- custom role has no spec to name, so the class is the most it can honestly
    -- claim. It beats the "?" these used to carry, which said nothing at all in
    -- lists that show nothing else about the role. They default to the
    -- canonical buff order.
    --
    -- There are two lists, and which one a role picker sees is the whole point:
    --
    --   classInfo.libraryRoles  the local profile's customRoles -- your own
    --                           roles, whole definitions: name, class, group
    --                           role, icon and blessing order.
    --   classInfo.raidRoles     db.profile.raidCustomRoles -- the shared board's
    --                           published copies, carrying their own buff order.
    --
    -- classInfo.customRoles (what every role picker reads) is the published
    -- list followed by whatever the library still holds privately. Offering the
    -- private ones is safe because assigning one publishes it first
    -- (EnsureRoleIsShareable), which is what keeps "a role somebody is assigned"
    -- and "a role every client can resolve" the same set.
    --
    -- A published role shares its id with the library entry it came from, so
    -- the raid version deliberately overwrites it in RolesAndCategories: the
    -- board is authoritative for anything the plan is computed from. The
    -- library window looks its rows up in LibraryRoles instead.
    local classByName = {}
    for _, classInfo in ipairs(self.Classes) do
        classInfo.customRoles = nil
        classInfo.libraryRoles = nil
        classInfo.raidRoles = nil
        classByName[classInfo.name] = classInfo
    end
    self.LibraryRoles = {}

    local function RegisterCustomRole(cr, listKey, registry)
        local classInfo = classByName[cr.class]
        if not classInfo then
            self:LogUiBuilding("Custom role '" .. tostring(cr.name)
                .. "' skipped: unknown class " .. tostring(cr.class))
            return
        end
        local entry = {
            name = cr.name,
            -- A saved icon is one the user picked out of CustomRoleIconChoices;
            -- without one the class icon stands in, so a role nobody has bothered
            -- to decorate still says which class it belongs to.
            icon = cr.icon or classInfo.classIcon,
            id = cr.id,
            isCustom = true,
            wowRole = cr.wowRole or false,
            classInfo = classInfo,
        }
        if cr.order then
            -- A custom role owns its blessing order outright: the role is
            -- yours, and it needs a full definition before it ever reaches the
            -- board. Built-in roles are the ones with nothing local to edit.
            entry.ownOrder = self:BackfillBuffOrder(cr.order)
            local allowed = math.floor(tonumber(cr.allowed) or #entry.ownOrder)
            entry.ownAllowed = math.max(0, math.min(allowed, #entry.ownOrder))
        end
        self.RolesAndCategories[cr.id] = entry
        if registry then registry[cr.id] = entry end
        classInfo[listKey] = classInfo[listKey] or {}
        table.insert(classInfo[listKey], entry)
    end

    local profile = self.db and self.db.profile
    for _, cr in ipairs(profile and profile.customRoles or {}) do
        RegisterCustomRole(cr, "libraryRoles", self.LibraryRoles)
    end
    for _, cr in ipairs(profile and profile.raidCustomRoles or {}) do
        RegisterCustomRole(cr, "raidRoles", nil)
    end

    -- Published first, then the library entries not published yet. Deduped by
    -- id, because publishing copies a library role rather than renaming it.
    for _, classInfo in ipairs(self.Classes) do
        local merged, seen = nil, {}
        for _, role in ipairs(classInfo.raidRoles or {}) do
            merged = merged or {}
            merged[#merged + 1] = role
            seen[role.id] = true
        end
        for _, role in ipairs(classInfo.libraryRoles or {}) do
            if not seen[role.id] then
                merged = merged or {}
                merged[#merged + 1] = role
            end
        end
        classInfo.customRoles = merged
    end

    -- Apply the board's buff orders. Every entry on raidCustomRoles carries one,
    -- whether it is a published custom role or an override of a built-in role or
    -- category, and it is the ONLY place an order can deviate from the defaults
    -- -- there is no local store any more, so two clients holding the same board
    -- cannot compute different blessing plans.
    --
    -- A category fans its order out to every sub-role, since the plan is only
    -- ever computed for concrete roles. Categories are applied first and direct
    -- role overrides second, so overriding Mage DPS and then Frost on top of it
    -- leaves Frost with the more specific of the two.
    local function ApplyOrder(entry, def)
        if not entry then return end
        entry.raidOrder = self:BackfillBuffOrder(def.order)
        local allowed = math.floor(tonumber(def.allowed) or #entry.raidOrder)
        entry.raidAllowed = math.max(0, math.min(allowed, #entry.raidOrder))
        entry.isRaid = true
    end

    local board = profile and profile.raidCustomRoles or {}
    for _, def in ipairs(board) do
        local entry = self.RolesAndCategories[def.id]
        if entry and entry.allSubRoles then
            ApplyOrder(entry, def)
            for _, subId in ipairs(entry.allSubRoles) do
                ApplyOrder(self.RolesAndCategories[subId], def)
            end
        end
    end
    for _, def in ipairs(board) do
        local entry = self.RolesAndCategories[def.id]
        if entry and not entry.allSubRoles then
            ApplyOrder(entry, def)
        elseif not entry then
            self:LogUiBuilding("Raid role override for unknown id " .. tostring(def.id))
        end
    end

    self:LogUiBuilding("Roles and categories lookup table populated.")
end

-- Check if a role ID is a category
function WhoDoesWhat:IsRoleACategory(roleId)
    local entry = self.RolesAndCategories[roleId]
    if entry and entry.allSubRoles then
        return true
    end
    return false
end

-- Check if a role ID is a category that wraps exactly one sub-role
function WhoDoesWhat:IsRoleASingleRoleCategory(roleId)
    if self:IsRoleACategory(roleId) then
        local entry = self.RolesAndCategories[roleId]
        if entry and #entry.allSubRoles == 1 then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Buff orders
--
-- Three sources, most specific first (GetEffectiveBuffSetup):
--
--   entry.raidOrder   an override on the shared board, whether of a built-in
--                     role, a category, or a published custom role. Applied
--                     onto the role entries by PopulateRolesAndCategories, so
--                     by the time anything reads an order it is already there.
--   entry.ownOrder    a custom role's own stored setup. The role is yours and
--                     needs a full definition before it ever reaches the board.
--   defaults          PaladinBuffDefaults, backfilled to all six blessings,
--                     with the role's banned blessings below the divider.
--
-- What is deliberately absent is a per-profile override of a BUILT-IN role.
-- That used to exist (db.profile.roleCustomizations) and meant a raid could
-- hold as many blessing plans as it had clients; the store is gone and Core.lua
-- drops it on load. A built-in role is changed by overriding it for the raid,
-- or by copying it into a custom role of your own.
-- ---------------------------------------------------------------------------

local function PartitionBannedBuffs(order, banned)
    local allowed, blocked = {}, {}
    for _, key in ipairs(order) do
        local target = banned and banned[key] and blocked or allowed
        target[#target + 1] = key
    end
    local allowedCount = #allowed
    for _, key in ipairs(blocked) do allowed[#allowed + 1] = key end
    return allowed, allowedCount
end

local function FirstBuffs(order, count)
    local allowed = {}
    for i = 1, count do allowed[i] = order[i] end
    return allowed
end

-- The combined default role-id and Blizzard-role bans for a role/category.
-- A clone doesn't need its source's bans looked up here: cloning copies the
-- source's resolved order AND divider into the new role's own stored setup, so
-- the boundary comes across with it.
function WhoDoesWhat:GetBannedPaladinBuffs(roleId)
    local entry = self.RolesAndCategories[roleId]
    if not entry then return nil end
    if entry.allSubRoles then
        return self:GetBannedPaladinBuffs(entry.allSubRoles[1])
    end
    local byRole = self.PaladinBuffBansByRole[entry.id]
    local byWowRole = self.PaladinBuffBansByWowRole[entry.wowRole]
    if not byRole and not byWowRole then return nil end
    local banned = {}
    for key in pairs(byRole or {}) do banned[key] = true end
    for key in pairs(byWowRole or {}) do banned[key] = true end
    return banned
end

-- Full default order plus the number of entries above the END divider.
function WhoDoesWhat:GetDefaultBuffSetup(roleId)
    local _, entry = self:FindRoleById(roleId)
    if not entry then return nil end
    if entry.allSubRoles then
        return self:GetDefaultBuffSetup(entry.allSubRoles[1])
    end
    return PartitionBannedBuffs(
        self:BackfillBuffOrder(entry.buffOrder or self.CanonicalBuffOrder),
        self:GetBannedPaladinBuffs(entry.id))
end

-- Allowed portion of the default order (the assignment model's input).
function WhoDoesWhat:GetDefaultBuffOrder(roleId)
    local order, allowedCount = self:GetDefaultBuffSetup(roleId)
    return order and FirstBuffs(order, allowedCount) or nil
end

-- Full effective order plus divider position, most specific first: the board's
-- override, then a custom role's own stored order, then the defaults. A
-- category answers from its own override if it has one, and from its first
-- sub-role's setup if it does not.
function WhoDoesWhat:GetEffectiveBuffSetup(roleId)
    local _, entry = self:FindRoleById(roleId)
    if not entry then return nil end
    if entry.raidOrder then
        return entry.raidOrder, entry.raidAllowed
    end
    if entry.ownOrder then
        return entry.ownOrder, entry.ownAllowed
    end
    if entry.allSubRoles then
        return self:GetEffectiveBuffSetup(entry.allSubRoles[1])
    end
    return self:GetDefaultBuffSetup(entry.id)
end

-- Whether the RAID is overriding this role, directly or through its category.
function WhoDoesWhat:IsRoleOverridden(roleId)
    local entry = self.RolesAndCategories[roleId]
    return (entry and entry.raidOrder) ~= nil
end

-- Whether this role carries a blessing order of its own -- i.e. it is a custom
-- role somebody has tuned. Deliberately NOT true for a built-in role the raid
-- happens to be overriding: the Roles window is your own library, and what one
-- raid is doing tonight is not a property of the role.
function WhoDoesWhat:HasOwnBuffOrder(roleId)
    local entry = self.RolesAndCategories[roleId]
    return (entry and entry.ownOrder) ~= nil
end

-- Effective allowed order for assignment computation.
function WhoDoesWhat:GetEffectiveBuffOrder(roleId)
    local order, allowedCount = self:GetEffectiveBuffSetup(roleId)
    return order and FirstBuffs(order, allowedCount) or nil
end

-- A custom role is only well-formed with all three of a name, an owning class,
-- and a group role -- "unassigned" used to be allowed and is deliberately gone.
-- Without a wowRole the role can't drive the Blizzard group-role flag, and a
-- main tank switched onto one can't be recognised as no-longer-a-tank, so the
-- main-tank mark sticks until somebody clears it by hand. Enforced here as well
-- as in the editor so the invariant doesn't depend on which caller wrote it.
-- Returns nil (and explains) when the arguments don't satisfy it.
local function ValidateCustomRole(self, name, className, wowRole)
    if type(name) ~= "string" or strtrim(name) == "" then
        self:Print("A custom role needs a name.")
        return nil
    end
    if type(className) ~= "string" or className == "" then
        self:Print("A custom role needs a class.")
        return nil
    end
    if not self.BasicWowRoles[wowRole] then
        self:Print("A custom role needs a group role (Tank, Healer or DPS).")
        return nil
    end
    return strtrim(name)
end

-- The icons a custom role of this class may wear, in the order the picker shows
-- them: the class icon (the default, and always first), that class's own
-- built-in role icons, then the three micro group-role icons the rest of the UI
-- already uses. Deliberately a short curated list rather than the client's full
-- macro-icon set -- the point is to tell two custom roles apart at a glance,
-- not to browse thousands of textures. Deduped, because a class's category
-- icons reuse its class icon.
--
-- className may be nil (create mode before a class is picked); the role icons
-- are offered on their own until one is.
function WhoDoesWhat:CustomRoleIconChoices(className)
    local choices, seen = {}, {}
    local function Add(icon, label)
        if not icon or seen[icon] then return end
        seen[icon] = true
        choices[#choices + 1] = { icon = icon, label = label }
    end
    for _, classInfo in ipairs(self.Classes) do
        if classInfo.name == className then
            Add(classInfo.classIcon, classInfo.name)
            for _, role in ipairs(classInfo.roles) do
                Add(role.icon, role.name)
            end
            break
        end
    end
    for _, key in ipairs({ "tank", "healer", "dps" }) do
        Add(self:MakeRoleIcon(key), self.BasicWowRoles[key].name)
    end
    return choices
end

-- Store only a deliberate choice: an icon equal to the class default is saved
-- as nil, so the role keeps following its class rather than freezing a copy of
-- whatever the class icon happened to be.
function WhoDoesWhat:NormalizeCustomRoleIcon(className, icon)
    if not icon then return nil end
    for _, classInfo in ipairs(self.Classes) do
        if classInfo.name == className then
            return icon ~= classInfo.classIcon and icon or nil
        end
    end
    return icon
end

-- Mint a custom-role id. The counter alone keeps ids unique within a profile;
-- the random block is what keeps them unique BETWEEN profiles, which matters
-- because a published role is keyed by this id on every client in the raid.
-- Core.lua re-keys pre-1.0.7 counter-only ids once on load.
function WhoDoesWhat:NewCustomRoleId()
    local profile = self.db.profile
    profile.customRoleCounter = (profile.customRoleCounter or 0) + 1
    return string.format("custom_%06x_%d", math.random(0, 0xFFFFFF),
        profile.customRoleCounter)
end

-- Create a new custom role with the given display name, owning class (by
-- name), group role, and optional picked icon; persist and register it. Returns
-- the new RolesAndCategories entry, or nil when the arguments are incomplete.
function WhoDoesWhat:CreateCustomRole(name, className, wowRole, icon, buffOrder, allowedCount)
    name = ValidateCustomRole(self, name, className, wowRole)
    if not name then return nil end
    local profile = self.db.profile
    local id = self:NewCustomRoleId()
    buffOrder = self:BackfillBuffOrder(buffOrder)
    allowedCount = math.floor(tonumber(allowedCount) or #buffOrder)
    table.insert(profile.customRoles, { id = id, name = name, class = className,
        wowRole = wowRole, icon = self:NormalizeCustomRoleIcon(className, icon),
        order = { unpack(buffOrder) },
        allowed = math.max(0, math.min(allowedCount, #buffOrder)) })
    self:PopulateRolesAndCategories()
    return self.RolesAndCategories[id]
end

-- Clone a built-in role (or category) into a new custom role of the same class,
-- carrying its name, icon, group role and its whole blessing setup -- order and
-- divider both -- so the copy starts out behaving exactly like its source. This
-- is how you get a second Frost Mage: built-in roles themselves can't be
-- edited, only overridden for the raid or copied into something of your own.
function WhoDoesWhat:CloneRoleToCustom(roleId)
    local classInfo, role = self:FindRoleById(roleId)
    if not role or not classInfo or role.isCustom then
        self:Print("That role can't be copied.")
        return nil
    end
    -- A category has no single icon or group role of its own; take them from the
    -- sub-role its defaults already come from.
    local source = role
    if role.allSubRoles then
        source = self.RolesAndCategories[role.allSubRoles[1]] or role
    end
    local order, allowed = self:GetEffectiveBuffSetup(roleId)
    return self:CreateCustomRole(role.name .. " copy", classInfo.name,
        source.wowRole or "dps", source.icon, order, allowed)
end

-- Update an existing custom role's whole definition. Returns false when the new
-- values are incomplete, leaving the stored role untouched.
function WhoDoesWhat:UpdateCustomRole(roleId, name, wowRole, icon, buffOrder, allowedCount)
    for _, cr in ipairs(self.db.profile.customRoles) do
        if cr.id == roleId then
            local valid = ValidateCustomRole(self, name, cr.class, wowRole)
            if not valid then return false end
            cr.name = valid
            cr.wowRole = wowRole
            cr.icon = self:NormalizeCustomRoleIcon(cr.class, icon)
            buffOrder = self:BackfillBuffOrder(buffOrder)
            allowedCount = math.floor(tonumber(allowedCount) or #buffOrder)
            cr.order = { unpack(buffOrder) }
            cr.allowed = math.max(0, math.min(allowedCount, #buffOrder))
            break
        end
    end
    self:PopulateRolesAndCategories()
    -- An unpublished role's order feeds nothing shared, but a published one's
    -- library copy is what the next raid gets; repaint either way.
    self:RefreshMainAssignmentsView()
    self:RefreshBuffingGridView()
    return true
end

-- The local profile's stored definition for a custom role id, or nil. Callers
-- that want what a role LOOKS like should use RolesAndCategories instead; this
-- is for the raw saved fields, where an unset icon is meaningfully nil.
function WhoDoesWhat:FindLocalCustomRole(roleId)
    for _, cr in ipairs(self.db.profile.customRoles) do
        if cr.id == roleId then return cr end
    end
    return nil
end

-- Delete a custom role along with any saved customization for it.
function WhoDoesWhat:DeleteCustomRole(roleId)
    local profile = self.db.profile
    for i, cr in ipairs(profile.customRoles) do
        if cr.id == roleId then
            table.remove(profile.customRoles, i)
            break
        end
    end
    self:PopulateRolesAndCategories()
end

-- ---------------------------------------------------------------------------
-- The raid's custom roles (db.profile.raidCustomRoles)
--
-- A published custom role is a complete definition -- name, class, group role,
-- buff order and divider -- copied onto the shared board, where it is group
-- strategy exactly like paladinBuffRules: synced as STATE.customRoles, edited
-- under the same assignment permission, cleared on leave.
--
-- Publishing exists because the board already syncs role IDS. Without the
-- definition beside them, a raider assigned "custom_a41f0c_2" resolves to
-- nothing on everybody else's client: their blessing order silently falls back
-- to the canonical one, guarantee rules scoped by group role skip them, and
-- IsMarkedTank stops seeing a custom tank. The list is the missing half of a
-- reference the board was already making.
--
-- Edits land here and nowhere else. The library entry the role was published
-- from is left untouched, so it stays a reusable template rather than
-- something one raid night's edits quietly rewrite.
-- ---------------------------------------------------------------------------

-- Bounded because the whole list rides in every board snapshot. Well past any
-- real raid's needs; it exists so a stuck loop can't inflate the payload.
local MAX_RAID_CUSTOM_ROLES = 20

function WhoDoesWhat:GetRaidCustomRoles()
    return self.db.profile.raidCustomRoles
end

-- The published definition for a role id, plus its index, or nil.
function WhoDoesWhat:FindRaidCustomRole(roleId)
    for i, cr in ipairs(self:GetRaidCustomRoles()) do
        if cr.id == roleId then return cr, i end
    end
    return nil
end

-- Copy a local custom role onto the board, freezing its current effective buff
-- setup into the published definition. Idempotent: a role already on the list
-- is left as it is, because the raid's copy outranks the publisher's template.
-- Returns true when the role is on the list afterwards.
-- A board entry describes a custom role when it carries the role's identity;
-- an entry with only an id and an order is an override of a built-in role or
-- category, whose name, class, icon and group role come from the built-in.
function WhoDoesWhat:IsRaidCustomRoleDef(def)
    return def ~= nil and def.name ~= nil
end

local function RoomOnBoard(self)
    local list = self:GetRaidCustomRoles()
    if #list < MAX_RAID_CUSTOM_ROLES then return list end
    self:Print("The raid's custom role list is full (" .. MAX_RAID_CUSTOM_ROLES
        .. " roles). Remove one before adding another.")
    return nil
end

function WhoDoesWhat:PublishCustomRole(roleId)
    if self:FindRaidCustomRole(roleId) then return true end
    local source = self:FindLocalCustomRole(roleId)
    if not source then
        self:LogUiBuilding("PublishCustomRole: no local custom role " .. tostring(roleId))
        return false
    end
    local list = RoomOnBoard(self)
    if not list then return false end
    local order, allowed = self:GetEffectiveBuffSetup(roleId)
    order = order or self.CanonicalBuffOrder
    table.insert(list, {
        id = source.id,
        name = source.name,
        class = source.class,
        wowRole = source.wowRole or false,
        icon = source.icon,
        order = { unpack(order) },
        allowed = allowed or #order,
    })
    self:PopulateRolesAndCategories()
    self:LogOperation("Custom role '" .. source.name .. "' added to the raid.")
    return true
end

-- Put a built-in role or category on the board so the raid can retune its
-- blessing order. Seeded from that role's defaults, so adding one changes
-- nothing until somebody edits it. Only the id and the order are stored:
-- everything else about a built-in role is the same on every client.
function WhoDoesWhat:PublishRoleOverride(roleId)
    if self:FindRaidCustomRole(roleId) then return true end
    local _, role = self:FindRoleById(roleId)
    if not role or role.isCustom then
        self:LogUiBuilding("PublishRoleOverride: not a built-in role " .. tostring(roleId))
        return false
    end
    local list = RoomOnBoard(self)
    if not list then return false end
    -- FindRoleById resolves a one-role category to the role itself, so take the
    -- id the caller asked for rather than the resolved entry's: overriding
    -- "Warrior Tank" should read as that category on the board.
    local order, allowed = self:GetEffectiveBuffSetup(roleId)
    order = order or self.CanonicalBuffOrder
    table.insert(list, {
        id = roleId,
        order = { unpack(order) },
        allowed = allowed or #order,
    })
    self:PopulateRolesAndCategories()
    self:LogOperation("Role '" .. role.name .. "' overridden for the raid.")
    return true
end

-- Rewrite a published role in place. Only the board copy changes.
-- An override entry has no identity to rewrite, so name/wowRole/icon are
-- ignored for one and only the order is stored.
function WhoDoesWhat:UpdateRaidCustomRole(roleId, name, wowRole, icon, buffOrder, allowedCount)
    local def = self:FindRaidCustomRole(roleId)
    if not def then return false end
    buffOrder = self:BackfillBuffOrder(buffOrder)
    allowedCount = math.floor(tonumber(allowedCount) or #buffOrder)
    if self:IsRaidCustomRoleDef(def) then
        local valid = ValidateCustomRole(self, name, def.class, wowRole)
        if not valid then return false end
        def.name = valid
        def.wowRole = wowRole
        def.icon = self:NormalizeCustomRoleIcon(def.class, icon)
    end
    def.order = { unpack(buffOrder) }
    def.allowed = math.max(0, math.min(allowedCount, #buffOrder))
    self:PopulateRolesAndCategories()
    self:RefreshMainAssignmentsView()
    self:RefreshBuffingGridView()
    return true
end

-- Everyone currently assigned to a role id. The row's confirm prompt counts
-- them; removal clears them.
function WhoDoesWhat:PlayersAssignedToRole(roleId)
    local names = {}
    for player, id in pairs(self.db.profile.assignments) do
        if id == roleId then names[#names + 1] = player end
    end
    table.sort(names)
    return names
end

-- The unit token for a group member's name, so a role change can sync the
-- Blizzard group-role flag the way the unit menu does. Nil when they can't be
-- resolved; the assignment itself still writes fine without one.
function WhoDoesWhat:UnitForPlayer(name)
    if not name then return nil end
    local function Key(unit)
        local unitName, realm = UnitName(unit)
        if unitName and realm and realm ~= "" then
            return unitName .. "-" .. realm
        end
        return unitName
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            if Key("raid" .. i) == name then return "raid" .. i end
        end
        return nil
    end
    if Key("player") == name then return "player" end
    for i = 1, GetNumSubgroupMembers() do
        if Key("party" .. i) == name then return "party" .. i end
    end
    return nil
end

-- Take a role off the raid list, clearing it from anyone still assigned to it.
-- Leaving them on it would put them back in the state this whole list exists to
-- prevent -- holding a role id nobody else can resolve -- so they go back to no
-- role instead. Routed through SetAssignedRole so the Blizzard group-role flag
-- and any main-tank mark come off with it.
-- Removing an OVERRIDE only puts that role back on its defaults -- the role
-- itself is built in and still exists, so nobody loses an assignment. Removing
-- a custom role deletes the only definition of it the raid has, which is why
-- that path clears everyone who was on it.
function WhoDoesWhat:RemoveRaidCustomRole(roleId)
    local def, index = self:FindRaidCustomRole(roleId)
    if not def then return end
    local isCustom = self:IsRaidCustomRoleDef(def)
    local assigned = isCustom and self:PlayersAssignedToRole(roleId) or {}
    local label = isCustom and tostring(def.name)
        or (select(2, self:FindRoleById(roleId)) or {}).name or roleId
    table.remove(self:GetRaidCustomRoles(), index)
    self:PopulateRolesAndCategories()
    for _, name in ipairs(assigned) do
        self:SetAssignedRole(name, nil, self:UnitForPlayer(name))
    end
    self:LogOperation((isCustom and "Custom role '" or "Override of '")
        .. label .. "' removed from the raid"
        .. (#assigned > 0 and (", clearing " .. #assigned .. " assignment"
            .. (#assigned == 1 and "" or "s")) or "") .. ".")
end

-- Clear the whole list, one role at a time so each one's assignments are
-- cleared too. Returns how many roles came off.
function WhoDoesWhat:ClearRaidCustomRoles()
    local list = self:GetRaidCustomRoles()
    local removed = #list
    while #list > 0 do
        self:RemoveRaidCustomRole(list[1].id)
    end
    return removed
end

-- Whether assigning this role is safe for the rest of the raid to resolve, and
-- publish it if it isn't yet. Solo, nothing needs publishing: the library is
-- what pickers offer and nobody else is reading. Returns false only when the
-- role can't be made shareable, having already said why.
function WhoDoesWhat:EnsureRoleIsShareable(roleId)
    if not roleId or not IsInGroup() then return true end
    -- Fake Raid is solo tooling, so IsInGroup already covers it: nothing is
    -- listening and the library entry resolves fine on the only client there is.
    local entry = self.RolesAndCategories[roleId]
    if not entry or not entry.isCustom or entry.isRaid then return true end
    if not self:CanEditAssignments() then
        self:Print("'" .. tostring(entry.name) .. "' is one of your own custom roles"
            .. " and is not part of this raid's list yet. Somebody who can edit"
            .. " assignments has to add it in the main window's Custom Roles section.")
        return false
    end
    return self:PublishCustomRole(roleId)
end

-- Sort rank for a player's assigned role WITHIN their class, so same-role
-- players clump when a list is ordered class > role > name. The rank is the
-- role's position in the class's own role list (class-definition order, e.g.
-- Warrior Fury/Arms/Tank), with custom roles after the built-ins and anything
-- roleless/unresolved sorted last. Class ordering is handled by the caller.
function WhoDoesWhat:RoleSortRank(playerName)
    local roleId = self:GetAssignedRole(playerName)
    if not roleId then return math.huge end
    local classInfo = self.RolesAndCategories[roleId] and self.RolesAndCategories[roleId].classInfo
    if not classInfo then return math.huge end
    for i, role in ipairs(classInfo.roles) do
        if role.id == roleId then return i end
    end
    if classInfo.customRoles then
        for i, role in ipairs(classInfo.customRoles) do
            if role.id == roleId then return 100 + i end
        end
    end
    return math.huge
end

-- Instantly find a role or category by ID
function WhoDoesWhat:FindRoleById(roleId)
    local entry = self.RolesAndCategories[roleId]
    if not entry then
        self:LogUiBuilding("FindRoleById: Failed to find role/category with ID: " .. tostring(roleId))
        return nil, nil
    end

    -- Keep the functionality of a category returning a single role if the length of allSubRoles is 1
    if self:IsRoleASingleRoleCategory(roleId) then
        return self:FindRoleById(entry.allSubRoles[1])
    end

    return entry.classInfo, entry
end
