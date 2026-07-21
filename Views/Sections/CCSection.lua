local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- CC Assignments section: user-grown rows added with the header's "Add (+)"
-- and removed with each row's [x] (or the header X clear-all, behind a
-- confirm popup):
--
--   [player v] ([spell v]) -> [marker v] [custom text] (!) [x] [mail]
--
-- The spell dropdown offers what the assigned player's class can cast (the
-- full list while unassigned, so a fight can be planned before the raid
-- fills); reassigning to an incompatible class clears the spell.
--
-- NOTE: this is the TEMPLATE for future user-grown sections (healer
-- assignments, fully custom assignments, ...). To add one: give it a model
-- def in Assignments.lua (key/title/store/noun/whisperLead + GetWarning), a
-- db store + sync slot, copy this file, strip the spell dropdown if the new
-- section doesn't need one, and register the Build/Refresh pair on
-- WhoDoesWhat.SectionViews + the main view's build order.

local A = WhoDoesWhat.Assign
local K = WhoDoesWhat.SectionKit

local GetEntries = A.GetEntries
local EntryText = A.EntryText
local EntryHasJob = A.EntryHasJob
local FindMember = A.FindMember
local PlayerText = A.PlayerText
local PlayerTextWithRole = A.PlayerTextWithRole
local PlayerEntriesText = A.PlayerEntriesText
local TargetText = A.TargetText
local TargetChatText = A.TargetChatText
local TargetPlainText = A.TargetPlainText
local SpellText = A.SpellText
local SpellById = A.SpellById
local SpellsForEntry = A.SpellsForEntry
local ClearSpellIfUncastable = A.ClearSpellIfUncastable
local FirstUnusedMarker = A.FirstUnusedMarker
local MarkerMarkup = A.MarkerMarkup

local SECTION = A.SectionByKey("cc")

local Refresh -- forward declared; row callbacks repaint through it

-- Members of the picked spell's class float to the top of the player list.
local function PrefersSpellClass(m, entry)
    local spell = SpellById(entry.spell)
    return spell ~= nil and m.classInfo.name == spell.class
end

-- One entry as a read-only line: player (spell) -> target, same vocabulary
-- as the editable widgets it replaces.
local function ReadOnlyText(entry)
    local target
    if entry.marker == "custom" then
        target = (entry.custom and entry.custom ~= "") and entry.custom
            or ("|T" .. K.CUSTOM_TARGET_ICON .. ":14:14:0:0|t Custom")
    else
        target = TargetText(entry) -- marker icon
    end
    local text = PlayerText(entry.player)
    local spell = SpellById(entry.spell)
    if spell then
        text = text .. " (" .. SpellText(spell) .. ")"
    end
    return text .. " -> " .. target
end

-- Build pooled row #index. The row position is fixed; Refresh maps entry
-- data onto it (and hides surplus rows), so every callback looks its entry
-- up by index at click time.
local function CreateRow(f, index)
    local state = f.ccSection
    local row = K.CreateSectionRow(state.box, index)
    local function Entry() return GetEntries(SECTION)[index] end

    -- UIDropDownMenu carries ~15px of transparent padding each side, so the
    -- frame hangs left of the row to land its visible box at the same x=4
    -- other sections start on. Everything to the right anchors off it.
    local playerDD = CreateFrame("Frame", "WhoDoesWhatccPlayerDD" .. index, row, "UIDropDownMenuTemplate")
    playerDD:SetPoint("LEFT", row, "LEFT", -11, -2)
    UIDropDownMenu_SetWidth(playerDD, K.DYN_PLAYER_DD_WIDTH)
    K.LeftAlignDropdown(playerDD)
    UIDropDownMenu_Initialize(playerDD, function(_, level)
        local entry = Entry()
        if not entry then return end
        K.AddPlayerMenuItems(level, nil,
            function(m) return PrefersSpellClass(m, entry) end,
            entry.player,
            function(name)
                ClearSpellIfUncastable(entry, name)
                entry.player = name
                if name then
                    WhoDoesWhat:Print(SECTION.title .. ": " .. name .. " -> "
                        .. EntryText(SECTION, entry, TargetPlainText) .. ".")
                else
                    WhoDoesWhat:Print(SECTION.title .. ": assignment cleared.")
                end
                Refresh(f)
            end)
    end)
    row.playerDD = playerDD

    -- Spell picker. The list is class-ordered, so a divider on each class
    -- change keeps a long list scannable.
    local spellDD = CreateFrame("Frame", "WhoDoesWhatccSpellDD" .. index, row, "UIDropDownMenuTemplate")
    spellDD:SetPoint("LEFT", playerDD, "RIGHT", -18, 0)
    UIDropDownMenu_SetWidth(spellDD, K.DYN_SPELL_DD_WIDTH)
    K.LeftAlignDropdown(spellDD)
    UIDropDownMenu_Initialize(spellDD, function(_, level)
        local entry = Entry()
        if not entry then return end

        local spells = SpellsForEntry(SECTION, entry)
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
                K.AddDropdownDivider(level)
            end
            lastClass = spell.class
            local info = UIDropDownMenu_CreateInfo()
            info.text = SpellText(spell)
            info.checked = (entry.spell == spell.id)
            info.func = function()
                entry.spell = spell.id
                Refresh(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    row.spellDD = spellDD

    local arrowLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    -- The +2 y compensates for the dropdown-frame anchor sitting at y=-2.
    arrowLabel:SetPoint("LEFT", spellDD, "RIGHT", -10, 2)
    arrowLabel:SetText("->")
    row.arrowLabel = arrowLabel -- hidden with the dropdowns in read-only mode

    -- Single-marker radio dropdown: the eight markers plus Custom. No
    -- "Everything else" here -- CC lands on one target.
    local markerDD = CreateFrame("Frame", "WhoDoesWhatccMarkerDD" .. index, row, "UIDropDownMenuTemplate")
    markerDD:SetPoint("LEFT", arrowLabel, "RIGHT", -12, -2)
    UIDropDownMenu_SetWidth(markerDD, K.MARKER_DD_WIDTH)
    K.LeftAlignDropdown(markerDD)
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
                Refresh(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end

        K.AddDropdownDivider(level)

        local info = UIDropDownMenu_CreateInfo()
        info.text = "|T" .. K.CUSTOM_TARGET_ICON .. ":14:14:0:0|t Custom..."
        info.checked = (entry.marker == "custom")
        info.func = function()
            entry.marker = "custom"
            Refresh(f)
            row.customEdit:SetFocus()
        end
        UIDropDownMenu_AddButton(info, level)
    end)
    row.markerDD = markerDD

    -- Right-hand controls, left to right: (!) [x] [mail]. Mail sits at the
    -- far right so it lines up with every section's mail column.
    row.mailBtn = K.CreateMailButton(row, function()
        local entry = Entry()
        if entry and entry.player then
            return entry.player,
                SECTION.whisperLead .. PlayerEntriesText(SECTION, entry.player, TargetChatText),
                SECTION.whisperLead .. PlayerEntriesText(SECTION, entry.player, TargetPlainText)
        end
    end)
    row.mailBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    delBtn:SetSize(K.MAIL_BTN_SIZE, K.MAIL_BTN_SIZE)
    delBtn:SetPoint("RIGHT", row.mailBtn, "LEFT", -2, 0)
    delBtn:SetText("x")
    delBtn:SetScript("OnClick", function()
        table.remove(GetEntries(SECTION), index)
        WhoDoesWhat:Print(SECTION.title .. ": " .. SECTION.noun .. " removed.")
        Refresh(f)
    end)
    delBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove this assignment", 1, 1, 1)
        GameTooltip:Show()
    end)
    delBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.delBtn = delBtn

    -- Warning (!) left of the buttons. Anchored off [x] rather than the row,
    -- so it holds its column while hidden and nothing shifts as warnings
    -- come and go.
    local warn = K.CreateWarningIcon(row)
    warn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
    row.warnIcon = warn

    -- Custom target text, shown only while the marker dropdown is on Custom.
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
    local state = f.ccSection
    local editable = WhoDoesWhat:CanEditAssignments()
    local entries = GetEntries(SECTION)

    for i, entry in ipairs(entries) do
        local row = state.rows[i] or CreateRow(f, i)
        row:Show()

        -- Edit widgets or the read-only line, never both (Permissions.lua).
        row.arrowLabel:SetShown(editable)
        row.roText:SetText(ReadOnlyText(entry))
        row.roText:SetShown(not editable)
        row.delBtn:SetShown(editable)

        row.playerDD:SetShown(editable)
        UIDropDownMenu_SetText(row.playerDD, PlayerTextWithRole(entry.player))
        row.spellDD:SetShown(editable)
        UIDropDownMenu_SetText(row.spellDD, SpellText(SpellById(entry.spell)))
        row.markerDD:SetShown(editable)
        UIDropDownMenu_SetText(row.markerDD, TargetText(entry))

        if editable and entry.marker == "custom" then
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

    state.emptyHint:SetText(editable
        and ("No " .. SECTION.noun .. "s yet - click Add (+) to add one.")
        or ("No " .. SECTION.noun .. "s yet."))
    state.emptyHint:SetShown(#entries == 0)
    state.plusBtn:SetShown(editable)
    state.clearBtn:SetShown(editable)
    state.clearBtn:SetEnabled(#entries > 0)
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
        mailCollect = A.CollectCCWhispers,
    })
    local box = chrome.box

    -- Header "X": empty the whole section, behind a confirm popup. Disabled
    -- (and saying so) while there's nothing to clear.
    local clearBtn = K.CreateHeaderSquareButton(box, "X")
    clearBtn:SetPoint("RIGHT", chrome.mailBtn, "LEFT", -2, 0)
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Hide("WHODOESWHAT_CLEAR_SECTION") -- re-arm for this section
        StaticPopup_Show("WHODOESWHAT_CLEAR_SECTION", SECTION.noun .. "s", nil,
            function()
                wipe(GetEntries(SECTION))
                WhoDoesWhat:Print(SECTION.title .. ": all " .. SECTION.noun .. "s removed.")
                Refresh(f)
            end)
    end)
    clearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self:IsEnabled() then
            GameTooltip:SetText("Clear this section", 1, 1, 1)
            GameTooltip:AddLine("Remove every " .. SECTION.noun .. " (asks first).",
                0.8, 0.8, 0.8, true)
        else
            GameTooltip:SetText("Nothing to clear", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    K.ChainHeaderButton(chrome, clearBtn)

    -- "Add (+)" appends an empty row, starting on the first marker no
    -- sibling row is using yet.
    local plusBtn = K.AddHeaderTextButton(box, clearBtn, "Add (+)",
        "Add a " .. SECTION.noun,
        "Append an empty " .. SECTION.noun .. " row.", function()
            local entries = GetEntries(SECTION)
            entries[#entries + 1] = { marker = FirstUnusedMarker(SECTION), custom = "" }
            WhoDoesWhat:LogUiBuilding("Added " .. SECTION.noun .. " row " .. #entries)
            Refresh(f)
        end) -- hidden without edit permission
    K.ChainHeaderButton(chrome, plusBtn)

    local hint = K.CreateEmptyHint(box)

    f.ccSection = {
        box = box,
        headerChain = chrome.headerChain,
        clearBtn = clearBtn,
        plusBtn = plusBtn,
        emptyHint = hint,
        rows = {},
    }
end

WhoDoesWhat.SectionViews.CC = { Build = Build, Refresh = Refresh }
