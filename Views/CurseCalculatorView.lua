local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Curse value calculator. Pulls a fight from Details! and estimates how much
-- raid damage Curse of the Elements and Curse of Recklessness provided (or, if
-- they weren't up, could have provided).
--
-- CoE is near-exact: Details records each spell's school bitmask and per-target
-- damage, so we sum the boss's fire/frost/shadow/arcane damage and apply the
-- flat magic-taken bonus (10%, or 13% with Malediction). Nature and Holy fall
-- out of the mask on their own.
--
-- CoR is an estimate. Armor mitigation is m(A) = C/(A+C); removing CoR's flat
-- 800 armor is worth more the lower the boss's armor already is (convex, but
-- bounded because C dominates). We reconstruct the boss's armor from the
-- assumed debuff set the user ticks -- the exact numbers Details can't know --
-- and compute the physical pool with vs. without the 800. Two deliberate
-- gaps, both surfaced in the footnote: bleeds are physical-school but ignore
-- armor, so a spell-id list drops them from the pool; and per-player armor pen
-- (trinkets, Executioner, gear) isn't tracked, offered instead as an optional
-- average the user fills in.

local calcFrame = nil

local FRAME_W = 520
local FRAME_H = 560
local MARGIN = 14
local COL_R = 268 -- right input column x

-- Level-70 attacker armor constant: 467.5*70 - 22167.5. Damage that lands
-- through armor A is C/(A+C).
local ARMOR_C = 10557.5

-- Flat armor removed by each debuff (5-stack / 5-point / TBC ranks) and CoR.
local SUNDER = 2600
local EXPOSE = 3075 -- Improved Expose Armor (talented)
local FAERIE_FIRE = 610
local COR_ARMOR = 800

-- Magic-taken bonus from Curse of the Elements: base rank 4, or 13% with the
-- Affliction talent Malediction.
local COE_BASE = 0.10
local COE_MALEDICTION = 0.13

-- Arms warrior Blood Frenzy: +4% to ALL physical damage the target takes,
-- bleeds included (it's a school multiplier, not an armor change).
local BLOOD_FRENZY = 0.04

-- School bitmask: Physical 1, Holy 2, Fire 4, Nature 8, Frost 16, Shadow 32,
-- Arcane 64. CoE boosts fire+frost+shadow+arcane (4|16|32|64 = 116).
local SCHOOL_PHYSICAL = 0x1
local COE_MASK = 0x4 + 0x10 + 0x20 + 0x40

-- Breakdown colors: CoR orange, CoE warlock-purple, total green, and a muted
-- grey for the rows the curses don't touch (bleeds, nature/holy).
local C_COR = "ff8000"
local C_COE = "9482c9"
local C_TOTAL = "40ff40"
local C_MUTED = "999999"

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

-- Wrap text in a |cff..|r color escape.
local function Color(hex, text)
    return "|cff" .. hex .. text .. "|r"
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
--     coeRelevant    fire/frost/shadow/arcane -- what CoE acts on
--     magicOther     magicAll - coeRelevant  -- nature/holy, unaffected
local function BossPoolsFromCombat(combat)
    local actors = combat.GetActorList and combat:GetActorList(1) -- 1 = damage
    if not actors then return nil end

    local perTarget = {}
    for _, actor in ipairs(actors) do
        if actor.grupo or actor.owner then -- in group, or a pet
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
                                    t = { total = 0, physAll = 0, bleeds = 0, coeRelevant = 0 }
                                    perTarget[targetName] = t
                                end
                                t.total = t.total + amount
                                if school == SCHOOL_PHYSICAL then
                                    t.physAll = t.physAll + amount
                                    if isBleed then t.bleeds = t.bleeds + amount end
                                elseif bit.band(school, COE_MASK) ~= 0 then
                                    t.coeRelevant = t.coeRelevant + amount
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local bossName, best
    for name, t in pairs(perTarget) do
        if not best or t.total > best.total then
            best, bossName = t, name
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
        magicOther = (best.total - best.physAll) - best.coeRelevant,
    }
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------

local function MakeCheck(parent, x, y, text, onToggle)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(22, 22)
    c:SetPoint("TOPLEFT", x, -y)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", c, "RIGHT", 2, 0)
    lbl:SetText(text)
    c:SetScript("OnClick", function(self)
        onToggle(self:GetChecked() and true or false)
    end)
    return c
end

-- ---------------------------------------------------------------------------
-- Recompute + render
-- ---------------------------------------------------------------------------

-- Blank every readout with a one-line status in the header slot.
local function ShowStatus(f, text)
    f.fightHeader:SetText(text)
    f.sumLabels:SetText("")
    f.sumValues:SetText("")
    f.coeResult:SetText("")
    f.corResult:SetText("")
    f.armsResult:SetText("")
    f.footnote:SetText("")
end

local function Recompute(f)
    local Details = GetDetails()
    if not Details then
        ShowStatus(f, "|cffff5555Details! is not installed or not enabled.|r"
            .. "\nInstall the Details! Damage Meter addon to use this calculator.")
        return
    end

    local combat = f.selectedCombat
    if not combat then
        ShowStatus(f, "|cffaaaaaaSelect a fight above.|r")
        return
    end

    local boss, stats = BossPoolsFromCombat(combat)
    if not boss then
        ShowStatus(f, "|cffaaaaaaNo damage recorded in this fight.|r")
        return
    end

    local coePool, physPool = stats.coeRelevant, stats.physNonBleed

    local duration = (combat.GetCombatTime and combat:GetCombatTime()) or 0
    f.fightHeader:SetText(string.format(
        "Target: |cffffd100%s|r    Duration: %d:%02d",
        boss, math.floor(duration / 60), duration % 60))

    -- Damage breakdown, rendered as two aligned columns (labels left, values
    -- right) so the numbers line up under one another.
    f.sumLabels:SetText(table.concat({
        Color(C_TOTAL, "Total damage to target"),
        "   Physical",
        "      " .. Color(C_COR, "Armor-mitigated  -> CoR"),
        "      " .. Color(C_MUTED, "Bleeds (ignore armor)"),
        "   Magic",
        "      " .. Color(C_COE, "Fire/Frost/Shadow/Arcane  -> CoE"),
        "      " .. Color(C_MUTED, "Other (Nature/Holy)"),
    }, "\n"))
    f.sumValues:SetText(table.concat({
        Color(C_TOTAL, Commafy(stats.total)),
        Commafy(stats.physAll),
        Color(C_COR, Commafy(stats.physNonBleed)),
        Color(C_MUTED, Commafy(stats.bleeds)),
        Commafy(stats.magicAll),
        Color(C_COE, Commafy(stats.coeRelevant)),
        Color(C_MUTED, Commafy(stats.magicOther)),
    }, "\n"))

    local function PerSec(total)
        if duration > 0 then
            return "  (" .. Commafy(total / duration) .. " DPS)"
        end
        return ""
    end

    -- Curse of the Elements ---------------------------------------------------
    local coeRate = f.state.malediction and COE_MALEDICTION or COE_BASE
    local ratePct = math.floor(coeRate * 100 + 0.5)
    if f.state.coe then
        -- Recorded magic already carries the bonus; back out to before-CoE.
        local before = coePool / (1 + coeRate)
        local provided = coePool - before
        f.coeResult:SetText(string.format(
            "|cff9482c9Curse of the Elements|r (+%d%%, applied)\n"
            .. "  Damage with CoE:   |cffffffff%s|r\n"
            .. "  Damage before CoE: |cffffffff%s|r\n"
            .. "  Provided: |cff00ff00%s|r%s",
            ratePct, Commafy(coePool), Commafy(before), Commafy(provided), PerSec(provided)))
    else
        -- No CoE was up; recorded magic is the before number.
        local withCoe = coePool * (1 + coeRate)
        local could = withCoe - coePool
        f.coeResult:SetText(string.format(
            "|cff9482c9Curse of the Elements|r (+%d%%, NOT applied)\n"
            .. "  Damage now:      |cffffffff%s|r\n"
            .. "  Damage with CoE: |cffffffff%s|r\n"
            .. "  Could have provided: |cffffff00%s|r%s",
            ratePct, Commafy(coePool), Commafy(withCoe), Commafy(could), PerSec(could)))
    end

    -- Curse of Recklessness ---------------------------------------------------
    local armorDebuff = (f.state.sunder and SUNDER) or (f.state.expose and EXPOSE) or 0
    local ff = f.state.ff and FAERIE_FIRE or 0
    local pen = tonumber(f.penEdit:GetText()) or 0
    local base = f.state.bossArmor
    local C = ARMOR_C
    local nonCorReduction = armorDebuff + ff + pen

    if f.state.cor then
        -- Recorded physical is the with-CoR number; add the 800 back to see
        -- what it would have been without.
        local aWith = math.max(base - nonCorReduction - COR_ARMOR, 0)
        local aWithout = aWith + COR_ARMOR
        local before = physPool * (aWith + C) / (aWithout + C)
        local provided = physPool - before
        f.corResult:SetText(string.format(
            "|cffff8000Curse of Recklessness|r (applied)\n"
            .. "  Damage with CoR:   |cffffffff%s|r\n"
            .. "  Damage before CoR: |cffffffff%s|r\n"
            .. "  Provided: |cff00ff00%s|r%s",
            Commafy(physPool), Commafy(before), Commafy(provided), PerSec(provided)))
    else
        -- No CoR was up; recorded physical is the without-CoR number.
        local aNow = math.max(base - nonCorReduction, 0)
        local aWithCor = math.max(aNow - COR_ARMOR, 0)
        local withCor = physPool * (aNow + C) / (aWithCor + C)
        local provided = withCor - physPool
        f.corResult:SetText(string.format(
            "|cffff8000Curse of Recklessness|r (NOT applied)\n"
            .. "  Damage now:      |cffffffff%s|r\n"
            .. "  Damage with CoR: |cffffffff%s|r\n"
            .. "  Could have provided: |cffffff00%s|r%s",
            Commafy(physPool), Commafy(withCor), Commafy(provided), PerSec(provided)))
    end

    -- Arms warrior (Blood Frenzy): a fixed +4% on all physical taken, bleeds
    -- included, so its pool is the full physical damage (not the CoR pool).
    -- No toggle -- always shown as the value of having one in the raid.
    local armsValue = stats.physAll * BLOOD_FRENZY
    f.armsResult:SetText(string.format(
        "|cffc79c6eAn Arms warrior|r could have provided |cffffff00%s|r damage%s\n"
        .. "|cff808080Blood Frenzy: +4%% to all physical, bleeds included|r",
        Commafy(armsValue), PerSec(armsValue)))

    f.footnote:SetText("CoR is an estimate: the armor state comes from the boxes you tick, bleeds"
        .. " are excluded from the physical pool, and per-player armor pen beyond the field"
        .. " above isn't tracked (so CoR is a conservative floor).")
end

-- ---------------------------------------------------------------------------
-- Fight picker
-- ---------------------------------------------------------------------------

-- Rebuild the fight dropdown from Details' stored segments (newest first) plus
-- the live one, and pick a sensible default (last completed fight).
local function RefreshFightList(f)
    local Details = GetDetails()
    if not Details then
        UIDropDownMenu_SetText(f.fightDD, "Details! not installed")
        f.selectedCombat = nil
        return
    end

    local segments = Details.GetCombatSegments and Details:GetCombatSegments() or {}
    local current = Details.GetCurrentCombat and Details:GetCurrentCombat()

    -- Default: the most recent completed segment, else the current fight.
    f.selectedCombat = segments[1] or current

    UIDropDownMenu_Initialize(f.fightDD, function(_, level)
        if current then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Current: " .. CombatLabel(current)
            info.checked = (f.selectedCombat == current)
            info.func = function()
                f.selectedCombat = current
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
-- Window
-- ---------------------------------------------------------------------------

local function EnsureCalcFrame()
    if calcFrame then return calcFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatCurseCalcFrame", FRAME_W, FRAME_H,
        "WhoDoesWhat - Curse Value Calculator")
    f.state = {
        bossArmor = 7700,
        sunder = true, expose = false,
        cor = true, coe = true, malediction = true,
    }

    local top = f.titleBarHeight + 12

    -- Fight picker
    local pickLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pickLabel:SetPoint("TOPLEFT", MARGIN, -top)
    pickLabel:SetText("Fight:")

    f.fightDD = CreateFrame("Frame", "WhoDoesWhatCurseCalcFightDD", f, "UIDropDownMenuTemplate")
    f.fightDD:SetPoint("LEFT", pickLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(f.fightDD, 320)

    -- Fight header + damage breakdown (two aligned columns)
    local y = top + 30
    f.fightHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.fightHeader:SetPoint("TOPLEFT", MARGIN, -y)
    f.fightHeader:SetPoint("RIGHT", f, "RIGHT", -MARGIN, 0)
    f.fightHeader:SetJustifyH("LEFT")

    f.sumLabels = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.sumLabels:SetPoint("TOPLEFT", MARGIN, -(y + 22))
    f.sumLabels:SetJustifyH("LEFT")
    f.sumLabels:SetJustifyV("TOP")
    f.sumLabels:SetSpacing(4)

    f.sumValues = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.sumValues:SetPoint("TOPLEFT", 270, -(y + 22))
    f.sumValues:SetWidth(120) -- right edge ~x=390, close to the labels
    f.sumValues:SetJustifyH("RIGHT")
    f.sumValues:SetJustifyV("TOP")
    f.sumValues:SetSpacing(4)

    -- Inputs -----------------------------------------------------------------
    local iy = y + 138

    -- Left column: boss armor + armor debuffs
    local armorLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    armorLabel:SetPoint("TOPLEFT", MARGIN, -iy)
    armorLabel:SetText("Boss base armor:")

    f.armorDD = CreateFrame("Frame", "WhoDoesWhatCurseCalcArmorDD", f, "UIDropDownMenuTemplate")
    f.armorDD:SetPoint("LEFT", armorLabel, "RIGHT", -10, -2)
    UIDropDownMenu_SetWidth(f.armorDD, 70)
    UIDropDownMenu_Initialize(f.armorDD, function(_, level)
        for _, v in ipairs({ 7700, 6200 }) do
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
    f.sunderCheck = MakeCheck(f, MARGIN, iy + 32, "Sunder Armor (2600)", function(on)
        f.state.sunder = on
        if on then f.state.expose = false; f.exposeCheck:SetChecked(false) end
        Recompute(f)
    end)
    f.exposeCheck = MakeCheck(f, MARGIN, iy + 58, "Improved Expose Armor (3075)", function(on)
        f.state.expose = on
        if on then f.state.sunder = false; f.sunderCheck:SetChecked(false) end
        Recompute(f)
    end)
    f.ffCheck = MakeCheck(f, MARGIN, iy + 84, "Faerie Fire (610)", function(on)
        f.state.ff = on
        Recompute(f)
    end)
    f.state.ff = true
    f.ffCheck:SetChecked(true)

    -- Left column continues: CoR was up, then the armor-pen field. Everything
    -- armor-related lives on the left; CoE settings sit on the right.
    f.corCheck = MakeCheck(f, MARGIN, iy + 110, "Curse of Recklessness applied", function(on)
        f.state.cor = on
        Recompute(f)
    end)

    local penLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    penLabel:SetPoint("TOPLEFT", MARGIN, -(iy + 142))
    penLabel:SetText("Avg extra armor pen / raider:")

    -- Right column: Curse of the Elements settings.
    f.coeCheck = MakeCheck(f, COL_R, iy, "Curse of the Elements applied", function(on)
        f.state.coe = on
        Recompute(f)
    end)
    f.maledictionCheck = MakeCheck(f, COL_R, iy + 26, "Malediction (13% instead of 10%)", function(on)
        f.state.malediction = on
        Recompute(f)
    end)

    f.penEdit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.penEdit:SetSize(48, 18)
    f.penEdit:SetPoint("LEFT", penLabel, "RIGHT", 10, 0)
    f.penEdit:SetAutoFocus(false)
    f.penEdit:SetNumeric(true)
    f.penEdit:SetMaxLetters(5)
    f.penEdit:SetText("0")
    f.penEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.penEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.penEdit:SetScript("OnTextChanged", function(_, userInput)
        if userInput then Recompute(f) end
    end)
    f.penEdit.tooltip = "Average extra armor reduction per physical raider from trinkets, enchants"
        .. " (Executioner), and gear (Swarmguard, Madness, armor-pen trinkets). Not"
        .. " auto-detected -- set what you think your raid runs. Leaving it 0 makes the"
        .. " CoR value a conservative floor."
    f.penEdit:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Extra armor penetration", 1, 1, 1)
        GameTooltip:AddLine(self.tooltip, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    f.penEdit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Divider above results
    local ry = iy + 172
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", MARGIN, -ry)
    divider:SetPoint("TOPRIGHT", -MARGIN, -ry)

    -- Results, side by side to mirror the inputs: CoR on the left, CoE right.
    f.corResult = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.corResult:SetPoint("TOPLEFT", MARGIN, -(ry + 12))
    f.corResult:SetWidth(COL_R - MARGIN - 10)
    f.corResult:SetJustifyH("LEFT")
    f.corResult:SetJustifyV("TOP")
    f.corResult:SetSpacing(3)

    f.coeResult = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.coeResult:SetPoint("TOPLEFT", COL_R, -(ry + 12))
    f.coeResult:SetPoint("RIGHT", f, "RIGHT", -MARGIN, 0)
    f.coeResult:SetJustifyH("LEFT")
    f.coeResult:SetJustifyV("TOP")
    f.coeResult:SetSpacing(3)

    f.footnote = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.footnote:SetPoint("BOTTOMLEFT", MARGIN, MARGIN)
    f.footnote:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN)
    f.footnote:SetJustifyH("LEFT")

    -- Arms-warrior line, centered just above the footnote.
    f.armsResult = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.armsResult:SetPoint("BOTTOM", f.footnote, "TOP", 0, 10)
    f.armsResult:SetJustifyH("CENTER")
    f.armsResult:SetSpacing(3)

    -- Reflect the default checkbox states.
    f.sunderCheck:SetChecked(f.state.sunder)
    f.exposeCheck:SetChecked(f.state.expose)
    f.corCheck:SetChecked(f.state.cor)
    f.coeCheck:SetChecked(f.state.coe)
    f.maledictionCheck:SetChecked(f.state.malediction)

    calcFrame = f
    return f
end

-- Toggle the calculator open/closed. Rebuilds the fight list each open so
-- fights logged since last time show up.
function WhoDoesWhat:OpenCurseCalculatorView()
    local f = EnsureCalcFrame()

    if f:IsShown() then
        self:LogUiBuilding("Curse Calculator open, closing it.")
        f:Hide()
        return
    end

    self:LogUiBuilding("Opening Curse Calculator...")
    RefreshFightList(f)
    Recompute(f)
    f:Show()
    f:Raise()
end
