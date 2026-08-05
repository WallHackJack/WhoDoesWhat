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
-- at CompileBuffRules in Assignments.lua):
--
--   [buff v] [Is Ignored / Prioritized for / Preferred by v] [target v] (!) [x]
--
-- One rule per blessing, six at most (the buff dropdown only offers unruled
-- blessings). Rules are shared strategy config in the synced board, so the
-- same assignment permission applies to editing them.
--
-- The whole section grays out while the group has no paladins (Developer
-- Mode keeps it live, same as it lifts class filters).

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit

local DevMode = A.DevMode
local MembersOfClass = A.MembersOfClass
local PlayerText = A.PlayerText
local PlayerTextWithRole = A.PlayerTextWithRole
local GetActivePaladinBuffPlan = A.GetActivePaladinBuffPlan
local ComputePaladinBuffCoverage = A.ComputePaladinBuffCoverage
local ComputePaladinBuffSummary = A.ComputePaladinBuffSummary
local GetPaladinBuffWhisper = A.GetPaladinBuffWhisper
local GetBuffRules = A.GetBuffRules
local BuffTalents = A.BuffTalents

local PALLY_ROW_H = K.ROW_H
local PALLY_STATUS_GAP = 6
local PALLY_MAX_BUFFS = 3
local PALLY_BUFF_ICON = K.ROW_ICON_SIZE
local PALLY_SLOT_W = PALLY_BUFF_ICON + 2
local COVERAGE_OK_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"
local RULE_ROW_H = K.ROW_H
local RULE_BUFF_DD_W = 68
local RULE_KIND_DD_W = 80
local RULE_TARGET_DD_W = 76
local RULE_HEADER_H = 30

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

-- Menu text / collapsed text per rule kind.
local RULE_KINDS = {
    { kind = "ignore", menu = "Is Ignored", short = "Ignored" },
    { kind = "prioritize", menu = "Is Prioritized for...", short = "Priority for" },
    { kind = "prefer", menu = "Is Preferred by...", short = "Preferred by" },
}

local Refresh -- the section's registered refresh; forward-declared to stay a
              -- file-local (rule callbacks repaint via RefreshMainAssignmentsView)

-- ---------------------------------------------------------------------------
-- Rule-row text + warning helpers
-- ---------------------------------------------------------------------------

local function RuleBuffText(rule)
    local buff = WhoDoesWhat.PaladinBuffs[rule.buff]
    if not buff then return "?" end
    return "|T" .. buff.iconId .. ":14:14:0:0|t " .. buff.name_short
end

local function RuleKindText(rule)
    for _, k in ipairs(RULE_KINDS) do
        if k.kind == rule.kind then return k.short end
    end
    return "?"
end

-- A paladin's scanned rank in a rule's buff talent: 0..max once scanned, nil
-- while unscanned OR when the buff has no talent at all (Salv/Light).
local function RuleBuffRank(rule, paladinName)
    if not BuffTalents[rule.buff] then return nil end
    local t = WhoDoesWhat:GetPaladinBuffTalents(paladinName)
    return t and t[rule.buff]
end

-- Talent note behind a paladin's name in the prefer dropdown: green
-- (talented) / red (can't cast) for the talent-granted blessings, gray n/max
-- for the Improved ones, gray (not scanned) while their data hasn't arrived.
-- nil (no note) for Salvation/Light -- every paladin casts those equally.
local function RulePaladinNote(rule, paladinName)
    local meta = BuffTalents[rule.buff]
    if not meta then return nil end
    local rank = RuleBuffRank(rule, paladinName)
    if rank == nil then
        return "|cff909090(not scanned)|r"
    end
    if meta.maxRank == 1 then
        return rank > 0 and "|cff40ff40(talented)|r" or "|cffff6060(can't cast)|r"
    end
    return "|cff909090(" .. rank .. "/" .. meta.maxRank .. ")|r"
end

-- Warning for a prefer rule whose paladin has a known 0 in the buff's
-- talent: for the gated blessings the rule is outright inert, for the
-- Improved ones the blessing lands unimproved. Unscanned paladins don't
-- warn -- no data is not the same as no talent.
local function RuleWarningText(rule)
    if rule.kind ~= "prefer" or not rule.value then return nil end
    local meta = BuffTalents[rule.buff]
    if not meta or RuleBuffRank(rule, rule.value) ~= 0 then return nil end
    local buffName = WhoDoesWhat.PaladinBuffs[rule.buff].name_long
    if meta.maxRank == 1 then
        return rule.value .. " has not talented " .. meta.talent
            .. " and can't cast " .. buffName .. " at all - this rule does nothing."
    end
    return rule.value .. " has no " .. meta.talent .. " ranks; their "
        .. buffName .. " will be unimproved while better-talented paladins exist."
end

local function RuleTargetText(rule)
    if rule.kind == "prefer" then
        return rule.value and PlayerTextWithRole(rule.value, K.DROPDOWN_ICON_SIZE)
            or "|cff909090Choose...|r"
    end
    if rule.scope == "wowrole" then
        return WOW_ROLE_LABELS[rule.value] or "?"
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
            return "|T" .. role.icon .. ":14:14:0:0|t " .. role.name
        end
        return "?"
    end
    return "Everyone"
end

-- ---------------------------------------------------------------------------
-- Rule rows
-- ---------------------------------------------------------------------------

-- Build pooled rule row #index. Position comes from Refresh (it sits below
-- however many summary rows there are); every callback looks its rule up by
-- index at click time.
local function CreateRuleRow(f, index)
    local state = f.pallySection
    local row = CreateFrame("Frame", nil, state.box)
    row:SetFrameLevel(state.box:GetFrameLevel() + 1)
    row:SetSize(state.box:GetWidth() - K.BOX_PAD * 2, RULE_ROW_H)
    K.AddRowBackground(row, index)

    local function Entry() return GetBuffRules()[index] end
    local function Changed()
        -- Route through the main refresh (not the section-local Refresh) so
        -- ApplyViewMode refits the window height -- adding/removing a rule
        -- grows/shrinks the box, and the collapsed view must follow.
        WhoDoesWhat:RefreshMainAssignmentsView()
        WhoDoesWhat:RefreshBuffingGridView()
    end

    -- Buff picker: only blessings no other rule already claims.
    local buffDD = CreateFrame("Frame", "WhoDoesWhatPallyRuleBuffDD" .. index, row, "UIDropDownMenuTemplate")
    buffDD:SetPoint("LEFT", row, "LEFT", -13, -2)
    UIDropDownMenu_SetWidth(buffDD, RULE_BUFF_DD_W)
    K.LeftAlignDropdown(buffDD)
    UIDropDownMenu_Initialize(buffDD, function(_, level)
        local rule = Entry()
        if not rule then return end
        local taken = {}
        for _, r in ipairs(GetBuffRules()) do
            if r ~= rule then taken[r.buff] = true end
        end
        for _, key in ipairs(WhoDoesWhat.CanonicalBuffOrder) do
            if not taken[key] then
                local buff = WhoDoesWhat.PaladinBuffs[key]
                local info = UIDropDownMenu_CreateInfo()
                info.text = "|T" .. buff.iconId .. ":14:14:0:0|t " .. buff.name_long
                info.checked = (rule.buff == key)
                info.func = function()
                    if not WhoDoesWhat:RequireEditPermission() then return end
                    rule.buff = key
                    Changed()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end)
    row.buffDD = buffDD

    local kindDD = CreateFrame("Frame", "WhoDoesWhatPallyRuleKindDD" .. index, row, "UIDropDownMenuTemplate")
    kindDD:SetPoint("LEFT", buffDD, "RIGHT", -30, 0)
    UIDropDownMenu_SetWidth(kindDD, RULE_KIND_DD_W)
    K.LeftAlignDropdown(kindDD)
    UIDropDownMenu_Initialize(kindDD, function(_, level)
        local rule = Entry()
        if not rule then return end
        for _, k in ipairs(RULE_KINDS) do
            local kind = k.kind
            local info = UIDropDownMenu_CreateInfo()
            info.text = k.menu
            info.checked = (rule.kind == kind)
            info.func = function()
                if rule.kind ~= kind then
                    if not WhoDoesWhat:RequireEditPermission() then return end
                    rule.kind = kind
                    -- The target means something different per kind.
                    rule.scope = (kind == "prioritize") and "everyone" or nil
                    rule.value = nil
                    Changed()
                end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    row.kindDD = kindDD

    -- Target picker; hidden for "Is Ignored". Prefer lists the group's
    -- paladins; prioritize offers Everyone / the three wow roles, then each
    -- class opening a level-2 list of "All <class>" plus its roles.
    local targetDD = CreateFrame("Frame", "WhoDoesWhatPallyRuleTargetDD" .. index, row, "UIDropDownMenuTemplate")
    targetDD:SetPoint("LEFT", kindDD, "RIGHT", -30, 0)
    UIDropDownMenu_SetWidth(targetDD, RULE_TARGET_DD_W)
    K.LeftAlignDropdown(targetDD)
    UIDropDownMenu_Initialize(targetDD, function(_, level)
        local rule = Entry()
        if not rule then return end

        if rule.kind == "prefer" then
            local paladins = MembersOfClass("Paladin")
            if #paladins == 0 then
                local info = UIDropDownMenu_CreateInfo()
                info.text = "|cff909090No paladins in group|r"
                info.notCheckable = true
                info.disabled = true
                UIDropDownMenu_AddButton(info, level)
            end

            -- Capable casters (a known rank in the buff's talent) float
            -- above a divider; everyone is annotated with where they stand.
            -- Salv/Light have no talent, so nobody floats and nothing notes.
            local floated, rest = {}, {}
            for _, name in ipairs(paladins) do
                if BuffTalents[rule.buff] and (RuleBuffRank(rule, name) or 0) > 0 then
                    floated[#floated + 1] = name
                else
                    rest[#rest + 1] = name
                end
            end
            local ordered = {}
            for _, name in ipairs(floated) do ordered[#ordered + 1] = name end
            for _, name in ipairs(rest) do ordered[#ordered + 1] = name end
            local dividerAfter = (#floated > 0 and #rest > 0) and #floated or nil

            for i, name in ipairs(ordered) do
                local note = RulePaladinNote(rule, name)
                local info = UIDropDownMenu_CreateInfo()
                info.text = PlayerTextWithRole(name, K.DROPDOWN_ICON_SIZE)
                    .. (note and (" " .. note) or "")
                info.checked = (rule.value == name)
                info.func = function()
                    if not WhoDoesWhat:RequireEditPermission() then return end
                    rule.value = name
                    Changed()
                end
                UIDropDownMenu_AddButton(info, level)
                if i == dividerAfter then
                    K.AddDropdownDivider(level)
                end
            end
            return
        end

        if level == 2 then
            local classInfo
            for _, ci in ipairs(WhoDoesWhat.Classes) do
                if ci.name == UIDROPDOWNMENU_MENU_VALUE then
                    classInfo = ci
                    break
                end
            end
            if not classInfo then return end
            local info = UIDropDownMenu_CreateInfo()
            info.text = "|cff" .. classInfo.colorHex .. "All " .. classInfo.name .. "s|r"
            info.checked = (rule.scope == "class" and rule.value == classInfo.name)
            info.func = function()
                if not WhoDoesWhat:RequireEditPermission() then return end
                rule.scope, rule.value = "class", classInfo.name
                Changed()
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
            K.AddDropdownDivider(level)
            for _, list in ipairs({ classInfo.roles, classInfo.customRoles or {} }) do
                for _, role in ipairs(list) do
                    local roleInfo = UIDropDownMenu_CreateInfo()
                    roleInfo.text = "|T" .. role.icon .. ":14:14:0:0|t |cff"
                        .. classInfo.colorHex .. role.name .. "|r"
                    roleInfo.checked = (rule.scope == "role" and rule.value == role.id)
                    roleInfo.func = function()
                        if not WhoDoesWhat:RequireEditPermission() then return end
                        rule.scope, rule.value = "role", role.id
                        Changed()
                        CloseDropDownMenus()
                    end
                    UIDropDownMenu_AddButton(roleInfo, level)
                end
            end
            return
        end

        local info = UIDropDownMenu_CreateInfo()
        info.text = "Everyone"
        info.checked = (rule.scope == "everyone" or not rule.scope)
        info.func = function()
            if not WhoDoesWhat:RequireEditPermission() then return end
            rule.scope, rule.value = "everyone", nil
            Changed()
        end
        UIDropDownMenu_AddButton(info, level)
        for _, wr in ipairs({ "tank", "healer", "dps" }) do
            local wrInfo = UIDropDownMenu_CreateInfo()
            wrInfo.text = WOW_ROLE_LABELS[wr]
            wrInfo.checked = (rule.scope == "wowrole" and rule.value == wr)
            wrInfo.func = function()
                if not WhoDoesWhat:RequireEditPermission() then return end
                rule.scope, rule.value = "wowrole", wr
                Changed()
            end
            UIDropDownMenu_AddButton(wrInfo, level)
        end
        K.AddDropdownDivider(level)
        for _, ci in ipairs(WhoDoesWhat.Classes) do
            local classItem = UIDropDownMenu_CreateInfo()
            classItem.text = "|cff" .. ci.colorHex .. ci.name .. "|r"
            classItem.hasArrow = true
            classItem.value = ci.name
            classItem.keepShownOnClick = true
            classItem.notCheckable = true
            classItem.func = function() end
            UIDropDownMenu_AddButton(classItem, level)
        end
    end)
    row.targetDD = targetDD

    local delBtn = K.CreateCloseButton(row)
    delBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    delBtn:SetScript("OnClick", function()
        if not WhoDoesWhat:RequireEditPermission() then return end
        table.remove(GetBuffRules(), index)
        WhoDoesWhat:LogOperation("Paladin Buffs: rule removed.")
        Changed()
    end)
    delBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove this rule", 1, 1, 1)
        GameTooltip:Show()
    end)
    delBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.delBtn = delBtn

    -- Warning (!) between the target and [x]: a prefer rule pointing at a
    -- paladin with a known 0 in the buff's talent (RuleWarningText).
    -- Anchored off [x] so it holds its column while hidden.
    local warn = K.CreateWarningIcon(row)
    warn:SetPoint("RIGHT", delBtn, "LEFT", -4, -2)
    row.warnIcon = warn

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
        row.nameText:SetText(PlayerTextWithRole(p.name, K.ROW_ICON_SIZE))
        local coverage = byPaladin[p.name] or { correct = 0, total = 0 }
        local complete = coverage.total > 0 and coverage.correct == coverage.total
        local hasMissing = coverage.correct < coverage.total
        row.mailBtn:SetEnabled(hasMissing)
        row.mailBtn.icon:SetDesaturated(not hasMissing)
        row.coverageIcon:SetTexture(awaitingTalents and WhoDoesWhat.WARNING_ICON
            or COVERAGE_OK_ICON)
        row.coverageIcon:SetShown(awaitingTalents or complete)
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
    state.ruleDivider:ClearAllPoints()
    state.ruleDivider:SetPoint("TOPLEFT", K.BOX_PAD, -(ruleHeaderTop + 28))
    state.ruleDivider:SetPoint("TOPRIGHT", -K.BOX_PAD, -(ruleHeaderTop + 28))
    state.ruleDivider:SetShown(showRules)

    local rulesTop = ruleHeaderTop + RULE_HEADER_H

    for i, rule in ipairs(rules) do
        local row = state.ruleRows[i] or CreateRuleRow(f, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", K.BOX_PAD, -(rulesTop + (i - 1) * RULE_ROW_H))
        row:SetShown(showRules)
        UIDropDownMenu_SetText(row.buffDD, RuleBuffText(rule))
        UIDropDownMenu_SetText(row.kindDD, RuleKindText(rule))
        row.targetDD:SetShown(rule.kind ~= "ignore")
        UIDropDownMenu_SetText(row.targetDD, RuleTargetText(rule))
        for _, dropdown in ipairs({ row.buffDD, row.kindDD, row.targetDD }) do
            if editable then
                UIDropDownMenu_EnableDropDown(dropdown)
            else
                UIDropDownMenu_DisableDropDown(dropdown)
            end
        end
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
    state.rulesEmptyHint:SetShown(showRules and #rules == 0)
    local rulesH = (#rules > 0) and (#rules * RULE_ROW_H) or K.DYN_EMPTY_H

    state.box:SetHeight(showRules and (rulesTop + rulesH + K.BOX_PAD)
        or (ppRowTop + PALLY_ROW_H + PALLY_STATUS_GAP + rowsH + K.BOX_PAD))
    K.UpdateContentHeight(f)

    -- No-paladin gray-out: dead buttons (with the tooltip saying why) and a
    -- gray title. Developer Mode keeps everything live, same as it
    -- lifts class filters. Runs last so it wins over the states above.
    local enabled = DevMode() or #MembersOfClass("Paladin") > 0
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
                WhoDoesWhat:RefreshBuffingGridView()
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
        WhoDoesWhat:RefreshBuffingGridView()
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

    local ruleBtn = K.AddHeaderTextButton(box, clearRulesBtn, "Add (+)", "Add a buff rule",
        "Add a custom blessing rule: ignore a buff for this fight,"
        .. " prioritize it for part of the raid, or hand it to a specific"
        .. " paladin. One rule per blessing; rules reshape the computed"
        .. " coverage and sync with the assignment board.", function()
            if not WhoDoesWhat:RequireEditPermission() then return end
            local rules = GetBuffRules()
            -- New rules take the first blessing without one; every rule
            -- starts as an inert "Preferred by (choose)" so nothing
            -- changes until it's actually configured.
            local taken = {}
            for _, r in ipairs(rules) do taken[r.buff] = true end
            local buff
            for _, key in ipairs(WhoDoesWhat.CanonicalBuffOrder) do
                if not taken[key] then
                    buff = key
                    break
                end
            end
            if not buff then
                WhoDoesWhat:Print("Paladin Buffs: every blessing already has a rule.")
                return
            end
            rules[#rules + 1] = { buff = buff, kind = "prefer" }
            WhoDoesWhat:RefreshMainAssignmentsView()
            WhoDoesWhat:RefreshBuffingGridView()
        end)

    local hint = K.CreateEmptyHint(box)
    hint:SetText("No paladins in the group.")

    local rulesEmptyHint = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rulesEmptyHint:SetText("No rules exist")
    rulesEmptyHint:SetTextColor(0.55, 0.55, 0.55)

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
        clearRulesBtn = clearRulesBtn,
        rulesEmptyHint = rulesEmptyHint,
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
