local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Warlock Curses section: one fixed row per curse (Recklessness, Elements),
-- rendered as
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
local PlayerText = A.PlayerText
local PlayerTextWithRole = A.PlayerTextWithRole

-- Our static-section def (title + row definitions), found by title so a
-- reordering of A.Sections can't silently swap our rows.
local SECTION
for _, s in ipairs(A.Sections) do
    if s.title == "Warlock Curses" then SECTION = s end
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

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(K.ROW_ICON_SIZE, K.ROW_ICON_SIZE)
    icon:SetPoint("LEFT", 4, 0)
    icon:SetTexture(def.icon)

    -- Small font: the longest ability names ("Curse of Recklessness") have to
    -- share the row with a dropdown, and the short ones read fine either way.
    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    label:SetText(def.label)

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
        def = def, dropdown = dropdown, warnIcon = warn, mailBtn = mailBtn,
        roText = roText,
    }
    return y + K.ROW_H
end

local function Refresh(f)
    local state = f.curseSection
    local editable = WhoDoesWhat:CanEditAssignments()

    for _, row in ipairs(state.rows) do
        local assigned = GetAssignment(row.def.id)
        UIDropDownMenu_SetText(row.dropdown, PlayerTextWithRole(assigned))
        row.dropdown:SetShown(editable)
        row.roText:SetText(PlayerText(assigned))
        row.roText:SetShown(not editable)
        local warning = row.def.GetWarning and row.def.GetWarning() or nil
        -- An unassigned row's warning is a to-do, and a viewer can't do it;
        -- only warnings about someone actually assigned matter read-only.
        if not editable and not assigned then
            warning = nil
        end
        row.warnIcon.tooltipText = warning
        row.warnIcon:SetShown(warning ~= nil)
        row.mailBtn:SetShown(editable)
        row.mailBtn:SetEnabled(assigned ~= nil)
        row.mailBtn.icon:SetDesaturated(assigned == nil)
    end

    -- Auto rewrites the whole section, so it's an edit control: greyed out
    -- (not hidden -- the affordance stays discoverable) without permission,
    -- with the tooltip explaining. Calc only opens a read-only window and
    -- stays live for everyone.
    state.autoBtn:SetEnabled(editable)
    state.autoBtn.disabledReason = not editable
        and ("Requires editing permission - the raid leader has editing set to "
            .. WhoDoesWhat:PermissionModeLabel() .. ".")
        or nil

    K.LayoutHeaderChain(state.headerChain)
end

local function Build(f, content)
    local chrome = K.CreateSectionChrome(f, content, {
        title = SECTION.title,
        column = K.COL_LEFT,
        mailCollect = A.CollectCurseWhispers,
    })
    local box = chrome.box

    local autoBtn = K.AddHeaderTextButton(box, chrome.mailBtn, "Auto", "Auto-assign",
        "Put Curse of the Elements on an Affliction warlock and Curse of"
        .. " Recklessness on another warlock. Each curse is gated by its"
        .. " Settings toggle; a disabled one keeps its current pick.",
        function()
            A.AutoAssignWarlockCurses()
            WhoDoesWhat:RefreshMainAssignmentsView()
            -- The info + grid window mirrors the paladin-buff picks; keep it live.
            WhoDoesWhat:RefreshPaladinBuffGridView()
        end)
    K.ChainHeaderButton(chrome, autoBtn)

    local calcBtn = K.AddHeaderTextButton(box, autoBtn, "Calc", "Curse Value Calculator",
        "Estimate how much raid damage Curse of the Elements and Curse of"
        .. " Recklessness provided (or could have provided), pulling the"
        .. " fight data from Details!.", function()
            WhoDoesWhat:OpenCurseCalculatorView()
        end)
    K.ChainHeaderButton(chrome, calcBtn)

    f.curseSection = {
        box = box,
        headerChain = chrome.headerChain,
        autoBtn = autoBtn,
        rows = {},
    }

    local innerY = K.BOX_PAD + K.SECTION_TITLE_H
    for i, def in ipairs(SECTION.rows) do
        if i > 1 then
            K.AddRowDivider(box, K.BOX_PAD + 2, innerY)
        end
        innerY = AddAssignmentRow(f, box, innerY, def)
    end
    box:SetHeight(innerY + K.BOX_PAD)
end

WhoDoesWhat.SectionViews.WarlockCurses = { Build = Build, Refresh = Refresh }
