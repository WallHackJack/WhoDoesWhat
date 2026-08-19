local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local K = WhoDoesWhat.SectionKit

-- Members window ("Members" button on the main view): every group member in one
-- of four role grids, bucketed by their assigned role's tank/healer/dps
-- classification and sorted by class then name.
--
-- Each row states the same fact three times over -- Blizzard's group flag, the
-- WhoDoesWhat role, and what the last talent scan reads as -- because the
-- interesting part is where they disagree. The first two are dropdowns you pick
-- from; the third is EVIDENCE, not a control, with the point spread on hover and
-- a Rescan button at the row's right edge to go and look again. The leading
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

-- The window auto-fits its content between these two; only at the ceiling does
-- the scrollbar appear (UpdateContentHeight).
local MIN_FRAME_H = 230
local MAX_FRAME_H = 560
local OVERVIEW_H = 55 -- two-line summary strip between the title bar and grids
-- The counts line's inline icons stand taller than the font, so it needs a bit
-- more clearance under the title bar than the text alone would suggest.
local OVERVIEW_TOP_PAD = 15
local OVERVIEW_ICON_SIZE = 18
local MARGIN = 12
local SCROLLBAR_W = 26

local GRID_GAP = 10
-- Two lines: the bucket's own title keeps the first row to itself and the column
-- headings sit under it, so "2 Tanks" reads as the grid's name rather than as
-- the first column's heading.
local GRID_HEADER_H = 44
local GRID_HEADINGS_Y = 24
local ROW_H = 30
local CLASS_ICON_SIZE = 20

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
-- Rescan is pinned to the row's right edge, out of the column's flow.
local TALENT_PAD = 6
local TALENT_TEXT_W = 132
local RESCAN_BTN_W = 62
local TALENT_COL_W = TALENT_PAD + TALENT_TEXT_W + 8 + RESCAN_BTN_W + 4
local CONTENT_W = TALENT_X + TALENT_COL_W
local FRAME_W = CONTENT_W + MARGIN * 2 + SCROLLBAR_W

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

-- The overview strip's first line: every bucket's icon and count, zeros
-- included. An empty grid is hidden below, so this is where "no healers at
-- all" stays visible -- which is the reading you actually want at a glance.
local function OverviewCounts(buckets)
    local parts = {}
    for _, section in ipairs(SECTIONS) do
        parts[#parts + 1] = SectionIcon(section, OVERVIEW_ICON_SIZE)
            .. " " .. #buckets[section.key]
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

-- The row's warning icon. Unlike K.CreateWarningIcon it carries a LIST: one
-- member can be several kinds of wrong at once (no group flag AND an unpromoted
-- tank), and the whole point of collapsing three per-column icons into one
-- gutter is that the tooltip now has to say all of it.
local function CreateIssueIcon(row)
    local warn = CreateFrame("Frame", nil, row)
    warn:SetSize(ISSUE_COL_W - 2, ISSUE_COL_W - 2)
    local tex = warn:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture(WhoDoesWhat.WARNING_ICON)
    warn:EnableMouse(true)
    warn:SetScript("OnEnter", function(self)
        local issues = self.issues
        if not (issues and #issues > 0) then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(#issues == 1 and "1 issue"
            or (#issues .. " issues"), 1, 0.82, 0)
        for index, text in ipairs(issues) do
            -- Blank line between them: several wrapped sentences run together
            -- read as one paragraph, and the count in the title then lies.
            if index > 1 then GameTooltip:AddLine(" ") end
            GameTooltip:AddLine(text, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    warn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    warn:Hide()
    return warn
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
    -- Writing another member's flag takes the single-writer election (Core.lua);
    -- your own is always yours. Without this UnitSetRole silently no-ops.
    if not (UnitIsUnit(unit, "player")
        or WhoDoesWhat:CanSetOthersBlizzardRole()) then
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
    dd:EnableMouse(true)
    dd:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(title, 1, 1, 1)
        GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true)
        if self.blockedReason then
            GameTooltip:AddLine(self.blockedReason, 1, 0.4, 0.4, true)
        end
        GameTooltip:Show()
    end)
    dd:SetScript("OnLeave", function() GameTooltip:Hide() end)
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

-- Build pooled row #index inside a role grid. The position is fixed;
-- RefreshRoster maps a member onto it (row.member / row.data) and hides surplus
-- rows, so the dropdowns read the current occupant at open time.
local function CreateRow(f, section, index)
    local state = f.sections[section.key]
    local box = state.box

    local row = CreateFrame("Frame", nil, box)
    row:SetFrameLevel(box:GetFrameLevel() + 1)
    row:SetSize(box:GetWidth(), ROW_H)
    row:SetPoint("TOPLEFT", 0, -(GRID_HEADER_H + (index - 1) * ROW_H))

    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    row.stripe = stripe

    local warn = CreateIssueIcon(row)
    warn:SetPoint("LEFT", 1, 0)
    row.warnIcon = warn

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(CLASS_ICON_SIZE, CLASS_ICON_SIZE)
    icon:SetPoint("LEFT", ICON_X, 0)
    row.classIcon = icon

    local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameFS:SetPoint("LEFT", row, "LEFT", NAME_X, 0)
    nameFS:SetWidth(NAME_W - 4)
    nameFS:SetWordWrap(false)
    nameFS:SetJustifyH("LEFT")
    row.nameFS = nameFS

    local nameHover = CreateFrame("Frame", nil, row)
    nameHover:SetHeight(ROW_H)
    nameHover:SetPoint("LEFT", ICON_X, 0)
    nameHover:EnableMouse(true)
    nameHover:SetScript("OnEnter", function(self)
        WhoDoesWhat:ShowRaiderTooltip(self, self.memberName)
    end)
    nameHover:SetScript("OnLeave", function() WhoDoesWhat:HideRaiderTooltip() end)
    row.nameHover = nameHover

    local addonStatus = CreateFrame("Frame", nil, row)
    addonStatus:SetSize(ADDON_COL_W, ROW_H)
    addonStatus:SetPoint("LEFT", row, "LEFT", ADDON_X, 0)
    local addonIcon = addonStatus:CreateTexture(nil, "OVERLAY")
    addonIcon:SetSize(16, 16)
    addonIcon:SetPoint("CENTER")
    row.addonIcon = addonIcon

    -- Group role: writes Blizzard's flag directly.
    local groupDD = CreateFrame("Frame",
        "WhoDoesWhatMembersGroupDD_" .. section.key .. index, row,
        "UIDropDownMenuTemplate")
    groupDD:SetPoint("LEFT", row, "LEFT", GROUP_X - DD_INSET, -2)
    UIDropDownMenu_SetWidth(groupDD, GROUP_DD_W - 30)
    K.LeftAlignDropdown(groupDD)
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
    local dropdown = CreateFrame("Frame",
        "WhoDoesWhatMembersRoleDD_" .. section.key .. index, row, "UIDropDownMenuTemplate")
    dropdown:SetPoint("LEFT", row, "LEFT", WDW_X - DD_INSET, -2)
    UIDropDownMenu_SetWidth(dropdown, WDW_DD_W - 30)
    K.LeftAlignDropdown(dropdown)
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
                WhoDoesWhat:SetAssignedRole(m.name, role.id, data and data.unit)
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
        K.AddDropdownDivider(level)
        local nr = WhoDoesWhat.NonRaiderRole
        local nrInfo = UIDropDownMenu_CreateInfo()
        nrInfo.text = RoleText(nr, WhoDoesWhat.NonRaiderClass)
        nrInfo.checked = (saved == nr.id)
        nrInfo.func = function()
            WhoDoesWhat:SetAssignedRole(m.name, nr.id, data and data.unit)
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
    talentHover:SetSize(TALENT_PAD + TALENT_TEXT_W, ROW_H)
    talentHover:EnableMouse(true)
    talentHover:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Talents", 1, 1, 1)
        local snapshot = self.snapshot
        if not snapshot then
            GameTooltip:AddLine("Nobody has been close enough to inspect them "
                .. "yet -- Rescan queues one.", 0.8, 0.8, 0.8, true)
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
        GameTooltip:Show()
    end)
    talentHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.talentHover = talentHover

    -- Go and look again. Not a fix and not gated on permissions -- an inspect
    -- writes nothing to anyone's board, it just refreshes the evidence the rest
    -- of the row is judged against.
    local rescanBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    rescanBtn:SetSize(RESCAN_BTN_W, ROW_H - 8)
    rescanBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    rescanBtn:SetText("Rescan")
    rescanBtn:SetMotionScriptsWhileDisabled(true)
    rescanBtn:SetScript("OnClick", function()
        local m = row.member
        if not m then return end
        WhoDoesWhat:RescanPlayerTalents(UnitOf(row), m.name)
    end)
    rescanBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Rescan talents", 1, 1, 1)
        GameTooltip:AddLine("Queue a fresh inspect. They have to be in range "
            .. "-- out of range, their last-known talents stand.",
            0.8, 0.8, 0.8, true)
        if self.blockedReason then
            GameTooltip:AddLine(self.blockedReason, 1, 0.4, 0.4, true)
        end
        GameTooltip:Show()
    end)
    rescanBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
        row.addonIcon:SetSize(16, installed and 13 or 16)
    end

    local combat = InCombatLockdown()
    local combatReason = combat and COMBAT_REASON or nil

    -- Permission and combat both end at the same place -- a dropdown that can't
    -- answer -- so both simply disable it. A disabled dropdown still reads its
    -- value out, which is exactly what a read-only column wants to do anyway.
    UIDropDownMenu_SetText(row.groupDD, GroupRoleText(data.blizzRole))
    row.groupDD.blockedReason = combatReason
        or (not data.mayFlag and (data.unit
            and "You can't set other players' group roles."
            or "They aren't in the group right now.") or nil)
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
    row.rescanBtn:SetEnabled(not combat and not pendingScan and data.unit ~= nil)
    row.rescanBtn:SetText(pendingScan and "Queued" or "Rescan")
    row.rescanBtn.blockedReason = (combat and "Can't inspect in combat.")
        or (pendingScan and "Waiting for their talents to arrive.")
        or (not data.unit and "They aren't in the group right now.") or nil

    row.warnIcon.issues = data.issues
    row.warnIcon:SetShown(#data.issues > 0)

    row:Show()
end

-- Recompute the scroll child's height from the stacked grids, then fit the
-- window to it. Empty grids are hidden (RefreshRoster), so they contribute
-- nothing. The trailing GRID_GAP after the last grid doubles as bottom padding,
-- exactly as the main view's SECTION_GAP does. Only once the content passes
-- MAX_FRAME_H does the window stop growing and the scrollbar appear -- the
-- ScrollFrame hides it on its own while the range is zero (scrollBarHideable).
local function UpdateContentHeight(f)
    local h = 0
    for _, section in ipairs(SECTIONS) do
        local box = f.sections[section.key].box
        if box:IsShown() then h = h + box:GetHeight() + GRID_GAP end
    end
    f.content:SetHeight(math.max(h, 1))
    f.scroll:UpdateScrollChildRect()

    local desired = f.scrollTop + h + MARGIN
    f:SetHeight(math.max(MIN_FRAME_H, math.min(desired, MAX_FRAME_H)))
    -- scrollBarHideable only reacts to a *change* in scroll range, which leaves
    -- the bar up on the first paint. We already know whether it's needed. The
    -- track can't ride the bar's OnShow/OnHide: the first repaint runs while the
    -- window is still hidden, where hiding an already-invisible bar fires
    -- neither -- so it's driven from the same answer.
    local needsBar = desired > MAX_FRAME_H
    if f.scrollBar then f.scrollBar:SetShown(needsBar) end
    if f.scrollTrack then f.scrollTrack:SetShown(needsBar) end
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

    f.titleText:SetText(IsInRaid() and "Raid Members" or "Group Members")

    -- One pass over the roster answers every row: role, flag, talents,
    -- permissions and everything wrong with them (ActionItems.lua).
    local review, issueCount = WhoDoesWhat:GetRosterIssues()
    local buckets = BucketedMembers(review)
    local prevBox -- last *shown* grid; the chain re-anchors past hidden ones
    local total, withAddon, offline = 0, 0, 0
    for _, section in ipairs(SECTIONS) do
        local state = f.sections[section.key]
        local members = buckets[section.key]

        state.title:SetText(SectionHeaderText(section, #members))

        for i, m in ipairs(members) do
            local row = state.rows[i] or CreateRow(f, section, i)
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
            state.box:SetHeight(GRID_HEADER_H + #members * ROW_H)
            state.box:ClearAllPoints()
            if prevBox then
                state.box:SetPoint("TOPLEFT", prevBox, "BOTTOMLEFT", 0, -GRID_GAP)
            else
                state.box:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, 0)
            end
            prevBox = state.box
        end
    end

    f.overviewCounts:SetText(OverviewCounts(buckets))
    f.overviewDetail:SetText(OverviewDetail(total, withAddon, offline, issueCount))

    UpdateContentHeight(f)
end

-- Build the window once and reuse it: shared chrome, a scroll column, and the
-- four role grids (rows come from RefreshRoster).
local function EnsureMembersFrame()
    if membersFrame then return membersFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatMembersFrame",
        FRAME_W, MIN_FRAME_H, "Group Members")

    -- Centred title, unlike the shared left-aligned chrome: this window's title
    -- is a two-word label rather than a sentence, and it sits over a centred
    -- overview strip.
    f.titleText:ClearAllPoints()
    f.titleText:SetPoint("CENTER", f.titleBarTexture, "CENTER", 0, 0)

    -- Overview strip: fixed chrome above the scroll area, so it stays put while
    -- the grids scroll under it.
    local counts = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    counts:SetPoint("TOP", f, "TOP", 0, -(f.titleBarHeight + OVERVIEW_TOP_PAD))
    counts:SetJustifyH("CENTER")
    f.overviewCounts = counts

    local detail = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    detail:SetPoint("TOP", counts, "BOTTOM", 0, -4)
    detail:SetJustifyH("CENTER")
    detail:SetTextColor(0.65, 0.65, 0.65)
    f.overviewDetail = detail

    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + OVERVIEW_H))
    rule:SetPoint("TOPRIGHT", -MARGIN, -(f.titleBarHeight + OVERVIEW_H))

    f.scrollTop = f.titleBarHeight + OVERVIEW_H + 8 -- chrome above the scroll area

    local scroll = CreateFrame("ScrollFrame", "WhoDoesWhatMembersScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", MARGIN, -f.scrollTop)
    scroll:SetPoint("BOTTOMRIGHT", -(MARGIN + SCROLLBAR_W), MARGIN)
    -- Let the template drop the bar entirely while everything fits; the gutter
    -- stays reserved either way, so the columns don't shift when it appears.
    scroll.scrollBarHideable = true

    local scrollBar = _G[scroll:GetName() .. "ScrollBar"]
    f.scrollBar = scrollBar
    if scrollBar then
        -- AceGUI's textured slider backdrop, one frame level behind the native
        -- scrollbar so the template's arrows and thumb stay on top (same as the
        -- main view). It follows the bar in and out of view.
        local scrollTrack = CreateFrame("Frame", nil, scroll, "BackdropTemplate")
        scrollTrack:SetAllPoints(scrollBar)
        scrollTrack:SetFrameLevel(math.max(scroll:GetFrameLevel(),
            scrollBar:GetFrameLevel() - 1))
        scrollTrack:SetBackdrop({
            bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
            edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
            tile = true, tileSize = 8, edgeSize = 8,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f.scrollTrack = scrollTrack
    end

    local content = CreateFrame("Frame", nil, scroll)
    -- Pin the scroll child explicitly or nothing renders until the window
    -- moves (same fix as the main view).
    content:SetPoint("TOPLEFT")
    content:SetWidth(CONTENT_W)
    scroll:SetScrollChild(content)
    f.content = content
    f.scroll = scroll

    WhoDoesWhat:LogUiBuilding("Building members content.")

    f.sections = {}
    local prevBox
    for _, section in ipairs(SECTIONS) do
        local box = CreateFrame("Frame", nil, content)
        box:SetFrameLevel(content:GetFrameLevel() + 1)
        box:SetWidth(CONTENT_W)
        if prevBox then
            box:SetPoint("TOPLEFT", prevBox, "BOTTOMLEFT", 0, -GRID_GAP)
        else
            box:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        end
        prevBox = box

        local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 4, -4)
        title:SetText(SectionHeaderText(section, 0))

        -- Column headings on their own line under the bucket title, each lined
        -- up with its column's content: the class icon, the WDW tick, the
        -- dropdowns' own text inset, and the first talent icon.
        local function Heading(text, x, w, justify)
            local fs = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetPoint("TOPLEFT", x, -GRID_HEADINGS_Y)
            fs:SetWidth(w)
            fs:SetJustifyH(justify or "LEFT")
            fs:SetText(text)
        end
        Heading("Player", ICON_X, NAME_W + CLASS_ICON_SIZE)
        Heading("Has WDW?", ADDON_X, ADDON_COL_W, "CENTER")
        Heading("Group role", GROUP_X + 8, GROUP_DD_W)
        Heading("WhoDoesWhat", WDW_X + 8, WDW_DD_W)
        Heading("Talents", TALENT_X + TALENT_PAD, TALENT_TEXT_W)

        local line = box:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(0.4, 0.4, 0.4, 0.6)
        line:SetHeight(1)
        line:SetPoint("TOPLEFT", 0, -(GRID_HEADER_H - 1))
        line:SetPoint("TOPRIGHT", 0, -(GRID_HEADER_H - 1))

        f.sections[section.key] = { box = box, title = title, rows = {} }
    end

    -- Track joins/leaves live while the window is open.
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:RegisterEvent("UNIT_CONNECTION")
    f:SetScript("OnEvent", function(self)
        if self:IsShown() then
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
            if membersFrame and membersFrame:IsShown() then
                RefreshRoster(membersFrame)
            end
        end)
    end

    membersFrame = f
    return f
end

-- Repaint if the window is up. Called from outside the view when assignments
-- change (SetAssignedRole in UnitMenuExtensions.lua, talent auto-detection).
function WhoDoesWhat:RefreshMembersView()
    if membersFrame and membersFrame:IsShown() then
        RefreshRoster(membersFrame)
    end
end

-- Toggle the members window open/closed.
function WhoDoesWhat:OpenMembersView()
    local f = EnsureMembersFrame()

    if f:IsShown() then
        self:LogUiBuilding("Members View open, closing it.")
        f:Hide()
        return
    end

    self:LogUiBuilding("Opening Members View...")
    RefreshRoster(f)
    f:Show()
    f:Raise()
end
