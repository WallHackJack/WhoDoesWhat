local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- WDW's palette: navy surfaces, steel-blue edges, and gold for whatever is
-- picked. The UI kit keeps neutral greys of its own, so every colour here
-- reaches it by argument; nothing in the kit is rewritten to match.

local GOLD = { 1, 0.82, 0 }
local EDGE = { 0.40, 0.48, 0.66 }

local T = {
    gold = GOLD,
    edge = EDGE,

    -- UI.CreateWindow opts, for any window that wants nothing else.
    window = { titleBarColor = { 0.10, 0.12, 0.19 }, borderColor = EDGE },
    -- The main window's edge: a muted gold, since the border art is light and
    -- takes full gold as something close to yellow.
    mainBorder = { 0.70, 0.55, 0.17 },

    -- The loose on-screen frames, dressed like the main window: its gold edge
    -- and title bar, over a navy fill. The Paladin Bar's is the window's own
    -- near-black navy; the Status Bars' a step lighter, as its grey was.
    paladinBarFill = { 0.015, 0.025, 0.06, 0.95 },
    statusBarsFill = { 0.04, 0.06, 0.12, 0.97 },

    -- UI.AddTabs `colors`. The panel and its border are left to the kit's own
    -- blue and grey; the blue is what About sits on. The selected tab is a dark
    -- bronze, which the gold label and underline stand out on.
    tabs = {
        selected      = { 0.26, 0.20, 0.08 },
        hover         = { 0.11, 0.18, 0.36 },
        unselected    = { 0.07, 0.11, 0.22 },
        label         = { 0.85, 0.87, 0.93 },
        labelHover    = { 1, 1, 1 },
        labelSelected = GOLD,
        labelDisabled = { 0.42, 0.45, 0.55 },
        underline     = GOLD,
    },

    -- A second tab row inside a page (Settings' sections): muted slate rather
    -- than the window's blue, so the two rows read as different levels. Same
    -- gold for the pick.
    subTabs = {
        selected      = { 0.24, 0.27, 0.34 },
        hover         = { 0.17, 0.19, 0.25 },
        unselected    = { 0.10, 0.115, 0.15 },
        label         = { 0.85, 0.86, 0.89 },
        labelHover    = { 1, 1, 1 },
        labelSelected = GOLD,
        labelDisabled = { 0.42, 0.44, 0.50 },
        underline     = GOLD,
        panelBorder   = { 0.28, 0.31, 0.38 },
    },

    -- Behind the roster-style pages: as near black as before, which the class
    -- tints were picked against, with just enough navy to belong to the window.
    pageDark = { 0.014, 0.018, 0.03, 1 },

    -- Settings' sections and the board pages (Blessings, Assignments): content sits
    -- in a dark navy well, just light enough for its edge shadows to show, on
    -- a slate panel a step lighter, so the well reads as sunk into it. The
    -- deep navy is a title bar over a well, darker and bluer than both.
    pageWell = { 0.045, 0.06, 0.10, 1 },
    panelSlate = { 0.075, 0.095, 0.16, 1 },
    wellHeaderBlue = { 0.025, 0.035, 0.085, 1 },
    -- Row stripes over a well: odd, even.
    wellRows = { { 0.14, 0.17, 0.26 }, { 0.085, 0.10, 0.17 } },

    -- The Blessings page: Paladin pink carries the page. Red leads
    -- blue in every surface - the other way round reads purple - so the panel
    -- is a dusty rose, the wells a near-black with a rose cast rather than
    -- navy (navy under pink also mixes to purple), and the row stripes a muted
    -- rose, and a dimmed pink edges the panel. Its section headings keep the
    -- Settings pages' dark gold (the page title the standard gold), which
    -- stands out on the rose where pink headings blended in.
    blessings = {
        panel = { 0.17, 0.09, 0.125, 1 },
        border = { 0.62, 0.36, 0.48 },
        well = { 0.07, 0.045, 0.058, 1 },
        rows = { { 0.28, 0.15, 0.20 }, { 0.185, 0.10, 0.135 } },
        accent = { 0.8, 0.65, 0.12 },
    },

    -- Hairline rules under headings.
    divider = { 0.40, 0.48, 0.64, 0.6 },
    -- The dark gold of the Settings pages' section dividers, for the roster
    -- pages (Members, Buff Grid).
    goldDivider = { 0.8, 0.65, 0.12, 0.3 },

    -- UI.StylePanel style for something floating over a window.
    popup = { fill = { 0.07, 0.10, 0.18, 0.95 }, border = EDGE },
}

-- A copy of a tab palette (default `T.tabs`) with some of its colours swapped,
-- for a tab row that sits on a panel of its own colour.
function T.TabsWith(overrides, base)
    local colors = {}
    for key, color in pairs(base or T.tabs) do colors[key] = color end
    for key, color in pairs(overrides) do colors[key] = color end
    return colors
end

WhoDoesWhat.Theme = T
