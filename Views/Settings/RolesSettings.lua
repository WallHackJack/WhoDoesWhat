local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI
local AceGUI = LibStub("AceGUI-3.0")

-- The Roles settings page: every role WDW knows, by class, plus your own custom
-- ones. It was a window of its own until it became a tab in Settings.
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
-- The settings page's scroll child (owns the options strip) and the AceGUI
-- content group rebuilt inside it. The strip is built once and never pooled,
-- so nothing leaks onto AceGUI's pooled frames.
local rolesPage = nil
local rolesScroll = nil
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

-- Page geometry: one column, centred on the page, holding a short intro, the
-- options strip under it and the two class columns under that.
local COLUMN_W = 520
local INTRO_TOP = 10 -- y (from the page top) where the intro starts
local OPTIONS_H = 24


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


-- (Re)build the AceGUI class-list content on the page. Releasing the previous
-- content group returns all its widgets to the pool cleanly -- and we attach no
-- raw frames to them, so nothing leaks across rebuilds.
local function BuildContent()
    if contentGroup then
        AceGUI:Release(contentGroup)
        contentGroup = nil
    end

    WhoDoesWhat:LogUiBuilding("Building class list content.")
    rolesPage.expandCheck:SetChecked(WhoDoesWhat.db.profile.expandRoles)

    local group = AceGUI:Create("SimpleGroup")
    group:SetLayout("Flow")
    group.frame:SetParent(rolesPage)
    group.frame:ClearAllPoints()
    group.frame:SetPoint("TOP", rolesPage.strip, "BOTTOM", 0, -10)
    group:SetWidth(COLUMN_W)
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

    -- The group is as tall as the taller column, which is what the page's
    -- scroll area measures.
    local contentH = math.max(leftColumn.frame:GetHeight(), rightColumn.frame:GetHeight())
    group.frame:SetHeight(contentH)
    UI.FitScrollToContent(rolesScroll)

    WhoDoesWhat:LogUiBuilding("Class list population complete. Content height: " .. math.floor(contentH))
end


-- Build the intro and options strip onto the Roles settings page, once. The
-- class list is (re)built separately, each time the page comes up.
function WhoDoesWhat:BuildRolesSettingsPage(page, scroll)
    rolesPage, rolesScroll = page, scroll

    -- Styled like the intro at the top of the other settings pages.
    local intro = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOP", 0, -INTRO_TOP)
    intro:SetWidth(COLUMN_W - 8)
    intro:SetJustifyH("LEFT")
    intro:SetTextColor(0.7, 0.7, 0.7)
    intro:SetText("Every role WDW knows, by class, plus your own custom ones."
        .. " Click a role to see its blessing order, or create your own when a"
        .. " raider's job needs its own name or its own blessings.")

    local strip = CreateFrame("Frame", nil, page)
    strip:SetPoint("TOP", intro, "BOTTOM", 0, -12)
    strip:SetSize(COLUMN_W, OPTIONS_H)
    page.strip = strip

    -- "Expand Roles" checkbox (a plain CheckButton; persistent, so toggling it
    -- never releases the widget mid-callback).
    local check = UI.CreateCheckbox(strip, "Expand Roles", nil, nil, function(self)
        local value = self:GetChecked() and true or false
        WhoDoesWhat.db.profile.expandRoles = value
        WhoDoesWhat:LogUiBuilding("Expand Roles toggled to " .. tostring(value) .. "; rebuilding roles.")
        BuildContent()
    end, { size = 22, font = "GameFontHighlight", gap = 2 })
    check:SetPoint("LEFT", 4, 0)
    page.expandCheck = check

    -- Create Role, right-aligned in the same strip. Its tooltip is written for
    -- somebody who has not met the concept yet: this page is where a new user
    -- most plausibly goes looking, and "role" is doing a lot of work in WDW.
    local createBtn = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    createBtn:SetSize(110, 22)
    createBtn:SetPoint("RIGHT", -4, 0)
    createBtn:SetText("Create Role")
    createBtn:SetScript("OnClick", function()
        WhoDoesWhat:OpenCustomizerForNewRole()
    end)
    UI.AddTooltip(createBtn, function(self)
        GameTooltip:SetText("Create a custom role", unpack(UI.TOOLTIP_TITLE))
        GameTooltip:AddLine("A role is the job a raider is doing -- Frost Mage,"
            .. " Protection Warrior, Holy Priest. WhoDoesWhat uses it to work"
            .. " out which paladin blessings they should get and whether they"
            .. " count as a tank, healer or damage dealer.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Every class already has its specs listed here."
            .. " Make your own when a raider's job needs its own name or its own"
            .. " blessings -- an off-tank, a decurser, a kite duty.",
            0.8, 0.8, 0.8, true)
        return true
    end)
end


-- Build the class list now; the Settings page calls this as the tab comes up.
function WhoDoesWhat:RefreshRolesSettingsPage()
    if rolesPage then BuildContent() end
end


-- Rebuild the class list if the page is on screen (the customizer calls this
-- after a save); otherwise the next visit builds it.
function WhoDoesWhat:RebuildAllRolesView()
    if rolesPage and rolesPage:IsVisible() then BuildContent() end
end


-- The page's Reset Defaults: your custom role library goes, and the list
-- collapses back to categories. Roles published to the raid are the board's,
-- not the library's, so they stay.
function WhoDoesWhat:ResetRolesSettingsPage()
    self.db.profile.expandRoles = false
    wipe(self.db.profile.customRoles)
    self:PopulateRolesAndCategories()
    self:RefreshMainAssignmentsView()
    self:RefreshBoardViews()
    self:RefreshRolesSettingsPage()
end

WhoDoesWhat.SettingsKit.RegisterPage({
    label = "Roles", title = "Roles",
    tooltip = "Every role WDW knows, by class, plus your own custom"
        .. " ones. Click a role to see its blessing order.",
    description = "Deletes your custom role library. Custom roles already"
        .. " published to the raid, and who holds which role, are kept.",
    Build = function(_, page, scroll) WhoDoesWhat:BuildRolesSettingsPage(page, scroll) end,
    Reset = function() WhoDoesWhat:ResetRolesSettingsPage() end,
    OnShow = function() WhoDoesWhat:RefreshRolesSettingsPage() end,
})
