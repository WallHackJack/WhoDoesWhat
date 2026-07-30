local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Tank Assignments section: one row per marked tank, auto-managed from the
-- roster (EnsureAutoRows) -- no Add, the player cell is a fixed label,
-- and the marker dropdown is a multi-select so one tank holds all their
-- markers (entry.markers) on a single row:
--
--   [tank]  ->  [markers v] [custom text] (!) [mail] [x]
--
-- Marker toggles route through the unit-menu setters (SetTankMarkerPlayer /
-- RemoveTankMarker, AssignmentsActions.lua), which enforce one-tank-per-
-- marker and pull the misdirects along; they end in a full window refresh,
-- so this file never repaints other sections itself. The header [x] clears
-- every marker assignment while the scanned tank rows remain auto-populated.

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit

local GetEntries = A.GetEntries
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
    playerLabel:SetWidth(K.NAME_LABEL_W)
    playerLabel:SetJustifyH("LEFT")
    row.playerLabel = playerLabel

    local arrowLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    arrowLabel:SetPoint("LEFT", playerLabel, "RIGHT", -10, 0)
    arrowLabel:SetText("->")
    row.arrowLabel = arrowLabel

    -- Multi-select marker dropdown: selecting a new option closes the menu;
    -- deselecting a checked option leaves it open. UIDropDownMenu carries
    -- ~15px of transparent padding per side, hence the negative anchors.
    local markerDD = CreateFrame("Frame", "WhoDoesWhattankMarkerDD" .. index, row, "UIDropDownMenuTemplate")
    markerDD:SetPoint("LEFT", arrowLabel, "RIGHT", -12, -2)
    UIDropDownMenu_SetWidth(markerDD, K.MARKER_DD_WIDTH)
    K.LeftAlignDropdown(markerDD)
    UIDropDownMenu_Initialize(markerDD, function(_, level)
        local entry = Entry()
        if not entry then return end
        local function AddToggle(value, text)
            local selected = HasMarkerValue(entry, value)
            local info = UIDropDownMenu_CreateInfo()
            info.text = text
            info.isNotRadio = true
            info.keepShownOnClick = selected
            info.checked = selected
            info.func = function()
                if HasMarkerValue(entry, value) then
                    WhoDoesWhat:RemoveTankMarker(value)
                else
                    WhoDoesWhat:SetTankMarkerPlayer(value, entry.player)
                    if value == "custom" then row.customEdit:SetFocus() end
                    CloseDropDownMenus()
                end
            end
            UIDropDownMenu_AddButton(info, level)
        end
        for _, m in ipairs(WhoDoesWhat.RaidTargetMarkers) do
            AddToggle(m.index, MarkerMarkup(m.index, 14) .. " " .. m.name)
        end
        K.AddDropdownDivider(level)
        AddToggle("all", "Everything else")
        AddToggle("custom", "|T" .. K.CUSTOM_TARGET_ICON .. ":14:14:0:0|t Custom...")
    end)
    row.markerDD = markerDD

    -- Clear this tank's markers without removing its auto-populated row.
    local clearBtn = K.CreateCloseButton(row)
    clearBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    clearBtn:SetScript("OnClick", function()
        local entry = Entry()
        if entry then WhoDoesWhat:ClearTankMarkers(entry.player) end
    end)
    clearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self:IsEnabled() and "Clear this tank assignment"
            or "Nothing to clear", self:IsEnabled() and 1 or 0.6,
            self:IsEnabled() and 1 or 0.6, self:IsEnabled() and 1 or 0.6)
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.clearBtn = clearBtn

    -- Mail sits immediately left of the row [x], matching the CC rows.
    row.mailBtn = K.CreateMailButton(row, function()
        local entry = Entry()
        if entry and entry.player then
            return entry.player,
                SECTION.whisperLead .. PlayerEntriesText(SECTION, entry.player, TargetChatText),
                SECTION.whisperLead .. PlayerEntriesText(SECTION, entry.player, TargetPlainText)
        end
    end)
    row.mailBtn:SetPoint("RIGHT", clearBtn, "LEFT", -2, 0)

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
    local entries = GetEntries(SECTION)

    local hasAssignments = false
    for i, entry in ipairs(entries) do
        local row = state.rows[i] or CreateRow(f, i)
        row:Show()
        if #(entry.markers or {}) > 0 then hasAssignments = true end

        row.playerLabel:SetShown(editable)
        row.playerLabel:SetText(PlayerTextWithRole(entry.player, 16))
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

        -- View-only users cannot fix tank assignments, so hide their warnings.
        local warning = editable and SECTION.GetWarning(entry) or nil
        row.warnIcon.tooltipText = warning
        row.warnIcon:SetShown(warning ~= nil)

        local hasJob = EntryHasJob(SECTION, entry)
        row.clearBtn:SetShown(editable)
        row.clearBtn:SetEnabled(hasJob)
        row.mailBtn:SetShown(editable)
        row.mailBtn:SetEnabled(hasJob)
        row.mailBtn.icon:SetDesaturated(not hasJob)
    end
    for i = #entries + 1, #state.rows do
        state.rows[i]:Hide()
    end

    state.emptyHint:SetShown(#entries == 0)
    state.clearBtn:SetShown(editable)
    state.clearBtn:SetEnabled(hasAssignments)
    K.LayoutHeaderChain(state.headerChain)

    local rowsH = (#entries > 0) and (#entries * K.ROW_H) or K.DYN_EMPTY_H
    state.box:SetHeight(K.BOX_PAD + K.SECTION_TITLE_H + rowsH + K.BOX_PAD)
    K.UpdateHeaderMailButtons(f)
    K.UpdateContentHeight(f)
end

local function Build(f, content)
    local chrome = K.CreateSectionChrome(f, content, {
        title = SECTION.title,
        column = K.COL_RIGHT,
        mailCollect = A.CollectTankWhispers,
    })

    -- Header [x]: clear every dropdown back to its empty default, behind the
    -- shared clear-all confirmation. Scanned tank rows repopulate on refresh.
    local clearBtn = K.CreateCloseButton(chrome.box, nil, 0.25)
    clearBtn:SetPoint("RIGHT", chrome.mailBtn, "LEFT", -2, 0)
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Hide("WHODOESWHAT_CLEAR_SECTION") -- re-arm for this section
        StaticPopup_Show("WHODOESWHAT_CLEAR_SECTION", SECTION.noun .. "s", nil,
            function()
                A.ClearTankAssignments()
                A.ReconcileRosterAssignments()
                WhoDoesWhat:RefreshMainAssignmentsView()
            end)
    end)
    clearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self:IsEnabled() then
            GameTooltip:SetText("Clear tank assignments", 1, 1, 1)
            GameTooltip:AddLine("Clear every tank's marker dropdown back to default (asks first).",
                0.8, 0.8, 0.8, true)
        else
            GameTooltip:SetText("Nothing to clear", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    table.insert(chrome.headerChain, 1, clearBtn)

    local hint = K.CreateEmptyHint(chrome.box)
    hint:SetText("No tanks marked yet - assign tank roles from the unit right-click menu.")

    f.tankSection = {
        box = chrome.box,
        headerChain = chrome.headerChain,
        clearBtn = clearBtn,
        emptyHint = hint,
        rows = {},
    }
end

WhoDoesWhat.SectionViews.Tank = { Build = Build, Refresh = Refresh }
