local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Paladin Buffs section. Blessings come from the synchronized raid's selected
-- WDW/PallyPower source, and this section shows the result as one pooled
-- read-only row per paladin,
--
--   [role icon] Name  [buff icon][buff icon][buff icon]  [!] n of n [mail]
--
-- the first three buffs each (count-desc), with an ellipsis when more exist;
-- paladins are sorted by workload
-- (ComputePaladinBuffSummary). Row mail whispers one paladin's missing live
-- coverage. A second "Buffing Rules" header below the paladin rows owns the
-- "Add (+)" and clear-all buttons and hides with its rows in PallyPower mode.
-- Buff Grid lives in the window toolbar. PallyBuffSource sits in the main
-- header; its compact sync/action row leads the summary rows.
--
-- Below the summary sit the custom rule rows (the model docs the semantics
-- above CompileBuffRules in Assignments.lua):
--
--   [icon] Salvation is guaranteed for [icon] Healers           (!) [x]
--   [icon] Sanctuary is all <paladin> casts                     (!) [x]
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
-- A (!) beside "Add (+)", inside its menu, and on a paladin's summary row all
-- point at the same thing: a paladin running neither WDW nor PallyPower, who
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
local GetActivePaladinBuffPlan = A.GetActivePaladinBuffPlan
local ComputePaladinBuffCoverage = A.ComputePaladinBuffCoverage
local ComputePaladinBuffSummary = A.ComputePaladinBuffSummary
local GetPaladinBuffWhisper = A.GetPaladinBuffWhisper
local GetBuffRules = A.GetBuffRules
local BuffTalents = A.BuffTalents
local PvpSalvationIgnored = A.PvpSalvationIgnored
local UnhandledDisabledPaladins = A.UnhandledDisabledPaladins
local PaladinBuffSlots = A.PaladinBuffSlots
local ShortAssignmentName = A.ShortAssignmentName

local PALLY_ROW_H = K.ROW_H
local PALLY_STATUS_GAP = 6
local PALLY_MAX_BUFFS = 3
local PALLY_BUFF_ICON = K.ROW_ICON_SIZE
local PALLY_SLOT_W = PALLY_BUFF_ICON + 2
local COVERAGE_OK_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"
local RULE_ROW_H = K.ROW_H
local RULE_HEADER_H = 30
local AUTO_RULE_H = 18

local PALLY_BUFF_SOURCES = {
    { key = "wdw", text = "WDW Assignments", short = "WDW" },
    { key = "pallypower", text = "PallyPower", short = "PallyPower" },
}

local function GetPallyBuffSource()
    return WhoDoesWhat.db.profile.settings.pallyBuffSource or "wdw"
end

local function SetActionButtonText(button, label)
    button:SetText(label)
    button:SetWidth(math.max(44, button:GetTextWidth() + 18))
end

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
        return "|cff909090is ignored|r"
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

-- What the three (!) marks for an unreachable paladin all say.
local function DisabledPaladinTooltip(names)
    local who = {}
    for i, name in ipairs(names) do who[i] = PaladinName(name) end
    return table.concat(who, ", ") .. (#names == 1 and " is" or " are")
        .. " running neither WhoDoesWhat nor PallyPower, so no board can reach"
        .. " them. Assign them one blessing (Add (+) > Assign a Paladin) and"
        .. " whisper it over."
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

-- The guarantee branch runs four levels deep (kind > blessing > target > that
-- class's roles). Nothing here has to arrange that: UIDropDownMenu_AddButton
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

local function BuffIgnored(buffKey)
    return FindRule(function(r)
        return r.kind == "ignore" and r.buff == buffKey
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

local function GuaranteeExists(buffKey, scope, value)
    return FindRule(function(r)
        return r.kind == "guarantee" and r.buff == buffKey
            and r.scope == scope and r.value == value
    end) ~= nil
end

local function AddRule(rule)
    if not WhoDoesWhat:RequireEditPermission() then return end
    CloseDropDownMenus()
    if rule.kind == "guarantee"
        and GuaranteeExists(rule.buff, rule.scope, rule.value) then
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

local function AddGuaranteeBuffs(level)
    for _, key in ipairs(WhoDoesWhat.CanonicalBuffOrder) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = BuffIcon(key) .. WhoDoesWhat.PaladinBuffs[key].name_long
        info.notCheckable = true
        info.hasArrow = true
        info.keepShownOnClick = true
        info.value = { kind = "guarantee", buff = key }
        UIDropDownMenu_AddButton(info, level)
    end
end

-- Level 3 of the guarantee branch: who the promise covers. Each class is both
-- a pick of its own ("All Mages") and a door to its roles on level 4.
local function AddGuaranteeTargets(level, buffKey)
    local function Target(text, scope, value)
        local info = UIDropDownMenu_CreateInfo()
        info.text = text
        info.notCheckable = true
        info.func = function()
            AddRule({ kind = "guarantee", buff = buffKey, scope = scope, value = value })
        end
        return info
    end

    local everyone = Target("Everyone", "everyone", nil)
    everyone.disabled = GuaranteeExists(buffKey, "everyone", nil)
    UIDropDownMenu_AddButton(everyone, level)
    for _, wr in ipairs({ "tank", "healer", "dps" }) do
        local info = Target(WowRoleLabel(wr), "wowrole", wr)
        info.disabled = GuaranteeExists(buffKey, "wowrole", wr)
        UIDropDownMenu_AddButton(info, level)
    end
    K.AddDropdownDivider(level)
    for _, ci in ipairs(WhoDoesWhat.Classes) do
        local info = Target("|cff" .. ci.colorHex .. "All " .. ci.name .. "s|r",
            "class", ci.name)
        info.hasArrow = true
        info.keepShownOnClick = true
        info.value = { kind = "guarantee", buff = buffKey, class = ci.name }
        UIDropDownMenu_AddButton(info, level)
    end
end

local function AddGuaranteeRoles(level, buffKey, className)
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
            info.disabled = GuaranteeExists(buffKey, "role", role.id)
            info.func = function()
                AddRule({ kind = "guarantee", buff = buffKey,
                    scope = "role", value = role.id })
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end
end

local function InitAddRuleMenu(_, level)
    level = level or 1
    if level == 1 then
        -- The two blessings a raid genuinely turns off. `hint` is the nudge for
        -- Light: with no Holy paladin it buffs nobody, so the menu says so
        -- rather than waiting to be asked.
        local function AddIgnore(buffKey, label, hint)
            local ignored = BuffIgnored(buffKey)
            local info = UIDropDownMenu_CreateInfo()
            info.text = BuffIcon(buffKey) .. label
                .. (ignored and " |cff909090(already ignored)|r"
                    or (hint and (" |cffffd100" .. hint .. "|r") or ""))
            info.notCheckable = true
            info.disabled = ignored
            info.func = function() AddRule({ kind = "ignore", buff = buffKey }) end
            UIDropDownMenu_AddButton(info, level)
        end

        AddIgnore("salv", "Ignore Salvation")
        AddIgnore("light", "Ignore Light",
            not HasHolyPaladin() and "(no Holy paladins)" or nil)

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
    elseif value == "guarantee" then
        AddGuaranteeBuffs(level)
    elseif type(value) == "table" then
        if value.kind == "assign" then
            AddAssignBuffs(level, value.paladin)
        elseif value.class then
            AddGuaranteeRoles(level, value.buff, value.class)
        else
            AddGuaranteeTargets(level, value.buff)
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
    row:SetSize(state.box:GetWidth() - K.BOX_PAD * 2, RULE_ROW_H)
    K.AddRowBackground(row, index)

    -- Hovering the row explains the rule (RuleTooltip); the [x] and the (!)
    -- are children and keep their own, more specific tooltips.
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if not self.tooltipTitle then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tooltipTitle, 1, 0.82, 0)
        GameTooltip:AddLine(self.tooltipText, 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local delBtn = K.CreateCloseButton(row)
    delBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    delBtn:SetScript("OnClick", function()
        if not WhoDoesWhat:RequireEditPermission() then return end
        table.remove(GetBuffRules(), index)
        WhoDoesWhat:LogOperation("Paladin Buffs: rule removed.")
        -- Route through the main refresh (not the section-local Refresh) so
        -- ApplyViewMode refits the window height -- removing a rule shrinks
        -- the box, and the collapsed view must follow.
        WhoDoesWhat:RefreshMainAssignmentsView()
        WhoDoesWhat:RefreshBoardViews()
    end)
    delBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove this rule", 1, 1, 1)
        GameTooltip:AddLine("Rules can't be edited in place - remove this one"
            .. " and add it again.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    delBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.delBtn = delBtn

    -- Warning (!) between the text and [x]: an assign rule whose paladin can't
    -- cast the blessing, or whose `only` no longer matches what they're
    -- running (RuleWarningText). Anchored off [x] so it holds its column
    -- while hidden.
    local warn = K.CreateWarningIcon(row)
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
-- Summary rows: name column + condensed buff icons + live-status mail
-- ---------------------------------------------------------------------------

local function PallyBuffSlotEnter(self)
    if not self.buffKey then return end
    local buff = WhoDoesWhat.PaladinBuffs[self.buffKey]
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT", 12, 12)
    GameTooltip:SetText(buff.name_long, 1, 1, 1)
    GameTooltip:AddLine("Casting on " .. self.buffCount
        .. (self.buffCount == 1 and " raider" or " raiders"), 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

local function CoverageTextColor(correct, total)
    if total == 0 then return 0.5, 0.5, 0.5 end
    local ratio = correct / total
    if ratio >= 1 then return 0.3, 1, 0.3 end
    local t = math.min(ratio / 0.95, 1)
    return 1, 0.2 + 0.62 * t, 0.2
end

local function CoverageText(correct, total)
    if total == 0 then return "|cff909090No assignments|r", "" end
    local r, g, b = CoverageTextColor(correct, total)
    local color = string.format("%02x%02x%02x",
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5))
    local percent = math.floor(correct / total * 100 + 0.5)
    return "|cff" .. color .. correct .. "|r |cff909090of|r |cffffffff"
        .. total .. "|r",
        "(" .. percent .. "%)"
end

function WhoDoesWhat:TestPaladinCoverageText()
    assert(CoverageText(0, 0):find("No assignments", 1, true))
    assert(CoverageText(0, 10):find("|cffff33330|r", 1, true))
    local text, percent = CoverageText(19, 20)
    assert(text:find("|cffffd13319|r", 1, true) and percent == "(95%)")
    assert(CoverageText(10, 10):find("|cff4dff4d10|r", 1, true))
    self:Print("Paladin coverage-text check passed.")
end

-- Pooled summary row #index: role/name owns the shared paladin tooltip; each
-- adjacent buff icon keeps its blessing-specific tooltip.
local function CreatePallyRow(state, index)
    local row = CreateFrame("Frame", nil, state.box)
    row:SetFrameLevel(state.box:GetFrameLevel() + 1)
    row:SetSize(state.box:GetWidth() - K.BOX_PAD * 2, PALLY_ROW_H)
    row:SetPoint("TOPLEFT", K.BOX_PAD,
        -(K.BOX_PAD + K.SECTION_TITLE_H + PALLY_ROW_H
            + PALLY_STATUS_GAP
            + (index - 1) * PALLY_ROW_H))
    K.AddRowBackground(row, index)

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("LEFT", 4, 0)
    name:SetWidth(K.NAME_LABEL_W)
    name:SetJustifyH("LEFT")
    row.nameText = name

    local nameHover = CreateFrame("Frame", nil, row)
    nameHover:SetSize(K.NAME_LABEL_W, PALLY_ROW_H)
    nameHover:SetPoint("LEFT", 4, 0)
    nameHover:EnableMouse(true)
    nameHover:SetScript("OnEnter", function(self)
        WhoDoesWhat:ShowRaiderTooltip(self, row.paladinName)
    end)
    nameHover:SetScript("OnLeave", function() WhoDoesWhat:HideRaiderTooltip() end)

    row.slots = {}
    for i = 1, PALLY_MAX_BUFFS do
        local slot = CreateFrame("Frame", nil, row)
        slot:SetSize(PALLY_SLOT_W, PALLY_ROW_H)
        slot:SetPoint("LEFT", 4 + K.NAME_LABEL_W + (i - 1) * PALLY_SLOT_W, 0)
        local icon = slot:CreateTexture(nil, "OVERLAY")
        icon:SetSize(PALLY_BUFF_ICON, PALLY_BUFF_ICON)
        icon:SetPoint("LEFT", 0, 0)
        slot.icon = icon
        slot:EnableMouse(true)
        slot:SetScript("OnEnter", PallyBuffSlotEnter)
        slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        slot:Hide()
        row.slots[i] = slot
    end

    row.mailBtn = K.CreateMailButton(row, function()
        if not row.paladinName then return end
        local msg = GetPaladinBuffWhisper(row.paladinName)
        if msg then return row.paladinName, msg, msg, true end
    end)
    row.mailBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    local coverageText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.coverageText = coverageText

    local coveragePercent = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    local percentFont, percentSize, percentFlags = coveragePercent:GetFont()
    if percentFont then
        coveragePercent:SetFont(percentFont, math.max(percentSize - 2, 8), percentFlags)
    end
    coveragePercent:SetPoint("RIGHT", row.mailBtn, "LEFT", -10, 0)
    coverageText:SetPoint("RIGHT", coveragePercent, "LEFT", -2, 0)
    row.coveragePercent = coveragePercent

    local coverageIcon = row:CreateTexture(nil, "OVERLAY")
    coverageIcon:SetSize(16, 16)
    coverageIcon:SetPoint("RIGHT", coverageText, "LEFT", -4, 0)
    row.coverageIcon = coverageIcon

    -- (!) for a paladin running neither WDW nor PallyPower: their column of
    -- the plan is being computed for someone who has no way to read it.
    local warn = K.CreateWarningIcon(row)
    warn:SetPoint("RIGHT", coverageIcon, "LEFT", -2, -1)
    row.warnIcon = warn

    local more = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    more:SetPoint("LEFT", 4 + K.NAME_LABEL_W + PALLY_MAX_BUFFS * PALLY_SLOT_W, 0)
    more:SetText("...")
    more:Hide()
    row.moreText = more
    return row
end

-- ---------------------------------------------------------------------------
-- Refresh: summary rows, rule rows, box height, no-paladin gray-out
-- ---------------------------------------------------------------------------

function Refresh(f) -- forward declared above
    local state = f.pallySection
    local buffPlan = GetActivePaladinBuffPlan()
    local summary = ComputePaladinBuffSummary(buffPlan)
    local _, _, byPaladin = ComputePaladinBuffCoverage(buffPlan)
    local editable = WhoDoesWhat:CanEditAssignments()
    local source = GetPallyBuffSource()
    local awaiting = {}
    if source == "wdw" then
        for _, paladin in ipairs(summary) do
            if paladin.awaitingTalents then
                awaiting[#awaiting + 1] = paladin.name
            end
        end
    end
    UIDropDownMenu_SetText(state.pallyBuffSourceDD,
        source == "pallypower" and "PallyPower" or "WDW")
    if editable then
        UIDropDownMenu_EnableDropDown(state.pallyBuffSourceDD)
    else
        UIDropDownMenu_DisableDropDown(state.pallyBuffSourceDD)
    end

    for i, p in ipairs(summary) do
        local row = state.rows[i] or CreatePallyRow(state, i)
        state.rows[i] = row
        row.paladinName = p.name
        row:Show()
        local awaitingTalents = source == "wdw" and p.awaitingTalents
        row.mailBtn:SetShown(editable and not awaitingTalents)
        row.coveragePercent:ClearAllPoints()
        if editable then
            row.coveragePercent:SetPoint("RIGHT", row.mailBtn, "LEFT", -10, 0)
        else
            row.coveragePercent:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        end
        row.moreText:SetShown(not awaitingTalents and #p.buffs > PALLY_MAX_BUFFS)
        -- Realm tags eat the narrow name column here; the paladin's full
        -- name still identifies them everywhere it matters (tooltips, the
        -- diffs window, whispers).
        row.nameText:SetText(PlayerTextWithRole(p.name, K.ROW_ICON_SIZE,
            ShortAssignmentName(p.name)))
        local coverage = byPaladin[p.name] or { correct = 0, total = 0 }
        local complete = coverage.total > 0 and coverage.correct == coverage.total
        local hasMissing = coverage.correct < coverage.total
        row.mailBtn:SetEnabled(hasMissing)
        row.mailBtn.icon:SetDesaturated(not hasMissing)
        row.coverageIcon:SetTexture(awaitingTalents and WhoDoesWhat.WARNING_ICON
            or COVERAGE_OK_ICON)
        row.coverageIcon:SetShown(awaitingTalents or complete)
        local disabled = source == "wdw" and WhoDoesWhat:IsPaladinDisabled(p.name)
        row.warnIcon:SetShown(disabled and true or false)
        if disabled then
            row.warnIcon.tooltipText = DisabledPaladinTooltip({ p.name })
        end
        if awaitingTalents then
            row.coverageText:SetText("Awaiting talents")
            row.coveragePercent:SetText("")
            row.coverageText:SetTextColor(1, 0.62, 0.25)
        else
            local coverageText, coveragePercent = CoverageText(
                coverage.correct, coverage.total)
            row.coverageText:SetText(coverageText)
            row.coveragePercent:SetText(coveragePercent)
            row.coverageText:SetTextColor(1, 1, 1)
        end
        for bi, slot in ipairs(row.slots) do
            local b = not awaitingTalents and p.buffs[bi]
            if b then
                slot.icon:SetTexture(WhoDoesWhat.PaladinBuffs[b.key].iconId)
                slot.buffKey = b.key
                slot.buffCount = b.count
                slot:Show()
            else
                slot.buffKey = nil
                slot:Hide()
            end
        end
    end
    for i = #summary + 1, #state.rows do
        state.rows[i]:Hide()
        state.rows[i].paladinName = nil
    end

    local ppRowTop = K.BOX_PAD + K.SECTION_TITLE_H
    state.emptyHint:ClearAllPoints()
    state.emptyHint:SetPoint("TOPLEFT", state.box, "TOPLEFT", K.BOX_PAD + 4,
        -(ppRowTop + PALLY_ROW_H + PALLY_STATUS_GAP + 4))
    state.emptyHint:SetShown(#summary == 0)
    local rowsH = (#summary > 0) and (#summary * PALLY_ROW_H) or K.DYN_EMPTY_H

    -- PallyPower leads the body as a compact, right-aligned status row.
    state.ppArea:ClearAllPoints()
    state.ppArea:SetPoint("TOPLEFT", state.box, "TOPLEFT", K.BOX_PAD, -ppRowTop)
    state.ppArea:SetPoint("TOPRIGHT", state.box, "TOPRIGHT", -K.BOX_PAD, -ppRowTop)

    local ppState, ppText, ppDiffCount
    if #awaiting == 0 then
        ppState, ppText, ppDiffCount = K.GetPallyPowerState(#summary)
    end
    state.ppArea.tooltipTitle = nil
    state.ppArea.tooltipText = nil
    state.ppIcon:ClearAllPoints()
    state.ppStatus:ClearAllPoints()
    state.ppDiffBtn:ClearAllPoints()
    state.ppApplyBtn:ClearAllPoints()
    if #awaiting > 0 then
        state.ppIcon:SetTexture(WhoDoesWhat.WARNING_ICON)
        state.ppIcon:Show()
        state.ppStatus:SetPoint("RIGHT", state.ppArea, "RIGHT", -2, 0)
        state.ppIcon:SetPoint("RIGHT", state.ppStatus, "LEFT", -4, 0)
        state.ppStatus:SetTextColor(1, 0.62, 0.25)
        state.ppDiffBtn:Hide()
        state.ppApplyBtn:Hide()
        ppText = "Awaiting Paladin talents"
        state.ppArea.tooltipTitle = ppText
        state.ppArea.tooltipText = "WDW will not assign blessings to "
            .. table.concat(awaiting, ", ") .. " until talent data arrives."
            .. " Target them once while in range to pull it, or mark a paladin"
            .. " as Non-raider if they are sitting out."
    elseif ppState == "inactive" then
        state.ppIcon:Hide()
        state.ppStatus:SetPoint("RIGHT", state.ppArea, "RIGHT", -2, 0)
        state.ppStatus:SetTextColor(0.5, 0.5, 0.5)
        state.ppDiffBtn:Hide()
        state.ppApplyBtn:Hide()
    elseif ppState == "synced" then
        state.ppIcon:SetTexture(COVERAGE_OK_ICON)
        state.ppIcon:Show()
        state.ppStatus:SetPoint("RIGHT", state.ppArea, "RIGHT", -2, 0)
        state.ppIcon:SetPoint("RIGHT", state.ppStatus, "LEFT", -4, 0)
        state.ppStatus:SetTextColor(0.3, 1, 0.3)
        state.ppDiffBtn:Hide()
        state.ppApplyBtn:Hide()
    else
        state.ppIcon:SetTexture(WhoDoesWhat.WARNING_ICON)
        state.ppIcon:Show()
        if source == "pallypower" then
            ppText = ppDiffCount .. " unoptimized buff"
                .. (ppDiffCount == 1 and "" or "s")
            SetActionButtonText(state.ppDiffBtn, "Examine")
            state.ppDiffBtn:SetPoint("RIGHT", state.ppArea, "RIGHT", 0, 0)
            state.ppStatus:SetTextColor(1, 0.82, 0)
            state.ppApplyBtn:Hide()
        else
            ppText = ppDiffCount .. " Buff" .. (ppDiffCount == 1 and "" or "s")
                .. " in PP " .. (ppDiffCount == 1 and "doesn't" or "don't")
                .. " match the plan"
            SetActionButtonText(state.ppDiffBtn, "Diffs")
            SetActionButtonText(state.ppApplyBtn, "Fix")
            if editable then
                state.ppApplyBtn:SetPoint("RIGHT", state.ppArea, "RIGHT", 0, 0)
                state.ppDiffBtn:SetPoint("RIGHT", state.ppApplyBtn, "LEFT", -2, 0)
                state.ppApplyBtn:Show()
            else
                state.ppDiffBtn:SetPoint("RIGHT", state.ppArea, "RIGHT", 0, 0)
                state.ppApplyBtn:Hide()
            end
            state.ppStatus:SetTextColor(1, 0.4, 0.4)
        end
        state.ppStatus:SetPoint("RIGHT", state.ppDiffBtn, "LEFT", -4, -1)
        state.ppIcon:SetPoint("RIGHT", state.ppStatus, "LEFT", -4, 0)
        state.ppDiffBtn:Show()
    end
    state.ppStatus:SetText(ppText)

    -- The rules area below the summary has its own header, then one editable
    -- row per rule (or an empty-state line). Everything is re-anchored every
    -- pass because its y depends on how many summary rows sit above it.
    local rules = GetBuffRules()
    local showRules = source ~= "pallypower"
    local ruleHeaderTop = ppRowTop + PALLY_ROW_H + PALLY_STATUS_GAP + rowsH + 4
    state.ruleTitle:ClearAllPoints()
    state.ruleTitle:SetPoint("LEFT", state.box, "TOPLEFT", K.BOX_PAD + 2,
        -(ruleHeaderTop + K.MAIL_BTN_SIZE / 2 + 3))
    state.clearRulesBtn:ClearAllPoints()
    state.clearRulesBtn:SetPoint("TOPRIGHT", state.box, "TOPRIGHT", -K.BOX_PAD,
        -(ruleHeaderTop + 3))
    state.ruleBtn:ClearAllPoints()
    state.ruleBtn:SetPoint("RIGHT", state.clearRulesBtn, "LEFT", -2, 0)
    state.ruleTitle:SetShown(showRules)
    state.ruleBtn:SetShown(showRules and editable)
    state.clearRulesBtn:SetShown(showRules and editable)

    -- (!) beside "Add (+)": paladins nothing can reach and no rule speaks for.
    -- It sits on the button that fixes them, and the same mark repeats inside
    -- the menu on the branch to walk down.
    local unhandled = showRules and editable and UnhandledDisabledPaladins() or {}
    state.ruleWarn:ClearAllPoints()
    state.ruleWarn:SetPoint("RIGHT", state.ruleBtn, "LEFT", -2, 0)
    state.ruleWarn:SetShown(#unhandled > 0)
    if #unhandled > 0 then
        state.ruleWarn.tooltipText = DisabledPaladinTooltip(unhandled)
    end
    state.ruleDivider:ClearAllPoints()
    state.ruleDivider:SetPoint("TOPLEFT", K.BOX_PAD, -(ruleHeaderTop + 28))
    state.ruleDivider:SetPoint("TOPRIGHT", -K.BOX_PAD, -(ruleHeaderTop + 28))
    state.ruleDivider:SetShown(showRules)

    local rulesTop = ruleHeaderTop + RULE_HEADER_H

    -- The one rule WDW writes itself, shown as a read-only line above the
    -- user's rules so a missing Salvation in a battleground isn't a mystery.
    local autoSalv = showRules and PvpSalvationIgnored()
    state.autoRuleText:ClearAllPoints()
    state.autoRuleText:SetPoint("TOPLEFT", K.BOX_PAD + 4, -(rulesTop + 2))
    state.autoRuleText:SetShown(autoSalv)
    local autoH = autoSalv and AUTO_RULE_H or 0
    rulesTop = rulesTop + autoH

    for i, rule in ipairs(rules) do
        local row = state.ruleRows[i] or CreateRuleRow(f, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", K.BOX_PAD, -(rulesTop + (i - 1) * RULE_ROW_H))
        row:SetShown(showRules)
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
    state.rulesEmptyHint:SetPoint("TOPLEFT", K.BOX_PAD + 4, -(rulesTop + 4))
    state.rulesEmptyHint:SetShown(showRules and #rules == 0 and not autoSalv)
    local rulesH = (#rules > 0) and (#rules * RULE_ROW_H)
        or (autoSalv and 2 or K.DYN_EMPTY_H)

    state.box:SetHeight(showRules and (rulesTop + rulesH + K.BOX_PAD)
        or (ppRowTop + PALLY_ROW_H + PALLY_STATUS_GAP + rowsH + K.BOX_PAD))
    K.UpdateContentHeight(f)

    -- No-paladin gray-out: dead buttons (with the tooltip saying why) and a
    -- gray title. Developer Mode keeps everything live, same as it
    -- lifts class filters. Runs last so it wins over the states above.
    local enabled = DevMode() or HasMemberOfClass("Paladin")
    local reason = not enabled and "No paladins in the group." or nil
    if enabled then
        state.box.title:SetTextColor(0.95, 0.95, 0.95)
        state.ruleTitle:SetTextColor(1, 0.82, 0)
    else
        state.box.title:SetTextColor(0.5, 0.5, 0.5)
        state.ruleTitle:SetTextColor(0.5, 0.5, 0.5)
    end
    for _, btn in ipairs(state.buttons) do
        btn:SetEnabled(enabled)
        btn.disabledReason = reason
    end
    state.clearRulesBtn:SetEnabled(enabled and #rules > 0)

    K.LayoutHeaderChain(state.headerChain)
end

local function ShowPallyBuffSourceTooltip(owner)
    local selected = GetPallyBuffSource()
    local wdwColor = selected == "wdw" and "|cffffffff" or "|cff909090"
    local ppColor = selected == "pallypower" and "|cffffffff" or "|cff909090"
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText("Pally Buff Source", 1, 0.82, 0)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffffd100WDW:|r " .. wdwColor
        .. "WhoDoesWhat's auto-assignments are the source of truth for this raid."
        .. " Auto-assignments power all of WDW's visual elements and are pushed"
        .. " to PallyPower automatically.|r", 1, 1, 1, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffffd100PP:|r " .. ppColor
        .. "Assignments set in PallyPower are the source of truth for this raid."
        .. " Assignments made there will power all of WDW's visual elements."
        .. " Buff assignments will not be changed automatically. Useful when WDW"
        .. " is |cffff4040NOT|r " .. ppColor
        .. "the primary controller of buffs in this raid.|r", 1, 1, 1, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("This affects WDW Status Bars, WDW buffing buttons, and"
        .. " the buff progress shown above.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end

local function CreatePallyBuffSourceDropdown(parent)
    local sourceDD = CreateFrame("Frame", "WhoDoesWhatPallyBuffSourceDD", parent,
        "UIDropDownMenuTemplate")
    sourceDD:SetPoint("LEFT", parent, "LEFT", -15, -3)
    UIDropDownMenu_SetWidth(sourceDD, 90)
    K.LeftAlignDropdown(sourceDD)
    UIDropDownMenu_Initialize(sourceDD, function(_, level)
        local saved = GetPallyBuffSource()
        for _, option in ipairs(PALLY_BUFF_SOURCES) do
            local key, label, short = option.key, option.text, option.short
            local info = UIDropDownMenu_CreateInfo()
            info.text = label
            info.checked = saved == key
            info.func = function()
                if not WhoDoesWhat:RequireEditPermission() then return end
                WhoDoesWhat.db.profile.settings.pallyBuffSource = key
                UIDropDownMenu_SetText(sourceDD, short)
                WhoDoesWhat:RefreshMainAssignmentsView()
                WhoDoesWhat:RefreshBoardViews()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    sourceDD:EnableMouse(true)
    sourceDD:SetScript("OnEnter", function() ShowPallyBuffSourceTooltip(sourceDD) end)
    sourceDD:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local sourceButton = _G[sourceDD:GetName() .. "Button"]
    if sourceButton then
        sourceButton:HookScript("OnEnter",
            function() ShowPallyBuffSourceTooltip(sourceDD) end)
        sourceButton:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return sourceDD
end

local function CreatePallyPowerArea(box)
    local area = CreateFrame("Frame", nil, box)
    area:SetHeight(PALLY_ROW_H)
    area:SetFrameLevel(box:GetFrameLevel() + 1)
    area:EnableMouse(true)
    area:SetScript("OnEnter", function(self)
        if not self.tooltipText then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tooltipTitle or "Paladin Buffs", 1, 0.82, 0)
        GameTooltip:AddLine(self.tooltipText, 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    area:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local icon = area:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)

    local status = area:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")

    local apply = K.AddHeaderTextButton(area, area, "Fix",
        "Send fixes to PallyPower",
        "Broadcast the optimized WDW blessing plan and update the local PP mirror.", function()
            WhoDoesWhat:SyncToPallyPower()
            WhoDoesWhat:RefreshMainAssignmentsView()
            WhoDoesWhat:RefreshStatusBarsView()
        end)

    local diff = K.AddHeaderTextButton(area, apply, "Diffs",
        "Show PallyPower differences",
        "Open the detailed comparison between WDW and PallyPower.", function()
            WhoDoesWhat:OpenPallyPowerDiffView()
        end)
    diff:ClearAllPoints()
    diff:SetPoint("RIGHT", apply, "LEFT", -2, 0)
    apply:ClearAllPoints()
    apply:SetPoint("RIGHT", area, "RIGHT", 0, 0)

    return area, icon, status, diff, apply
end

local function Build(f, content)
    local chrome = K.CreateSectionChrome(f, content, {
        title = "Paladin Buffs",
        column = K.COL_LEFT,
        tintClass = "Paladin",
    })
    local box = chrome.box

    local sourceArea = CreateFrame("Frame", nil, box)
    sourceArea:SetFrameLevel(box:GetFrameLevel() + 1)
    sourceArea:SetSize(145, K.MAIL_BTN_SIZE)
    local sourceLabel = sourceArea:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sourceLabel:SetPoint("LEFT", sourceArea, "LEFT", 0, 0)
    sourceLabel:SetText("Mode:")
    local sourceDD = CreatePallyBuffSourceDropdown(sourceArea)
    sourceDD:ClearAllPoints()
    sourceDD:SetPoint("LEFT", sourceLabel, "RIGHT", -14, -3)
    K.ChainHeaderButton(chrome, sourceArea)

    local ruleTitle = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ruleTitle:SetText("Buffing Rules")

    local ruleDivider = box:CreateTexture(nil, "ARTWORK")
    ruleDivider:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    ruleDivider:SetHeight(1)

    local clearRulesBtn = K.CreateCloseButton(box, nil, 0.25)
    clearRulesBtn:SetScript("OnClick", function()
        if not WhoDoesWhat:RequireEditPermission() then return end
        wipe(GetBuffRules())
        WhoDoesWhat:LogOperation("Paladin Buffs: all buffing rules removed.")
        WhoDoesWhat:RefreshMainAssignmentsView()
        WhoDoesWhat:RefreshBoardViews()
    end)
    clearRulesBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self:IsEnabled() then
            GameTooltip:SetText("Clear buffing rules", 1, 1, 1)
            GameTooltip:AddLine("Remove every buffing rule.", 0.8, 0.8, 0.8, true)
        elseif self.disabledReason then
            GameTooltip:SetText(self.disabledReason, 0.6, 0.6, 0.6)
        else
            GameTooltip:SetText("No buffing rules to clear", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    clearRulesBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local ruleBtn
    ruleBtn = K.AddHeaderTextButton(box, clearRulesBtn, "Add (+)", "Add a buffing rule",
        "Add a rule to influence paladin buff assignments.", function()
            if not WhoDoesWhat:RequireEditPermission() then return end
            OpenAddRuleMenu(ruleBtn)
        end)

    local ruleWarn = K.CreateWarningIcon(box)

    local hint = K.CreateEmptyHint(box)
    hint:SetText("No paladins in the group.")

    local rulesEmptyHint = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rulesEmptyHint:SetText("No rules exist")
    rulesEmptyHint:SetTextColor(0.55, 0.55, 0.55)

    local autoRuleText = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoRuleText:SetText("|T" .. WhoDoesWhat.PaladinBuffs.salv.iconId
        .. ":14:14:0:0|t Salvation is ignored in PvP instances")
    autoRuleText:SetTextColor(0.75, 0.75, 0.75)
    autoRuleText:Hide()

    local ppArea, ppIcon, ppStatus, ppDiffBtn, ppApplyBtn =
        CreatePallyPowerArea(box)

    f.pallySection = {
        box = box,
        headerChain = chrome.headerChain,
        buttons = { ruleBtn, clearRulesBtn },
        emptyHint = hint,
        ruleTitle = ruleTitle,
        ruleDivider = ruleDivider,
        ruleBtn = ruleBtn,
        ruleWarn = ruleWarn,
        clearRulesBtn = clearRulesBtn,
        rulesEmptyHint = rulesEmptyHint,
        autoRuleText = autoRuleText,
        pallyBuffSourceDD = sourceDD,
        ppArea = ppArea,
        ppIcon = ppIcon,
        ppStatus = ppStatus,
        ppDiffBtn = ppDiffBtn,
        ppApplyBtn = ppApplyBtn,
        rows = {},
        ruleRows = {},
    }
end

WhoDoesWhat.SectionViews.PaladinBuffs = { Build = Build, Refresh = Refresh }
