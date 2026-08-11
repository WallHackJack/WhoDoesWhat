local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local AceGUI = LibStub("AceGUI-3.0")

-- The Roles window: every role WDW knows, by class, plus your own custom ones.
--
-- It used to be where blessing orders were edited. It isn't any more -- an order
-- deviates from the defaults only on the shared board (the main window's Custom
-- Roles section), so built-in roles here are a read-only reference: click one to
-- see its default order, and use Create a Copy to start a custom role from it.
-- Custom roles are still created (Create Role, in the options strip), renamed,
-- re-iconed and deleted here.
--
-- A gear beside a role means it carries a blessing order of its own -- so only
-- custom roles ever wear one. What the raid is overriding tonight belongs to
-- the Custom Roles section, not to a role's entry in your library.
--
-- Persistent custom root frame (owns the chrome) and the AceGUI content group
-- rebuilt inside it. The root frame is created once and never pooled, so the
-- title/close/background/options box never leak the way overlays on AceGUI's
-- pooled Window frames did.
local mainFrame = nil
local contentGroup = nil

-- Soft row highlight shown when hovering a role
local ROW_HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

-- Leading indent so roles sit pushed right, nested under the class divider
local ROLE_INDENT = "      "

-- Small gear appended to a custom role carrying a blessing order of its own.
-- Built-in roles never wear it, not even while the raid is overriding one --
-- this window is your library, and tonight's raid is not a property of a role.
local CUSTOMIZED_MARKER = "  |TInterface\\Buttons\\UI-OptionsButton:12:12:0:0|t"

-- Vertical spacing (in pixels), easy to tune
local PAD_BELOW_HEADER = 4 -- gap under a class divider before its first role
local PAD_BETWEEN_ROLES = 2 -- gap between role rows so icons don't touch
local PAD_END_OF_CLASS = 8 -- gap after a class before the next divider

-- Frame geometry
local FRAME_W = 380
local FRAME_H = 500
local TITLEBAR_H = 22
local MARGIN = 10
local OPTIONS_TOP = TITLEBAR_H + MARGIN -- y (from top) where the options box sits
local OPTIONS_H = 32
local CONTENT_TOP = OPTIONS_TOP + OPTIONS_H + 8 -- y (from top) where the columns start


-- Add a precise-height vertical spacer. A SimpleGroup normally re-sizes itself
-- to its (zero) content during layout, which fights the parent's stacking; the
-- noAutoHeight flag makes its LayoutFinished bail out, so our SetHeight sticks.
local function AddSpacer(parent, px)
    local spacer = AceGUI:Create("SimpleGroup")
    spacer:SetLayout("List")
    spacer:SetFullWidth(true)
    spacer.noAutoHeight = true
    spacer:SetHeight(px)
    parent:AddChild(spacer)
end


-- Split the class list into two columns by class count (first half left, rest
-- right). We deliberately don't balance by spec count -- role counts vary with
-- the expand/collapse setting, so a simple, stable class split reads better.
local function SplitClasses(classes)
    local left, right = {}, {}
    local half = math.ceil(#classes / 2)
    for i, class in ipairs(classes) do
        if i <= half then
            table.insert(left, class)
        else
            table.insert(right, class)
        end
    end
    return left, right
end


-- Choose which role list to render for a class: the full spec list when
-- expanded, or the condensed scheme (if the class defines one) when collapsed.
-- Built-in roles omitted from every category stay visible under their own name.
-- Classes without a categories table show their full roles in both modes.
-- Custom roles assigned to the class are always appended at the end (they
-- never collapse into categories). This window is the local library, so it
-- lists classInfo.libraryRoles -- your own templates -- and not the raid's
-- published copies, which live in the main window's Custom Roles section.
local function GetRolesForClass(classInfo)
    local base = classInfo.roles
    if not WhoDoesWhat.db.profile.expandRoles and classInfo.categories then
        local categorized = {}
        base = {}
        for _, category in ipairs(classInfo.categories) do
            base[#base + 1] = category
            for _, id in ipairs(category.allSubRoles) do categorized[id] = true end
        end
        for _, role in ipairs(classInfo.roles) do
            if not categorized[role.id] then base[#base + 1] = role end
        end
    end
    if not classInfo.libraryRoles then
        return base
    end
    local merged = {}
    for _, role in ipairs(base) do
        merged[#merged + 1] = role
    end
    for _, role in ipairs(classInfo.libraryRoles) do
        merged[#merged + 1] = role
    end
    return merged
end


-- Build one class as a single self-contained block: a divider header, a touch
-- of padding, then one clickable row per role. The block is its own List
-- container, so its height is computed purely from its children.
local function BuildClassBlock(column, classInfo)
    WhoDoesWhat:LogUiBuilding("Building class block for: " .. classInfo.name)

    local roles = GetRolesForClass(classInfo)

    local block = AceGUI:Create("SimpleGroup")
    block:SetFullWidth(true)
    block:SetLayout("List")
    column:AddChild(block)

    -- Class divider (no icon, bolder font):  ----- Warrior -----
    local header = AceGUI:Create("Heading")
    header.label:SetFontObject(GameFontNormalLarge) -- bolder/larger class name
    header:SetText("|cff" .. classInfo.colorHex .. classInfo.name .. "|r")
    header:SetFullWidth(true)
    block:AddChild(header)

    AddSpacer(block, PAD_BELOW_HEADER)

    for i, role in ipairs(roles) do
        WhoDoesWhat:LogUiBuilding("Creating role row for: " .. role.name)

        -- Flat, full-width, left-aligned clickable row: inline icon +
        -- class-colored name, lightly indented, with a hover highlight. A small
        -- gear trails the name when the role has saved customizations.
        local marker = WhoDoesWhat:HasOwnBuffOrder(role.id) and CUSTOMIZED_MARKER or ""
        local roleRow = AceGUI:Create("InteractiveLabel")
        roleRow:SetText(
            ROLE_INDENT .. WhoDoesWhat:RoleIconMarkup(role.icon, 16)
                .. "  |cff" .. classInfo.colorHex .. role.name .. "|r" .. marker
        )
        roleRow:SetFontObject(GameFontHighlight)
        roleRow:SetFullWidth(true)
        roleRow:SetJustifyH("LEFT")
        roleRow:SetHighlight(ROW_HIGHLIGHT)
        roleRow:SetCallback("OnClick", function()
            WhoDoesWhat:OpenCustomizer(role.id)
        end)
        block:AddChild(roleRow)

        if i < #roles then
            AddSpacer(block, PAD_BETWEEN_ROLES)
        end
    end

    AddSpacer(block, PAD_END_OF_CLASS)
end


-- Build our root frame once and reuse it. Chrome (backdrop / title bar / close /
-- drag / Escape) comes from the shared factory; we add the persistent lighter
-- options box + expand checkbox on top. The class list is (re)built separately.
local function EnsureMainFrame()
    if mainFrame then return mainFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatFrame", FRAME_W, FRAME_H, "WDW - Roles")

    -- Persistent lighter options box (child of our frame, never pooled)
    local optionsBox = CreateFrame("Frame", nil, f, "BackdropTemplate")
    optionsBox:SetPoint("TOPLEFT", MARGIN, -OPTIONS_TOP)
    optionsBox:SetPoint("TOPRIGHT", -MARGIN, -OPTIONS_TOP)
    optionsBox:SetHeight(OPTIONS_H)
    optionsBox:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    optionsBox:SetBackdropColor(0.16, 0.16, 0.18, 0.9)
    optionsBox:SetBackdropBorderColor(0.4, 0.4, 0.4)

    -- "Expand Roles" checkbox (a plain CheckButton; persistent, so toggling it
    -- never releases the widget mid-callback).
    local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    check:SetSize(22, 22)
    check:SetPoint("LEFT", optionsBox, "LEFT", 8, 0)

    local checkLabel = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    checkLabel:SetPoint("LEFT", check, "RIGHT", 2, 0)
    checkLabel:SetText("Expand Roles")

    check:SetScript("OnClick", function(self)
        local value = self:GetChecked() and true or false
        WhoDoesWhat.db.profile.expandRoles = value
        WhoDoesWhat:LogUiBuilding("Expand Roles toggled to " .. tostring(value) .. "; rebuilding roles.")
        WhoDoesWhat:RebuildAllRolesView()
    end)
    f.expandCheck = check

    -- Create Role, right-aligned in the same strip. Its tooltip is written for
    -- somebody who has not met the concept yet: this window is where a new user
    -- most plausibly goes looking, and "role" is doing a lot of work in WDW.
    -- Parented to the options box and lifted above it: as a sibling at the same
    -- frame level its art fought with the box's backdrop.
    local createBtn = CreateFrame("Button", nil, optionsBox, "UIPanelButtonTemplate")
    createBtn:SetFrameLevel(optionsBox:GetFrameLevel() + 2)
    createBtn:SetSize(110, 22)
    createBtn:SetPoint("RIGHT", optionsBox, "RIGHT", -8, 0)
    createBtn:SetText("Create Role")
    createBtn:SetScript("OnClick", function()
        WhoDoesWhat:OpenCustomizerForNewRole()
    end)
    createBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Create a custom role", 1, 1, 1)
        GameTooltip:AddLine("A role is the job a raider is doing -- Frost Mage,"
            .. " Protection Warrior, Holy Priest. WhoDoesWhat uses it to work"
            .. " out which paladin blessings they should get and whether they"
            .. " count as a tank, healer or damage dealer.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Every class already has its specs listed here."
            .. " Make your own when a raider's job needs its own name or its own"
            .. " blessings -- an off-tank, a decurser, a kite duty.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    createBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.createButton = createBtn

    -- "Reset all" used to live here, when this window owned per-profile buff
    -- orders. It no longer owns any: overrides are the raid's, and removing one
    -- is a row in the Custom Roles section.
    mainFrame = f
    return f
end


-- Resize a frame's height while keeping its top-left corner fixed on screen, so
-- content that grows or shrinks downward doesn't shift widgets anchored top-left.
local function SetFrameHeightKeepingTopLeft(f, height)
    local left, top = f:GetLeft(), f:GetTop()
    f:ClearAllPoints()
    if left and top then
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    else
        f:SetPoint("CENTER") -- not yet positioned (first build, before Show)
    end
    f:SetHeight(height)
end


-- (Re)build the AceGUI class-list content inside the root frame. Releasing the
-- previous content group returns all its widgets to the pool cleanly -- and we
-- attach no raw frames to them, so nothing leaks across rebuilds.
local function BuildContent()
    local f = EnsureMainFrame()

    if contentGroup then
        AceGUI:Release(contentGroup)
        contentGroup = nil
    end

    WhoDoesWhat:LogUiBuilding("Building class list content.")

    local group = AceGUI:Create("SimpleGroup")
    group:SetLayout("Flow")
    group.frame:SetParent(f)
    group.frame:ClearAllPoints()
    group.frame:SetPoint("TOPLEFT", f, "TOPLEFT", MARGIN, -CONTENT_TOP)
    group:SetWidth(FRAME_W - MARGIN * 2)
    group.frame:Show()
    contentGroup = group

    -- Two side-by-side, top-aligned columns of whole class blocks.
    local leftClasses, rightClasses = SplitClasses(WhoDoesWhat.Classes)
    WhoDoesWhat:LogUiBuilding("Split: " .. #leftClasses .. " classes left, " .. #rightClasses .. " right.")

    local leftColumn = AceGUI:Create("SimpleGroup")
    leftColumn:SetRelativeWidth(0.5)
    leftColumn:SetLayout("List")
    leftColumn.alignoffset = 0 -- force top-alignment (Flow otherwise centers columns)
    group:AddChild(leftColumn)

    local rightColumn = AceGUI:Create("SimpleGroup")
    rightColumn:SetRelativeWidth(0.5)
    rightColumn:SetLayout("List")
    rightColumn.alignoffset = 0
    group:AddChild(rightColumn)

    for _, classInfo in ipairs(leftClasses) do
        BuildClassBlock(leftColumn, classInfo)
    end
    for _, classInfo in ipairs(rightClasses) do
        BuildClassBlock(rightColumn, classInfo)
    end

    -- Fit the window to the taller column, keeping the top-left corner fixed so
    -- the options checkbox stays under the cursor when toggling
    -- expand/collapse. Creating a role is the strip's button now, not a row
    -- down here, so nothing trails the columns.
    local contentH = math.max(leftColumn.frame:GetHeight(), rightColumn.frame:GetHeight())
    SetFrameHeightKeepingTopLeft(f, CONTENT_TOP + contentH + MARGIN)

    WhoDoesWhat:LogUiBuilding("Class list population complete. Content height: " .. math.floor(contentH))
end


-- Rebuild just the class list in place (the frame and its chrome stay put).
function WhoDoesWhat:RebuildAllRolesView()
    if not mainFrame or not mainFrame:IsShown() then return end
    BuildContent()
end


-- Toggle the window open/closed.
function WhoDoesWhat:OpenAllRolesView()
    local f = EnsureMainFrame()

    if f:IsShown() then
        WhoDoesWhat:LogUiBuilding("All Roles View open, closing it.")
        f:Hide()
        return
    end

    WhoDoesWhat:LogUiBuilding("Opening All Roles View...")
    f.expandCheck:SetChecked(WhoDoesWhat.db.profile.expandRoles)
    BuildContent()
    f:Show()
end
