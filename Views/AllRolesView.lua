local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local AceGUI = LibStub("AceGUI-3.0")

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

-- Small gear appended to a role row that has saved customizations (categories
-- count as customized when any of their sub-roles is)
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


local function CustomizedRoleCount()
    local count = 0
    for _ in pairs(WhoDoesWhat.db.profile.roleCustomizations) do
        count = count + 1
    end
    return count
end


local function ResetAllRoleCustomizations()
    local count = CustomizedRoleCount()
    if count == 0 then return end
    wipe(WhoDoesWhat.db.profile.roleCustomizations)
    WhoDoesWhat:RefreshMainAssignmentsView()
    WhoDoesWhat:RefreshBuffingGridView()
    WhoDoesWhat:RebuildAllRolesView()
    WhoDoesWhat:LogOperation("Reset " .. count .. " role customizations to defaults.")
end


StaticPopupDialogs["WHODOESWHAT_RESET_ALL_ROLES"] = {
    text = "Reset all %d customized roles to their defaults?",
    button1 = "Reset All",
    button2 = "Cancel",
    OnAccept = ResetAllRoleCustomizations,
    timeout = 0,
    hideOnEscape = true,
    preferredIndex = 3,
}


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
-- never collapse into categories).
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
    if not classInfo.customRoles then
        return base
    end
    local merged = {}
    for _, role in ipairs(base) do
        merged[#merged + 1] = role
    end
    for _, role in ipairs(classInfo.customRoles) do
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
        local marker = WhoDoesWhat:IsRoleCustomized(role.id) and CUSTOMIZED_MARKER or ""
        local roleRow = AceGUI:Create("InteractiveLabel")
        roleRow:SetText(
            ROLE_INDENT .. "|T" .. role.icon .. ":16:16:0:2|t  |cff" .. classInfo.colorHex .. role.name .. "|r" .. marker
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

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatFrame", FRAME_W, FRAME_H, "WDW - Customize Role Defaults")

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

    local resetAll = CreateFrame("Button", nil, optionsBox, "UIPanelButtonTemplate")
    resetAll:SetSize(110, 22)
    resetAll:SetPoint("RIGHT", optionsBox, "RIGHT", -8, 0)
    resetAll:SetScript("OnClick", function()
        local count = CustomizedRoleCount()
        if count == 0 then return end
        StaticPopup_Hide("WHODOESWHAT_RESET_ALL_ROLES")
        StaticPopup_Show("WHODOESWHAT_RESET_ALL_ROLES", count)
    end)
    f.resetAllButton = resetAll

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
    local customizedCount = CustomizedRoleCount()
    f.resetAllButton:SetText("Reset all (" .. customizedCount .. ")")
    f.resetAllButton:SetEnabled(customizedCount > 0)

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

    -- Full-width row under the columns: create a new custom role (it lands
    -- inside whichever class the user assigns it to).
    local addRow = AceGUI:Create("InteractiveLabel")
    addRow:SetText("|cff40ff40+ Create Custom Role|r")
    addRow:SetFontObject(GameFontHighlight)
    addRow:SetFullWidth(true)
    addRow:SetJustifyH("CENTER")
    addRow:SetHighlight(ROW_HIGHLIGHT)
    addRow:SetCallback("OnClick", function()
        WhoDoesWhat:OpenCustomizerForNewRole()
    end)
    group:AddChild(addRow)

    -- Fit the window to the taller column plus the create row, keeping the
    -- top-left corner fixed so the options checkbox stays under the cursor
    -- when toggling expand/collapse.
    local contentH = math.max(leftColumn.frame:GetHeight(), rightColumn.frame:GetHeight())
        + addRow.frame:GetHeight() + 4
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
