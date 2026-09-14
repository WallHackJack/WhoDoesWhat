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
-- weapon). Flasks are offered for both elixir slots and fill both. A weapon can also be told to
-- stay bare, for melee hoping for Windfury: right-click then strips whatever
-- enchant is on it, and Windfury itself counts as bare.
--
-- Right-click using an item is a protected action, so the grid's icons are
-- secure buttons. That brings the Shout Bar's combat discipline with it: a
-- secure button cannot be created, shown, hidden, moved or re-pointed mid-
-- fight, so in combat this file repaints icons, glows and countdowns only, and
-- PLAYER_REGEN_ENABLED settles the layout. The picker itself only writes a
-- saved choice, so it is an ordinary frame and works any time.
--
-- Wraps into rows at the configured column count. With "Hide buffs I have" on
-- the grid shrinks to what is still missing or expiring, and with nothing left
-- to show the window hides altogether.

local frame = nil
local picker = nil

local INSET = 3
local PAD = 3
local GAP = 4
-- The optional header strip, the Paladin Bar's height and colour.
local TITLE_H = 12
local TITLE_TEXT_PAD = 6
WhoDoesWhat.BUFF_CHECKLIST_ICON_SIZE = { min = 16, max = 64, default = 28 }
WhoDoesWhat.BUFF_CHECKLIST_COLUMNS = { min = 1, max = 12, default = 6 }

-- A buff this close to dropping glows blue and counts down on its icon.
local EXPIRING_SECONDS = 60
local GLOW_STYLE = "flash"
local MISSING_GLOW_COLOR = { r = 0.949, g = 0.71, b = 0 }
local EXPIRING_GLOW_COLOR = { r = 0.157, g = 0.561, b = 1 }
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
-- which side a short last row hugs. Encoded as the saved anchor point, like
-- the Shout Bar's anchor, so a stored position describes itself.
local ALIGN_POINTS = { LEFT = "TOPLEFT", RIGHT = "TOPRIGHT" }
WhoDoesWhat.BuffChecklistAligns = {
    { key = "LEFT", label = "Left" },
    { key = "RIGHT", label = "Right" },
}

function WhoDoesWhat:GetBuffChecklistAlign()
    local align = self.db.profile.settings.buffChecklistAlign
    return ALIGN_POINTS[align] and align or "LEFT"
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
local ITEM_CLASS_CONSUMABLE = 0
local ITEM_CLASS_WEAPON = 2
local WINDFURY_ICON = "Interface\\Icons\\Spell_Nature_Windfury"

-- hand is GetWeaponEnchantInfo's / CancelItemTempEnchantment's 1 or 2.
local WEAPON_SLOTS = {
    { key = "mainHand", slot = 16, hand = 1, name = "Main Hand" },
    { key = "offHand", slot = 17, hand = 2, name = "Off Hand" },
}

local weaponItems = {}
for _, id in ipairs(WhoDoesWhat.WeaponEnchantItems) do weaponItems[id] = true end

local function Picks()
    return WhoDoesWhat.db.char.buffChecklistItems
end

local function ItemName(id)
    return GetItemInfo(id)
        or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
        or ("item " .. id)
end

-- Whether a tooltip the setter fills has a line containing `needle`
-- (lowercase), or nil when it came back empty -- item data not loaded yet,
-- which is not an answer worth caching. English text, like BuffTracking's
-- aura-name matching.
local scanTip
local function TooltipContains(setter, needle)
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "WhoDoesWhatChecklistScanTip", nil,
            "GameTooltipTemplate")
    end
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:ClearLines()
    setter(scanTip)
    local lines = scanTip:NumLines()
    if lines == 0 then return nil end
    for i = 1, lines do
        local fs = _G["WhoDoesWhatChecklistScanTipTextLeft" .. i]
        local text = fs and fs:GetText()
        if text and string.find(string.lower(text), needle, 1, true) then
            return true
        end
    end
    return false
end

-- Food that makes you Well Fed, as opposed to food that only heals. Nothing in
-- the item data tells them apart, so it is read off the tooltip once per item.
local buffFood = {}
local function IsBuffFood(id, bag, slot)
    if buffFood[id] == nil then
        local _, _, _, _, _, classID = GetItemInfoInstant(id)
        if classID ~= ITEM_CLASS_CONSUMABLE or not GetItemSpell(id) then
            buffFood[id] = false
        else
            buffFood[id] = TooltipContains(function(tip)
                tip:SetBagItem(bag, slot)
            end, "well fed")
        end
    end
    return buffFood[id] == true
end

-- The two elixir slots (TBC only; ElixirItems is nil on Classic Era). Each
-- picker lists its own category plus flasks, which fill both.
local ELIXIR_SLOTS = {
    { key = "battleElixir", category = "battle", name = "Battle Elixir",
      defaultIcon = 22831 }, -- Elixir of Major Agility
    { key = "guardianElixir", category = "guardian", name = "Guardian Elixir",
      defaultIcon = 32067 }, -- Elixir of Draenic Wisdom
}

-- item id -> "battle" / "guardian" / "flask", and per picker which ids it
-- offers.
local elixirCategory, elixirChoices = {}, {}
for category, ids in pairs(WhoDoesWhat.ElixirItems or {}) do
    for _, id in ipairs(ids) do elixirCategory[id] = category end
end
for _, slot in ipairs(ELIXIR_SLOTS) do
    elixirChoices[slot.key] = {}
    for id, category in pairs(elixirCategory) do
        if category == slot.category or category == "flask" then
            elixirChoices[slot.key][id] = true
        end
    end
end

-- An elixir's aura is its use-spell, so the category of an aura on you is
-- found by resolving each listed item's spell. Item data loads on demand,
-- so ids not answered yet are asked for again on the next pass.
local elixirBySpellId, elixirBySpellName = {}, {}
local unresolvedElixirs = {}
for id in pairs(elixirCategory) do unresolvedElixirs[id] = true end

local function ResolveElixirSpells()
    for id in pairs(unresolvedElixirs) do
        local name, spellId = GetItemSpell(id)
        if name then
            elixirBySpellName[name] = elixirCategory[id]
            if spellId then elixirBySpellId[spellId] = elixirCategory[id] end
            unresolvedElixirs[id] = nil
        elseif C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(id)
        end
    end
end

-- The battle-slot and guardian-slot elixir on you, each { name, icon,
-- remaining } or nil. A flask answers for both.
local GetBuffDataByIndex = C_UnitAuras and C_UnitAuras.GetBuffDataByIndex
local function ActiveElixirs()
    if next(unresolvedElixirs) then ResolveElixirSpells() end
    local battle, guardian
    for i = 1, 40 do
        local name, icon, expirationTime, spellId
        if GetBuffDataByIndex then
            local aura = GetBuffDataByIndex("player", i)
            if not aura then break end
            name, icon, expirationTime, spellId =
                aura.name, aura.icon, aura.expirationTime, aura.spellId
        else
            local _
            name, icon, _, _, _, expirationTime, _, _, _, spellId = UnitBuff("player", i)
            if not name then break end
        end
        local category = spellId and elixirBySpellId[spellId]
            or elixirBySpellName[name]
        if category then
            local found = {
                name = name, icon = icon,
                remaining = expirationTime and expirationTime > 0
                    and expirationTime - GetTime() or nil,
            }
            if category ~= "guardian" then battle = found end
            if category ~= "battle" then guardian = found end
        end
    end
    return battle, guardian
end

-- Distinct item ids in your bags a picker offers, by name. `kind` is "food",
-- an elixir slot key, or a weapon slot key for the weapon enchant list.
local function BagChoices(kind)
    local seen, out = {}, {}
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, GetContainerNumSlots(bag) or 0 do
            local id = GetContainerItemID(bag, slot)
            if id and not seen[id] then
                seen[id] = true
                local wanted
                if kind == "food" then
                    wanted = IsBuffFood(id, bag, slot)
                elseif elixirChoices[kind] then
                    wanted = elixirChoices[kind][id]
                else
                    wanted = weaponItems[id] and GetItemSpell(id) ~= nil
                end
                if wanted then out[#out + 1] = id end
            end
        end
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

-- Is the temporary enchant on this weapon Windfury? The totem's and the
-- shaman's own both put it in the weapon's tooltip by name. Cached by enchant
-- id where the client gives one, since this can run on every repaint.
local windfuryEnchants = {}
local function IsWindfury(slot, enchantID)
    if enchantID and windfuryEnchants[enchantID] ~= nil then
        return windfuryEnchants[enchantID]
    end
    local found = TooltipContains(function(tip)
        tip:SetInventoryItem("player", slot)
    end, "windfury")
    if enchantID and found ~= nil then windfuryEnchants[enchantID] = found end
    return found == true
end

local function ApplyPick(entry, pick)
    if not pick then return end
    entry.useItem = pick
    entry.useCount = GetItemCount(pick)
    entry.icon = GetItemIcon(pick) or entry.icon
end

-- The model's list plus what only this character's bags and gear can say: the
-- picked food on the food entry, a battle and a guardian elixir, and one
-- entry per wielded weapon.
--
-- Extra fields on those entries:
--   pick      "food" / an elixir slot key / "mainHand" / "offHand": left-click
--             opens a picker
--   pickNoun, useVerb   how the tooltip names the pick and its right-click
--   useItem   the picked item id, useCount how many are in your bags
--   activeName          the elixir or flask on you, when it isn't the pick
--   slot, hand     the weapon's inventory slot and enchant hand
--   bare      the weapon is meant to stay unenchanted; enchanted / windfury
--             say what is on it
local function CollectEntries()
    local entries = Assign.GetPlayerBuffChecklist()
    local picks = Picks()
    for _, entry in ipairs(entries) do
        if entry.key == "food" then
            entry.pick, entry.pickNoun, entry.useVerb = "food", "food", "Eat"
            ApplyPick(entry, picks.food)
        end
    end

    if WhoDoesWhat.ElixirItems and WhoDoesWhat.db.char.buffChecklistElixirs then
        local battle, guardian = ActiveElixirs()
        for _, slot in ipairs(ELIXIR_SLOTS) do
            local active = slot.category == "battle" and battle or guardian
            local entry = {
                id = "elixir:" .. slot.key, key = slot.key, pick = slot.key,
                pickNoun = "elixir", useVerb = "Drink",
                name = slot.name, selfSupplied = true,
                has = active ~= nil, missing = active == nil,
                remaining = active and active.remaining,
                activeName = active and active.name,
                icon = active and active.icon or GetItemIcon(slot.defaultIcon),
            }
            ApplyPick(entry, picks[slot.key])
            -- What is on you outranks what you would drink next.
            if active and active.icon then entry.icon = active.icon end
            entries[#entries + 1] = entry
        end
    end

    if not WhoDoesWhat.db.char.buffChecklistWeapons then return entries end

    local states = { WeaponEnchantState() }
    for _, weapon in ipairs(WEAPON_SLOTS) do
        if WieldsWeapon(weapon.slot) then
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
                entry.windfury = enchanted and IsWindfury(weapon.slot, state[3])
                entry.has = not enchanted or entry.windfury
            else
                entry.name = weapon.name .. " Enchant"
                entry.has = enchanted
                local ms = state[2]
                entry.remaining = enchanted and ms and ms > 0 and ms / 1000 or nil
                ApplyPick(entry, pick)
            end
            entry.missing = not entry.has
            entries[#entries + 1] = entry
        end
    end
    return entries
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
    local text = "[WhoDoesWhat] " .. entry.name .. " please!"
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
local PICKER_HEADER_H = 20
local PICKER_ROW_H = 20

local PICKER_TITLES = {
    food = "Food", mainHand = "Main Hand", offHand = "Off Hand",
    battleElixir = "Battle Elixir", guardianElixir = "Guardian Elixir",
}
-- By the entry's pickNoun.
local PICKER_EMPTY = {
    food = "No Well Fed food in your bags.",
    elixir = "No elixirs or flasks for this slot in your bags.",
    enchant = "No oils, stones or poisons in your bags.",
}

local function HidePicker()
    if picker then picker:Hide() end
end

local function PickValue(value)
    local owner = picker.owner
    Picks()[picker.kind] = value or nil
    picker:Hide()
    WhoDoesWhat:RefreshBuffChecklist()
    if owner and GameTooltip:GetOwner() == owner then GameTooltip:Hide() end
end

local function PickerRow(index)
    local row = picker.rows[index]
    if row then return row end
    row = CreateFrame("Button", nil, picker)
    row:SetHeight(PICKER_ROW_H)
    local y = -(INSET + PICKER_HEADER_H + (index - 1) * PICKER_ROW_H)
    row:SetPoint("TOPLEFT", INSET + 2, y)
    row:SetPoint("TOPRIGHT", -(INSET + 2), y)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    local selected = row:CreateTexture(nil, "BACKGROUND")
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

    row:SetScript("OnClick", function(self)
        if self.choosable then PickValue(self.value) end
    end)
    row:SetScript("OnEnter", function(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.itemID)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    picker.rows[index] = row
    return row
end

local function EnsurePicker()
    if picker then return picker end
    picker = CreateFrame("Frame", "WhoDoesWhatBuffChecklistPicker", UIParent,
        "BackdropTemplate")
    picker:SetFrameStrata("DIALOG")
    picker:SetClampedToScreen(true)
    picker:EnableMouse(true)
    picker:SetWidth(PICKER_W)
    picker:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = INSET, right = INSET, top = INSET, bottom = INSET },
    })
    picker:SetBackdropColor(0.14, 0.14, 0.16, 0.97)
    picker:SetBackdropBorderColor(0.4, 0.4, 0.4)

    local title = picker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", INSET + 5, -(INSET + 4))
    picker.title = title
    local hint = picker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPRIGHT", -(INSET + 5), -(INSET + 5))
    hint:SetTextColor(0.4, 0.7, 1)
    hint:SetText("Right-click the icon to use")
    picker.rows = {}
    picker:Hide()
    -- Escape closes it, like any other pop-up.
    tinsert(UISpecialFrames, picker:GetName())
    return picker
end

-- Fill the picker for `btn`'s entry and put it under the button. Re-run by the
-- refresh while it is open, so the bag counts stay honest.
local function FillPicker(btn)
    local entry = btn.entry
    local kind = entry.pick
    local current = Picks()[kind]
    local rows = {}
    if entry.slot then
        rows[#rows + 1] = { value = false, text = "Any enchant (nothing to apply)",
            icon = 134400 } -- INV_Misc_QuestionMark
        rows[#rows + 1] = { value = "none", text = "No enchant (for Windfury)",
            icon = WINDFURY_ICON }
    else
        rows[#rows + 1] = { value = false, text = "Nothing picked", icon = 134400 }
    end
    local listed = {}
    local choices = BagChoices(kind)
    for _, id in ipairs(choices) do
        listed[id] = true
        rows[#rows + 1] = { value = id, itemID = id }
    end
    -- A pick you have run out of stays on the list, so it can be seen and
    -- changed.
    if type(current) == "number" and not listed[current] then
        rows[#rows + 1] = { value = current, itemID = current }
    end
    local empty = #choices == 0

    picker.title:SetText(PICKER_TITLES[kind])
    local shown = #rows + (empty and 1 or 0)
    for i, spec in ipairs(rows) do
        local row = PickerRow(i)
        row.value, row.itemID, row.choosable = spec.value, spec.itemID, true
        if spec.itemID then
            local count = GetItemCount(spec.itemID)
            row.icon:SetTexture(GetItemIcon(spec.itemID))
            row.text:SetText(ItemName(spec.itemID))
            row.count:SetText(count)
            if count > 0 then
                row.count:SetTextColor(1, 0.82, 0)
            else
                row.count:SetTextColor(1, 0.3, 0.3)
            end
            row.icon:SetDesaturated(count == 0)
        else
            row.icon:SetTexture(spec.icon)
            row.icon:SetDesaturated(false)
            row.text:SetText(spec.text)
            row.count:SetText("")
        end
        row.selected:SetShown((current or false) == spec.value)
        row:Show()
    end
    if empty then
        local row = PickerRow(#rows + 1)
        row.value, row.itemID, row.choosable = nil, nil, false
        row.icon:SetTexture(nil)
        row.text:SetText("|cff999999" .. PICKER_EMPTY[entry.pickNoun] .. "|r")
        row.count:SetText("")
        row.selected:Hide()
        row:Show()
    end
    for i = shown + 1, #picker.rows do picker.rows[i]:Hide() end
    picker:SetHeight(INSET * 2 + PICKER_HEADER_H + shown * PICKER_ROW_H + 2)

    picker.owner, picker.kind = btn, kind
    picker:ClearAllPoints()
    if WhoDoesWhat:GetBuffChecklistAlign() == "RIGHT" then
        picker:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
    else
        picker:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    end
end

local function TogglePicker(btn)
    EnsurePicker()
    if picker:IsShown() and picker.owner == btn then
        picker:Hide()
        return
    end
    GameTooltip:Hide()
    FillPicker(btn)
    picker:Show()
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

local function IsExpiring(entry)
    return entry.has == true and entry.remaining ~= nil
        and entry.remaining < EXPIRING_SECONDS
end

local function CanUse(entry)
    return entry.useItem ~= nil and (entry.useCount or 0) > 0
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
    if not entry or (picker and picker:IsShown()) then return end
    GameTooltip:SetOwner(btn, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, 0)
    GameTooltip:SetText(entry.name, 1, 1, 1)
    if entry.bare then
        if entry.windfury then
            GameTooltip:AddLine("Windfury is on it.", 0.3, 1, 0.3)
        elseif entry.enchanted then
            GameTooltip:AddLine("Has an enchant, so Windfury can't land.", 1, 0.3, 0.3)
        else
            GameTooltip:AddLine("Bare, ready for Windfury.", 0.3, 1, 0.3)
        end
    elseif entry.slot then
        if entry.enchanted then
            AddTimeLeftLine(btn, "Enchanted")
        else
            GameTooltip:AddLine("No enchant.", 1, 0.3, 0.3)
        end
    elseif entry.has == nil then
        GameTooltip:AddLine("Not scanned yet.", 0.6, 0.6, 0.6)
    elseif entry.has == false then
        GameTooltip:AddLine("Missing.", 1, 0.3, 0.3)
    else
        AddTimeLeftLine(btn, entry.activeName and ("On you: " .. entry.activeName)
            or "On you")
        local source = not entry.selfSupplied
            and WhoDoesWhat:GetBuffSource(UnitName("player"), entry.key)
        if source then
            GameTooltip:AddLine("From " .. WhoDoesWhat:DisplayName(source) .. ".",
                0.8, 0.8, 0.8)
        end
        if entry.note then GameTooltip:AddLine(entry.note, 1, 0.6, 0.2, true) end
    end

    local noun = entry.pickNoun
    if entry.pick and not entry.bare then
        if entry.useItem then
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
    if entry.pick then
        UI.AddTooltipHint(GameTooltip, "Left-Click:", "Pick " .. noun)
        if entry.bare then
            if entry.enchanted and not entry.windfury then
                UI.AddTooltipHint(GameTooltip, "Right-Click:", "Remove enchant")
            end
        elseif CanUse(entry) then
            UI.AddTooltipHint(GameTooltip, "Right-Click:",
                entry.useVerb .. " " .. ItemName(entry.useItem))
        end
    end
    local ask = not entry.selfSupplied and (entry.isShout and "Ask your party"
        or entry.askName and ("Ask " .. WhoDoesWhat:DisplayName(entry.askName)))
    if ask then UI.AddTooltipHint(GameTooltip, "Shift-Click:", ask) end
    UI.AddTooltipHint(GameTooltip, "Alt-Drag:", "Move")
    UI.AddTooltipHint(GameTooltip, "Shift-Right-Click:", "Buff Checklist Settings")
    GameTooltip:Show()
end

local function SizeButton(btn, size)
    if btn.sizedAt == size then return end
    btn.sizedAt = size
    btn:SetSize(size, size)
    local face, _, flags = btn.timer:GetFont()
    btn.timer:SetFont(face or FALLBACK_FONT,
        math.max(9, math.floor(size * TIMER_FONT_RATIO + 0.5)), flags)
end

-- Point right-click at the entry's picked item: a macro for a weapon, since
-- an oil has to be used and then aimed at the slot (the classic
-- "/use item" + "/use 16" pair), and a plain item use for food. Out of combat
-- only, and only written when it changed -- the same button can be any entry
-- from one repaint to the next.
local function ConfigureUse(btn, entry)
    if InCombatLockdown() then return end
    local kind, value
    if CanUse(entry) then
        if entry.slot then
            kind = "macro"
            value = string.format("/use item:%d\n/use %d", entry.useItem, entry.slot)
        else
            kind, value = "item", "item:" .. entry.useItem
        end
    end
    local stamp = kind and (kind .. value) or ""
    if btn.useStamp == stamp then return end
    btn.useStamp = stamp
    btn:SetAttribute("type2", kind)
    btn:SetAttribute("macrotext2", kind == "macro" and value or nil)
    btn:SetAttribute("item2", kind == "item" and value or nil)
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

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(0, 0, 0, 0.9)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn.icon = icon

    local timer = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    timer:SetPoint("CENTER")
    timer:SetFont(GameFontNormal:GetFont() or FALLBACK_FONT, 16, "OUTLINE")
    timer:SetTextColor(EXPIRING_GLOW_COLOR.r, EXPIRING_GLOW_COLOR.g,
        EXPIRING_GLOW_COLOR.b)
    timer:Hide()
    btn.timer = timer

    btn:SetScript("OnEnter", ShowTooltip)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UI.AttachDrag(btn, frame)
    btn:SetScript("PostClick", function(self, mouseButton, down)
        local entry = self.entry
        if down or not entry or IsAltKeyDown() then return end
        if mouseButton == "RightButton" then
            if IsShiftKeyDown() then
                WhoDoesWhat:OpenAddonSettingsView("Checklist")
            elseif entry.bare then
                if entry.enchanted and not entry.windfury then
                    CancelItemTempEnchantment(entry.hand)
                end
            elseif entry.pick and not CanUse(entry) then
                -- Nothing to use yet: offer the choice instead.
                TogglePicker(self)
            end
        elseif IsShiftKeyDown() then
            if not entry.selfSupplied and (entry.missing or IsExpiring(entry)) then
                AskFor(entry)
            end
        elseif entry.pick then
            TogglePicker(self)
        end
    end)
    btn:Hide()
    frame.buttons[index] = btn
    return btn
end

-- The countdown over the icon, off the stored expiry, and the glow that goes
-- with it. Split out so the tick can run it between repaints.
local function UpdateTimerAndGlow(btn)
    local entry = btn.entry
    local remaining = btn.expiresAt and (btn.expiresAt - GetTime())
    local expiring = entry.has == true and remaining ~= nil and remaining > 0
        and remaining < EXPIRING_SECONDS
    if expiring then
        btn.timer:SetFormattedText("%d", math.ceil(remaining))
    end
    btn.timer:SetShown(expiring)
    local color = entry.missing and MISSING_GLOW_COLOR
        or expiring and EXPIRING_GLOW_COLOR or nil
    WhoDoesWhat:ApplyStatusBarHighlight(btn.highlightHost, color ~= nil,
        GLOW_STYLE, color)
end

local function PaintButton(btn, entry)
    btn.entry = entry
    btn.expiresAt = entry.remaining and (GetTime() + entry.remaining) or nil
    btn.icon:SetTexture(entry.icon)
    -- Grey unless it is actually on you; unknown reads as not-yet rather than
    -- as missing, so it greys without glowing.
    btn.icon:SetDesaturated(entry.has ~= true or entry.missing)
    ConfigureUse(btn, entry)
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
    local titleBg = title:CreateTexture(nil, "ARTWORK")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(unpack(WhoDoesWhat.Theme.window.titleBarColor))
    local titleText = title:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleText:SetPoint("CENTER")
    titleText:SetText("Buff Checklist")
    title.text = titleText
    UI.AttachDrag(title, frame)
    title:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        GameTooltip:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, 0)
        GameTooltip:SetText("|T" .. WhoDoesWhat.ADDON_ICON .. ":16:16:0:0|t "
            .. "WhoDoesWhat Buff Checklist", 1, 1, 1)
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
        OnStart = HidePicker,
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

-- When the hidden-frame reveal timer below is due, or nil with none waiting.
local pendingReveal = nil

-- Out of combat only: it hides secure buttons and the frame parenting them.
local function HideFrame()
    HidePicker()
    if not frame then return end
    for _, btn in ipairs(frame.buttons) do
        WhoDoesWhat:ApplyStatusBarHighlight(btn.highlightHost, false, GLOW_STYLE)
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

    local entries = CollectEntries()

    -- Mid-fight nothing secure can be shown, hidden or moved, so whatever is
    -- on screen stays where it is and just repaints from the fresh list;
    -- anything that came or went waits for PLAYER_REGEN_ENABLED.
    if combat then
        if not frame or not frame:IsShown() then return end
        local byId = {}
        for _, entry in ipairs(entries) do byId[entry.id] = entry end
        for _, btn in ipairs(frame.buttons) do
            local entry = btn:IsShown() and btn.entry and byId[btn.entry.id]
            if entry then PaintButton(btn, entry) end
        end
        return
    end

    local shown, revealAt = {}, nil
    for _, entry in ipairs(entries) do
        local quiet = settings.buffChecklistHideHave and entry.has == true
            and not entry.missing and not IsExpiring(entry)
        if not quiet then
            shown[#shown + 1] = entry
        elseif entry.remaining then
            local at = GetTime() + entry.remaining - EXPIRING_SECONDS
            if not revealAt or at < revealAt then revealAt = at end
        end
    end
    if #shown == 0 then
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
    local columns = math.min(self:GetBuffChecklistColumns(), #shown)
    local rows = math.ceil(#shown / columns)
    local header = settings.buffChecklistShowHeader and true or false
    f.title:SetShown(header)
    local top = INSET + (header and (TITLE_H + 2) or PAD)
    local right = self:GetBuffChecklistAlign() == "RIGHT"
    for i, entry in ipairs(shown) do
        local btn = f.buttons[i] or CreateButton(i)
        SizeButton(btn, size)
        local col, row = (i - 1) % columns, math.floor((i - 1) / columns)
        local y = -(top + row * (size + GAP))
        btn:ClearAllPoints()
        if right then
            -- Still reads left to right; a short last row just sits against
            -- the right edge instead of the left.
            local inRow = math.min(columns, #shown - row * columns)
            btn:SetPoint("TOPRIGHT", f, "TOPRIGHT",
                -(INSET + PAD + (inRow - 1 - col) * (size + GAP)), y)
        else
            btn:SetPoint("TOPLEFT", f, "TOPLEFT", INSET + PAD + col * (size + GAP), y)
        end
        btn:Show()
        PaintButton(btn, entry)
    end
    for i = #shown + 1, #f.buttons do
        self:ApplyStatusBarHighlight(f.buttons[i].highlightHost, false, GLOW_STYLE)
        f.buttons[i].entry = nil
        f.buttons[i]:Hide()
    end
    -- A grid narrower than the header's name widens to fit it; the icons stay
    -- against the aligned edge.
    local width = INSET * 2 + PAD * 2 + columns * size + (columns - 1) * GAP
    if header then
        width = math.max(width, INSET * 2
            + math.ceil(f.title.text:GetStringWidth()) + TITLE_TEXT_PAD * 2)
    end
    f:SetSize(width, top + rows * size + (rows - 1) * GAP + PAD + INSET)
    f:Show()
    if not f.moving then LoadPosition() end

    -- An open picker follows its icon: gone with it, or refilled so the bag
    -- counts and the highlighted pick are current.
    if picker and picker:IsShown() then
        local owner = picker.owner
        if owner and owner:IsShown() and owner.entry
            and owner.entry.pick == picker.kind then
            FillPicker(owner)
        else
            picker:Hide()
        end
    end
end

local RESET_SETTINGS = {
    "buffChecklistEnabled", "buffChecklistColumns", "buffChecklistIconSize",
    "buffChecklistHideHave", "buffChecklistAlign", "buffChecklistShowHeader",
}

-- Picks are left alone: they are this character's stock, not an option.
function WhoDoesWhat:ResetBuffChecklistSettings()
    self:RestoreDefaultSettings(RESET_SETTINGS)
    self.db.char.buffChecklistWeapons = true
    self.db.char.buffChecklistElixirs = true
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
-- Elixirs and flasks aren't BuffTracking auras, so nothing else repaints when
-- one lands or drops. Your own auras churn in a fight, so these collapse into
-- one refresh every half second.
loader:RegisterUnitEvent("UNIT_AURA", "player")
local auraRefreshPending = false
loader:SetScript("OnEvent", function(_, event)
    if event == "UNIT_AURA" then
        if auraRefreshPending or not WhoDoesWhat.ElixirItems then return end
        auraRefreshPending = true
        C_Timer.After(0.5, function()
            auraRefreshPending = false
            WhoDoesWhat:RefreshBuffChecklist()
        end)
        return
    end
    WhoDoesWhat:RefreshBuffChecklist()
    if event ~= "PLAYER_ENTERING_WORLD" then return end
    C_Timer.After(2, function() WhoDoesWhat:RefreshBuffChecklist() end)
end)
