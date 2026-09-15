local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI

-- Paladin blessing strategy on the Blessings tab's left panel, flat on the page
-- (divider headings, no box): a titleless block at the top with the Source of
-- Truth dropdown (PallyBuffSource) and a grey line describing the choice, then
-- the Buffing Rules section, whose header owns "Add (+)" and clear-all. It
-- stays up in PallyPower mode, where the rules still decide what counts as an
-- unoptimized buff on PallyPower's board. What each paladin
-- casts and how far along they are lives in the Blessing Assignments block of the
-- panel beside it (PallyPowerDiffView.lua), with the PallyPower fixes.
--
-- The rule rows (the model docs the semantics above CompileBuffRules in
-- Assignments.lua):
--
--   [icon] Salvation is guaranteed for [icon] Healers           (!) [x]
--   [icon] Sanctuary is all <paladin> casts                     (!) [x]
--   [icon] Sanctuary is ignored except for [icon] Tanks             [x]
--
-- One string per row rather than a blessing column and a detail column: the
-- rule reads as a sentence, so a short blessing name can't leave a gap in the
-- middle of one.
--
-- Read-only text, because rules are written whole from the "Add (+)" pop-out
-- and can't be edited in place -- delete and re-add instead. WDW's own
-- implicit rule -- Salvation ignored in PvP instances -- appears above them as
-- a read-only line. Rules are shared strategy config in the synced board, so
-- the same assignment permission applies to adding and removing them.
--
-- A (!) beside "Add (+)", inside its menu, and on a paladin's Paladin Buffs
-- row beside this panel all point at the same thing: a paladin running neither WDW nor PallyPower, who
-- no board can reach and who needs an assign rule to be useful.
--
-- The raid's shared custom-role list is board state like these rules, but it
-- describes the roster rather than blessing strategy, so it has its own section
-- above (Views/Sections/CustomRolesSection.lua). Its published buff orders are
-- an input to the plan computed here.
--
-- The whole section grays out while the group has no paladins (Developer
-- Mode keeps it live, same as it lifts class filters).

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit

local DevMode = A.DevMode
local MembersOfClass = A.MembersOfClass
local HasMemberOfClass = A.HasMemberOfClass
local PlayerTextWithRole = A.PlayerTextWithRole
local GetBuffRules = A.GetBuffRules
local BuffTalents = A.BuffTalents
local PvpSalvationIgnored = A.PvpSalvationIgnored
local UnhandledDisabledPaladins = A.UnhandledDisabledPaladins
local PaladinBuffSlots = A.PaladinBuffSlots
local ShortAssignmentName = A.ShortAssignmentName

local RULE_ROW_H = UI.ROW_H
local AUTO_RULE_H = 18

local PALLY_BUFF_SOURCES = {
    { key = "wdw", text = "WDW Assignments" },
    { key = "pallypower", text = "PallyPower" },
}

local function GetPallyBuffSource()
    return WhoDoesWhat.db.profile.settings.pallyBuffSource or "wdw"
end

local function PallyBuffSourceText(key)
    for _, option in ipairs(PALLY_BUFF_SOURCES) do
        if option.key == key then return option.text end
    end
    return PALLY_BUFF_SOURCES[1].text
end

-- The grey line under the Source of Truth dropdown, one per choice.
local SOURCE_BLURB_LEAD = "A raid-wide setting that sets the source of truth for"
    .. " Paladin blessings. "
local SOURCE_BLURBS = {
    wdw = SOURCE_BLURB_LEAD .. "With |cffffd100WDW Assignments|r selected, all"
        .. " blessings are optimized for every raider based on the rules below."
        .. " All UI elements are powered by the blessings assigned by WDW, and"
        .. " many updates are auto-synced to PallyPower.",
    pallypower = SOURCE_BLURB_LEAD .. "With |cffffd100PallyPower|r selected, all"
        .. " UI elements are powered by the assignments made within the"
        .. " PallyPower board. WDW will not make any changes automatically, but"
        .. " the rules below still decide which buffs count as unoptimized."
        .. " Useful in legacy raids that insist on using PallyPower and don't"
        .. " know what they're missing.",
}

-- The grey line describes only the choice that is up, so it is rewritten, and
-- the block re-fitted to it, on every refresh.
local function RefreshSourceBlock(state, source)
    state.sourceBlurb:SetText(SOURCE_BLURBS[source] or SOURCE_BLURBS.wdw)
    state.sourceBlock:SetHeight(36 + math.ceil(state.sourceBlurb:GetStringHeight()) + 6)
end

-- The page's heading colour, for the Buffing Rules heading (Theme.lua).
local ACCENT = WhoDoesWhat.Theme.blessings.accent

local WOW_ROLE_LABELS = { tank = "Tanks", healer = "Healers", dps = "DPS" }

-- How many rules the list will hold. Guarantees are per (buff, target), so the
-- old "one rule per blessing" ceiling of six is far too low now.
local MAX_RULES = 12

local Refresh -- the section's registered refresh; forward-declared to stay a
              -- file-local (rule callbacks repaint via RefreshMainAssignmentsView)

-- ---------------------------------------------------------------------------
-- Rule-row text + warning helpers
-- ---------------------------------------------------------------------------

local function BuffIcon(key, size)
    local buff = WhoDoesWhat.PaladinBuffs[key]
    if not buff then return "" end
    size = size or 14
    return "|T" .. buff.iconId .. ":" .. size .. ":" .. size .. ":0:0|t "
end

-- Tooltip sentences name three kinds of moving part, and each keeps its own
-- colour so a glance finds the one you came for: the blessing, the paladin
-- (Paladin pink, same as their name anywhere else), and the counts and groups
-- the rule turns on.
local function BuffName(key)
    local buff = WhoDoesWhat.PaladinBuffs[key]
    return "|cffffd100" .. (buff and buff.name_long or "this blessing") .. "|r"
end

local paladinColor
local function PaladinColor()
    if not paladinColor then
        for _, ci in ipairs(WhoDoesWhat.Classes) do
            if ci.name == "Paladin" then paladinColor = ci.colorHex end
        end
        paladinColor = paladinColor or "f58cba"
    end
    return paladinColor
end

local function PaladinName(name)
    return "|cff" .. PaladinColor() .. ShortAssignmentName(name) .. "|r"
end

-- A count of paladins wears their class colour, so the number and the people
-- it counts read as the same thing.
local function PaladinCount(n)
    return "|cff" .. PaladinColor() .. n .. "|r"
end

-- Tanks / Healers / DPS wearing the same role icons as the rest of the UI.
local function WowRoleLabel(wowRole)
    return WhoDoesWhat:GetWowRoleIconMarkup(wowRole, 14) .. " "
        .. (WOW_ROLE_LABELS[wowRole] or "?")
end

local function RuleBuffText(rule)
    local buff = WhoDoesWhat.PaladinBuffs[rule.buff]
    if not buff then return "?" end
    return BuffIcon(rule.buff) .. buff.name_long
end

-- A paladin's scanned rank in a blessing's talent: 0..max once scanned, nil
-- while unscanned OR when the buff has no talent at all (Salv/Light).
local function BuffRank(buffKey, paladinName)
    if not BuffTalents[buffKey] then return nil end
    local t = WhoDoesWhat:GetPaladinBuffTalents(paladinName)
    return t and t[buffKey]
end

-- Talent note behind a blessing in the assign menu: green (talented) / red
-- (can't cast) for the talent-granted blessings, gray n/max for the Improved
-- ones, gray (not scanned) while their data hasn't arrived. nil (no note) for
-- Salvation/Light -- every paladin casts those equally.
local function BuffTalentNote(buffKey, paladinName)
    local meta = BuffTalents[buffKey]
    if not meta then return nil end
    local rank = BuffRank(buffKey, paladinName)
    if rank == nil then
        return "|cff909090(not scanned)|r"
    end
    if meta.maxRank == 1 then
        return rank > 0 and "|cff40ff40(talented)|r" or "|cffff6060(can't cast)|r"
    end
    return "|cff909090(" .. rank .. "/" .. meta.maxRank .. ")|r"
end

-- The scope half of a rule, as text: who a guarantee covers.
local function RuleScopeText(rule)
    if rule.scope == "wowrole" then
        return WowRoleLabel(rule.value)
    elseif rule.scope == "class" then
        for _, ci in ipairs(WhoDoesWhat.Classes) do
            if ci.name == rule.value then
                return "|cff" .. ci.colorHex .. ci.name .. "|r"
            end
        end
        return "|cff909090" .. tostring(rule.value) .. "|r"
    elseif rule.scope == "role" then
        local _, role = WhoDoesWhat:FindRoleById(rule.value)
        if role then
            return WhoDoesWhat:RoleIconMarkup(role.icon, 14) .. " " .. role.name
        end
        return "?"
    end
    return "Everyone"
end

-- The rule as one read-only sentence: what it does, then who to. Rules can't
-- be edited in place, so this is text rather than a row of dropdowns.
local function RuleDetailText(rule)
    if rule.kind == "ignore" then
        if not rule.scope then
            return "|cff909090is ignored|r"
        end
        if rule.except then
            return "|cff909090is ignored except for|r " .. RuleScopeText(rule)
        end
        return "|cff909090is ignored for|r " .. RuleScopeText(rule)
    end
    if rule.kind == "assign" then
        local who = rule.value
            and PlayerTextWithRole(rule.value, K.DROPDOWN_ICON_SIZE, ShortAssignmentName(rule.value))
            or "|cff909090?|r"
        if rule.only then
            return "|cff909090is all|r " .. who .. " |cff909090casts|r"
        end
        return "|cff909090is|r " .. who .. "|cff909090's|r"
    end
    if rule.kind == "guarantee" then
        return "|cff909090is guaranteed for|r " .. RuleScopeText(rule)
    end
    return "|cff909090?|r"
end

-- The hover explanation for a rule row: what the rule does to the plan, which
-- the row's one line has no room to say. Returns title, body.
local function RuleTooltip(rule)
    local buff = BuffName(rule.buff)

    if rule.kind == "ignore" then
        if rule.scope then
            local who = RuleScopeText(rule)
            if rule.except then
                return "Ignored", buff .. " is planned for " .. who
                    .. " and nobody else. A raider with no role assigned is"
                    .. " nobody else, so they lose it too."
            end
            return "Ignored", buff .. " is dropped from what " .. who
                .. " are planned. Everyone else still receives it normally."
        end
        local why = ""
        if rule.buff == "salv" then
            why = " Automatic in PvP."
        elseif rule.buff == "light" then
            why = " It only improves a paladin's own heals, so a group with no"
                .. " Holy paladin loses nothing."
        end
        return "Ignored", buff .. " is ignored from the plan and won't be"
            .. " assigned." .. why
    end

    if rule.kind == "assign" then
        local who = rule.value and PaladinName(rule.value) or "?"
        if rule.only then
            return "Assigned, and nothing else",
                who .. " casts " .. buff .. " alone and sits out the planning."
                .. " Raiders who don't want it get nothing from them - empty"
                .. " grid cells are correct here."
        end
        return "Assigned",
            who .. " is handed " .. buff .. " wherever it's wanted, ahead of"
            .. " better-talented paladins. They still cover other blessings"
            .. " elsewhere."
    end

    if rule.kind == "guarantee" then
        local slots = PaladinBuffSlots()
        local who = RuleScopeText(rule)
        if slots == 0 then
            return "Guaranteed", buff .. " will be pulled into what " .. who
                .. " receive - but no paladin is buffing right now."
        end
        return "Guaranteed",
            buff .. " reaches " .. who .. " even when it falls outside their top "
            .. PaladinCount(slots) .. " choices, given " .. PaladinCount(slots)
            .. " paladins."
    end

    return nil
end

-- Row warnings, in the order they'd bite. An assign rule can name a paladin
-- who can't cast the blessing well (or at all), and its `only` flag -- which
-- is frozen at creation time on purpose, see the rule model in
-- Assignments.lua -- can drift out of step with who is actually running an
-- addon by now.
local function RuleWarningText(rule)
    if rule.kind ~= "assign" or not rule.value then return nil end
    local meta = BuffTalents[rule.buff]
    local who, buff = PaladinName(rule.value), BuffName(rule.buff)
    if meta and BuffRank(rule.buff, rule.value) == 0 then
        if meta.maxRank == 1 then
            return who .. " can't cast " .. buff .. " at all - this rule does nothing."
        end
        return who .. " has no " .. meta.talent .. " ranks; their " .. buff
            .. " will be unimproved."
    end
    local disabled = WhoDoesWhat:IsPaladinDisabled(rule.value)
    if rule.only and not disabled then
        return who .. " is running an addon now, but this rule still limits them"
            .. " to " .. buff .. ". Delete and re-add to put them back in the plan."
    end
    if disabled and not rule.only then
        return who .. " can't see a blessing board, so they'll be planned"
            .. " blessings they never receive. Delete and re-add to give them "
            .. buff .. " alone."
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Rules: the "Add (+)" pop-out that writes them, and the read-only rows below
--
-- A rule is picked whole out of one nested menu -- kind, then blessing, then
-- who -- and is never edited afterwards; to change one, delete it and add it
-- again. That is what keeps the model honest: no rule ever exists with half
-- its fields filled in, so nothing downstream has to defend against one, and
-- the row is text plus an [x] rather than a line of dropdowns.
-- ---------------------------------------------------------------------------

local WARN_MARKUP = "|T" .. WhoDoesWhat.WARNING_ICON .. ":14:14:0:0|t"

-- The ignore and guarantee branches run four levels deep (kind > blessing >
-- target > that class's roles) and share the last two levels: both say "this
-- blessing, for these raiders", one to take it away and one to promise it.
-- Nothing here has to arrange that depth: UIDropDownMenu_AddButton
-- builds the list frame for a level on demand and raises
-- UIDROPDOWNMENU_MAXLEVELS itself as it goes. Do NOT raise that global by
-- hand -- it counts the DropDownList frames that exist, so setting it ahead of
-- them makes CloseDropDownMenus index a nil frame and takes the whole UI down
-- with it.
local addRuleMenu

local function FindRule(Match)
    for _, r in ipairs(GetBuffRules()) do
        if Match(r) then return r end
    end
    return nil
end

-- Ignored for the whole raid -- the scopeless rule. A scoped ignore leaves the
-- blessing in the plan for everyone it doesn't name, so it isn't this.
local function BuffIgnored(buffKey)
    return FindRule(function(r)
        return r.kind == "ignore" and r.buff == buffKey and not r.scope
    end) ~= nil
end

-- Blessing of Light only improves a paladin's own Holy Light and Flash of
-- Light, so with no Holy paladin in the group it buffs nothing at all. Read off
-- the board's roles rather than talents: the roles are what the raid has agreed
-- on, and they're the same answer the healer rows use. LOCAL knowledge, and it
-- only decides whether the menu nudges -- the rule itself is what changes the
-- plan, so clients that disagree still compute the same coverage.
local function HasHolyPaladin()
    for _, name in ipairs(MembersOfClass("Paladin")) do
        if WhoDoesWhat:GetAssignedRole(name) == "paladin_holy" then
            return true
        end
    end
    return false
end

local function AssignRuleFor(paladinName)
    return FindRule(function(r)
        return r.kind == "assign" and r.value == paladinName
    end)
end

local function BuffAssignedTo(buffKey)
    local rule = FindRule(function(r)
        return r.kind == "assign" and r.buff == buffKey
    end)
    return rule and rule.value
end

-- The same (kind, blessing, target) rule already in the list. Both scoped
-- kinds are picked from the same target menu, so both dedupe the same way.
local function ScopedRuleExists(kind, buffKey, scope, value, except)
    return FindRule(function(r)
        return r.kind == kind and r.buff == buffKey and r.scope == scope
            and r.value == value and (r.except or false) == (except or false)
    end) ~= nil
end

local function AddRule(rule)
    if not WhoDoesWhat:RequireEditPermission() then return end
    CloseDropDownMenus()
    if rule.scope
        and ScopedRuleExists(rule.kind, rule.buff, rule.scope, rule.value, rule.except) then
        return
    end
    -- A rule scoped to a role puts a role id on the board, so the same
    -- publish-or-refuse gate as assigning one applies: an id the rest of the
    -- raid can't resolve would make the rule match nobody but us.
    if rule.scope == "role" and not WhoDoesWhat:EnsureRoleIsShareable(rule.value) then
        return
    end
    local rules = GetBuffRules()
    if #rules >= MAX_RULES then
        WhoDoesWhat:Print("Paladin Buffs: the rule list is full (" .. MAX_RULES
            .. " rules). Remove one before adding another.")
        return
    end
    rules[#rules + 1] = rule
    WhoDoesWhat:LogOperation("Paladin Buffs: rule added (" .. tostring(rule.kind)
        .. " " .. tostring(rule.buff)
        .. (rule.value and (" -> " .. tostring(rule.value)) or "") .. ").")
    WhoDoesWhat:RefreshMainAssignmentsView()
    WhoDoesWhat:RefreshBoardViews()
end

-- Level 2 of the assign branch: the group's paladins, the ones running
-- neither addon flagged, the ones already spoken for closed off.
local function AddAssignPaladins(level)
    local paladins = MembersOfClass("Paladin")
    if #paladins == 0 then
        local info = UIDropDownMenu_CreateInfo()
        info.text = "|cff909090No paladins in group|r"
        info.notCheckable = true
        info.disabled = true
        UIDropDownMenu_AddButton(info, level)
        return
    end
    for _, name in ipairs(paladins) do
        local existing = AssignRuleFor(name)
        local info = UIDropDownMenu_CreateInfo()
        info.text = (WhoDoesWhat:IsPaladinDisabled(name) and (WARN_MARKUP .. " ") or "")
            .. PlayerTextWithRole(name, K.DROPDOWN_ICON_SIZE)
            .. (existing and " |cff909090(already assigned)|r" or "")
        info.notCheckable = true
        info.disabled = existing ~= nil
        info.hasArrow = existing == nil
        info.keepShownOnClick = true
        info.value = { kind = "assign", paladin = name }
        UIDropDownMenu_AddButton(info, level)
    end
end

-- Level 3 of the assign branch: what to give them, annotated with how well
-- they cast it. A paladin running neither addon gets `only` baked in -- the
-- whole point of assigning them is that one blessing is all they can act on.
local function AddAssignBuffs(level, paladinName)
    local locked = WhoDoesWhat:IsPaladinDisabled(paladinName)
    for _, key in ipairs(WhoDoesWhat.CanonicalBuffOrder) do
        -- A blessing they're known not to have talented isn't offered at all:
        -- Kings and Sanctuary are granted BY the talent, so assigning one is
        -- an instruction they couldn't follow. An unscanned paladin still
        -- gets the full list -- no data is not the same as no talent.
        local meta = BuffTalents[key]
        local castable = not (meta and meta.maxRank == 1
            and BuffRank(key, paladinName) == 0)
        if castable then
            local takenBy = BuffAssignedTo(key)
            local note = BuffTalentNote(key, paladinName)
            local info = UIDropDownMenu_CreateInfo()
            info.text = BuffIcon(key) .. WhoDoesWhat.PaladinBuffs[key].name_long
                .. (note and (" " .. note) or "")
                .. (takenBy and (" |cff909090(" .. ShortAssignmentName(takenBy) .. ")|r") or "")
            info.notCheckable = true
            info.disabled = takenBy ~= nil
            info.func = function()
                AddRule({ kind = "assign", buff = key, value = paladinName,
                    only = locked or nil })
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end
end

-- Level 2 of both scoped branches: which blessing. The ignore branch offers
-- all six too -- turning a blessing off for a group is a different statement
-- from turning it off entirely, which stays a Salvation/Light decision on the
-- target level below.
local function AddScopedBuffs(level, kind)
    for _, key in ipairs(WhoDoesWhat.CanonicalBuffOrder) do
        local ignoredEverywhere = kind == "ignore" and BuffIgnored(key)
        local info = UIDropDownMenu_CreateInfo()
        info.text = BuffIcon(key) .. WhoDoesWhat.PaladinBuffs[key].name_long
            .. (ignoredEverywhere and " |cff909090(already ignored)|r" or "")
        info.notCheckable = true
        info.disabled = ignoredEverywhere
        info.hasArrow = not ignoredEverywhere
        info.keepShownOnClick = true
        info.value = { kind = kind, buff = key }
        UIDropDownMenu_AddButton(info, level)
    end
end

-- Level 3 of both scoped branches: who the rule covers. Each class is both a
-- pick of its own ("All Mages") and a door to its roles on level 4.
--
-- The ignore branch adds the inverted Tanks/Healers/DPS picks -- "everyone
-- but the tanks" is what Sanctuary is actually for, and saying it as one rule
-- also catches raiders with no role assigned, which two positive rules would
-- miss. Its "Everyone" writes the scopeless raid-wide ignore, and only
-- Salvation and Light offer it: the other four are always worth casting to
-- somebody, so turning one off for the whole raid is not a pick we hand out.
local function AddScopedTargets(level, kind, buffKey)
    local function Target(text, scope, value, except)
        local info = UIDropDownMenu_CreateInfo()
        info.text = text
        info.notCheckable = true
        info.disabled = ScopedRuleExists(kind, buffKey, scope, value, except)
        info.func = function()
            AddRule({ kind = kind, buff = buffKey, scope = scope,
                value = value, except = except or nil })
        end
        return info
    end

    if kind == "guarantee" then
        UIDropDownMenu_AddButton(Target("Everyone", "everyone", nil), level)
    elseif buffKey == "salv" or buffKey == "light" then
        -- The raid-wide ignore is scopeless, so it can't go through Target.
        local hint = buffKey == "light" and not HasHolyPaladin()
            and " |cffffd100(no Holy paladins)|r" or ""
        local info = UIDropDownMenu_CreateInfo()
        info.text = "Everyone" .. hint
        info.notCheckable = true
        info.func = function() AddRule({ kind = "ignore", buff = buffKey }) end
        UIDropDownMenu_AddButton(info, level)
    end
    for _, wr in ipairs({ "tank", "healer", "dps" }) do
        UIDropDownMenu_AddButton(Target(WowRoleLabel(wr), "wowrole", wr), level)
    end
    if kind == "ignore" then
        for _, wr in ipairs({ "tank", "healer", "dps" }) do
            UIDropDownMenu_AddButton(
                Target("Everyone but " .. WowRoleLabel(wr), "wowrole", wr, true),
                level)
        end
    end
    UI.AddDropdownDivider(level)
    for _, ci in ipairs(WhoDoesWhat.Classes) do
        local info = Target("|cff" .. ci.colorHex .. "All " .. ci.name .. "s|r",
            "class", ci.name)
        info.hasArrow = true
        info.keepShownOnClick = true
        info.value = { kind = kind, buff = buffKey, class = ci.name }
        UIDropDownMenu_AddButton(info, level)
    end
end

local function AddScopedRoles(level, kind, buffKey, className)
    local classInfo
    for _, ci in ipairs(WhoDoesWhat.Classes) do
        if ci.name == className then
            classInfo = ci
            break
        end
    end
    if not classInfo then return end
    for _, list in ipairs({ classInfo.roles, classInfo.customRoles or {} }) do
        for _, role in ipairs(list) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = WhoDoesWhat:RoleIconMarkup(role.icon, 14) .. " |cff"
                .. classInfo.colorHex .. role.name .. "|r"
            info.notCheckable = true
            info.disabled = ScopedRuleExists(kind, buffKey, "role", role.id)
            info.func = function()
                AddRule({ kind = kind, buff = buffKey,
                    scope = "role", value = role.id })
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end
end

local function InitAddRuleMenu(_, level)
    level = level or 1
    if level == 1 then
        local ignore = UIDropDownMenu_CreateInfo()
        ignore.text = "Ignore a Blessing"
        ignore.notCheckable = true
        ignore.hasArrow = true
        ignore.keepShownOnClick = true
        ignore.value = "ignore"
        UIDropDownMenu_AddButton(ignore, level)

        -- The (!) here is the same one the header wears: somebody in the group
        -- can't be reached by any board, and this branch is where that gets
        -- fixed.
        local unhandled = UnhandledDisabledPaladins()
        local assign = UIDropDownMenu_CreateInfo()
        assign.text = "Assign a Paladin a Blessing"
            .. (#unhandled > 0 and (" " .. WARN_MARKUP) or "")
        assign.notCheckable = true
        assign.hasArrow = true
        assign.keepShownOnClick = true
        assign.value = "assign"
        UIDropDownMenu_AddButton(assign, level)

        local guarantee = UIDropDownMenu_CreateInfo()
        guarantee.text = "Guarantee a Blessing"
        guarantee.notCheckable = true
        guarantee.hasArrow = true
        guarantee.keepShownOnClick = true
        guarantee.value = "guarantee"
        UIDropDownMenu_AddButton(guarantee, level)
        return
    end

    local value = UIDROPDOWNMENU_MENU_VALUE
    if value == "assign" then
        AddAssignPaladins(level)
    elseif value == "guarantee" or value == "ignore" then
        AddScopedBuffs(level, value)
    elseif type(value) == "table" then
        if value.kind == "assign" then
            AddAssignBuffs(level, value.paladin)
        elseif value.class then
            AddScopedRoles(level, value.kind, value.buff, value.class)
        else
            AddScopedTargets(level, value.kind, value.buff)
        end
    end
end

local function OpenAddRuleMenu(button)
    if not addRuleMenu then
        addRuleMenu = CreateFrame("Frame", "WhoDoesWhatPallyAddRuleMenu",
            UIParent, "UIDropDownMenuTemplate")
    end
    UIDropDownMenu_Initialize(addRuleMenu, InitAddRuleMenu, "MENU")
    ToggleDropDownMenu(1, nil, addRuleMenu, button, 0, 0)
end

-- Build pooled rule row #index. Position comes from Refresh (it sits below
-- however many summary rows there are); the [x] looks its rule up by index at
-- click time.
local function CreateRuleRow(f, index)
    local state = f.pallySection
    local row = CreateFrame("Frame", nil, state.box)
    row:SetFrameLevel(state.box:GetFrameLevel() + 1)
    row:SetSize(state.box:GetWidth() - UI.BOX_PAD * 2, RULE_ROW_H)
    UI.AddRowBackground(state.box, row, index)

    -- Hovering the row explains the rule (RuleTooltip); the [x] and the (!)
    -- are children and keep their own, more specific tooltips.
    UI.AddTooltip(row, function(self)
        return self.tooltipTitle, self.tooltipText
    end, nil, nil, true)

    local delBtn = UI.CreateCloseButton(row, nil, 0.25)
    delBtn:SetPoint("RIGHT", row, "RIGHT", -K.ROW_END_PAD, 0)
    delBtn:SetScript("OnClick", function()
        if not WhoDoesWhat:RequireEditPermission() then return end
        table.remove(GetBuffRules(), index)
        WhoDoesWhat:LogOperation("Paladin Buffs: rule removed.")
        -- Route through the main refresh (not the section-local Refresh) so
        -- the tab row's counts move along with the board.
        WhoDoesWhat:RefreshMainAssignmentsView()
        WhoDoesWhat:RefreshBoardViews()
    end)
    UI.AddTooltip(delBtn, "Remove this rule",
        "Rules can't be edited in place - remove this one and add it again.")
    row.delBtn = delBtn

    -- Warning (!) between the text and [x]: an assign rule whose paladin can't
    -- cast the blessing, or whose `only` no longer matches what they're
    -- running (RuleWarningText). Anchored off [x] so it holds its column
    -- while hidden.
    local warn = UI.CreateWarningIcon(row)
    warn:SetPoint("RIGHT", delBtn, "LEFT", -4, -2)
    row.warnIcon = warn

    -- One string, not a blessing column plus a detail column: the rule reads
    -- as a sentence, and a short blessing name can't leave a gap in the
    -- middle of it.
    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", row, "LEFT", 4, 0)
    text:SetPoint("RIGHT", warn, "LEFT", -4, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    row.text = text

    state.ruleRows[index] = row
    return row
end

-- ---------------------------------------------------------------------------
-- Refresh: the Source of Truth block, rule rows, box height, no-paladin gray-out
-- ---------------------------------------------------------------------------

function Refresh(f) -- forward declared above
    local state = f.pallySection
    local editable = WhoDoesWhat:CanEditAssignments()
    local source = GetPallyBuffSource()
    UIDropDownMenu_SetText(state.pallyBuffSourceDD, PallyBuffSourceText(source))
    RefreshSourceBlock(state, source)
    if editable then
        UIDropDownMenu_EnableDropDown(state.pallyBuffSourceDD)
    else
        UIDropDownMenu_DisableDropDown(state.pallyBuffSourceDD)
    end

    -- Shown in both modes: in PallyPower mode WDW's rule-driven plan is still
    -- what PallyPower's board is judged against ("unoptimized" buffs).
    local rules = GetBuffRules()
    state.ruleBtn:SetShown(editable)
    state.clearRulesBtn:SetShown(editable)

    -- (!) beside "Add (+)": paladins nothing can reach and no rule speaks for.
    -- It sits on the button that fixes them, and the same mark repeats inside
    -- the menu on the branch to walk down.
    local unhandled = editable and UnhandledDisabledPaladins() or {}
    state.ruleWarn:SetShown(#unhandled > 0)
    if #unhandled > 0 then
        state.ruleWarn.tooltipText = K.DisabledPaladinTooltip(unhandled)
    end

    local rulesTop = UI.BOX_PAD + UI.SECTION_TITLE_H

    -- The one rule WDW writes itself, shown as a read-only line above the
    -- user's rules so a missing Salvation in a battleground isn't a mystery.
    local autoSalv = PvpSalvationIgnored()
    state.autoRuleText:ClearAllPoints()
    state.autoRuleText:SetPoint("TOPLEFT", UI.BOX_PAD + 4, -(rulesTop + 2))
    state.autoRuleText:SetShown(autoSalv)
    local autoH = autoSalv and AUTO_RULE_H or 0
    rulesTop = rulesTop + autoH

    for i, rule in ipairs(rules) do
        local row = state.ruleRows[i] or CreateRuleRow(f, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", UI.BOX_PAD, -(rulesTop + (i - 1) * RULE_ROW_H))
        row:Show()
        row.text:SetText(RuleBuffText(rule) .. " " .. RuleDetailText(rule))
        row.tooltipTitle, row.tooltipText = RuleTooltip(rule)
        row.delBtn:SetShown(editable)
        local warning = RuleWarningText(rule)
        row.warnIcon.tooltipText = warning
        row.warnIcon:SetShown(warning ~= nil)
    end
    for i = #rules + 1, #state.ruleRows do
        state.ruleRows[i]:Hide()
    end

    state.rulesEmptyHint:ClearAllPoints()
    state.rulesEmptyHint:SetPoint("TOPLEFT", UI.BOX_PAD + 4, -(rulesTop + 4))
    state.rulesEmptyHint:SetShown(#rules == 0 and not autoSalv)
    local rulesH = (#rules > 0) and (#rules * RULE_ROW_H)
        or (autoSalv and 2 or UI.EMPTY_ROWS_H)

    state.box:SetHeight(rulesTop + rulesH + UI.BOX_PAD)
    K.LayoutSections(f)

    -- No-paladin gray-out: dead buttons (with the tooltip saying why) and a
    -- gray title. Developer Mode keeps everything live, same as it
    -- lifts class filters. Runs last so it wins over the states above.
    local enabled = DevMode() or HasMemberOfClass("Paladin")
    local reason = not enabled and "No paladins in the group." or nil
    UI.SetSectionTitleColor(state.box, enabled and ACCENT or { 0.5, 0.5, 0.5 })
    for _, btn in ipairs(state.buttons) do
        btn:SetEnabled(enabled)
        btn.disabledReason = reason
    end
    state.clearRulesBtn:SetEnabled(enabled and #rules > 0)
    state.clearRulesBtn.disabledReason = reason or "No buffing rules to clear."

    UI.LayoutHeaderChain(state.box)
end

local function CreatePallyBuffSourceDropdown(parent)
    local sourceDD = UI.CreateMenuDropdown(parent, "WhoDoesWhatPallyBuffSourceDD", 130)
    UIDropDownMenu_Initialize(sourceDD, function(_, level)
        local saved = GetPallyBuffSource()
        for _, option in ipairs(PALLY_BUFF_SOURCES) do
            local key, label = option.key, option.text
            local info = UIDropDownMenu_CreateInfo()
            info.text = label
            info.checked = saved == key
            info.func = function()
                if not WhoDoesWhat:RequireEditPermission() then return end
                WhoDoesWhat.db.profile.settings.pallyBuffSource = key
                UIDropDownMenu_SetText(sourceDD, label)
                WhoDoesWhat:RefreshMainAssignmentsView()
                WhoDoesWhat:RefreshBoardViews()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    return sourceDD
end

-- The page's first option, above every heading: the Source of Truth dropdown
-- and a grey line under it saying what it decides, as Settings pages open
-- with. A titleless section, so it stacks with the rest.
local function BuildSourceBlock(f)
    local block = K.CreateSectionChrome(f, { stack = K.STACK_BLESSINGS }).box

    local label = block:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("TOPLEFT", 4, -8)
    label:SetText("Source of Truth:")
    local sourceDD = CreatePallyBuffSourceDropdown(block)
    -- The template draws its box ~17px in from its own left edge.
    sourceDD:SetPoint("LEFT", label, "RIGHT", -8, -2)

    local blurb = block:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    blurb:SetPoint("TOPLEFT", 4, -36)
    blurb:SetWidth(block:GetWidth() - 8)
    blurb:SetJustifyH("LEFT")
    blurb:SetTextColor(0.7, 0.7, 0.7)
    return sourceDD, block, blurb
end


local function Build(f)
    local sourceDD, sourceBlock, sourceBlurb = BuildSourceBlock(f)

    local chrome = K.CreateSectionChrome(f, {
        title = "Buffing Rules",
        stack = K.STACK_BLESSINGS,
        tintClass = "Paladin",
    })
    local box = chrome.box

    -- The header strip, right to left: clear-all, Add (+), and the (!) for
    -- paladins no rule speaks for yet.
    local clearRulesBtn = UI.CreateCloseButton(box, nil, 0.25)
    clearRulesBtn:SetScript("OnClick", function()
        if not WhoDoesWhat:RequireEditPermission() then return end
        wipe(GetBuffRules())
        WhoDoesWhat:LogOperation("Paladin Buffs: all buffing rules removed.")
        WhoDoesWhat:RefreshMainAssignmentsView()
        WhoDoesWhat:RefreshBoardViews()
    end)
    UI.AddTooltip(clearRulesBtn, "Clear buffing rules", "Remove every buffing rule.")

    local ruleBtn
    ruleBtn = UI.CreateTextButton(box, "Add (+)", "Add a buffing rule",
        "Add a rule to influence paladin buff assignments.", function()
            if not WhoDoesWhat:RequireEditPermission() then return end
            OpenAddRuleMenu(ruleBtn)
        end)

    local ruleWarn = UI.CreateWarningIcon(box)
    K.ChainHeaderButton(chrome, clearRulesBtn)
    K.ChainHeaderButton(chrome, ruleBtn)
    K.ChainHeaderButton(chrome, ruleWarn)

    local rulesEmptyHint = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rulesEmptyHint:SetText("No rules exist")
    rulesEmptyHint:SetTextColor(0.55, 0.55, 0.55)

    local autoRuleText = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoRuleText:SetText("|T" .. WhoDoesWhat.PaladinBuffs.salv.iconId
        .. ":14:14:0:0|t Salvation is ignored in PvP instances")
    autoRuleText:SetTextColor(0.75, 0.75, 0.75)
    autoRuleText:Hide()

    f.pallySection = {
        box = box,
        headerChain = chrome.headerChain,
        buttons = { ruleBtn, clearRulesBtn },
        ruleBtn = ruleBtn,
        ruleWarn = ruleWarn,
        clearRulesBtn = clearRulesBtn,
        rulesEmptyHint = rulesEmptyHint,
        autoRuleText = autoRuleText,
        pallyBuffSourceDD = sourceDD,
        sourceBlock = sourceBlock,
        sourceBlurb = sourceBlurb,
        ruleRows = {},
    }
end

WhoDoesWhat.SectionViews.PaladinBuffs = { Build = Build, Refresh = Refresh }
