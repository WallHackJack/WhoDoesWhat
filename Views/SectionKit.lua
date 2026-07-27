local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Shared widget kit for the main window's assignment sections. Every section
-- (Views/Sections/*.lua) builds its chrome and rows from these primitives so
-- the boxes, header buttons, mail/warning icons and layout math stay
-- identical across sections -- but each section's actual content and refresh
-- logic is hard-coded in its own file, not driven by flags. Nothing here
-- knows what a "tank row" is.
--
-- The `f` passed around is the main window frame (MainAssignmentsView.lua),
-- which carries the shared state the kit needs:
--   f.columns    { [COL_LEFT] = { boxes, x, width }, [COL_RIGHT] = ... }
--   f.headerMail registry of header mass-mail buttons (AddHeaderMailButton)
--   f.content / f.scroll   the scroll child + scroll frame
--
-- Section files register themselves on WhoDoesWhat.SectionViews (Build /
-- Refresh pairs); the main view builds and refreshes them in its fixed order.

WhoDoesWhat.SectionViews = WhoDoesWhat.SectionViews or {}

local A = WhoDoesWhat.Assign
local GetEligibleMembers = A.GetEligibleMembers
local PlayerText = A.PlayerText
local RoleIconMarkup = A.RoleIconMarkup
local MassWhisper = A.MassWhisper

local K = {}
WhoDoesWhat.SectionKit = K

-- ---------------------------------------------------------------------------
-- Geometry + icons, shared so every section box and row lines up
-- ---------------------------------------------------------------------------

K.COL_LEFT, K.COL_RIGHT = 1, 2

K.SECTION_GAP = 10 -- vertical gap between section boxes
K.SECTION_TITLE_H = 22 -- box interior reserved for the title + divider
K.BOX_PAD = 8 -- section box inner margin
K.ROW_H = 32
K.ROW_ICON_SIZE = 22
K.DROPDOWN_WIDTH = 100 -- player picker; sized for a name, not a sentence
K.WARNING_ICON_SIZE = 18
K.MAIL_BTN_SIZE = 22
K.DYN_EMPTY_H = 20 -- rows-area height while a section's row list is empty
-- How far the header button strip's top sits below the box top. The section
-- title centers on this strip too (see CreateSectionChrome), so both move
-- together -- tweak here to nudge the whole header row up/down.
K.HEADER_STRIP_TOP = 3

K.DYN_PLAYER_DD_WIDTH = 100
K.DYN_SPELL_DD_WIDTH = 110
-- Fixed-label name column (tank/misdirect rows, paladin summary). Wider than
-- the player dropdown so a long name plus its role icon clears the following
-- "->" / "for" label instead of overlapping it.
K.NAME_LABEL_W = 120

-- Marker dropdown widths. UIDropDownMenuTemplate anchors its label 7px in
-- from the left and 43px in from the right (the gap houses the arrow button),
-- so ~69px of frame is the floor for showing a 14px icon -- there's no way to
-- get thinner without abandoning the dropdown chrome. The icon-only states
-- sit on that floor; "Everything else" is the one option with no icon to
-- stand in for it, so its box widens to fit the words.
K.MARKER_DD_WIDTH = 44
K.MARKER_DD_WIDE = 95

K.WARNING_ICON = WhoDoesWhat.WARNING_ICON
K.MAIL_ICON = "Interface\\Icons\\INV_Letter_15"
K.CUSTOM_TARGET_ICON = 134400 -- INV_Misc_QuestionMark, our "custom" marker

local paladinColor
for _, classInfo in ipairs(WhoDoesWhat.Classes) do
    if classInfo.name == "Paladin" then
        paladinColor = classInfo.colorRGB
        break
    end
end

-- ---------------------------------------------------------------------------
-- Dropdown helpers
-- ---------------------------------------------------------------------------

-- UIDropDownMenuTemplate right-aligns its collapsed label by default, which
-- leaves player/spell names (and the marker icon) floating against the arrow
-- with dead space on the left. Left-align so the content hugs the left edge,
-- and nudge it down 1px -- the template sits the label a hair high in the box.
function K.LeftAlignDropdown(dd)
    local text = _G[dd:GetName() .. "Text"]
    if text then
        text:SetJustifyH("LEFT")
        text:AdjustPointsOffset(0, -1)
    end
end

function K.AddDropdownDivider(level)
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
--   noneFirst      puts the "None" clearer at the top (misdirect tank picker)
function K.AddPlayerMenuItems(level, class, IsPreferred, saved, OnPick, Annotate, noneFirst)
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

    if noneFirst then
        AddNone()
        if #members > 0 then K.AddDropdownDivider(level) end
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
            K.AddDropdownDivider(level)
        end
    end

    if not noneFirst then
        AddNone()
    end
end

-- ---------------------------------------------------------------------------
-- Small row widgets
-- ---------------------------------------------------------------------------

-- Shared PallyPower badge used by the Overview and Paladin Buffs section.
function K.CreatePallyPowerBadge(parent, size)
    local badge = CreateFrame("Frame", nil, parent)
    badge:SetSize(size or 18, size or 18)
    local bg = badge:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.28, 0.28, 0.3, 1)
    local label = badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("CENTER", 0, 0)
    label:SetText("PP")
    label:SetTextColor(paladinColor.r, paladinColor.g, paladinColor.b)
    return badge
end

-- Matching compact flat-red action button for PallyPower status areas.
function K.CreatePallyPowerActionButton(parent, text, width, tooltipTitle, tooltipText, OnClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width, 16)
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.42, 0.06, 0.09, 1)
    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 0.35, 0.42, 0.18)
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("CENTER", 0, 0)
    label:SetText(text)
    btn:SetScript("OnClick", OnClick)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(tooltipTitle, 1, 1, 1)
        GameTooltip:AddLine(tooltipText, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

-- One source of truth for the PallyPower status text shown in both views.
function K.GetPallyPowerState(paladinCount)
    if paladinCount == 0 then return "inactive", "No Paladins, Inactive" end
    local diffs, reason = WhoDoesWhat:CheckPallyPowerSync()
    if reason == "no-paladins" then return "inactive", "No Paladins, Inactive" end
    if diffs == nil then return "inactive", "PallyPower Not Loaded, Inactive" end
    if #diffs == 0 then return "synced", "Optimized and synced" end
    return "desynced", #diffs .. " buff" .. (#diffs == 1 and "" or "s")
        .. " out of sync"
end

-- Warning (!) icon; the refresh passes set .tooltipText and show/hide it.
-- Hover explains the problem. Starts hidden.
function K.CreateWarningIcon(row)
    local warn = CreateFrame("Frame", nil, row)
    warn:SetSize(K.WARNING_ICON_SIZE, K.WARNING_ICON_SIZE)
    local tex = warn:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture(K.WARNING_ICON)
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
function K.CreateMailButton(row, GetWhisper)
    local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    btn:SetSize(K.MAIL_BTN_SIZE, K.MAIL_BTN_SIZE)
    btn:SetText("")
    btn:SetMotionScriptsWhileDisabled(true) -- tooltip works while disabled
    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(K.MAIL_ICON)
    btn.icon = icon
    btn:SetScript("OnClick", function()
        local name, job, display = GetWhisper()
        if not name then return end
        SendChatMessage("[WhoDoesWhat] Your assignment: " .. job .. ".", "WHISPER", nil, name)
        WhoDoesWhat:LogOperation("Whispered " .. name .. " their assignment: " .. (display or job) .. ".")
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
function K.AddRowDivider(parent, insetX, y)
    local divider = parent:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.3, 0.3, 0.3, 0.5)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", insetX, -y)
    divider:SetPoint("TOPRIGHT", -insetX, -y)
    return divider
end

-- One pooled section row at the standard grid position: full box width, ROW_H
-- tall, row #index sitting under the title strip, with the hairline divider
-- every row after the first carries. The section fills in the widgets.
function K.CreateSectionRow(box, index)
    local row = CreateFrame("Frame", nil, box)
    row:SetFrameLevel(box:GetFrameLevel() + 1)
    row:SetSize(box:GetWidth() - K.BOX_PAD * 2, K.ROW_H)
    row:SetPoint("TOPLEFT", K.BOX_PAD, -(K.BOX_PAD + K.SECTION_TITLE_H + (index - 1) * K.ROW_H))
    if index > 1 then
        K.AddRowDivider(row, 2, 0)
    end
    return row
end

-- Gray hint FontString in the rows area, for a section with nothing to show.
function K.CreateEmptyHint(box)
    local hint = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", K.BOX_PAD + 4, -(K.BOX_PAD + K.SECTION_TITLE_H + 4))
    hint:SetTextColor(0.55, 0.55, 0.55)
    return hint
end

-- ---------------------------------------------------------------------------
-- Section chrome: the box shell + the right-aligned header button strip
-- ---------------------------------------------------------------------------

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
        box:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -K.SECTION_GAP)
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
    title:SetPoint("LEFT", box, "TOPLEFT", K.BOX_PAD + 2,
        -(K.HEADER_STRIP_TOP + K.MAIL_BTN_SIZE / 2))
    title:SetText(titleText)
    box.title = title -- sections gray it when they disable themselves

    -- The divider sits right under the header buttons (22px from y -6), so
    -- the rows can start immediately below without dead space.
    local line = box:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", K.BOX_PAD, -(K.BOX_PAD + 20))
    line:SetPoint("TOPRIGHT", -K.BOX_PAD, -(K.BOX_PAD + 20))

    col.boxes[#col.boxes + 1] = box
    return box
end

-- The mass-mail button in a section box's title strip. Yourself is filtered
-- out of the collection (not just the send): whispering yourself is noise,
-- and this way the tooltip, the enabled state and the sent count all tell
-- the same story. Registered on f.headerMail so UpdateHeaderMailButtons can
-- keep the enabled state honest on every refresh.
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
    btn:SetSize(K.MAIL_BTN_SIZE, K.MAIL_BTN_SIZE)
    btn:SetPoint("TOPRIGHT", -K.BOX_PAD, -K.HEADER_STRIP_TOP)
    btn:SetText("")
    btn:SetMotionScriptsWhileDisabled(true) -- tooltip works while disabled
    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(K.MAIL_ICON)
    btn.icon = icon

    btn:SetScript("OnClick", function()
        local sent = MassWhisper(CollectOthers())
        if sent > 0 then
            WhoDoesWhat:LogOperation(sectionTitle .. ": whispered " .. sent
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

-- Show/hide every header mail button on edit permission, WITHOUT running the
-- collectors (some are expensive -- the paladin one recomputes the buff
-- grid). The refresh coordinator runs this before the sections refresh, so
-- each section lays out its header chain against settled mail visibility.
function K.UpdateHeaderMailVisibility(f)
    local editable = WhoDoesWhat:CanEditAssignments()
    for _, hm in ipairs(f.headerMail) do
        hm.btn:SetShown(editable)
    end
end

-- Enable/desaturate every header mail button from its current collection.
-- Hidden outright without edit permission -- mass-whispering the raid their
-- jobs is the coordinator's move, and a dead button would just clutter the
-- read-only board.
function K.UpdateHeaderMailButtons(f)
    local editable = WhoDoesWhat:CanEditAssignments()
    for _, hm in ipairs(f.headerMail) do
        local n = #hm.Collect()
        hm.btn:SetShown(editable)
        hm.btn:SetEnabled(n > 0)
        hm.btn.icon:SetDesaturated(n == 0)
    end
end

-- Small text button in a section's title strip (Auto, Reset, Add (+), ...),
-- provisionally chained left of anchorTo -- LayoutHeaderChain re-anchors on
-- every refresh. The tooltip swaps its body for btn.disabledReason while the
-- button is disabled, so a dead button explains itself.
function K.AddHeaderTextButton(box, anchorTo, text, tooltipTitle, tooltipText, OnClick)
    local btn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    btn:SetFrameLevel(box:GetFrameLevel() + 1)
    btn:SetHeight(K.MAIL_BTN_SIZE) -- same strip height as the mail/X buttons
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

-- The window's round red close button (UIPanelCloseButton -- same as the title
-- bar's), for the small delete / clear-all "x" controls so they match the
-- window's close button. The caller wires the click and tooltip scripts.
-- MotionScriptsWhileDisabled keeps the tooltip alive for the clear-all's
-- disabled ("nothing to clear") state.
--
-- The frame stays MAIL_BTN_SIZE so header and row X's line up with the mail
-- column. UIPanelCloseButton's texture is mostly transparent padding around a
-- small X, so we grow the textures past the frame -- the visible X fills the
-- button's footprint (a bolder X, little apparent left/right padding) without
-- changing the layout size.
function K.CreateCloseButton(parent, size, growFactor)
    local s = size or K.MAIL_BTN_SIZE
    local btn = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    btn:SetFrameLevel(parent:GetFrameLevel() + 1)
    btn:SetSize(s, s)
    btn:SetMotionScriptsWhileDisabled(true)
    local grow = s * (growFactor or 0.3)
    for _, tex in ipairs({ btn:GetNormalTexture(), btn:GetPushedTexture(),
        btn:GetHighlightTexture(), btn:GetDisabledTexture() }) do
        if tex then
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", -grow, grow)
            tex:SetPoint("BOTTOMRIGHT", grow, -grow)
        end
    end
    return btn
end

-- Re-anchor a section's header buttons right-to-left, skipping hidden ones,
-- so the rightmost VISIBLE button hugs the box corner -- the mail button
-- (and edit-only buttons like Add/X/Reset) hide in read-only mode and would
-- otherwise leave a hole at the right edge. Chains are stored rightmost-
-- first; run after every visibility change.
function K.LayoutHeaderChain(chain)
    local prev
    for _, btn in ipairs(chain) do
        if btn:IsShown() then
            btn:ClearAllPoints()
            if prev then
                -- -2 matches the rows' x/mail gap, so the columns line up.
                btn:SetPoint("RIGHT", prev, "LEFT", -2, 0)
            else
                btn:SetPoint("TOPRIGHT", btn:GetParent(), "TOPRIGHT", -K.BOX_PAD, -K.HEADER_STRIP_TOP)
            end
            prev = btn
        end
    end
end

-- Build a section's standard chrome in one call: the box shell plus the
-- header strip, with the section's extra buttons injected right-aligned.
--   opts.title       box title
--   opts.column      K.COL_LEFT / K.COL_RIGHT
--   opts.mailCollect optional whisper collector; adds the header mail button
-- Returns { box, mailBtn, headerChain }. headerChain starts with the mail
-- button (rightmost); sections append their own buttons with ChainHeaderButton
-- in right-to-left order and call LayoutHeaderChain on refresh.
function K.CreateSectionChrome(f, content, opts)
    WhoDoesWhat:LogUiBuilding("Building assignment section: " .. opts.title)
    local box = CreateSectionBox(f, content, opts.title, opts.column)
    local chrome = { box = box, headerChain = {} }
    if opts.mailCollect then
        chrome.mailBtn = AddHeaderMailButton(f, box, opts.title, opts.mailCollect)
        chrome.headerChain[1] = chrome.mailBtn
    end
    return chrome
end

function K.ChainHeaderButton(chrome, btn)
    chrome.headerChain[#chrome.headerChain + 1] = btn
    return btn
end

-- ---------------------------------------------------------------------------
-- Scroll-height bookkeeping + shared confirm popups
-- ---------------------------------------------------------------------------

-- Recompute the scroll child's height from the taller column (section boxes
-- grow and shrink with their rows) and refresh the scroll range. Hidden boxes
-- (the Paladin-only view hides all but one) don't count toward the height.
function K.UpdateContentHeight(f)
    local tallest = 0
    for _, col in ipairs(f.columns) do
        local h = 0
        for _, box in ipairs(col.boxes) do
            if box:IsShown() then
                h = h + box:GetHeight() + K.SECTION_GAP
            end
        end
        tallest = math.max(tallest, h)
    end
    f.content:SetHeight(math.max(tallest, 1))
    f.scroll:UpdateScrollChildRect()
end

-- Re-anchor each column's VISIBLE section boxes top-to-bottom, chaining each to
-- the previous visible box's bottom so a hidden box (Paladin-only view) leaves
-- no gap. Idempotent -- in the full view it reproduces CreateSectionBox's own
-- anchor chain. Run whenever box visibility might have changed.
function K.LayoutColumnBoxes(f)
    for _, col in ipairs(f.columns) do
        local prev
        for _, box in ipairs(col.boxes) do
            if box:IsShown() then
                box:ClearAllPoints()
                if prev then
                    box:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -K.SECTION_GAP)
                else
                    box:SetPoint("TOPLEFT", f.content, "TOPLEFT", col.x, 0)
                end
                prev = box
            end
        end
    end
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

-- Reset-a-section confirm, same shape as the clear-all dialog.
StaticPopupDialogs["WHODOESWHAT_RESET_SECTION"] = {
    text = "Reset all %s to their defaults?",
    button1 = "Reset",
    button2 = "Cancel",
    OnAccept = function(self) self.data() end,
    timeout = 0,
    hideOnEscape = true,
    preferredIndex = 3,
}
