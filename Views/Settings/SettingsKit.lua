local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI

-- What every page of the Settings tab shares: the column layout, the option
-- widgets, and the page registry. The tab itself -- its sub-tabs, the header
-- with Reset Defaults, and the wells -- is AddonSettingsView.lua; each page is a
-- file of its own beside this one and registers itself here:
--   label        the page's tab, and the name OpenAddonSettingsView takes
--   title, color the heading over the page (gold unless given)
--   tooltip      optional hover text on that heading
--   description  what the page's Reset Defaults does, for its tooltip and confirm
--   right        run the tab from the right-hand end of the row
--   ownScroll    the page re-lays its own well out (no edge shadows from us)
--   Build(f, page, scroll)  lay the page out; `f` is the whole Settings frame
--   Refresh(f)   read every control back out of the settings
--   Reset(f)     put the page's settings back to their defaults
--   OnShow(f)    optional, run each time the page's tab comes up
-- The order the tabs run in is AddonSettingsView's, not load order.
local S = {}
WhoDoesWhat.SettingsKit = S
S.pages = {}

function S.RegisterPage(page)
    S.pages[page.label] = page
end

-- Where the first widget on a page goes.
S.PAGE_TOP = 10

-- Each section scrolls on its own under its tab. Everything a section lays out
-- is measured from the left of its own scroll area, which is why CONTENT_X is
-- so small.
local CONTENT_X = 8
local CONTENT_W = 410
-- Most sections set their column in from the left so it sits near the middle of
-- the page. Buff Tracking's table is wide enough to want the room. A little
-- right of true centre: most rows are short checkbox labels, so the column's
-- visible weight sits well left of its full width.
local PAGE_X = CONTENT_X + 244
-- That column's width, which its section dividers span.
local PAGE_COLUMN_W = 400
-- Laid out like the Buff Tracking row options: a label at the column's left,
-- and every dropdown box and colour swatch starting this far to its right.
local PAGE_FIELD_OFFSET = 146
-- One width for every dropdown in the column, wide enough for the longest
-- choice any of them has ("Pulsing wings (right)").
local PAGE_DROPDOWN_W = 140
local PAGE_DROPDOWN_ROW_H = 32
local DROPDOWN_INSET = 17
local DIVIDER_GAP = 14
local STATUS_DISPLAY_LABELS = {
    default = "Default", percent = "Percent", missing = "Missing Count",
    fraction = "Fraction", applied = "Applied Count",
}

-- One confirm for every reset. The `data` passed to StaticPopup_Show is the
-- reset to run on Yes; the text is the whole question.
StaticPopupDialogs["WHODOESWHAT_RESET_SETTINGS"] = {
    text = "%s",
    button1 = "Reset",
    button2 = "Cancel",
    OnAccept = function(self) self.data() end,
    timeout = 0,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Put settings keys back to their profile defaults - straight from the defaults
-- rather than a second list of values, so a reset and a fresh install cannot
-- disagree. Tables are copied: handing out the defaults' own table would let the
-- next edit rewrite the default itself.
function WhoDoesWhat:RestoreDefaultSettings(keys)
    local settings = self.db.profile.settings
    local defaults = self.db.defaults.profile.settings
    for _, key in ipairs(keys) do
        local value = defaults[key]
        settings[key] = type(value) == "table" and CopyTable(value) or value
    end
end

-- The label lives on the page rather than on the box: the pages fade a
-- checkbox and its label separately, and a label parented to the box would
-- take both fades. The hit rect runs the width of the column, so the label and
-- the air after it toggle the box too.
local function AddCompactCheckboxRow(f, x, y, labelText, tooltip, apply)
    local check = UI.CreateCheckbox(f, labelText, labelText, tooltip,
        function(self) apply(self:GetChecked() and true or false) end,
        { size = 24, font = "GameFontHighlight", gap = 2, labelParent = f })
    check:SetPoint("TOPLEFT", x, -y)
    check:SetHitRectInsets(0, -(PAGE_COLUMN_W - 30 - (x - PAGE_X)), 0, 0)
    return check, y + 28, check.label
end

local function SetOptionAvailable(check, label, available)
    check:SetEnabled(available)
    label:SetTextColor(available and 1 or 0.45,
        available and 1 or 0.45, available and 1 or 0.45)
end

local CreateMiniDivider = UI.CreateDivider

-- ---------------------------------------------------------------------------
-- Option widgets three pages share
-- ---------------------------------------------------------------------------

-- A Buff Tracking style divider across the column, heading the group of
-- options under it. `y` is where it goes; returns the y the group starts at.
local function AddPageDivider(parent, y, text, color)
    local divider = CreateMiniDivider(parent, text, color)
    divider:SetPoint("TOPLEFT", PAGE_X, -y)
    divider:SetWidth(PAGE_COLUMN_W)
    divider.isPageDivider = true
    return y + 18, divider
end

-- The same, after the group above it, with the gap between groups first.
local function AddNextPageDivider(parent, y, text, color)
    return AddPageDivider(parent, y + DIVIDER_GAP, text, color)
end

-- A label at the column's left and a dropdown whose box starts at the column's
-- shared field x. Returns the label, the dropdown, and the y below the row.
-- A short grey paragraph at the top of the column saying what the page's
-- feature is. Returns the text and the y below it.
local function AddPageIntro(parent, y, text)
    local intro = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", PAGE_X + 4, -y)
    intro:SetWidth(PAGE_COLUMN_W - 8)
    intro:SetJustifyH("LEFT")
    intro:SetTextColor(0.7, 0.7, 0.7)
    intro:SetText(text)
    return intro, y + math.ceil(intro:GetStringHeight()) + 12
end

local function AddDropdownRow(parent, y, text, name)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", PAGE_X + 4, -(y + 4))
    label:SetText(text)
    local dd = UI.CreateMenuDropdown(parent, name, PAGE_DROPDOWN_W)
    dd:SetPoint("LEFT", label, "LEFT", PAGE_FIELD_OFFSET - DROPDOWN_INSET, -2)
    return label, dd, y + PAGE_DROPDOWN_ROW_H
end

-- For a page with a master switch: returns a function that greys out and
-- disables everything on the page except the dividers and what `keep` lists
-- (the switch itself, its label, any intro text). The page is re-read on every
-- call: the outline highlight styles add their frame to it the first time the
-- preview runs one.
local function PageControlSwitch(page, keep)
    local kept = {}
    for _, widget in ipairs(keep) do kept[widget] = true end
    return function(enabled)
        local controls = {}
        for _, child in ipairs({ page:GetChildren() }) do
            if not kept[child] and not child.isPageDivider then
                controls[#controls + 1] = child
            end
        end
        for _, region in ipairs({ page:GetRegions() }) do
            if not kept[region] then controls[#controls + 1] = region end
        end
        if not enabled then UI.CancelColorPicker() end
        for _, widget in ipairs(controls) do
            if widget.uiHousingStyled then
                if enabled then
                    UIDropDownMenu_EnableDropDown(widget)
                else
                    UIDropDownMenu_DisableDropDown(widget)
                end
            elseif widget.swatch then
                -- A colour field: the swatch button and the hex box inside it.
                widget.swatch:SetEnabled(enabled)
                widget.hex:EnableMouse(enabled)
                if not enabled then widget.hex:ClearFocus() end
            elseif widget:GetObjectType() == "EditBox" then
                widget:EnableMouse(enabled)
                if not enabled then widget:ClearFocus() end
            elseif widget.Enable and widget.Disable then
                if enabled then widget:Enable() else widget:Disable() end
            end
            widget:SetAlpha(enabled and 1 or 0.35)
        end
    end
end

-- The highlight-style dropdown, the box beside it showing that style running,
-- and one colour field per state the caller has. Three pages want exactly
-- these controls over three different sets of settings, so the settings are
-- what varies:
--   spec.name       a unique frame name for the dropdown
--   spec.styleLabel the dropdown's caption
--   spec.tooltip    what this bar's highlight is for, in one sentence
--   spec.GetStyle / spec.SetStyle
--   spec.noWings    leave the wing styles out of the dropdown
--   spec.colors     { { label, tooltip, key }, ... }, `key` naming the colour's
--                   setting; the first one leads: it is the colour the preview
--                   box is drawn in
--   spec.Store / spec.Defaults  optional functions returning the table those
--                   keys live in and its defaults; the profile's settings
--                   when left out
--   spec.OnChange   repaint whatever wears these
-- Returns the page refresher and the y the next widget starts at.
local function AddHighlightControls(parent, x, y, spec)
    -- A reset writes the profile default back rather than nil. The default is
    -- a table, and AceDB copies a table default into the profile instead of
    -- falling back to it, so a nil left there stays nil: the swatch went white
    -- and each bar drew its own stale fallback colour.
    local Store = spec.Store or function() return WhoDoesWhat.db.profile.settings end
    local Defaults = spec.Defaults
        or function() return WhoDoesWhat.db.defaults.profile.settings end
    for _, entry in ipairs(spec.colors) do
        local key = entry.key
        entry.Default = function() return Defaults()[key] end
        entry.Get = function() return Store()[key] end
        entry.Set = function(color)
            Store()[key] = color or CopyTable(entry.Default())
        end
    end

    -- Only reached if a profile has somehow lost the default too; it keeps a
    -- missing colour from taking the settings window down with it.
    local function EntryColor(entry)
        return entry.Get() or { r = 1, g = 1, b = 1 }
    end

    local styleLabel = parent:CreateFontString(nil, "OVERLAY",
        "GameFontHighlight")
    styleLabel:SetPoint("TOPLEFT", x + 4, -(y + 4))
    styleLabel:SetText(spec.styleLabel or "Highlight style:")

    local dd = UI.CreateMenuDropdown(parent, spec.name, PAGE_DROPDOWN_W)
    dd:SetPoint("LEFT", styleLabel, "LEFT", PAGE_FIELD_OFFSET - DROPDOWN_INSET, -2)

    -- Built like a status row rather than as one flat frame: the sample's own
    -- art lives on a child frame, and the box sits a few levels above the page,
    -- so the styles that draw behind a row land behind this too. The clearance
    -- to its left is for the ones that draw outside the box -- the wings flank
    -- it the way they flank a real row.
    local preview = CreateFrame("Frame", nil, parent)
    preview:SetSize(56, 18)
    preview:SetPoint("LEFT", dd, "RIGHT", 28, 2)
    preview:SetFrameLevel(parent:GetFrameLevel() + 3)
    local previewBody = CreateFrame("Frame", nil, preview)
    previewBody:SetAllPoints()
    local previewBg = previewBody:CreateTexture(nil, "BACKGROUND")
    previewBg:SetAllPoints()
    previewBg:SetColorTexture(0.16, 0.16, 0.18, 1)
    local previewFill = previewBody:CreateTexture(nil, "ARTWORK")
    previewFill:SetPoint("TOPLEFT", 1, -1)
    previewFill:SetPoint("BOTTOMLEFT", 1, 1)
    previewFill:SetWidth(34)
    previewFill:SetColorTexture(0.96, 0.55, 0.73, 0.8)

    -- spec.noWings drops the wing styles (they draw beside the frame, which a
    -- packed icon grid has no room for), including a saved one.
    local function Offered(styles, key)
        return styles[key] and not (spec.noWings and styles[key].wings)
    end

    local function SavedStyle()
        local styles, _, default = WhoDoesWhat:GetStatusBarHighlightStyles()
        local saved = spec.GetStyle()
        if not Offered(styles, saved) then saved = default end
        return saved, styles
    end

    local function ApplyPreview(styleKey)
        -- Off and on again: the colour and the size are read at start, so a
        -- style that is already running has to be rebuilt to pick either up.
        local color = EntryColor(spec.colors[1])
        WhoDoesWhat:ApplyStatusBarHighlight(preview, false, styleKey, color)
        WhoDoesWhat:ApplyStatusBarHighlight(preview, true, styleKey, color)
    end

    UIDropDownMenu_Initialize(dd, function(_, level)
        local styles, order = WhoDoesWhat:GetStatusBarHighlightStyles()
        local saved = SavedStyle()
        for _, key in ipairs(order) do
            local styleKey = key
            if Offered(styles, styleKey) then
                local info = UIDropDownMenu_CreateInfo()
                info.text = styles[styleKey].label
                info.checked = saved == styleKey
                info.func = function()
                    spec.SetStyle(styleKey)
                    UIDropDownMenu_SetText(dd, styles[styleKey].label)
                    ApplyPreview(styleKey)
                    spec.OnChange()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end)
    UI.AddDropdownTooltip(dd, styleLabel, "Highlight style", spec.tooltip)

    -- The colours go under the dropdown so the sample box beside it shows a
    -- colour change as it is dragged. Each swatch starts at the dropdown box's
    -- x, like every other field in the column.
    local fields = {}
    local rowY = y + 32
    local labels = {}
    for index, entry in ipairs(spec.colors) do
        local label = parent:CreateFontString(nil, "OVERLAY",
            "GameFontHighlight")
        label:SetPoint("TOPLEFT", x + 4, -(rowY + (index - 1) * 24 + 4))
        label:SetText(entry.label)
        UI.AddTooltip(label, entry.label, entry.tooltip)
        labels[index] = label
    end

    -- The picker's live preview: repaint the sample, then let whatever wears
    -- these colours pick the change up on the way past.
    local function ColorsChanged()
        ApplyPreview(SavedStyle())
        spec.OnChange()
    end

    for index, entry in ipairs(spec.colors) do
        local field = UI.CreateColorField(parent, {
            title = entry.label,
            Get = entry.Get, Set = entry.Set,
            Default = entry.Default,
            OnChange = ColorsChanged,
        })
        field:SetPoint("LEFT", labels[index], "LEFT", PAGE_FIELD_OFFSET, 0)
        fields[index] = field
    end
    rowY = rowY + #spec.colors * 24

    -- Every control here, read back out of the settings: the window opening,
    -- a page's Defaults button, or a different profile loading.
    local function Refresh()
        local styles = WhoDoesWhat:GetStatusBarHighlightStyles()
        UIDropDownMenu_SetText(dd, styles[SavedStyle()].label)
        for _, field in ipairs(fields) do field:Refresh() end
        ApplyPreview(SavedStyle())
    end

    return Refresh, rowY + 4, labels, fields
end

-- A whole number with two ways in: a slider to drag, and a box beside it to
-- type an exact value into. `spec` is { name, label, tooltip, min, max },
-- `Get` reads the saved number, `Set` writes one back, `OnChange` repaints.
local function AddSliderWithInput(parent, x, y, spec, Get, Set, OnChange)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", x + 4, -(y + 4))
    label:SetText(spec.label)

    -- On the label's row, starting at the column's shared field x.
    local slider, edit, Refresh = UI.CreateSliderWithInput(parent, spec, Get, Set, OnChange)
    slider:SetPoint("LEFT", label, "LEFT", PAGE_FIELD_OFFSET, 0)

    UI.AddTooltip(label, spec.label, spec.tooltip)
    UI.AddTooltip(edit, spec.label, spec.tooltip)

    return Refresh, y + PAGE_DROPDOWN_ROW_H
end

S.CONTENT_X = CONTENT_X
S.CONTENT_W = CONTENT_W
S.PAGE_X = PAGE_X
S.DROPDOWN_INSET = DROPDOWN_INSET
S.DIVIDER_GAP = DIVIDER_GAP
S.STATUS_DISPLAY_LABELS = STATUS_DISPLAY_LABELS
S.AddCompactCheckboxRow = AddCompactCheckboxRow
S.SetOptionAvailable = SetOptionAvailable
S.AddPageDivider = AddPageDivider
S.AddNextPageDivider = AddNextPageDivider
S.AddPageIntro = AddPageIntro
S.AddDropdownRow = AddDropdownRow
S.PageControlSwitch = PageControlSwitch
S.AddHighlightControls = AddHighlightControls
S.AddSliderWithInput = AddSliderWithInput
