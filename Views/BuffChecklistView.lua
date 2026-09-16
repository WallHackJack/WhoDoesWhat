local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local Assign = WhoDoesWhat.Assign

-- The Buff Checklist: a movable grid of every buff YOUR character should be
-- wearing -- the blessings the active plan gives you, the class buffs and food
-- Buff Tracking checks for, your party's shouts (Assign.GetPlayerBuffChecklist
-- decides which), a battle and a guardian elixir (TBC), and a temporary
-- enchant on each weapon you wield. An icon in full colour is on you; a grey
-- one glowing amber is missing; a blue glow with a countdown is about to drop.
--
-- Shift-click asks for a missing buff: a whisper to whoever should cast it, or
-- party chat for a shout. Food, elixirs and weapon enchants are yours to
-- supply, so instead they carry a picker -- the "trundle": left-click opens it
-- to choose which food, elixir, flask, oil, stone or poison from your bags,
-- and right-click uses that choice (eats or drinks it, or applies it to that
-- weapon). Flasks are offered for both elixir slots and fill both. Physical
-- damage roles also get a Scroll of Agility and a Scroll of Strength slot,
-- each picking a rank. An elixir or scroll that is up but isn't the pick wears
-- the expiring glow. A weapon can also be told to
-- stay bare, for melee hoping for Windfury: right-click then strips whatever
-- enchant is on it, and Windfury itself counts as bare. A picked consumable's
-- icon carries how many are left in its corner.
--
-- A paladin gets an aura swapper, a hunter an aspect swapper, and a mage or
-- warlock an armor swapper: left-click opens a secure menu where picking one
-- casts it, right-click recasts the pick. Self-buffs cast by hand get an icon
-- each, right-click to cast: Omen of Clarity and Trueshot Aura for whoever has
-- the talent, Inner Fire for priests, Righteous Fury for a tanking paladin.
--
-- A hunter's grid gains a second section for the pet (Assign.
-- GetPetBuffChecklist) under a divider reading "Pet (covered/total)", or a red
-- "Pet Not Summoned". Clicking the divider collapses the pet's icons.
--
-- Right-click using an item is a protected action, so the grid's icons are
-- secure buttons. That brings the Shout Bar's combat discipline with it: a
-- secure button cannot be created, shown, hidden, moved or re-pointed mid-
-- fight, so in combat this file repaints icons, glows and countdowns only, and
-- PLAYER_REGEN_ENABLED settles the layout. The item pickers' rows use items on
-- right-click too, so they are secure as well: one per slot, laid out ahead of
-- time out of combat and opened by a secure snippet, so they work mid-fight.
--
-- Wraps into rows at the configured column count. With "Hide buffs I have" on
-- the grid shrinks to what is still missing or expiring, and with nothing left
-- to show the window hides altogether.

local frame = nil
-- Defined in the picker section, used by the button section after it.
local ItemUseAction
-- Defined in the swap menu section, needed by the pickers before it.
local EnsureSwapMenu
-- Set by the loader at the bottom of the file: a refresh a moment from now.
local RequestChecklistRefresh = nil
local swapMenu = nil
local divider = nil

local INSET = 3
local PAD = 3
local GAP = 4
-- The optional header strip, the Paladin Bar's height and colour.
local TITLE_H = 12
local TITLE_TEXT_PAD = 6
WhoDoesWhat.BUFF_CHECKLIST_ICON_SIZE = { min = 16, max = 64, default = 28 }
WhoDoesWhat.BUFF_CHECKLIST_COLUMNS = { min = 1, max = 12, default = 6 }

-- A buff this close to dropping glows in the expiring colour and counts down
-- on its icon. Minutes, from the same choices as the Paladin Bar's "Warn
-- below" (BuffingWarnMinutes); 6 unless set.
local DEFAULT_WARN_MINUTES = 6

function WhoDoesWhat:GetBuffChecklistWarnMinutes()
    local saved = self.db.profile.settings.buffChecklistWarnMinutes
    for _, minutes in ipairs(self.BuffingWarnMinutes) do
        if minutes == saved then return saved end
    end
    return DEFAULT_WARN_MINUTES
end

local function WarnSeconds()
    return WhoDoesWhat:GetBuffChecklistWarnMinutes() * 60
end

-- The glow is the status bars' highlight styles in this checklist's own two
-- colours, all three settings. These are only reached if one has gone missing
-- from the profile. "Missing" is a buff that wants fixing; "expiring" is one
-- inside the warning time above.
local DEFAULT_GLOW_STYLE = "flash"
local MISSING_GLOW_COLOR = { r = 0.949, g = 0.71, b = 0 }
local EXPIRING_GLOW_COLOR = { r = 0.157, g = 0.561, b = 1 }

-- The wing styles aren't offered here (the grid has no room beside its
-- icons), so one saved before that was the case falls back to the default.
function WhoDoesWhat:GetBuffChecklistGlowStyle()
    local saved = self.db.profile.settings.buffChecklistGlowStyle
    local styles = self:GetStatusBarHighlightStyles()
    if not saved or not styles[saved] or styles[saved].wings then
        return DEFAULT_GLOW_STYLE
    end
    return saved
end

function WhoDoesWhat:GetBuffChecklistGlowColor(which)
    local settings = self.db.profile.settings
    if which == "expiring" then
        return settings.buffChecklistGlowExpiringColor or EXPIRING_GLOW_COLOR
    end
    return settings.buffChecklistGlowMissingColor or MISSING_GLOW_COLOR
end
local TIMER_FONT_RATIO = 16 / 28
local FALLBACK_FONT = "Fonts\\FRIZQT__.TTF"

local function Clamp(value, range)
    value = tonumber(value) or range.default
    return math.floor(math.max(range.min, math.min(range.max, value)) + 0.5)
end

function WhoDoesWhat:GetBuffChecklistIconSize()
    return Clamp(self.db.profile.settings.buffChecklistIconSize,
        self.BUFF_CHECKLIST_ICON_SIZE)
end

function WhoDoesWhat:GetBuffChecklistColumns()
    return Clamp(self.db.profile.settings.buffChecklistColumns,
        self.BUFF_CHECKLIST_COLUMNS)
end

-- ---------------------------------------------------------------------------
-- Position (Alt-drag)
-- ---------------------------------------------------------------------------

-- Left or Right: which top corner holds still as the grid changes width, and
-- which corner the grid starts from (Right mirrors it, filling leftwards from
-- the top-right). Encoded as the saved anchor point, like
-- the Shout Bar's anchor, so a stored position describes itself.
local ALIGN_POINTS = { LEFT = "TOPLEFT", RIGHT = "TOPRIGHT" }
WhoDoesWhat.BuffChecklistAligns = {
    { key = "LEFT", label = "Left" },
    { key = "RIGHT", label = "Right" },
}

function WhoDoesWhat:GetBuffChecklistAlign()
    local align = self.db.profile.settings.buffChecklistAlign
    return ALIGN_POINTS[align] and align or "RIGHT"
end

function WhoDoesWhat:GetBuffChecklistAlignLabel(align)
    for _, entry in ipairs(self.BuffChecklistAligns) do
        if entry.key == align then return entry.label end
    end
end

local function SavePosition()
    local pos = UI.SavePoint(frame, ALIGN_POINTS[WhoDoesWhat:GetBuffChecklistAlign()])
    if pos then WhoDoesWhat.db.profile.settings.buffChecklistPos = pos end
end

-- Moving a frame that parents secure buttons is forbidden mid-fight; the
-- callers that could land in combat check before calling this.
local function LoadPosition()
    local pos = WhoDoesWhat.db.profile.settings.buffChecklistPos
    if pos then pos.point = pos.point == "TOPRIGHT" and "TOPRIGHT" or "TOPLEFT" end
    UI.RestorePoint(frame, pos)
end

-- Re-anchor to the new corner without visually moving the window: save the
-- current rect under the new point, then load it straight back.
function WhoDoesWhat:SetBuffChecklistAlign(align)
    self.db.profile.settings.buffChecklistAlign = align
    if frame and frame:IsShown() and frame:GetLeft() and not InCombatLockdown() then
        SavePosition()
        LoadPosition()
    end
    self:RefreshBuffChecklist()
end

-- Where the pop-out menus (the item picker and the aura/aspect menu) open
-- against the icon that opened them. The four straight directions centre on
-- the icon; the diagonals meet it corner to corner, which is what keeps a menu
-- off the rest of the grid when the checklist sits against a screen edge.
-- x and y say which way the small gap goes.
local POPOUT_GAP = 2
WhoDoesWhat.BuffChecklistPopoutDirections = {
    { key = "ABOVE", label = "Above", point = "BOTTOM", rel = "TOP", x = 0, y = 1 },
    { key = "BELOW", label = "Below", point = "TOP", rel = "BOTTOM", x = 0, y = -1 },
    { key = "LEFT", label = "Left", point = "RIGHT", rel = "LEFT", x = -1, y = 0 },
    { key = "RIGHT", label = "Right", point = "LEFT", rel = "RIGHT", x = 1, y = 0 },
    { key = "ABOVELEFT", label = "Above Left", point = "BOTTOMRIGHT", rel = "TOPLEFT",
      x = -1, y = 1 },
    { key = "ABOVERIGHT", label = "Above Right", point = "BOTTOMLEFT", rel = "TOPRIGHT",
      x = 1, y = 1 },
    { key = "BELOWLEFT", label = "Below Left", point = "TOPRIGHT", rel = "BOTTOMLEFT",
      x = -1, y = -1 },
    { key = "BELOWRIGHT", label = "Below Right", point = "TOPLEFT", rel = "BOTTOMRIGHT",
      x = 1, y = -1 },
}
local DEFAULT_POPOUT_DIRECTION = "BELOWLEFT"

function WhoDoesWhat:GetBuffChecklistPopoutDirection()
    local saved = self.db.profile.settings.buffChecklistPopoutDirection
    local fallback
    for _, direction in ipairs(self.BuffChecklistPopoutDirections) do
        if direction.key == saved then return direction end
        if direction.key == DEFAULT_POPOUT_DIRECTION then fallback = direction end
    end
    return fallback
end

-- ---------------------------------------------------------------------------
-- Items: bags, weapons, tooltips
-- ---------------------------------------------------------------------------

local GetContainerNumSlots = C_Container and C_Container.GetContainerNumSlots
    or GetContainerNumSlots
local GetContainerItemID = C_Container and C_Container.GetContainerItemID
    or GetContainerItemID
local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
local GetItemInfo = GetItemInfo or C_Item.GetItemInfo
local GetItemIcon = GetItemIcon or C_Item.GetItemIconByID
local GetItemCount = GetItemCount or C_Item.GetItemCount
local GetItemSpell = GetItemSpell or C_Item.GetItemSpell
local ITEM_CLASS_WEAPON = 2
local WINDFURY_ICON = "Interface\\Icons\\Spell_Nature_Windfury"

-- hand is GetWeaponEnchantInfo's 1 or 2; slot is the inventory slot, which the
-- secure "cancelaura" action takes as target-slot.
local WEAPON_SLOTS = {
    { key = "mainHand", slot = 16, hand = 1, name = "Main Hand" },
    { key = "offHand", slot = 17, hand = 2, name = "Off Hand" },
}

-- Item id -> true for the weapon pickers, and the enchant id each puts on a
-- weapon -> its item id.
local weaponItems, itemByEnchant = {}, {}
for _, pair in ipairs(WhoDoesWhat.WeaponEnchantItems) do
    weaponItems[pair[1]] = true
    itemByEnchant[pair[2]] = pair[1]
end

local function Picks()
    return WhoDoesWhat.db.char.buffChecklistItems
end

-- Item ids whose names were asked for and haven't arrived; the checklist
-- repaints when one does (GET_ITEM_INFO_RECEIVED).
local pendingItemNames = {}

local function KnownItemName(id)
    return GetItemInfo(id)
        or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
end

local function ItemName(id)
    local name = KnownItemName(id)
    if name then return name end
    if not pendingItemNames[id] then
        pendingItemNames[id] = true
        if C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(id)
        end
    end
    return "Gathering Data... (" .. id .. ")"
end

-- The consumable slots that fill from an aura: two elixir slots (TBC only;
-- ElixirItems is nil on Classic Era), whose pickers list their own category
-- plus flasks, which fill both; and two scroll slots (ScrollItems), one per
-- scroll family, each picker listing that family's ranks.
local ELIXIR_SLOTS = {
    { key = "battleElixir", category = "battle", name = "Battle Elixir",
      defaultIcon = 22831 }, -- Elixir of Major Agility
    { key = "guardianElixir", category = "guardian", name = "Guardian Elixir",
      defaultIcon = 32067 }, -- Elixir of Draenic Wisdom
}
-- petKey is the pick for the pet section's copy of the slot.
local SCROLL_SLOTS = {
    { key = "agilityScroll", petKey = "petAgilityScroll", category = "agility",
      name = "Scroll of Agility", defaultIcon = 3012 }, -- Scroll of Agility
    { key = "strengthScroll", petKey = "petStrengthScroll", category = "strength",
      name = "Scroll of Strength", defaultIcon = 954 }, -- Scroll of Strength
}

-- item id -> category ("battle" / "guardian" / "flask" / "agility" /
-- "strength"), and per picker which ids it offers.
local consumableCategory, consumableChoices = {}, {}
for category, ids in pairs(WhoDoesWhat.ElixirItems or {}) do
    for _, id in ipairs(ids) do consumableCategory[id] = category end
end
for category, ids in pairs(WhoDoesWhat.ScrollItems or {}) do
    for _, id in ipairs(ids) do consumableCategory[id] = category end
end
for _, slots in ipairs({ ELIXIR_SLOTS, SCROLL_SLOTS }) do
    for _, slot in ipairs(slots) do
        consumableChoices[slot.key] = {}
        for id, category in pairs(consumableCategory) do
            if category == slot.category
                or (category == "flask" and slots == ELIXIR_SLOTS) then
                consumableChoices[slot.key][id] = true
            end
        end
        if slot.petKey then consumableChoices[slot.petKey] = consumableChoices[slot.key] end
    end
end

-- A consumable's aura is its use-spell, so the category of an aura on you is
-- found by resolving each listed item's spell. Item data loads on demand, so
-- ids not answered yet are asked for again on the next pass.
--
-- Matched by spell id. Names are only a fallback for a client that hands out
-- no ids, because they collide: Elixir of Agility's aura and every Scroll of
-- Agility's are all just "Agility", which is how scrolls were landing in the
-- battle elixir slot.
local consumableBySpellId, consumableBySpellName = {}, {}
local unresolvedConsumables = {}
for id in pairs(consumableCategory) do unresolvedConsumables[id] = true end

local function ResolveConsumableSpells()
    for id in pairs(unresolvedConsumables) do
        local name, spellId = GetItemSpell(id)
        if name then
            consumableBySpellName[name] = consumableCategory[id]
            if spellId then consumableBySpellId[spellId] = consumableCategory[id] end
            unresolvedConsumables[id] = nil
        elseif C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(id)
        end
    end
end

-- Your own buffs (or your pet's, with unit "pet"), scanned once per pass for
-- everything here that BuffTracking doesn't follow (elixirs, scrolls, aura,
-- aspect, Omen of Clarity): an array of { name, icon, remaining, spellId },
-- plus the same records by name.
local GetBuffDataByIndex = C_UnitAuras and C_UnitAuras.GetBuffDataByIndex
local function OwnBuffs(unit)
    unit = unit or "player"
    local list, byName = {}, {}
    for i = 1, 40 do
        local name, icon, duration, expirationTime, spellId
        if GetBuffDataByIndex then
            local aura = GetBuffDataByIndex(unit, i)
            if not aura then break end
            name, icon, duration, expirationTime, spellId = aura.name, aura.icon,
                aura.duration, aura.expirationTime, aura.spellId
        else
            local _
            name, icon, _, _, duration, expirationTime, _, _, _, spellId =
                UnitBuff(unit, i)
            if not name then break end
        end
        local buff = {
            name = name, icon = icon, spellId = spellId,
            duration = duration, expirationTime = expirationTime,
            remaining = expirationTime and expirationTime > 0
                and expirationTime - GetTime() or nil,
        }
        list[#list + 1] = buff
        byName[name] = buff
    end
    return list, byName
end

-- category -> the OwnBuffs record filling it. A flask fills both "battle"
-- and "guardian".
local function ActiveConsumables(buffs)
    if next(unresolvedConsumables) then ResolveConsumableSpells() end
    local byIds = next(consumableBySpellId) ~= nil
    local active = {}
    for _, buff in ipairs(buffs) do
        local category
        if buff.spellId and byIds then
            category = consumableBySpellId[buff.spellId]
        else
            category = consumableBySpellName[buff.name]
        end
        if category == "flask" then
            active.battle, active.guardian = buff, buff
        elseif category then
            active[category] = buff
        end
    end
    return active
end

-- The options in a spell list this character can cast, less any a known
-- later spell `replaces` (Ice Armor over Frost Armor). A name lookup only
-- answers for spells in your spellbook.
local function KnownSpells(list)
    local known, superseded = {}, {}
    for _, spell in ipairs(list) do
        if GetSpellInfo(spell.name) then
            known[#known + 1] = spell
            if spell.replaces then superseded[spell.replaces] = true end
        end
    end
    local out = {}
    for _, spell in ipairs(known) do
        if not superseded[spell.key] then out[#out + 1] = spell end
    end
    return out
end

-- The swapper a class gets: one self-buff out of a set, where picking one
-- casts it. `List` is what this character can cast right now.
-- Which demon is out, as a WhoDoesWhat.WarlockDemons entry: matched by the
-- creature id in the pet's GUID, which no locale changes. Nil with no pet, a
-- dead one, or anything else (an enslaved demon).
local function RunningDemon(options)
    if not UnitExists("pet") or UnitIsDead("pet") then return nil end
    local guid = UnitGUID("pet")
    local npcId = guid and tonumber((select(6, strsplit("-", guid))))
    for _, demon in ipairs(options) do
        if demon.npcId == npcId then return demon end
    end
    return nil
end

-- The swappers a class gets, in grid order. `Running` says which option is up
-- when that isn't just a buff of the option's name (a demon is a pet).
local SWAPPERS = {
    PALADIN = { {
        key = "aura", name = "Aura", noun = "aura",
        List = function() return WhoDoesWhat:GetKnownPaladinAuras() end,
    } },
    HUNTER = { {
        key = "aspect", name = "Aspect", noun = "aspect",
        List = function() return KnownSpells(WhoDoesWhat.HunterAspects) end,
    } },
    MAGE = { {
        key = "mageArmor", name = "Armor", noun = "armor",
        List = function() return KnownSpells(WhoDoesWhat.MageArmors) end,
    } },
    WARLOCK = { {
        key = "warlockArmor", name = "Armor", noun = "armor",
        List = function() return KnownSpells(WhoDoesWhat.WarlockArmors) end,
    }, {
        key = "demon", name = "Demon", noun = "demon",
        List = function() return KnownSpells(WhoDoesWhat.WarlockDemons) end,
        Running = RunningDemon,
    } },
}

-- Item id sets for the food, pet food and alcohol pickers.
local function ItemSet(ids)
    local set = {}
    for _, id in ipairs(ids or {}) do set[id] = true end
    return set
end
local pickerItems = {
    food = ItemSet(WhoDoesWhat.BuffFoodItems),
    petFood = ItemSet(WhoDoesWhat.PetBuffFoodItems),
    alcohol = ItemSet(WhoDoesWhat.AlcoholItems),
}

-- Distinct item ids in your bags a picker offers, by name. `kind` is "food",
-- "petFood", "alcohol", an elixir slot key, or a weapon slot key for the
-- weapon enchant list.
--
-- The bags themselves are walked once and kept (bagItems) until they change:
-- every picker is refilled on every refresh, and walking every slot once per
-- picker per refresh was the costly part. BAG_UPDATE_DELAYED clears it.
local bagItems = nil
local function BagItems()
    if bagItems then return bagItems end
    bagItems = {}
    local seen = {}
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, GetContainerNumSlots(bag) or 0 do
            local id = GetContainerItemID(bag, slot)
            if id and not seen[id] then
                seen[id] = true
                bagItems[#bagItems + 1] = { id = id, bag = bag, slot = slot }
            end
        end
    end
    return bagItems
end

local function BagChoices(kind)
    local out = {}
    for _, item in ipairs(BagItems()) do
        local id = item.id
        local wanted
        if pickerItems[kind] then
            wanted = pickerItems[kind][id]
        elseif consumableChoices[kind] then
            wanted = consumableChoices[kind][id]
        else
            wanted = weaponItems[id] and GetItemSpell(id) ~= nil
        end
        if wanted then out[#out + 1] = id end
    end
    table.sort(out, function(a, b) return ItemName(a) < ItemName(b) end)
    return out
end

-- Holding an actual weapon there -- not empty, not a shield or an off-hand
-- frill, neither of which takes an oil.
local function WieldsWeapon(slot)
    local id = GetInventoryItemID("player", slot)
    if not id then return false end
    local _, _, _, _, _, classID = GetItemInfoInstant(id)
    return classID == ITEM_CLASS_WEAPON
end

-- { enchanted, expirationMs, enchantID } per hand. Clients before the enchant
-- ids were added return six values rather than eight.
local function WeaponEnchantState()
    local count = select("#", GetWeaponEnchantInfo())
    local a, b, c, d, e, f, g, h = GetWeaponEnchantInfo()
    if count >= 8 then
        return { a, b, d }, { e, f, h }
    end
    return { a, b }, { d, e }
end

-- Enchant id -> true for the totem's and the shaman's own Windfury.
local windfuryEnchants = {}
for _, id in ipairs(WhoDoesWhat.WindfuryEnchantIDs) do windfuryEnchants[id] = true end

-- Enchant id -> the shaman imbue it is.
local imbueByEnchant = {}
for _, imbue in ipairs(WhoDoesWhat.ShamanImbues or {}) do
    for _, id in ipairs(imbue.enchantIDs) do imbueByEnchant[id] = imbue end
end

-- Whether a shaman is in your party -- your raid subgroup, or the whole group
-- outside a raid -- the same scope the Shout Bar counts warriors in.
local function PartyHasShaman()
    local party = Assign.PartyNames()
    for _, name in ipairs(Assign.MembersOfClass("Shaman")) do
        if not party or party[name] then return true end
    end
    return false
end

local function ApplyPick(entry, pick)
    if not pick then return end
    entry.useItem = pick
    entry.useCount = GetItemCount(pick)
    entry.icon = GetItemIcon(pick) or entry.icon
end

-- Grid order: what you cast on yourself (aura, aspect, Omen of Clarity), then
-- weapon enchants, food, elixirs, scrolls, blessings, and everything else
-- (class buffs, shouts). Within a group the order things were collected in
-- stands, so main hand stays ahead of off hand.
local function EntryGroup(entry)
    if entry.swap or entry.castSpell then return 1 end
    if entry.slot then return 2 end
    if entry.key == "food" or entry.key == "alcohol" then return 3 end
    if entry.id:find("elixir:", 1, true) then return 4 end
    if entry.id:find("scroll:", 1, true) then return 5 end
    if entry.id:find("blessing:", 1, true) then return 6 end
    return 7
end

local function SortEntries(list)
    for i, entry in ipairs(list) do
        entry.sortGroup, entry.sortIndex = EntryGroup(entry), i
    end
    table.sort(list, function(a, b)
        if a.sortGroup ~= b.sortGroup then return a.sortGroup < b.sortGroup end
        return a.sortIndex < b.sortIndex
    end)
end

-- The aura you sit in while eating (the base Food spell's name, so every food
-- shares it), and how long it takes to become Well Fed on TBC.
local FOOD_AURA_NAME = GetSpellInfo(433) or "Food"
local EAT_SECONDS = 10

-- The self-buffs a class casts by hand, one icon each: right-click casts it.
--   talent    granted by a talent of the same name, so the talent tree is
--             asked (a name lookup would find it talented or not)
--   toggles   a form or aura a second cast might cancel: cast as "/cast !Name",
--             which only ever turns it on
--   tankOnly  only while you're marked as a tank -- the Paladin Bar's
--             Righteous Fury rule
-- Anything else shows once the spell is in your spellbook.
local SELF_CASTS = {
    DRUID = { { key = "omen", spell = WhoDoesWhat.OmenOfClarity, talent = true } },
    PRIEST = {
        { key = "innerFire", spell = WhoDoesWhat.InnerFire },
        { key = "shadowform", spell = WhoDoesWhat.Shadowform, talent = true,
          toggles = true },
    },
    PALADIN = { { key = "righteousFury", spell = WhoDoesWhat.RighteousFury, tankOnly = true } },
    HUNTER = { { key = "trueshot", spell = WhoDoesWhat.TrueshotAura, talent = true,
        toggles = true } },
}

-- Self-cast key -> whether this character has its talent; asked once, and
-- forgotten when the spellbook changes (SPELLS_CHANGED on the loader).
local talentedSelfCasts = {}

local function WantsSelfCast(cast)
    local name = cast.spell.name
    if cast.talent then
        if talentedSelfCasts[cast.key] == nil then
            talentedSelfCasts[cast.key] =
                (WhoDoesWhat:GetOwnTalentRankByName(name) or 0) > 0
        end
        if not talentedSelfCasts[cast.key] then return false end
    elseif not GetSpellInfo(name) then
        return false
    end
    return not cast.tankOnly or WhoDoesWhat:IsMarkedTank(UnitName("player"))
end

local function IsHunter()
    local _, class = UnitClass("player")
    return class == "HUNTER"
end

-- The model's list plus what only this character's bags and gear can say: the
-- picked food on the food entry, a battle and a guardian elixir, and one
-- entry per wielded weapon.
--
-- Extra fields on those entries:
--   pick      "food" / "petFood" / "alcohol" / an elixir slot key /
--             "mainHand" / "offHand": left-click opens a picker
--   pickNoun, useVerb   how the tooltip names the pick and its right-click
--   useItem   the picked item id, useCount how many are in your bags
--   activeName          the elixir or flask on you, when it isn't the pick
--   slot, hand     the weapon's inventory slot and enchant hand
--   bare      the weapon is meant to stay unenchanted; enchanted / windfury
--             say what is on it
--   forPet    one of the pet section's entries
--
-- Returns your entries, then the pet's: nil for anyone but a hunter, false
-- for a hunter with no pet out, otherwise the pet's list.
local function CollectEntries()
    local entries = Assign.GetPlayerBuffChecklist()
    local picks = Picks()
    for _, entry in ipairs(entries) do
        if entry.key == "food" then
            entry.pick, entry.pickNoun, entry.useVerb = "food", "food", "Eat"
            ApplyPick(entry, picks.food)
        elseif entry.key == "alcohol" then
            entry.pick, entry.pickNoun, entry.useVerb = "alcohol", "drink", "Drink"
            ApplyPick(entry, picks.alcohol)
        end
    end

    local pet = nil
    if IsHunter() then
        pet = Assign.GetPetBuffChecklist() or false
        for _, entry in ipairs(pet or {}) do
            entry.forPet = true
            if entry.key == "food" then
                entry.name = "Pet Food"
                entry.pick, entry.pickNoun, entry.useVerb = "petFood", "pet food", "Feed"
                ApplyPick(entry, picks.petFood)
            end
        end
    end

    local buffs, buffsByName = OwnBuffs()
    local _, class = UnitClass("player")

    -- Sitting eating: the food entry counts down to the moment Well Fed lands,
    -- EAT_SECONDS after the eating aura started (not the aura's own 30
    -- seconds -- you are Well Fed long before you are done chewing). Read off
    -- when the "Food" aura began, like NovaConsumesHelper's eating timer.
    local eating = buffsByName[FOOD_AURA_NAME]
    if eating and eating.duration and eating.duration > 0 and eating.expirationTime then
        local wellFedAt = eating.expirationTime - eating.duration + EAT_SECONDS
        for _, entry in ipairs(entries) do
            if entry.key == "food" and wellFedAt > GetTime() then
                entry.eatingUntil = wellFedAt
            end
        end
    end

    -- Aura (paladin), aspect (hunter), armor (mage, warlock) or demon
    -- (warlock): shows what is running, glows while that isn't the one you
    -- picked. Nothing picked yet adopts what is up.
    for _, swapper in ipairs(SWAPPERS[class] or {}) do
        local swapOptions = swapper.List()
        if #swapOptions > 0 then
            local running, selected
            if swapper.Running then running = swapper.Running(swapOptions) end
            for _, option in ipairs(swapOptions) do
                if not swapper.Running and buffsByName[option.name] then
                    running = option
                end
                if option.key == picks[swapper.key] then selected = option end
            end
            selected = selected or running
            local entry = {
                id = "swap:" .. swapper.key, key = swapper.key, swap = swapper,
                swapOptions = swapOptions, name = swapper.name, selfSupplied = true,
                running = running, selected = selected,
                has = running ~= nil and running == selected,
                icon = (running or selected or swapOptions[1]).icon,
            }
            entry.missing = not entry.has
            entries[#entries + 1] = entry
        end
    end

    -- Omen of Clarity, Inner Fire, Righteous Fury, Trueshot Aura (SELF_CASTS).
    for _, cast in ipairs(SELF_CASTS[class] or {}) do
        if WantsSelfCast(cast) then
            local spell = cast.spell
            local buff = buffsByName[spell.name]
            entries[#entries + 1] = {
                id = "self:" .. cast.key, key = cast.key, name = spell.name,
                icon = spell.icon, selfSupplied = true, castSpell = spell.name,
                castToggles = cast.toggles,
                has = buff ~= nil, missing = buff == nil,
                remaining = buff and buff.remaining,
            }
        end
    end

    local consumables = ActiveConsumables(buffs)
    local petConsumables = pet and ActiveConsumables((OwnBuffs("pet"))) or {}
    -- `forPet` builds the pet's copy of a slot: its own pick (slot.petKey),
    -- read off the pet's auras, and added to the pet's list.
    local function AddConsumableSlot(slot, prefix, noun, verb, forPet)
        local active = (forPet and petConsumables or consumables)[slot.category]
        local pickKey = forPet and slot.petKey or slot.key
        local entry = {
            id = prefix .. slot.key, key = pickKey, pick = pickKey,
            pickNoun = noun, useVerb = verb, forPet = forPet,
            -- A scroll reads onto a friendly target, so it is aimed (unit2): onto
            -- the pet for its copy, onto you otherwise -- never whoever you target.
            useUnit = forPet and "pet" or "player",
            name = slot.name, selfSupplied = true,
            has = active ~= nil, missing = active == nil,
            remaining = active and active.remaining,
            activeName = active and active.name,
            icon = active and active.icon or GetItemIcon(slot.defaultIcon),
        }
        ApplyPick(entry, picks[pickKey])
        -- What is on you outranks what you would drink next.
        if active and active.icon then entry.icon = active.icon end
        -- Up, but not the one picked -- another elixir, a lower scroll rank.
        -- The slot is full so it isn't missing, but it glows as expiring: it
        -- wants replacing. Compared by spell id where both have one, since a
        -- scroll's ranks all share a name.
        if active and entry.useItem then
            local pickedName, pickedSpellId = GetItemSpell(entry.useItem)
            if pickedSpellId and active.spellId then
                entry.otherActive = pickedSpellId ~= active.spellId
            elseif pickedName then
                entry.otherActive = pickedName ~= active.name
            end
        end
        local list = forPet and pet or entries
        list[#list + 1] = entry
    end

    if WhoDoesWhat.ElixirItems and WhoDoesWhat.db.char.buffChecklistElixirs then
        for _, slot in ipairs(ELIXIR_SLOTS) do
            AddConsumableSlot(slot, "elixir:", "elixir", "Drink")
        end
    end

    -- Scrolls of Agility and Strength, for the physical damage roles: whoever
    -- the raid would give Battle Shout, plus every hunter (whose ranged roles
    -- don't stand in a shout, but do want the agility).
    local member = Assign.FindMember(UnitName("player"))
    if WhoDoesWhat.ScrollItems and WhoDoesWhat.db.char.buffChecklistScrolls
        and member and (class == "HUNTER" or WhoDoesWhat:WantsBattleShout(member)) then
        for _, slot in ipairs(SCROLL_SLOTS) do
            AddConsumableSlot(slot, "scroll:", "scroll", "Read")
        end
    end
    -- And the pet's: a scroll reads onto a friendly target, and every hunter
    -- pet fights in melee.
    if pet and WhoDoesWhat.ScrollItems and WhoDoesWhat.db.char.buffChecklistScrolls then
        for _, slot in ipairs(SCROLL_SLOTS) do
            AddConsumableSlot(slot, "pet:scroll:", "scroll", "Read", true)
        end
    end

    local weapons = WhoDoesWhat.db.char.buffChecklistWeapons
    local states = weapons and { WeaponEnchantState() }
    for _, weapon in ipairs(WEAPON_SLOTS) do
        if weapons and WieldsWeapon(weapon.slot) then
            local state = states[weapon.hand]
            local enchanted = state[1] and true or false
            local pick = picks[weapon.key]
            local entry = {
                id = "weapon:" .. weapon.key, key = weapon.key, pick = weapon.key,
                slot = weapon.slot, hand = weapon.hand, selfSupplied = true,
                pickNoun = "enchant", useVerb = "Apply", enchanted = enchanted,
                icon = GetInventoryItemTexture("player", weapon.slot),
            }
            if pick == "none" then
                entry.bare = true
                entry.name = weapon.name .. ": No Enchant"
                entry.windfury = enchanted and windfuryEnchants[state[3]] == true
                -- Windfury Totem reaches the shaman's party and no further, like
                -- a shout: with no shaman in yours, a bare weapon waits for
                -- nothing, so it reads as wrong until Windfury is actually on.
                entry.noShaman = not entry.windfury and not PartyHasShaman()
                entry.has = entry.windfury or (not enchanted and not entry.noShaman)
            else
                entry.name = weapon.name .. " Enchant"
                entry.has = enchanted
                local ms = state[2]
                entry.remaining = enchanted and ms and ms > 0 and ms / 1000 or nil
                local imbueKey = type(pick) == "string" and pick:match("^imbue:(.+)$")
                if imbueKey then
                    -- A shaman's own imbue: right-click casts it (useSpell).
                    for _, imbue in ipairs(WhoDoesWhat.ShamanImbues or {}) do
                        if imbue.key == imbueKey then
                            entry.useSpell, entry.icon = imbue.name, imbue.icon
                        end
                    end
                elseif type(pick) == "number" then
                    ApplyPick(entry, pick)
                end
                -- What is on the weapon shows as itself, and glows when it
                -- isn't the pick: a second Flametongue lands on the off hand
                -- you meant for Windfury, a lesser oil is still running. An
                -- enchant id we don't list just counts as enchanted.
                local enchantID = enchanted and state[3]
                local onImbue = enchantID and imbueByEnchant[enchantID]
                local onItem = enchantID and itemByEnchant[enchantID]
                if onImbue then
                    entry.icon, entry.activeName = onImbue.icon, onImbue.name
                    entry.otherActive = pick ~= nil and onImbue.key ~= imbueKey
                elseif onItem then
                    entry.icon = GetItemIcon(onItem) or entry.icon
                    entry.activeName = ItemName(onItem)
                    entry.otherActive = pick ~= nil and onItem ~= pick
                end
            end
            entry.missing = not entry.has
            entries[#entries + 1] = entry
        end
    end
    SortEntries(entries)
    if pet then SortEntries(pet) end
    return entries, pet
end

-- ---------------------------------------------------------------------------
-- Asking
-- ---------------------------------------------------------------------------

-- One request per buff every few seconds, so an impatient hand posts once.
local REQUEST_COOLDOWN = 10
local lastRequest = {}

-- Whisper the caster the checklist named, or party chat for a shout, which
-- reaches exactly the warriors whose shout reaches you. Anyone who can't be
-- whispered -- a fake raider, nobody named, not in a group -- gets the line
-- printed instead, the way the Shout Bar's request does solo.
local function AskFor(entry)
    local now = GetTime()
    if lastRequest[entry.id] and now - lastRequest[entry.id] < REQUEST_COOLDOWN then
        return
    end
    lastRequest[entry.id] = now
    local text = "[WhoDoesWhat] " .. entry.name
        .. (entry.forPet and " on my pet please!" or " please!")
    if entry.isShout then
        if IsInGroup() then
            SendChatMessage(text, "PARTY")
        else
            WhoDoesWhat:Print(text)
        end
        return
    end
    local target = entry.askName
    local member = target and Assign.FindMember(target)
    if member and not member.isFake and IsInGroup() then
        SendChatMessage(text, "WHISPER", nil, target)
    elseif target then
        WhoDoesWhat:Print(text .. " (to " .. WhoDoesWhat:DisplayName(target) .. ")")
    else
        WhoDoesWhat:Print("Nobody here to ask for " .. entry.name .. ".")
    end
end

-- ---------------------------------------------------------------------------
-- Picker (the trundle)
-- ---------------------------------------------------------------------------

local PICKER_W = 230
local PICKER_ROW_H = 20

-- Both pop-outs (this picker and the aura/aspect menu below) wear the main
-- window's dress: gold edge, its blue title strip as a header, the Paladin
-- Bar's near-black navy inside.
local POPOUT_HEADER_H = 18
local POPOUT_HINT = "Right-click to use"
-- Alternating rows, a faint lift over the dark fill.
local POPOUT_ROW_COLORS = { { 1, 1, 1, 0.025 }, { 1, 1, 1, 0.07 } }

local function StylePopout(f)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = INSET, right = INSET, top = INSET, bottom = INSET },
    })
    local fill, edge = WhoDoesWhat.Theme.paladinBarFill, WhoDoesWhat.Theme.mainBorder
    f:SetBackdropColor(fill[1], fill[2], fill[3], fill[4])
    f:SetBackdropBorderColor(edge[1], edge[2], edge[3])
    -- On the frame's BACKGROUND, over the fill and under the gold edge, like
    -- the window headers.
    local header = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    header:SetPoint("TOPLEFT", INSET, -INSET)
    header:SetPoint("TOPRIGHT", -INSET, -INSET)
    header:SetHeight(POPOUT_HEADER_H)
    header:SetColorTexture(unpack(WhoDoesWhat.Theme.window.titleBarColor))
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("LEFT", header, "LEFT", 6, 0)
    local gold = WhoDoesWhat.Theme.gold
    title:SetTextColor(gold[1], gold[2], gold[3])
    f.title = title
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("RIGHT", header, "RIGHT", -6, 0)
    hint:SetTextColor(0.62, 0.66, 0.75)
    f.hint = hint
end

-- How right-click uses an item for this entry: a macro for a weapon (an oil is
-- used, then aimed at the slot -- "/use item" + "/use 16"), a plain item use
-- otherwise. Consumables add unit2 on top of this (entry.useUnit): "pet" for
-- a pet scroll, "player" for yours, so a scroll never lands on your target.
function ItemUseAction(entry, itemID)
    if entry.slot then
        return "macro", string.format("/use item:%d\n/use %d", itemID, entry.slot)
    end
    return "item", "item:" .. itemID
end

local PICKER_TITLES = {
    food = "Food", alcohol = "Alcohol",
    mainHand = "Main Hand", offHand = "Off Hand",
    battleElixir = "Battle Elixir", guardianElixir = "Guardian Elixir",
    petFood = "Pet Food",
    agilityScroll = "Scroll of Agility", strengthScroll = "Scroll of Strength",
    petAgilityScroll = "Pet: Scroll of Agility", petStrengthScroll = "Pet: Scroll of Strength",
}
-- By the entry's pickNoun.
local PICKER_EMPTY = {
    food = "No buff food in your bags.",
    drink = "No Kreeg's, Gordok Green Grog or Rumsey Rum in your bags.",
    ["pet food"] = "No Kibler's Bits or Sporeling Snacks in your bags.",
    scroll = "No scrolls of this kind in your bags.",
    elixir = "No elixirs or flasks for this slot in your bags.",
    enchant = "No oils, stones or poisons in your bags.",
}

-- One picker per slot kind ("food", "mainHand", "battleElixir", ...), each a
-- secure frame of secure rows: a right-click on a row uses what it picks, and
-- that is protected. They work in combat the way the Paladin Bar's menus do --
-- everything a picker holds is laid out ahead of time, out of combat, on every
-- refresh (FillPickers), and a fight only ever shows, hides and repaints them.
-- Opening one is the grid button's secure OnClick snippet (the swap menu's
-- toggle, below), which also closes every other pop-out. A bag change mid-fight
-- updates the counts but can't add or drop a row until the fight ends. Not in
-- UISpecialFrames: Escape would try to hide a protected frame mid-fight.
local pickers = {}
local pickerCount = 0
-- Swapper key -> its swap menu (EnsureSwapper). Registered on the hub the same
-- way, so the grid's snippet closes them along with the pickers.
local swapMenus = {}

local function AnyPickerShown()
    for _, p in pairs(pickers) do
        if p:IsShown() then return true end
    end
    for _, menu in pairs(swapMenus) do
        if menu:IsShown() then return true end
    end
    return false
end

-- Out of combat only: they are protected frames.
local function HidePickers()
    if InCombatLockdown() then return end
    for _, p in pairs(pickers) do p:Hide() end
    for _, menu in pairs(swapMenus) do menu:Hide() end
end

-- A shaman's own weapon imbues, offered in the weapon pickers beside the oils.
local function KnownImbues()
    local _, class = UnitClass("player")
    local out = {}
    if class ~= "SHAMAN" then return out end
    for _, imbue in ipairs(WhoDoesWhat.ShamanImbues or {}) do
        if GetSpellInfo(imbue.name) then out[#out + 1] = imbue end
    end
    return out
end

-- Post body on each row: close the picker once the click (and any use) has
-- gone out. The hint row picks nothing, so it leaves the picker up.
local PICKER_ROW_POST_SNIPPET = [==[
    if not down then owner:Hide() end
]==]

-- A wrapped OnClick only runs its post body when the pre body hands back a
-- message (its second return; the first, nil, leaves the button alone). The
-- hint row picks nothing, so it sends none and the picker stays up. The close
-- waits for the release: hiding on the press would take the row away before a
-- client that acts on key-up ever used anything.
local PICKER_ROW_PRE_SNIPPET = [==[
    if self:GetAttribute("choosable") then return nil, "close" end
]==]

local function PickerRow(p, index)
    local row = p.rows[index]
    if row then return row end
    row = CreateFrame("Button", p:GetName() .. "Row" .. index, p,
        "SecureActionButtonTemplate")
    row:SetHeight(PICKER_ROW_H)
    row:RegisterForClicks("AnyUp", "AnyDown")
    local y = -(INSET + POPOUT_HEADER_H + 1 + (index - 1) * PICKER_ROW_H)
    row:SetPoint("TOPLEFT", INSET, y)
    row:SetPoint("TOPRIGHT", -INSET, y)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    local color = POPOUT_ROW_COLORS[index % 2 == 1 and 1 or 2]
    stripe:SetColorTexture(color[1], color[2], color[3], color[4])

    local selected = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    selected:SetAllPoints()
    selected:SetColorTexture(1, 0.82, 0, 0.18)
    row.selected = selected

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 2, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.icon = icon

    local count = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("RIGHT", -4, 0)
    row.count = count

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    text:SetPoint("RIGHT", count, "LEFT", -4, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    row.text = text

    -- The use is the row's own secure action (a right-click on "No enchant"
    -- strips the weapon, see FillPicker); this remembers the pick.
    row:SetScript("PostClick", function(self, mouseButton, down)
        if down or not self.spec then return end
        Picks()[p.kind] = self.spec.value
        -- Belt and braces on the post body: out of combat, where hiding the
        -- picker is ours to do, it closes whatever the snippet got.
        if not InCombatLockdown() then p:Hide() end
        GameTooltip:Hide()
        WhoDoesWhat:RefreshBuffChecklist()
        if mouseButton == "RightButton" and RequestChecklistRefresh then
            RequestChecklistRefresh(0.3)
        end
    end)
    row:SetScript("OnEnter", function(self)
        local spec = self.spec
        if not spec or not (spec.itemID or spec.spell) then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if spec.itemID then
            GameTooltip:SetItemByID(spec.itemID)
        elseif GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(select(7, GetSpellInfo(spec.spell.name))
                or spec.spell.spellId)
        else
            GameTooltip:SetText(spec.spell.name, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    SecureHandlerWrapScript(row, "OnClick", p, PICKER_ROW_PRE_SNIPPET,
        PICKER_ROW_POST_SNIPPET)
    p.rows[index] = row
    return row
end

-- Out of combat only. Each picker is registered on the swap menu, which the
-- grid's snippet reaches as `owner`, so that snippet can close them all.
local function EnsurePicker(kind)
    local p = pickers[kind]
    if p then return p end
    local header = EnsureSwapMenu()
    p = CreateFrame("Frame", "WhoDoesWhatBuffChecklistPicker_" .. kind, frame,
        "SecureHandlerShowHideTemplate, BackdropTemplate")
    StylePopout(p)
    p:SetWidth(PICKER_W)
    p.title:SetText(PICKER_TITLES[kind] or kind)
    p.hint:SetText(POPOUT_HINT)
    p.kind = kind
    p.rows = {}
    p:Hide()
    pickerCount = pickerCount + 1
    SecureHandlerSetFrameRef(header, "picker" .. pickerCount, p)
    header:SetAttribute("pickerCount", pickerCount)
    pickers[kind] = p
    return p
end

-- What a slot's picker lists: for a weapon, "No enchant" and (for a shaman)
-- the imbues first; then whatever of that kind is in your bags, and the pick
-- itself if you have run out of it, so it can still be seen and changed.
local function PickerSpecs(entry)
    local kind = entry.pick
    local current = Picks()[kind]
    local specs = {}
    if entry.slot then
        specs[#specs + 1] = { value = "none", text = "No enchant (for Windfury)",
            icon = WINDFURY_ICON }
        for _, imbue in ipairs(KnownImbues()) do
            specs[#specs + 1] = { value = "imbue:" .. imbue.key, spell = imbue,
                text = imbue.name, icon = imbue.icon }
        end
    end
    local listed = {}
    local choices = BagChoices(kind)
    for _, id in ipairs(choices) do
        listed[id] = true
        specs[#specs + 1] = { value = id, itemID = id }
    end
    if type(current) == "number" and not listed[current] then
        specs[#specs + 1] = { value = current, itemID = current }
    end
    return specs, #choices == 0
end

-- The part of a picker that can change any time, combat included: bag counts
-- and which row is the pick.
local function PaintPicker(p)
    local current = Picks()[p.kind]
    for _, row in ipairs(p.rows) do
        local spec = row:IsShown() and row.spec
        if spec then
            if spec.itemID then
                local count = GetItemCount(spec.itemID)
                row.count:SetText(count)
                if count > 0 then
                    row.count:SetTextColor(1, 0.82, 0)
                else
                    row.count:SetTextColor(1, 0.3, 0.3)
                end
                row.icon:SetDesaturated(count == 0)
            end
            row.selected:SetShown(current == spec.value)
        end
    end
end

-- Lay a slot's picker out and bake each row's right-click. Out of combat
-- only, and a no-op unless what it lists has changed.
local function FillPicker(entry)
    local p = EnsurePicker(entry.pick)
    p.entry = entry
    local specs, empty = PickerSpecs(entry)
    -- A right-click on "No enchant" strips the weapon, when there is something
    -- other than Windfury on it to strip (the secure "cancelaura" action).
    local stripSlot = entry.hand and entry.enchanted and not entry.windfury
        and tostring(entry.slot) or nil
    local parts = { tostring(entry.useUnit), tostring(empty), tostring(stripSlot) }
    for _, spec in ipairs(specs) do
        spec.usable = spec.spell ~= nil
            or (spec.itemID ~= nil and GetItemCount(spec.itemID) > 0)
        -- "?" while the item's name is still loading, so the rows are
        -- relaid once it arrives.
        parts[#parts + 1] = tostring(spec.value) .. (spec.usable and "+" or "-")
            .. ((spec.itemID and not KnownItemName(spec.itemID)) and "?" or "")
    end
    local stamp = table.concat(parts, ",")
    if p.stamp ~= stamp then
        p.stamp = stamp
        for i, spec in ipairs(specs) do
            local row = PickerRow(p, i)
            row.spec = spec
            row:SetAttribute("choosable", true)
            local kind, value
            if spec.spell then
                kind, value = "spell", spec.spell.name
            elseif spec.itemID and spec.usable then
                kind, value = ItemUseAction(entry, spec.itemID)
            elseif spec.value == "none" and stripSlot then
                kind, value = "cancelaura", stripSlot
            end
            row:SetAttribute("type2", kind)
            row:SetAttribute("target-slot2", kind == "cancelaura" and value or nil)
            row:SetAttribute("macrotext2", kind == "macro" and value or nil)
            row:SetAttribute("item2", kind == "item" and value or nil)
            row:SetAttribute("spell2", kind == "spell" and value or nil)
            row:SetAttribute("unit2", kind == "item" and entry.useUnit or nil)
            if spec.itemID then
                row.icon:SetTexture(GetItemIcon(spec.itemID))
                row.text:SetText(ItemName(spec.itemID))
            else
                row.icon:SetTexture(spec.icon)
                row.icon:SetDesaturated(false)
                row.text:SetText(spec.text)
                row.count:SetText("")
            end
            row:Show()
        end
        local shown = #specs
        if empty then
            shown = shown + 1
            local row = PickerRow(p, shown)
            row.spec = nil
            row:SetAttribute("choosable", nil)
            row:SetAttribute("type2", nil)
            row.icon:SetTexture(nil)
            row.text:SetText("|cff999999" .. PICKER_EMPTY[entry.pickNoun] .. "|r")
            row.count:SetText("")
            row.selected:Hide()
            row:Show()
        end
        for i = shown + 1, #p.rows do
            p.rows[i].spec = nil
            p.rows[i]:Hide()
        end
        p:SetHeight(INSET * 2 + POPOUT_HEADER_H + 1 + shown * PICKER_ROW_H + 2)
    end
    PaintPicker(p)
end

-- Every slot on the grid gets its picker brought up to date. Out of combat;
-- in a fight the refresh only repaints them. A picker whose slot has gone, or
-- whose icon now shows a different slot, is closed.
local function FillPickers(lists)
    local present = {}
    for _, list in ipairs(lists) do
        for _, entry in ipairs(list) do
            if entry.pick then
                present[entry.pick] = true
                FillPicker(entry)
            end
        end
    end
    for kind, p in pairs(pickers) do
        if p:IsShown() then
            local _, anchor = p:GetPoint(1)
            if not present[kind] or not (anchor and anchor.entry
                and anchor.entry.pick == kind) then
                p:Hide()
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

local function IsExpiring(entry)
    return entry.has == true and entry.remaining ~= nil
        and entry.remaining < WarnSeconds()
end

local function CanUse(entry)
    return entry.useSpell ~= nil
        or (entry.useItem ~= nil and (entry.useCount or 0) > 0)
end

-- Whether a right-click takes the weapon's enchant off rather than using
-- anything: a weapon kept bare for Windfury with something else on it, or a
-- shaman imbue picked where another enchant sits (an imbue can't land over
-- one, so the next right-click casts). Done with the secure "cancelaura"
-- action -- CancelItemTempEnchantment is protected, and from our own click
-- scripts it was silently blocked.
local function StripsEnchant(entry)
    return entry.hand ~= nil and entry.enchanted
        and ((entry.bare and not entry.windfury)
            or (entry.useSpell ~= nil and entry.otherActive))
end

local function AddTimeLeftLine(btn, prefix)
    local remaining = btn.expiresAt and (btn.expiresAt - GetTime())
    if remaining and remaining > 0 then
        GameTooltip:AddLine(string.format("%s, %d:%02d left.", prefix,
            math.floor(remaining / 60), math.floor(remaining % 60)), 0.3, 1, 0.3)
    else
        GameTooltip:AddLine(prefix .. ".", 0.3, 1, 0.3)
    end
end

local function ShowTooltip(btn)
    local entry = btn.entry
    if not entry then return end
    -- A pop-out open over the grid wants the space: no tooltip, and not one
    -- left behind from before it opened.
    if AnyPickerShown() then
        if GameTooltip:GetOwner() == btn then GameTooltip:Hide() end
        return
    end
    GameTooltip:SetOwner(btn, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, 0)
    GameTooltip:SetText((entry.forPet and "Pet: " or "") .. entry.name, 1, 1, 1)
    if entry.swap then
        if entry.running then
            GameTooltip:AddLine("Running: " .. entry.running.name .. ".", 0.3, 1, 0.3)
        else
            GameTooltip:AddLine("No " .. entry.swap.noun .. " running.", 1, 0.3, 0.3)
        end
        if entry.selected and entry.selected ~= entry.running then
            GameTooltip:AddLine("Picked: " .. entry.selected.name .. ".", 1, 0.6, 0.2)
        end
    elseif entry.bare then
        if entry.windfury then
            GameTooltip:AddLine("Windfury is on it.", 0.3, 1, 0.3)
        elseif entry.enchanted then
            GameTooltip:AddLine("Has an enchant, so Windfury can't land.", 1, 0.3, 0.3)
        elseif entry.noShaman then
            GameTooltip:AddLine("Bare, but no shaman in your party to Windfury it.",
                1, 0.3, 0.3)
        else
            GameTooltip:AddLine("Bare, ready for Windfury.", 0.3, 1, 0.3)
        end
        if entry.noShaman and entry.enchanted then
            GameTooltip:AddLine("No shaman in your party either.", 1, 0.3, 0.3)
        end
    elseif entry.slot then
        if entry.enchanted then
            AddTimeLeftLine(btn, entry.activeName
                and ("On it: " .. entry.activeName) or "Enchanted")
            if entry.otherActive then
                local c = WhoDoesWhat:GetBuffChecklistGlowColor("expiring")
                GameTooltip:AddLine("Not the enchant you picked.", c.r, c.g, c.b)
            end
        else
            GameTooltip:AddLine("No enchant.", 1, 0.3, 0.3)
        end
    elseif entry.has == nil then
        GameTooltip:AddLine("Not scanned yet.", 0.6, 0.6, 0.6)
    elseif entry.eatingUntil and entry.eatingUntil > GetTime() then
        local c = WhoDoesWhat:GetBuffChecklistGlowColor("expiring")
        GameTooltip:AddLine(string.format("Eating: Well Fed in %ds.",
            math.ceil(entry.eatingUntil - GetTime())), c.r, c.g, c.b)
    elseif entry.has == false then
        GameTooltip:AddLine("Missing.", 1, 0.3, 0.3)
    else
        local onWho = entry.forPet and "On your pet" or "On you"
        AddTimeLeftLine(btn, entry.activeName and (onWho .. ": " .. entry.activeName)
            or onWho)
        if entry.otherActive then
            local c = WhoDoesWhat:GetBuffChecklistGlowColor("expiring")
            GameTooltip:AddLine("Not the " .. entry.pickNoun .. " you picked.",
                c.r, c.g, c.b)
        end
        local source = not entry.selfSupplied
            and WhoDoesWhat:GetBuffSource(entry.target or UnitName("player"), entry.key)
        if source then
            GameTooltip:AddLine("From " .. WhoDoesWhat:DisplayName(source) .. ".",
                0.8, 0.8, 0.8)
        end
        if entry.note then GameTooltip:AddLine(entry.note, 1, 0.6, 0.2, true) end
    end

    local noun = entry.pickNoun
    if entry.pick and not entry.bare then
        if entry.useSpell then
            GameTooltip:AddLine("Using " .. entry.useSpell .. ".", 0.8, 0.8, 0.8)
        elseif entry.useItem then
            local name = ItemName(entry.useItem)
            if CanUse(entry) then
                GameTooltip:AddLine("Using " .. name .. " (" .. entry.useCount
                    .. " in bags).", 0.8, 0.8, 0.8)
            else
                GameTooltip:AddLine("Out of " .. name .. ".", 1, 0.3, 0.3)
            end
        else
            GameTooltip:AddLine("No " .. noun .. " picked.", 0.6, 0.6, 0.6)
        end
    end

    GameTooltip:AddLine(" ")
    if entry.swap then
        UI.AddTooltipHint(GameTooltip, "Left-Click:",
            "Pick " .. entry.swap.noun .. " (casts it)")
        if entry.selected then
            UI.AddTooltipHint(GameTooltip, "Right-Click:", "Cast " .. entry.selected.name)
        end
    elseif entry.castSpell then
        UI.AddTooltipHint(GameTooltip, "Right-Click:", "Cast " .. entry.castSpell)
    end
    if entry.pick then
        UI.AddTooltipHint(GameTooltip, "Left-Click:", "Pick " .. noun)
        if StripsEnchant(entry) then
            UI.AddTooltipHint(GameTooltip, "Right-Click:", "Remove "
                .. (entry.activeName or "enchant"))
        elseif CanUse(entry) and not entry.bare then
            UI.AddTooltipHint(GameTooltip, "Right-Click:", entry.useSpell
                and ("Cast " .. entry.useSpell)
                or (entry.useVerb .. " " .. ItemName(entry.useItem)))
        end
    end
    local ask = not entry.selfSupplied and (entry.isShout and "Ask your party"
        or entry.askName and ("Ask " .. WhoDoesWhat:DisplayName(entry.askName)))
    if ask then UI.AddTooltipHint(GameTooltip, "Shift-Click:", ask) end
    UI.AddTooltipHint(GameTooltip, "Alt-Drag:", "Move")
    UI.AddTooltipHint(GameTooltip, "Shift-Right-Click:", "Buff Checklist Settings")
    GameTooltip:Show()
end

local STOCK_FONT_RATIO = 11 / 28

local function SizeButton(btn, size)
    if btn.sizedAt == size then return end
    btn.sizedAt = size
    btn:SetSize(size, size)
    local face, _, flags = btn.timer:GetFont()
    btn.timer:SetFont(face or FALLBACK_FONT,
        math.max(9, math.floor(size * TIMER_FONT_RATIO + 0.5)), flags)
    local stockFace = btn.stock:GetFont()
    btn.stock:SetFont(stockFace or FALLBACK_FONT,
        math.max(8, math.floor(size * STOCK_FONT_RATIO + 0.5)), "OUTLINE")
end

-- ---------------------------------------------------------------------------
-- Swap menus (aura / aspect / armor / demon)
-- ---------------------------------------------------------------------------

-- Unlike the item picker, choosing here CASTS, and a cast is protected -- so
-- each menu is a secure frame of secure buttons, opened by a restricted
-- snippet wrapped round the grid button's OnClick (it has to open mid-fight,
-- which is when aspects get swapped). One menu per swapper, since a warlock
-- carries two (armor and demon). Built like the Paladin Bar's aura picker,
-- whose notes explain the template order and the post body.
local SWAP_OPTION_SIZE = 28
local SWAP_COLUMNS = 7
local SWAP_PAD = 5

-- Pre body on every grid button's OnClick, and the one place any pop-out opens
-- or closes -- here, in the secure snippet, because none of them can be shown
-- or hidden from ordinary code in combat. `owner` is the hub every pop-out is
-- registered on (EnsureSwapMenu).
--
-- The button's attributes (set out of combat, ConfigureUse) say what it opens:
-- a "swapper" opens its swap menu (the "swapMenu" frame ref) on left-click; a
-- "picks" button opens its
-- own picker (the "picker" frame ref) on left-click, and on right-click too
-- while there is nothing to use ("pickOnRight"). Every click closes every
-- pop-out first, so opening one closes the rest, and clicking the same icon
-- again closes its own. A held Shift or Alt means settings or dragging.
local SWAP_TOGGLE_SNIPPET = [==[
    if down or IsShiftKeyDown() or IsAltKeyDown() then return end
    local target
    if self:GetAttribute("swapper") then
        if button == "LeftButton" then target = self:GetFrameRef("swapMenu") end
    elseif self:GetAttribute("picks") then
        if button == "LeftButton"
            or (button == "RightButton" and self:GetAttribute("pickOnRight")) then
            target = self:GetFrameRef("picker")
        end
    end
    local wasShown = target and target:IsShown()
    for i = 1, owner:GetAttribute("pickerCount") or 0 do
        local p = owner:GetFrameRef("picker" .. i)
        if p then p:Hide() end
    end
    if not target or wasShown then return end
    target:ClearAllPoints()
    target:SetPoint(self:GetAttribute("swapPoint"), self,
        self:GetAttribute("swapRelPoint"), self:GetAttribute("swapX"),
        self:GetAttribute("swapY"))
    target:Show()
    target:RegisterAutoHide(1.5)
    target:AddToAutoHide(self)
]==]

-- Post body on each option: close once the cast has gone out.
local SWAP_OPTION_POST_SNIPPET = [==[
    if not down then owner:Hide() end
]==]
-- The pre body only exists to send the message that lets the post body run
-- (see PICKER_ROW_PRE_SNIPPET).
local SWAP_OPTION_PRE_SNIPPET = [==[
    return nil, "close"
]==]

local function CreateSwapOption(menu, index)
    local option = CreateFrame("Button", menu:GetName() .. "Option" .. index,
        menu, "SecureActionButtonTemplate")
    option:SetSize(SWAP_OPTION_SIZE, SWAP_OPTION_SIZE)
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

    UI.AddTooltip(option, function(self)
        if not self.spell then return end
        local spellId = select(7, GetSpellInfo(self.spell.name)) or self.spell.spellId
        if GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(spellId)
        else
            GameTooltip:SetHyperlink("spell:" .. spellId)
        end
        return true
    end)
    -- The cast is the option's own macro; this only remembers the pick.
    option:SetScript("PostClick", function(self, _, down)
        if down == true or not self.spell then return end
        Picks()[menu.kind] = self.spell.key
        if not InCombatLockdown() then menu:Hide() end
        WhoDoesWhat:RefreshBuffChecklist()
    end)
    SecureHandlerWrapScript(option, "OnClick", menu, SWAP_OPTION_PRE_SNIPPET,
        SWAP_OPTION_POST_SNIPPET)
    menu.options[index] = option
    return option
end

-- The hub every pop-out hangs its secure refs off: never shown itself, the
-- grid's snippet runs with it as `owner`, and each picker (EnsurePicker) and
-- swap menu (EnsureSwapper) registers here so that snippet can close them all.
function EnsureSwapMenu()
    if swapMenu then return swapMenu end
    swapMenu = CreateFrame("Frame", "WhoDoesWhatBuffChecklistPopouts", frame,
        "SecureHandlerBaseTemplate")
    return swapMenu
end

-- One swapper's menu. Out of combat only.
local function EnsureSwapper(kind)
    local menu = swapMenus[kind]
    if menu then return menu end
    local hub = EnsureSwapMenu()
    menu = CreateFrame("Frame", "WhoDoesWhatBuffChecklistSwap_" .. kind, frame,
        "SecureHandlerShowHideTemplate, BackdropTemplate")
    StylePopout(menu)
    menu.hint:SetText("Click to cast")
    menu.kind = kind
    menu.options = {}
    menu:Hide()
    pickerCount = pickerCount + 1
    SecureHandlerSetFrameRef(hub, "picker" .. pickerCount, menu)
    hub:SetAttribute("pickerCount", pickerCount)
    swapMenus[kind] = menu
    return menu
end

-- Lay the swapper's spells out and bake each option's cast. Out of combat
-- only; mid-fight the menu keeps what it last had.
local function ConfigureSwapMenu(entry)
    if InCombatLockdown() then return end
    local menu = EnsureSwapper(entry.swap.key)
    local keys = {}
    for i, spell in ipairs(entry.swapOptions) do keys[i] = spell.key end
    local stamp = table.concat(keys, ",")
    if menu.stamp == stamp then return end
    menu.stamp = stamp
    menu.title:SetText(entry.swap.name .. "s")
    local count = #entry.swapOptions
    for i, spell in ipairs(entry.swapOptions) do
        local option = menu.options[i] or CreateSwapOption(menu, i)
        option.spell = spell
        option.icon:SetTexture(spell.icon)
        option:SetAttribute("macrotext1", "/cast " .. spell.name)
        local col, row = (i - 1) % SWAP_COLUMNS, math.floor((i - 1) / SWAP_COLUMNS)
        option:ClearAllPoints()
        option:SetPoint("TOPLEFT", INSET + SWAP_PAD + col * (SWAP_OPTION_SIZE + GAP),
            -(INSET + POPOUT_HEADER_H + SWAP_PAD + row * (SWAP_OPTION_SIZE + GAP)))
        option:Show()
    end
    for i = count + 1, #menu.options do
        menu.options[i].spell = nil
        menu.options[i]:Hide()
    end
    local columns = math.min(count, SWAP_COLUMNS)
    local rows = math.ceil(count / SWAP_COLUMNS)
    menu:SetSize(math.max(INSET * 2 + SWAP_PAD * 2 + columns * SWAP_OPTION_SIZE
            + (columns - 1) * GAP, math.ceil(menu.title:GetStringWidth()
            + menu.hint:GetStringWidth()) + INSET * 2 + 24),
        INSET * 2 + POPOUT_HEADER_H + SWAP_PAD * 2 + rows * SWAP_OPTION_SIZE
            + (rows - 1) * GAP)
end

-- Repaint the menu's icons: full colour on what is running, a gold border on
-- the pick. Safe in combat.
local function PaintSwapMenu(entry)
    local menu = swapMenus[entry.swap.key]
    if not menu then return end
    for _, option in ipairs(menu.options) do
        if option.spell then
            option.icon:SetDesaturated(option.spell ~= entry.running)
            if option.spell == entry.selected then
                option.border:SetColorTexture(1, 0.82, 0.2, 1)
            else
                option.border:SetColorTexture(0, 0, 0, 0.9)
            end
        end
    end
end

-- Point the button's secure actions at its entry. Right-click: the picked
-- item (a macro for a weapon, since an oil has to be used and then aimed at
-- the slot -- "/use item" + "/use 16"; food, pet food and elixirs are a plain
-- use), the picked aura or aspect, or a self-buff spell. Left-click opens the
-- swap menu when the entry is a swapper. Out of combat only, and only written
-- when it changed -- the same button can be any entry from one repaint to the
-- next.
local function ConfigureUse(btn, entry)
    if InCombatLockdown() then return end
    local kind, value
    if StripsEnchant(entry) then
        kind, value = "cancelaura", tostring(entry.slot)
    elseif entry.castSpell then
        if entry.castToggles then
            kind, value = "macro", "/cast !" .. entry.castSpell
        else
            kind, value = "spell", entry.castSpell
        end
    elseif entry.swap then
        if entry.selected then kind, value = "macro", "/cast " .. entry.selected.name end
    elseif entry.useSpell then
        kind, value = "spell", entry.useSpell
    elseif CanUse(entry) then
        kind, value = ItemUseAction(entry, entry.useItem)
    end
    local direction = WhoDoesWhat:GetBuffChecklistPopoutDirection()
    local stamp = (kind and (kind .. value) or "") .. (entry.swap and ("|swap:" .. entry.swap.key) or "")
        .. (entry.pick and ("|pick:" .. entry.pick) or "")
        .. (entry.useUnit and ("|" .. entry.useUnit) or "")
        .. "|" .. direction.key
    if btn.useStamp == stamp then return end
    btn.useStamp = stamp
    btn:SetAttribute("type2", kind)
    btn:SetAttribute("macrotext2", kind == "macro" and value or nil)
    btn:SetAttribute("item2", kind == "item" and value or nil)
    btn:SetAttribute("spell2", kind == "spell" and value or nil)
    btn:SetAttribute("unit2", kind == "item" and entry.useUnit or nil)
    btn:SetAttribute("target-slot2", kind == "cancelaura" and value or nil)
    btn:SetAttribute("swapper", entry.swap and true or nil)
    if entry.swap then
        SecureHandlerSetFrameRef(btn, "swapMenu", EnsureSwapper(entry.swap.key))
    end
    -- A slot with a picker: the snippet opens it on left-click, and on
    -- right-click while there is nothing to use (a bare weapon's right-click
    -- strips its enchant instead). Its contents are filled at the end of the
    -- same refresh (FillPickers).
    btn:SetAttribute("picks", entry.pick and true or nil)
    btn:SetAttribute("pickOnRight",
        (entry.pick and not entry.bare and not CanUse(entry)) and true or nil)
    if entry.pick then
        SecureHandlerSetFrameRef(btn, "picker", EnsurePicker(entry.pick))
    end
    -- Where the swap menu opens, read by SWAP_TOGGLE_SNIPPET.
    btn:SetAttribute("swapPoint", direction.point)
    btn:SetAttribute("swapRelPoint", direction.rel)
    btn:SetAttribute("swapX", direction.x * POPOUT_GAP)
    btn:SetAttribute("swapY", direction.y * POPOUT_GAP)
end

local function CreateButton(index)
    local btn = CreateFrame("Button", nil, frame, "SecureActionButtonTemplate")
    WhoDoesWhat:CreateIconHighlightHost(btn)
    -- Both edges, as the other bars do: a secure button obeys
    -- ActionButtonUseKeyDown, and an up-only registration never fires on a
    -- client set to act on key down. PostClick drops the second pass.
    btn:RegisterForClicks("AnyUp", "AnyDown")
    -- Shift-right-click is the settings shortcut, so it must not also eat the
    -- food: a type with no handler behind it does nothing.
    btn:SetAttribute("shift-type2", "none")
    SecureHandlerWrapScript(btn, "OnClick", EnsureSwapMenu(), SWAP_TOGGLE_SNIPPET)

    -- How many of the picked consumable are left, in the corner.
    local stock = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    stock:SetPoint("BOTTOMRIGHT", -1, 2)
    stock:SetJustifyH("RIGHT")
    stock:Hide()
    btn.stock = stock

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(0, 0, 0, 0.9)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn.icon = icon

    -- Nothing picked and nothing in your bags to pick (NothingToPick).
    local nothing = btn:CreateTexture(nil, "OVERLAY")
    nothing:SetPoint("TOPLEFT", 3, -3)
    nothing:SetPoint("BOTTOMRIGHT", -3, 3)
    nothing:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
    nothing:Hide()
    btn.nothing = nothing

    local timer = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    timer:SetPoint("CENTER")
    timer:SetFont(GameFontNormal:GetFont() or FALLBACK_FONT, 16, "OUTLINE")
    timer:Hide()
    btn.timer = timer

    btn:SetScript("OnEnter", ShowTooltip)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UI.AttachDrag(btn, frame)
    btn:SetScript("PostClick", function(self, mouseButton, down)
        local entry = self.entry
        if down or not entry or IsAltKeyDown() then return end
        if mouseButton == "RightButton" and not IsShiftKeyDown() then
            -- Whatever that used lands shortly; follow it, then once more in
            -- case the aura or the bag count took its time.
            RequestChecklistRefresh(0.3)
            C_Timer.After(1.5, function() WhoDoesWhat:RefreshBuffChecklist() end)
        end
        if mouseButton == "RightButton" then
            if IsShiftKeyDown() then
                WhoDoesWhat:OpenAddonSettingsView("Checklist")
            end
        elseif IsShiftKeyDown() then
            if not entry.selfSupplied and (entry.missing or IsExpiring(entry)) then
                AskFor(entry)
            end
        end
        -- Pickers open and close in the secure snippet (SWAP_TOGGLE_SNIPPET).
        if entry.pick or entry.swap then GameTooltip:Hide() end
    end)
    btn:Hide()
    frame.buttons[index] = btn
    return btn
end

-- The countdown over the icon, off the stored expiry, and the glow that goes
-- with it. Split out so the tick can run it between repaints.
local function UpdateTimerAndGlow(btn)
    local entry = btn.entry
    -- Eating: a 10-to-0 countdown in the expiring colour, glowing the same,
    -- until Well Fed lands (the aura change repaints it away).
    local eatLeft = entry.eatingUntil and (entry.eatingUntil - GetTime())
    if eatLeft and eatLeft > 0 then
        local c = WhoDoesWhat:GetBuffChecklistGlowColor("expiring")
        btn.timer:SetFormattedText("%d", math.ceil(eatLeft))
        btn.timer:SetTextColor(c.r, c.g, c.b)
        btn.timer:Show()
        WhoDoesWhat:ApplyStatusBarHighlight(btn.highlightHost, true,
            WhoDoesWhat:GetBuffChecklistGlowStyle(), c)
        return
    end
    local remaining = btn.expiresAt and (btn.expiresAt - GetTime())
    local expiring = entry.has == true and remaining ~= nil and remaining > 0
        and remaining < WarnSeconds()
    if expiring then
        -- Minutes while there are any, so a six-minute warning fits the icon.
        if remaining >= 60 then
            btn.timer:SetFormattedText("%dm", math.ceil(remaining / 60))
        else
            btn.timer:SetFormattedText("%d", math.ceil(remaining))
        end
        -- The countdown wears the expiring colour, like the Paladin Bar's.
        local c = WhoDoesWhat:GetBuffChecklistGlowColor("expiring")
        btn.timer:SetTextColor(c.r, c.g, c.b)
    end
    btn.timer:SetShown(expiring)
    -- The wrong elixir or scroll rank up wears the expiring glow too, without
    -- a countdown: it wants replacing, but nothing is missing.
    local color = entry.missing and WhoDoesWhat:GetBuffChecklistGlowColor("missing")
        or (expiring or entry.otherActive) and WhoDoesWhat:GetBuffChecklistGlowColor("expiring")
        or nil
    WhoDoesWhat:ApplyStatusBarHighlight(btn.highlightHost, color ~= nil,
        WhoDoesWhat:GetBuffChecklistGlowStyle(), color)
end

-- A picker slot that is down with nothing picked and nothing in your bags
-- the picker could offer (for a weapon, no oils or stones and no imbue of
-- your own either): there is nothing to do about it from here.
local function NothingToPick(entry)
    if not entry.pick or entry.has == true or Picks()[entry.pick] ~= nil then
        return false
    end
    if #BagChoices(entry.pick) > 0 then return false end
    return not (entry.slot and #KnownImbues() > 0)
end

local function PaintButton(btn, entry)
    btn.entry = entry
    btn.nothing:SetShown(NothingToPick(entry))
    btn.expiresAt = entry.remaining and (GetTime() + entry.remaining) or nil
    btn.icon:SetTexture(entry.icon)
    -- Grey unless it is actually on you; unknown reads as not-yet rather than
    -- as missing, so it greys without glowing.
    btn.icon:SetDesaturated(entry.has ~= true or entry.missing)
    if entry.useItem then
        btn.stock:SetText(entry.useCount or 0)
        if (entry.useCount or 0) > 0 then
            btn.stock:SetTextColor(1, 1, 1)
        else
            btn.stock:SetTextColor(1, 0.3, 0.3)
        end
        btn.stock:Show()
    else
        btn.stock:Hide()
    end
    ConfigureUse(btn, entry)
    if entry.swap then
        ConfigureSwapMenu(entry)
        PaintSwapMenu(entry)
    end
    UpdateTimerAndGlow(btn)
    if GameTooltip:IsShown() and GameTooltip:GetOwner() == btn then
        ShowTooltip(btn)
    end
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

local function EnsureFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", "WhoDoesWhatBuffChecklist", UIParent, "BackdropTemplate")
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(20)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = INSET, right = INSET, top = INSET, bottom = INSET },
    })
    local fill, edge = WhoDoesWhat.Theme.paladinBarFill, WhoDoesWhat.Theme.mainBorder
    frame:SetBackdropColor(fill[1], fill[2], fill[3], fill[4])
    frame:SetBackdropBorderColor(edge[1], edge[2], edge[3])
    frame.buttons = {}

    -- Header strip (a setting): the window's name, a drag handle, and the
    -- one spot on it that isn't a buff, so its tooltip is about the window.
    local title = CreateFrame("Frame", nil, frame)
    title:SetHeight(TITLE_H)
    title:SetPoint("TOPLEFT", INSET, -INSET)
    title:SetPoint("TOPRIGHT", -INSET, -INSET)
    -- The fill is the window's, not the strip's: a child frame draws above
    -- its parent's backdrop, which laid the header over the gold edge. On
    -- the window's BACKGROUND it sits over the fill and under the edge
    -- (BORDER). Being off the strip, it's shown and hidden alongside it.
    local titleBg = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    titleBg:SetAllPoints(title)
    titleBg:Hide()
    frame.titleBg = titleBg
    titleBg:SetColorTexture(unpack(WhoDoesWhat.Theme.window.titleBarColor))
    local titleText = title:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleText:SetPoint("CENTER")
    titleText:SetText("Buff Checklist |cff808080(Beta)|r")
    title.text = titleText
    UI.AttachDrag(title, frame)
    title:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        GameTooltip:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, 0)
        GameTooltip:SetText("|T" .. WhoDoesWhat.ADDON_ICON .. ":16:16:0:0|t "
            .. "WhoDoesWhat Buff Checklist |cff808080(Beta)|r", 1, 1, 1)
        GameTooltip:AddLine("The buffs your character should have.", 0.6, 0.6, 0.6)
        GameTooltip:AddLine(" ")
        UI.AddTooltipHint(GameTooltip, "Alt-Drag:", "Move")
        UI.AddTooltipHint(GameTooltip, "Shift-Right-Click:", "Buff Checklist Settings")
        GameTooltip:Show()
    end)
    title:SetScript("OnLeave", function() GameTooltip:Hide() end)
    title:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and IsShiftKeyDown() then
            WhoDoesWhat:OpenAddonSettingsView("Checklist")
        end
    end)
    title:Hide()
    frame.title = title
    UI.MakeMovable(frame, {
        noCombat = true,
        OnStart = HidePickers,
        OnStop = function()
            SavePosition()
            LoadPosition()
        end,
    })

    -- Countdowns tick without an event to hang off. With "Hide buffs I have"
    -- on, a hidden buff entering its warning window has to come back, which is
    -- a re-layout, so the tick asks for one at the moment the first does.
    frame.tick = 0
    frame:SetScript("OnUpdate", function(self, elapsed)
        self.tick = self.tick + elapsed
        if self.tick < 0.25 then return end
        self.tick = 0
        if self.revealAt and GetTime() >= self.revealAt and not InCombatLockdown() then
            WhoDoesWhat:RefreshBuffChecklist()
            return
        end
        for _, btn in ipairs(self.buttons) do
            if btn:IsShown() then UpdateTimerAndGlow(btn) end
        end
    end)
    LoadPosition()
    return frame
end

-- ---------------------------------------------------------------------------
-- Pet divider (hunters)
-- ---------------------------------------------------------------------------

-- A rule across the grid between your buffs and your pet's, carrying the
-- pet's coverage -- "Pet (2/4)" -- or a red "Pet Not Summoned". Clicking it
-- collapses the pet's icons away (per character), leaving the count. An
-- ordinary frame, so it repaints in combat; the collapse itself moves secure
-- buttons, so it lands when the fight ends.
local DIVIDER_H = 14
local DIVIDER_ARROW = 10
local DIVIDER_LINE_MIN = 10

local function EnsureDivider()
    if divider then return divider end
    divider = CreateFrame("Button", nil, frame)
    divider:SetHeight(DIVIDER_H)
    divider:RegisterForClicks("LeftButtonUp")

    local label = divider:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", DIVIDER_ARROW / 2, 0)
    divider.label = label
    local arrow = divider:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(DIVIDER_ARROW, DIVIDER_ARROW)
    arrow:SetPoint("RIGHT", label, "LEFT", -3, 0)
    divider.arrow = arrow

    local edge = WhoDoesWhat.Theme.mainBorder
    local leftLine = divider:CreateTexture(nil, "ARTWORK")
    leftLine:SetHeight(1)
    leftLine:SetColorTexture(edge[1], edge[2], edge[3], 0.6)
    leftLine:SetPoint("LEFT", 0, 0)
    leftLine:SetPoint("RIGHT", arrow, "LEFT", -4, 0)
    local rightLine = divider:CreateTexture(nil, "ARTWORK")
    rightLine:SetHeight(1)
    rightLine:SetColorTexture(edge[1], edge[2], edge[3], 0.6)
    rightLine:SetPoint("LEFT", label, "RIGHT", 4, 0)
    rightLine:SetPoint("RIGHT", 0, 0)

    divider:SetScript("OnClick", function()
        local char = WhoDoesWhat.db.char
        char.buffChecklistPetCollapsed = not char.buffChecklistPetCollapsed
        GameTooltip:Hide()
        WhoDoesWhat:RefreshBuffChecklist()
    end)
    divider:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        GameTooltip:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, 0)
        GameTooltip:SetText("Pet Buffs", 1, 1, 1)
        GameTooltip:AddLine("Your pet's buffs, counted as covered/total.", 0.6, 0.6, 0.6)
        GameTooltip:AddLine(" ")
        UI.AddTooltipHint(GameTooltip, "Left-Click:",
            WhoDoesWhat.db.char.buffChecklistPetCollapsed and "Expand" or "Collapse")
        UI.AddTooltipHint(GameTooltip, "Alt-Drag:", "Move")
        GameTooltip:Show()
    end)
    divider:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UI.AttachDrag(divider, frame)
    divider:Hide()
    return divider
end

-- `pet` is CollectEntries' second return: false for no pet out.
local function PaintDivider(pet, collapsed)
    if pet == false then
        divider.label:SetText("Pet Not Summoned")
        divider.label:SetTextColor(1, 0.25, 0.25)
        divider.arrow:Hide()
        return
    end
    local covered = 0
    for _, entry in ipairs(pet) do
        if entry.has == true and not entry.missing then covered = covered + 1 end
    end
    divider.label:SetFormattedText("Pet (%d/%d)", covered, #pet)
    if covered >= #pet then
        divider.label:SetTextColor(0.3, 1, 0.3)
    else
        local c = WhoDoesWhat:GetBuffChecklistGlowColor("missing")
        divider.label:SetTextColor(c.r, c.g, c.b)
    end
    divider.arrow:SetTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-Up"
        or "Interface\\Buttons\\UI-MinusButton-Up")
    divider.arrow:Show()
end

-- When the hidden-frame reveal timer below is due, or nil with none waiting.
local pendingReveal = nil

-- Out of combat only: it hides secure buttons and the frame parenting them.
local function HideFrame()
    HidePickers()
    if not frame then return end
    for _, btn in ipairs(frame.buttons) do
        WhoDoesWhat:ApplyStatusBarHighlight(btn.highlightHost, false,
            WhoDoesWhat:GetBuffChecklistGlowStyle())
        btn:Hide()
    end
    frame:Hide()
end

-- Recompute the list and lay the grid out. Rides RefreshBoardViews (buff
-- tracking, roster, plan changes), so it bails first thing while switched off.
function WhoDoesWhat:RefreshBuffChecklist()
    if not self.db then return end
    local settings = self.db.profile.settings
    local combat = InCombatLockdown()
    if not settings.buffChecklistEnabled then
        if not combat then HideFrame() end
        return
    end

    local entries, pet = CollectEntries()
    local collapsed = self.db.char.buffChecklistPetCollapsed and true or false

    -- Mid-fight nothing secure can be shown, hidden or moved, so whatever is
    -- on screen stays where it is and just repaints from the fresh list;
    -- anything that came or went waits for PLAYER_REGEN_ENABLED.
    if combat then
        if not frame or not frame:IsShown() then return end
        local byId = {}
        for _, entry in ipairs(entries) do byId[entry.id] = entry end
        for _, entry in ipairs(pet or {}) do byId[entry.id] = entry end
        for _, btn in ipairs(frame.buttons) do
            local entry = btn:IsShown() and btn.entry and byId[btn.entry.id]
            if entry then PaintButton(btn, entry) end
        end
        if divider and divider:IsShown() and pet ~= nil then
            PaintDivider(pet, collapsed)
        end
        for _, p in pairs(pickers) do PaintPicker(p) end
        return
    end

    local revealAt = nil
    -- "Hide completed buffs from other classes": a done buff somebody else
    -- casts goes, while your own class's buffs and everything you supply
    -- yourself (food, elixirs, weapons, aura/aspect) stay.
    local _, classToken = UnitClass("player")
    local myClass = Assign.GetClassInfoByToken(classToken)
    myClass = myClass and myClass.name
    local function Hideable(entry)
        if settings.buffChecklistHideHave then return true end
        return settings.buffChecklistHideOthersHave and not entry.selfSupplied
            and entry.className ~= nil and entry.className ~= myClass
    end
    local function Visible(list)
        local out = {}
        for _, entry in ipairs(list) do
            local quiet = Hideable(entry) and entry.has == true
                and not entry.missing and not IsExpiring(entry) and not entry.otherActive
            if not quiet then
                out[#out + 1] = entry
            elseif entry.remaining then
                local at = GetTime() + entry.remaining - WarnSeconds()
                if not revealAt or at < revealAt then revealAt = at end
            end
        end
        return out
    end
    local shown = Visible(entries)
    local petShown = pet and Visible(pet) or {}
    local petLaid = collapsed and {} or petShown
    -- A hunter's divider stays up while it has something to say: no pet out,
    -- or pet buffs on the list -- collapsed or not, it carries the count.
    local showDivider = pet == false or #petShown > 0
    if #shown == 0 and not showDivider then
        HideFrame()
        -- Nothing is on screen to tick, so a hidden buff running down would
        -- never be noticed: wait for it on a timer instead. One at a time --
        -- this runs on every buff-tracking repaint.
        if revealAt and not (pendingReveal and pendingReveal <= revealAt) then
            pendingReveal = revealAt
            C_Timer.After(math.max(0.25, revealAt - GetTime()), function()
                if pendingReveal ~= revealAt then return end
                pendingReveal = nil
                WhoDoesWhat:RefreshBuffChecklist()
            end)
        end
        return
    end

    local f = EnsureFrame()
    f.revealAt = revealAt
    local size = self:GetBuffChecklistIconSize()
    local columns = math.max(1, math.min(self:GetBuffChecklistColumns(),
        math.max(#shown, #petLaid)))
    local header = settings.buffChecklistShowHeader and true or false
    f.title:SetShown(header)
    f.titleBg:SetShown(header)
    local y = INSET + (header and (TITLE_H + 2) or PAD)
    local right = self:GetBuffChecklistAlign() == "RIGHT"

    -- One grid block, starting at y; the button pool runs straight on through
    -- both sections.
    local used = 0
    local function PlaceGrid(list)
        for i, entry in ipairs(list) do
            used = used + 1
            local btn = f.buttons[used] or CreateButton(used)
            SizeButton(btn, size)
            local col, row = (i - 1) % columns, math.floor((i - 1) / columns)
            local by = -(y + row * (size + GAP))
            btn:ClearAllPoints()
            if right then
                -- Mirrored: the first icon takes the top-right corner and
                -- rows fill leftwards, so a short last row hugs the right.
                btn:SetPoint("TOPRIGHT", f, "TOPRIGHT",
                    -(INSET + PAD + col * (size + GAP)), by)
            else
                btn:SetPoint("TOPLEFT", f, "TOPLEFT",
                    INSET + PAD + col * (size + GAP), by)
            end
            btn:Show()
            PaintButton(btn, entry)
        end
        local rows = math.ceil(#list / columns)
        if rows > 0 then y = y + rows * (size + GAP) - GAP end
    end

    PlaceGrid(shown)
    local dividerW = 0
    if showDivider then
        if #shown > 0 then y = y + GAP end
        local d = EnsureDivider()
        d:ClearAllPoints()
        d:SetPoint("TOPLEFT", f, "TOPLEFT", INSET + PAD, -y)
        d:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(INSET + PAD), -y)
        PaintDivider(pet, collapsed)
        d:Show()
        y = y + DIVIDER_H
        dividerW = INSET * 2 + PAD * 2 + math.ceil(d.label:GetStringWidth())
            + DIVIDER_ARROW + 7 + DIVIDER_LINE_MIN * 2
        if #petLaid > 0 then
            y = y + GAP
            PlaceGrid(petLaid)
        end
    elseif divider then
        divider:Hide()
    end

    for i = used + 1, #f.buttons do
        self:ApplyStatusBarHighlight(f.buttons[i].highlightHost, false,
            WhoDoesWhat:GetBuffChecklistGlowStyle())
        f.buttons[i].entry = nil
        f.buttons[i]:Hide()
    end
    -- A grid narrower than the header's name or the divider's label widens to
    -- fit it; the icons stay against the aligned edge.
    local width = INSET * 2 + PAD * 2 + columns * size + (columns - 1) * GAP
    if header then
        width = math.max(width, INSET * 2
            + math.ceil(f.title.text:GetStringWidth()) + TITLE_TEXT_PAD * 2)
    end
    width = math.max(width, dividerW)
    f:SetSize(width, y + PAD + INSET)
    f:Show()
    if not f.moving then LoadPosition() end

    -- Now the icons carry their slots, an open picker whose icon moved on can
    -- be told apart and closed.
    FillPickers({ entries, pet or {} })
end

local RESET_SETTINGS = {
    "buffChecklistEnabled", "buffChecklistColumns", "buffChecklistIconSize",
    "buffChecklistHideHave", "buffChecklistAlign", "buffChecklistShowHeader",
    "buffChecklistPopoutDirection",
    "buffChecklistHideOthersHave", "buffChecklistGlowStyle", "buffChecklistWarnMinutes",
    "buffChecklistGlowMissingColor", "buffChecklistGlowExpiringColor",
}

-- Picks are left alone: they are this character's stock, not an option.
function WhoDoesWhat:ResetBuffChecklistSettings()
    self:RestoreDefaultSettings(RESET_SETTINGS)
    self.db.char.buffChecklistWeapons = true
    self.db.char.buffChecklistElixirs = true
    self.db.char.buffChecklistScrolls = true
    self.db.profile.settings.buffChecklistPos = nil
    if frame and not InCombatLockdown() then LoadPosition() end
    self:RefreshBuffChecklist()
end

-- Buff arrivals ride RefreshBoardViews. Caught here: the roster changing
-- under you (a warrior joining your party), a weapon enchant landing or
-- lapsing or a weapon swapped (UNIT_INVENTORY_CHANGED), bag counts moving,
-- and the end of combat settling whatever the fight deferred.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("GROUP_ROSTER_UPDATE")
loader:RegisterEvent("PLAYER_REGEN_ENABLED")
loader:RegisterEvent("BAG_UPDATE_DELAYED")
loader:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
-- Elixirs, flasks, auras, aspects and Omen of Clarity aren't BuffTracking
-- auras, so nothing else repaints when one lands or drops; and the pet's own
-- changes (BuffTracking scans your pet on its UNIT_AURA) otherwise wait out
-- the board's once-a-second notify. Auras churn in a fight, so a burst
-- collapses into one refresh a moment later -- late enough that BuffTracking
-- has already rescanned whatever fired it.
loader:RegisterUnitEvent("UNIT_AURA", "player", "pet")
-- A pet summoned, dismissed, dead or revived.
loader:RegisterUnitEvent("UNIT_PET", "player")
loader:RegisterUnitEvent("UNIT_HEALTH", "pet")
-- A respec or a new rank: which auras, aspects and talents you have.
loader:RegisterEvent("SPELLS_CHANGED")
-- An item name the pickers are showing "Gathering Data..." for.
loader:RegisterEvent("GET_ITEM_INFO_RECEIVED")
local AURA_REFRESH_DELAY = 0.15
local auraRefreshPending = false

-- Also asked for by a click on the grid: the item or spell a right-click used
-- lands a beat later, and the checklist should follow it without waiting.
local function RefreshSoon(delay)
    if auraRefreshPending then return end
    auraRefreshPending = true
    C_Timer.After(delay or AURA_REFRESH_DELAY, function()
        auraRefreshPending = false
        WhoDoesWhat:RefreshBuffChecklist()
    end)
end
RequestChecklistRefresh = RefreshSoon

local lastPetDead = nil
loader:SetScript("OnEvent", function(_, event, arg1)
    if event == "GET_ITEM_INFO_RECEIVED" then
        -- A burst of names on login collapses into one repaint.
        if pendingItemNames[arg1] then
            pendingItemNames[arg1] = nil
            RefreshSoon()
        end
        return
    end
    if event == "SPELLS_CHANGED" then wipe(talentedSelfCasts) end
    if event == "BAG_UPDATE_DELAYED" or event == "PLAYER_ENTERING_WORLD" then
        bagItems = nil
    end
    if event == "UNIT_HEALTH" then
        -- Only a death or a revive matters here, not every tick of damage.
        local dead = UnitIsDead("pet") and true or false
        if dead == lastPetDead then return end
        lastPetDead = dead
        RefreshSoon()
        return
    end
    if event == "UNIT_AURA" then
        RefreshSoon()
        return
    end
    WhoDoesWhat:RefreshBuffChecklist()
    if event ~= "PLAYER_ENTERING_WORLD" then return end
    C_Timer.After(2, function() WhoDoesWhat:RefreshBuffChecklist() end)
end)
