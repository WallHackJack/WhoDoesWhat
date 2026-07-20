local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Tank Assignments section: one row per marked tank, auto-managed from the
-- roster (EnsureAutoRows) -- no Add/[x], the player cell is a fixed label,
-- and the marker dropdown is a multi-select so one tank holds all their
-- markers (entry.markers) on a single row:
--
--   [tank]  ->  [markers v] [custom text] (!) [mail]
--
-- Marker toggles route through the unit-menu setters (SetTankMarkerPlayer /
-- RemoveTankMarker, AssignmentsActions.lua), which enforce one-tank-per-
-- marker and pull the misdirects along; they end in a full window refresh,
-- so this file never repaints other sections itself. The header Reset
-- rebuilds the rows with the stock marker layout (ResetTankAssignments).

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit

local GetEntries = A.GetEntries
local EnsureAutoRows = A.EnsureAutoRows
local EntryHasJob = A.EntryHasJob
local PlayerText = A.PlayerText
local PlayerTextWithRole = A.PlayerTextWithRole
local PlayerEntriesText = A.PlayerEntriesText
local TargetText = A.TargetText
local TargetChatText = A.TargetChatText
local TargetPlainText = A.TargetPlainText
local HasMarkerValue = A.HasMarkerValue
local MarkersRichText = A.MarkersRichText
local MarkerMarkup = A.MarkerMarkup

local SECTION = A.SectionByKey("tank")

local Refresh -- forward declared; row callbacks repaint through it

-- Collapsed multi-marker box width: the 44px floor covers one icon; each
-- extra icon adds 16px, the word "Everything else" ~55px. Capped so a
-- kitchen-sink pick can't crowd the row's right-hand buttons.
local function MarkerDDWidth(entry)
    local w, icons = K.MARKER_DD_WIDTH, 0
    for _, v in ipairs(entry.markers or {}) do
        if v == "all" then w = w + 55 else icons = icons + 1 end
    end
    if icons > 1 then w = w + (icons - 1) * 16 end
    return math.min(w, 230)
end

-- Build pooled row #index. The row position is fixed; Refresh maps entry
-- data onto it (and hides surplus rows), so every callback looks its entry
-- up by index at click time.
local function CreateRow(f, index)
    local state = f.tankSection
    local row = K.CreateSectionRow(state.box, index)
    local function Entry() return GetEntries(SECTION)[index] end

    -- The row IS its tank, so a fixed label stands where a picker would be.
    local playerLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    playerLabel:SetPoint("LEFT", row, "LEFT", 4, 0)
    playerLabel:SetWidth(K.DYN_PLAYER_DD_WIDTH)
    playerLabel:SetJustifyH("LEFT")
    row.playerLabel = playerLabel

    local arrowLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    arrowLabel:SetPoint("LEFT", playerLabel, "RIGHT", -10, 0)
    arrowLabel:SetText("->")
    row.arrowLabel = arrowLabel

    -- Multi-select marker dropdown: every option is a checkbox toggling
    -- membership in entry.markers, and the menu stays open so several can be
    -- picked in one visit. UIDropDownMenu carries ~15px of transparent
    -- padding per side, hence the negative anchor offsets.
    local markerDD = CreateFrame("Frame", "WhoDoesWhattankMarkerDD" .. index, row, "UIDropDownMenuTemplate")
    markerDD:SetPoint("LEFT", arrowLabel, "RIGHT", -12, -2)
    UIDropDownMenu_SetWidth(markerDD, K.MARKER_DD_WIDTH)
    K.LeftAlignDropdown(markerDD)
    UIDropDownMenu_Initialize(markerDD, function(_, level)
        local entry = Entry()
        if not entry then return end
        local function AddToggle(value, text, closeAfter)
            local info = UIDropDownMenu_CreateInfo()
            info.text = text
            info.isNotRadio = true
            info.keepShownOnClick = not closeAfter
            info.checked = HasMarkerValue(entry, value)
            info.func = function()
                if HasMarkerValue(entry, value) then
                    WhoDoesWhat:RemoveTankMarker(value)
                else
                    WhoDoesWhat:SetTankMarkerPlayer(value, entry.player)
                    if value == "custom" then row.customEdit:SetFocus() end
                end
                if closeAfter then CloseDropDownMenus() end
            end
            UIDropDownMenu_AddButton(info, level)
        end
        for _, m in ipairs(WhoDoesWhat.RaidTargetMarkers) do
            AddToggle(m.index, MarkerMarkup(m.index, 14) .. " " .. m.name)
        end
        K.AddDropdownDivider(level)
        AddToggle("all", "Everything else")
        -- Custom closes the menu so the freed text box can take focus.
        AddToggle("custom", "|T" .. K.CUSTOM_TARGET_ICON .. ":14:14:0:0|t Custom...", true)
    end)
    row.markerDD = markerDD

    -- Mail at the far right so it lines up with every section's mail column.
    row.mailBtn = K.CreateMailButton(row, function()
        local entry = Entry()
        if entry and entry.player then
            return entry.player,
                SECTION.whisperLead .. PlayerEntriesText(SECTION, entry.player, TargetChatText),
                SECTION.whisperLead .. PlayerEntriesText(SECTION, entry.player, TargetPlainText)
        end
    end)
    row.mailBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    -- Warning (!) left of mail; anchored off the button rather than the row
    -- so it holds its column while hidden and nothing shifts.
    local warn = K.CreateWarningIcon(row)
    warn:SetPoint("RIGHT", row.mailBtn, "LEFT", -4, 0)
    row.warnIcon = warn

    -- Custom target text, shown only while "custom" is among the markers.
    -- Saves as it's typed; refreshes never clobber it while it has focus.
    local customEdit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    customEdit:SetHeight(18)
    customEdit:SetPoint("LEFT", markerDD, "RIGHT", -8, 2)
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

    -- Read-only stand-in for the whole widget strip (Permissions.lua).
    local roText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    roText:SetPoint("LEFT", row, "LEFT", 4, 0)
    roText:SetPoint("RIGHT", warn, "LEFT", -6, 0)
    roText:SetJustifyH("LEFT")
    roText:Hide()
    row.roText = roText

    state.rows[index] = row
    return row
end

function Refresh(f) -- forward declared above
    local state = f.tankSection
    local editable = WhoDoesWhat:CanEditAssignments()
    -- Reconcile the rows to the marked-tank roster before painting.
    EnsureAutoRows(SECTION)
    local entries = GetEntries(SECTION)

    for i, entry in ipairs(entries) do
        local row = state.rows[i] or CreateRow(f, i)
        row:Show()

        row.playerLabel:SetShown(editable)
        row.playerLabel:SetText(PlayerTextWithRole(entry.player))
        row.arrowLabel:SetShown(editable)
        row.roText:SetText(PlayerText(entry.player) .. " -> " .. MarkersRichText(entry))
        row.roText:SetShown(not editable)

        -- The marker box grows with its icons; set width before text.
        row.markerDD:SetShown(editable)
        UIDropDownMenu_SetWidth(row.markerDD, MarkerDDWidth(entry))
        UIDropDownMenu_SetText(row.markerDD, TargetText(entry))

        if editable and HasMarkerValue(entry, "custom") then
            if not row.customEdit:HasFocus() then
                row.customEdit:SetText(entry.custom or "")
            end
            row.customEdit:Show()
        else
            row.customEdit:ClearFocus()
            row.customEdit:Hide()
        end

        local warning = SECTION.GetWarning(entry)
        -- A row with nobody on it only warns the people who could fix it.
        if not editable and not entry.player then
            warning = nil
        end
        row.warnIcon.tooltipText = warning
        row.warnIcon:SetShown(warning ~= nil)

        local hasJob = EntryHasJob(SECTION, entry)
        row.mailBtn:SetShown(editable)
        row.mailBtn:SetEnabled(hasJob)
        row.mailBtn.icon:SetDesaturated(not hasJob)
    end
    for i = #entries + 1, #state.rows do
        state.rows[i]:Hide()
    end

    state.emptyHint:SetShown(#entries == 0)
    state.resetBtn:SetShown(editable)
    K.LayoutHeaderChain(state.headerChain)

    local rowsH = (#entries > 0) and (#entries * K.ROW_H) or K.DYN_EMPTY_H
    state.box:SetHeight(K.BOX_PAD + K.SECTION_TITLE_H + rowsH + K.BOX_PAD)
    K.UpdateHeaderMailButtons(f)
    K.UpdateContentHeight(f)
end

local function Build(f, content)
    local chrome = K.CreateSectionChrome(f, content, {
        title = SECTION.title,
        column = K.COL_LEFT,
        mailCollect = A.CollectTankWhispers,
    })

    -- Header "Reset": stock marker layout, behind a confirm popup. A reset
    -- moves misdirect markers too, so it ends in a full window refresh.
    local resetBtn = K.AddHeaderTextButton(chrome.box, chrome.mailBtn, "Reset",
        "Reset " .. SECTION.title,
        "Rebuild the rows from the marked tanks with default markers,"
        .. " skull-first (Skull, Cross, Square, ...): a feral tank leads on"
        .. " Skull, and a paladin tank slots third on Everything else.",
        function()
            StaticPopup_Hide("WHODOESWHAT_RESET_SECTION") -- re-arm for this section
            StaticPopup_Show("WHODOESWHAT_RESET_SECTION", SECTION.noun .. "s", nil,
                function()
                    A.ResetTankAssignments()
                    WhoDoesWhat:RefreshMainAssignmentsView()
                end)
        end) -- hidden without edit permission
    K.ChainHeaderButton(chrome, resetBtn)

    local hint = K.CreateEmptyHint(chrome.box)
    hint:SetText("No tanks marked yet - assign tank roles from the unit right-click menu.")

    f.tankSection = {
        box = chrome.box,
        headerChain = chrome.headerChain,
        resetBtn = resetBtn,
        emptyHint = hint,
        rows = {},
    }
end

WhoDoesWhat.SectionViews.Tank = { Build = Build, Refresh = Refresh }
