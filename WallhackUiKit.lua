local ADDON_NAME, ns = ...

--------------------------------------------------------------------------------
-- WallhackUiKit - window chrome and the widgets that sit in it
--
-- Takes nothing from the addon around it: `local ADDON_NAME, ns = ...` is the
-- entire contact surface. It holds every number the chrome is built from, so
-- one window cannot drift from another by redefining a margin locally.
--
-- The addon gets its own private copy at `ns.UI` - no global, no LibStub.
--------------------------------------------------------------------------------

local UI = {}
ns.UI = UI

-- Optional logging hook. The kit cannot know the addon's logger, so the addon
-- hands one in once it has it; until then, building a window says nothing.
function UI.Log(message)
    if UI.logger then UI.logger(message) end
end

--------------------------------------------------------------------------------
-- The numbers
--------------------------------------------------------------------------------

UI.TITLEBAR_H  = 22
UI.INSET       = 5    -- backdrop edge to anything inside it
UI.SCROLLBAR_W = 26   -- gutter reserved on the right of a scroll area

UI.TAB_H       = 22
UI.TAB_PAD     = 12   -- either side of a tab's label; tabs size to their text
UI.TAB_GAP     = 2    -- between neighbouring tabs
UI.TAB_INDENT  = 14   -- strip start to the left edge of the first tab, so the
                      -- row sits inboard like the tabs on a real folder
UI.TAB_DROP    = 6    -- title bar to the top of the tabs
UI.TAB_LIP     = 3    -- how far the panel rides UP behind the tab row, so the
                      -- tabs sit on the panel instead of floating above it

-- The window fill, and the slightly lighter panel a tabbed window's pages sit
-- on. Very dark blues rather than black: black reads as a hole in the screen,
-- and the blue keeps the class-coloured rows on top of it from looking muddy.
UI.WINDOW_COLOR    = { 0.015, 0.025, 0.06, 0.95 }
UI.TAB_PANEL_COLOR = { 0.03, 0.045, 0.09, 1 }

-- Solid dark, thin border. Every window uses this and only this, which is the
-- whole reason they look like they came from the same hand.
UI.BACKDROP = {
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = false, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- A lighter panel inside a window: section boxes, toolbars, grouped settings.
-- Thinner border than the window's own so it reads as part of the window
-- rather than a second one.
UI.PANEL_BACKDROP = {
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- The fill and border for each kind of panel: `raised` sits on the window,
-- `sunken` is a well that something scrolls inside, `popup` floats over
-- other controls.
UI.PANEL_STYLES = {
    raised = { fill = { 0.16, 0.16, 0.18, 0.9 },  border = { 0.4, 0.4, 0.4 } },
    sunken = { fill = { 0.07, 0.07, 0.08, 0.95 }, border = { 0.3, 0.3, 0.3 } },
    popup  = { fill = { 0.1, 0.1, 0.12, 0.95 },   border = { 0.4, 0.4, 0.4 } },
}

-- Dress a BackdropTemplate frame as a panel; `style` is a key of PANEL_STYLES,
-- default raised, or a `{ fill = ..., border = ... }` of the caller's own.
function UI.StylePanel(frame, style)
    local s = type(style) == "table" and style or UI.PANEL_STYLES[style or "raised"]
    frame:SetBackdrop(UI.PANEL_BACKDROP)
    frame:SetBackdropColor(s.fill[1], s.fill[2], s.fill[3], s.fill[4])
    frame:SetBackdropBorderColor(s.border[1], s.border[2], s.border[3])
end

-- AceGUI's slider art, used for the track behind a native scrollbar.
UI.SCROLL_TRACK_BACKDROP = {
    bgFile   = "Interface\\Buttons\\UI-SliderBar-Background",
    edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
    tile = true, tileSize = 8, edgeSize = 8,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- The trough of a horizontal slider, and the height that art is cut for.
--
-- Same two files the scroll track uses, but the insets are NOT the same, and
-- that difference is the whole point. UI-SliderBar-Border is an 8px edge file:
-- a corner piece is 8px tall, so at 8 + 8 = 16 the top and bottom corners of an
-- end cap meet and the cap reads as one rounded shape. Go taller and the
-- backdrop fills the difference by stretching the left and right edge segments
-- between them, and since those segments are cap art rather than a repeating
-- rail, what you get is four disjointed corners with nothing joining them. That
-- is the whole bug: the height, not the insets.
--
-- 15 rather than 16, so the two corners overlap by a pixel instead of merely
-- touching. Not a number worth deriving - it is what AceGUI-3.0's slider widget
-- and DBM-GUI's panel prototype both use, which between them is most of the
-- sliders anybody running this game has ever looked at.
UI.SLIDER_H = 15
UI.SLIDER_BACKDROP = {
    bgFile   = "Interface\\Buttons\\UI-SliderBar-Background",
    edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
    tile = true, tileSize = 8, edgeSize = 8,
    insets = { left = 3, right = 3, top = 6, bottom = 6 },
}

-- BackdropTemplate is the Shadowlands-era split of backdrop support out of the
-- base frame. Both clients have it, but resolve it rather than assume it -
-- CreateFrame takes a nil template happily.
UI.TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

-- The lookup moved onto C_AddOns and the bare global is a deprecated alias on
-- these clients. Take whichever exists.
local GetMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata

-- The host addon's version, resolved once. Windows stamp it into their title
-- bar; an About page wants it too, and neither should look it up again.
UI.VERSION = GetMetadata and GetMetadata(ADDON_NAME, "Version") or nil

--------------------------------------------------------------------------------
-- Windows
--------------------------------------------------------------------------------

-- Retitling goes through here so a window that stamps its version cannot lose
-- the stamp to a caller that only meant to change the name.
--
-- A colour escape rather than a second font string: one region keeps the name
-- and the version centred as a single unit, which is what actually reads as a
-- title bar. Two regions would centre one of them and hang the other off its
-- edge, leaving the pair off-centre by half the stamp's width.
local function SetTitle(f, text)
    text = text or ""
    if f.showVersion and UI.VERSION then
        text = text .. " |cff808080(v" .. UI.VERSION .. ")|r"
    end
    f.titleText:SetText(text)
end

-- A standard window: solid black, a title bar, a close button, draggable by
-- anywhere on it, closes on Escape.
--
-- Retitle with `f:SetTitle("Name")`. `bare` windows have no title bar and
-- therefore no `SetTitle`.
--
-- `globalName` must be unique per window - it is what the Escape-close registry
-- keys on, and the only reason these frames are named at all.
--
-- The caller anchors its own content below the title bar, at `f.titleBarHeight`
-- from the top.
--
-- opts:
--   bare        no title bar and no close button, for a pop-up: a prompt with
--               two buttons in it does not need a third way to dismiss it, and
--               the title bar on something that small is most of its height.
--               `titleBarHeight` is 0 there, so the same anchoring arithmetic
--               works either way.
--   closeButton keep the close button on a `bare` window, for a pop-up that
--               has nothing else to dismiss it by
--   titleAlign  "CENTER" (default) or "LEFT"
--   version     stamp the addon version after the title, greyed: `Name (vX.Y.Z)`.
--               For the window that IS the addon, not for every pop-up in it.
--   borderColor    { r, g, b } for the window's edge; grey when left out
--   titleBarColor  { r, g, b } for the title bar; slate when left out
function UI.CreateWindow(globalName, width, height, titleText, opts)
    opts = opts or {}
    UI.Log("Creating window frame: " .. tostring(globalName))
    local f = CreateFrame("Frame", globalName, UIParent, UI.TEMPLATE)
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetBackdrop(UI.BACKDROP)
    local c = UI.WINDOW_COLOR
    f:SetBackdropColor(c[1], c[2], c[3], c[4])
    local edge = opts.borderColor or { 0.4, 0.4, 0.4 }
    f:SetBackdropBorderColor(edge[1], edge[2], edge[3])

    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    tinsert(UISpecialFrames, globalName)

    local function AddCloseButton()
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 1, 1)
        close:SetScript("OnClick", function() f:Hide() end)
        f.closeButton = close
    end

    if opts.bare then
        if opts.closeButton then AddCloseButton() end
        f.titleBarHeight = 0
        f:Hide()
        return f
    end

    local titlebar = f:CreateTexture(nil, "ARTWORK")
    local bar = opts.titleBarColor or { 0.12, 0.12, 0.15 }
    titlebar:SetColorTexture(bar[1], bar[2], bar[3], 1)
    titlebar:SetPoint("TOPLEFT", UI.INSET, -UI.INSET)
    titlebar:SetPoint("TOPRIGHT", -UI.INSET, -UI.INSET)
    titlebar:SetHeight(UI.TITLEBAR_H)
    f.titleBar = titlebar

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    -- Placed against the BAR, not the window, and the bar is anchored to both
    -- edges - so a window that changes width re-centres its own title with no
    -- arithmetic and nothing to keep in step.
    if opts.titleAlign == "LEFT" then
        title:SetPoint("LEFT", titlebar, "LEFT", 10, 0)
    else
        title:SetPoint("CENTER", titlebar, "CENTER", 0, 0)
    end
    f.titleText = title

    f.showVersion = opts.version and true or false
    f.SetTitle = SetTitle
    f:SetTitle(titleText)

    AddCloseButton()

    f.titleBarHeight = UI.TITLEBAR_H
    f:Hide()
    return f
end

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------

-- A tab can be named by its position or by its spec's `page` key; everything
-- that takes a tab takes either. Nil for a key nothing answers to.
local function TabIndex(f, key)
    if type(key) == "number" then
        return f.tabs[key] and key or nil
    end
    return f.tabIndexByPage[key]
end

-- One function decides what "selected" looks like, for the tab and its page
-- both, so the two can never disagree about which tab is up.
--
-- Depth is part of "selected" here, which is what gives the row its folder
-- shape: the selected tab comes forward OVER the panel, so its bottom edge and
-- its underline sit on top of the panel's border and it reads as one piece with
-- the page below. Every other tab drops BEHIND the panel, and the border runs
-- unbroken across them.
--
-- Both levels are derived from the panel rather than written down, so the only
-- thing that has to stay true is the gap AddTabs leaves around it.
--
-- PaintTab is the colours alone, which is all the mouse crossing a tab changes.
local function PaintTab(f, i)
    local tab, c = f.tabs[i], f.tabColors
    local on = i == f.selectedTab
    local hot = not on and tab:IsEnabled() and tab.hovered
    local bg = on and c.selected or (hot and c.hover) or c.unselected
    tab.bg:SetColorTexture(bg[1], bg[2], bg[3], 1)
    local text = on and c.labelSelected
        or (not tab:IsEnabled() and c.labelDisabled)
        or (hot and c.labelHover) or c.label
    tab.label:SetTextColor(text[1], text[2], text[3])
end

local function PaintTabs(f)
    local panelLevel = f.tabPanel:GetFrameLevel()
    for i, tab in ipairs(f.tabs) do
        local on = i == f.selectedTab
        PaintTab(f, i)
        tab.underline:SetShown(on)
        -- +2 clears the pages, which are the panel's own children at +1.
        tab:SetFrameLevel(on and panelLevel + 2 or panelLevel - 1)
        f.pages[i]:SetShown(on)
    end
end

-- Bring a tab up. Refuses - returning false - a tab that is hidden, disabled
-- or unknown, so a stale saved choice cannot land the window on a page that
-- should not be reachable.
--
-- A page with a `build` is filled the first time it comes up rather than when
-- the window is made, and before it is shown, so an OnShow hooked on the page
-- sees it finished.
local function SelectTab(f, key)
    local index = TabIndex(f, key)
    local tab = index and f.tabs[index]
    if not tab or not tab:IsShown() or not tab:IsEnabled() then return false end

    local spec = f.tabSpecs[index]
    if spec.build and not tab.built then
        tab.built = true
        spec.build(f.pages[index], f)
    end

    f.selectedTab, f.selectedPage = index, spec.page
    PaintTabs(f)
    for _, listener in ipairs(f.tabListeners) do
        listener(index, spec.page, f.pages[index])
    end
    return true
end

-- The first tab that can be selected, in spec order. Nil when none can.
local function FirstAvailableTab(f)
    for i, tab in ipairs(f.tabs) do
        if tab:IsShown() and tab:IsEnabled() then return i end
    end
end

-- Whatever was selected may just have been hidden or disabled; move off it to
-- the first tab that is still available, or to no page at all.
local function EnsureSelectable(f)
    local current = f.selectedTab and f.tabs[f.selectedTab]
    if current and current:IsShown() and current:IsEnabled() then
        PaintTabs(f)
        return
    end
    local fallback = FirstAvailableTab(f)
    if fallback then
        SelectTab(f, fallback)
    else
        f.selectedTab, f.selectedPage = nil, nil
        PaintTabs(f)
    end
end

-- Tabs run left to right, each anchored to the one before it, so the label
-- widths stay the only thing deciding the spacing. A hidden tab is skipped
-- rather than left as a hole, which is why this re-runs on every visibility
-- change.
--
-- A spec with `right = true` is anchored from the other end instead, and the
-- two runs simply never meet in the middle. That is how a tab that is not part
-- of the sequence - About, Help, anything you go to rather than through - gets
-- separated from it without anybody counting pixels.
local function LayoutTabs(f)
    local previous, previousRight
    for i, tab in ipairs(f.tabs) do
        if tab:IsShown() then
            tab:ClearAllPoints()
            if f.tabSpecs[i].right then
                if previousRight then
                    tab:SetPoint("TOPRIGHT", previousRight, "TOPLEFT", -UI.TAB_GAP, 0)
                else
                    tab:SetPoint("TOPRIGHT", f, "TOPRIGHT",
                        -(UI.INSET + UI.TAB_INDENT), -f.tabTop)
                end
                previousRight = tab
            else
                if previous then
                    tab:SetPoint("TOPLEFT", previous, "TOPRIGHT", UI.TAB_GAP, 0)
                else
                    tab:SetPoint("TOPLEFT", f, "TOPLEFT",
                        UI.INSET + UI.TAB_INDENT, -f.tabTop)
                end
                previous = tab
            end
        end
    end
end

local function SizeTab(tab)
    tab:SetWidth(tab.label:GetStringWidth() + UI.TAB_PAD * 2)
end

-- Show or hide a tab. The row closes up around a hidden one, and if it was the
-- selected tab the window moves to the first tab still available.
local function SetTabShown(f, key, shown)
    local index = TabIndex(f, key)
    if not index then return end
    f.tabs[index]:SetShown(shown and true or false)
    LayoutTabs(f)
    EnsureSelectable(f)
end

-- Enable or grey out a tab. A disabled tab stays in the row - so the page it
-- leads to is still known to exist - and its tooltip says `reason`.
local function SetTabEnabled(f, key, enabled, reason)
    local index = TabIndex(f, key)
    if not index then return end
    local tab = f.tabs[index]
    tab:SetEnabled(enabled and true or false)
    tab.disabledReason = (not enabled) and reason or nil
    EnsureSelectable(f)
end

-- Reword a tab - a count that changes, say - and re-fit its width to it.
local function SetTabLabel(f, key, label)
    local index = TabIndex(f, key)
    if not index then return end
    local tab = f.tabs[index]
    tab.label:SetText(label)
    SizeTab(tab)
end

-- Hear about every switch: `listener(index, pageKey, page)`. Any number may
-- listen; they run in the order they were added.
local function OnTabSelected(f, listener)
    f.tabListeners[#f.tabListeners + 1] = listener
end

-- How wide the row of shown tabs is, both runs and their indents, for a window
-- that sizes itself to fit its tabs. The row does not wrap or scroll: a window
-- narrower than this overlaps its left and right runs.
local function GetTabRowWidth(f)
    local width, left, right = 0, 0, 0
    for i, tab in ipairs(f.tabs) do
        if tab:IsShown() then
            width = width + tab:GetWidth()
            if f.tabSpecs[i].right then right = right + 1 else left = left + 1 end
        end
    end
    local gaps = math.max(left - 1, 0) + math.max(right - 1, 0)
        + ((left > 0 and right > 0) and 1 or 0)
    return width + gaps * UI.TAB_GAP + 2 * (UI.INSET + UI.TAB_INDENT)
end

-- The tab row's colours where AddTabs is given none of its own.
local TAB_COLORS = {
    selected      = { 0.22, 0.22, 0.26 },
    unselected    = { 0.10, 0.10, 0.12 },
    label         = { 0.65, 0.65, 0.65 },
    labelSelected = { 1, 0.82, 0 },
    labelDisabled = { 0.35, 0.35, 0.35 },
    underline     = { 1, 0.82, 0 },
    panel         = UI.TAB_PANEL_COLOR,
    panelBorder   = { 0.25, 0.25, 0.25 },
}

-- Deliberately not PanelTabButtonTemplate: the stock tab art is parchment and
-- would look pasted on against a black window, and its availability varies by
-- client. A button, a background and a label is the whole of it.
--
-- Width follows the label rather than a fixed number, so a longer tab name
-- cannot silently clip.
local function BuildTab(f, index, spec)
    local tab = CreateFrame("Button", nil, f)
    tab:SetHeight(UI.TAB_H)

    tab.bg = tab:CreateTexture(nil, "BACKGROUND")
    tab.bg:SetAllPoints(tab)

    tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tab.label:SetPoint("CENTER")
    tab.label:SetText(spec.label)

    -- A thin bar along the bottom of the selected tab. Against a dark
    -- background the colour change on its own is too subtle; this is what
    -- actually reads as "this one" at a glance.
    tab.underline = tab:CreateTexture(nil, "ARTWORK")
    local line = f.tabColors.underline
    tab.underline:SetColorTexture(line[1], line[2], line[3], 1)
    tab.underline:SetPoint("BOTTOMLEFT", 0, 0)
    tab.underline:SetPoint("BOTTOMRIGHT", 0, 0)
    tab.underline:SetHeight(2)
    tab.underline:Hide()

    SizeTab(tab)
    tab:SetScript("OnClick", function() SelectTab(f, index) end)
    -- A tooltip on every tab, even without one to say: a disabled tab has to
    -- be able to explain itself.
    UI.AddTooltip(tab, function(self)
        if spec.tooltip or self.disabledReason then
            return self.label:GetText(), spec.tooltip
        end
    end)
    -- Hover repaints only when the caller gave it colours to repaint with.
    if f.tabColors.hover or f.tabColors.labelHover then
        tab:HookScript("OnEnter", function(self)
            self.hovered = true
            PaintTab(f, index)
        end)
        tab:HookScript("OnLeave", function(self)
            self.hovered = nil
            PaintTab(f, index)
        end)
    end

    return tab
end

-- Fit a window out with a tab row and a content panel, one page per tab.
--
-- `specs` is a list, one entry per tab:
--   label     what the tab says
--   page      a stable key for the page - see below
--   right     run this tab from the right-hand end of the row
--   build     function(page, f), called the first time the tab is selected,
--             for a page too expensive to fill until somebody opens it
--   tooltip   a sentence about what the page is for
--   hidden    start hidden
--   disabled  start disabled; `disabledReason` is what its tooltip says
--
-- opts, all optional:
--   top       extra room between the title bar and the tab row, for chrome the
--             window keeps above its tabs
--   initial   the tab to open on, by index or page key; falls back to the first
--             available tab when it cannot be selected
--   colors    any keys of TAB_COLORS, each { r, g, b }, over the kit's greys;
--             `panel` may carry an alpha. Also `hover` and `labelHover`, which
--             have no default: without them a tab does not change under the
--             mouse.
--
-- Adding a tab is adding an entry, and nothing here counts them by hand. The
-- window gains:
--   f:SelectTab(key)                  -> whether it could
--   f:SetTabShown(key, shown)
--   f:SetTabEnabled(key, enabled, reason)
--   f:SetTabLabel(key, label)
--   f:OnTabSelected(listener)         listener(index, pageKey, page)
--   f:GetTabRowWidth()
--   f.selectedTab, f.selectedPage     index and page key of the tab that is up
-- where `key` is an index or a page key.
--
-- Returns the pages under BOTH keys: the index, and `spec.page` when a spec
-- carries one. Reach for the name - `pages.general`, not `pages[6]`. The index is
-- what the tab row itself runs on and cannot go away, but a caller that counts
-- positions is one inserted tab away from building the wrong page onto the wrong
-- label, and nothing would say so: every page is the same empty frame, so the
-- mistake surfaces as a tab full of its neighbour's contents rather than as an
-- error. `page` is a stable key precisely because it is not the label - the
-- label is the part that gets reworded.
--
-- Every page fills the panel and all but the selected one is hidden, so they
-- stack and no page needs to know anything about the others. Remembering the
-- last tab across sessions is the caller's: listen, save the page key, pass it
-- back as `initial`.
function UI.AddTabs(f, specs, opts)
    opts = opts or {}
    f.tabColors = {}
    for key, color in pairs(TAB_COLORS) do f.tabColors[key] = color end
    for key, color in pairs(opts.colors or {}) do f.tabColors[key] = color end
    f.tabs, f.pages, f.tabSpecs = {}, {}, {}
    f.tabIndexByPage, f.tabListeners = {}, {}
    f.tabTop = (f.titleBarHeight or 0) + UI.INSET + UI.TAB_DROP + (opts.top or 0)

    -- The panel is deliberately parked THREE levels above the window, and every
    -- tab level is measured from it (see PaintTabs). The gap underneath is the
    -- point: an unselected tab has to be below the panel to tuck behind it, and
    -- still above `f` to be clickable at all.
    --
    -- That second half is easy to lose. `f` is mouse-enabled - it is what you
    -- drag the window by - so a tab left on the same level as `f` is not merely
    -- drawn wrong, it stops receiving clicks entirely, and the tabs go dead with
    -- nothing in the log to say why. One level of clearance is what keeps them
    -- alive; the panel needs the extra one so its own pages sit under a
    -- brought-forward tab.
    local panel = CreateFrame("Frame", nil, f, UI.TEMPLATE)
    panel:SetFrameLevel(f:GetFrameLevel() + 3)
    panel:SetPoint("TOPLEFT", UI.INSET, -(f.tabTop + UI.TAB_H - UI.TAB_LIP))
    panel:SetPoint("BOTTOMRIGHT", -UI.INSET, UI.INSET)
    panel:SetBackdrop(UI.BACKDROP)
    local fill, edge = f.tabColors.panel, f.tabColors.panelBorder
    panel:SetBackdropColor(fill[1], fill[2], fill[3], fill[4] or 1)
    panel:SetBackdropBorderColor(edge[1], edge[2], edge[3])
    f.tabPanel = panel

    for i, spec in ipairs(specs) do
        f.tabSpecs[i] = spec
        local tab = BuildTab(f, i, spec)
        f.tabs[i] = tab
        if spec.hidden then tab:Hide() end
        if spec.disabled then
            tab:Disable()
            tab.disabledReason = spec.disabledReason
        end

        local page = CreateFrame("Frame", nil, panel)
        page:SetPoint("TOPLEFT", 10, -10)
        page:SetPoint("BOTTOMRIGHT", -10, 10)
        page:Hide()
        f.pages[i] = page
        -- The named key is an ALIAS onto the same frame, not a second page. A
        -- duplicated `page` in the specs would silently overwrite the earlier
        -- alias and leave one tab unreachable by name, so it is caught here
        -- rather than puzzled over later. A number would collide with the
        -- positions, so it is refused for the same reason.
        if spec.page then
            if f.pages[spec.page] or type(spec.page) ~= "string" then
                error(("UI.AddTabs: bad or duplicate page key %q")
                    :format(tostring(spec.page)), 2)
            end
            f.pages[spec.page] = page
            f.tabIndexByPage[spec.page] = i
        end
    end

    f.SelectTab = SelectTab
    f.SetTabShown = SetTabShown
    f.SetTabEnabled = SetTabEnabled
    f.SetTabLabel = SetTabLabel
    f.OnTabSelected = OnTabSelected
    f.GetTabRowWidth = GetTabRowWidth

    LayoutTabs(f)
    if not (opts.initial and SelectTab(f, opts.initial)) then
        EnsureSelectable(f)
    end
    return f.pages
end

-- Give one tab page its own background colour in place of the panel's, across
-- the whole panel inside its border - not just wherever the page's content
-- happens to reach - so the page reads as one surface. The fill belongs to the
-- page, so it comes and goes with its tab. `color` is { r, g, b, a }.
function UI.SetTabPageColor(page, color)
    local panel = page:GetParent()
    if not page.uiFill then
        page.uiFill = page:CreateTexture(nil, "BACKGROUND", nil, -8)
        page.uiFill:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
        page.uiFill:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
    end
    page.uiFill:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
end

--------------------------------------------------------------------------------
-- Moving
--
-- For frames that live on the screen rather than in a window: bars the player
-- places once and then leaves. A position is kept as the coordinates of one
-- anchor POINT of the frame against UIParent's bottom-left, and that point is
-- the edge that holds still while the frame changes size - so a bar that grows
-- to the left is saved by its right edge, one that spreads both ways by its
-- midpoint. The caller picks the point and owns where the position is stored.
--------------------------------------------------------------------------------

-- Each half of the point says what its coordinate measures: the edge it names,
-- or that axis's midpoint when it names neither ("TOP" is a horizontal
-- midpoint, "LEFT" a vertical one).
local function PointSides(point)
    local h = point:find("RIGHT") and "RIGHT" or point:find("LEFT") and "LEFT" or nil
    local v = point:find("TOP") and "TOP" or point:find("BOTTOM") and "BOTTOM" or nil
    return h, v
end

-- Keep a frame anchored at `point` fully on screen: pull x, y back so no edge
-- of a frame its current size would hang off UIParent. A frame larger than the
-- screen is pinned to the edge its point names.
function UI.ClampPoint(frame, point, x, y)
    local parentW, parentH = UIParent:GetWidth(), UIParent:GetHeight()
    local width, height = frame:GetWidth(), frame:GetHeight()
    local h, v = PointSides(point)
    if h == "RIGHT" then
        x = math.max(math.min(width, parentW), math.min(x, parentW))
    elseif h == "LEFT" then
        x = math.max(0, math.min(x, math.max(0, parentW - width)))
    else
        local half = math.min(width / 2, parentW / 2)
        x = math.max(half, math.min(x, parentW - half))
    end
    if v == "TOP" then
        y = math.max(math.min(height, parentH), math.min(y, parentH))
    elseif v == "BOTTOM" then
        y = math.max(0, math.min(y, math.max(0, parentH - height)))
    else
        local half = math.min(height / 2, parentH / 2)
        y = math.max(half, math.min(y, parentH - half))
    end
    return x, y
end

-- Where `point` of the frame is right now, against UIParent's bottom-left.
-- Nil before the frame has a rect.
function UI.PointPosition(frame, point)
    local h, v = PointSides(point)
    local cx, cy = frame:GetCenter()
    local x = h == "RIGHT" and frame:GetRight() or h == "LEFT" and frame:GetLeft() or cx
    local y = v == "TOP" and frame:GetTop() or v == "BOTTOM" and frame:GetBottom() or cy
    if not x or not y then return end
    return x, y
end

-- The frame's current place as { point, x, y }, clamped, ready to store. Nil
-- before the frame has a rect.
function UI.SavePoint(frame, point)
    local x, y = UI.PointPosition(frame, point)
    if not x then return end
    x, y = UI.ClampPoint(frame, point, x, y)
    return { point = point, x = x, y = y }
end

-- Put a frame back where `pos` ({ point, x, y }) says, clamped to the screen as
-- it is now - the resolution may have changed since it was saved - and written
-- back into `pos` so the stored copy stays honest. Without a usable `pos` the
-- frame is centred, `fallbackY` below the middle. Returns whether `pos` was used.
function UI.RestorePoint(frame, pos, fallbackY)
    frame:ClearAllPoints()
    if pos and pos.point and pos.x and pos.y then
        pos.x, pos.y = UI.ClampPoint(frame, pos.point, pos.x, pos.y)
        frame:SetPoint(pos.point, UIParent, "BOTTOMLEFT", pos.x, pos.y)
        return true
    end
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, -(fallbackY or 0))
    return false
end

-- Make a frame draggable by a held modifier, so a bar full of buttons can still
-- be clicked normally and only moves on purpose.
--
-- opts, all optional:
--   modifier  function returning whether dragging is allowed to start; default
--             IsAltKeyDown
--   noCombat  refuse to start in combat - required for a frame that parents
--             secure buttons, which may not move mid-fight
--   OnStart   function(frame) as the drag begins, e.g. to shut pop-outs that
--             would otherwise ride along
--   OnStop    function(frame) after it is dropped. StartMoving can leave the
--             frame on a different anchor than the one its position is kept
--             by, so this is where the caller saves and re-anchors.
--
-- `frame.moving` is true for the length of a drag, for a repaint that must not
-- re-anchor the frame out from under the cursor.
function UI.MakeMovable(frame, opts)
    frame.uiMove = opts or {}
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    UI.AttachDrag(frame, frame)
end

-- Let another region - a title strip, a button covering most of the frame -
-- start the same drag. The options are read off the frame at drag time, so a
-- region may be attached before the frame has been through MakeMovable.
function UI.AttachDrag(region, frame)
    region:EnableMouse(true)
    region:RegisterForDrag("LeftButton")
    region:SetScript("OnDragStart", function()
        local opts = frame.uiMove
        if not opts then return end
        if not (opts.modifier or IsAltKeyDown)() then return end
        if opts.noCombat and InCombatLockdown() then return end
        frame.moving = true
        frame:StartMoving()
        if opts.OnStart then opts.OnStart(frame) end
    end)
    region:SetScript("OnDragStop", function()
        if not frame.moving then return end
        frame.moving = nil
        frame:StopMovingOrSizing()
        if frame.uiMove.OnStop then frame.uiMove.OnStop(frame) end
    end)
end

--------------------------------------------------------------------------------
-- Scrolling
--------------------------------------------------------------------------------

-- A scroll area and its scroll child. The caller anchors `scroll` itself,
-- leaving UI.SCROLLBAR_W of gutter on the right, fills `content`, and calls
-- UI.SetScrollHeight whenever that content changes height.
--
-- `globalName` is required by UIPanelScrollFrameTemplate: the template finds
-- its own scrollbar by appending "ScrollBar" to the frame's name, so an
-- unnamed scroll frame silently has no bar to style or hide.
--
-- scrollBarHideable lets the template drop the bar entirely while everything
-- fits. The gutter stays reserved either way, so nothing shifts sideways at the
-- moment the bar appears.
--
-- The content is kept as wide as the viewport, unless `ownWidth` says the
-- caller sizes it - a grid wider or narrower than its viewport, say.
function UI.CreateScroll(parent, globalName, ownWidth)
    local scroll = CreateFrame("ScrollFrame", globalName, parent,
        "UIPanelScrollFrameTemplate")
    scroll.scrollBarHideable = true

    local content = CreateFrame("Frame", nil, scroll)
    content:SetPoint("TOPLEFT")
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    -- The native bar draws a thumb and arrows over nothing; this is the track
    -- they run in, one frame level behind so the template's own art stays on
    -- top. It follows the bar in and out of view.
    local bar = globalName and _G[globalName .. "ScrollBar"]
    if bar then
        local track = CreateFrame("Frame", nil, scroll, UI.TEMPLATE)
        track:SetAllPoints(bar)
        track:SetFrameLevel(math.max(scroll:GetFrameLevel(),
            bar:GetFrameLevel() - 1))
        track:SetBackdrop(UI.SCROLL_TRACK_BACKDROP)
        scroll.uiScrollBar   = bar
        scroll.uiScrollTrack = track
        -- Hidden until SetScrollHeight says the content needs them. The
        -- template shows its bar from the start, so a scroll area whose
        -- height is measured after it appears would flash one for a frame.
        bar:Hide()
        track:Hide()
    end

    -- The scroll child's width has to track the viewport or the content lays
    -- itself out against the 1px placeholder above.
    scroll:HookScript("OnSizeChanged", function(self, w)
        if not ownWidth then content:SetWidth(w) end
        if self.uiContentHeight then UI.SetScrollHeight(self, self.uiContentHeight) end
    end)

    return scroll, content
end

-- Tell a scroll area how tall its content became. Hides the bar and its track
-- while everything fits, and snaps back to the top when it does - a scroll
-- offset left over from taller content strands the view on empty space.
function UI.SetScrollHeight(scroll, height)
    scroll.uiContentHeight = height
    scroll:GetScrollChild():SetHeight(math.max(height, 1))
    scroll:UpdateScrollChildRect()

    local needed = height > scroll:GetHeight() + 0.5
    if scroll.uiScrollBar   then scroll.uiScrollBar:SetShown(needed) end
    if scroll.uiScrollTrack then scroll.uiScrollTrack:SetShown(needed) end
    if not needed then scroll:SetVerticalScroll(0) end
end

-- A 10px shadow for the edge of a scroll area, dark against the edge and clear
-- toward the content, drawn at `level` so content scrolls under it (the
-- scroll's own level + 20 clears its rows and dropdowns). `top` says which
-- edge; the caller anchors and sizes it across. It takes no mouse. On a client
-- without gradients it is an empty frame.
function UI.CreateEdgeShadow(parent, level, top)
    local edge = CreateFrame("Frame", nil, parent)
    edge:SetHeight(10)
    edge:SetFrameLevel(level)
    local shadow = edge:CreateTexture(nil, "BACKGROUND")
    if not (shadow.SetGradient and CreateColor) then return edge end
    shadow:SetAllPoints()
    shadow:SetColorTexture(1, 1, 1, 1)
    -- Vertical gradients run bottom to top.
    local clear, dark = CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.55)
    if top then
        shadow:SetGradient("VERTICAL", clear, dark)
    else
        shadow:SetGradient("VERTICAL", dark, clear)
    end
    return edge
end

-- Pull a scroll area's bar in from both ends by `pad`. The template hangs its
-- arrow buttons right at the scroll area's ends, where they poke into whatever
-- borders it -- a heading, a divider, an edge shadow. The track follows the bar.
function UI.InsetScrollBar(scroll, pad)
    local bar = scroll.uiScrollBar
    if not bar then return end
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, -(16 + pad))
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 6, 16 + pad)
end

-- Size a scroll area to what its content actually covers, for a page laid out
-- by hand where nobody kept a running total. Measured off the shown children
-- and regions of the scroll child, a frame after the call: rects are not settled
-- until the layout pass after something is shown, so measuring on the spot
-- reads a page that is not there yet. `pad` is the room left under the lowest
-- thing, default 12.
function UI.FitScrollToContent(scroll, pad)
    local content = scroll:GetScrollChild()
    C_Timer.After(0, function()
        local top = content:GetTop()
        if not top then return end
        local lowest = top
        local function Consider(region)
            if not region:IsShown() then return end
            local bottom = region:GetBottom()
            if bottom and bottom < lowest then lowest = bottom end
        end
        for _, child in ipairs({ content:GetChildren() }) do Consider(child) end
        for _, region in ipairs({ content:GetRegions() }) do Consider(region) end
        UI.SetScrollHeight(scroll, top - lowest + (pad or 12))
    end)
end

--------------------------------------------------------------------------------
-- Sections
--
-- A section is a boxed list with a title and a right-aligned strip of header
-- buttons, stacked vertically with its siblings.
--------------------------------------------------------------------------------

UI.SECTION_GAP      = 10   -- between stacked section boxes
UI.SECTION_TITLE_H  = 22   -- box interior reserved for the title strip
UI.BOX_PAD          = 8    -- section box inner margin
UI.ROW_H            = 24
UI.ROW_ICON         = 18   -- gear/action icons on a row
UI.ROW_CHECK        = 22   -- a checkbox on a row. Bigger than the icons beside
                           -- it on purpose: it is the control, they are
                           -- shortcuts, and it is the one thing on the row that
                           -- has to be hittable without aiming.
UI.ROW_CLICK_FRAC   = 0.8  -- how much of a row's width toggles it. Its buttons
                           -- live at the right end, and missing one by a pixel
                           -- used to hit the stripe behind it instead.
UI.HEADER_BTN_SIZE  = 22
UI.HEADER_TEXT_MIN_W = 44  -- a header text button is never narrower than this
UI.HEADER_TEXT_PAD  = 18   -- label width to button width, for the side bevels
UI.HEADER_STRIP_TOP = 5    -- box top to the top of the header button strip
UI.EMPTY_ROWS_H     = 20   -- rows area height while the list is empty

UI.WARNING_ICON      = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"
UI.WARNING_ICON_SIZE = 18

local function TowardWhite(value, amount)
    return value + (1 - value) * amount
end

-- The neutral section panel colour, for a caller deriving a tint from it.
UI.SECTION_COLOR = { 0.16, 0.16, 0.18 }

-- Boxed section shell: a lighter inset panel with a title on the header strip's
-- midline, so the title text and the header buttons share a line.
--
-- Alternating row colours are derived from the panel colour and cached on the
-- box, so rows tint with the panel instead of being picked twice. `color` is an
-- optional { r, g, b } panel colour; nil is the neutral grey. `borderColor` is
-- likewise optional, grey when left out.
function UI.CreateSectionBox(parent, titleText, color, borderColor)
    local box = CreateFrame("Frame", nil, parent, UI.TEMPLATE)
    -- Explicit level: same-level siblings render in unstable order, and the box
    -- backdrop can end up drawing over its own rows until something moves and
    -- re-sorts the frames.
    box:SetFrameLevel(parent:GetFrameLevel() + 1)
    box:SetBackdrop(UI.PANEL_BACKDROP)
    color = color or UI.SECTION_COLOR
    local r, g, b = color[1], color[2], color[3]
    box:SetBackdropColor(r, g, b, 1)
    local edge = borderColor or { 0.4, 0.4, 0.4 }
    box:SetBackdropBorderColor(edge[1], edge[2], edge[3])
    box.rowColors = {
        { TowardWhite(r, 0.09), TowardWhite(g, 0.09), TowardWhite(b, 0.09) },
        { TowardWhite(r, 0.04), TowardWhite(g, 0.04), TowardWhite(b, 0.04) },
    }

    local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local font, size = title:GetFont()
    if font and size then title:SetFont(font, size + 2, "OUTLINE") end
    title:SetTextColor(0.95, 0.95, 0.95)
    -- Anchored by LEFT, which vertically centers a FontString, onto the header
    -- strip's midline. Move HEADER_STRIP_TOP and the title follows the buttons.
    title:SetPoint("LEFT", box, "TOPLEFT", UI.BOX_PAD + 2,
        -(UI.HEADER_STRIP_TOP + UI.HEADER_BTN_SIZE / 2))
    title:SetText(titleText)
    box.title = title

    box.headerChain, box.rows = {}, {}
    return box
end

-- A heading rule: a label near the left end, a short rule before it and a long
-- one after, both in the label's colour, faded. Width comes from where the
-- caller places it. `color` is { r, g, b }, a dark gold when left out.
-- The label and the two rules are `label`, `left` and `right` on the frame.
function UI.CreateDivider(parent, text, color)
    local r, g, b = 0.8, 0.65, 0.12
    if color then r, g, b = color[1], color[2], color[3] end
    local divider = CreateFrame("Frame", nil, parent)
    divider:SetHeight(10)
    local label = divider:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", 36, 0)
    label:SetText(text)
    label:SetTextColor(r, g, b)
    local left = divider:CreateTexture(nil, "ARTWORK")
    left:SetHeight(1)
    left:SetPoint("LEFT")
    left:SetPoint("RIGHT", label, "LEFT", -6, 0)
    left:SetColorTexture(r, g, b, 0.3)
    local right = divider:CreateTexture(nil, "ARTWORK")
    right:SetHeight(1)
    right:SetPoint("LEFT", label, "RIGHT", 6, 0)
    right:SetPoint("RIGHT")
    right:SetColorTexture(r, g, b, 0.3)
    divider.label, divider.left, divider.right = label, left, right
    return divider
end

-- The same section without the box: no panel or border, and its title is a
-- divider rule across the header strip, for sections sitting straight on a
-- page. Same geometry, fields and header chain as a boxed one, so a section
-- lays itself out identically either way. `color` tints the title and rule;
-- `rowColors` is the { odd, even } row stripes, which a box would derive from
-- its panel.
function UI.CreateFlatSection(parent, titleText, color, rowColors)
    local box = CreateFrame("Frame", nil, parent)
    box:SetFrameLevel(parent:GetFrameLevel() + 1)
    box.rowColors = rowColors
    box.headerChain, box.rows = {}, {}
    if not titleText then return box end

    local divider = UI.CreateDivider(box, titleText, color)
    local midline = -(UI.HEADER_STRIP_TOP + UI.HEADER_BTN_SIZE / 2)
    divider:SetPoint("LEFT", box, "TOPLEFT", 0, midline)
    divider:SetPoint("RIGHT", box, "TOPRIGHT", 0, midline)
    box.divider = divider
    box.title = divider.label
    return box
end

-- Re-anchor a box's header buttons right to left, skipping hidden ones, so the
-- rightmost VISIBLE button hugs the corner instead of leaving a hole. The chain
-- is stored rightmost-first. Run after anything that changes visibility. A
-- flat section's title rule stops short of the leftmost button.
function UI.LayoutHeaderChain(box)
    local prev
    for _, btn in ipairs(box.headerChain) do
        if btn:IsShown() then
            btn:ClearAllPoints()
            if prev then
                btn:SetPoint("RIGHT", prev, "LEFT", -2, 0)
            else
                btn:SetPoint("TOPRIGHT", box, "TOPRIGHT",
                    -UI.BOX_PAD, -UI.HEADER_STRIP_TOP)
            end
            prev = btn
        end
    end
    if box.divider then
        local rule = box.divider.right
        rule:ClearAllPoints()
        rule:SetPoint("LEFT", box.divider.label, "RIGHT", 6, 0)
        if prev then
            rule:SetPoint("RIGHT", prev, "LEFT", -6, 0)
        else
            rule:SetPoint("RIGHT", box.divider, "RIGHT")
        end
    end
end

--------------------------------------------------------------------------------
-- Tooltips
--------------------------------------------------------------------------------

-- A gold heading - the colour the game's own tooltips title with - a grey body,
-- and red for why a control will not answer.
UI.TOOLTIP_TITLE   = { 1, 0.82, 0 }
UI.TOOLTIP_BODY    = { 0.8, 0.8, 0.8 }
UI.TOOLTIP_PROBLEM = { 1, 0.4, 0.4 }

-- The tooltip's bottom-left corner on the cursor, which ANCHOR_CURSOR gets
-- close to but not exactly: it keeps a gap and flips the box about near an
-- edge, so the corner is somewhere different depending on where you point.
--
-- Placed against UIParent, and divided by the TOOLTIP's effective scale rather
-- than UIParent's. A SetPoint offset is measured in the units of the frame
-- being MOVED, not of the frame it is anchored to, and GameTooltip runs at its
-- own scale (the game has a slider for it). Dividing by UIParent's put the box
-- a long way below and left of the cursor on any client where the two differ.
--
-- The tooltip grows up and to the right from a BOTTOMLEFT point, so the corner
-- stays put as lines are added.
local function PinToCursor()
    local x, y = GetCursorPosition()
    local scale = GameTooltip:GetEffectiveScale()
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT",
        x / scale, y / scale)
end

-- One shared handler rather than a closure per hover, and it lets go the
-- moment the tooltip belongs to somebody else: another addon showing its own
-- while the mouse is still over ours would otherwise have it dragged about.
local function TrackCursor(self)
    if GameTooltip:IsOwned(self) then
        PinToCursor()
    else
        self:SetScript("OnUpdate", nil)
    end
end

local function AddColoredLine(text, color)
    GameTooltip:AddLine(text, color[1], color[2], color[3], true)
end

-- Fill and show GameTooltip for a hover on `owner`. Returns whether anything
-- was shown.
--
-- `title` is one of:
--   a string    the heading; `body` (a string, or a function(owner) returning
--               one) goes under it
--   a function  function(owner, tooltip) called with the tooltip already
--               owned, for content that is only known at hover time. Return
--               `title, body` to have them drawn as above; return `true` when
--               it has filled the tooltip itself; return nothing to show no
--               tooltip at all.
--
-- While `source` (default `owner`) is disabled and carries `disabledReason`,
-- that reason is shown in red: in place of the body for a plain tooltip, and
-- after the content for one that filled itself. A dead control explains itself
-- rather than just going grey.
--
-- Placement: bottom-left of the tooltip on the control's top-right, so it
-- opens up and to the right and stays where it opened. `follow` pins it to the
-- cursor instead and keeps it there while the mouse moves - for rows the width
-- of a box, where where you are pointing is the only clue to which tooltip you
-- asked for. A button is a few pixels square; a tooltip that jitters along with
-- the mouse over one just looks unwell.
function UI.ShowTooltip(owner, title, body, source, follow)
    source = source or owner
    GameTooltip:SetOwner(owner, "ANCHOR_NONE")
    local reason = source.IsEnabled and not source:IsEnabled()
        and source.disabledReason or nil

    local filled = false
    if type(title) == "function" then
        local result, fnBody = title(owner, GameTooltip)
        if result == true then
            filled = true
        elseif result then
            title, body = result, fnBody
        else
            GameTooltip:Hide()
            return false
        end
    end

    if filled then
        if reason then AddColoredLine(reason, UI.TOOLTIP_PROBLEM) end
    else
        local c = UI.TOOLTIP_TITLE
        GameTooltip:SetText(title or "", c[1], c[2], c[3])
        if type(body) == "function" then body = body(owner) end
        if reason then
            AddColoredLine(reason, UI.TOOLTIP_PROBLEM)
        elseif body then
            AddColoredLine(body, UI.TOOLTIP_BODY)
        end
    end
    GameTooltip:Show()

    -- Show() sizes it, so the corner is placed after rather than before.
    if follow then
        PinToCursor()
        -- Cleared on leave: an OnUpdate that outlived the hover would drag
        -- other addons' tooltips around.
        owner:SetScript("OnUpdate", TrackCursor)
    else
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("BOTTOMLEFT", owner, "TOPRIGHT", 0, 0)
    end
    return true
end

-- Standard tooltip for a control; see ShowTooltip for what the arguments mean.
--
-- `source` is for the frame that hovers standing in for a control that does
-- not: a row carrying its checkbox's tooltip asks the CHECKBOX whether it is
-- disabled and why, because a row has neither.
--
-- Any OnEnter/OnLeave the frame already has still runs, first - a highlight
-- set up before the tooltip is not lost to it.
function UI.AddTooltip(btn, title, body, source, follow)
    -- Without this a disabled widget stops firing OnEnter, so the explanation
    -- of WHY it is disabled goes away exactly when it is wanted.
    if btn.SetMotionScriptsWhileDisabled then
        btn:SetMotionScriptsWhileDisabled(true)
    end
    btn:EnableMouse(true)
    local previousEnter = btn:GetScript("OnEnter")
    local previousLeave = btn:GetScript("OnLeave")
    btn:SetScript("OnEnter", function(self, ...)
        if previousEnter then previousEnter(self, ...) end
        UI.ShowTooltip(self, title, body, source, follow)
    end)
    btn:SetScript("OnLeave", function(self, ...)
        if previousLeave then previousLeave(self, ...) end
        if follow then self:SetScript("OnUpdate", nil) end
        -- GetOwner rather than IsOwned: a dropdown's caption is a font string,
        -- and IsOwned refuses anything that is not a frame.
        if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
    end)
end

-- A dropdown's tooltip on every part of it people point at: the caption beside
-- it, the box - which is where the current value is written - and the arrow
-- button. Enabling the mouse on the dropdown frame is safe: its arrow is a
-- child button and still takes the clicks.
function UI.AddDropdownTooltip(dd, label, title, body)
    if label then UI.AddTooltip(label, title, body) end
    UI.AddTooltip(dd, title, body)
    local button = dd:GetName() and _G[dd:GetName() .. "Button"]
    if button then UI.AddTooltip(button, title, body) end
end

-- Shortcut hints ("Alt-Drag: move it") are reference material rather than the
-- answer the tooltip was opened for, so they are drawn a point below the body
-- font and let the content above them lead. Blizzard's own small tooltip font
-- is two sizes down and reads as fine print, so the hint font is derived from
-- the body's instead, which also keeps it following the player's tooltip font
-- scale.
local HINT_FONT = CreateFont(ADDON_NAME .. "TooltipHintFont")
do
    local path, size, flags = GameTooltipText:GetFont()
    HINT_FONT:SetFont(path, (size or 12) - 1, flags)
end

-- A tooltip pools its font strings across every tooltip it draws, so a shrunk
-- line has to be put back before the next content inherits it. Keyed by
-- tooltip: the value is the last line we shrank, and nil means we have not
-- hooked that tooltip's clear yet.
local hintLines = {}

local function RestoreHintFonts(tooltip)
    local name = tooltip:GetName()
    -- Line 1 is the header, in its own larger font, and never a hint.
    for i = 2, hintLines[tooltip] or 0 do
        local left = _G[name .. "TextLeft" .. i]
        local right = _G[name .. "TextRight" .. i]
        if left then left:SetFontObject(GameTooltipText) end
        if right then right:SetFontObject(GameTooltipText) end
    end
    hintLines[tooltip] = 0
end

-- One shortcut hint: "Alt-Drag:" on the left in gold, what it does on the
-- right. SetFontObject brings the font's own colour with it, so the line's
-- colours are re-applied after the shrink rather than before it. An unnamed
-- tooltip has no reachable font strings; it just keeps the body size.
function UI.AddTooltipHint(tooltip, shortcut, action, r, g, b)
    tooltip = tooltip or GameTooltip
    r, g, b = r or 1, g or 1, b or 1
    local c = UI.TOOLTIP_TITLE
    tooltip:AddDoubleLine(shortcut, action, c[1], c[2], c[3], r, g, b)
    local name = tooltip:GetName()
    if not name then return end
    if hintLines[tooltip] == nil then
        hintLines[tooltip] = 0
        tooltip:HookScript("OnTooltipCleared", RestoreHintFonts)
    end
    local i = tooltip:NumLines()
    local left = _G[name .. "TextLeft" .. i]
    local right = _G[name .. "TextRight" .. i]
    if left then
        left:SetFontObject(HINT_FONT)
        left:SetTextColor(c[1], c[2], c[3])
    end
    if right then
        right:SetFontObject(HINT_FONT)
        right:SetTextColor(r, g, b)
    end
    if i > hintLines[tooltip] then hintLines[tooltip] = i end
end

--------------------------------------------------------------------------------
-- Buttons and controls
--------------------------------------------------------------------------------

-- A text button with a tooltip, sized to its label: a fixed size crams longer
-- labels against the template's side bevels, and a bare "+" leaves a stretched
-- empty button. HEADER_BTN_SIZE tall, so it shares a strip with the icon and
-- close buttons; size it again after if it lives somewhere else.
function UI.CreateTextButton(parent, text, tooltipTitle, tooltipText, OnClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetFrameLevel(parent:GetFrameLevel() + 1)
    btn:SetHeight(UI.HEADER_BTN_SIZE)
    btn:SetText(text)
    btn:SetWidth(math.max(UI.HEADER_TEXT_MIN_W,
        btn:GetTextWidth() + UI.HEADER_TEXT_PAD))
    btn:SetScript("OnClick", OnClick)
    if tooltipTitle then UI.AddTooltip(btn, tooltipTitle, tooltipText) end
    return btn
end

-- The same, appended to a section box's header chain; call LayoutHeaderChain
-- to place it.
function UI.AddHeaderTextButton(box, text, tooltipTitle, tooltipText, OnClick)
    local btn = UI.CreateTextButton(box, text, tooltipTitle, tooltipText, OnClick)
    box.headerChain[#box.headerChain + 1] = btn
    return btn
end

-- The window's round red close button, reused for the small delete and
-- clear-all controls so they match the title bar's.
--
-- UIPanelCloseButton's texture is mostly transparent padding around a small X,
-- so the textures are grown past the frame: the visible X then fills the
-- button's footprint without the frame changing size and breaking the columns.
function UI.CreateCloseButton(parent, size, growFactor)
    local s = size or UI.HEADER_BTN_SIZE
    local btn = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    btn:SetFrameLevel(parent:GetFrameLevel() + 1)
    btn:SetSize(s, s)
    if btn.SetMotionScriptsWhileDisabled then
        btn:SetMotionScriptsWhileDisabled(true)
    end
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

-- The [x] of a section header. Same button, wired and chained.
function UI.AddHeaderCloseButton(box, tooltipTitle, tooltipText, OnClick)
    local btn = UI.CreateCloseButton(box)
    btn:SetScript("OnClick", OnClick)
    UI.AddTooltip(btn, tooltipTitle, tooltipText)
    box.headerChain[#box.headerChain + 1] = btn
    return btn
end

-- A checkbox, sized to sit in a row rather than at Blizzard's default 32px.
-- The label is optional: in a list the row's own text is the label, and a
-- second one beside the box just repeats it.
--
-- opts, all optional:
--   size         the box's side; default ROW_H - 4
--   font         the label's font object; default GameFontNormal
--   gap          box to label; default 4
--   labelParent  where the label lives; default the checkbox itself, so it
--                hides and fades with the box. A caller that fades the two
--                separately parents it elsewhere, or the fades multiply.
--
-- A nil tooltipTitle leaves the tooltip off. OnClick is the raw script,
-- (self, button).
function UI.CreateCheckbox(parent, labelText, tooltipTitle, tooltipText, OnClick, opts)
    opts = opts or {}
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetFrameLevel(parent:GetFrameLevel() + 1)
    local size = opts.size or (UI.ROW_H - 4)
    cb:SetSize(size, size)
    cb:SetScript("OnClick", OnClick)
    if labelText then
        local label = (opts.labelParent or cb):CreateFontString(nil, "OVERLAY",
            opts.font or "GameFontNormal")
        label:SetPoint("LEFT", cb, "RIGHT", opts.gap or 4, 0)
        label:SetText(labelText)
        cb.label = label
    end
    if tooltipTitle then UI.AddTooltip(cb, tooltipTitle, tooltipText) end
    return cb
end

-- The checkbox at the left edge of a section row, and the row behind it as a
-- click target: a checkbox you have to hit exactly is a checkbox people miss,
-- so the label, the icon and the empty space after them toggle it too - out to
-- UI.ROW_CLICK_FRAC, short of wherever the row's own buttons sit.
-- Guarded on the box being live, because a row greyed out by a master
-- switch must not stay clickable through its stripe.
--
-- Stored as row.check, which is where every refresh looks for it.
function UI.AddRowCheckbox(row, labelText, tooltipTitle, tooltipText, OnClick)
    local cb = UI.CreateCheckbox(row, labelText, tooltipTitle, tooltipText,
        OnClick)
    cb:SetSize(UI.ROW_CHECK, UI.ROW_CHECK)
    cb:SetPoint("LEFT", 4, 0)
    row.check = cb

    row:EnableMouse(true)
    -- ...but only the left of the row, so the space around its buttons is not a
    -- second, larger target for the wrong thing. Re-cut on resize: the width is
    -- anchor-driven and still zero here.
    row:SetScript("OnSizeChanged", function(self, width)
        self:SetHitRectInsets(0, (width or 0) * (1 - UI.ROW_CLICK_FRAC), 0, 0)
    end)
    row:SetScript("OnMouseUp", function()
        if cb:IsEnabled() then cb:Click() end
    end)
    -- The row explains itself as well as toggling: the box is a few pixels
    -- square and the sentence about what it does is the reason to look. Same
    -- click area, so anything that toggles on hover also has a tooltip.
    UI.AddTooltip(row, tooltipTitle, tooltipText, cb, true)
    return cb
end

-- Enable or grey out a run of widgets in one call, for a master switch that
-- turns off everything under it.
--
-- Buttons and checkboxes are disabled, which keeps their tooltips alive
-- (AddTooltip sets MotionScriptsWhileDisabled) so a greyed control can still
-- say why it is greyed. Textures and font strings have no disabled state, so
-- they are faded instead - and fading everything means the disabled ones read
-- as off too, rather than only slightly different.
function UI.SetEnabled(enabled, ...)
    for i = 1, select("#", ...) do
        local w = select(i, ...)
        if w then
            if w.Enable and w.Disable then
                if enabled then w:Enable() else w:Disable() end
            end
            if w.SetAlpha then w:SetAlpha(enabled and 1 or 0.35) end
        end
    end
end

-- A horizontal slider, dressed by hand rather than taken from
-- OptionsSliderTemplate.
--
-- The template was the source of the mismatched end caps. It ships a frame
-- height that does not suit the border art (see UI.SLIDER_H), it carries Low,
-- High and Text regions we blank on every single slider anyway, and the numbers
-- behind all of that differ by client - which is a lot of art we do not control
-- in exchange for three font strings we do not want.
--
-- What is here instead is what AceGUI-3.0 and DBM-GUI both do, to the pixel: a
-- bare Slider on BackdropTemplate, explicitly horizontal, 15 tall, with the
-- SliderBar backdrop and the SliderBar thumb. Those two are the reference
-- implementation by sheer weight of use, and a slider that matches them is a
-- slider that looks like every other addon's.
--
-- `globalName` is no longer needed for region lookups, but it stays: it is what
-- makes a control findable from a /script line while debugging, and callers
-- already pass one.
function UI.CreateSlider(parent, globalName, minValue, maxValue, step, OnChange)
    local s = CreateFrame("Slider", globalName, parent, UI.TEMPLATE)
    s:SetFrameLevel(parent:GetFrameLevel() + 1)
    s:SetOrientation("HORIZONTAL")
    s:SetWidth(180)
    s:SetHeight(UI.SLIDER_H)
    -- The trough is a backdrop and the handle is a thumb texture, both left at
    -- the art's own size. Guarded only because SetBackdrop lives on the
    -- template, and UI.TEMPLATE resolves to nil on a client without it.
    if s.SetBackdrop then s:SetBackdrop(UI.SLIDER_BACKDROP) end
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    -- 15px of grabbable height is a thin target for something people drag.
    -- Widened a little top and bottom, but nowhere near AceGUI's -10: its
    -- sliders have empty space under them and ours have the next setting.
    s:SetHitRectInsets(0, 0, -4, -4)
    s:SetMinMaxValues(minValue, maxValue)
    s:SetValueStep(step)
    -- Retail-era addition, present on both clients, guarded like every other
    -- optional member. Without it a drag reports every fractional position.
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end

    s:SetScript("OnValueChanged", function(self, value)
        -- SetValue fires this too. Without the guard, a refresh that pushes the
        -- saved value in would call back and re-save it, and a drag would fight
        -- the refresh for the handle.
        if self.settingValue then return end
        if OnChange then OnChange(self, value) end
    end)

    -- Let go of the handle. A drag reports every step it passes through, so
    -- anything expensive or audible hangs off this rather than off OnChange:
    -- dragging 0 to 100 is twenty values and one release. Fires on a click on
    -- the track too, which is a jump to a value and equally a release.
    s:SetScript("OnMouseUp", function(self)
        if self.OnRelease then self:OnRelease(self:GetValue()) end
    end)
    return s
end

-- Push a value in without the OnChange coming back out.
function UI.SetSliderValue(s, value)
    s.settingValue = true
    s:SetValue(value)
    s.settingValue = nil
end

-- A whole-number slider with a number box beside it, for a setting where
-- dragging is for finding the value and typing is for knowing it. No range is
-- written under it, so it fits on one row beside its label. The caller anchors
-- the slider; the box follows it.
--
-- spec: { name, min, max, width }
-- Get() returns the saved value, Set(value) saves one, OnChange() runs after a
-- save. Returns the slider, the box, and a Refresh that repaints both from Get.
--
-- The box is deliberately left alone while it is being typed in. Rewriting
-- what somebody is halfway through entering - clamping a "5" that was going to
-- be "50", or refusing the keystroke outright - fights them for their own
-- cursor, so nothing is read out of it until Enter or the focus leaving, and
-- anything that isn't a number in range at that point simply puts the saved
-- value back.
function UI.CreateSliderWithInput(parent, spec, Get, Set, OnChange)
    local slider = UI.CreateSlider(parent, spec.name, spec.min, spec.max, 1)
    slider:SetWidth(spec.width or 150)

    local edit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    edit:SetSize(40, 20)
    edit:SetPoint("LEFT", slider, "RIGHT", 18, 0)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(4)
    edit:SetJustifyH("CENTER")

    -- Both widgets show the same number, and writing it into either one fires
    -- that one's own change script - so the write is fenced off rather than
    -- allowed to come back round as a fresh edit.
    local painting = false
    local function Paint(value)
        painting = true
        UI.SetSliderValue(slider, value)
        edit:SetText(tostring(value))
        edit:SetCursorPosition(0)
        painting = false
    end

    local function Commit(value)
        value = math.floor(math.max(spec.min, math.min(spec.max, value)) + 0.5)
        Set(value)
        Paint(value)
        if OnChange then OnChange() end
    end

    slider:SetScript("OnValueChanged", function(self, value)
        if painting or self.settingValue then return end
        Commit(value)
    end)

    local function ReadBox()
        local typed = tonumber(edit:GetText())
        if typed then Commit(typed) else Paint(Get()) end
        edit:ClearFocus()
    end
    edit:SetScript("OnEnterPressed", ReadBox)
    edit:SetScript("OnEditFocusLost", ReadBox)
    edit:SetScript("OnEscapePressed", function()
        Paint(Get())
        edit:ClearFocus()
    end)

    return slider, edit, function() Paint(Get()) end
end

-- Teach an already-built dropdown frame a list of { value, label }, and give it
-- a `Sync` that puts the current value's label in the box.
--
-- Split out of CreateDropdown because the pop-up in CreatePrompt builds its
-- dropdown itself - it has to, since a UIDropDownMenuTemplate finds its regions
-- by global name and the pop-up's is named after the pop-up. Sharing this
-- initialiser is what lets the pop-up have submenus too.
--
-- `List` is asked for the entries on every open rather than handed them once:
-- an entry whose label reports something that moves - where you currently are,
-- what a setting currently costs - is frozen and wrong otherwise, and a list
-- that is expensive to build is the caller's problem to memoise.
--
-- `Selected` is asked for the current value the same way, so the control cannot
-- disagree with what it is showing.
--
-- An entry carrying `entries` instead of a `value` is a SUBMENU holding that
-- list. This is not decoration: Blizzard's dropdown draws its buttons in one
-- column and does not scroll them, so a list long enough to reach past the
-- screen edge simply has a bottom nobody can get to - which is what any list
-- borrowed from a media pack does the moment it is more than a screenful.
-- Grouping is the caller's business, since only the caller knows
-- what the list means; all this knows is how to nest one.
local function BindDropdown(dd, List, Selected, OnPick)
    -- Depth first: the label for the box has to be found wherever in the tree
    -- the value ended up, and the caller does not tell us where that was.
    local function Find(value, list)
        for _, entry in ipairs(list) do
            if entry.entries then
                local found = Find(value, entry.entries)
                if found then return found end
            elseif entry.value == value then
                return entry.label
            end
        end
    end

    local function Label(value)
        return Find(value, List() or {}) or tostring(value)
    end

    -- `menuList` is whatever the parent button put in info.menuList, and comes
    -- back here when a submenu opens - so one initialiser serves every level.
    UIDropDownMenu_Initialize(dd, function(_, level, menuList)
        local current = Selected()
        for _, entry in ipairs(menuList and menuList.entries or List() or {}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = entry.label
            if entry.entries then
                -- notCheckable, because a submenu is a way through rather than
                -- a choice: a tick box beside it would be a tick nobody can set.
                info.hasArrow, info.notCheckable = true, true
                info.menuList = entry
            else
                info.checked = entry.value == current
                -- An entry may name a Font OBJECT to draw its own label with.
                -- A font list that shows each name in the font it names is the
                -- whole point of a font list, and a dropdown button takes a
                -- font object or nothing - there is no other way in.
                info.fontObject = entry.font
                info.func = function()
                    OnPick(entry.value)
                    UIDropDownMenu_SetText(dd, Label(entry.value))
                    CloseDropDownMenus()   -- every level, not just this one
                end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    function dd:Sync() UIDropDownMenu_SetText(self, Label(Selected())) end
    return dd
end

-- A divider line in an open dropdown menu, for a menu initialiser that groups
-- its own entries. The separator API is missing on some clients; a blank,
-- disabled entry is the same gap without the line.
function UI.AddDropdownDivider(level)
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

-- A dropdown bound to a list of { value, label }, or to a function returning
-- one. Blizzard's dropdown carries a lot of transparent housing, so
-- StyleDropdown trims it to something that fits a row; see that function for
-- the numbers. Everything about the list itself is in BindDropdown above.
function UI.CreateDropdown(parent, globalName, width, choices, Selected, OnPick)
    local dd = CreateFrame("Frame", globalName, parent, "UIDropDownMenuTemplate")
    dd:SetFrameLevel(parent:GetFrameLevel() + 1)
    UI.SetDropdownWidth(dd, width)
    UI.StyleDropdown(dd, true)

    BindDropdown(dd, function()
        return type(choices) == "function" and choices() or choices
    end, Selected, OnPick)

    dd:Sync()
    return dd
end

-- A styled dropdown whose menu the caller builds itself: `Initialize` is the
-- UIDropDownMenu_Initialize callback, (frame, level, menuList). For a menu
-- that is not a flat list of values - toggles, dividers, per-row state - where
-- CreateDropdown's binding would be in the way. The caller anchors it.
function UI.CreateMenuDropdown(parent, globalName, width, Initialize)
    local dd = CreateFrame("Frame", globalName, parent, "UIDropDownMenuTemplate")
    UI.SetDropdownWidth(dd, width)
    UI.StyleDropdown(dd, true)
    if Initialize then UIDropDownMenu_Initialize(dd, Initialize) end
    return dd
end

-- Resize a dropdown. UIDropDownMenu_SetWidth also resets the label's width,
-- which silently undoes the extra room StyleDropdown gives a left-aligned
-- label - so a dropdown that is resized after styling goes through here.
function UI.SetDropdownWidth(dd, width)
    UIDropDownMenu_SetWidth(dd, width)
    local label = dd.uiTextAligned and dd:GetName() and _G[dd:GetName() .. "Text"]
    if label then label:SetWidth(label:GetWidth() + UI.DROPDOWN_LABEL_GROW) end
end

UI.GEAR_ICON = "Interface\\Buttons\\UI-OptionsButton"
-- The circular arrows on the LFG tool's refresh button.
UI.REFRESH_ICON = "Interface\\Buttons\\UI-RefreshButton"
-- The old voice-chat speaker, which is the only plain volume glyph the client
-- ships outside an ability icon. If it ever comes up blank this is the one line
-- to change - a missing texture draws as nothing rather than erroring.
UI.SPEAKER_ICON = "Interface\\COMMON\\VoiceChat-Speaker"

-- A framed button with an icon inside it rather than a bare texture, so it
-- matches the [x] and the text buttons beside it and lands in the same column -
-- a naked icon in a row of framed buttons reads as a different kind of control.
-- The 14px icon inside a 22px button is what leaves it room to look like a
-- button at all.
function UI.CreateIconButton(parent, iconPath, tooltipTitle, tooltipText, OnClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetFrameLevel(parent:GetFrameLevel() + 1)
    btn:SetSize(UI.HEADER_BTN_SIZE, UI.HEADER_BTN_SIZE)
    btn:SetText("")
    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(iconPath)
    btn.icon = icon
    btn:SetScript("OnClick", OnClick)
    UI.AddTooltip(btn, tooltipTitle, tooltipText)
    return btn
end

-- The Blizzard arrow art sits off-centre inside its texture - the up caret
-- rides high, the down caret low - so each is nudged to sit visually centred.
local ARROW_NUDGE = { Up = 2, Down = -4, Left = 0, Right = 0 }

local function SetArrowEnabled(btn, enabled)
    btn:SetEnabled(enabled)
    -- The template greys its own chrome but not a texture laid over it.
    btn.arrow:SetDesaturated(not enabled)
    local shade = enabled and 1 or 0.5
    btn.arrow:SetVertexColor(shade, shade, shade)
end

-- A framed button with an arrow in it, for moving something up or down a list.
-- `direction` is "Up", "Down", "Left" or "Right"; `size` defaults to 24.
-- Enable and disable it with `btn:SetArrowEnabled(on)`, which dims the arrow
-- along with the frame.
function UI.CreateArrowButton(parent, direction, size)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(size or 24, size or 24)
    btn:SetText("")
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetSize(12, 12)
    arrow:SetPoint("CENTER", 0, ARROW_NUDGE[direction] or 0)
    arrow:SetTexture("Interface\\Buttons\\Arrow-" .. direction .. "-Up")
    btn.arrow = arrow
    btn.SetArrowEnabled = SetArrowEnabled
    return btn
end

-- The gear, by far the commonest of these. Kept as its own name because every
-- caller of it means "settings" rather than "a button with a picture on".
function UI.CreateGearButton(parent, tooltipTitle, tooltipText, OnClick)
    return UI.CreateIconButton(parent, UI.GEAR_ICON,
        tooltipTitle, tooltipText, OnClick)
end

-- The icon and nothing else - no frame, no fill. For a row that already has a
-- framed button on it: two of those side by side read as a button bar, where
-- the point is one control and one shortcut.
--
-- It highlights on hover instead, which is what says it can be clicked. The
-- click target is the button, so it stays the full size whatever the art does.
function UI.CreateBareIconButton(parent, iconPath, size, tooltipTitle,
                                 tooltipText, OnClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetFrameLevel(parent:GetFrameLevel() + 1)
    btn:SetSize(size, size)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(iconPath)
    btn.icon = icon

    btn:SetScript("OnClick", OnClick)
    UI.AddTooltip(btn, tooltipTitle, tooltipText)

    -- Dimmed until you point at it, so a row of them does not shout over the
    -- labels they sit beside. HOOKED rather than set: AddTooltip owns OnEnter
    -- and OnLeave, and setting them after it would take the tooltip with them.
    icon:SetVertexColor(0.75, 0.75, 0.75)
    btn:HookScript("OnEnter", function(self)
        self.icon:SetVertexColor(1, 1, 1)
    end)
    btn:HookScript("OnLeave", function(self)
        self.icon:SetVertexColor(0.75, 0.75, 0.75)
    end)
    return btn
end

-- A warning (!) that explains itself on hover. The caller sets `.tooltipText`
-- and shows or hides it; with no text there is nothing to say and no tooltip.
-- `title` replaces the plain tooltip - a string, or a function as ShowTooltip
-- takes - for a warning with more to say than one sentence. Starts hidden.
function UI.CreateWarningIcon(parent, size, title)
    local warn = CreateFrame("Frame", nil, parent)
    warn:SetSize(size or UI.WARNING_ICON_SIZE, size or UI.WARNING_ICON_SIZE)
    local tex = warn:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture(UI.WARNING_ICON)
    warn.icon = tex
    UI.AddTooltip(warn, title or function(self)
        if self.tooltipText then return "Warning", self.tooltipText end
    end)
    warn:Hide()
    return warn
end

-- The alternating stripe behind a row, in the box's own row colours so rows
-- tint with their panel. Opaque, so adjacent rows meet without divider lines.
-- For a row that is positioned by its caller rather than by CreateSectionRow.
function UI.AddRowBackground(box, row, index)
    local color = box.rowColors[index % 2 == 1 and 1 or 2]
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(color[1], color[2], color[3], 1)
    return bg
end

-- One section row at the standard grid position: full box width inside the
-- padding, ROW_H tall, row #index sitting under the title strip. Rows are
-- pooled on the box - a refresh reuses row 1 rather than creating a new one -
-- so the caller asks for a row by index and fills it.
function UI.CreateSectionRow(box, index)
    local row = box.rows[index]
    if row then return row end

    -- Rows normally hang off the box itself, below its title and whatever strip
    -- has been reserved. A box given its own scroll area (ScrollSectionRows)
    -- puts them in the scroll child instead, where neither offset applies -
    -- the child IS the rows area.
    local host = box.rowHost or box
    local pad  = box.rowHost and 0 or UI.BOX_PAD
    local top  = (box.rowHost and 0
        or (UI.BOX_PAD + UI.SECTION_TITLE_H + (box.rowsInset or 0)))
        + (index - 1) * UI.ROW_H

    row = CreateFrame("Frame", nil, host)
    row:SetFrameLevel(host:GetFrameLevel() + 1)
    row:SetHeight(UI.ROW_H)
    row:SetPoint("TOPLEFT", pad, -top)
    row:SetPoint("TOPRIGHT", -pad, -top)
    UI.AddRowBackground(box, row, index)

    box.rows[index] = row
    return row
end

-- Grey hint in the rows area, for a section with nothing to show.
function UI.CreateEmptyHint(box)
    local hint = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", UI.BOX_PAD + 4,
        -(UI.BOX_PAD + UI.SECTION_TITLE_H + (box.rowsInset or 0) + 4))
    hint:SetTextColor(0.55, 0.55, 0.55)
    return hint
end

-- Reserve a strip between a box's title and its first row, for a box whose top
-- is a picture rather than a list. The caller fills the strip itself.
--
-- MUST be called before any row is created: a row anchors once, at creation,
-- and a pooled row that already exists will not move for this.
function UI.ReserveSectionStrip(box, height)
    box.rowsInset = height
end

-- Give a box its own scroll area for its rows, capped at `maxRows` tall.
--
-- For a list with no natural ceiling. Without it a box simply grows and the
-- PAGE scrolls, which is right for a handful of settings and wrong for a list
-- somebody can keep adding to: one long list otherwise pushes everything under
-- it off the bottom, and you scroll the whole tab to reach the next section.
--
-- Must be called before any row is created - a row anchors once, at creation,
-- and rows made before this belong to the box rather than to the scroll child.
--
-- `globalName` is required by UIPanelScrollFrameTemplate; see CreateScroll.
function UI.ScrollSectionRows(box, globalName, maxRows)
    local scroll = UI.CreateScroll(box, globalName)
    scroll:SetPoint("TOPLEFT", UI.BOX_PAD,
        -(UI.BOX_PAD + UI.SECTION_TITLE_H + (box.rowsInset or 0)))
    scroll:SetPoint("BOTTOMRIGHT", -(UI.BOX_PAD + UI.SCROLLBAR_W), UI.BOX_PAD)
    box.rowScroll, box.rowHost, box.maxRows = scroll, scroll:GetScrollChild(), maxRows
end

-- Size a box to hold `count` rows, and hide any pooled row past that count.
-- An empty list still gets EMPTY_ROWS_H so the hint has somewhere to sit.
function UI.SetSectionRowCount(box, count)
    for i = count + 1, #box.rows do box.rows[i]:Hide() end
    local rowsH = count > 0 and count * UI.ROW_H or UI.EMPTY_ROWS_H

    -- A scrolling box stops growing at its cap and lets the bar take over. The
    -- scroll child keeps the FULL height either way - that is what there is to
    -- scroll through.
    local shown = rowsH
    if box.rowHost then
        UI.SetScrollHeight(box.rowScroll, rowsH)
        shown = min(rowsH, box.maxRows * UI.ROW_H)
    end
    box:SetHeight(UI.BOX_PAD * 2 + UI.SECTION_TITLE_H
        + (box.rowsInset or 0) + shown)
end

-- Stack visible section boxes down a parent, chaining each to the one above so
-- a hidden box leaves no gap. Returns the total height, which is what a scroll
-- area wants to hear. Idempotent - safe to run on every refresh.
--
-- By default the boxes span the parent's width. Given `x`, they are a column
-- instead: they keep their own widths and hang from `x` along the parent's top,
-- which is how several stacks share one parent side by side.
function UI.StackSections(parent, boxes, x)
    local prev, total = nil, 0
    for _, box in ipairs(boxes) do
        if box:IsShown() then
            box:ClearAllPoints()
            if prev then
                box:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -UI.SECTION_GAP)
                if not x then
                    box:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -UI.SECTION_GAP)
                end
            elseif x then
                box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, 0)
            else
                box:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
                box:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
            end
            prev = box
            total = total + box:GetHeight() + UI.SECTION_GAP
        end
    end
    return total
end

--------------------------------------------------------------------------------
-- Prompts
--
-- One reusable modal per addon: a title bar, a name field, an optional dropdown
-- and Accept. Reconfigured per Ask rather than rebuilt, so the same window
-- serves every "add a thing" control and they all behave identically.
--
-- Not a StaticPopup. StaticPopupDialogs cannot carry a dropdown without
-- anchoring one to a frame it does not own, and its stack is Blizzard's - the
-- rest of the addon keeps preferredIndex 3 to stay off it.
--------------------------------------------------------------------------------

local PROMPT_W        = 300   -- default; opts.width widens one that needs it
local PROMPT_PAD      = UI.BOX_PAD + 6
local PROMPT_BASE_H   = 128   -- title bar + edit box + buttons, with room
local PROMPT_ROW_H    = 40    -- added when the dropdown is in play
local PROMPT_SLIDER_H = 50    -- added when the slider is in play: caption over
                              -- handle, so two lines rather than one
local PROMPT_TOGGLE_H = 26    -- and when the checkbox is
local PROMPT_CHECK_MS = 0.4   -- typing settles this long before Validate runs
local PROMPT_BTN_W    = 84    -- both of them, so the pair on the right lines up
local PROMPT_FIELD_H  = 22    -- added when the field carries a caption line
local PROMPT_EDIT_H   = 30    -- the edit box row itself
-- How far a caption sits above the control it names. Shorter than
-- PROMPT_FIELD_H, which is what the caption COSTS the frame: the line itself is
-- about 14px tall, so stepping the layout by the full 22 left a caption
-- floating clear of its own box. The frame still grows by PROMPT_FIELD_H - the
-- difference lands as breathing room at the bottom rather than as a gap between
-- a label and the thing it labels.
local PROMPT_CAP_H    = 16
-- The same trick the other way round: how far the layout steps PAST the toggle,
-- which is more than the toggle COSTS the frame. The switch governs everything
-- under it rather than belonging to it, so it wants clear air beneath it - and
-- the gap comes out of the slack at the bottom rather than making the frame
-- taller again.
local PROMPT_TOGGLE_STEP = PROMPT_TOGGLE_H + 10
-- Transparent padding on the left of Blizzard's dropdown housing. Subtracted
-- from the dropdown's x so its visible left edge lands in the same column as
-- the edit box above it rather than 22px inboard of it.
local PROMPT_DD_LEAD  = 22
-- The mirror of it on the right, and the reason the dropdown can be SIZED to
-- the field above it rather than guessed at.
--
-- UIDropDownMenu_SetWidth(w) sets the MIDDLE texture to w. What gets drawn is
-- Left + Middle + Right, so the housing is w + PROMPT_DD_CAPS wide, of which
-- PROMPT_DD_LEAD on the left and PROMPT_DD_TRAIL on the right are transparent -
-- and a visible width of v therefore wants w = v + LEAD + TRAIL - CAPS.
--
-- CAPS is the two 25px end textures, NOT the 25 that SetWidth adds to the
-- frame's own width: the art overhangs the frame, which is why sizing off the
-- frame put the right-hand end cap 25px outside the pop-up.
local PROMPT_DD_TRAIL = 17
local PROMPT_DD_CAPS  = 50    -- Left and Right, 25px of housing art each
-- Grey text under the dropdown, saying what the thing just picked IS. It wraps,
-- so its height is measured rather than declared; this is only the air left
-- under it before whatever comes next.
local PROMPT_NOTE_GAP = 10

-- The first value in a list, submenus included. What a prompt starts on when
-- the caller did not say - and a caller who groups a long list has a first
-- entry that is a group rather than a choice, so this cannot just read [1].
local function FirstChoice(list)
    for _, entry in ipairs(list or {}) do
        if entry.entries then
            local found = FirstChoice(entry.entries)
            if found ~= nil then return found end
        elseif entry.value ~= nil then
            return entry.value
        end
    end
end

-- opts:
--   title    the title bar's text; no version stamp, unlike a window's
--   width    frame width; defaults to PROMPT_W
--   hint     greyed text inside the empty edit box, e.g. "Character name"
--   text     value the edit box opens with (may be nil)
--   choices  { { value = ..., label = ... }, ... }, or a function returning
--            one; nil hides the dropdown. An entry with `entries` instead of a
--            `value` is a submenu - see BindDropdown. Sits ABOVE the field: a
--            list of what is on offer is the choice, and the field under it is
--            the escape hatch for what is not on it.
--   choice   which choice value starts selected
--   choiceLabel  caption over the dropdown; nil leaves it unlabelled
--   note     grey wrapped text UNDER the dropdown, or a function(choiceValue)
--            returning one, re-read every time a choice is picked. For saying
--            what the thing just chosen actually is - which a tooltip would
--            say too, except that a tooltip is only read by somebody who
--            already suspects they need it.
--   maxLetters  cap on the edit box, 0 or nil for no cap
--   OnChoice function(choiceValue), as it is picked. For previewing what was
--            just chosen; the answer itself still arrives at OnAccept.
--   Field    function(choiceValue) -> show the edit box for this choice? Absent
--            means always, which is every prompt that predates the dropdown.
--            A hidden field takes its caption with it, and stops being able to
--            hold the accept button down - there is nothing in it to judge.
--   slider   { label, min, max, step, value, OnChange } or nil for no slider.
--            Caption over the handle, both centred. Live: OnChange fires as it
--            moves, for a setting whose point is seeing or hearing it change.
--   toggle   { label, checked, OnClick } or nil. A centred checkbox above
--            everything else, applied on click rather than on accept. It
--            GOVERNS what is below it: unticked, the dropdown, the field and
--            the slider all grey out.
--   reset    function; adds a Reset button. Closes the prompt.
--   accept   accept button label, default "Add"
--   allowEmpty  accept an empty box; for a prompt where blank means "reset".
--            A field the current choice has hidden counts as this whatever it
--            says - there was nothing to type, so an empty one is not a slip.
--   Validate function(text) -> ok, reason. Runs a moment after typing stops and
--            greys the accept button when it says no. Return nil to abstain -
--            a validator with no opinion must not disable anything.
--   OnAccept function(text, choiceValue) - not called with an empty name
function UI.CreatePrompt(globalName)
    -- A window like the addon's others, title bar and all. The bar carries the
    -- name of the thing being edited, and its close button is the way out, so
    -- there is no Cancel button.
    local p = UI.CreateWindow(globalName, PROMPT_W, PROMPT_BASE_H, "")
    -- Above DIALOG so it lands on top of the window that opened it.
    p:SetFrameStrata("FULLSCREEN_DIALOG")

    -- A caption in front of the box, for a prompt whose field needs naming.
    -- Hidden when there is nothing to say, and then the box takes the full
    -- width as before.
    local editLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    -- Same width as the slider caption below it, so the field and the handle
    -- start in the same column.
    editLabel:SetJustifyH("CENTER")
    p.editLabel = editLabel

    -- Anchored to both edges rather than given a width, so opts.width is the
    -- only place a size is decided.
    local edit = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    edit:SetHeight(20)
    edit:SetPoint("RIGHT", p, "RIGHT", -PROMPT_PAD, 0)
    edit:SetAutoFocus(true)
    p.edit = edit

    -- Placeholder. This client's EditBox has no Instructions region, so it is a
    -- font string on top of the box, hidden the moment there is anything to
    -- read underneath it.
    local hint = edit:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 4, 0)
    p.hint = hint

    -- Why the accept button is grey, under the box that caused it.
    local problem = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    problem:SetPoint("TOPLEFT", edit, "BOTTOMLEFT", 2, -3)
    problem:SetTextColor(1, 0.35, 0.35)
    problem:Hide()
    p.problem = problem

    -- A caption in front of the dropdown. LEFT, unlike the field's: the field
    -- is the full width of the pop-up so a centred caption sits over its middle,
    -- and the dropdown is not, so a centred one would float off its right edge.
    local choiceLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    choiceLabel:SetJustifyH("LEFT")
    p.choiceLabel = choiceLabel

    -- UIDropDownMenuTemplate finds its own regions by name, so this one needs
    -- a global name of its own even though nothing else looks it up. Placed by
    -- the layout in Ask rather than chained to anything here: the field it used
    -- to hang off can be hidden now, and an anchor to a hidden frame is an
    -- anchor to wherever that frame was last put.
    local dd = CreateFrame("Frame", globalName .. "Choice", p,
        "UIDropDownMenuTemplate")
    UI.StyleDropdown(dd, true)
    p.dropdown = dd

    -- What the current choice means, in a sentence or two, under the list that
    -- picked it. Grey and wrapped: it is an explanation, not a control, and it
    -- must not read as a second caption for the field below it.
    local note = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetJustifyH("LEFT")
    note:SetJustifyV("TOP")
    note:SetTextColor(0.62, 0.62, 0.62)
    note:Hide()
    p.note = note

    -- Bound once, here, rather than re-initialised on every Ask. The list and
    -- the current value are both read back through `p`, so a new Ask changing
    -- either is picked up without the menu being rebuilt - which is also what
    -- lets the pop-up have submenus, since it shares the initialiser every
    -- other dropdown in the addon uses.
    BindDropdown(dd,
        function()
            local choices = p.opts and p.opts.choices
            return type(choices) == "function" and choices() or choices
        end,
        function() return p.choice end,
        function(value)
            p.choice = value
            if p.opts and p.opts.OnChoice then p.opts.OnChoice(value) end
            -- The field may live or die by this choice, so the frame is laid
            -- out again rather than just redrawn.
            p:LayoutPrompt()
        end)

    -- Caption over the handle, both centred; see the layout. A slider stretched
    -- across the whole pop-up reads as the main event; this one is a detail.
    local sliderLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sliderLabel:SetJustifyH("CENTER")
    p.sliderLabel = sliderLabel

    local slider = UI.CreateSlider(p, globalName .. "Slider", 0, 100, 5, nil)
    slider:SetWidth(150)
    p.slider = slider

    -- A switch on the pop-up itself, for the setting somebody came here to
    -- change but would otherwise have to close this and find on another tab.
    p.toggle = UI.CreateCheckbox(p, "", "", "", nil)
    p.toggle:SetSize(UI.ROW_CHECK, UI.ROW_CHECK)

    -- Reset and the accept button, paired at the right and both the same width.
    -- There is no Cancel: the close button on the title bar is the way out, and
    -- Escape still closes this frame like every other window in the addon.
    local accept = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    accept:SetSize(PROMPT_BTN_W, 22)
    accept:SetPoint("BOTTOMRIGHT", -PROMPT_PAD, UI.INSET + 8)
    p.accept = accept

    local reset = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    reset:SetSize(PROMPT_BTN_W, 22)
    reset:SetPoint("RIGHT", accept, "LEFT", -6, 0)
    reset:SetText("Reset")
    p.reset = reset

    local function Accept()
        local text = strtrim(edit:GetText() or "")
        -- An empty box is normally a mis-click, not an answer. A prompt that
        -- means something BY being empty says so - and so does one where the
        -- box is not on screen at all, since then the answer is the dropdown's
        -- and there was never anything to type.
        if text == "" and not (p.allowEmpty or not edit:IsShown()) then return end
        if not accept:IsEnabled() then return end
        p:Hide()
        if p.OnAccept then p.OnAccept(text, p.choice) end
    end
    accept:SetScript("OnClick", Accept)
    edit:SetScript("OnEnterPressed", Accept)
    edit:SetScript("OnEscapePressed", function() p:Hide() end)

    -- Validation runs a moment AFTER typing stops, never per keystroke: a
    -- validator may be expensive - checking a file by trying to load it - and
    -- doing that on every letter of a path would be a machine gun.
    --
    -- The token is what makes the delay safe - a timer that fires after another
    -- keystroke has already been typed finds a token that has moved on, and
    -- does nothing rather than judging text that is no longer there.
    local function Check()
        -- A hidden field cannot be wrong. Whatever it was holding when it went
        -- away must not keep the accept button down, so any standing verdict is
        -- cleared rather than left to stand over a box nobody can see.
        if not edit:IsShown() then
            p.checkToken = (p.checkToken or 0) + 1
            accept:Enable()
            problem:Hide()
            return
        end
        if not p.Validate then return end
        p.checkToken = (p.checkToken or 0) + 1
        local mine = p.checkToken
        C_Timer.After(PROMPT_CHECK_MS, function()
            if mine ~= p.checkToken or not p:IsShown() then return end
            local ok, reason = p.Validate(strtrim(p.edit:GetText() or ""))
            -- nil abstains. Only an explicit false disables anything.
            if ok == false then
                accept:Disable()
                problem:SetText(reason or "")
                problem:SetShown(reason ~= nil)
            else
                accept:Enable()
                problem:Hide()
            end
        end)
    end

    edit:SetScript("OnTextChanged", function(self)
        hint:SetShown((self:GetText() or "") == "")
        Check()
    end)

    -- Menus are children of UIParent, not of this frame, so one left open would
    -- outlive the prompt and hang in mid-air.
    p:SetScript("OnHide", function() CloseDropDownMenus() end)

    -- The toggle governs the controls under it, so an unticked one greys them.
    -- Turning a thing off and still being invited to configure it is an
    -- invitation to a setting that does nothing - the switch says so, and the
    -- controls agree.
    --
    -- A prompt with no toggle has nothing governing it and stays live.
    function p:GateOnToggle()
        local on = (not self.toggle:IsShown()) or self.toggle:GetChecked()
        UI.SetEnabled(on and true or false,
            self.edit, self.editLabel, self.slider, self.sliderLabel,
            self.choiceLabel, self.note)
        -- The dropdown has no Enable/Disable of its own to find, so it takes
        -- FrameXML's pair - which greys its text and stops the button opening
        -- the menu, where a bare SetAlpha would have left it clickable.
        if self.dropdown:IsShown() and UIDropDownMenu_DisableDropDown then
            if on then
                UIDropDownMenu_EnableDropDown(self.dropdown)
            else
                UIDropDownMenu_DisableDropDown(self.dropdown)
            end
        end
        -- An EditBox keeps the caret and the keyboard when it is disabled, so
        -- letting go has to be spelled out - otherwise a greyed box still eats
        -- what you type.
        if not on then self.edit:ClearFocus() end
    end

    -- Where every row goes and how tall the frame ends up. Run by Ask, and
    -- again every time a choice is picked: the field can come and go with the
    -- choice now, so this is a layout that has to be REDONE rather than done
    -- once at the top of Ask.
    --
    -- POSITION AND VISIBILITY ONLY. What a control is set to - the slider's
    -- value, the toggle's tick, the text in the box - belongs to Ask, and any
    -- of it in here would snap back under somebody in the middle of using it
    -- the moment they touched the dropdown.
    function p:LayoutPrompt()
        local opts = self.opts or {}
        local width = opts.width or PROMPT_W

        -- Laid out top down with a RUNNING OFFSET rather than by chaining each
        -- row to the one above it.
        --
        -- Chaining is fine while everything is left aligned. These rows are
        -- centred, and a centred row chained to the row above centres on THAT
        -- row - so a caption under the toggle would centre on a checkbox
        -- sitting at the left edge rather than on the frame. Anchoring every
        -- row to the frame keeps the two things independent: `y` decides how
        -- far down, the frame decides where across.
        --
        -- The height is accumulated alongside it. PROMPT_BASE_H is the title
        -- bar, ONE field row and the buttons, so every optional row adds its
        -- own - and a prompt whose field is hidden hands that row back.
        local y = -(UI.INSET + UI.TITLEBAR_H + 10)
        local height = PROMPT_BASE_H

        -- The toggle goes above everything: it decides whether any of it
        -- matters at all, and a switch found under the setting it governs is a
        -- switch found second.
        --
        -- CENTRED, like the captions under it, which takes arithmetic a
        -- checkbox cannot do for itself: the label is a separate region hanging
        -- off the box's right edge, so the pair is only centred when the box
        -- itself sits half the label's width left of centre. GetStringWidth
        -- needs the text set first, and Ask has set it by the time we run.
        if opts.toggle then
            local labelWidth = self.toggle.label
                and self.toggle.label:GetStringWidth() or 0
            self.toggle:ClearAllPoints()
            self.toggle:SetPoint("TOP", self, "TOP", -(labelWidth + 4) / 2, y)
            self.toggle:Show()
            y = y - PROMPT_TOGGLE_STEP
            height = height + PROMPT_TOGGLE_H
        else
            self.toggle:Hide()
        end

        -- The dropdown sits ABOVE the field. The list is the question and the
        -- box under it is the escape hatch for an answer that is not on the
        -- list, and a hatch found before the door it is an alternative to is
        -- one nobody reads the list to avoid needing.
        --
        -- Left aligned, so it takes the field's x less the transparent lead on
        -- its housing; there is nothing here to centre.
        if opts.choices then
            if opts.choiceLabel then
                self.choiceLabel:SetText(opts.choiceLabel)
                self.choiceLabel:ClearAllPoints()
                -- The field's x, not the frame's padding: this caption names
                -- the dropdown under it, and the dropdown's visible left edge
                -- is where the field starts.
                self.choiceLabel:SetPoint("TOPLEFT", self, "TOPLEFT", PROMPT_PAD + 6, y)
                self.choiceLabel:SetPoint("TOPRIGHT", self, "TOPRIGHT", -PROMPT_PAD, y)
                self.choiceLabel:Show()
                y = y - PROMPT_CAP_H
                height = height + PROMPT_FIELD_H
            else
                self.choiceLabel:Hide()
            end
            self.dropdown:ClearAllPoints()
            self.dropdown:SetPoint("TOPLEFT", self, "TOPLEFT",
                PROMPT_PAD + 6 - PROMPT_DD_LEAD, y)
            -- Sized to the FIELD's visible width, not to a fraction of the
            -- frame: the two controls sit one above the other and anything but
            -- the same width reads as a mistake. See PROMPT_DD_TRAIL for where
            -- the arithmetic comes from.
            UI.SetDropdownWidth(self.dropdown,
                (width - 2 * PROMPT_PAD - 6)
                    + PROMPT_DD_LEAD + PROMPT_DD_TRAIL - PROMPT_DD_CAPS)
            self.dropdown:Show()
            -- Asked for its own label rather than told one: the list may have
            -- come from a function, and only the dropdown knows where in it the
            -- current value ended up.
            self.dropdown:Sync()
            y = y - PROMPT_ROW_H
            height = height + PROMPT_ROW_H
        else
            self.dropdown:Hide()
            self.choiceLabel:Hide()
        end

        -- Under the dropdown, and only ever there: it explains the choice, so
        -- a prompt with no choice to make has nothing for it to say.
        --
        -- MEASURED, not declared, and that is what decides how it is anchored.
        -- A font string pinned by both sides takes its width from a layout pass
        -- that has not run yet, so GetStringHeight on a fresh one reports the
        -- height of ONE unwrapped line and the frame comes up short. One anchor
        -- and an explicit SetWidth wraps it there and then, so the number below
        -- is the real one.
        local note = opts.choices and opts.note or nil
        if type(note) == "function" then note = note(self.choice) end
        if note and note ~= "" then
            self.note:ClearAllPoints()
            self.note:SetPoint("TOPLEFT", self, "TOPLEFT", PROMPT_PAD + 6, y)
            self.note:SetWidth(width - 2 * PROMPT_PAD - 6)
            self.note:SetText(note)
            self.note:Show()
            local grown = ceil(self.note:GetStringHeight()) + PROMPT_NOTE_GAP
            y = y - grown
            height = height + grown
        else
            self.note:Hide()
        end

        -- A labelled field is a CAPTION OVER A BOX, both centred; an unlabelled
        -- one is the box on its own. Stacked rather than inline because these
        -- pop-ups are narrow and a value can be long - side by side, the
        -- caption ate a third of the width the value needed.
        --
        -- Absent altogether when the current choice does not want one. A prompt
        -- with no Field wants one always.
        local showField = true
        if opts.Field then showField = opts.Field(self.choice) and true or false end

        if showField then
            self.edit:ClearAllPoints()
            if opts.label then
                self.editLabel:SetText(opts.label)
                self.editLabel:ClearAllPoints()
                -- Both corners at the SAME y: two points that fix the width and
                -- one height between them, which is what a centred line of text
                -- needs. A third point for the vertical would fight these two.
                self.editLabel:SetPoint("TOPLEFT", self, "TOPLEFT", PROMPT_PAD, y)
                self.editLabel:SetPoint("TOPRIGHT", self, "TOPRIGHT", -PROMPT_PAD, y)
                self.editLabel:Show()
                y = y - PROMPT_CAP_H
                height = height + PROMPT_FIELD_H
            else
                self.editLabel:Hide()
            end
            self.edit:SetPoint("TOPLEFT", self, "TOPLEFT", PROMPT_PAD + 6, y)
            self.edit:SetPoint("TOPRIGHT", self, "TOPRIGHT", -PROMPT_PAD, y)
            self.edit:Show()
            y = y - PROMPT_EDIT_H
        else
            self.editLabel:Hide()
            self.edit:Hide()
            -- An EditBox hidden with the keyboard still on it goes on eating
            -- what you type, and Enter would accept off a box nobody can see.
            self.edit:ClearFocus()
            height = height - PROMPT_EDIT_H
        end

        -- Placed off `y` like the rows above it; see the note at the top.
        if opts.slider then
            -- Caption over the handle, both centred, same as the field above.
            -- The caption carries the value, so inline it changed width as you
            -- dragged and walked the handle sideways with it; stacked, there is
            -- nothing for the digits to push.
            --
            -- The handle takes ONE point: a Slider has a width of its own, so
            -- TOP against the frame centres it across and places it down in the
            -- same anchor.
            self.sliderLabel:ClearAllPoints()
            self.sliderLabel:SetPoint("TOPLEFT", self, "TOPLEFT", PROMPT_PAD, y - 10)
            self.sliderLabel:SetPoint("TOPRIGHT", self, "TOPRIGHT", -PROMPT_PAD, y - 10)
            self.slider:ClearAllPoints()
            self.slider:SetPoint("TOP", self, "TOP", 0, y - 10 - PROMPT_CAP_H)
            self.sliderLabel:Show()
            self.slider:Show()
            height = height + PROMPT_SLIDER_H
        else
            self.sliderLabel:Hide()
            self.slider:Hide()
        end

        self:SetHeight(height)
        -- The field may have just gone away, and a verdict left standing over a
        -- box nobody can see would hold the accept button down for good.
        Check()
        -- Whatever is on screen now has to obey the switch above it, including
        -- rows that were hidden when the switch was last consulted.
        self:GateOnToggle()
    end

    function p:Ask(opts)
        self.opts = opts
        self:SetWidth(opts.width or PROMPT_W)
        -- Straight onto the title bar's font string rather than through
        -- SetTitle: that one stamps the addon version after the text, which
        -- belongs on a window that IS the addon, not on a pop-up naming the one
        -- thing it is editing.
        self.titleText:SetText(opts.title or "")
        self.hint:SetText(opts.hint or "")
        -- 0 is the EditBox's own word for "no cap", so a prompt that says
        -- nothing gets what it had before this existed.
        self.edit:SetMaxLetters(opts.maxLetters or 0)
        self.OnAccept = opts.OnAccept
        self.Validate = opts.Validate
        self.allowEmpty = opts.allowEmpty
        self.accept:SetText(opts.accept or "Add")
        self.accept:Enable()
        self.problem:Hide()

        if opts.reset then
            self.reset:Show()
            self.reset:SetScript("OnClick", function()
                self:Hide()
                opts.reset()
            end)
        else
            self.reset:Hide()
        end

        -- Which entry the dropdown opens on. A caller that groups a long list
        -- has a first entry that is a group rather than a choice, so the
        -- fallback digs for the first actual value.
        self.choice = opts.choice
        if self.choice == nil and opts.choices then
            local list = type(opts.choices) == "function"
                and opts.choices() or opts.choices
            self.choice = FirstChoice(list)
        end

        -- The toggle's label is set here rather than in the layout because the
        -- layout MEASURES it: the pair is centred off its width, and a width
        -- read before the text was set is the last prompt's.
        if opts.toggle and self.toggle.label then
            self.toggle.label:SetText(opts.toggle.label or "")
        end

        if opts.slider then
            self.slider:SetMinMaxValues(opts.slider.min or 0, opts.slider.max or 100)
            self.slider:SetValueStep(opts.slider.step or 5)
            self.slider.OnChange = opts.slider.OnChange
            -- Wrapped so a prompt's handlers all take just the value, the way
            -- OnChange above does; the kit hands its own sliders (self, value).
            self.slider.OnRelease = opts.slider.OnRelease and function(_, value)
                opts.slider.OnRelease(value)
            end or nil
            self.slider:SetScript("OnValueChanged", function(s, value)
                if s.settingValue then return end
                if opts.slider.label then
                    self.sliderLabel:SetText(format(opts.slider.label, value))
                end
                if s.OnChange then s.OnChange(value) end
            end)
            UI.SetSliderValue(self.slider, opts.slider.value or 100)
            if opts.slider.label then
                self.sliderLabel:SetText(format(opts.slider.label,
                    opts.slider.value or 100))
            end
        end

        -- Placed and shown by the layout. Only its state and its handler are
        -- set here.
        if opts.toggle then
            -- Applied as it is clicked rather than on Accept: it is a switch,
            -- not part of the answer being typed, and closing on a box you have
            -- already watched take effect would be a strange thing to want -
            -- the same reasoning the live slider above it uses.
            self.toggle:SetChecked(opts.toggle.checked and true or false)
            self.toggle:SetScript("OnClick", function(box)
                local on = box:GetChecked() and true or false
                if opts.toggle.OnClick then opts.toggle.OnClick(on) end
                p:GateOnToggle()
            end)
        end

        -- Before the layout: it measures the toggle's label, reads the choice
        -- to decide whether the field is on screen at all, and finishes by
        -- gating everything on the switch.
        self.edit:SetText(opts.text or "")
        self:LayoutPrompt()
        self:Show()
        -- Only a field that is on screen AND live takes the keyboard. One the
        -- current choice has hidden must not, or the first thing typed into a
        -- pop-up that is asking a dropdown would go into a box nobody can see.
        if self.edit:IsShown() and self.edit:IsEnabled() then
            self.edit:SetFocus()
        end
        -- Taking focus selects whatever is in the box, and a name handed to the
        -- prompt is a starting point rather than something to type over - a
        -- selected one is gone on the first keystroke. Cleared explicitly
        -- rather than by not focusing: the box should still be ready to type in.
        self.edit:HighlightText(0, 0)
        -- After SetText, or the caret sits in front of the name they were
        -- handed and typing prepends to it.
        self.edit:SetCursorPosition(strlen(opts.text or ""))
    end

    return p
end

--------------------------------------------------------------------------------
-- Colour picker
--
-- The client has one ColorPickerFrame for everybody, and its API changed shape
-- between clients. This wraps both, and keeps track of the one edit the kit
-- has open so a second can cleanly back out the first.
--------------------------------------------------------------------------------

local pickerSession
local pickerHooked

-- A picker dismissed with OK, or closed by anything other than its own Cancel
-- button, leaves its cancel handler behind. The next picker to open starts by
-- cancelling whatever is still pending, which would undo the edit that was just
-- accepted - so the session ends the moment the frame goes away.
local function HookPicker()
    if pickerHooked then return end
    pickerHooked = true
    ColorPickerFrame:HookScript("OnHide", function()
        local session = pickerSession
        pickerSession = nil
        if session and session.OnClose then session.OnClose() end
    end)
end

-- Back out the colour edit the kit has open, if there is one: its OnCancel
-- restores the old value, then the picker closes. Returns whether there was
-- anything to cancel. Call it when whatever the picker is editing goes away.
function UI.CancelColorPicker()
    local session = pickerSession
    if not session then return false end
    session.cancel()
    if ColorPickerFrame:IsShown() then
        ColorPickerFrame:Hide()   -- the OnHide hook ends the session
    else
        pickerSession = nil
        if session.OnClose then session.OnClose() end
    end
    return true
end

-- Open the picker over a colour.
--
-- opts:
--   color     { r, g, b } to start from
--   above     frame the picker must sit over; it is lifted clear of it
--   OnChange  function(r, g, b), on every drag - keep what it repaints cheap
--   OnCancel  function() when the edit is backed out; restore the old value
--   OnClose   function() whenever the picker goes away, accepted or not
--
-- Any edit already open is cancelled first. A caller that reads the value it
-- will restore should cancel before reading it, or it reads the value the
-- previous edit is about to put back.
function UI.OpenColorPicker(opts)
    UI.CancelColorPicker()
    HookPicker()

    local session = { OnClose = opts.OnClose }
    session.cancel = function()
        if session.cancelled then return end
        session.cancelled = true
        if opts.OnCancel then opts.OnCancel() end
    end
    local function Changed()
        if opts.OnChange then opts.OnChange(ColorPickerFrame:GetColorRGB()) end
    end

    local c = opts.color or { r = 1, g = 1, b = 1 }
    ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    if opts.above then
        ColorPickerFrame:SetFrameLevel(opts.above:GetFrameLevel() + 30)
    end
    ColorPickerFrame:SetClampedToScreen(true)
    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow({
            r = c.r, g = c.g, b = c.b,
            hasOpacity = false,
            swatchFunc = Changed,
            cancelFunc = session.cancel,
        })
    else
        ColorPickerFrame.func = Changed
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.opacityFunc = nil
        ColorPickerFrame.cancelFunc = session.cancel
        ColorPickerFrame:SetColorRGB(c.r, c.g, c.b)
        ColorPickerFrame:Show()
    end
    -- After showing: a picker that was already up and gets re-shown can fire
    -- its OnHide first, which would end this session before it began.
    pickerSession = session
end

local function ColorToHex(color)
    local function Byte(value)
        return math.floor(math.max(0, math.min(1, value)) * 255 + 0.5)
    end
    return string.format("#%02X%02X%02X", Byte(color.r), Byte(color.g), Byte(color.b))
end

local function HexToColor(text)
    local hex = text and text:match("^#?(%x%x%x%x%x%x)$")
    if not hex then return nil end
    return {
        r = tonumber(hex:sub(1, 2), 16) / 255,
        g = tonumber(hex:sub(3, 4), 16) / 255,
        b = tonumber(hex:sub(5, 6), 16) / 255,
    }
end

UI.COLOR_FIELD_H = 18

-- A colour setting's whole control: a swatch that reads as a button and opens
-- the picker, and a hex box after it to type one in. Left-click the swatch to
-- pick, right-click to reset; the hex box takes six digits, with or without #,
-- on Enter, and Escape puts back what was there.
--
-- opts:
--   Get       function() -> the saved { r, g, b }, or nil while on the default
--   Set       function(color) to write one; nil hands it back to the default
--   Default   function() -> the colour shown while Get has none (white if absent)
--   OnChange  function() after every write - the picker calls it on each drag,
--             so keep what it repaints cheap
--   OnOpen / OnClose   function() as the picker comes up and goes away
--   title     the tooltip heading for both parts
--   above     the frame the picker must sit over (default: parent)
--
-- Returns a frame to anchor, COLOR_FIELD_H tall and as wide as its two parts,
-- with field:Refresh() to repaint it from Get.
function UI.CreateColorField(parent, opts)
    local field = CreateFrame("Frame", nil, parent)
    field:SetHeight(UI.COLOR_FIELD_H)

    local function Current()
        return opts.Get() or (opts.Default and opts.Default()) or { r = 1, g = 1, b = 1 }
    end

    -- Built to read as a button: a light frame round a dark gap round the
    -- colour, a gold frame and a sheen on hover, and the colour pressing in a
    -- pixel while held.
    local swatch = CreateFrame("Button", nil, field)
    swatch:SetSize(34, UI.COLOR_FIELD_H)
    swatch:SetPoint("LEFT")
    swatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local frame = swatch:CreateTexture(nil, "BACKGROUND")
    frame:SetAllPoints()
    frame:SetColorTexture(0.55, 0.55, 0.55, 1)
    local gap = swatch:CreateTexture(nil, "BORDER")
    gap:SetPoint("TOPLEFT", 1, -1)
    gap:SetPoint("BOTTOMRIGHT", -1, 1)
    gap:SetColorTexture(0, 0, 0, 1)
    local color = swatch:CreateTexture(nil, "ARTWORK")
    local function PlaceColor(pressed)
        local shift = pressed and 1 or 0
        color:ClearAllPoints()
        color:SetPoint("TOPLEFT", 2 + shift, -2 - shift)
        color:SetPoint("BOTTOMRIGHT", -2 + shift, 2 - shift)
    end
    PlaceColor(false)
    local sheen = swatch:CreateTexture(nil, "HIGHLIGHT")
    sheen:SetAllPoints(color)
    sheen:SetColorTexture(1, 1, 1, 0.18)
    swatch:SetScript("OnEnter", function() frame:SetColorTexture(1, 0.82, 0, 1) end)
    swatch:SetScript("OnLeave", function()
        frame:SetColorTexture(0.55, 0.55, 0.55, 1)
        PlaceColor(false)
    end)
    swatch:SetScript("OnMouseDown", function() PlaceColor(true) end)
    swatch:SetScript("OnMouseUp", function() PlaceColor(false) end)
    field.swatch = swatch

    -- InputBoxTemplate's art hangs a few pixels left of the frame, so the gap
    -- before it is wider than it looks.
    local hex = CreateFrame("EditBox", nil, field, "InputBoxTemplate")
    hex:SetSize(64, UI.COLOR_FIELD_H)
    hex:SetPoint("LEFT", swatch, "RIGHT", 16, 0)
    hex:SetAutoFocus(false)
    hex:SetMaxLetters(7)
    field.hex = hex
    field:SetWidth(34 + 16 + 64)

    function field:Refresh()
        local c = Current()
        color:SetColorTexture(c.r, c.g, c.b, 1)
        if not hex:HasFocus() then hex:SetText(ColorToHex(c)) end
    end

    local function Write(value)
        opts.Set(value)
        field:Refresh()
        if opts.OnChange then opts.OnChange() end
    end

    swatch:SetScript("OnClick", function(_, button)
        if hex:HasFocus() then hex:ClearFocus() end
        if button == "RightButton" then
            UI.CancelColorPicker()
            Write(nil)
            return
        end
        -- Cancel first: an edit still open would restore its own colour after
        -- this one read what to put back.
        UI.CancelColorPicker()
        local saved = opts.Get()
        local original = saved and { r = saved.r, g = saved.g, b = saved.b } or nil
        UI.OpenColorPicker({
            color = Current(), above = opts.above or parent,
            OnChange = function(r, g, b) Write({ r = r, g = g, b = b }) end,
            OnCancel = function() Write(original) end,
            OnClose = opts.OnClose,
        })
        if opts.OnOpen then opts.OnOpen() end
    end)

    hex:SetScript("OnEditFocusGained", function(self)
        UI.CancelColorPicker()
        self:SetText(ColorToHex(Current()))
        self:HighlightText()
    end)
    hex:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    hex:SetScript("OnEscapePressed", function(self)
        self.reverting = true
        self:ClearFocus()
    end)
    hex:SetScript("OnEditFocusLost", function(self)
        local typed = not self.reverting and HexToColor(self:GetText())
        self.reverting = nil
        if typed then Write(typed) else field:Refresh() end
    end)

    UI.AddTooltip(swatch, opts.title,
        "Left-click for the WoW color picker; right-click to reset.")
    UI.AddTooltip(hex, opts.title or "Hex color",
        "Enter a six-digit RGB color, with or without #, then press Enter.")
    field:Refresh()
    return field
end

--------------------------------------------------------------------------------
-- Blizzard widgets
--------------------------------------------------------------------------------

-- Apply the compact treatment to Blizzard's legacy dropdown chrome. Its three
-- housing textures are 64px tall (with transparent padding) around a 24px
-- arrow. Trim and position that housing without scaling any click target or
-- menu content, then place its label and arrow independently.
--
-- `leftAlign` left-justifies the collapsed label: the template right-aligns it,
-- which leaves names and icons floating against the arrow with dead space on
-- the left.
UI.DROPDOWN_LABEL_GROW = 5   -- extra label width toward the left edge

function UI.StyleDropdown(dd, leftAlign)
    local name = dd:GetName()
    if not name then return end

    if not dd.uiHousingStyled then
        for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
            local texture = _G[name .. suffix]
            if texture then texture:SetHeight(57) end
        end
        local left   = _G[name .. "Left"]
        local button = _G[name .. "Button"]
        local label  = _G[name .. "Text"]
        -- Middle and Right are chained from Left, so moving Left shifts the
        -- entire housing. Its dependent arrow/text anchors follow it; leave the
        -- arrow 0.5px and text 2.8px lower, then nudge the arrow right.
        if left   then left:AdjustPointsOffset(0, -3) end
        if button then button:AdjustPointsOffset(2, 2.5) end
        if label  then label:AdjustPointsOffset(0, 0.2) end
        dd.uiHousingStyled = true
    end

    -- The whole box opens the menu, not just the arrow: the box is what reads
    -- as the control. The hit rect is trimmed to the visible housing (the
    -- template overhangs it by ~16px each side) so it can't steal clicks from
    -- a neighbour. A disabled dropdown's arrow is disabled, so this follows it.
    -- The arrow still takes its own clicks, sitting above the frame.
    if not dd.uiBoxClickable then
        dd:EnableMouse(true)
        dd:SetHitRectInsets(16, 16, 4, 4)
        dd:SetScript("OnMouseDown", function(self, mouseButton)
            if mouseButton ~= "LeftButton" then return end
            local arrow = _G[name .. "Button"]
            if arrow and not arrow:IsEnabled() then return end
            ToggleDropDownMenu(nil, nil, self)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        -- Blizzard closes open menus on any mouse-down outside them unless the
        -- clicked frame claims it, which would shut the menu this click is
        -- about to toggle and then reopen it.
        dd.HandlesGlobalMouseEvent = function(_, mouseButton, event)
            return event == "GLOBAL_MOUSE_DOWN" and mouseButton == "LeftButton"
        end
        dd.uiBoxClickable = true
    end

    if leftAlign and not dd.uiTextAligned then
        local label = _G[name .. "Text"]
        if label then
            label:SetJustifyH("LEFT")
            label:SetWidth(label:GetWidth() + UI.DROPDOWN_LABEL_GROW)
            label:AdjustPointsOffset(0, -1)
        end
        dd.uiTextAligned = true
    end
end
