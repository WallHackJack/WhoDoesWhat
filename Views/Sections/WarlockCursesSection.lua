local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Warlocks section: three compact Improved Healthstone header icons followed
-- by one fixed row per curse, rendered as
--
--   [spell icon] Name    (!)  [player dropdown v] [mail]
--
-- The row definitions (exclusivity, preferred roles, warnings) live in
-- Assignments.lua (RowDefs / Sections); assignment writes go through
-- SetAssignment, which enforces exclusiveWith and repaints. Header buttons:
-- mass-mail, Auto (fill both curses from the group's warlocks, gated by the
-- Settings toggles) and Calc (the Details!-backed Curse Value Calculator).

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit

local GetAssignment = A.GetAssignment
local SetAssignment = A.SetAssignment
local MembersOfClass = A.MembersOfClass
local PlayerText = A.PlayerText
local PlayerTextWithRole = A.PlayerTextWithRole
local RoleIconMarkup = A.RoleIconMarkup
local HEALTHSTONE = WhoDoesWhat.WarlockHealthstone
local HEALTHSTONE_RANKS = { 2, 1, 0 }
local IS_CLASSIC_ERA = WhoDoesWhat.ClientFeatures.isClassicEra

-- Our static-section def (title + row definitions), found by title so a
-- reordering of A.Sections can't silently swap our rows.
local SECTION
for _, s in ipairs(A.Sections) do
    if s.title == "Warlocks" then SECTION = s end
end

local function CollectWarlockWhispers()
    if #MembersOfClass("Warlock") == 0 then return {} end
    return A.CollectCurseWhispers()
end

local function HealthstoneSlotEnter(self)
    local state = self.state
    local rank = self.rank
    local confirmedNames = self.confirmedNames or {}
    local unknownNames = state.healthstoneUnknownNames or {}

    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("(" .. rank .. "/" .. HEALTHSTONE.maxRank .. ") "
        .. HEALTHSTONE.name, 1, 1, 1)
    GameTooltip:AddLine("Restores " .. HEALTHSTONE.lifeByTalentRank[rank] .. " life.",
        0.6, 0.6, 0.6, true)
    if state.healthstoneTotal == 0 then
        GameTooltip:AddLine("No warlocks in the group.", 0.6, 0.6, 0.6, true)
    elseif #confirmedNames > 0 then
        for _, name in ipairs(confirmedNames) do
            local roleIcon = RoleIconMarkup(name, 16)
            GameTooltip:AddLine(roleIcon .. (roleIcon ~= "" and " " or "")
                .. "|cff40ff40" .. name .. "|r", 1, 1, 1)
        end
    elseif #unknownNames == 0 then
        GameTooltip:AddLine("No warlocks have this talent", 1, 0.35, 0.35, true)
    end
    if #unknownNames > 0 then
        GameTooltip:AddLine("Unscanned: " .. table.concat(unknownNames, ", "),
            0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

local function AddHealthstoneHeaderIcons(f, chrome)
    local slots = {}
    for i = #HEALTHSTONE_RANKS, 1, -1 do
        local rank = HEALTHSTONE_RANKS[i]
        local slot = CreateFrame("Frame", nil, chrome.box)
        slot:SetFrameLevel(chrome.box:GetFrameLevel() + 1)
        slot:SetSize(K.MAIL_BTN_SIZE, K.MAIL_BTN_SIZE)
        slot:EnableMouse(true)
        slot:SetScript("OnEnter", HealthstoneSlotEnter)
        slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        slot.rank = rank
        slot.state = f.curseSection

        local icon = slot:CreateTexture(nil, "ARTWORK")
        icon:SetSize(K.ROW_ICON_SIZE, K.ROW_ICON_SIZE)
        icon:SetPoint("CENTER")
        icon:SetTexture(HEALTHSTONE.icon)
        slot.icon = icon
        slots[rank] = slot
        K.ChainHeaderButton(chrome, slot)
    end

    f.curseSection.healthstoneSlots = slots
end

-- One static assignment row inside the box: spell icon + name on the left
-- (hovering the icon shows the ability's game tooltip), then the warning
-- icon, the player dropdown, and the mail button. Returns the y offset below.
local function AddAssignmentRow(f, box, y, def)
    local state = f.curseSection
    local row = CreateFrame("Frame", nil, box)
    row:SetFrameLevel(box:GetFrameLevel() + 1)
    row:SetSize(box:GetWidth() - K.BOX_PAD * 2, K.ROW_H)
    row:SetPoint("TOPLEFT", K.BOX_PAD, -y)
    K.AddRowBackground(row, #state.rows + 1)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(K.ROW_ICON_SIZE, K.ROW_ICON_SIZE)
    icon:SetPoint("LEFT", 4, 0)
    icon:SetTexture(def.icon)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    local shortLabel = def.label:gsub("^Curse of the ", "")
    label:SetText(shortLabel:gsub("^Curse of ", ""))

    -- Ability tooltip when hovering the spell icon only (textures can't take
    -- mouse events, so a small invisible frame sits over it). Anchored with
    -- the tooltip's bottom-left just above the icon.
    local iconHover = CreateFrame("Frame", nil, row)
    iconHover:SetAllPoints(icon)
    iconHover:EnableMouse(true)
    iconHover:SetScript("OnEnter", function(self)
        if def.spellId then
            GameTooltip:SetOwner(self, "ANCHOR_NONE")
            GameTooltip:SetPoint("BOTTOMLEFT", icon, "TOPLEFT", 0, 6)
            GameTooltip:SetHyperlink("spell:" .. def.spellId)
            GameTooltip:Show()
        end
    end)
    iconHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local mailBtn = K.CreateMailButton(row, function()
        local name = GetAssignment(def.id)
        if name then
            return name, def.label .. " (" .. SECTION.title .. ")"
        end
    end)
    mailBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    -- UIDropDownMenu carries ~15px of transparent padding each side; overhang
    -- toward the mail button so the visible box sits a few px left of it.
    local dropdown = CreateFrame("Frame", "WhoDoesWhatAssignDropDown_" .. def.id, row, "UIDropDownMenuTemplate")
    dropdown:SetPoint("RIGHT", mailBtn, "LEFT", 12, -2)
    UIDropDownMenu_SetWidth(dropdown, K.DROPDOWN_WIDTH)
    K.LeftAlignDropdown(dropdown)
    -- The initialize function re-runs every time the menu opens, so the
    -- member list is always fresh.
    UIDropDownMenu_Initialize(dropdown, function(_, level)
        local IsPreferred = def.IsPreferred
            or (def.preferRoleId and function(m)
                return WhoDoesWhat:GetAssignedRole(m.name) == def.preferRoleId
            end)
            or nil
        K.AddPlayerMenuItems(level, def.class, IsPreferred, GetAssignment(def.id),
            function(name) SetAssignment(def.id, name) end, def.Annotate)
    end)

    local warn = K.CreateWarningIcon(row)
    warn:SetPoint("RIGHT", dropdown, "LEFT", 12, 2)

    -- Read-only stand-in for the dropdown: the assigned name as plain text
    -- (class colors survive, unlike a disabled dropdown's gray-out). Runs to
    -- the row edge -- the mail button is hidden whenever this shows.
    local roText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    roText:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    roText:SetJustifyH("RIGHT")
    roText:Hide()

    state.rows[#state.rows + 1] = {
        frame = row, def = def, dropdown = dropdown, warnIcon = warn, mailBtn = mailBtn,
        roText = roText, icon = icon, label = label,
    }
    return y + K.ROW_H
end

local function Refresh(f)
    local state = f.curseSection
    local editable = WhoDoesWhat:CanEditAssignments()
    local warlocks = MembersOfClass("Warlock")
    local enabled = #warlocks > 0

    local counts = { [0] = 0, [1] = 0, [2] = 0 }
    local names = { [0] = {}, [1] = {}, [2] = {} }
    local unknownNames = {}
    for _, name in ipairs(warlocks) do
        local rank = WhoDoesWhat:GetWarlockHealthstoneTalent(name)
        if rank == nil then
            unknownNames[#unknownNames + 1] = name
        else
            rank = math.floor(math.max(0,
                math.min(HEALTHSTONE.maxRank, tonumber(rank) or 0)))
            counts[rank] = counts[rank] + 1
            names[rank][#names[rank] + 1] = name
        end
    end
    state.healthstoneTotal = #warlocks
    state.healthstoneUnknownNames = unknownNames
    for _, rank in ipairs(HEALTHSTONE_RANKS) do
        local slot = state.healthstoneSlots[rank]
        local count = counts[rank]
        slot.confirmedNames = names[rank]
        slot.icon:SetDesaturated(count == 0)
    end

    local assignedCount = 0
    for _, row in ipairs(state.rows) do
        local assigned = GetAssignment(row.def.id)
        if assigned then assignedCount = assignedCount + 1 end
        UIDropDownMenu_SetText(row.dropdown,
            PlayerTextWithRole(assigned, K.DROPDOWN_ICON_SIZE))
        row.dropdown:SetShown(editable)
        if enabled then
            UIDropDownMenu_EnableDropDown(row.dropdown)
        else
            UIDropDownMenu_DisableDropDown(row.dropdown)
        end
        row.roText:SetText(PlayerText(assigned))
        row.roText:SetShown(not editable)
        row.icon:SetDesaturated(not enabled)
        row.label:SetTextColor(enabled and 1 or 0.5, enabled and 1 or 0.5,
            enabled and 1 or 0.5)
        local warning = enabled and row.def.GetWarning and row.def.GetWarning() or nil
        -- An unassigned row's warning is a to-do, and a viewer can't do it;
        -- only warnings about someone actually assigned matter read-only.
        if not editable and not assigned then
            warning = nil
        end
        row.warnIcon.tooltipText = warning
        row.warnIcon:SetShown(warning ~= nil)
        row.mailBtn:SetShown(editable)
        row.mailBtn:SetEnabled(enabled and assigned ~= nil)
        row.mailBtn.icon:SetDesaturated(not enabled or assigned == nil)
    end

    local showEmpty = not editable and assignedCount == 0
    for _, row in ipairs(state.rows) do row.frame:SetShown(not showEmpty) end
    state.emptyHint:SetShown(showEmpty)
    state.box:SetHeight(showEmpty
        and (K.BOX_PAD + K.SECTION_TITLE_H + K.DYN_EMPTY_H + K.BOX_PAD)
        or state.fullHeight)
    K.UpdateContentHeight(f)

    -- Auto rewrites the whole section, so hide it without edit permission.
    -- Calc only opens a read-only window and stays live for everyone.
    state.autoBtn:SetShown(editable)
    state.box.title:SetTextColor(enabled and 0.95 or 0.5,
        enabled and 0.95 or 0.5, enabled and 0.95 or 0.5)
    for _, btn in ipairs(state.buttons) do
        btn:SetEnabled(enabled)
        btn.disabledReason = not enabled and "No warlocks in the group."
            or nil
    end

    K.LayoutHeaderChain(state.headerChain)
end

local function Build(f, content)
    local chrome = K.CreateSectionChrome(f, content, {
        title = SECTION.title,
        column = K.COL_LEFT,
        tintClass = "Warlock",
        mailCollect = CollectWarlockWhispers,
    })
    local box = chrome.box

    local autoTooltip = IS_CLASSIC_ERA
        and "Put Curse of the Elements, Curse of Shadow, and Curse of Recklessness"
            .. " on separate warlocks. The magic curses and Recklessness are gated"
            .. " by their Settings toggles."
        or "Put Curse of the Elements on an Affliction warlock and Curse of"
            .. " Recklessness on another warlock. Each curse is gated by its"
            .. " Settings toggle; a disabled one keeps its current pick."
    local autoBtn = K.AddHeaderTextButton(box, chrome.mailBtn, "Auto", "Auto-assign",
        autoTooltip,
        function()
            A.AutoAssignWarlockCurses()
            WhoDoesWhat:RefreshMainAssignmentsView()
            -- The buff grid mirrors the paladin-buff picks; keep it live.
            WhoDoesWhat:RefreshBuffingGridView()
        end)
    K.ChainHeaderButton(chrome, autoBtn)

    local calculatorCurses = IS_CLASSIC_ERA
        and "Curse of the Elements, Curse of Shadow, and Curse of Recklessness"
        or "Curse of the Elements and Curse of Recklessness"
    local calcBtn = K.AddHeaderTextButton(box, autoBtn, "Calc", "Curse Value Calculator",
        "Estimate how much raid damage " .. calculatorCurses
        .. " provided (or could have provided), pulling the fight data from Details!.", function()
            WhoDoesWhat:OpenCurseCalculatorView()
        end)
    K.ChainHeaderButton(chrome, calcBtn)

    f.curseSection = {
        box = box,
        headerChain = chrome.headerChain,
        mailBtn = chrome.mailBtn,
        autoBtn = autoBtn,
        buttons = { autoBtn, calcBtn },
        emptyHint = K.CreateEmptyHint(box),
        rows = {},
    }
    f.curseSection.emptyHint:SetText("No Warlock assignments yet.")
    f.curseSection.emptyHint:Hide()
    AddHealthstoneHeaderIcons(f, chrome)

    local innerY = K.BOX_PAD + K.SECTION_TITLE_H
    for _, def in ipairs(SECTION.rows) do
        innerY = AddAssignmentRow(f, box, innerY, def)
    end
    box:SetHeight(innerY + K.BOX_PAD)
    f.curseSection.fullHeight = innerY + K.BOX_PAD
end

WhoDoesWhat.SectionViews.WarlockCurses = { Build = Build, Refresh = Refresh }
