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
-- running and, while tanking, Righteous Fury. Display order is the aura
-- swapper's rotation order.
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
    { key = "fireResist",    spellId = 19891, name_short = "Fire" },
    { key = "frostResist",   spellId = 19888, name_short = "Frost" },
    { key = "shadowResist",  spellId = 19876, name_short = "Shadow" },
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
    "pallyPower", "paladinBuffs", "gift",
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
        -- Being a shaman does not make you responsible for other people's
        -- Sated: the debuff is the cooldown, not a job left undone.
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

-- Saved order is a full list so newly-added checks can be appended safely.
function WhoDoesWhat:GetStatusBarCheckOrder()
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
    return order
end

function WhoDoesWhat:GetStatusBarCheckOptions(key)
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
    -- Only offered on class-based checks (see responsibleGlow in
    -- hiddenOptions); the status view still decides whether the local player
    -- is the one on the hook.
    local responsibleGlow = saved.responsibleGlow ~= false
    return {
        bar = bar,
        grid = grid,
        scope = saved.scope or "always",
        display = display,
        hideComplete = hideComplete,
        hideColumnComplete = hideColumnComplete,
        bestAvailable = bestAvailable,
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
        hideWhenSynced = hideWhenSynced,
        hideWhenInactive = hideWhenInactive,
        assignmentIssuesGlow = saved.assignmentIssuesGlow ~= false,
    }
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

    -- Register user-created custom roles (from the saved profile) inside their
    -- assigned class's role list (classInfo.customRoles, appended after the
    -- regular roles by the All Roles view and never collapsed into categories).
    -- They always use the "?" icon and default to the canonical buff order.
    local classByName = {}
    for _, classInfo in ipairs(self.Classes) do
        classInfo.customRoles = nil
        classByName[classInfo.name] = classInfo
    end
    local customRoles = self.db and self.db.profile.customRoles or {}
    for _, cr in ipairs(customRoles) do
        local classInfo = classByName[cr.class]
        if classInfo then
            local entry = {
                name = cr.name,
                icon = 134400, -- INV_Misc_QuestionMark
                id = cr.id,
                isCustom = true,
                wowRole = cr.wowRole or false,
                classInfo = classInfo,
            }
            self.RolesAndCategories[cr.id] = entry
            classInfo.customRoles = classInfo.customRoles or {}
            table.insert(classInfo.customRoles, entry)
        else
            self:LogUiBuilding("Custom role '" .. tostring(cr.name) .. "' skipped: unknown class " .. tostring(cr.class))
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
-- Role customization storage (db.profile.roleCustomizations + customRoles)
--
-- The DB only ever holds deviations from the defaults: saving a buff order
-- that matches a role's defaults deletes its entry, and a role with no entry
-- is "on defaults". Custom roles live in db.profile.customRoles and default
-- to the canonical order with any Blizzard-role bans below its divider.
-- ---------------------------------------------------------------------------

-- Shallow-compare two buff order arrays.
function WhoDoesWhat:BuffOrdersEqual(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

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
    return PartitionBannedBuffs(self:BackfillBuffOrder(entry.buffOrder or self.CanonicalBuffOrder),
        self:GetBannedPaladinBuffs(entry.id))
end

-- Allowed portion of the default order (the assignment model's input).
function WhoDoesWhat:GetDefaultBuffOrder(roleId)
    local order, allowedCount = self:GetDefaultBuffSetup(roleId)
    return order and FirstBuffs(order, allowedCount) or nil
end

-- Full effective order plus divider position. Legacy saves without an
-- allowedCount receive the current default bans; new saves own their boundary.
function WhoDoesWhat:GetEffectiveBuffSetup(roleId)
    local _, entry = self:FindRoleById(roleId)
    if not entry then return nil end
    if entry.allSubRoles then
        return self:GetEffectiveBuffSetup(entry.allSubRoles[1])
    end
    local saved = self.db.profile.roleCustomizations[entry.id]
    if saved then
        local order = self:BackfillBuffOrder(saved.buffOrder)
        if saved.allowedCount ~= nil then
            local allowedCount = math.floor(tonumber(saved.allowedCount) or #order)
            return order, math.max(0, math.min(allowedCount, #order))
        end
        return PartitionBannedBuffs(order, self:GetBannedPaladinBuffs(entry.id))
    end
    return self:GetDefaultBuffSetup(entry.id)
end

-- Effective allowed order for assignment computation.
function WhoDoesWhat:GetEffectiveBuffOrder(roleId)
    local order, allowedCount = self:GetEffectiveBuffSetup(roleId)
    return order and FirstBuffs(order, allowedCount) or nil
end

-- Whether a role has a saved customization. A category counts as customized
-- when any of its sub-roles is.
function WhoDoesWhat:IsRoleCustomized(roleId)
    local entry = self.RolesAndCategories[roleId]
    if not entry then return false end
    if entry.allSubRoles then
        for _, subId in ipairs(entry.allSubRoles) do
            if self.db.profile.roleCustomizations[subId] then return true end
        end
        return false
    end
    return self.db.profile.roleCustomizations[roleId] ~= nil
end

-- Save a buff-order customization for one concrete role id (categories fan out
-- at the call site). If the order matches the role's own default, the saved
-- entry is removed instead. Returns true when a customization was stored,
-- false when the role is (back) on defaults.
function WhoDoesWhat:SetRoleCustomization(roleId, buffOrder, allowedCount)
    local entry = self.RolesAndCategories[roleId]
    if not entry or entry.allSubRoles then
        self:LogUiBuilding("SetRoleCustomization: invalid role id " .. tostring(roleId))
        return false
    end
    buffOrder = self:BackfillBuffOrder(buffOrder)
    allowedCount = math.floor(tonumber(allowedCount) or #buffOrder)
    allowedCount = math.max(0, math.min(allowedCount, #buffOrder))
    local defaultOrder, defaultAllowedCount = self:GetDefaultBuffSetup(roleId)
    if allowedCount == defaultAllowedCount and self:BuffOrdersEqual(buffOrder, defaultOrder) then
        self.db.profile.roleCustomizations[roleId] = nil
        -- Buff priorities feed both assignment demand and the live Paladin plan.
        self:RefreshMainAssignmentsView()
        self:RefreshBuffingGridView()
        return false
    end
    self.db.profile.roleCustomizations[roleId] = {
        buffOrder = { unpack(buffOrder) },
        allowedCount = allowedCount,
    }
    self:RefreshMainAssignmentsView()
    self:RefreshBuffingGridView()
    return true
end

-- Remove any saved customization for a role (or, for a category, all of its
-- sub-roles), putting them back on their defaults.
function WhoDoesWhat:ClearRoleCustomization(roleId)
    local entry = self.RolesAndCategories[roleId]
    if not entry then return end
    for _, id in ipairs(entry.allSubRoles or { roleId }) do
        self.db.profile.roleCustomizations[id] = nil
    end
    -- Buff priorities feed both assignment demand and the live Paladin plan.
    self:RefreshMainAssignmentsView()
    self:RefreshBuffingGridView()
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

-- Create a new custom role with the given display name, owning class (by
-- name), and group role; persist and register it. Returns the new
-- RolesAndCategories entry, or nil when the arguments are incomplete.
function WhoDoesWhat:CreateCustomRole(name, className, wowRole)
    name = ValidateCustomRole(self, name, className, wowRole)
    if not name then return nil end
    local profile = self.db.profile
    profile.customRoleCounter = (profile.customRoleCounter or 0) + 1
    local id = "custom_" .. profile.customRoleCounter
    table.insert(profile.customRoles, { id = id, name = name, class = className, wowRole = wowRole })
    self:PopulateRolesAndCategories()
    return self.RolesAndCategories[id]
end

-- Update an existing custom role's display name and group role. Returns false
-- when the new values are incomplete, leaving the stored role untouched.
function WhoDoesWhat:UpdateCustomRole(roleId, name, wowRole)
    for _, cr in ipairs(self.db.profile.customRoles) do
        if cr.id == roleId then
            local valid = ValidateCustomRole(self, name, cr.class, wowRole)
            if not valid then return false end
            cr.name = valid
            cr.wowRole = wowRole
            break
        end
    end
    self:PopulateRolesAndCategories()
    return true
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
    profile.roleCustomizations[roleId] = nil
    self:PopulateRolesAndCategories()
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
