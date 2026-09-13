local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI

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

K.ROW_ICON_SIZE = 20
K.DROPDOWN_ICON_SIZE = 14
K.DROPDOWN_WIDTH = 100 -- player picker; sized for a name, not a sentence

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

K.MAIL_ICON = "Interface\\Icons\\INV_Letter_15"
K.CUSTOM_TARGET_ICON = 134400 -- INV_Misc_QuestionMark, our "custom" marker
K.PALADIN_GRID_COL_W = 26
K.PALADIN_GRID_CELL_SIZE = 20
K.PALADIN_GRID_LOCAL_GAP = 8

local classColors = {}
for _, classInfo in ipairs(WhoDoesWhat.Classes) do
    classColors[classInfo.name] = classInfo.colorRGB
end
local paladinColor = classColors.Paladin

local function PaladinName(paladin)
    return type(paladin) == "table" and paladin.name or paladin
end

local function ShortName(name)
    return name and name:match("^([^%-]+)") or name
end

-- Shared geometry and cells for every paladin-buff grid. The local paladin is
-- always first, followed by a small visual break from the remaining columns.
function K.IsLocalPaladin(paladin)
    local name, player = ShortName(PaladinName(paladin)), ShortName(UnitName("player"))
    return name ~= nil and player ~= nil and name == player
end

function K.OrderPaladinsLocalFirst(paladins)
    local ordered, localIndex = {}
    for i, paladin in ipairs(paladins or {}) do
        ordered[i] = paladin
        if K.IsLocalPaladin(paladin) then localIndex = i end
    end
    if localIndex and localIndex > 1 then
        table.insert(ordered, 1, table.remove(ordered, localIndex))
    end
    return ordered
end

function K.PaladinColumnOffset(index, paladins, columnWidth)
    local width = columnWidth or K.PALADIN_GRID_COL_W
    local localFirst = paladins and paladins[1] and K.IsLocalPaladin(paladins[1])
    return (index - 1) * width
        + (localFirst and index > 1 and K.PALADIN_GRID_LOCAL_GAP or 0)
end

function K.PaladinColumnsWidth(paladins, columnWidth, minimumColumns)
    local width = columnWidth or K.PALADIN_GRID_COL_W
    local count = math.max(#(paladins or {}), minimumColumns or 1)
    local localFirst = paladins and paladins[1] and K.IsLocalPaladin(paladins[1])
    return count * width + (localFirst and count > 1 and K.PALADIN_GRID_LOCAL_GAP or 0)
end

function K.CreateLocalPaladinStripe(parent)
    local stripe = parent:CreateTexture(nil, "BACKGROUND")
    stripe:SetColorTexture(0.72, 0.72, 0.72, 0.14)
    stripe:Hide()
    return stripe
end

function K.CreatePaladinGridHeader(parent)
    local header = CreateFrame("Button", nil, parent)
    header:SetSize(K.PALADIN_GRID_CELL_SIZE, K.PALADIN_GRID_CELL_SIZE)
    local icon = header:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    header.icon = icon
    local initial = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    initial:SetPoint("CENTER")
    local font, size = initial:GetFont()
    if font then initial:SetFont(font, size + 1, "OUTLINE") end
    header.initial = initial
    return header
end

function K.CreatePaladinBuffCell(parent, size)
    size = size or K.PALADIN_GRID_CELL_SIZE
    local cell = CreateFrame("Button", nil, parent)
    cell:SetSize(size, size)

    local alert = CreateFrame("Frame", nil, cell, "BackdropTemplate")
    alert:SetAllPoints()
    alert:SetFrameLevel(cell:GetFrameLevel() + 1)
    alert:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 2,
    })
    alert:SetBackdropBorderColor(1, 0.05, 0.05, 1)
    alert:Hide()
    cell.alert = alert

    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetSize(size - 2, size - 2)
    icon:SetPoint("CENTER")
    cell.icon = icon
    return cell
end

function K.SetPaladinBuffCell(cell, buffPlan, raider, paladin)
    local paladinName = PaladinName(paladin)
    local cells = buffPlan and buffPlan.grid and buffPlan.grid[raider]
    local buffKey = cells and cells[paladinName]
    cell.buffKey = buffKey
    cell.isGreater = nil
    if not buffKey then
        cell.icon:Hide()
        return nil
    end

    local buff = WhoDoesWhat.PaladinBuffs[buffKey]
    local greater = buffPlan.greaterByPaladin
        and buffPlan.greaterByPaladin[paladinName]
    cell.isGreater = greater
        and greater[buffPlan.targetClass and buffPlan.targetClass[raider]] == buffKey
    cell.icon:SetTexture(cell.isGreater and buff.icon or buff.normalIcon)
    cell.icon:Show()
    return buffKey
end

-- ---------------------------------------------------------------------------
-- Dropdown helpers
-- ---------------------------------------------------------------------------

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
        if #members > 0 then UI.AddDropdownDivider(level) end
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
        info.text = RoleIconMarkup(name, K.DROPDOWN_ICON_SIZE)
            .. "|cff" .. m.classInfo.colorHex .. name .. "|r"
            .. (note and (" " .. note) or "")
        info.checked = (saved == name)
        info.func = function() OnPick(name) end
        UIDropDownMenu_AddButton(info, level)
        if i == dividerAfter then
            UI.AddDropdownDivider(level)
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

-- One source of truth for the PallyPower status text shown in both views.
function K.GetPallyPowerState(paladinCount)
    if paladinCount == 0 then return "inactive", "No Paladins, Inactive" end
    local diffs, reason, unoptimized = WhoDoesWhat:CheckPallyPowerSync()
    if reason == "no-paladins" then return "inactive", "No Paladins, Inactive" end
    local ppMode = WhoDoesWhat.db.profile.settings.pallyBuffSource == "pallypower"
    local count = ppMode and unoptimized or #diffs
    if count == 0 then
        return "synced", ppMode and "Optimized" or "Optimized and synced", 0
    end
    if ppMode then
        return "desynced", count .. " unoptimized buff"
            .. (count == 1 and "" or "s"), count
    end
    return "desynced", count .. " Buff" .. (count == 1 and "" or "s")
        .. " out of sync", count
end

-- Small red mail button: whispers the assigned player their job. GetWhisper
-- returns (playerName, whisperText, displayText, bare), or nothing while
-- unassigned; the refresh passes disable/desaturate it accordingly.
-- displayText is the version for our own chat and the hover tooltip (it
-- defaults to whisperText) -- they differ where the whisper uses chat's
-- {skull} tokens, which only expand into icons on the receiving end.
-- bare omits the generic "Your assignment:" lead after the addon tag.
function K.CreateMailButton(row, GetWhisper)
    -- Spell out what will be sent: one player can hold several rows, and every
    -- one of their buttons whispers the same full list.
    local function Tooltip()
        local name, job, display = GetWhisper()
        if name then return "Whisper " .. name, display or job end
        return "Whisper assignment", "No one assigned to whisper."
    end
    return UI.CreateIconButton(row, K.MAIL_ICON, Tooltip, nil, function()
        local name, job, display, bare = GetWhisper()
        if not name then return end
        SendChatMessage("[WhoDoesWhat] " .. (bare and "" or "Your assignment: ")
            .. job .. ".", "WHISPER", nil, name)
        WhoDoesWhat:LogOperation("Whispered " .. name .. " their assignment: " .. (display or job) .. ".")
    end)
end

-- ---------------------------------------------------------------------------
-- Section chrome: the box shell + the right-aligned header button strip
-- ---------------------------------------------------------------------------

-- Boxed section shell in its column. A class tint mixes a little of the
-- class colour into the panel; the kit derives the row stripes from it.
local function CreateSectionBox(f, content, titleText, column, tintClass)
    local col = f.columns[column]
    local tint = tintClass and classColors[tintClass]
    local color = tint and {
        0.08 + tint.r * 0.18, 0.08 + tint.g * 0.18, 0.08 + tint.b * 0.18,
    }
    local box = UI.CreateSectionBox(content, titleText, color)
    box:SetWidth(col.width)
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

    local function Tooltip()
        local list = CollectOthers()
        if #list == 0 then
            return "Whisper everyone their assignment", "No one assigned to whisper."
        end
        local names = {}
        for _, w in ipairs(list) do
            names[#names + 1] = PlayerText(w.name)
        end
        return "Whisper everyone their assignment", table.concat(names, ", ")
    end

    local btn = UI.CreateIconButton(box, K.MAIL_ICON, Tooltip, nil, function()
        local sent = MassWhisper(CollectOthers())
        if sent > 0 then
            WhoDoesWhat:LogOperation(sectionTitle .. ": whispered " .. sent
                .. (sent == 1 and " player" or " players") .. " their assignments.")
        else
            WhoDoesWhat:Print(sectionTitle .. ": no one assigned to whisper.")
        end
    end)

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

-- Build a section's standard chrome in one call: the box shell plus the
-- header strip.
--   opts.title       box title
--   opts.column      K.COL_LEFT / K.COL_RIGHT
--   opts.tintClass   optional class name for a subtle panel/row tint
--   opts.mailCollect optional whisper collector; adds the header mail button
-- Returns { box, mailBtn, headerChain }. headerChain is the box's own chain and
-- starts with the mail button (rightmost); sections add their own buttons in
-- right-to-left order and call UI.LayoutHeaderChain(box) on refresh.
function K.CreateSectionChrome(f, content, opts)
    WhoDoesWhat:LogUiBuilding("Building assignment section: " .. opts.title)
    local box = CreateSectionBox(f, content, opts.title, opts.column, opts.tintClass)
    local chrome = { box = box, headerChain = box.headerChain }
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
-- Column layout + shared confirm popups
-- ---------------------------------------------------------------------------

-- Re-anchor each column's VISIBLE section boxes top-to-bottom, so a hidden box
-- (Paladin-only view) leaves no gap, and size the scroll child to the taller
-- column. Section boxes grow and shrink with their rows, so every section runs
-- this after settling its own height.
function K.LayoutColumns(f)
    local tallest = 0
    for _, col in ipairs(f.columns) do
        tallest = math.max(tallest, UI.StackSections(f.content, col.boxes, col.x))
    end
    UI.SetScrollHeight(f.scroll, tallest)
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
