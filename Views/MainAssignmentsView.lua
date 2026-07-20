local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Main /wdw window: two scrollable columns of boxed assignment sections. The
-- dynamic, user-grown sections live on the left (they're wide and busy); the
-- fixed per-ability sections live on the right. Boxes are anchor-chained
-- within their column, so a section that changes height pushes the ones under
-- it down on its own.
--
-- This file is UI only: widget builders, layout, and the refresh passes.
-- The model -- section/row definitions and their field docs, member and text
-- helpers, whisper collectors, demand math, auto-assigns, and assignment
-- storage -- lives in Assignments.lua and is re-localized below.
--
-- Two kinds of sections:
--
-- 1. Dynamic (`DynamicSections`): pooled rows the user adds with the title
--    strip's "Add (+)" button and removes with each row's [x]. Rendered as
--
--      [player v] ([spell v]) -> [marker v] [custom text] (!) [x] [mail]
--
-- 2. Static (`Sections`): one fixed row per ability, rendered as
--
--      [spell icon] Name    (!)  [player dropdown v] [mail]
--
--    Except the Paladin Buffs section (`paladinSummary`): blessings aren't
--    assigned to paladins anymore -- coverage is computed (Assignments.lua),
--    and the section shows one pooled read-only row per paladin:
--
--      [role icon] Name  [buff icon] (n) > [buff icon] (n)

local mainFrame = nil

local FRAME_W = 940
local FRAME_H = 560
local MARGIN = 12
local SCROLLBAR_W = 26
local CONTENT_W = FRAME_W - MARGIN * 2 - SCROLLBAR_W

-- Column geometry. The columns are deliberately uneven: the left one carries
-- the dynamic rows (two dropdowns, an arrow, a text field and three buttons),
-- while the right one only needs an icon, a name and one dropdown.
local COL_LEFT, COL_RIGHT = 1, 2
local COLUMN_GAP = 12
local LEFT_COLUMN_W = 500
local RIGHT_COLUMN_W = CONTENT_W - COLUMN_GAP - LEFT_COLUMN_W

local BUTTON_ROW_H = 22
local SECTION_GAP = 10 -- vertical gap between section boxes
local SECTION_TITLE_H = 22 -- box interior reserved for the title + divider
local BOX_PAD = 8 -- section box inner margin
local ROW_H = 32
local ROW_ICON_SIZE = 22
local DROPDOWN_WIDTH = 100 -- player picker; sized for a name, not a sentence
local WARNING_ICON_SIZE = 18
local MAIL_BTN_SIZE = 22
-- How far the header button strip's top sits below the box top. The section
-- title centers on this strip too (see the shared box builder), so both move
-- together -- tweak here to nudge the whole header row up/down.
local HEADER_STRIP_TOP = 3

local DYN_PLAYER_DD_WIDTH = 100
local DYN_SPELL_DD_WIDTH = 110

-- Marker dropdown widths. UIDropDownMenuTemplate anchors its label 7px in
-- from the left and 43px in from the right (the gap houses the arrow button),
-- so ~69px of frame is the floor for showing a 14px icon -- there's no way to
-- get thinner without abandoning the dropdown chrome. The icon-only states
-- sit on that floor; "Everything else" is the one option with no icon to
-- stand in for it, so its box widens to fit the words.
local TANK_MARKER_DD_WIDTH = 44
local TANK_MARKER_DD_WIDE = 95
local DYN_EMPTY_H = 20 -- rows-area height while a dynamic list is empty

-- UIDropDownMenuTemplate right-aligns its collapsed label by default, which
-- leaves player/spell names (and the marker icon) floating against the arrow
-- with dead space on the left. Left-align so the content hugs the left edge,
-- and nudge it down 1px -- the template sits the label a hair high in the box.
local function LeftAlignDropdown(dd)
    local text = _G[dd:GetName() .. "Text"]
    if text then
        text:SetJustifyH("LEFT")
        text:AdjustPointsOffset(0, -1)
    end
end

local WARNING_ICON = WhoDoesWhat.WARNING_ICON
local MAIL_ICON = "Interface\\Icons\\INV_Letter_15"
local CUSTOM_TARGET_ICON = 134400 -- INV_Misc_QuestionMark, our "custom" marker

-- The assignment model lives in Assignments.lua (helpers, section
-- definitions, whisper collectors, demand math, auto-assigns, storage);
-- re-localize the pieces the widgets below use so their code reads the same
-- as when it all lived in this file.
local A = WhoDoesWhat.Assign
local DevMode = A.DevMode
local GetEligibleMembers = A.GetEligibleMembers
local FindMember = A.FindMember
local MembersOfClass = A.MembersOfClass
local PlayerText = A.PlayerText
local PlayerTextWithRole = A.PlayerTextWithRole
local RoleIconMarkup = A.RoleIconMarkup
local GetAssignment = A.GetAssignment
local MarkerMarkup = A.MarkerMarkup
local TargetText = A.TargetText
local TargetPlainText = A.TargetPlainText
local TargetChatText = A.TargetChatText
local SpellText = A.SpellText
local SpellById = A.SpellById
local SpellsForEntry = A.SpellsForEntry
local ClearSpellIfUncastable = A.ClearSpellIfUncastable
local DynamicSections = A.DynamicSections
local Sections = A.Sections
local GetEntries = A.GetEntries
local EnsureAutoRows = A.EnsureAutoRows
local EntryText = A.EntryText
local PlayerEntriesText = A.PlayerEntriesText
local FirstUnusedMarker = A.FirstUnusedMarker
local CollectDynamicWhispers = A.CollectDynamicWhispers
local CollectStaticWhispers = A.CollectStaticWhispers
local CollectPaladinBuffWhispers = A.CollectPaladinBuffWhispers
local MassWhisper = A.MassWhisper
local ComputePaladinBuffSummary = A.ComputePaladinBuffSummary
local GetBuffRules = A.GetBuffRules
local BuffTalents = A.BuffTalents
local PruneDepartedAssignments = A.PruneDepartedAssignments
local SetAssignment = A.SetAssignment

-- The mass-mail button itself, in a section box's title strip. Yourself is
-- filtered out of the collection (not just the send): whispering yourself is
-- noise, and this way the tooltip, the enabled state and the sent count all
-- tell the same story. Registered on f.headerMail so refreshes keep the
-- enabled state honest.
local function AddHeaderMailButton(f, box, sectionTitle, Collect)
    local function CollectOthers()
        local out = {}
        local me = UnitName("player")
        for _, w in ipairs(Collect()) do
            if w.name ~= me then
                out[#out + 1] = w
            end
        end
        return out
    end

    local btn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    btn:SetFrameLevel(box:GetFrameLevel() + 1)
    -- Same size as the rows' buttons, so the header's mail/X land in the
    -- same columns as the rows' mail/x below them.
    btn:SetSize(MAIL_BTN_SIZE, MAIL_BTN_SIZE)
    btn:SetPoint("TOPRIGHT", -BOX_PAD, -HEADER_STRIP_TOP)
    btn:SetText("")
    btn:SetMotionScriptsWhileDisabled(true) -- tooltip works while disabled
    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(MAIL_ICON)
    btn.icon = icon

    btn:SetScript("OnClick", function()
        local sent = MassWhisper(CollectOthers())
        if sent > 0 then
            WhoDoesWhat:Print(sectionTitle .. ": whispered " .. sent
                .. (sent == 1 and " player" or " players") .. " their assignments.")
        else
            WhoDoesWhat:Print(sectionTitle .. ": no one assigned to whisper.")
        end
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local list = CollectOthers()
        if #list > 0 then
            local names = {}
            for _, w in ipairs(list) do
                names[#names + 1] = PlayerText(w.name)
            end
            GameTooltip:SetText("Whisper everyone their assignment", 1, 1, 1)
            GameTooltip:AddLine(table.concat(names, ", "), 0.8, 0.8, 0.8, true)
        else
            GameTooltip:SetText("No one assigned to whisper", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.headerMail[#f.headerMail + 1] = { btn = btn, Collect = CollectOthers }
    return btn
end

-- Enable/desaturate every header mail button from its current collection.
-- Hidden outright without edit permission -- mass-whispering the raid their
-- jobs is the coordinator's move, and a dead button would just clutter the
-- read-only board.
local function UpdateHeaderMailButtons(f)
    local editable = WhoDoesWhat:CanEditAssignments()
    for _, hm in ipairs(f.headerMail) do
        local n = #hm.Collect()
        hm.btn:SetShown(editable)
        hm.btn:SetEnabled(n > 0)
        hm.btn.icon:SetDesaturated(n == 0)
    end
end

-- ---------------------------------------------------------------------------
-- Refresh passes
-- ---------------------------------------------------------------------------

local RefreshDynamicSection -- forward declared; defined with the dynamic rows
local RefreshPaladinSummary -- forward declared; defined with its row builder

-- Read-only rendering (Permissions.lua): without edit rights every row swaps
-- its dropdowns for a plain text line (row.roText) and hides the add/remove/
-- clear/Auto controls. Warnings, mail buttons and the pop-out windows
-- (Info + Grid / Calc) stay -- reading the board and whispering your own
-- assignment never took rights. The Paladin Buffs section is computed and
-- read-only for everyone, so permissions never touch its rows.

-- One dynamic entry as a read-only line: player (spell) -> target, same
-- vocabulary as the editable widgets it replaces.
local function ReadOnlyEntryText(section, entry)
    local target
    if section.targetPlayer then
        target = PlayerText(entry.target)
        if entry.marker then
            target = target .. " " .. MarkerMarkup(entry.marker, 14)
        end
    elseif entry.marker == "custom" then
        target = (entry.custom and entry.custom ~= "") and entry.custom
            or ("|T" .. CUSTOM_TARGET_ICON .. ":14:14:0:0|t Custom")
    else
        target = TargetText(entry) -- marker icon / "Everything else"
    end
    local text = PlayerText(entry.player)
    if section.spells then
        local spell = SpellById(entry.spell)
        if spell then
            text = text .. " (" .. SpellText(spell) .. ")"
        end
    end
    return text .. " -> " .. target
end

-- The editing-permission strip at the window's top-left: the raid leader
-- gets the picker dropdown, every other raid member a note naming the rule
-- (and whether the board is read-only for them). Hidden outside raids --
-- parties and solo are always open, nothing to say.
local function UpdatePermissionControls(f)
    if not IsInRaid() then
        f.permDD:Hide()
        f.permNote:Hide()
        return
    end
    -- Rule stood down (battleground, or the leader doesn't run the addon):
    -- everyone edits, and the note says why -- the picker would be a lie.
    local openReason = WhoDoesWhat:PermissionsOpenReason()
    if openReason then
        f.permDD:Hide()
        f.permNote:SetText("|cff909090Editing: everyone (" .. openReason .. ")|r")
        f.permNote:Show()
        return
    end
    if UnitIsGroupLeader("player") then
        UIDropDownMenu_SetText(f.permDD, "Editing: " .. WhoDoesWhat:PermissionModeLabel())
        f.permDD:Show()
        f.permNote:Hide()
    else
        f.permDD:Hide()
        f.permNote:SetText("|cff909090Editing: " .. WhoDoesWhat:PermissionModeLabel()
            .. (WhoDoesWhat:CanEditAssignments() and ""
                or " - the board is read-only for you") .. "|r")
        f.permNote:Show()
    end
end

-- Re-anchor a section's header buttons right-to-left, skipping hidden ones,
-- so the rightmost VISIBLE button hugs the box corner -- the mail button
-- (and a dynamic section's X) hide in read-only mode and would otherwise
-- leave a hole at the right edge. Chains are stored rightmost-first at build
-- time; run after every visibility change.
local function LayoutHeaderChain(chain)
    local prev
    for _, btn in ipairs(chain) do
        if btn:IsShown() then
            btn:ClearAllPoints()
            if prev then
                -- -2 matches the rows' x/mail gap, so the columns line up.
                btn:SetPoint("RIGHT", prev, "LEFT", -2, 0)
            else
                btn:SetPoint("TOPRIGHT", btn:GetParent(), "TOPRIGHT", -BOX_PAD, -HEADER_STRIP_TOP)
            end
            prev = btn
        end
    end
end

-- Repaint every static row from the DB (dropdown text, warning icon, mail
-- button state), the computed paladin summary rows, then every dynamic
-- section.
local function RefreshRows(f)
    local editable = WhoDoesWhat:CanEditAssignments()
    UpdatePermissionControls(f)
    for id, row in pairs(f.rows) do
        local assigned = GetAssignment(id)
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
    RefreshPaladinSummary(f)
    for _, section in ipairs(DynamicSections) do
        RefreshDynamicSection(f, section)
    end
    UpdateHeaderMailButtons(f)

    -- Auto rewrites its whole section, so it's an edit control: greyed out
    -- (not hidden -- the affordance stays discoverable) without permission,
    -- with the tooltip explaining. Info + Grid / Calc only open read-only
    -- windows and stay live for everyone; the class-disable pass below
    -- leaves a permission-greyed Auto alone.
    for _, s in ipairs(f.staticSections) do
        if s.autoBtn then
            s.autoBtn:SetEnabled(editable)
            s.autoBtn.disabledReason = not editable
                and ("Requires editing permission - the raid leader has editing set to "
                    .. WhoDoesWhat:PermissionModeLabel() .. ".")
                or nil
        end
    end

    -- Disable pass, last so it wins over the row and header-mail updates
    -- above: a section tied to a class grays out entirely while that class is
    -- absent (no paladins: nothing to assign, Auto and Info + Grid pointless).
    -- Developer Mode keeps everything live, same as it lifts class filters.
    for _, s in ipairs(f.staticSections) do
        local cls = s.def.disableWhenNoClass
        if cls then
            local enabled = DevMode() or #MembersOfClass(cls) > 0
            local reason = not enabled and ("No " .. cls:lower() .. "s in the group.") or nil

            if enabled then
                s.box.title:SetTextColor(1, 0.82, 0) -- GameFontNormal gold
            else
                s.box.title:SetTextColor(0.5, 0.5, 0.5)
                s.mailBtn:SetEnabled(false)
                s.mailBtn.icon:SetDesaturated(true)
            end
            for _, btn in ipairs(s.buttons) do
                if btn == s.autoBtn and not editable then
                    -- keep the permission grey-out (and its tooltip reason)
                else
                    btn:SetEnabled(enabled)
                    btn.disabledReason = reason
                end
            end
            for _, id in ipairs(s.rowIds) do
                local row = f.rows[id]
                row.icon:SetDesaturated(not enabled)
                if enabled then
                    UIDropDownMenu_EnableDropDown(row.dropdown)
                    row.label:SetTextColor(1, 1, 1)
                else
                    UIDropDownMenu_DisableDropDown(row.dropdown)
                    row.label:SetTextColor(0.45, 0.45, 0.45)
                    row.warnIcon:Hide()
                    row.mailBtn:SetEnabled(false)
                    row.mailBtn.icon:SetDesaturated(true)
                end
            end
        end
    end

    -- Header button visibility is settled now; close ranks around the
    -- read-only mode's hidden mail buttons.
    for _, s in ipairs(f.staticSections) do
        LayoutHeaderChain(s.headerChain)
    end
end

-- ---------------------------------------------------------------------------
-- Widget builders
-- ---------------------------------------------------------------------------

local function AddDropdownDivider(level)
    if UIDropDownMenu_AddSeparator then
        UIDropDownMenu_AddSeparator(level)
        return
    end
    local info = UIDropDownMenu_CreateInfo()
    info.text = ""
    info.disabled = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info, level)
end

-- Shared player-list portion of an assignment dropdown: eligible members
-- (class-filtered unless class is nil / Developer Mode), IsPreferred members
-- floated above a divider, an empty-state line, and a "None" clearer.
--   class          eligible class name, or nil for everyone
--   IsPreferred(m) optional; true floats the member above the divider
--   saved          currently assigned player name (radio state)
--   OnPick(name)   selection callback (nil = None)
--   Annotate(m)    optional; note text appended after the member's name
--                  (talent ranks on the paladin buff rows), nil for none
local function AddPlayerMenuItems(level, class, IsPreferred, saved, OnPick, Annotate, noneFirst)
    local members = GetEligibleMembers(class)

    local dividerAfter = nil
    if IsPreferred then
        local preferred, rest = {}, {}
        for _, m in ipairs(members) do
            if IsPreferred(m) then
                preferred[#preferred + 1] = m
            else
                rest[#rest + 1] = m
            end
        end
        if #preferred > 0 and #rest > 0 then
            dividerAfter = #preferred
        end
        members = preferred
        for _, m in ipairs(rest) do
            members[#members + 1] = m
        end
    end

    local function AddNone()
        local info = UIDropDownMenu_CreateInfo()
        info.text = "None"
        info.checked = (saved == nil)
        info.func = function() OnPick(nil) end
        UIDropDownMenu_AddButton(info, level)
    end

    -- noneFirst puts the clear option at the top (used by the misdirect tank
    -- picker); everywhere else "None" trails the roster.
    if noneFirst then
        AddNone()
        if #members > 0 then AddDropdownDivider(level) end
    end

    if #members == 0 then
        local info = UIDropDownMenu_CreateInfo()
        info.text = "|cff909090No " .. (class and class:lower() .. "s" or "players") .. " in group|r"
        info.notCheckable = true
        info.disabled = true
        UIDropDownMenu_AddButton(info, level)
    end

    for i, m in ipairs(members) do
        local name = m.name
        local info = UIDropDownMenu_CreateInfo()
        local note = Annotate and Annotate(m)
        info.text = RoleIconMarkup(name) .. "|cff" .. m.classInfo.colorHex .. name .. "|r"
            .. (note and (" " .. note) or "")
        info.checked = (saved == name)
        info.func = function() OnPick(name) end
        UIDropDownMenu_AddButton(info, level)
        if i == dividerAfter then
            AddDropdownDivider(level)
        end
    end

    if not noneFirst then
        AddNone()
    end
end

-- Wire a static row's dropdown. The initialize function re-runs every time
-- the menu opens, so the member list is always fresh.
local function InitAssignmentDropdown(dropdown, def)
    UIDropDownMenu_Initialize(dropdown, function(_, level)
        local IsPreferred = def.IsPreferred
            or (def.preferRoleId and function(m)
                return WhoDoesWhat:GetAssignedRole(m.name) == def.preferRoleId
            end)
            or nil
        AddPlayerMenuItems(level, def.class, IsPreferred, GetAssignment(def.id),
            function(name) SetAssignment(def.id, name) end, def.Annotate)
    end)
end

-- Warning (!) icon; the refresh passes set .tooltipText and show/hide it.
-- Hover explains the problem. Starts hidden.
local function CreateWarningIcon(row)
    local warn = CreateFrame("Frame", nil, row)
    warn:SetSize(WARNING_ICON_SIZE, WARNING_ICON_SIZE)
    local tex = warn:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture(WARNING_ICON)
    warn:EnableMouse(true)
    warn:SetScript("OnEnter", function(self)
        if self.tooltipText then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Warning", 1, 0.82, 0)
            GameTooltip:AddLine(self.tooltipText, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    warn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    warn:Hide()
    return warn
end

-- Small red mail button: whispers the assigned player their job. GetWhisper
-- returns (playerName, whisperText, displayText), or nothing while
-- unassigned; the refresh passes disable/desaturate it accordingly.
-- displayText is the version for our own chat and the hover tooltip (it
-- defaults to whisperText) -- they differ where the whisper uses chat's
-- {skull} tokens, which only expand into icons on the receiving end.
local function CreateMailButton(row, GetWhisper)
    local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    btn:SetSize(MAIL_BTN_SIZE, MAIL_BTN_SIZE)
    btn:SetText("")
    btn:SetMotionScriptsWhileDisabled(true) -- tooltip works while disabled
    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(MAIL_ICON)
    btn.icon = icon
    btn:SetScript("OnClick", function()
        local name, job, display = GetWhisper()
        if not name then return end
        SendChatMessage("[WhoDoesWhat] Your assignment: " .. job .. ".", "WHISPER", nil, name)
        WhoDoesWhat:Print("Whispered " .. name .. " their assignment: " .. (display or job) .. ".")
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local name, job, display = GetWhisper()
        if name then
            -- Spell out what will be sent: one player can hold several rows,
            -- and every one of their buttons whispers the same full list.
            GameTooltip:SetText("Whisper " .. name, 1, 1, 1)
            GameTooltip:AddLine(display or job, 0.8, 0.8, 0.8, true)
        else
            GameTooltip:SetText("No one assigned to whisper", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

-- Hairline divider on a row boundary (subtler + more inset than the section
-- title's line).
local function AddRowDivider(parent, insetX, y)
    local divider = parent:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.3, 0.3, 0.3, 0.5)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", insetX, -y)
    divider:SetPoint("TOPRIGHT", -insetX, -y)
    return divider
end

-- Boxed section shell: lighter inset backdrop (same style as the All Roles
-- options box), gold title with a divider line. Anchor-chained below the
-- previous box *in its own column*, so height changes ripple down that column
-- and leave the other one alone.
local function CreateSectionBox(f, content, titleText, column)
    local col = f.columns[column]
    local box = CreateFrame("Frame", nil, content, "BackdropTemplate")
    -- Explicit level: same-level siblings render in unstable order (the box
    -- backdrop can draw over the rows until a move re-sorts the frames).
    box:SetFrameLevel(content:GetFrameLevel() + 1)
    box:SetWidth(col.width)
    local prev = col.boxes[#col.boxes]
    if prev then
        box:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -SECTION_GAP)
    else
        box:SetPoint("TOPLEFT", content, "TOPLEFT", col.x, 0)
    end
    box:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    box:SetBackdropColor(0.16, 0.16, 0.18, 0.9)
    box:SetBackdropBorderColor(0.4, 0.4, 0.4)

    local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    -- Anchor by LEFT (vertically centers the FontString) onto the header
    -- button strip's midline -- buttons sit at top -HEADER_STRIP_TOP, height
    -- MAIL_BTN_SIZE -- so the title text and the header buttons share a line.
    title:SetPoint("LEFT", box, "TOPLEFT", BOX_PAD + 2, -(HEADER_STRIP_TOP + MAIL_BTN_SIZE / 2))
    title:SetText(titleText)
    box.title = title -- the disable pass grays it

    -- The divider sits right under the header buttons (22px from y -6), so
    -- the rows can start immediately below without dead space.
    local line = box:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", BOX_PAD, -(BOX_PAD + 20))
    line:SetPoint("TOPRIGHT", -BOX_PAD, -(BOX_PAD + 20))

    col.boxes[#col.boxes + 1] = box
    return box
end

-- Recompute the scroll child's height from the taller column (the dynamic
-- boxes grow and shrink with their rows) and refresh the scroll range.
local function UpdateContentHeight(f)
    local tallest = 0
    for _, col in ipairs(f.columns) do
        local h = 0
        for _, box in ipairs(col.boxes) do
            h = h + box:GetHeight() + SECTION_GAP
        end
        tallest = math.max(tallest, h)
    end
    f.content:SetHeight(math.max(tallest, 1))
    f.scroll:UpdateScrollChildRect()
end

-- ---------------------------------------------------------------------------
-- Static section rows
-- ---------------------------------------------------------------------------

-- One static assignment row inside a section box: spell icon + name on the
-- left (hovering the icon shows the ability's game tooltip), then the
-- warning icon, the player dropdown, and the mail button. Registers the row
-- on f.rows so RefreshRows can repaint it. Returns the y offset below.
local function AddAssignmentRow(f, box, y, def, sectionTitle)
    local row = CreateFrame("Frame", nil, box)
    row:SetFrameLevel(box:GetFrameLevel() + 1)
    row:SetSize(box:GetWidth() - BOX_PAD * 2, ROW_H)
    row:SetPoint("TOPLEFT", BOX_PAD, -y)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ROW_ICON_SIZE, ROW_ICON_SIZE)
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

    local mailBtn = CreateMailButton(row, function()
        local name = GetAssignment(def.id)
        if name then
            return name, def.label .. " (" .. sectionTitle .. ")"
        end
    end)
    mailBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    -- UIDropDownMenu carries ~15px of transparent padding each side; overhang
    -- toward the mail button so the visible box sits a few px left of it.
    local dropdown = CreateFrame("Frame", "WhoDoesWhatAssignDropDown_" .. def.id, row, "UIDropDownMenuTemplate")
    dropdown:SetPoint("RIGHT", mailBtn, "LEFT", 12, -2)
    UIDropDownMenu_SetWidth(dropdown, DROPDOWN_WIDTH)
    LeftAlignDropdown(dropdown)
    InitAssignmentDropdown(dropdown, def)

    local warn = CreateWarningIcon(row)
    warn:SetPoint("RIGHT", dropdown, "LEFT", 12, 2)

    -- Read-only stand-in for the dropdown: the assigned name as plain text
    -- (class colors survive, unlike a disabled dropdown's gray-out). Runs to
    -- the row edge -- the mail button is hidden whenever this shows. The
    -- refresh pass swaps the two on edit permission.
    local roText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    roText:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    roText:SetJustifyH("RIGHT")
    roText:Hide()

    f.rows[def.id] = {
        def = def, dropdown = dropdown, warnIcon = warn, mailBtn = mailBtn,
        roText = roText,
        icon = icon, label = label, -- for the disabled (grayed) look
    }
    return y + ROW_H
end

-- Paladin Buffs summary rows: one short, read-only row per paladin --
-- [role icon] Name  [buff icon] (n) > [buff icon] (n) -- showing up to
-- three of their computed blessing workloads (ComputePaladinBuffSummary,
-- already count-sorted with the paladins total-sorted). Pooled, since the
-- paladin count changes; the box resizes and ripples its column.
--
-- Below the summary sit the custom rule rows ("+ Rule" header button; the
-- model docs the semantics at CompileBuffRules):
--
--   [buff v] [Is Ignored / Prioritized for / Preferred by v] [target v] [x]
--
-- One rule per blessing, six at most (the buff dropdown only offers unruled
-- blessings). Rules are LOCAL strategy config -- not part of the synced
-- board, so they aren't permission-gated; everyone tunes their own view.
local PALLY_ROW_H = 24
local PALLY_MAX_BUFFS = 3
local RULE_ROW_H = 30
local RULE_BUFF_DD_W = 78
local RULE_KIND_DD_W = 90
local RULE_TARGET_DD_W = 76

local WOW_ROLE_LABELS = { tank = "Tanks", healer = "Healers", dps = "DPS" }

-- Menu text / collapsed text per rule kind.
local RULE_KINDS = {
    { kind = "ignore", menu = "Is Ignored", short = "Ignored" },
    { kind = "prioritize", menu = "Is Prioritized for...", short = "Priority for" },
    { kind = "prefer", menu = "Is Preferred by...", short = "Preferred by" },
}

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

-- Build pooled rule row #index. Position comes from RefreshPaladinSummary
-- (it sits below however many summary rows there are); every callback looks
-- its rule up by index at click time, like the dynamic sections' rows.
local function CreatePallyRuleRow(f, index)
    local state = f.pallySummary
    local row = CreateFrame("Frame", nil, state.box)
    row:SetFrameLevel(state.box:GetFrameLevel() + 1)
    row:SetSize(state.box:GetWidth() - BOX_PAD * 2, RULE_ROW_H)

    local function Entry() return GetBuffRules()[index] end
    local function Changed()
        RefreshPaladinSummary(f)
        WhoDoesWhat:RefreshPaladinBuffGridView()
    end

    -- Buff picker: only blessings no other rule already claims.
    local buffDD = CreateFrame("Frame", "WhoDoesWhatPallyRuleBuffDD" .. index, row, "UIDropDownMenuTemplate")
    buffDD:SetPoint("LEFT", row, "LEFT", -13, -2)
    UIDropDownMenu_SetWidth(buffDD, RULE_BUFF_DD_W)
    LeftAlignDropdown(buffDD)
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
    LeftAlignDropdown(kindDD)
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
    LeftAlignDropdown(targetDD)
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
                    AddDropdownDivider(level)
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
            AddDropdownDivider(level)
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
        AddDropdownDivider(level)
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
    delBtn:SetSize(MAIL_BTN_SIZE, MAIL_BTN_SIZE)
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
    local warn = CreateWarningIcon(row)
    warn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
    row.warnIcon = warn

    state.ruleRows[index] = row
    return row
end

function RefreshPaladinSummary(f) -- forward declared above
    local state = f.pallySummary
    if not state then return end
    local summary = ComputePaladinBuffSummary()

    for i, p in ipairs(summary) do
        local row = state.rows[i]
        if not row then
            row = CreateFrame("Frame", nil, state.box)
            row:SetFrameLevel(state.box:GetFrameLevel() + 1)
            row:SetSize(state.box:GetWidth() - BOX_PAD * 2, PALLY_ROW_H)
            row:SetPoint("TOPLEFT", BOX_PAD, -(BOX_PAD + SECTION_TITLE_H + (i - 1) * PALLY_ROW_H))
            if i > 1 then
                AddRowDivider(row, 2, 0)
            end
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", 4, 0)
            fs:SetPoint("RIGHT", -4, 0)
            fs:SetJustifyH("LEFT")
            row.text = fs
            state.rows[i] = row
        end
        row:Show()

        local segs = {}
        for bi = 1, math.min(PALLY_MAX_BUFFS, #p.buffs) do
            local b = p.buffs[bi]
            segs[#segs + 1] = "|T" .. WhoDoesWhat.PaladinBuffs[b.key].iconId
                .. ":14:14:0:0|t (" .. b.count .. ")"
        end
        row.text:SetText(PlayerTextWithRole(p.name)
            .. (#segs > 0 and ("  " .. table.concat(segs, " > ")) or ""))
    end
    for i = #summary + 1, #state.rows do
        state.rows[i]:Hide()
    end

    state.emptyHint:SetShown(#summary == 0)
    local rowsH = (#summary > 0) and (#summary * PALLY_ROW_H) or DYN_EMPTY_H

    -- The rules area below the summary: a hairline, then one editable row
    -- per rule. The rows are re-anchored every pass -- their y depends on
    -- how many summary rows sit above them.
    local rules = GetBuffRules()
    local rulesTop = BOX_PAD + SECTION_TITLE_H + rowsH
    if #rules > 0 then
        if not state.ruleDivider then
            state.ruleDivider = AddRowDivider(state.box, BOX_PAD + 2, 0)
        end
        state.ruleDivider:ClearAllPoints()
        state.ruleDivider:SetPoint("TOPLEFT", BOX_PAD + 2, -(rulesTop + 2))
        state.ruleDivider:SetPoint("TOPRIGHT", -(BOX_PAD + 2), -(rulesTop + 2))
        state.ruleDivider:Show()
        rulesTop = rulesTop + 5
    elseif state.ruleDivider then
        state.ruleDivider:Hide()
    end

    for i, rule in ipairs(rules) do
        local row = state.ruleRows[i] or CreatePallyRuleRow(f, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", BOX_PAD, -(rulesTop + (i - 1) * RULE_ROW_H))
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

    state.box:SetHeight(rulesTop + #rules * RULE_ROW_H + BOX_PAD)
    UpdateContentHeight(f)
end

-- Small text button in a static section's title strip (Auto, Grid), chained
-- left of anchorTo. The tooltip swaps its body for btn.disabledReason while
-- the disable pass has the button off, so a dead button explains itself.
local function AddHeaderTextButton(box, anchorTo, text, tooltipTitle, tooltipText, OnClick)
    local btn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    btn:SetFrameLevel(box:GetFrameLevel() + 1)
    btn:SetHeight(MAIL_BTN_SIZE) -- same strip height as the mail/X buttons
    btn:SetPoint("RIGHT", anchorTo, "LEFT", -2, 0)
    btn:SetText(text)
    -- Width from the label: a fixed 40px crams four-letter labels against
    -- the template's side bevels.
    btn:SetWidth(math.max(44, btn:GetTextWidth() + 18))
    btn:SetMotionScriptsWhileDisabled(true)
    btn:SetScript("OnClick", OnClick)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tooltipTitle, 1, 1, 1)
        if not self:IsEnabled() and self.disabledReason then
            GameTooltip:AddLine(self.disabledReason, 1, 0.4, 0.4, true)
        else
            GameTooltip:AddLine(tooltipText, 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

-- One static boxed section: shell + header buttons (mass-mail, then Auto and
-- Grid when the section asks for them) + its rows, with hairline row
-- dividers. The built widgets are registered on f.staticSections so the
-- refresh's disable pass can gray the section out wholesale.
local function AddSection(f, content, section)
    WhoDoesWhat:LogUiBuilding("Building assignment section: " .. section.title)

    local box = CreateSectionBox(f, content, section.title, section.column)
    local mailBtn = AddHeaderMailButton(f, box, section.title, function()
        if section.paladinSummary then
            -- Computed workloads, not stored rows: each paladin gets their
            -- "Blessings: Might x12, Kings x3" line.
            return CollectPaladinBuffWhispers()
        end
        return CollectStaticWhispers(section)
    end)

    local buttons = {}
    local autoBtn
    local anchor = mailBtn
    if section.AutoAssign then
        anchor = AddHeaderTextButton(box, anchor, "Auto", "Auto-assign",
            section.autoTooltip, function()
                section.AutoAssign()
                RefreshRows(f)
                WhoDoesWhat:RefreshPaladinBuffGridView()
            end)
        buttons[#buttons + 1] = anchor
        autoBtn = anchor -- hidden without edit permission (see RefreshRows)
    end
    if section.gridButton then
        anchor = AddHeaderTextButton(box, anchor, "Info + Grid", "Paladin Info + Grid",
            "Open the paladin window: every paladin's buff-talent ranks on"
            .. " the left, and the buff grid -- every raider against every"
            .. " paladin, with the blessing each paladin gives them -- on"
            .. " the right.", function()
                WhoDoesWhat:OpenPaladinBuffGridView()
            end)
        buttons[#buttons + 1] = anchor
    end
    if section.paladinSummary then
        anchor = AddHeaderTextButton(box, anchor, "+ Rule", "Add a buff rule",
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
                RefreshPaladinSummary(f)
                WhoDoesWhat:RefreshPaladinBuffGridView()
            end)
        buttons[#buttons + 1] = anchor
    end
    if section.calcButton then
        anchor = AddHeaderTextButton(box, anchor, "Calc", "Curse Value Calculator",
            "Estimate how much raid damage Curse of the Elements and Curse of"
            .. " Recklessness provided (or could have provided), pulling the"
            .. " fight data from Details!.", function()
                WhoDoesWhat:OpenCurseCalculatorView()
            end)
        buttons[#buttons + 1] = anchor
    end

    local rowIds = {}
    local innerY = BOX_PAD + SECTION_TITLE_H
    if section.paladinSummary then
        -- No assignment rows: pooled read-only paladin rows plus the custom
        -- rule rows, built and sized by RefreshPaladinSummary. The empty
        -- hint covers the no-paladin case.
        local hint = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOPLEFT", BOX_PAD + 4, -(innerY + 4))
        hint:SetTextColor(0.55, 0.55, 0.55)
        hint:SetText("No paladins in the group.")
        f.pallySummary = { box = box, rows = {}, ruleRows = {}, emptyHint = hint }
        innerY = innerY + DYN_EMPTY_H -- provisional; the refresh resizes
    else
        for i, def in ipairs(section.rows) do
            if i > 1 then
                AddRowDivider(box, BOX_PAD + 2, innerY)
            end
            innerY = AddAssignmentRow(f, box, innerY, def, section.title)
            rowIds[#rowIds + 1] = def.id
        end
    end
    box:SetHeight(innerY + BOX_PAD)

    -- Rightmost-first header chain for LayoutHeaderChain: mail at the box
    -- corner, then the text buttons in creation order (Auto, Grid, ...).
    local headerChain = { mailBtn }
    for _, b in ipairs(buttons) do
        headerChain[#headerChain + 1] = b
    end

    f.staticSections[#f.staticSections + 1] = {
        def = section, box = box, mailBtn = mailBtn,
        buttons = buttons, rowIds = rowIds, autoBtn = autoBtn,
        headerChain = headerChain,
    }
end

-- ---------------------------------------------------------------------------
-- Dynamic sections (pooled, user-added rows)
-- ---------------------------------------------------------------------------

-- Build the pooled row #index for a dynamic section. The row position is
-- fixed; RefreshDynamicSection maps entry data onto it (and hides surplus
-- rows), so every callback looks its entry up by index at click time.
local function CreateDynamicRow(f, section, index)
    local state = f.dynamic[section.key]
    local box = state.box
    local prefix = "WhoDoesWhat" .. section.key

    local row = CreateFrame("Frame", nil, box)
    row:SetFrameLevel(box:GetFrameLevel() + 1)
    row:SetSize(box:GetWidth() - BOX_PAD * 2, ROW_H)
    row:SetPoint("TOPLEFT", BOX_PAD, -(BOX_PAD + SECTION_TITLE_H + (index - 1) * ROW_H))

    if index > 1 then
        AddRowDivider(row, 2, 0)
    end

    local function Entry() return GetEntries(section)[index] end

    -- Repaint the misdirect box (a tank-row change only repaints the tank box).
    local function RepaintMisdirects()
        for _, s in ipairs(DynamicSections) do
            if s.key == "md" then RefreshDynamicSection(f, s) break end
        end
    end

    -- Reconcile misdirects after a tank row changes: pull the tank's misdirects
    -- onto its new first marker, and (adopt=true) point any tank-less misdirect
    -- already on this row's marker at the tank. adopt is false for deletes --
    -- the tank no longer holds that marker. No-op off the tank section (this row
    -- builder is shared with CC/misdirect).
    local function SyncTankMisdirects(entry, adopt)
        if section.key ~= "tank" or not entry then return end
        WhoDoesWhat:SyncMisdirectsForTank(entry.player)
        if adopt and entry.player and type(entry.marker) == "number" then
            WhoDoesWhat:AdoptMisdirectsForMarker(entry.marker, entry.player)
        end
        RepaintMisdirects()
    end

    local anchor

    if section.autoRows then
        -- Auto-row sections (one row per hunter) don't pick the player -- the
        -- row IS that player, so a fixed label stands where the picker would be.
        -- Sits at row center; the arrow/"for" label drops its usual +2 nudge
        -- when anchored to this plain label (see below) so they line up.
        local playerLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        playerLabel:SetPoint("LEFT", row, "LEFT", 4, 0)
        playerLabel:SetWidth(DYN_PLAYER_DD_WIDTH)
        playerLabel:SetJustifyH("LEFT")
        row.playerLabel = playerLabel
        anchor = playerLabel
    else
    -- UIDropDownMenu carries ~15px of transparent padding each side, so the
    -- frame hangs left of the row to land its visible box at the same x=4 the
    -- static rows start their icon on. Everything to the right is anchored off
    -- this one, so they all come with it.
    local playerDD = CreateFrame("Frame", prefix .. "PlayerDD" .. index, row, "UIDropDownMenuTemplate")
    playerDD:SetPoint("LEFT", row, "LEFT", -11, -2)
    UIDropDownMenu_SetWidth(playerDD, DYN_PLAYER_DD_WIDTH)
    LeftAlignDropdown(playerDD)
    UIDropDownMenu_Initialize(playerDD, function(_, level)
        local entry = Entry()
        if not entry then return end
        AddPlayerMenuItems(level, section.playerClass,
            section.IsPreferred and function(m) return section.IsPreferred(m, entry) end,
            entry.player,
            function(name)
                local prev = entry.player
                ClearSpellIfUncastable(entry, name)
                entry.player = name
                if name then
                    WhoDoesWhat:Print(section.title .. ": " .. name .. " -> "
                        .. EntryText(section, entry, TargetPlainText) .. ".")
                else
                    WhoDoesWhat:Print(section.title .. ": assignment cleared.")
                end
                if section.key == "tank" then
                    -- Old tank first (data only), then the new tank through the
                    -- shared helper: forward-sync + adopt tank-less misdirects on
                    -- its marker + repaint the misdirect box.
                    WhoDoesWhat:SyncMisdirectsForTank(prev)
                    SyncTankMisdirects(entry, true)
                end
                RefreshDynamicSection(f, section)
            end)
    end)
    row.playerDD = playerDD
    anchor = playerDD
    end

    -- Spell picker (CC only). The list is class-ordered, so a divider on each
    -- class change keeps a long list scannable.
    if section.spells then
        local spellDD = CreateFrame("Frame", prefix .. "SpellDD" .. index, row, "UIDropDownMenuTemplate")
        spellDD:SetPoint("LEFT", anchor, "RIGHT", -18, 0)
        UIDropDownMenu_SetWidth(spellDD, DYN_SPELL_DD_WIDTH)
        LeftAlignDropdown(spellDD)
        UIDropDownMenu_Initialize(spellDD, function(_, level)
            local entry = Entry()
            if not entry then return end

            local spells = SpellsForEntry(section, entry)
            if #spells == 0 then
                -- A player is assigned but their class brings no CC (Warrior,
                -- Shaman); say so rather than showing an empty menu.
                local m = FindMember(entry.player)
                local info = UIDropDownMenu_CreateInfo()
                info.text = "|cff909090No CC spells for a "
                    .. (m and m.classInfo.name or "this class") .. "|r"
                info.notCheckable = true
                info.disabled = true
                UIDropDownMenu_AddButton(info, level)
                return
            end

            local lastClass
            for _, spell in ipairs(spells) do
                if lastClass and spell.class ~= lastClass then
                    AddDropdownDivider(level)
                end
                lastClass = spell.class
                local info = UIDropDownMenu_CreateInfo()
                info.text = SpellText(spell)
                info.checked = (entry.spell == spell.id)
                info.func = function()
                    entry.spell = spell.id
                    RefreshDynamicSection(f, section)
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        row.spellDD = spellDD
        anchor = spellDD
    end

    local arrowLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    -- The +2 y compensates for a dropdown-frame anchor sitting at y=-2; when the
    -- anchor is the plain hunter label (auto-rows) there's no such offset, so it
    -- drops to 0 to stay level with the name.
    arrowLabel:SetPoint("LEFT", anchor, "RIGHT", -10, section.autoRows and 0 or 2)
    -- Misdirects read "Hunter for Tank on Skull"; other rows keep the arrow.
    arrowLabel:SetText(section.targetPlayer and "for" or "->")
    row.arrowLabel = arrowLabel -- hidden with the dropdowns in read-only mode

    if section.targetPlayer then
        -- Target player picker (Misdirects): a second player dropdown in the
        -- marker dropdown's spot, listing the whole group with the preferred
        -- targets (marked tanks) floated above a divider.
        local targetDD = CreateFrame("Frame", prefix .. "TargetDD" .. index, row, "UIDropDownMenuTemplate")
        targetDD:SetPoint("LEFT", arrowLabel, "RIGHT", -12, -2)
        UIDropDownMenu_SetWidth(targetDD, DYN_PLAYER_DD_WIDTH)
        LeftAlignDropdown(targetDD)
        UIDropDownMenu_Initialize(targetDD, function(_, level)
            local entry = Entry()
            if not entry then return end
            AddPlayerMenuItems(level, nil, section.IsPreferredTarget, entry.target,
                function(name)
                    entry.target = name
                    -- Default the misdirect's marker to the tank's first marker.
                    entry.marker = name and WhoDoesWhat:FirstTankMarker(name) or nil
                    RefreshDynamicSection(f, section)
                end, nil, true)
        end)
        row.targetDD = targetDD

        -- "on" between the tank and its marker: "Hunter for Tank on Skull".
        local onLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        onLabel:SetPoint("LEFT", targetDD, "RIGHT", -10, 2)
        onLabel:SetText("on")
        row.onLabel = onLabel -- hidden with the dropdowns in read-only mode

        -- Marker on the pair (which target the hunter misdirects on): plain
        -- markers plus None, no "Everything else"/custom here. It defaults to
        -- (and follows) the tank's first marker, but can be overridden here.
        local markerDD = CreateFrame("Frame", prefix .. "TargetMarkerDD" .. index, row, "UIDropDownMenuTemplate")
        markerDD:SetPoint("LEFT", onLabel, "RIGHT", -12, -2)
        UIDropDownMenu_SetWidth(markerDD, TANK_MARKER_DD_WIDTH)
        LeftAlignDropdown(markerDD)
        UIDropDownMenu_Initialize(markerDD, function(_, level)
            local entry = Entry()
            if not entry then return end
            for _, m in ipairs(WhoDoesWhat.RaidTargetMarkers) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = MarkerMarkup(m.index, 14) .. " " .. m.name
                info.checked = (entry.marker == m.index)
                info.func = function()
                    entry.marker = m.index
                    RefreshDynamicSection(f, section)
                end
                UIDropDownMenu_AddButton(info, level)
            end
            AddDropdownDivider(level)
            local info = UIDropDownMenu_CreateInfo()
            info.text = "None"
            info.checked = (entry.marker == nil)
            info.func = function()
                entry.marker = nil
                RefreshDynamicSection(f, section)
            end
            UIDropDownMenu_AddButton(info, level)
        end)
        row.targetMarkerDD = markerDD
    else
        local markerDD = CreateFrame("Frame", prefix .. "MarkerDD" .. index, row, "UIDropDownMenuTemplate")
        markerDD:SetPoint("LEFT", arrowLabel, "RIGHT", -12, -2)
        UIDropDownMenu_SetWidth(markerDD, TANK_MARKER_DD_WIDTH)
        LeftAlignDropdown(markerDD)
        UIDropDownMenu_Initialize(markerDD, function(_, level)
            local entry = Entry()
            if not entry then return end
            -- The open menu keeps icon + name on every row; only the collapsed
            -- box narrows to the bare icon (see TargetText).
            for _, m in ipairs(WhoDoesWhat.RaidTargetMarkers) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = MarkerMarkup(m.index, 14) .. " " .. m.name
                info.checked = (entry.marker == m.index)
                info.func = function()
                    entry.marker = m.index
                    SyncTankMisdirects(entry, true)
                    RefreshDynamicSection(f, section)
                end
                UIDropDownMenu_AddButton(info, level)
            end

            AddDropdownDivider(level)

            if section.allowAll then
                local allInfo = UIDropDownMenu_CreateInfo()
                allInfo.text = "Everything else"
                allInfo.checked = (entry.marker == "all")
                allInfo.func = function()
                    entry.marker = "all"
                    SyncTankMisdirects(entry, true)
                    RefreshDynamicSection(f, section)
                end
                UIDropDownMenu_AddButton(allInfo, level)
            end

            local info = UIDropDownMenu_CreateInfo()
            info.text = "|T" .. CUSTOM_TARGET_ICON .. ":14:14:0:0|t Custom..."
            info.checked = (entry.marker == "custom")
            info.func = function()
                entry.marker = "custom"
                SyncTankMisdirects(entry, true)
                RefreshDynamicSection(f, section)
                row.customEdit:SetFocus()
            end
            UIDropDownMenu_AddButton(info, level)
        end)
        row.markerDD = markerDD
    end

    -- Right-hand controls, left to right: (!) [x] [mail]. Mail sits at the
    -- far right so it lines up with the static sections' mail column.
    row.mailBtn = CreateMailButton(row, function()
        local entry = Entry()
        if entry and entry.player then
            return entry.player,
                section.whisperLead .. PlayerEntriesText(section, entry.player, TargetChatText),
                section.whisperLead .. PlayerEntriesText(section, entry.player, TargetPlainText)
        end
    end)
    row.mailBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    -- Auto-row sections (misdirects) have no per-row [x] -- the row set is the
    -- roster, not hand-managed. The warning then anchors off mail instead.
    local warnAnchor = row.mailBtn
    if not section.autoRows then
        local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        delBtn:SetSize(MAIL_BTN_SIZE, MAIL_BTN_SIZE)
        delBtn:SetPoint("RIGHT", row.mailBtn, "LEFT", -2, 0)
        delBtn:SetText("x")
        delBtn:SetScript("OnClick", function()
            local removed = table.remove(GetEntries(section), index)
            SyncTankMisdirects(removed, false)
            WhoDoesWhat:Print(section.title .. ": " .. section.noun .. " removed.")
            RefreshDynamicSection(f, section)
        end)
        delBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Remove this assignment", 1, 1, 1)
            GameTooltip:Show()
        end)
        delBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.delBtn = delBtn
        warnAnchor = delBtn
    end

    -- Warning (!) left of the buttons. Anchored off [x] (or mail) rather than
    -- the row, so it holds its column while hidden and nothing shifts as
    -- warnings come and go.
    local warn = CreateWarningIcon(row)
    warn:SetPoint("RIGHT", warnAnchor, "LEFT", -4, 0)
    row.warnIcon = warn

    -- Custom target text, shown only while the marker dropdown is on Custom
    -- (marker sections only). Saves as it's typed; refreshes never clobber it
    -- while it has focus.
    if row.markerDD then
        local customEdit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        customEdit:SetHeight(18)
        customEdit:SetPoint("LEFT", row.markerDD, "RIGHT", -8, 2)
        customEdit:SetPoint("RIGHT", warn, "LEFT", -6, 0)
        customEdit:SetAutoFocus(false)
        customEdit:SetMaxLetters(40)
        customEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        customEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        customEdit:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                local entry = Entry()
                if entry then
                    entry.custom = self:GetText()
                end
            end
        end)
        customEdit:Hide()
        row.customEdit = customEdit
    end

    -- Read-only stand-in for the whole widget strip: one text line
    -- ("player (spell) -> target") in the dropdowns' place. The refresh pass
    -- swaps the two on edit permission.
    local roText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    roText:SetPoint("LEFT", row, "LEFT", 4, 0)
    roText:SetPoint("RIGHT", warn, "LEFT", -6, 0)
    roText:SetJustifyH("LEFT")
    roText:Hide()
    row.roText = roText

    state.rows[index] = row
    return row
end

-- Map a section's saved entries onto its pooled rows, resize its box to fit,
-- and ripple the new height into the scroll content.
function RefreshDynamicSection(f, section)
    local state = f.dynamic[section.key]
    local editable = WhoDoesWhat:CanEditAssignments()
    -- Auto-row sections rebuild their rows from the roster (one per hunter)
    -- before we map them onto the pooled UI rows.
    if section.autoRows then EnsureAutoRows(section) end
    local entries = GetEntries(section)

    for i, entry in ipairs(entries) do
        local row = state.rows[i] or CreateDynamicRow(f, section, i)
        row:Show()

        -- Edit widgets or the read-only line, never both (Permissions.lua).
        row.arrowLabel:SetShown(editable)
        if row.onLabel then row.onLabel:SetShown(editable) end
        row.roText:SetText(ReadOnlyEntryText(section, entry))
        row.roText:SetShown(not editable)

        if row.playerDD then
            row.playerDD:SetShown(editable)
            UIDropDownMenu_SetText(row.playerDD, PlayerTextWithRole(entry.player))
        end
        if row.playerLabel then
            row.playerLabel:SetShown(editable)
            row.playerLabel:SetText(PlayerTextWithRole(entry.player))
        end
        if row.delBtn then row.delBtn:SetShown(editable) end
        if row.spellDD then
            row.spellDD:SetShown(editable)
            UIDropDownMenu_SetText(row.spellDD, SpellText(SpellById(entry.spell)))
        end
        if row.targetDD then
            row.targetDD:SetShown(editable)
            row.targetMarkerDD:SetShown(editable)
            UIDropDownMenu_SetText(row.targetDD, PlayerTextWithRole(entry.target))
            UIDropDownMenu_SetText(row.targetMarkerDD, entry.marker
                and MarkerMarkup(entry.marker, 14) or "|cff909090--|r")
        end
        if row.markerDD then
            -- The marker box shrinks to its icon and widens only for the one
            -- text-only option, so set the width before the text each refresh.
            row.markerDD:SetShown(editable)
            UIDropDownMenu_SetWidth(row.markerDD,
                (entry.marker == "all") and TANK_MARKER_DD_WIDE or TANK_MARKER_DD_WIDTH)
            UIDropDownMenu_SetText(row.markerDD, TargetText(entry))

            if entry.marker == "custom" and editable then
                if not row.customEdit:HasFocus() then
                    row.customEdit:SetText(entry.custom or "")
                end
                row.customEdit:Show()
            else
                row.customEdit:ClearFocus()
                row.customEdit:Hide()
            end
        end

        local warning = section.GetWarning(entry)
        -- Same read-only rule as the static rows: a row with nobody on it
        -- only warns the people who could put somebody on it.
        if not editable and not entry.player then
            warning = nil
        end
        row.warnIcon.tooltipText = warning
        row.warnIcon:SetShown(warning ~= nil)
        -- A misdirect row only has a job to whisper once its tank is picked;
        -- other rows just need a player.
        local hasJob = entry.player ~= nil
            and (not section.targetPlayer or entry.target ~= nil)
        row.mailBtn:SetShown(editable)
        row.mailBtn:SetEnabled(hasJob)
        row.mailBtn.icon:SetDesaturated(not hasJob)
    end
    for i = #entries + 1, #state.rows do
        state.rows[i]:Hide()
    end
    if section.autoRows then
        state.emptyHint:SetText("No " .. section.autoRows:lower() .. "s in the group.")
    else
        state.emptyHint:SetText(editable
            and ("No " .. section.noun .. "s yet - click Add (+) to add one.")
            or ("No " .. section.noun .. "s yet."))
    end
    state.emptyHint:SetShown(#entries == 0)
    if state.plusBtn then state.plusBtn:SetShown(editable) end
    if state.clearBtn then
        state.clearBtn:SetShown(editable)
        state.clearBtn:SetEnabled(#entries > 0)
    end
    LayoutHeaderChain(state.headerChain)

    local rowsH = (#entries > 0) and (#entries * ROW_H) or DYN_EMPTY_H
    state.box:SetHeight(BOX_PAD + SECTION_TITLE_H + rowsH + BOX_PAD)
    -- Dropdown picks and [x] removals land here without a full RefreshRows,
    -- so the header mail buttons re-check alongside.
    UpdateHeaderMailButtons(f)
    UpdateContentHeight(f)
end

-- Clear-a-whole-section confirm. The `data` passed to StaticPopup_Show is the
-- function to run on Yes, so one dialog serves every section that wants it.
-- preferredIndex 3 keeps us off the frames the default UI cycles through.
StaticPopupDialogs["WHODOESWHAT_CLEAR_SECTION"] = {
    text = "Remove all %s?",
    button1 = "Clear All",
    button2 = "Cancel",
    OnAccept = function(self) self.data() end,
    timeout = 0,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Build a dynamic section's box: shell, empty-state hint, and the [+] button
-- (bottom-right) that appends an entry. Rows come from RefreshDynamicSection.
local function BuildDynamicSection(f, content, section)
    WhoDoesWhat:LogUiBuilding("Building assignment section: " .. section.title)

    local box = CreateSectionBox(f, content, section.title, COL_LEFT)
    local mailBtn = AddHeaderMailButton(f, box, section.title, function()
        return CollectDynamicWhispers(section)
    end)
    local state = { box = box, rows = {} }
    f.dynamic[section.key] = state

    -- Header "X": empty the whole section, behind a confirm popup. Disabled
    -- (and saying so) while there's nothing to clear.
    if section.clearAll then
        local clearBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
        clearBtn:SetFrameLevel(box:GetFrameLevel() + 1)
        -- Row-button size so it sits in the same column as the rows' [x].
        clearBtn:SetSize(MAIL_BTN_SIZE, MAIL_BTN_SIZE)
        clearBtn:SetPoint("RIGHT", mailBtn, "LEFT", -2, 0)
        clearBtn:SetText("X")
        clearBtn:SetMotionScriptsWhileDisabled(true)
        clearBtn:SetScript("OnClick", function()
            StaticPopup_Hide("WHODOESWHAT_CLEAR_SECTION") -- re-arm for this section
            StaticPopup_Show("WHODOESWHAT_CLEAR_SECTION", section.noun .. "s", nil,
                function()
                    wipe(GetEntries(section))
                    if section.key == "tank" then
                        -- Every tank lost its markers; clear the misdirects that
                        -- were following them, and repaint their box.
                        for _, e in ipairs(WhoDoesWhat.db.profile.mdAssignments) do
                            WhoDoesWhat:SyncMisdirectsForTank(e.target)
                        end
                        for _, s in ipairs(DynamicSections) do
                            if s.key == "md" then RefreshDynamicSection(f, s) break end
                        end
                    end
                    WhoDoesWhat:Print(section.title .. ": all " .. section.noun .. "s removed.")
                    RefreshDynamicSection(f, section)
                end)
        end)
        clearBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self:IsEnabled() then
                GameTooltip:SetText("Clear this section", 1, 1, 1)
                GameTooltip:AddLine("Remove every " .. section.noun .. " (asks first).",
                    0.8, 0.8, 0.8, true)
            else
                GameTooltip:SetText("Nothing to clear", 0.6, 0.6, 0.6)
            end
            GameTooltip:Show()
        end)
        clearBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        state.clearBtn = clearBtn
    end

    local hint = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", BOX_PAD + 4, -(BOX_PAD + SECTION_TITLE_H + 4))
    hint:SetTextColor(0.55, 0.55, 0.55)
    state.emptyHint = hint

    -- "Add (+)" lives in the title strip with the other section controls
    -- (LayoutHeaderChain re-anchors, so the initial anchor is provisional).
    -- Auto-row sections (misdirects) have no Add -- their rows are the roster.
    if not section.autoRows then
        state.plusBtn = AddHeaderTextButton(box, mailBtn, "Add (+)",
            "Add a " .. section.noun,
            "Append an empty " .. section.noun .. " row.", function()
                local entries = GetEntries(section)
                -- Player-target rows start fully blank; marker rows start on the
                -- first marker no sibling row is using yet.
                entries[#entries + 1] = section.targetPlayer and {}
                    or { marker = FirstUnusedMarker(section), custom = "" }
                WhoDoesWhat:LogUiBuilding("Added " .. section.noun .. " row " .. #entries)
                RefreshDynamicSection(f, section)
            end) -- hidden without edit permission
    end

    -- Rightmost-first header chain for LayoutHeaderChain: mail at the box
    -- corner, then X (when the section has one), then Add (+) when present.
    state.headerChain = { mailBtn }
    if state.clearBtn then
        state.headerChain[#state.headerChain + 1] = state.clearBtn
    end
    if state.plusBtn then
        state.headerChain[#state.headerChain + 1] = state.plusBtn
    end
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

-- The raid leader's editing-permission picker (Permissions.lua). Level 1
-- lists the four modes; "One assistant" opens a level-2 list of the raid's
-- current assistants (UIDROPDOWNMENU_MENU_VALUE pattern). Selection goes
-- through SetPermissionMode, which announces, repaints, and lets the sync
-- poll carry the new rule to everyone.
local PERMISSION_OPTIONS = {
    { mode = "leader", text = "Only me (leader)" },
    { mode = "assistant", text = "One assistant", hasArrow = true },
    { mode = "assists", text = "All assistants" },
    { mode = "everyone", text = "Everyone" },
}

local function InitPermissionsDropdown(_, level)
    local perms = WhoDoesWhat:GetPermissions()

    if level == 2 and UIDROPDOWNMENU_MENU_VALUE == "assistant" then
        local found = 0
        for i = 1, GetNumGroupMembers() do
            local name, rank, _, _, _, classToken = GetRaidRosterInfo(i)
            if rank == 1 then
                found = found + 1
                local color = classToken and RAID_CLASS_COLORS[classToken]
                local info = UIDropDownMenu_CreateInfo()
                info.text = color and ("|c" .. color.colorStr .. name .. "|r") or name
                info.checked = (perms.mode == "assistant" and perms.assistant == name)
                info.func = function()
                    WhoDoesWhat:SetPermissionMode("assistant", name)
                    CloseDropDownMenus()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
        if found == 0 then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "|cff909090No assistants - promote one first|r"
            info.notCheckable = true
            info.disabled = true
            UIDropDownMenu_AddButton(info, level)
        end
        return
    end

    for _, opt in ipairs(PERMISSION_OPTIONS) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = opt.text
        if opt.hasArrow then
            info.hasArrow = true
            info.value = "assistant"
            info.keepShownOnClick = true
            info.checked = (perms.mode == "assistant")
            info.func = function() end -- picking happens in the submenu
        else
            info.checked = (perms.mode == opt.mode)
            info.func = function()
                WhoDoesWhat:SetPermissionMode(opt.mode)
            end
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

-- Build the window once and reuse it: shared chrome, the Settings / Role
-- Preferences buttons under the title bar, and the two scrollable columns.
local function EnsureMainFrame()
    if mainFrame then return mainFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatMainFrame", FRAME_W, FRAME_H, "WhoDoesWhat - Raid Assignments")
    local top = f.titleBarHeight + 10

    local settingsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    settingsBtn:SetSize(80, BUTTON_ROW_H)
    settingsBtn:SetPoint("TOPRIGHT", -MARGIN, -top)
    settingsBtn:SetText("Settings")
    settingsBtn:SetScript("OnClick", function()
        WhoDoesWhat:OpenAddonSettingsView()
    end)

    local prefsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    prefsBtn:SetSize(130, BUTTON_ROW_H)
    prefsBtn:SetPoint("RIGHT", settingsBtn, "LEFT", -6, 0)
    prefsBtn:SetText("Role Preferences")
    prefsBtn:SetScript("OnClick", function()
        WhoDoesWhat:OpenAllRolesView()
    end)

    local raiderBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    raiderBtn:SetSize(110, BUTTON_ROW_H)
    raiderBtn:SetPoint("RIGHT", prefsBtn, "LEFT", -6, 0)
    raiderBtn:SetText("Raider Roles")
    raiderBtn:SetScript("OnClick", function()
        WhoDoesWhat:OpenRaiderRolesView()
    end)

    -- Editing-permission strip, top-left across from the view buttons: the
    -- raid leader sees the picker, other raid members a read-only note, and
    -- outside raids both hide (UpdatePermissionControls decides each refresh).
    -- The dropdown overhangs left by its template's ~15px padding so its
    -- visible box lines up with the window margin.
    local permDD = CreateFrame("Frame", "WhoDoesWhatPermissionsDD", f, "UIDropDownMenuTemplate")
    permDD:SetPoint("TOPLEFT", MARGIN - 15, -(top - 2))
    UIDropDownMenu_SetWidth(permDD, 170)
    LeftAlignDropdown(permDD)
    UIDropDownMenu_Initialize(permDD, InitPermissionsDropdown)
    permDD:Hide()
    f.permDD = permDD

    local permNote = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    permNote:SetPoint("TOPLEFT", MARGIN + 4, -(top + 6))
    permNote:Hide()
    f.permNote = permNote

    local scrollTop = top + BUTTON_ROW_H + 8
    local scroll = CreateFrame("ScrollFrame", "WhoDoesWhatMainScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", MARGIN, -scrollTop)
    scroll:SetPoint("BOTTOMRIGHT", -(MARGIN + SCROLLBAR_W), MARGIN)

    local content = CreateFrame("Frame", nil, scroll)
    -- A scroll child with no anchor point has an indeterminate rect until
    -- something forces a re-layout -- the "nothing renders until the window
    -- is moved" bug. Pin it explicitly.
    content:SetPoint("TOPLEFT")
    content:SetWidth(CONTENT_W)
    scroll:SetScrollChild(content)
    f.content = content
    f.scroll = scroll

    WhoDoesWhat:LogUiBuilding("Building main assignments content.")

    f.rows = {}
    f.dynamic = {}
    f.headerMail = {} -- section-header mass-mail buttons (AddHeaderMailButton)
    f.staticSections = {} -- per static section widgets, for the disable pass
    f.columns = {
        [COL_LEFT] = { boxes = {}, x = 0, width = LEFT_COLUMN_W },
        [COL_RIGHT] = { boxes = {}, x = LEFT_COLUMN_W + COLUMN_GAP, width = RIGHT_COLUMN_W },
    }

    for _, section in ipairs(DynamicSections) do
        BuildDynamicSection(f, content, section)
    end
    for _, section in ipairs(Sections) do
        AddSection(f, content, section)
    end
    -- Creates rows for saved entries and settles every height.
    for _, section in ipairs(DynamicSections) do
        RefreshDynamicSection(f, section)
    end

    -- Keep names' class colors and the warnings honest while the window is
    -- open (an assigned player leaving the group turns gray, etc.).
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:SetScript("OnEvent", function(self)
        if self:IsShown() then
            RefreshRows(self)
        end
    end)

    mainFrame = f
    return f
end

-- Repaint the rows if the window is up. Called from outside the view when
-- something warning-relevant changes (e.g. a role assignment in UnitMenu).
function WhoDoesWhat:RefreshMainAssignmentsView()
    if mainFrame and mainFrame:IsShown() then
        RefreshRows(mainFrame)
    end
end

-- Toggle the main assignments window open/closed.
function WhoDoesWhat:OpenMainAssignmentsView()
    local f = EnsureMainFrame()

    if f:IsShown() then
        self:LogUiBuilding("Main Assignments View open, closing it.")
        f:Hide()
        return
    end

    self:LogUiBuilding("Opening Main Assignments View...")
    PruneDepartedAssignments()
    RefreshRows(f)
    f:Show()
    f:Raise()
end
