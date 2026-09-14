local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI

-- Curse value calculator. Pulls a fight from Details! and estimates how much
-- raid damage each client flavor's raid curses provided (or could provide).
--
-- Details records each spell's school bitmask and per-target damage, so the
-- magic curses use the appropriate school pools: Classic CoE fire/frost and
-- CoS shadow/arcane, or TBC CoE all four (10%, or 13% with Malediction).
--
-- CoR is an estimate. Damage through armor is m(A) = C/(A+C). We reconstruct
-- the boss's armor from the assumed debuff set the user ticks -- the exact
-- numbers Details can't know --
-- and compute the physical pool with vs. without CoR. Two deliberate
-- gaps, both surfaced in the footnote: bleeds are physical-school but ignore
-- armor, so a spell-id list drops them from the pool; and per-player armor pen
-- (trinkets, Executioner, gear) isn't tracked, offered instead as an optional
-- average the user fills in.

local K = WhoDoesWhat.SectionKit
local IS_CLASSIC_ERA = WhoDoesWhat.ClientFeatures.isClassicEra
local CURSES = WhoDoesWhat.WarlockCurses

-- The page is the Calculator tab of the main window, wider than it is tall,
-- laid out in section boxes on the page's dark ground:
--
--   Fight: picker, target, damage breakdown  | Curse of Recklessness
--   Boss Armor                               | Curse of the Elements
--                                            | Curse of Shadow / Blood Frenzy
--   footnote across the bottom
--
-- Each curse's own options sit at the top of its result box. Curse of
-- Recklessness is also an armor reduction, so its toggle appears in Boss Armor
-- as well; the two are one setting.
local GAP = 10
local LEFT_W = 520
local TARGET_STRIP_H = 24  -- Fight box: target and duration, above the rows
local BOX_ICON = 18
local LABEL_X = 6          -- a row's label and value from its edges
local INDENT = 14          -- per breakdown depth
-- Midline of a box's title strip, where its title, icon, tag and any header
-- dropdown all centre.
local STRIP_MID = UI.HEADER_STRIP_TOP + UI.HEADER_BTN_SIZE / 2
-- UIDropDownMenu carries ~16px of transparent padding past its visible box.
local DD_OVERHANG = 16

-- Damage that lands through armor A is C/(A+C). Classic uses the level-60
-- constant (400 + 85*60); TBC uses 467.5*70 - 22167.5.
local ARMOR_C = IS_CLASSIC_ERA and 5500 or 10557.5
local BOSS_ARMORS = IS_CLASSIC_ERA and { 3731, 3009, 4641 } or { 7700, 6200 }

-- Flat armor removed by each debuff (5-stack / 5-point / TBC ranks) and CoR.
local SUNDER = IS_CLASSIC_ERA and 2250 or 2600
local EXPOSE = IS_CLASSIC_ERA and 2550 or 3075 -- Improved Expose Armor
local FAERIE_FIRE = IS_CLASSIC_ERA and 505 or 610
local COR_ARMOR = IS_CLASSIC_ERA and 640 or 800

-- Magic-taken bonus from Curse of the Elements: base rank 4, or 13% with the
-- Affliction talent Malediction.
local COE_BASE = 0.10
local COE_MALEDICTION = 0.13

local BLOOD_FRENZY = 0.04

-- School bitmask: Physical 1, Holy 2, Fire 4, Nature 8, Frost 16, Shadow 32,
-- Arcane 64. In Classic, CoE covers fire/frost and CoS covers shadow/arcane;
-- in TBC, CoE covers all four schools.
local SCHOOL_PHYSICAL = 0x1
local COE_MASK = IS_CLASSIC_ERA and (0x4 + 0x10) or (0x4 + 0x10 + 0x20 + 0x40)
local COS_MASK = 0x20 + 0x40
local IGNITE_SPELL_ID = 12654

local BLOOD_FRENZY_ICON = "Interface\\Icons\\Ability_Warrior_BloodFrenzy"

-- Text colours: CoR orange, CoE a lifted warlock-purple (the class colour
-- itself reads dim on the tinted stripes), the Arms warrior's class tan, total
-- green, and a light grey for damage the curses don't touch. Values the curses
-- provided read green; values they could have provided read gold.
local C_COR = { 1, 0.5, 0 }
local C_COE = { 0.68, 0.61, 0.9 }
local C_ARMS = { 0.78, 0.61, 0.43 }
local C_TOTAL = { 0.25, 1, 0.25 }
local C_MUTED = { 0.74, 0.74, 0.74 }
local C_WHITE = { 1, 1, 1 }
local C_PROVIDED = C_TOTAL
local C_MISSED = WhoDoesWhat.Theme.gold
local MUTED_ESCAPE = "|cffbdbdbd"

-- The rows' text: GameFontHighlight with a thin outline, which is as close to
-- bold as the game font gets and keeps the numbers crisp on striped rows.
local ROW_FONT = CreateFont("WhoDoesWhatCalcRowFont")
do
    local path, size = GameFontHighlight:GetFont()
    ROW_FONT:SetFont(path, size, "OUTLINE")
    ROW_FONT:SetTextColor(1, 1, 1)
end

-- The Fight box's breakdown, one striped row per damage pool, indented under
-- the pool it splits. `key` is the BossPoolsFromCombat stat it shows.
local BREAKDOWN = {
    { key = "total", label = "Total damage to target", color = C_TOTAL },
    { key = "physAll", label = "Physical", depth = 1 },
    { key = "physNonBleed", label = "Armor-mitigated (CoR)", depth = 2, color = C_COR },
    { key = "bleeds", label = "Bleeds, which ignore armor", depth = 2, color = C_MUTED },
    { key = "magicAll", label = "Magic", depth = 1 },
}
if IS_CLASSIC_ERA then
    BREAKDOWN[#BREAKDOWN + 1] =
        { key = "coeRelevant", label = "Fire and Frost (CoE)", depth = 2, color = C_COE }
    BREAKDOWN[#BREAKDOWN + 1] =
        { key = "cosRelevant", label = "Shadow and Arcane (CoS)", depth = 2, color = C_COE }
else
    BREAKDOWN[#BREAKDOWN + 1] = { key = "coeRelevant",
        label = "Fire, Frost, Shadow and Arcane (CoE)", depth = 2, color = C_COE }
end
BREAKDOWN[#BREAKDOWN + 1] =
    { key = "magicOther", label = "Nature and Holy", depth = 2, color = C_MUTED }

-- Physical-school abilities that ignore armor (bleeds) -- they must not count
-- toward the CoR pool. Keyed by spell id; TBC ranks of the usual offenders.
-- Not exhaustive: a missed id just leaves that bleed in the pool (a small
-- over-count), never an error.
local BLEEDS = {}
for _, id in ipairs({
    -- Rip (Druid)
    1079, 9492, 9493, 9752, 9894, 9896, 27008,
    -- Rake periodic (Druid)
    1822, 1823, 1824, 9904, 27003,
    -- Lacerate (Druid)
    33745,
    -- Pounce Bleed (Druid)
    9007, 9824, 9826, 27007,
    -- Rend (Warrior)
    772, 6546, 6547, 6548, 11572, 11573, 11574, 25208,
    -- Deep Wounds (Warrior)
    12162, 12721, 12834, 12849, 12867, 12868,
    -- Rupture (Rogue)
    1943, 8639, 8640, 11273, 11274, 11275, 26867,
    -- Garrote (Rogue)
    703, 8631, 8632, 8633, 11289, 11290, 26839, 26884,
}) do
    BLEEDS[id] = true
end

-- Details! handle. Either global is fine; nil means it isn't loaded.
local function GetDetails()
    return _G.Details or _G._detalhes
end

-- Group thousands: 1234567 -> "1,234,567".
local function Commafy(n)
    n = math.floor(n + 0.5)
    local s = tostring(n)
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- Readable label for a Details combat: encounter name (or a segment number)
-- plus its length.
local function CombatLabel(combat)
    local name = combat.GetEncounterName and combat:GetEncounterName()
    if not name or name == "" then
        name = "Segment " .. tostring(combat.GetCombatNumber and combat:GetCombatNumber() or "?")
    end
    local t = (combat.GetCombatTime and combat:GetCombatTime()) or 0
    return string.format("%s (%d:%02d)", tostring(name), math.floor(t / 60), t % 60)
end

-- Walk a combat's damage actors (group players + their pets only, so the
-- boss's own hits on the tank -- and paladins' self-damage, which lands on
-- themselves -- never enter the total), bucket each spell's damage to each
-- target by school, then return the single most-damaged target as the boss
-- with a full breakdown of the damage dealt to it.
--   returns bossName, stats  (nil if no data). stats fields:
--     total          everything dealt to the target
--     physAll        physical school (includes bleeds)
--     bleeds         physical but armor-ignoring (the BLEEDS list)
--     physNonBleed   physAll - bleeds  -- what CoR acts on
--     magicAll       total - physAll   -- every non-physical school
--     coeRelevant    schools affected by this client's CoE
--     cosRelevant    Classic shadow/arcane damage affected by CoS
--     ignite         Classic Ignite damage (inside coeRelevant)
--     magicOther     magic unaffected by either curse
local function BossPoolsFromCombat(combat)
    local actors = combat.GetActorList and combat:GetActorList(1) -- 1 = damage
    if not actors then return nil end

    local perTarget = {}
    for _, actor in ipairs(actors) do
        local owner = actor.owner
        if actor.grupo or (type(owner) == "table" and owner.grupo) then
            local spells = actor.spells and actor.spells._ActorTable
            if spells then
                for spellId, spell in pairs(spells) do
                    local school = spell.spellschool or 0
                    local isBleed = BLEEDS[spellId]
                    local targets = spell.targets
                    if targets then
                        for targetName, amount in pairs(targets) do
                            if amount and amount > 0 then
                                local t = perTarget[targetName]
                                if not t then
                                    t = { total = 0, physAll = 0, bleeds = 0,
                                        coeRelevant = 0, cosRelevant = 0, ignite = 0 }
                                    perTarget[targetName] = t
                                end
                                t.total = t.total + amount
                                if school == SCHOOL_PHYSICAL then
                                    t.physAll = t.physAll + amount
                                    if isBleed then t.bleeds = t.bleeds + amount end
                                elseif bit.band(school, COE_MASK) ~= 0 then
                                    t.coeRelevant = t.coeRelevant + amount
                                    if IS_CLASSIC_ERA and spellId == IGNITE_SPELL_ID then
                                        t.ignite = t.ignite + amount
                                    end
                                elseif IS_CLASSIC_ERA and bit.band(school, COS_MASK) ~= 0 then
                                    t.cosRelevant = t.cosRelevant + amount
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Details knows the encounter boss for most raid segments. Prefer that
    -- exact target; older/non-encounter segments retain the old max-damage
    -- target heuristic as a fallback.
    local bossName = combat.GetBossName and combat:GetBossName() or combat.bossName
    local best = bossName and perTarget[bossName]
    if not best and combat.bossName then
        bossName = combat.bossName
        best = perTarget[bossName]
    end
    if not best then
        for name, t in pairs(perTarget) do
            if not best or t.total > best.total then
                best, bossName = t, name
            end
        end
    end
    if not best then return nil end

    return bossName, {
        total = best.total,
        physAll = best.physAll,
        bleeds = best.bleeds,
        physNonBleed = best.physAll - best.bleeds,
        magicAll = best.total - best.physAll,
        coeRelevant = best.coeRelevant,
        cosRelevant = best.cosRelevant,
        ignite = best.ignite,
        magicOther = (best.total - best.physAll)
            - best.coeRelevant - best.cosRelevant,
    }
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------

-- A section box on the page. opts: `tintClass` or `tintColor` ({ r, g, b })
-- tints it the way the Raid board tints its class sections, `icon` sits before
-- the title, `titleColor` recolours the title. Every box gets `box.tag`, a
-- small note right-aligned on its title strip.
local function CreateBox(f, title, opts)
    opts = opts or {}
    local color, border
    if opts.tintColor then
        color, border = K.ColorTint(unpack(opts.tintColor))
    else
        color, border = K.ClassTint(opts.tintClass)
    end
    local box = UI.CreateSectionBox(f, title, color, border)
    if opts.icon then
        local icon = box:CreateTexture(nil, "ARTWORK")
        icon:SetSize(BOX_ICON, BOX_ICON)
        icon:SetPoint("LEFT", box, "TOPLEFT", UI.BOX_PAD + 2, -STRIP_MID)
        icon:SetTexture(opts.icon)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        box.title:ClearAllPoints()
        box.title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    end
    if opts.titleColor then box.title:SetTextColor(unpack(opts.titleColor)) end
    box.tag = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    box.tag:SetPoint("RIGHT", box, "TOPRIGHT", -(UI.BOX_PAD + LABEL_X), -STRIP_MID)
    return box
end

-- A box's height with `rows` rows under its title and any reserved strip.
local function BoxHeight(box, rows)
    return UI.BOX_PAD + UI.SECTION_TITLE_H + (box.rowsInset or 0)
        + rows * UI.ROW_H + UI.BOX_PAD
end

-- A striped row: a label on the left, a value on the right.
local function AddValueRow(box, index, depth)
    local row = UI.CreateSectionRow(box, index)
    row.label = row:CreateFontString(nil, "OVERLAY")
    row.label:SetFontObject(ROW_FONT)
    row.label:SetPoint("LEFT", LABEL_X + (depth or 0) * INDENT, 0)
    row.value = row:CreateFontString(nil, "OVERLAY")
    row.value:SetFontObject(ROW_FONT)
    row.value:SetPoint("RIGHT", -LABEL_X, 0)
    row.value:SetJustifyH("RIGHT")
    return row
end

-- A striped row the whole left of which toggles its checkbox, with an optional
-- muted note on the right saying what the option is worth.
local function AddCheckRow(box, index, text, note, tooltip, onToggle)
    local row = UI.CreateSectionRow(box, index)
    local check = UI.AddRowCheckbox(row, text, text, tooltip, function(self)
        onToggle(self:GetChecked() and true or false)
    end)
    check.label:SetFontObject(ROW_FONT)
    local noteText = row:CreateFontString(nil, "OVERLAY")
    noteText:SetFontObject(ROW_FONT)
    noteText:SetPoint("RIGHT", -LABEL_X, 0)
    noteText:SetTextColor(unpack(C_MUTED))
    noteText:SetText(note or "")
    return check
end

-- ---------------------------------------------------------------------------
-- Recompute + render
-- ---------------------------------------------------------------------------

-- Fill one result box: the tag on its title strip, and each row from `lines`,
-- a list of { label, value, valueColor }. No lines blanks the box.
local function SetResult(result, tag, lines)
    result.box.tag:SetText(tag or "")
    for i, row in ipairs(result.rows) do
        local line = lines and lines[i]
        row.label:SetText(line and line[1] or "")
        row.value:SetText(line and line[2] or "")
        row.value:SetTextColor(unpack(line and line[3] or C_WHITE))
    end
end

-- Blank every readout, with a one-line status where the target goes.
local function ShowStatus(f, text)
    f.target:SetText(text)
    f.duration:SetText("")
    for _, row in ipairs(f.breakdownRows) do row.value:SetText("") end
    for _, result in pairs(f.results) do SetResult(result) end
end

local function Recompute(f)
    local Details = GetDetails()
    if not Details then
        ShowStatus(f, "|cffff5555Install or enable Details! to use the calculator.|r")
        return
    end

    local combat = f.selectedCombat
    if not combat then
        ShowStatus(f, "|cffaaaaaaPick a fight.|r")
        return
    end

    local boss, stats = BossPoolsFromCombat(combat)
    if not boss then
        ShowStatus(f, "|cffaaaaaaNo damage recorded in this fight.|r")
        return
    end

    local coePool, physPool = stats.coeRelevant, stats.physNonBleed

    local duration = (combat.GetCombatTime and combat:GetCombatTime()) or 0
    f.target:SetText("Target: |cffffffff" .. boss .. "|r")
    f.duration:SetText(string.format("Duration: |cffffffff%d:%02d|r",
        math.floor(duration / 60), duration % 60))
    for _, row in ipairs(f.breakdownRows) do
        row.value:SetText(Commafy(stats[row.key]))
    end

    -- A value with its per-second rate after it, in grey.
    local function WithDps(total)
        if duration > 0 then
            return Commafy(total) .. "  " .. MUTED_ESCAPE .. "(" .. Commafy(total / duration)
                .. " DPS)|r"
        end
        return Commafy(total)
    end

    -- A flat damage-taken bonus on one pool (the magic curses, Blood Frenzy).
    -- `noun` names the effect in the row labels.
    local function PercentBonus(result, noun, pool, rate, applied, specialPool, specialMultiplier)
        local normalPool = pool - (specialPool or 0)
        local multiplier = 1 + rate
        local tag = "+" .. math.floor(rate * 100 + 0.5) .. "%"
        if applied then
            local before = normalPool / multiplier
                + (specialPool or 0) / (specialMultiplier or multiplier)
            SetResult(result, tag, {
                { "Damage with " .. noun, Commafy(pool) },
                { "Damage before " .. noun, Commafy(before) },
                { "Provided", WithDps(pool - before), C_PROVIDED },
            })
        else
            local withBonus = normalPool * multiplier
                + (specialPool or 0) * (specialMultiplier or multiplier)
            SetResult(result, tag, {
                { "Damage now", Commafy(pool) },
                { "Damage with " .. noun, Commafy(withBonus) },
                { "Could have provided", WithDps(withBonus - pool), C_MISSED },
            })
        end
    end

    -- Curse of the Elements ---------------------------------------------------
    local coeRate = f.state.malediction and COE_MALEDICTION or COE_BASE
    local ignitePool = IS_CLASSIC_ERA and f.state.igniteDoubleDip and stats.ignite or 0
    PercentBonus(f.results.coe, "curse", coePool, coeRate, f.state.coe,
        ignitePool, ignitePool > 0 and 1.21 or nil)

    if IS_CLASSIC_ERA then
        PercentBonus(f.results.cos, "curse", stats.cosRelevant, COE_BASE, f.state.cos)
    end

    -- Curse of Recklessness ---------------------------------------------------
    local armorDebuff = (f.state.sunder and SUNDER) or (f.state.expose and EXPOSE) or 0
    local ff = f.state.ff and FAERIE_FIRE or 0
    local pen = tonumber(f.penEdit:GetText()) or 0
    local base = f.state.bossArmor
    local C = ARMOR_C
    local nonCorReduction = armorDebuff + ff + pen
    local corTag = "-" .. Commafy(COR_ARMOR) .. " armor"

    if f.state.cor then
        -- Reconstruct both states independently so a debuff set that already
        -- reaches zero armor cannot invent armor in the without-CoR state.
        local aWithout = math.max(base - nonCorReduction, 0)
        local aWith = math.max(aWithout - COR_ARMOR, 0)
        local before = physPool * (aWith + C) / (aWithout + C)
        SetResult(f.results.cor, corTag, {
            { "Damage with curse", Commafy(physPool) },
            { "Damage before curse", Commafy(before) },
            { "Provided", WithDps(physPool - before), C_PROVIDED },
        })
    else
        -- No CoR was up; recorded physical is the without-CoR number.
        local aNow = math.max(base - nonCorReduction, 0)
        local aWithCor = math.max(aNow - COR_ARMOR, 0)
        local withCor = physPool * (aNow + C) / (aWithCor + C)
        SetResult(f.results.cor, corTag, {
            { "Damage now", Commafy(physPool) },
            { "Damage with curse", Commafy(withCor) },
            { "Could have provided", WithDps(withCor - physPool), C_MISSED },
        })
    end

    if not IS_CLASSIC_ERA then
        -- All physical damage, bleeds included.
        PercentBonus(f.results.arms, "Blood Frenzy", stats.physAll, BLOOD_FRENZY,
            f.state.bloodFrenzy)
    end
end

-- ---------------------------------------------------------------------------
-- Fight picker
-- ---------------------------------------------------------------------------

-- Rebuild the fight dropdown from Details' stored segments (newest first) plus
-- the live one. A fight the user picked stays picked while Details still holds
-- it; otherwise pick a sensible default (last completed fight).
local function RefreshFightList(f)
    local Details = GetDetails()
    if not Details then
        UIDropDownMenu_SetText(f.fightDD, "Details! not installed")
        f.selectedCombat = nil
        return
    end

    local segments = Details.GetCombatSegments and Details:GetCombatSegments() or {}
    local current = Details.GetCurrentCombat and Details:GetCurrentCombat()

    local picked = f.pickedCombat
    local stillHeld = picked ~= nil and picked == current
    for i = 1, math.min(#segments, 20) do
        if segments[i] == picked then stillHeld = true end
    end
    if not stillHeld then f.pickedCombat = nil end

    -- Default: the most recent completed segment, else the current fight.
    f.selectedCombat = f.pickedCombat or segments[1] or current

    UIDropDownMenu_Initialize(f.fightDD, function(_, level)
        if current then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Current: " .. CombatLabel(current)
            info.checked = (f.selectedCombat == current)
            info.func = function()
                f.selectedCombat = current
                f.pickedCombat = current
                UIDropDownMenu_SetText(f.fightDD, CombatLabel(current))
                Recompute(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
        for i = 1, math.min(#segments, 20) do
            local seg = segments[i]
            local label = CombatLabel(seg)
            local info = UIDropDownMenu_CreateInfo()
            info.text = label
            info.checked = (f.selectedCombat == seg)
            info.func = function()
                f.selectedCombat = seg
                f.pickedCombat = seg
                UIDropDownMenu_SetText(f.fightDD, label)
                Recompute(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    UIDropDownMenu_SetText(f.fightDD,
        f.selectedCombat and CombatLabel(f.selectedCombat) or "No fights logged")
end

-- ---------------------------------------------------------------------------
-- Page
-- ---------------------------------------------------------------------------

-- Build the page into its main-window tab. Open to everyone: it only reads
-- Details!, so there is nothing to lock it behind.
function WhoDoesWhat:BuildCurseCalculatorPage(page)
    local f = CreateFrame("Frame", nil, page)
    f:SetAllPoints(page)
    f.state = {
        bossArmor = BOSS_ARMORS[1],
        sunder = true, expose = false, ff = true,
        cor = true, coe = true, cos = true,
        malediction = not IS_CLASSIC_ERA, igniteDoubleDip = true,
        bloodFrenzy = false,
    }
    f.results = {}

    -- Fight: the picker on the title strip, the target and duration under it,
    -- then the damage breakdown ------------------------------------------------
    local fight = CreateBox(f, "Fight")
    fight:SetPoint("TOPLEFT")
    fight:SetWidth(LEFT_W)
    UI.ReserveSectionStrip(fight, TARGET_STRIP_H)

    f.fightDD = UI.CreateMenuDropdown(fight, "WhoDoesWhatCurseCalcFightDD", 300)
    f.fightDD:SetPoint("RIGHT", fight, "TOPRIGHT", DD_OVERHANG - UI.BOX_PAD, -STRIP_MID - 2)

    local targetY = -(UI.BOX_PAD + UI.SECTION_TITLE_H + TARGET_STRIP_H / 2)
    f.target = fight:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.target:SetPoint("LEFT", fight, "TOPLEFT", UI.BOX_PAD + LABEL_X, targetY)
    f.target:SetWidth(LEFT_W - 160)
    f.target:SetJustifyH("LEFT")
    f.target:SetWordWrap(false)

    f.duration = fight:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.duration:SetPoint("RIGHT", fight, "TOPRIGHT", -(UI.BOX_PAD + LABEL_X), targetY)

    f.breakdownRows = {}
    for i, def in ipairs(BREAKDOWN) do
        local row = AddValueRow(fight, i, def.depth)
        local color = def.color or C_WHITE
        row.key = def.key
        row.label:SetText(def.label)
        row.label:SetTextColor(unpack(color))
        row.value:SetTextColor(unpack(color))
        f.breakdownRows[i] = row
    end
    fight:SetHeight(BoxHeight(fight, #BREAKDOWN))

    -- Boss Armor: the armor CoR's estimate is reconstructed from -------------
    local armor = CreateBox(f, "Boss Armor")
    armor:SetPoint("TOPLEFT", fight, "BOTTOMLEFT", 0, -GAP)
    armor:SetWidth(LEFT_W)
    armor:SetHeight(BoxHeight(armor, 6))

    -- The one Curse of Recklessness setting, shown by a toggle here and one in
    -- its result box; either keeps the other in step.
    local corChecks = {}
    local function SetCor(on)
        f.state.cor = on
        for _, check in ipairs(corChecks) do check:SetChecked(on) end
        Recompute(f)
    end

    local baseRow = AddValueRow(armor, 1)
    baseRow.label:SetText("Base armor")
    f.armorDD = UI.CreateMenuDropdown(baseRow, "WhoDoesWhatCurseCalcArmorDD", 60)
    f.armorDD:SetPoint("RIGHT", baseRow, "RIGHT", DD_OVERHANG - LABEL_X + 6, -2)
    UIDropDownMenu_Initialize(f.armorDD, function(_, level)
        for _, v in ipairs(BOSS_ARMORS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = tostring(v)
            info.checked = (f.state.bossArmor == v)
            info.func = function()
                f.state.bossArmor = v
                UIDropDownMenu_SetText(f.armorDD, tostring(v))
                Recompute(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetText(f.armorDD, tostring(f.state.bossArmor))

    -- Sunder / Expose are mutually exclusive (at most one), so each unticks the
    -- other. Unticking the checked one leaves neither -> no armor debuff.
    f.sunderCheck = AddCheckRow(armor, 2, "Sunder Armor", "-" .. Commafy(SUNDER),
        "Five stacks of Sunder Armor on the boss. Replaces Improved Expose Armor.",
        function(on)
            f.state.sunder = on
            if on then f.state.expose = false; f.exposeCheck:SetChecked(false) end
            Recompute(f)
        end)
    f.exposeCheck = AddCheckRow(armor, 3, "Improved Expose Armor", "-" .. Commafy(EXPOSE),
        "Improved Expose Armor on the boss. Replaces Sunder Armor.",
        function(on)
            f.state.expose = on
            if on then f.state.sunder = false; f.sunderCheck:SetChecked(false) end
            Recompute(f)
        end)
    f.ffCheck = AddCheckRow(armor, 4, "Faerie Fire", "-" .. Commafy(FAERIE_FIRE),
        "Faerie Fire on the boss.",
        function(on)
            f.state.ff = on
            Recompute(f)
        end)
    corChecks[#corChecks + 1] = AddCheckRow(armor, 5, CURSES.reck.name_long,
        "-" .. Commafy(COR_ARMOR), "Curse of Recklessness was up on the boss.", SetCor)

    local penRow = AddValueRow(armor, 6)
    penRow.label:SetText("Extra armor pen")
    f.penEdit = CreateFrame("EditBox", nil, penRow, "InputBoxTemplate")
    f.penEdit:SetSize(48, 18)
    f.penEdit:SetPoint("RIGHT", penRow, "RIGHT", -LABEL_X, 0)
    f.penEdit:SetAutoFocus(false)
    f.penEdit:SetNumeric(true)
    f.penEdit:SetMaxLetters(5)
    f.penEdit:SetText("0")
    f.penEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.penEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.penEdit:SetScript("OnTextChanged", function(_, userInput)
        if userInput then Recompute(f) end
    end)
    f.penEdit.tooltip = IS_CLASSIC_ERA
        and "Average extra flat armor reduction or armor penetration per physical raider"
            .. " from effects such as Annihilator and Badge of the Swarmguard. Not"
            .. " auto-detected; leave 0 if you do not want to approximate it."
        or "Average extra armor reduction per physical raider from trinkets, enchants"
            .. " (Executioner), and gear (Swarmguard, Madness, armor-pen trinkets). Not"
            .. " auto-detected; leave 0 if you do not want to approximate it."
    UI.AddTooltip(f.penEdit, "Extra armor penetration",
        function(self) return self.tooltip end)

    -- Results, one box each down the right-hand column. A box's options take
    -- its top `options` rows; the result rows follow. -------------------------
    local function AddResult(key, title, opts, options, rows, above)
        local box = CreateBox(f, title, opts)
        if above then
            box:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -GAP)
            box:SetPoint("TOPRIGHT", above, "BOTTOMRIGHT", 0, -GAP)
        else
            box:SetPoint("TOPLEFT", LEFT_W + GAP, 0)
            box:SetPoint("TOPRIGHT")
        end
        local result = { box = box, rows = {} }
        for i = 1, rows do result.rows[i] = AddValueRow(box, options + i) end
        box:SetHeight(BoxHeight(box, options + rows))
        f.results[key] = result
        return box
    end

    local corBox = AddResult("cor", CURSES.reck.name_long,
        { icon = CURSES.reck.icon, titleColor = C_COR, tintColor = C_COR }, 1, 3)
    corChecks[#corChecks + 1] = AddCheckRow(corBox, 1, "Applied during the fight", nil,
        "Curse of Recklessness was up on the boss.", SetCor)

    local coeBox = AddResult("coe", CURSES.elements.name_long,
        { icon = CURSES.elements.icon, titleColor = C_COE, tintClass = "Warlock" },
        2, 3, corBox)
    f.coeCheck = AddCheckRow(coeBox, 1, "Applied during the fight", nil,
        "Curse of the Elements was up on the boss.",
        function(on)
            f.state.coe = on
            Recompute(f)
        end)
    if IS_CLASSIC_ERA then
        f.igniteCheck = AddCheckRow(coeBox, 2, "Ignite double-dips", "1.21x",
            "Ignite copies a fire crit that Curse of the Elements already raised,"
                .. " then the curse raises the Ignite damage again.",
            function(on)
                f.state.igniteDoubleDip = on
                Recompute(f)
            end)

        local cosBox = AddResult("cos", CURSES.shadow.name_long,
            { icon = CURSES.shadow.icon, titleColor = C_COE, tintClass = "Warlock" },
            1, 3, coeBox)
        f.cosCheck = AddCheckRow(cosBox, 1, "Applied during the fight", nil,
            "Curse of Shadow was up on the boss.",
            function(on)
                f.state.cos = on
                Recompute(f)
            end)
    else
        f.maledictionCheck = AddCheckRow(coeBox, 2, "Malediction", "13%",
            "The Affliction talent that raises Curse of the Elements to 13%.",
            function(on)
                f.state.malediction = on
                Recompute(f)
            end)

        local armsBox = AddResult("arms", "Blood Frenzy",
            { icon = BLOOD_FRENZY_ICON, titleColor = C_ARMS, tintClass = "Warrior" },
            1, 3, coeBox)
        f.bloodFrenzyCheck = AddCheckRow(armsBox, 1, "Applied during the fight", nil,
            "An Arms warrior kept Blood Frenzy up on the boss: +4% to all physical"
                .. " damage, bleeds included.",
            function(on)
                f.state.bloodFrenzy = on
                Recompute(f)
            end)
    end

    f.footnote = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.footnote:SetPoint("BOTTOMLEFT", 4, 2)
    f.footnote:SetPoint("BOTTOMRIGHT", -4, 2)
    f.footnote:SetJustifyH("LEFT")
    f.footnote:SetText("Assumes 100% curse uptime; resistance reduction is not valued. CoR is an"
        .. " estimate: ticked debuffs and average armor pen are flat reductions, and known"
        .. " bleeds are excluded. Zero extra pen is conservative unless armor is already zero.")

    -- Reflect the default checkbox states.
    f.sunderCheck:SetChecked(f.state.sunder)
    f.exposeCheck:SetChecked(f.state.expose)
    f.ffCheck:SetChecked(f.state.ff)
    for _, check in ipairs(corChecks) do check:SetChecked(f.state.cor) end
    f.coeCheck:SetChecked(f.state.coe)
    if IS_CLASSIC_ERA then
        f.igniteCheck:SetChecked(f.state.igniteDoubleDip)
        f.cosCheck:SetChecked(f.state.cos)
    else
        f.maledictionCheck:SetChecked(f.state.malediction)
        f.bloodFrenzyCheck:SetChecked(f.state.bloodFrenzy)
    end

    -- Rebuild the fight list every time the page comes up, so fights logged
    -- since last time show up.
    f:SetScript("OnShow", function(self)
        RefreshFightList(self)
        Recompute(self)
    end)

    return f
end
