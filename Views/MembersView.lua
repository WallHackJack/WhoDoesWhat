local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI

-- Members page (the main window's Members tab): every group member in one
-- of four role grids, bucketed by their assigned role's tank/healer/dps
-- classification and sorted by class then name.
--
-- Each row states the same fact three times over -- Blizzard's group flag, the
-- WhoDoesWhat role, and what the last talent scan reads as -- because the
-- interesting part is where they disagree. The first two are dropdowns you pick
-- from; the third is EVIDENCE, not a control, with the point spread on hover and
-- a rescan button at the row's right edge to go and look again. The leading
-- column is one warning icon per member whose tooltip lists everything wrong
-- with them, from "no role yet" through to "tank isn't promoted".
--
-- This absorbed the old Action Items window, which was this page filtered to the
-- rows with a problem -- same roster line, same class tinting, same role
-- dropdown, and it said so in its own header. The filtering is gone; the
-- judging moved to ActionItems.lua, which is still the model behind the warning
-- icons and the count on the toolbar button.
--
-- There is deliberately no "fix" here -- neither per row nor a Fix All. Both
-- applied a guess derived from Blizzard's flag, which is the least trustworthy
-- thing on the row: Blizzard drops every new raider on DAMAGER, so "fix" mostly
-- meant writing that guess onto the board in bulk. Talents are the real
-- evidence, so the column offers them and lets you pick from the dropdown.
--
-- The "Unknown or Inactive" bucket collects players whose role has no
-- tank/healer/dps classification (custom roles left unclassified, and the
-- Non-raider pseudo-role) as well as those with no role at all, so it isn't
-- purely a to-do list. Talent auto-detection (TalentScanning.lua) fills most
-- rows on its own as data arrives, so this page is mainly for reviewing and
-- correcting. Empty buckets are hidden outright.

local membersFrame = nil

local OVERVIEW_H = 64 -- two-line summary strip between the title bar and grids
-- The counts line's inline icons stand taller than the font, so it needs a bit
-- more clearance under the title bar than the text alone would suggest.
local OVERVIEW_TOP_PAD = 15
local OVERVIEW_ICON_SIZE = 20
local MARGIN = 12
local SCROLLBAR_W = UI.SCROLLBAR_W

local GRID_GAP = 10
local CONTENT_TOP_PAD = 8 -- first grid's gap under the divider
-- Two lines: the bucket's own title keeps the first row to itself and the column
-- headings sit under it, so "2 Tanks" reads as the grid's name rather than as
-- the first column's heading.
-- The bucket title sits between GameFontNormal (12) and Large (16).
local GRID_TITLE_FONT_SIZE = 14
-- The icon SLOT: the name column starts after it at every density, and a
-- condensed row centres its smaller icon inside it.
local CLASS_ICON_SIZE = 20

-- Row density by group size. Roomy rows read well for a party or a ten-man,
-- but at 25 or 40 they turn the page into a long scroll where you can't see
-- both ends of the raid at once. So bigger groups get shorter rows: smaller
-- icons, a smaller name font past 30, and the two dropdowns and the refresh
-- button drawn at `controlScale` -- the dropdown template's box can't be made
-- shorter any other way. The grid header tightens a little alongside. Picked
-- off the whole roster, not per bucket, so every grid on the page matches.
local DENSITIES = {
    { minMembers = 30, label = "Compact", rowH = 22, iconSize = 16, tickSize = 12,
      headerH = 42, headingsY = 24, nameFont = "GameFontHighlightSmall",
      controlScale = 0.76, buttonSize = 18, buttonIcon = 12 },
    { minMembers = 20, label = "Condensed", rowH = 26, iconSize = 18, tickSize = 14,
      headerH = 45, headingsY = 26, nameFont = "GameFontHighlight",
      controlScale = 0.88, buttonSize = 21, buttonIcon = 14 },
    { minMembers = 0, label = "Roomy", rowH = 30, iconSize = 20, tickSize = 16,
      headerH = 48, headingsY = 28, nameFont = "GameFontHighlight",
      controlScale = 1, buttonSize = 24, buttonIcon = 16 },
}
local GEAR_SIZE = 16

local function DensityFor(memberCount)
    for _, density in ipairs(DENSITIES) do
        if memberCount >= density.minMembers then return density end
    end
end

-- Column geometry, left to right. The warning gutter LEADS the row: trailing it,
-- the icon read as belonging to the column it followed rather than to the member
-- it was flagging.
local ISSUE_COL_W = 22
local ICON_X = ISSUE_COL_W + 4
local NAME_X = ICON_X + CLASS_ICON_SIZE + 6
local NAME_W = 116
local ADDON_X = NAME_X + NAME_W
local ADDON_COL_W = 64 -- wide enough for the "Has WDW?" header
local GROUP_X = ADDON_X + ADDON_COL_W
local GROUP_DD_W = 124
local WDW_X = GROUP_X + GROUP_DD_W
local WDW_DD_W = 164
local TALENT_X = WDW_X + WDW_DD_W
-- The talents column: the role the spread reads as, icon and name, exactly like
-- the other two columns state a role. The point spread itself lives in the hover
-- tooltip -- "0/47/14" is evidence you consult, not a label you scan a list by.
-- The rescan button is pinned to the row's right edge, out of the column's flow.
local TALENT_PAD = 6
local TALENT_TEXT_W = 132

-- UIDropDownMenuTemplate's visible box starts inset from the frame's own left
-- edge, so both dropdown anchors back off by this much to line the box up with
-- the column it belongs to.
local DD_INSET = 15

local READY_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"
local NOT_READY_ICON = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local HEADER_ICON_SIZE = 16
local COMBAT_REASON = "Can't change roles in combat."

local BLIZZ_TO_WOW = WhoDoesWhat.BLIZZ_ROLE_TO_WOW_ROLE
local GROUP_ROLE_ORDER = { "tank", "healer", "dps" }

local SECTIONS = {
    { key = "tank",   one = "Tank",   many = "Tanks" },
    { key = "healer", one = "Healer", many = "Healers" },
    { key = "dps",    one = "DPS",    many = "DPS" },
    -- Non-raiders and unclassified custom roles land here too, so this bucket
    -- isn't purely a to-do list -- hence the vaguer label.
    { key = "none",   one = "Unknown or Inactive", many = "Unknown or Inactive" },
}

-- A bucket's icon: the three wow roles wear the client's micro role icon (same
-- shield/plus/sword the rows and dropdowns use), the roleless bucket wears the
-- shared warning icon.
local function SectionIcon(section, size)
    size = size or HEADER_ICON_SIZE
    if section.key == "none" then
        return "|T" .. WhoDoesWhat.WARNING_ICON .. ":" .. size .. ":" .. size .. ":0:0|t"
    end
    return WhoDoesWhat:GetWowRoleIconMarkup(section.key, size)
end

-- Grid header: "[icon] 2 Tanks".
local function SectionHeaderText(section, count)
    return SectionIcon(section) .. " " .. count .. " "
        .. (count == 1 and section.one or section.many)
end

-- The overview strip's first line: each bucket's icon and count. The three
-- role buckets show their zeros, since the grid below hides itself when empty
-- and this is where "no healers at all" stays visible. The roleless bucket
-- shows only when it has someone in it -- see below.
local function OverviewCounts(buckets)
    local parts = {}
    for _, section in ipairs(SECTIONS) do
        local count = #buckets[section.key]
        -- Zero earns its place for the three real roles: the grid below hides
        -- itself when empty, so this line is the only spot where "no healers at
        -- all" stays readable. The roleless bucket is the opposite case. It
        -- wears the warning icon, and a warning icon sitting over a 0 reads as
        -- an alert about nothing -- nobody unaccounted for is the GOOD outcome,
        -- and the good outcome should not be announced with a warning. So that
        -- one entry drops out entirely rather than showing an empty complaint.
        if count > 0 or section.key ~= "none" then
            parts[#parts + 1] = SectionIcon(section, OVERVIEW_ICON_SIZE)
                .. " " .. count
        end
    end
    return table.concat(parts, "      ")
end

-- Its second line: group size, WDW adoption, offline count when there is one,
-- and the issue tally.
--
-- The tally is the last thing the old Action Items window did that a page of
-- rows can't: "no warning icons anywhere" is not the same as being TOLD nothing
-- is wrong, and a clean board before a pull is worth stating outright. So zero
-- gets a green line of its own rather than silence.
local function OverviewDetail(total, withAddon, offline, issues)
    local text = total .. (total == 1 and " member" or " members")
        .. "  |cff606060-|r  " .. withAddon .. " with WhoDoesWhat"
    if offline > 0 then
        text = text .. "  |cff606060-|r  " .. offline .. " offline"
    end
    text = text .. "  |cff606060-|r  " .. (issues > 0
        and ("|cffff8000" .. issues .. (issues == 1 and " issue" or " issues")
            .. "|r")
        or "|cff40ff40Nothing to fix|r")
    return text
end

-- Dropdown row / collapsed text for a role: spec icon + class-colored name.
local function RoleText(role, classInfo)
    if not role then return "|cff909090None|r" end
    return WhoDoesWhat:RoleIconMarkup(role.icon, 14) .. " |cff"
        .. ((classInfo and classInfo.colorHex) or "ffffff") .. role.name .. "|r"
end

-- The same statement for Blizzard's coarser flag: role icon plus role name, so
-- the column reads against the two beside it.
local function GroupRoleText(blizzRole)
    local wowRole = blizzRole and BLIZZ_TO_WOW[blizzRole]
    local meta = wowRole and WhoDoesWhat.BasicWowRoles[wowRole]
    if not meta then return "|cff909090None|r" end
    return WhoDoesWhat:GetWowRoleIconMarkup(wowRole, 14) .. " " .. meta.name
end

-- Group members split into the four buckets, each sorted class > role > name.
local function BucketedMembers(review)
    local buckets = { tank = {}, healer = {}, dps = {}, none = {} }
    for _, m in ipairs(WhoDoesWhat:GetGroupMembers(nil)) do
        local data = review[m.name]
        local role = data and data.role
        local bucket = role and role.wowRole or "none" -- wowRole=false lands here too
        local list = buckets[bucket] or buckets.none
        list[#list + 1] = m
    end
    for _, list in pairs(buckets) do
        table.sort(list, function(a, b)
            if a.classInfo.name ~= b.classInfo.name then
                return a.classInfo.name < b.classInfo.name
            end
            -- Within a class, group by assigned role (specs clump together).
            local ra, rb = WhoDoesWhat:RoleSortRank(a.name), WhoDoesWhat:RoleSortRank(b.name)
            if ra ~= rb then return ra < rb end
            return a.name < b.name
        end)
    end
    return buckets
end

-- The row's warning icon, carrying a LIST rather than one sentence: one
-- member can be several kinds of wrong at once (no group flag AND an unpromoted
-- tank), and the whole point of collapsing three per-column icons into one
-- gutter is that the tooltip now has to say all of it.
local function CreateIssueIcon(row)
    return UI.CreateWarningIcon(row, ISSUE_COL_W - 2, function(self)
        local issues = self.issues
        if not (issues and #issues > 0) then return end
        GameTooltip:SetText(#issues == 1 and "1 issue"
            or (#issues .. " issues"), unpack(UI.TOOLTIP_TITLE))
        for index, text in ipairs(issues) do
            -- Blank line between them: several wrapped sentences run together
            -- read as one paragraph, and the count in the title then lies.
            if index > 1 then GameTooltip:AddLine(" ") end
            GameTooltip:AddLine(text, 1, 1, 1, true)
        end
        return true
    end)
end

-- The unit token for a group member, from the pass in ActionItems.lua. Nil for
-- fake raiders and for anyone who has since left (the assignment itself still
-- saves fine without one).
local function UnitOf(row)
    return row.data and row.data.unit or nil
end

-- Write the group flag straight, without touching the WDW board -- the opposite
-- direction from the WhoDoesWhat dropdown, which writes the board and lets
-- SyncBlizzardRoleState push the flag. This is the one you want when the board
-- is right and Blizzard's flag is what drifted.
--
-- Deliberately NOT gated on ManagesBlizzardRoles(): that switch stops WDW
-- writing flags on its own initiative. A person picking a group role out of a
-- dropdown IS the initiative.
local function SetGroupRole(name, unit, wowRole)
    local meta = WhoDoesWhat.BasicWowRoles[wowRole]
    if not (meta and UnitSetRole and unit) then return end
    if InCombatLockdown() then return end
    -- Picking here is a MANUAL write, so it takes the WoW rank the server
    -- demands (raid assist / party lead) rather than the single-writer
    -- election -- that election is for writes WDW makes on its own initiative,
    -- and a person clicking one dropdown once is not a race. Your own is always
    -- yours. Without some gate UnitSetRole silently no-ops.
    if not (UnitIsUnit(unit, "player")
        or WhoDoesWhat:CanSetOthersBlizzardRoleManually()) then
        return
    end
    UnitSetRole(unit, meta.blizzRole)
    -- The auto-sync path latches the last role id it wrote for this player to
    -- break write loops. A hand-picked flag makes that latch stale evidence.
    WhoDoesWhat:ClearRoleWriteLatch(name)
end

local function SetDropdownEnabled(dd, enabled)
    if enabled then
        UIDropDownMenu_EnableDropDown(dd)
    else
        UIDropDownMenu_DisableDropDown(dd)
    end
end

-- Both dropdowns explain themselves, and say why they're dead when they are.
-- Permission is a standing fact about the raid and combat is temporary, but the
-- reader doesn't care which -- they care why this control won't answer -- so
-- both arrive the same way.
local function AddDropdownTooltip(dd, title, body)
    UI.AddTooltip(dd, function(self)
        GameTooltip:SetText(title, unpack(UI.TOOLTIP_TITLE))
        GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true)
        if self.blockedReason then
            GameTooltip:AddLine(self.blockedReason, 1, 0.4, 0.4, true)
        end
        return true
    end)
end

-- Stand-in for a member the roster pass didn't cover; see RefreshRoster.
local EMPTY_REVIEW = { talentRoles = {}, issues = {} }

local RefreshRoster -- forward declared; row callbacks repaint through it

-- A repaint rebuckets everyone, so a role landing anywhere grows one grid and
-- shrinks another -- and both ends of that close every open dropdown. Hiding a
-- surplus row hides the dropdown frame inside it, and UIDropDownMenuTemplate's
-- OnHide is a global CloseDropDownMenus(); CreateRow's UIDropDownMenu_Initialize
-- hides every menu level outright. Neither cares which row you had open.
--
-- Mid-raid the repaint triggers never stop -- talent detection alone fires once
-- per player as inspect data lands (TalentScanning.lua), which is exactly the
-- stretch where you're here fixing the stragglers -- so menus were being yanked
-- shut before they could be clicked. Hold repaints while a menu is up and flush
-- once it closes.
local pendingRepaint = false

local function MenuIsOpen()
    return DropDownList1 and DropDownList1:IsShown()
end

-- Place a row dropdown so its visible box lands at column `x`, `width` wide,
-- at `scale`. Offsets and widths are in the dropdown's own scaled units, and
-- the template's DD_INSET overhang shrinks with it.
local function PlaceDropdown(dd, row, x, width, scale)
    dd:SetScale(scale)
    dd:ClearAllPoints()
    dd:SetPoint("LEFT", row, "LEFT", x / scale - DD_INSET, -2 / scale)
    UI.SetDropdownWidth(dd, width / scale)
end

-- Size and position pooled row #index for a density. Only runs when the
-- density changes (RefreshRoster checks), so a steady raid pays nothing.
local function ApplyRowDensity(row, index, density)
    row.density = density
    local rowH, headerH = density.rowH, density.headerH

    row:SetHeight(rowH)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -(headerH + (index - 1) * rowH))
    row:SetPoint("TOPRIGHT", 0, -(headerH + (index - 1) * rowH))

    local warnSize = math.min(ISSUE_COL_W - 2, rowH - 4)
    row.warnIcon:SetSize(warnSize, warnSize)

    row.classIcon:SetSize(density.iconSize, density.iconSize)
    row.classIcon:ClearAllPoints()
    row.classIcon:SetPoint("LEFT", ICON_X + (CLASS_ICON_SIZE - density.iconSize) / 2, 0)

    row.nameFS:SetFontObject(density.nameFont)
    row.nameHover:SetHeight(rowH)
    row.addonStatus:SetHeight(rowH)

    PlaceDropdown(row.groupDD, row, GROUP_X, GROUP_DD_W - 30, density.controlScale)
    PlaceDropdown(row.dropdown, row, WDW_X, WDW_DD_W - 30, density.controlScale)

    row.talentHover:SetHeight(rowH)

    row.rescanBtn:SetSize(density.buttonSize, density.buttonSize)
    row.rescanBtn.icon:SetSize(density.buttonIcon, density.buttonIcon)
end

-- The grid header's column headings and gold rule for a density.
local function ApplyHeaderDensity(state, density)
    state.density = density
    for _, fs in ipairs(state.headings) do
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", fs.x, -density.headingsY)
    end
    state.line:ClearAllPoints()
    state.line:SetPoint("TOPLEFT", 0, -(density.headerH - 1))
    state.line:SetPoint("TOPRIGHT", 0, -(density.headerH - 1))
end

-- Build pooled row #index inside a role grid. RefreshRoster positions it for
-- the current density and maps a member onto it (row.member / row.data),
-- hiding surplus rows, so the dropdowns read the current occupant at open time.
local function CreateRow(f, section, index)
    local state = f.sections[section.key]
    local box = state.box

    local row = CreateFrame("Frame", nil, box)
    row:SetFrameLevel(box:GetFrameLevel() + 1)

    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    row.stripe = stripe

    local warn = CreateIssueIcon(row)
    warn:SetPoint("LEFT", 1, 0)
    row.warnIcon = warn

    local icon = row:CreateTexture(nil, "ARTWORK")
    row.classIcon = icon

    local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameFS:SetPoint("LEFT", row, "LEFT", NAME_X, 0)
    nameFS:SetWidth(NAME_W - 4)
    nameFS:SetWordWrap(false)
    nameFS:SetJustifyH("LEFT")
    row.nameFS = nameFS

    local nameHover = CreateFrame("Frame", nil, row)
    nameHover:SetPoint("LEFT", ICON_X, 0)
    nameHover:EnableMouse(true)
    nameHover:SetScript("OnEnter", function(self)
        WhoDoesWhat:ShowRaiderTooltip(self, self.memberName)
    end)
    nameHover:SetScript("OnLeave", function() WhoDoesWhat:HideRaiderTooltip() end)
    row.nameHover = nameHover

    local addonStatus = CreateFrame("Frame", nil, row)
    addonStatus:SetWidth(ADDON_COL_W)
    addonStatus:SetPoint("LEFT", row, "LEFT", ADDON_X, 0)
    local addonIcon = addonStatus:CreateTexture(nil, "OVERLAY")
    addonIcon:SetSize(16, 16)
    addonIcon:SetPoint("CENTER")
    row.addonIcon = addonIcon
    row.addonStatus = addonStatus

    -- Group role: writes Blizzard's flag directly.
    local groupDD = UI.CreateMenuDropdown(row, "WhoDoesWhatMembersGroupDD_" .. section.key .. index, GROUP_DD_W - 30)
    UIDropDownMenu_Initialize(groupDD, function(_, level)
        local data, m = row.data, row.member
        if not (data and m) then return end
        for _, wowRole in ipairs(GROUP_ROLE_ORDER) do
            local meta = WhoDoesWhat.BasicWowRoles[wowRole]
            local info = UIDropDownMenu_CreateInfo()
            info.text = WhoDoesWhat:GetWowRoleIconMarkup(wowRole, 14) .. " " .. meta.name
            info.checked = data.blizzRole and BLIZZ_TO_WOW[data.blizzRole] == wowRole
            info.func = function()
                SetGroupRole(m.name, data.unit, wowRole)
                RefreshRoster(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    AddDropdownTooltip(groupDD, "Group role",
        "Blizzard's own Tank / Healer / Damage flag. Picking here changes only "
            .. "the flag.")
    row.groupDD = groupDD

    -- WhoDoesWhat role: writes the board, which pushes the flag to match.
    local dropdown = UI.CreateMenuDropdown(row, "WhoDoesWhatMembersRoleDD_" .. section.key .. index, WDW_DD_W - 30)
    UIDropDownMenu_Initialize(dropdown, function(_, level)
        local m, data = row.member, row.data
        if not m then return end
        local saved = data and data.roleId or nil

        local function AddRole(role)
            local info = UIDropDownMenu_CreateInfo()
            info.text = RoleText(role, m.classInfo)
            info.checked = (saved == role.id)
            info.func = function()
                -- SetAssignedRole repaints this view (and the main one).
                WhoDoesWhat:SetAssignedRole(m.name, role.id, data and data.unit, true)
            end
            UIDropDownMenu_AddButton(info, level)
        end
        for _, role in ipairs(m.classInfo.roles) do
            AddRole(role)
        end
        for _, role in ipairs(m.classInfo.customRoles or {}) do
            AddRole(role)
        end

        -- Non-raider (the classless "sitting out" pseudo-role), below a
        -- divider like the unit menu -- it isn't one of the class's specs.
        UI.AddDropdownDivider(level)
        local nr = WhoDoesWhat.NonRaiderRole
        local nrInfo = UIDropDownMenu_CreateInfo()
        nrInfo.text = RoleText(nr, WhoDoesWhat.NonRaiderClass)
        nrInfo.checked = (saved == nr.id)
        nrInfo.func = function()
            WhoDoesWhat:SetAssignedRole(m.name, nr.id, data and data.unit, true)
        end
        UIDropDownMenu_AddButton(nrInfo, level)

        -- "None" matches the unit menu: a passive read-out of the roleless
        -- state, shown only while the player has no role and never clickable.
        -- Once assigned, the way to change is to pick another role -- neither
        -- panel un-assigns a role back to roleless.
        if saved == nil then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "None"
            info.checked = true
            info.disabled = true
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    AddDropdownTooltip(dropdown, "WhoDoesWhat role",
        "Sets their spec on the board and pushes their group role to match.")
    row.dropdown = dropdown

    -- Talents: what we have actually seen, not what anyone picked, stated as a
    -- role so the column can be read against the two beside it -- two roles for
    -- a feral druid, whose tree genuinely cannot tell cat from bear. The raw
    -- points are one hover away.
    local talentText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    talentText:SetPoint("LEFT", row, "LEFT", TALENT_X + TALENT_PAD, 0)
    talentText:SetWidth(TALENT_TEXT_W)
    talentText:SetWordWrap(false)
    talentText:SetJustifyH("LEFT")
    row.talentText = talentText

    -- A FontString can't take OnEnter, so the breakdown hangs off a frame laid
    -- over the column. RefreshRoster hands it the snapshot to render.
    local talentHover = CreateFrame("Frame", nil, row)
    talentHover:SetPoint("LEFT", row, "LEFT", TALENT_X, 0)
    talentHover:SetWidth(TALENT_PAD + TALENT_TEXT_W)
    talentHover:EnableMouse(true)
    UI.AddTooltip(talentHover, function(self)
        GameTooltip:SetText("Talents", unpack(UI.TOOLTIP_TITLE))
        local snapshot = self.snapshot
        if not snapshot then
            GameTooltip:AddLine("Nobody has been close enough to inspect them "
                .. "yet -- the refresh button queues one.", 0.8, 0.8, 0.8, true)
        else
            for i, points in ipairs(snapshot.points) do
                GameTooltip:AddDoubleLine(
                    (snapshot.specNames and snapshot.specNames[i])
                        or ("Tree " .. i),
                    tostring(points), 1, 0.82, 0, 1, 1, 1)
            end
            if self.readsAs then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Reads as " .. self.readsAs .. ".",
                    0.8, 0.8, 0.8, true)
            end
        end
        return true
    end)
    row.talentHover = talentHover

    -- Go and look again. Not a fix and not gated on permissions -- an inspect
    -- writes nothing to anyone's board, it just refreshes the evidence the rest
    -- of the row is judged against. Wears the LFG tool's refresh arrows rather
    -- than a word; the tooltip says what it does.
    local rescanBtn = UI.CreateIconButton(row, UI.REFRESH_ICON, function(self)
        GameTooltip:SetText("Rescan talents", unpack(UI.TOOLTIP_TITLE))
        GameTooltip:AddLine("Queue a fresh inspect. They have to be in range "
            .. "-- out of range, their last-known talents stand.",
            0.8, 0.8, 0.8, true)
        if self.blockedReason then
            GameTooltip:AddLine(self.blockedReason, 1, 0.4, 0.4, true)
        end
        return true
    end, nil, function()
        local m = row.member
        if not m then return end
        WhoDoesWhat:RescanPlayerTalents(UnitOf(row), m.name)
    end)
    rescanBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.rescanBtn = rescanBtn

    state.rows[index] = row
    return row
end

-- Paint one member onto one pooled row.
local function LayoutRow(row, m, data, index, connected)
    row.member = m
    row.data = data

    local rowColors = connected and m.classInfo.gridRowColors
        or WhoDoesWhat.DisconnectedGridRowColors
    local rowColor = rowColors[index % 2 == 1 and 1 or 2]
    row.stripe:SetColorTexture(rowColor.r, rowColor.g, rowColor.b, rowColor.a)

    -- Their spec's icon once they have one; the class icon while they don't.
    -- The warning gutter is its own column now, so the icon slot no longer has
    -- to be given up to hold a (!).
    WhoDoesWhat:SetRoleIconTexture(row.classIcon,
        (data.role and data.role.icon) or m.classInfo.classIcon)
    row.classIcon:SetDesaturated(not connected)

    row.nameFS:SetText("|cff" .. (connected and m.classInfo.colorHex or "909090")
        .. m.name .. "|r")
    row.nameHover.memberName = m.name
    row.nameHover:SetWidth(CLASS_ICON_SIZE + 6
        + math.min(NAME_W - 4, row.nameFS:GetStringWidth()))

    local installed = m.name == UnitName("player")
        or WhoDoesWhat.syncPeers[m.name] == true
    -- Offline says nothing about whether they run WDW, and the row already
    -- reads as offline four other ways -- leave the cell empty.
    row.addonIcon:SetShown(connected)
    if connected then
        row.addonIcon:SetTexture(installed and READY_ICON or NOT_READY_ICON)
        -- The ready tick's art sits short in its square, so it's drawn 13/16
        -- as tall to match the cross beside it.
        local tick = row.density.tickSize
        row.addonIcon:SetSize(tick, installed and tick * 13 / 16 or tick)
    end

    local combat = InCombatLockdown()
    local combatReason = combat and COMBAT_REASON or nil

    -- Permission and combat both end at the same place -- a dropdown that can't
    -- answer -- so both simply disable it. A disabled dropdown still reads its
    -- value out, which is exactly what a read-only column wants to do anyway.
    UIDropDownMenu_SetText(row.groupDD, GroupRoleText(data.blizzRole))
    -- The model already worked out WHY, and the causes want telling apart: a
    -- rank you lack (standing) versus combat (passes on its own).
    row.groupDD.blockedReason = combatReason
        or (not data.mayFlag and data.flagBlocker or nil)
    SetDropdownEnabled(row.groupDD, data.mayFlag and not combat)

    if data.role then
        UIDropDownMenu_SetText(row.dropdown, RoleText(data.role, m.classInfo))
    elseif data.roleId then
        -- An id that no longer resolves (deleted custom role): show honest
        -- confusion rather than pretending it's unassigned.
        UIDropDownMenu_SetText(row.dropdown, "|cff909090?|r")
    else
        UIDropDownMenu_SetText(row.dropdown, "|cff909090None|r")
    end
    row.dropdown.blockedReason = combatReason
        or (not data.mayRole and "The raid leader has editing restricted." or nil)
    SetDropdownEnabled(row.dropdown, data.mayRole and not combat)
    row.dropdown:SetAlpha(connected and 1 or 0.55)

    -- Talents, or a grey "not scanned yet" where none have been seen: an unknown
    -- spread has to read as unknown, not as a player with no points.
    local talentLabels, talentNames = {}, {}
    for _, role in ipairs(data.talentRoles) do
        talentLabels[#talentLabels + 1] = RoleText(role, m.classInfo)
        talentNames[#talentNames + 1] = role.name
    end
    row.talentText:SetText(
        (#talentLabels > 0 and table.concat(talentLabels, " / "))
        -- Points seen but no role behind them: a class/spec the table doesn't
        -- map (there is no such class today, but a bad spec index would land
        -- here). Fall back to the spread rather than claiming nothing is known.
        or (data.snapshot and table.concat(data.snapshot.points, "/"))
        or "|cff909090not scanned|r")
    row.talentHover.snapshot = data.snapshot
    row.talentHover.readsAs = #talentNames > 0
        and table.concat(talentNames, " or ") or nil

    -- Already queued: the button has done its job and pressing it again just
    -- re-queues the same inspect, so it goes quiet until the answer lands or
    -- the request times out.
    local pendingScan = WhoDoesWhat:IsTalentRescanPending(m.name)
    local canScan = not combat and not pendingScan and data.unit ~= nil
    row.rescanBtn:SetEnabled(canScan)
    -- The template greys its own chrome but not the icon laid over it.
    row.rescanBtn.icon:SetDesaturated(not canScan)
    row.rescanBtn.blockedReason = (m.isFake
            and "Fake raiders' talents are simulated -- there is nobody to inspect.")
        or (combat and "Can't inspect in combat.")
        or (pendingScan and "Queued -- waiting for their talents to arrive.")
        or (not data.unit and "They aren't in the group right now.") or nil

    row.warnIcon.issues = data.issues
    row.warnIcon:SetShown(#data.issues > 0)

    row:Show()
end

-- Recompute the scroll child's height from the stacked grids. Empty grids are
-- hidden (RefreshRoster), so they contribute nothing. The trailing GRID_GAP
-- after the last grid doubles as bottom padding, exactly as the Raid page's
-- SECTION_GAP does.
local function UpdateContentHeight(f)
    local h = CONTENT_TOP_PAD
    for _, section in ipairs(SECTIONS) do
        local box = f.sections[section.key].box
        if box:IsShown() then h = h + box:GetHeight() + GRID_GAP end
    end
    -- The scroll area keeps the content as wide as itself when it resizes; this
    -- covers a first paint that lands before the scroll area has had a size.
    local width = f.scroll:GetWidth()
    if width and width > 1 then f.content:SetWidth(width) end
    UI.SetScrollHeight(f.scroll, h)
end

-- Map the current group onto the pooled rows, retitle each grid with its count,
-- and resize everything. The grids are anchor-chained, so height changes ripple
-- down on their own.
function RefreshRoster(f)
    if MenuIsOpen() then
        pendingRepaint = true
        return
    end
    pendingRepaint = false

    -- One pass over the roster answers every row: role, flag, talents,
    -- permissions and everything wrong with them (ActionItems.lua).
    local review, issueCount = WhoDoesWhat:GetRosterIssues()
    local buckets = BucketedMembers(review)
    local prevBox -- last *shown* grid; the chain re-anchors past hidden ones
    local total, withAddon, offline = 0, 0, 0
    local memberCount = 0
    for _, section in ipairs(SECTIONS) do
        memberCount = memberCount + #buckets[section.key]
    end
    -- A size picked from the gear holds only while the roster stays in the
    -- tier it was picked in; crossing into another hands the page back to the
    -- automatic size for its new headcount.
    local autoDensity = DensityFor(memberCount)
    f.autoDensity = autoDensity
    if f.pickedDensity and f.pickedInTier ~= autoDensity then
        f.pickedDensity, f.pickedInTier = nil, nil
    end
    local density = f.pickedDensity or autoDensity

    for _, section in ipairs(SECTIONS) do
        local state = f.sections[section.key]
        local members = buckets[section.key]

        state.title:SetText(SectionHeaderText(section, #members))
        if state.density ~= density then ApplyHeaderDensity(state, density) end

        for i, m in ipairs(members) do
            local row = state.rows[i] or CreateRow(f, section, i)
            if row.density ~= density then ApplyRowDensity(row, i, density) end
            -- Both loops walk the same frame-cached roster (Assignments.lua),
            -- so the lookup always lands; the fallback only keeps a roster that
            -- somehow moved underneath us from erroring mid-paint.
            local data = review[m.name] or EMPTY_REVIEW
            local connected = m.isFake
                or (data.unit and UnitIsConnected(data.unit) ~= false) or false

            LayoutRow(row, m, data, i, connected)

            total = total + 1
            if not connected then offline = offline + 1 end
            if m.name == UnitName("player")
                or WhoDoesWhat.syncPeers[m.name] == true then
                withAddon = withAddon + 1
            end
        end
        for i = #members + 1, #state.rows do
            state.rows[i]:Hide()
            state.rows[i].member = nil
            state.rows[i].data = nil
            state.rows[i].nameHover.memberName = nil
        end
        -- An empty bucket says nothing worth a header, so it drops out of the
        -- page entirely; hiding alone would leave its slot in the anchor
        -- chain, so the next shown grid re-anchors to the last shown one.
        state.box:SetShown(#members > 0)
        if #members > 0 then
            state.box:SetHeight(density.headerH + #members * density.rowH)
            -- Both edges, every time: the grid takes its width from the page,
            -- and a grid pinned by one corner alone has no width, so neither
            -- do the rows hung across it.
            state.box:ClearAllPoints()
            if prevBox then
                state.box:SetPoint("TOPLEFT", prevBox, "BOTTOMLEFT", 0, -GRID_GAP)
                state.box:SetPoint("TOPRIGHT", prevBox, "BOTTOMRIGHT", 0, -GRID_GAP)
            else
                state.box:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -CONTENT_TOP_PAD)
                state.box:SetPoint("TOPRIGHT", f.content, "TOPRIGHT", 0, -CONTENT_TOP_PAD)
            end
            prevBox = state.box
        end
    end

    f.overviewCounts:SetText(OverviewCounts(buckets))
    f.overviewDetail:SetText(OverviewDetail(total, withAddon, offline, issueCount))

    UpdateContentHeight(f)
end

-- Created on first open, not at load: see PaladinBuffsSection's note on
-- DropDownList frames.
local sizeMenu

local function OpenSizeMenu(f, button)
    if not sizeMenu then
        sizeMenu = CreateFrame("Frame", "WhoDoesWhatMembersSizeMenu",
            UIParent, "UIDropDownMenuTemplate")
    end
    UIDropDownMenu_Initialize(sizeMenu, function(_, level)
        local title = UIDropDownMenu_CreateInfo()
        title.text = "Row Size"
        title.isTitle = true
        title.notCheckable = true
        UIDropDownMenu_AddButton(title, level)

        local auto = UIDropDownMenu_CreateInfo()
        auto.text = "Automatic"
        auto.checked = f.pickedDensity == nil
        auto.func = function()
            f.pickedDensity, f.pickedInTier = nil, nil
            RefreshRoster(f)
        end
        UIDropDownMenu_AddButton(auto, level)

        -- Roomiest first, the order the page steps down through as it fills.
        for i = #DENSITIES, 1, -1 do
            local density = DENSITIES[i]
            local info = UIDropDownMenu_CreateInfo()
            info.text = density.label
            info.checked = f.pickedDensity == density
            info.func = function()
                f.pickedDensity, f.pickedInTier = density, f.autoDensity
                RefreshRoster(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end, "MENU")
    ToggleDropDownMenu(1, nil, sizeMenu, button, 0, 0)
end

-- Build the page into the Members tab: the four role grids (rows come from
-- RefreshRoster) scrolling under a fixed overview strip, stretched across the
-- page. The columns keep their places from the left; the rescan button rides the
-- right edge, so the rows' stripes span the whole width.
function WhoDoesWhat:BuildMembersPage(page)
    local f = CreateFrame("Frame", nil, page)
    f:SetAllPoints(page)
    f.titleBarHeight = 0

    -- Overview strip: fixed chrome above the scroll area, so it stays put while
    -- the grids scroll under it.
    local counts = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    counts:SetPoint("TOP", f, "TOP", 0, -(f.titleBarHeight + OVERVIEW_TOP_PAD))
    counts:SetJustifyH("CENTER")
    f.overviewCounts = counts

    local detail = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detail:SetPoint("TOP", counts, "BOTTOM", 0, -8)
    detail:SetJustifyH("CENTER")
    detail:SetTextColor(0.65, 0.65, 0.65)
    f.overviewDetail = detail

    -- The row-size picker, in the corner over the scrollbar's gutter like the
    -- Buff Grid's source gear.
    local gear = UI.CreateBareIconButton(f, UI.GEAR_ICON, GEAR_SIZE,
        function()
            GameTooltip:SetText("Row Size", unpack(UI.TOOLTIP_TITLE))
            GameTooltip:AddLine(f.pickedDensity
                and (f.pickedDensity.label .. ", until the group grows or"
                    .. " shrinks into another size.")
                or "Automatic: rows tighten as the group grows.",
                0.8, 0.8, 0.8, true)
            return true
        end, nil,
        function(self) OpenSizeMenu(f, self) end)
    gear:SetPoint("CENTER", f, "TOPRIGHT", -(MARGIN + SCROLLBAR_W / 2),
        -(f.titleBarHeight + OVERVIEW_TOP_PAD + GEAR_SIZE / 2))

    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(unpack(WhoDoesWhat.Theme.goldDivider))
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + OVERVIEW_H))
    rule:SetPoint("TOPRIGHT", -MARGIN, -(f.titleBarHeight + OVERVIEW_H))

    -- The scroll area starts right under the divider, so rows scroll up to it
    -- and fade under its shadow; the breathing room at rest is CONTENT_TOP_PAD
    -- inside the content instead.
    f.scrollTop = f.titleBarHeight + OVERVIEW_H + 1 -- chrome above the scroll area

    local scroll, content = UI.CreateScroll(f, "WhoDoesWhatMembersScroll")
    scroll:SetPoint("TOPLEFT", MARGIN, -f.scrollTop)
    scroll:SetPoint("BOTTOMRIGHT", -(MARGIN + SCROLLBAR_W), 0)
    f.content = content
    f.scroll = scroll
    -- Shadows on both ends, so rows fade out under the divider and off the
    -- page's bottom edge; the bar pulls in clear of both.
    local shadowLevel = scroll:GetFrameLevel() + 20
    local topShadow = UI.CreateEdgeShadow(f, shadowLevel, true)
    topShadow:SetPoint("TOPLEFT", rule, "BOTTOMLEFT")
    topShadow:SetPoint("TOPRIGHT", rule, "BOTTOMRIGHT")
    local bottomShadow = UI.CreateEdgeShadow(f, shadowLevel, false)
    bottomShadow:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", MARGIN, 0)
    bottomShadow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -MARGIN, 0)
    UI.InsetScrollBar(scroll, 8)

    WhoDoesWhat:LogUiBuilding("Building members content.")

    f.sections = {}
    local prevBox
    for _, section in ipairs(SECTIONS) do
        local box = CreateFrame("Frame", nil, content)
        box:SetFrameLevel(content:GetFrameLevel() + 1)
        if prevBox then
            box:SetPoint("TOPLEFT", prevBox, "BOTTOMLEFT", 0, -GRID_GAP)
            box:SetPoint("TOPRIGHT", prevBox, "BOTTOMRIGHT", 0, -GRID_GAP)
        else
            box:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -CONTENT_TOP_PAD)
            box:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -CONTENT_TOP_PAD)
        end
        prevBox = box

        local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        local fontPath, _, fontFlags = title:GetFont()
        title:SetFont(fontPath, GRID_TITLE_FONT_SIZE, fontFlags)
        title:SetPoint("TOPLEFT", 4, -4)
        title:SetText(SectionHeaderText(section, 0))

        -- Column headings on their own line under the bucket title, each lined
        -- up with its column's content: the class icon, the WDW tick, the
        -- dropdowns' own text inset, and the first talent icon.
        -- ApplyHeaderDensity places them vertically, per density.
        local headings = {}
        local function Heading(text, x, w, justify)
            local fs = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetWidth(w)
            fs:SetJustifyH(justify or "LEFT")
            fs:SetText(text)
            fs.x = x
            headings[#headings + 1] = fs
        end
        Heading("Player", ICON_X, NAME_W + CLASS_ICON_SIZE)
        Heading("Has WDW?", ADDON_X, ADDON_COL_W, "CENTER")
        Heading("Group role", GROUP_X + 8, GROUP_DD_W)
        Heading("WhoDoesWhat", WDW_X + 8, WDW_DD_W)
        Heading("Talents", TALENT_X + TALENT_PAD, TALENT_TEXT_W)

        local line = box:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(unpack(WhoDoesWhat.Theme.goldDivider))
        line:SetHeight(1)

        f.sections[section.key] = { box = box, title = title, rows = {},
            headings = headings, line = line }
    end

    -- Track joins/leaves live while the page is on screen, and catch up
    -- whenever it comes back.
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:RegisterEvent("UNIT_CONNECTION")
    f:SetScript("OnShow", RefreshRoster)
    f:SetScript("OnEvent", function(self)
        if self:IsVisible() then
            RefreshRoster(self)
        end
    end)

    -- Flush whatever the open menu held back. A selection made here doesn't
    -- come through this path: Blizzard hides the list before running the
    -- clicked button's func, so SetAssignedRole's repaint arrives with nothing
    -- open and paints straight away.
    if DropDownList1 then
        DropDownList1:HookScript("OnHide", function()
            if not pendingRepaint then return end
            pendingRepaint = false
            if membersFrame and membersFrame:IsVisible() then
                RefreshRoster(membersFrame)
            end
        end)
    end

    membersFrame = f
    return f
end

-- Repaint if the page is on screen, and keep the Members tab's count honest
-- either way. Called from outside the view when assignments change
-- (SetAssignedRole in UnitMenuExtensions.lua, talent auto-detection).
function WhoDoesWhat:RefreshMembersView()
    self:RefreshMainTabs()
    if membersFrame and membersFrame:IsVisible() then
        RefreshRoster(membersFrame)
    end
end

-- Open the main window on the Members tab, or close it if it is already there.
function WhoDoesWhat:OpenMembersView()
    self:ShowMainTab("members")
end
