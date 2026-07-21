local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Paladin Buffs section. Blessings are never assigned to paladins -- coverage
-- is computed from the roster, roles and talents (ComputeBuffGrid), and this
-- section shows the result: one pooled read-only 24px row per paladin,
--
--   [role icon] Name  [buff icon] (n) > [buff icon] (n)
--
-- up to three buffs each (count-desc), paladins sorted by workload
-- (ComputePaladinBuffSummary). Header: mass-mail (each paladin's computed
-- workload), "Info + Grid" (the paladin info + buff grid window) and
-- "+ Rule".
--
-- Below the summary sit the custom rule rows (the model docs the semantics
-- at CompileBuffRules in Assignments.lua):
--
--   [buff v] [Is Ignored / Prioritized for / Preferred by v] [target v] (!) [x]
--
-- One rule per blessing, six at most (the buff dropdown only offers unruled
-- blessings). Rules are LOCAL strategy config -- not part of the synced
-- board, so they aren't permission-gated; everyone tunes their own view.
--
-- The whole section grays out while the group has no paladins (Developer
-- Mode keeps it live, same as it lifts class filters).

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit

local DevMode = A.DevMode
local MembersOfClass = A.MembersOfClass
local PlayerText = A.PlayerText
local PlayerTextWithRole = A.PlayerTextWithRole
local ComputePaladinBuffSummary = A.ComputePaladinBuffSummary
local GetBuffRules = A.GetBuffRules
local BuffTalents = A.BuffTalents

local PALLY_ROW_H = 24
local PALLY_MAX_BUFFS = 3
-- Buff summary is laid out as a grid: the name in a fixed-width column, then
-- one fixed-width slot per buff so the icons line up in columns down the rows.
local PALLY_SLOT_W = 48   -- per-buff column: icon + count
local PALLY_BUFF_ICON = 20
local RULE_ROW_H = 30
local RULE_BUFF_DD_W = 78
local RULE_KIND_DD_W = 90
local RULE_TARGET_DD_W = 76
local FOOTER_BTN_H = 22
local FOOTER_TOP_GAP = 8 -- gap above the footer button row

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
        return rule.value and PlayerText(rule.value) or "|cff909090Choose...|r"
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

    local function Entry() return GetBuffRules()[index] end
    local function Changed()
        -- Route through the main refresh (not the section-local Refresh) so
        -- ApplyViewMode refits the window height -- adding/removing a rule
        -- grows/shrinks the box, and the collapsed view must follow.
        WhoDoesWhat:RefreshMainAssignmentsView()
        WhoDoesWhat:RefreshPaladinBuffGridView()
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
                info.text = PlayerTextWithRole(name) .. (note and (" " .. note) or "")
                info.checked = (rule.value == name)
                info.func = function()
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
            rule.scope, rule.value = "everyone", nil
            Changed()
        end
        UIDropDownMenu_AddButton(info, level)
        for _, wr in ipairs({ "tank", "healer", "dps" }) do
            local wrInfo = UIDropDownMenu_CreateInfo()
            wrInfo.text = WOW_ROLE_LABELS[wr]
            wrInfo.checked = (rule.scope == "wowrole" and rule.value == wr)
            wrInfo.func = function()
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

    local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    delBtn:SetSize(K.MAIL_BTN_SIZE, K.MAIL_BTN_SIZE)
    delBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    delBtn:SetText("x")
    delBtn:SetScript("OnClick", function()
        table.remove(GetBuffRules(), index)
        WhoDoesWhat:Print("Paladin Buffs: rule removed.")
        Changed()
    end)
    delBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove this rule", 1, 1, 1)
        GameTooltip:Show()
    end)
    delBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Warning (!) between the target and [x]: a prefer rule pointing at a
    -- paladin with a known 0 in the buff's talent (RuleWarningText).
    -- Anchored off [x] so it holds its column while hidden.
    local warn = K.CreateWarningIcon(row)
    warn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
    row.warnIcon = warn

    state.ruleRows[index] = row
    return row
end

-- ---------------------------------------------------------------------------
-- Summary rows: name column + one grid slot per buff (icon + count + tooltip)
-- ---------------------------------------------------------------------------

local function PallyBuffSlotEnter(self)
    if not self.buffKey then return end
    local buff = WhoDoesWhat.PaladinBuffs[self.buffKey]
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(buff.name_long, 1, 1, 1)
    GameTooltip:AddLine("Casting on " .. self.buffCount
        .. (self.buffCount == 1 and " raider" or " raiders"), 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

-- Pooled summary row #index: fixed name column on the left, then PALLY_MAX_BUFFS
-- fixed-width slots so the buff icons line up in columns across every row. Each
-- slot is a mouse-enabled frame (icon + count) that tooltips the blessing.
local function CreatePallyRow(state, index)
    local row = CreateFrame("Frame", nil, state.box)
    row:SetFrameLevel(state.box:GetFrameLevel() + 1)
    row:SetSize(state.box:GetWidth() - K.BOX_PAD * 2, PALLY_ROW_H)
    row:SetPoint("TOPLEFT", K.BOX_PAD, -(K.BOX_PAD + K.SECTION_TITLE_H + (index - 1) * PALLY_ROW_H))
    if index > 1 then
        K.AddRowDivider(row, 2, 0)
    end

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("LEFT", 4, 0)
    name:SetWidth(K.NAME_LABEL_W)
    name:SetJustifyH("LEFT")
    row.nameText = name

    row.slots = {}
    for i = 1, PALLY_MAX_BUFFS do
        local slot = CreateFrame("Frame", nil, row)
        slot:SetSize(PALLY_SLOT_W, PALLY_ROW_H)
        slot:SetPoint("LEFT", 4 + K.NAME_LABEL_W + (i - 1) * PALLY_SLOT_W, 0)
        local icon = slot:CreateTexture(nil, "OVERLAY")
        icon:SetSize(PALLY_BUFF_ICON, PALLY_BUFF_ICON)
        icon:SetPoint("LEFT", 0, 0)
        slot.icon = icon
        local count = slot:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        count:SetPoint("LEFT", icon, "RIGHT", 3, 0)
        slot.count = count
        slot:EnableMouse(true)
        slot:SetScript("OnEnter", PallyBuffSlotEnter)
        slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        slot:Hide()
        row.slots[i] = slot
    end
    return row
end

-- ---------------------------------------------------------------------------
-- Refresh: summary rows, rule rows, box height, no-paladin gray-out
-- ---------------------------------------------------------------------------

function Refresh(f) -- forward declared above
    local state = f.pallySection
    local summary = ComputePaladinBuffSummary()

    for i, p in ipairs(summary) do
        local row = state.rows[i] or CreatePallyRow(state, i)
        state.rows[i] = row
        row:Show()
        row.nameText:SetText(PlayerTextWithRole(p.name, 16))
        for bi, slot in ipairs(row.slots) do
            local b = p.buffs[bi]
            if b then
                slot.icon:SetTexture(WhoDoesWhat.PaladinBuffs[b.key].iconId)
                slot.count:SetText(b.count)
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
    end

    state.emptyHint:SetShown(#summary == 0)
    local rowsH = (#summary > 0) and (#summary * PALLY_ROW_H) or K.DYN_EMPTY_H

    -- The rules area below the summary: a hairline, then one editable row
    -- per rule. The rows are re-anchored every pass -- their y depends on
    -- how many summary rows sit above them.
    local rules = GetBuffRules()
    local rulesTop = K.BOX_PAD + K.SECTION_TITLE_H + rowsH
    if #rules > 0 then
        if not state.ruleDivider then
            state.ruleDivider = K.AddRowDivider(state.box, K.BOX_PAD + 2, 0)
        end
        state.ruleDivider:ClearAllPoints()
        state.ruleDivider:SetPoint("TOPLEFT", K.BOX_PAD + 2, -(rulesTop + 2))
        state.ruleDivider:SetPoint("TOPRIGHT", -(K.BOX_PAD + 2), -(rulesTop + 2))
        state.ruleDivider:Show()
        rulesTop = rulesTop + 5
    elseif state.ruleDivider then
        state.ruleDivider:Hide()
    end

    for i, rule in ipairs(rules) do
        local row = state.ruleRows[i] or CreateRuleRow(f, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", K.BOX_PAD, -(rulesTop + (i - 1) * RULE_ROW_H))
        row:Show()
        UIDropDownMenu_SetText(row.buffDD, RuleBuffText(rule))
        UIDropDownMenu_SetText(row.kindDD, RuleKindText(rule))
        row.targetDD:SetShown(rule.kind ~= "ignore")
        UIDropDownMenu_SetText(row.targetDD, RuleTargetText(rule))
        local warning = RuleWarningText(rule)
        row.warnIcon.tooltipText = warning
        row.warnIcon:SetShown(warning ~= nil)
    end
    for i = #rules + 1, #state.ruleRows do
        state.ruleRows[i]:Hide()
    end

    -- One footer row below the rules: "Info + Grid" left-aligned, then the
    -- right-aligned "Pally Power: [Sync] [Log]" cluster. Re-anchored every
    -- pass (y depends on how many rule rows sit above); each button sizes to
    -- its own label (set in Build).
    local y = rulesTop + #rules * RULE_ROW_H + FOOTER_TOP_GAP
    state.gridBtn:ClearAllPoints()
    state.gridBtn:SetPoint("TOPLEFT", K.BOX_PAD, -y)
    state.ppLogBtn:ClearAllPoints()
    state.ppLogBtn:SetPoint("TOPRIGHT", state.box, "TOPRIGHT", -K.BOX_PAD, -y)
    state.ppSyncBtn:ClearAllPoints()
    state.ppSyncBtn:SetPoint("RIGHT", state.ppLogBtn, "LEFT", -4, 0)
    state.ppLabel:ClearAllPoints()
    state.ppLabel:SetPoint("RIGHT", state.ppSyncBtn, "LEFT", -6, 0)

    state.box:SetHeight(y + FOOTER_BTN_H + K.BOX_PAD)
    K.UpdateContentHeight(f)

    -- No-paladin gray-out: dead buttons (with the tooltip saying why), gray
    -- title, dead mail. Developer Mode keeps everything live, same as it
    -- lifts class filters. Runs last so it wins over the states above.
    local enabled = DevMode() or #MembersOfClass("Paladin") > 0
    local reason = not enabled and "No paladins in the group." or nil
    if enabled then
        state.box.title:SetTextColor(1, 0.82, 0) -- GameFontNormal gold
    else
        state.box.title:SetTextColor(0.5, 0.5, 0.5)
        state.mailBtn:SetEnabled(false)
        state.mailBtn.icon:SetDesaturated(true)
    end
    for _, btn in ipairs(state.buttons) do
        btn:SetEnabled(enabled)
        btn.disabledReason = reason
    end

    K.LayoutHeaderChain(state.headerChain)
end

-- Full-width action button at the foot of the box. Position + width are set
-- in Refresh (they sit below the rule rows); tipWarn is an optional red line.
local function CreateFooterButton(box, text, tipTitle, tipBody, tipWarn, onClick)
    local btn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    btn:SetFrameLevel(box:GetFrameLevel() + 1)
    btn:SetHeight(FOOTER_BTN_H)
    btn:SetText(text)
    btn:SetWidth(math.max(44, btn:GetTextWidth() + 20))
    btn:SetScript("OnClick", onClick)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tipTitle, 1, 1, 1)
        GameTooltip:AddLine(tipBody, 0.8, 0.8, 0.8, true)
        if tipWarn then GameTooltip:AddLine(tipWarn, 1, 0.5, 0.4, true) end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

local function Build(f, content)
    local chrome = K.CreateSectionChrome(f, content, {
        title = "Paladin Buffs",
        column = K.COL_LEFT,
        mailCollect = A.CollectPaladinBuffWhispers,
    })
    local box = chrome.box

    -- "Info + Grid" lives on the footer row (positioned in Refresh), not the
    -- header chain -- but it still grays out with the section (state.buttons).
    local gridBtn = K.AddHeaderTextButton(box, chrome.mailBtn, "Info + Grid", "Paladin Info + Grid",
        "Open the paladin window: every paladin's buff-talent ranks on"
        .. " the left, and the buff grid -- every raider against every"
        .. " paladin, with the blessing each paladin gives them -- on"
        .. " the right.", function()
            WhoDoesWhat:OpenPaladinBuffGridView()
        end)

    local ruleBtn = K.AddHeaderTextButton(box, chrome.mailBtn, "+ Rule", "Add a buff rule",
        "Add a custom blessing rule: ignore a buff for this fight,"
        .. " prioritize it for part of the raid, or hand it to a specific"
        .. " paladin. One rule per blessing; rules reshape the computed"
        .. " coverage and are saved locally (not synced).", function()
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
            WhoDoesWhat:RefreshPaladinBuffGridView()
        end)
    K.ChainHeaderButton(chrome, ruleBtn)

    local hint = K.CreateEmptyHint(box)
    hint:SetText("No paladins in the group.")

    -- Two full-width buttons at the foot of the box (mirrors the Paladin Info
    -- + Grid window's title-bar actions). Refresh lays them out below the
    -- rules and grows the box to fit.
    local ppLabel = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ppLabel:SetText("Pally Power:")

    local ppSyncBtn = CreateFooterButton(box, "Sync",
        "Sync to PallyPower",
        "Write this computed grid into PallyPower (each paladin's per-class"
        .. " blessings; per-raider differences become Normal blessing"
        .. " exceptions) and broadcast it to the other paladins over"
        .. " PallyPower's own sync.",
        "Other clients only accept the push from a raid lead/assist, or when"
        .. " they run Free Assignment.",
        function() WhoDoesWhat:SyncToPallyPower() end)

    local ppLogBtn = CreateFooterButton(box, "Log",
        "PallyPower log",
        "Open a live feed of PallyPower's hidden addon-channel sync messages,"
        .. " translated to plain lines -- what every paladin is assigning and"
        .. " reporting.", nil,
        function() WhoDoesWhat:OpenPallyPowerLogView() end)

    f.pallySection = {
        box = box,
        headerChain = chrome.headerChain,
        mailBtn = chrome.mailBtn,
        buttons = { gridBtn, ruleBtn }, -- the no-paladin gray-out pass
        emptyHint = hint,
        gridBtn = gridBtn,
        ppLabel = ppLabel,
        ppSyncBtn = ppSyncBtn,
        ppLogBtn = ppLogBtn,
        rows = {},
        ruleRows = {},
    }
end

WhoDoesWhat.SectionViews.PaladinBuffs = { Build = Build, Refresh = Refresh }
