local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Misdirect Assignments section: one row per hunter, auto-managed from the
-- roster (EnsureAutoRows) -- no Add/per-row [x], the hunter cell is a fixed label;
-- you only fill in each hunter's tank:
--
--   [hunter]  for  [tank v]  on  [marker v] (!) [mail]
--
-- The marker defaults to (and follows) the tank's first tank-marker -- the
-- setters in AssignmentsActions.lua keep it synced when tank markers move --
-- but stays hand-overridable here. The header [x] clears every misdirect;
-- auto-row reconciliation then restores one blank row per hunter.

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit

local GetEntries = A.GetEntries
local EnsureAutoRows = A.EnsureAutoRows
local EntryHasJob = A.EntryHasJob
local PlayerText = A.PlayerText
local PlayerTextWithRole = A.PlayerTextWithRole
local PlayerEntriesText = A.PlayerEntriesText
local TargetChatText = A.TargetChatText
local TargetPlainText = A.TargetPlainText
local MarkerMarkup = A.MarkerMarkup

local SECTION = A.SectionByKey("md")

local Refresh -- forward declared; row callbacks repaint through it

-- Marked tanks float to the top of the tank picker.
local function PrefersMarkedTank(m)
    return WhoDoesWhat:IsMarkedTank(m.name)
end

-- Build pooled row #index. The row position is fixed; Refresh maps entry
-- data onto it (and hides surplus rows), so every callback looks its entry
-- up by index at click time.
local function CreateRow(f, index)
    local state = f.mdSection
    local row = K.CreateSectionRow(state.box, index)
    local function Entry() return GetEntries(SECTION)[index] end

    -- The row IS its hunter, so a fixed label stands where a picker would be.
    local playerLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    playerLabel:SetPoint("LEFT", row, "LEFT", 4, 0)
    playerLabel:SetWidth(K.NAME_LABEL_W)
    playerLabel:SetJustifyH("LEFT")
    row.playerLabel = playerLabel

    -- Misdirects read "Hunter for Tank on Skull".
    local forLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    forLabel:SetPoint("LEFT", playerLabel, "RIGHT", -10, 0)
    forLabel:SetText("for")
    row.forLabel = forLabel

    -- Tank picker: the whole group, marked tanks floated above a divider,
    -- with the None clearer at the top.
    local targetDD = CreateFrame("Frame", "WhoDoesWhatmdTargetDD" .. index, row, "UIDropDownMenuTemplate")
    targetDD:SetPoint("LEFT", forLabel, "RIGHT", -12, -2)
    UIDropDownMenu_SetWidth(targetDD, K.DYN_PLAYER_DD_WIDTH)
    K.LeftAlignDropdown(targetDD)
    UIDropDownMenu_Initialize(targetDD, function(_, level)
        local entry = Entry()
        if not entry then return end
        K.AddPlayerMenuItems(level, nil, PrefersMarkedTank, entry.target,
            function(name)
                entry.target = name
                -- Default the misdirect's marker to the tank's first marker.
                entry.marker = name and WhoDoesWhat:FirstTankMarker(name) or nil
                Refresh(f)
            end, nil, true)
    end)
    row.targetDD = targetDD

    local onLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    -- The +2 y compensates for the dropdown-frame anchor sitting at y=-2.
    onLabel:SetPoint("LEFT", targetDD, "RIGHT", -10, 2)
    onLabel:SetText("on")
    row.onLabel = onLabel

    -- Marker on the pair (which pull the hunter misdirects on): plain
    -- markers plus None, no "Everything else"/custom here.
    local markerDD = CreateFrame("Frame", "WhoDoesWhatmdTargetMarkerDD" .. index, row, "UIDropDownMenuTemplate")
    markerDD:SetPoint("LEFT", onLabel, "RIGHT", -12, -2)
    UIDropDownMenu_SetWidth(markerDD, K.MARKER_DD_WIDTH)
    K.LeftAlignDropdown(markerDD)
    UIDropDownMenu_Initialize(markerDD, function(_, level)
        local entry = Entry()
        if not entry then return end
        for _, m in ipairs(WhoDoesWhat.RaidTargetMarkers) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = MarkerMarkup(m.index, 14) .. " " .. m.name
            info.checked = (entry.marker == m.index)
            info.func = function()
                entry.marker = m.index
                Refresh(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
        K.AddDropdownDivider(level)
        local info = UIDropDownMenu_CreateInfo()
        info.text = "None"
        info.checked = (entry.marker == nil)
        info.func = function()
            entry.marker = nil
            Refresh(f)
        end
        UIDropDownMenu_AddButton(info, level)
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
    local state = f.mdSection
    local editable = WhoDoesWhat:CanEditAssignments()
    -- Reconcile the rows to the hunter roster before painting.
    EnsureAutoRows(SECTION)
    local entries = GetEntries(SECTION)

    local hasAssignments = false
    for i, entry in ipairs(entries) do
        local row = state.rows[i] or CreateRow(f, i)
        row:Show()
        if entry.target or entry.marker then hasAssignments = true end

        row.playerLabel:SetShown(editable)
        row.playerLabel:SetText(PlayerTextWithRole(entry.player, 16))
        row.forLabel:SetShown(editable)
        row.onLabel:SetShown(editable)

        local target = PlayerText(entry.target)
        if entry.marker then
            target = target .. " " .. MarkerMarkup(entry.marker, 14)
        end
        row.roText:SetText(PlayerText(entry.player) .. " -> " .. target)
        row.roText:SetShown(not editable)

        row.targetDD:SetShown(editable)
        UIDropDownMenu_SetText(row.targetDD, PlayerTextWithRole(entry.target))
        row.markerDD:SetShown(editable)
        UIDropDownMenu_SetText(row.markerDD, entry.marker
            and MarkerMarkup(entry.marker, 14) or "|cff909090--|r")

        local warning = SECTION.GetWarning(entry)
        -- A row with nobody on it only warns the people who could fix it.
        if not editable and not entry.player then
            warning = nil
        end
        row.warnIcon.tooltipText = warning
        row.warnIcon:SetShown(warning ~= nil)

        -- A misdirect row only has a job to whisper once its tank is picked.
        local hasJob = EntryHasJob(SECTION, entry)
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
        mailCollect = A.CollectMisdirectWhispers,
    })

    -- Header [x]: clear every misdirect behind the shared confirmation;
    -- hunter rows repopulate blank on refresh.
    local clearBtn = K.CreateCloseButton(chrome.box, nil, 0.25)
    clearBtn:SetPoint("RIGHT", chrome.mailBtn, "LEFT", -2, 0)
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Hide("WHODOESWHAT_CLEAR_SECTION") -- re-arm for this section
        StaticPopup_Show("WHODOESWHAT_CLEAR_SECTION", SECTION.noun .. "s", nil,
            function()
                A.ClearMisdirectAssignments()
                Refresh(f)
            end)
    end)
    clearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self:IsEnabled() then
            GameTooltip:SetText("Clear misdirect assignments", 1, 1, 1)
            GameTooltip:AddLine("Clear every misdirect back to default (asks first).",
                0.8, 0.8, 0.8, true)
        else
            GameTooltip:SetText("Nothing to clear", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    table.insert(chrome.headerChain, 1, clearBtn)

    local hint = K.CreateEmptyHint(chrome.box)
    hint:SetText("No hunters in the group.")

    f.mdSection = {
        box = chrome.box,
        headerChain = chrome.headerChain,
        clearBtn = clearBtn,
        emptyHint = hint,
        rows = {},
    }
end

WhoDoesWhat.SectionViews.Misdirect = { Build = Build, Refresh = Refresh }
