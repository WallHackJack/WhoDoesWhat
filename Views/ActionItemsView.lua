local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- "Action Items" window: things worth tidying before a pull. Two sections, in
-- the order you can act on them:
--
--   * MAIN TANKS -- WDW tanks who haven't been promoted to Main Tank. Read-only:
--     promoting is a protected action an addon can't perform, so there is
--     nothing to pick here and it gets its own block rather than sitting in a
--     grid of dropdowns that don't apply to it.
--   * OUT-DATED ROLES -- one row per player whose group role and WDW role need
--     attention. Both middle columns ARE dropdowns: pick on the left to write
--     their Blizzard group flag, pick on the right to set their WhoDoesWhat role
--     (which pushes the flag to match). The last column is EVIDENCE, not a
--     control: the spec their talents read as, with the point spread on hover
--     and a Rescan button at the row's right edge to go and look again.
--
-- All three columns state the same fact -- what this player does -- so all three
-- are stated the same way, as a role icon and a role name, and each ends in a
-- gutter carrying a warning icon when it disagrees with either of the others.
-- Reading down the (!) column is how you find the row's actual argument; the
-- tooltip on each names who it is arguing with. See RowDisagreements.
--
-- There is deliberately no "fix" here -- neither per row nor a Fix All. Both
-- applied a guess derived from Blizzard's flag, which is the least trustworthy
-- thing on the row: Blizzard drops every new raider on DAMAGER, so "fix" mostly
-- meant writing that guess onto the board in bulk. Talents are the real
-- evidence, so the column offers them and lets you pick from the dropdown.
--
-- Rows wear the class tinting and spec/class icon of the Members window, since
-- they are the same thing -- a roster line you change a role on.
--
-- Opened by hand from the main window's toolbar -- nothing here pops up on its
-- own; the toolbar button glows instead.
--
-- What earns a player a row -- and the lists themselves -- is ActionItems.lua.
-- It used to sit at the top of this file, justified as "used by nothing else";
-- that stopped being true once the main window's toolbar button and the WDW
-- Status row started reading the count, so it is a model now and lives with the
-- other models.

local K = WhoDoesWhat.SectionKit

local actionsFrame = nil
local RenderRows

local FRAME_MAX_H = 500
-- Floor for the populated window. Sizing exactly to the rows left the scroll
-- viewport the same height as its content, which is a rounding error away from
-- "content overflows" -- so a two-row list could grow a scrollbar with nothing
-- to scroll. The slack also stops a short list rendering as a cramped sliver.
local FRAME_MIN_H = 300
local COMPACT_W = 320
local COMPACT_H = 96        -- the frame's build size; SetCompact measures the real one
local EMPTY_TITLE_H = 26
local EMPTY_BULLET_H = 17
local READY_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"
-- The questions the window actually asks, in the order its sections do.
local EMPTY_BULLETS = {
    "Main Tanks Promoted",
    "All Roles assigned",
    "All Roles Match",
    "All Roles Match Talents",
}
local MARGIN = 10
local TOP_PAD = 18          -- breathing room under the title bar
-- Section chrome copied from the Members window: a GameFontNormal title with
-- the small column headings under it, and a hairline below both.
local HEADER_H = 26
local HEADER_RULE_Y = 25
-- A section that has columns gets a second line: the title keeps the first row
-- to itself and the column headings sit under it, so "Out-dated Roles:" reads
-- as the section's name rather than as the first column's heading.
local COLUMN_HEADER_H = 44
local COLUMN_HEADINGS_Y = 24
local SECTION_GAP = 12
local ROW_H = 30
local PROMOTE_ROW_H = 26
local SCROLLBAR_W = 26

local NAME_COL_W = 134
local GROUP_DD_W = 128
local WDW_DD_W = 170
-- Every one of the three role columns OPENS with a gutter for its warning icon.
-- On the right the icon read as belonging to the column it was trailing rather
-- than the one it was flagging; leading it, the (!) and the entry it doubts
-- read as one thing.
local WARN_W = 20
-- The talents column: the role the spread reads as, icon and name, exactly like
-- the other two columns state a role. The point spread itself moved into the
-- hover tooltip -- "0/47/14" is evidence you consult, not a label you scan a
-- list by. Rescan is pinned to the row's right edge, out of the column's flow.
local TALENT_TEXT_W = 150
local TALENT_PAD = 6
local RESCAN_BTN_W = 66
local TALENT_COL_W = TALENT_PAD + TALENT_TEXT_W + 8 + RESCAN_BTN_W + 4

local GROUP_WARN_X = NAME_COL_W
local GROUP_X = GROUP_WARN_X + WARN_W
local WDW_WARN_X = GROUP_X + GROUP_DD_W
local WDW_X = WDW_WARN_X + WARN_W
local TALENT_WARN_X = WDW_X + WDW_DD_W
local TALENT_X = TALENT_WARN_X + WARN_W
local CONTENT_W = TALENT_X + TALENT_COL_W
local CLASS_ICON_SIZE = 20
local FRAME_W = CONTENT_W + MARGIN * 2 + SCROLLBAR_W

-- UIDropDownMenuTemplate's visible box starts inset from the frame's own left
-- edge, so every anchor below backs off by this much to line the box up with
-- the column it belongs to.
local DD_INSET = 15

-- What earns a row, and both lists themselves, live in ActionItems.lua. These
-- two are shared with it: the dropdown ticks the group role the model compared
-- against, and the promote rows name a class by token.
local BLIZZ_TO_WOW = WhoDoesWhat.BLIZZ_ROLE_TO_WOW_ROLE
local ClassInfoForToken = WhoDoesWhat.Assign.GetClassInfoByToken

local GROUP_ROLE_ORDER = { "tank", "healer", "dps" }

-- ---------------------------------------------------------------------------
-- View
-- ---------------------------------------------------------------------------

local function GroupRoleText(blizzRole)
    if not blizzRole then return "|cff909090none|r" end
    local wowRole = BLIZZ_TO_WOW[blizzRole]
    local meta = wowRole and WhoDoesWhat.BasicWowRoles[wowRole]
    if not meta then return "|cff909090none|r" end
    return WhoDoesWhat:GetWowRoleIconMarkup(wowRole, 14) .. " " .. meta.name
end

local function RoleText(role, classInfo)
    if not role then return "|cff909090none|r" end
    return WhoDoesWhat:RoleIconMarkup(role.icon, 14) .. " |cff"
        .. (classInfo and classInfo.colorHex or "ffffff") .. role.name .. "|r"
end

-- ---------------------------------------------------------------------------
-- Agreement between the row's three answers
--
-- The row states the same fact three times -- Blizzard's flag, the board, and
-- the last talent scan -- and the point of the window is the places they
-- disagree. The three are compared pairwise, and the warning goes on the ODD
-- ONE OUT: a resto shaman the board and his talents both call Restoration,
-- flagged DAMAGER, has one thing wrong with him, and marking all three columns
-- makes the reader do the elimination the row already did.
--
-- The rule is a plain majority. Each column counts how many of the others it
-- agrees with; anything below the best score, and in a disagreement, gets the
-- icon. Two answers that disagree with nothing else to break the tie flag BOTH
-- -- there genuinely is no odd one out -- and so does a three-way split, where
-- nobody scores an agreement at all.
--
-- Only answers we actually have take part. A player nobody has inspected, or a
-- flag Blizzard never set, is unknown rather than wrong -- the column already
-- reads "none" / "not scanned", and a warning on top of it would fire on most
-- of the list the moment a raid forms. So does a pair that can't be compared:
-- the group flag only ever names tank/healer/dps, so it is compared at that
-- coarseness, and a role the points can't name (warlock_firetank, custom roles)
-- can't be argued with by the scan in either direction.
-- ---------------------------------------------------------------------------

local function WowRoleName(wowRole)
    local meta = wowRole and WhoDoesWhat.BasicWowRoles[wowRole]
    return meta and meta.name or nil
end

-- The three comparisons, in the order the counts below walk them.
local COMPARISONS = {
    { "group", "wdw" }, { "group", "talent" }, { "wdw", "talent" },
}

local function Reason(others, agreed, best, lead)
    if #others == 0 then return nil end
    -- Outvoted, or nothing to be outvoted by.
    if best > 0 and agreed >= best then return nil end
    return lead .. table.concat(others, " and ") .. "."
end

-- Reason strings for the three columns, nil where that column is right, alone,
-- or unknown.
local function RowDisagreements(data, talentRoles)
    local groupWow = data.blizzRole and BLIZZ_TO_WOW[data.blizzRole] or nil
    local wdwWow = data.role and data.role.wowRole or nil
    local haveTalents = #talentRoles > 0

    local talentMatchesGroup, talentMatchesWdw = false, false
    local talentNames = {}
    for _, role in ipairs(talentRoles) do
        if role.wowRole == groupWow then talentMatchesGroup = true end
        if role.id == data.roleId then talentMatchesWdw = true end
        talentNames[#talentNames + 1] = role.name
    end
    local talentName = table.concat(talentNames, " / ")

    -- Can the scan judge the role on the board at all? Where it can't, it must
    -- not argue with the flag either -- a Fire Tank warlock's points read as
    -- destro DPS forever, and blaming his TANK flag for that is a warning that
    -- can never be cleared.
    local judgeable = WhoDoesWhat:TalentsCanJudgeRole(data.roleId)
    local comparable = {
        (groupWow and wdwWow) and true or false,
        (groupWow and haveTalents and (not data.roleId or judgeable)) and true or false,
        (haveTalents and judgeable) and true or false,
    }
    local agrees = {
        groupWow == wdwWow,
        talentMatchesGroup,
        talentMatchesWdw,
    }

    local describes = {
        group = "their group role (" .. (WowRoleName(groupWow) or "none") .. ")",
        wdw = "the WhoDoesWhat role (" .. (data.role and data.role.name or "none") .. ")",
        talent = "their talents (" .. talentName .. ")",
    }
    local agreed = { group = 0, wdw = 0, talent = 0 }
    local against = { group = {}, wdw = {}, talent = {} }
    for i = 1, #COMPARISONS do
        if comparable[i] then
            local a, b = COMPARISONS[i][1], COMPARISONS[i][2]
            if agrees[i] then
                agreed[a] = agreed[a] + 1
                agreed[b] = agreed[b] + 1
            else
                against[a][#against[a] + 1] = describes[b]
                against[b][#against[b] + 1] = describes[a]
            end
        end
    end

    local best = math.max(agreed.group, agreed.wdw, agreed.talent)
    return Reason(against.group, agreed.group, best,
            "Group role (" .. (WowRoleName(groupWow) or "none")
                .. ") disagrees with "),
        Reason(against.wdw, agreed.wdw, best,
            "WhoDoesWhat role (" .. (data.role and data.role.name or "none")
                .. ") disagrees with "),
        Reason(against.talent, agreed.talent, best,
            "Talents read as " .. talentName .. ", which disagrees with ")
end

-- Whether the local player may write each half of a row. Your own role is
-- always yours, permissions or not (Permissions.lua), so an unpermitted raider
-- still gets working controls on their own row.
--
-- These decide whether a column is a CONTROL or plain text. Permission is a
-- standing fact about the raid: a dropdown that can only ever answer "no" is
-- worse than no dropdown, so an unpermitted client reads the column instead.
-- Combat is not the same thing -- it passes -- so it leaves the controls in
-- place and merely disables them, with the reason in the tooltip. Rescan is
-- outside all of this: looking at someone's talents changes nothing and needs
-- no rights.
local function MayEditRole(data)
    return WhoDoesWhat:CanEditRoleOf(data.name)
end

-- Writing another member's Blizzard flag needs BOTH: the WoW rank that lets
-- the server accept it at all (raid assist / party lead), and our single-writer
-- election on top, so ten assistants don't all set flags at once. Your own is
-- always yours.
--
-- The rank half is stated here rather than left to the election because the two
-- can disagree loudly: board permissions read wide open when the raid leader
-- has no WhoDoesWhat, which is precisely when a plain raider looks permitted
-- and can still change nobody's flag.
local function MayEditGroupRole(data)
    if UnitIsUnit(data.unit, "player") then return true end
    return WhoDoesWhat:PlayerCanSetGroupRoles(UnitName("player"))
        and WhoDoesWhat:CanSetOthersBlizzardRole()
end

local COMBAT_REASON = "Can't change roles in combat."

-- Write the group flag straight, without touching the WDW board -- the opposite
-- direction from the WhoDoesWhat dropdown, which writes the board and lets
-- SyncBlizzardRoleState push the flag. This is the one you want when the board
-- is right and Blizzard's flag is what drifted.
--
-- Deliberately NOT gated on ManagesBlizzardRoles(): that switch stops WDW
-- writing flags on its own initiative. A person picking a group role out of a
-- dropdown IS the initiative.
local function SetGroupRole(data, wowRole)
    local meta = WhoDoesWhat.BasicWowRoles[wowRole]
    if not (meta and UnitSetRole) then return end
    if InCombatLockdown() then return end
    -- Writing another member's flag takes the single-writer election (Core.lua);
    -- your own is always yours. Without this UnitSetRole silently no-ops.
    if not (UnitIsUnit(data.unit, "player")
        or WhoDoesWhat:CanSetOthersBlizzardRole()) then
        return
    end
    UnitSetRole(data.unit, meta.blizzRole)
    -- The auto-sync path latches the last role id it wrote for this player to
    -- break write loops. A hand-picked flag makes that latch stale evidence.
    WhoDoesWhat:ClearRoleWriteLatch(data.name)
end

local function ShowWarning(warn, reason)
    warn.tooltipText = reason
    warn:SetShown(reason ~= nil)
end

local function SetDropdownEnabled(dd, enabled)
    if enabled then
        UIDropDownMenu_EnableDropDown(dd)
    else
        UIDropDownMenu_DisableDropDown(dd)
    end
end

-- ---------------------------------------------------------------------------
-- Main-tank rows (read-only)
-- ---------------------------------------------------------------------------

-- Who could actually promote this tank. Rank 2 is the leader, 1 an assistant;
-- both may call SetPartyAssignment, and nobody else can.
local function RaidPromoters()
    local promoters = {}
    for i = 1, GetNumGroupMembers() do
        local name, rank, _, _, _, classToken = GetRaidRosterInfo(i)
        if name and rank and rank >= 1 then
            promoters[#promoters + 1] = {
                name = name,
                rank = rank,
                classInfo = ClassInfoForToken(classToken),
            }
        end
    end
    table.sort(promoters, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end -- leader first
        return a.name < b.name
    end)
    return promoters
end

-- The key that opens Blizzard's social/raid panel, rendered the way the game's
-- own tips do it: yellow, in brackets. Read at paint time -- a keybinding can
-- change under an open window -- and simply omitted when unbound. The raid tab
-- has had its own binding name on some builds and not others, so try that
-- first and fall back to the socials panel it lives in.
local RAID_PANEL_BINDINGS = { "TOGGLERAIDTAB", "TOGGLESOCIAL" }

local function RaidPanelKeyMarkup()
    if not GetBindingKey then return nil end
    for _, binding in ipairs(RAID_PANEL_BINDINGS) do
        local key = GetBindingKey(binding)
        if key and key ~= "" then
            local shown = GetBindingText and GetBindingText(key, "KEY_") or key
            return " |cffffd100[" .. shown .. "]|r"
        end
    end
    return nil
end

local function CreatePromoteRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(PROMOTE_ROW_H)

    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    row.stripe = stripe

    local mark = row:CreateTexture(nil, "ARTWORK")
    mark:SetSize(14, 14)
    mark:SetPoint("LEFT", 7, 0)
    mark:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_7")

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", 27, 0)
    text:SetJustifyH("LEFT")
    row.text = text

    -- The hint needs a frame of its own: a FontString can't take OnEnter, and
    -- the whole row shouldn't own the tooltip -- only this half of it is about
    -- who may promote.
    local hintBox = CreateFrame("Frame", nil, row)
    hintBox:SetPoint("RIGHT", -8, 0)
    hintBox:SetHeight(PROMOTE_ROW_H)
    hintBox:EnableMouse(true)
    local hint = hintBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("RIGHT")
    hint:SetJustifyH("RIGHT")
    hint:SetTextColor(0.6, 0.6, 0.6)
    hintBox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Promoting is protected", 1, 1, 1)
        GameTooltip:AddLine("SetPartyAssignment is a Blizzard-UI-only action, "
            .. "so no addon can promote a Main Tank for you.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(" ")
        local promoters = RaidPromoters()
        if #promoters == 0 then
            GameTooltip:AddLine("Nobody in this raid can promote right now.",
                1, 0.4, 0.4, true)
        end
        for _, promoter in ipairs(promoters) do
            GameTooltip:AddDoubleLine(
                promoter.rank == 2 and "Leader" or "Assistant",
                "|cff" .. ((promoter.classInfo and promoter.classInfo.colorHex)
                    or "ffffff") .. (promoter.name:match("^[^-]+")
                    or promoter.name) .. "|r",
                1, 0.82, 0, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    hintBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.hintBox = hintBox
    row.hint = hint

    text:SetPoint("RIGHT", hintBox, "LEFT", -8, 0)

    parent.promoteRows[index] = row
    return row
end

-- The class tint the Members window uses, alternating between the class's two
-- shades so consecutive rows of one class stay separable.
local function StripeColor(stripe, classInfo, index)
    local colors = classInfo.gridRowColors
    local color = colors[index % 2 == 1 and 1 or 2]
    stripe:SetColorTexture(color.r, color.g, color.b, color.a)
end

local function LayoutPromoteRow(row, data, index)
    StripeColor(row.stripe, data.classInfo, index)
    -- Name in class colour, the statement itself in plain white: it's the row's
    -- point, not an aside.
    row.text:SetText("|cff" .. data.classInfo.colorHex
        .. (data.name:match("^[^-]+") or data.name) .. "|r"
        .. " isn't promoted to Main Tank")

    -- An assistant is told where to do it; everyone else is told who to ask,
    -- and the tooltip names them.
    if WhoDoesWhat:IsRaidAssistant() then
        row.hint:SetText("Promote in the raid UI"
            .. (RaidPanelKeyMarkup() or ""))
    else
        row.hint:SetText("Ask a raid assistant to fix it.")
    end
    row.hintBox:SetWidth(math.max(1, row.hint:GetStringWidth() + 2))
    row:Show()
end

-- ---------------------------------------------------------------------------
-- Role rows
-- ---------------------------------------------------------------------------

local function CreateRow(content, index)
    local row = CreateFrame("Frame", nil, content)
    row:SetHeight(ROW_H)

    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    row.stripe = stripe

    local classIcon = row:CreateTexture(nil, "ARTWORK")
    classIcon:SetSize(CLASS_ICON_SIZE, CLASS_ICON_SIZE)
    classIcon:SetPoint("LEFT", 4, 0)
    row.classIcon = classIcon

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("LEFT", classIcon, "RIGHT", 6, 0)
    name:SetWidth(NAME_COL_W - CLASS_ICON_SIZE - 14)
    name:SetJustifyH("LEFT")
    row.name = name

    -- Group role: writes Blizzard's flag directly.
    local groupDD = CreateFrame("Frame", "WhoDoesWhatActionItemsGroupDD" .. index,
        row, "UIDropDownMenuTemplate")
    groupDD:SetPoint("LEFT", row, "LEFT", GROUP_X - DD_INSET, -2)
    UIDropDownMenu_SetWidth(groupDD, GROUP_DD_W - 30)
    K.LeftAlignDropdown(groupDD)
    UIDropDownMenu_Initialize(groupDD, function(_, level)
        local data = row.data
        if not data then return end
        for _, wowRole in ipairs(GROUP_ROLE_ORDER) do
            local meta = WhoDoesWhat.BasicWowRoles[wowRole]
            local info = UIDropDownMenu_CreateInfo()
            info.text = WhoDoesWhat:GetWowRoleIconMarkup(wowRole, 14) .. " " .. meta.name
            info.checked = data.blizzRole and BLIZZ_TO_WOW[data.blizzRole] == wowRole
            info.func = function()
                SetGroupRole(data, wowRole)
                RenderRows(row.ownerFrame)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    groupDD:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Group role", 1, 1, 1)
        GameTooltip:AddLine("Blizzard's own Tank / Healer / Damage flag. "
            .. "Picking here changes only the flag.", 0.8, 0.8, 0.8, true)
        if self.blockedReason then
            GameTooltip:AddLine(self.blockedReason, 1, 0.4, 0.4, true)
        end
        GameTooltip:Show()
    end)
    groupDD:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.groupDD = groupDD

    -- Read-only stand-in for the column above, shown instead of the dropdown
    -- when this client may never write it. Sits where the dropdown's own label
    -- does so the column doesn't shift between rows.
    local groupText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    groupText:SetPoint("LEFT", row, "LEFT", GROUP_X + 8, 0)
    groupText:SetWidth(GROUP_DD_W - 12)
    groupText:SetJustifyH("LEFT")
    row.groupText = groupText

    local groupWarn = K.CreateWarningIcon(row)
    groupWarn:SetPoint("LEFT", row, "LEFT", GROUP_WARN_X, 0)
    row.groupWarn = groupWarn

    -- WhoDoesWhat role: writes the board, which pushes the flag to match.
    local wdwDD = CreateFrame("Frame", "WhoDoesWhatActionItemsWdwDD" .. index,
        row, "UIDropDownMenuTemplate")
    wdwDD:SetPoint("LEFT", row, "LEFT", WDW_X - DD_INSET, -2)
    UIDropDownMenu_SetWidth(wdwDD, WDW_DD_W - 30)
    K.LeftAlignDropdown(wdwDD)
    UIDropDownMenu_Initialize(wdwDD, function(_, level)
        local data = row.data
        if not (data and data.classInfo) then return end
        local function AddRole(role, classInfo)
            local info = UIDropDownMenu_CreateInfo()
            info.text = RoleText(role, classInfo)
            info.checked = data.roleId == role.id
            info.func = function()
                WhoDoesWhat:SetAssignedRole(data.name, role.id, data.unit)
                RenderRows(row.ownerFrame)
            end
            UIDropDownMenu_AddButton(info, level)
        end
        for _, role in ipairs(data.classInfo.roles) do
            AddRole(role, data.classInfo)
        end
        for _, role in ipairs(data.classInfo.customRoles or {}) do -- published + library
            AddRole(role, data.classInfo)
        end
    end)
    wdwDD:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("WhoDoesWhat role", 1, 1, 1)
        GameTooltip:AddLine("Sets their spec on the board and pushes their "
            .. "group role to match.", 0.8, 0.8, 0.8, true)
        if self.blockedReason then
            GameTooltip:AddLine(self.blockedReason, 1, 0.4, 0.4, true)
        end
        GameTooltip:Show()
    end)
    wdwDD:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.wdwDD = wdwDD

    local wdwText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    wdwText:SetPoint("LEFT", row, "LEFT", WDW_X + 8, 0)
    wdwText:SetWidth(WDW_DD_W - 12)
    wdwText:SetJustifyH("LEFT")
    row.wdwText = wdwText

    local wdwWarn = K.CreateWarningIcon(row)
    wdwWarn:SetPoint("LEFT", row, "LEFT", WDW_WARN_X, 0)
    row.wdwWarn = wdwWarn

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
    -- over the column. LayoutRow hands it the snapshot to render.
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

    local talentWarn = K.CreateWarningIcon(row)
    talentWarn:SetPoint("LEFT", row, "LEFT", TALENT_WARN_X, 0)
    row.talentWarn = talentWarn

    -- Go and look again. Not a fix and not gated on permissions -- an inspect
    -- writes nothing to anyone's board, it just refreshes the evidence the rest
    -- of the row is judged against.
    local rescanBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    rescanBtn:SetSize(RESCAN_BTN_W, ROW_H - 8)
    rescanBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    rescanBtn:SetText("Rescan")
    rescanBtn:SetMotionScriptsWhileDisabled(true)
    rescanBtn:SetScript("OnClick", function()
        local data = row.data
        if not data then return end
        WhoDoesWhat:RescanPlayerTalents(data.unit, data.name)
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

    content.rows[index] = row
    return row
end

local function LayoutRow(row, data, index, ownerFrame)
    row.data = data
    row.ownerFrame = ownerFrame

    row.name:SetText("|cff" .. data.classInfo.colorHex
        .. (data.name:match("^[^-]+") or data.name) .. "|r")
    -- Their spec's icon once they have one; the class icon while they don't --
    -- same fallback the Members window uses.
    WhoDoesWhat:SetRoleIconTexture(row.classIcon,
        (data.role and data.role.icon) or data.classInfo.classIcon)
    StripeColor(row.stripe, data.classInfo, index)

    local combat = InCombatLockdown()
    local reason = combat and COMBAT_REASON or nil

    local mayGroup = MayEditGroupRole(data)
    row.groupDD:SetShown(mayGroup)
    row.groupText:SetShown(not mayGroup)
    if mayGroup then
        UIDropDownMenu_SetSelectedValue(row.groupDD, data.blizzRole)
        UIDropDownMenu_SetText(row.groupDD, GroupRoleText(data.blizzRole))
        row.groupDD.blockedReason = reason
        SetDropdownEnabled(row.groupDD, not combat)
    else
        row.groupText:SetText(GroupRoleText(data.blizzRole))
    end

    local mayRole = MayEditRole(data)
    row.wdwDD:SetShown(mayRole)
    row.wdwText:SetShown(not mayRole)
    if mayRole then
        UIDropDownMenu_SetSelectedValue(row.wdwDD, data.roleId)
        UIDropDownMenu_SetText(row.wdwDD, RoleText(data.role, data.classInfo))
        row.wdwDD.blockedReason = reason
        SetDropdownEnabled(row.wdwDD, not combat)
    else
        row.wdwText:SetText(RoleText(data.role, data.classInfo))
    end

    -- Talents, or a grey "not scanned yet" where none have been seen: an
    -- unknown spread has to read as unknown, not as a player with no points.
    -- The role(s) the points name are resolved once here -- the column shows
    -- them, and the warning icons below compare against them.
    --
    -- (FindRoleById returns two values, so the lookup can't hide behind an
    -- `and`: that truncates to one and the role -- the icon -- comes back nil.)
    local snapshot = WhoDoesWhat:GetTalentSnapshot(data.unit)
    local talentRoles = {}
    if snapshot and snapshot.roleIds then
        for _, roleId in ipairs(snapshot.roleIds) do
            local _, role = WhoDoesWhat:FindRoleById(roleId)
            if role then talentRoles[#talentRoles + 1] = role end
        end
    end

    local talentLabels, talentNames = {}, {}
    for _, role in ipairs(talentRoles) do
        talentLabels[#talentLabels + 1] = RoleText(role, data.classInfo)
        talentNames[#talentNames + 1] = role.name
    end
    row.talentText:SetText(
        (#talentLabels > 0 and table.concat(talentLabels, " / "))
        -- Points seen but no role behind them: a class/spec the table doesn't
        -- map (there is no such class today, but a bad spec index would land
        -- here). Fall back to the spread rather than claiming nothing is known.
        or (snapshot and table.concat(snapshot.points, "/"))
        or "|cff909090not scanned|r")
    row.talentHover.snapshot = snapshot
    row.talentHover.readsAs = #talentNames > 0
        and table.concat(talentNames, " or ") or nil

    local groupReason, wdwReason, talentReason = RowDisagreements(data, talentRoles)
    ShowWarning(row.groupWarn, groupReason)
    ShowWarning(row.wdwWarn, wdwReason)
    ShowWarning(row.talentWarn, talentReason)

    -- Already queued: the button has done its job and pressing it again just
    -- re-queues the same inspect, so it goes quiet until the answer lands or
    -- the request times out.
    local pendingScan = WhoDoesWhat:IsTalentRescanPending(data.name)
    row.rescanBtn:SetEnabled(not combat and not pendingScan)
    row.rescanBtn:SetText(pendingScan and "Queued" or "Rescan")
    row.rescanBtn.blockedReason = combat and "Can't inspect in combat."
        or (pendingScan and "Waiting for their talents to arrive." or nil)
    row:Show()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

-- Nothing to do: shrink to a checklist, the way the diffs window shrinks to a
-- label. A tall empty box with a scroll track in it reads as "broken", not as
-- "you're all set" -- and the ticked lines say which questions were actually
-- asked, which a bare "nothing to fix" leaves you guessing at.
--
-- Ungrouped keeps the small shape but drops the checklist: none of those
-- were checked, they were skipped, and claiming them would be a lie.
local function SetCompact(f, inGroup)
    f.promoteHeader:Hide()
    f.rolesHeader:Hide()
    f.scroll:Hide()
    for _, row in ipairs(f.promoteRows) do row:Hide() end

    local y = f.titleBarHeight + 16
    f.emptyTitle:ClearAllPoints()
    f.emptyTitle:SetPoint("TOP", f, "TOP", 0, -y)
    f.emptyTitle:SetWidth(COMPACT_W - MARGIN * 2)
    f.emptyTitle:SetText(inGroup
        and ("|T" .. READY_ICON .. ":18:18:0:0|t |cffffffffNothing to fix!|r")
        or "|cffffffffNot in a group.|r")
    f.emptyTitle:Show()
    y = y + EMPTY_TITLE_H
    for index, line in ipairs(f.emptyBullets) do
        line:ClearAllPoints()
        line:SetPoint("TOP", f, "TOP", 0, -(y + (index - 1) * EMPTY_BULLET_H))
        line:SetWidth(COMPACT_W - MARGIN * 2)
        line:SetShown(inGroup)
    end
    if inGroup then y = y + #f.emptyBullets * EMPTY_BULLET_H end
    f:SetSize(COMPACT_W, y + 14)
end

RenderRows = function(f)
    local rows, promotes = WhoDoesWhat:GetActionItems()

    if #rows == 0 and #promotes == 0 then
        SetCompact(f, IsInGroup())
        return false
    end

    f.emptyTitle:Hide()
    for _, line in ipairs(f.emptyBullets) do line:Hide() end

    local y = f.titleBarHeight + TOP_PAD

    -- Main tanks first: it's the section you can't act on from here, so it stays
    -- short and out of the way above the part you work down.
    if #promotes > 0 then
        f.promoteHeader:ClearAllPoints()
        f.promoteHeader:SetPoint("TOPLEFT", MARGIN, -y)
        f.promoteHeader:Show()
        y = y + HEADER_H
        for i, data in ipairs(promotes) do
            local row = f.promoteRows[i] or CreatePromoteRow(f, i)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", MARGIN, -y)
            row:SetPoint("RIGHT", f, "RIGHT", -MARGIN, 0)
            LayoutPromoteRow(row, data, i)
            y = y + PROMOTE_ROW_H
        end
        y = y + SECTION_GAP
    else
        f.promoteHeader:Hide()
    end
    for i = #promotes + 1, #f.promoteRows do f.promoteRows[i]:Hide() end

    -- An empty roles section is hidden entirely, the same way the main-tank one
    -- is: a lone header over a blank scroll box reads as something failing to
    -- load. Reaching here with no rows means the promotes are the whole list.
    local content = f.content
    f.rolesHeader:SetShown(#rows > 0)
    f.scroll:SetShown(#rows > 0)
    if #rows > 0 then
        f.rolesHeader:ClearAllPoints()
        f.rolesHeader:SetPoint("TOPLEFT", MARGIN, -y)
        y = y + COLUMN_HEADER_H

        f.scroll:ClearAllPoints()
        f.scroll:SetPoint("TOPLEFT", MARGIN, -y)
        f.scroll:SetPoint("BOTTOMRIGHT", -(MARGIN + SCROLLBAR_W), MARGIN)
    else
        -- Nothing below the promotes, so the bottom strip has nothing to hold
        -- either; trim the gap it would have left.
        y = y - SECTION_GAP
    end

    for i, data in ipairs(rows) do
        local row = content.rows[i] or CreateRow(content, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((i - 1) * ROW_H))
        row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        LayoutRow(row, data, i, f)
    end
    for i = #rows + 1, #content.rows do content.rows[i]:Hide() end

    local bodyHeight = #rows * ROW_H
    content:SetHeight(math.max(1, bodyHeight))
    if #rows > 0 then
        -- The floor only earns its keep while there IS a scroll box to give
        -- slack to.
        f:SetSize(FRAME_W, math.max(FRAME_MIN_H, math.min(FRAME_MAX_H,
            y + bodyHeight + MARGIN * 2)))
        -- After the resize, so the scrollbar decision sees the height it got.
        K.UpdatePaladinGridScroll(f.scroll, bodyHeight)
    else
        f:SetSize(FRAME_W, y + MARGIN)
    end
    return true
end

local function EnsureFrame()
    if actionsFrame then return actionsFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatActionItemsFrame",
        FRAME_W, COMPACT_H, "Action Items")
    f.titleText:ClearAllPoints()
    f.titleText:SetPoint("CENTER", f, "TOP", 0, -(f.titleBarHeight / 2 + 5))
    f.promoteRows = {}

    -- One frame per section header so the whole block -- title, column
    -- headings and hairline -- moves on a single anchor as the section above
    -- it comes and goes. Same chrome as the Members window's role grids.
    local function SectionHeader(titleText, withColumns)
        local header = CreateFrame("Frame", nil, f)
        local height = withColumns and COLUMN_HEADER_H or HEADER_H
        header:SetSize(CONTENT_W, height)
        local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 4, -4)
        title:SetJustifyH("LEFT")
        title:SetText(titleText)
        local ruleY = withColumns and (height - 1) or HEADER_RULE_Y
        local rule = header:CreateTexture(nil, "ARTWORK")
        rule:SetColorTexture(0.4, 0.4, 0.4, 0.6)
        rule:SetHeight(1)
        rule:SetPoint("TOPLEFT", 0, -ruleY)
        rule:SetPoint("TOPRIGHT", 0, -ruleY)
        -- Headings sit on their own line under the title and hug the left edge,
        -- matching the row contents below them -- every column's content is
        -- left-aligned, so a centred heading floated away from what it labels.
        header.Heading = function(_, text, x, w)
            local fs = header:CreateFontString(nil, "OVERLAY",
                "GameFontNormalSmall")
            fs:SetPoint("TOPLEFT", x, -COLUMN_HEADINGS_Y)
            fs:SetWidth(w)
            fs:SetJustifyH("LEFT")
            fs:SetText(text)
        end
        return header
    end
    f.promoteHeader = SectionHeader("Main Tanks:")
    f.rolesHeader = SectionHeader("Out-dated Roles:", true)
    -- Each heading lines up with its column's content: the class icon, the
    -- dropdowns' own text inset, and the first talent icon.
    f.rolesHeader:Heading("Player", 4, NAME_COL_W)
    f.rolesHeader:Heading("Group role", GROUP_X + 8, GROUP_DD_W)
    f.rolesHeader:Heading("WhoDoesWhat", WDW_X + 8, WDW_DD_W)
    f.rolesHeader:Heading("Talents", TALENT_X + TALENT_PAD, TALENT_TEXT_W)

    local scroll, content = K.CreatePaladinGridScroll(f,
        "WhoDoesWhatActionItemsScroll")
    content:SetWidth(CONTENT_W)
    content.rows = {}
    f.scroll = scroll
    f.content = content

    -- The all-clear panel. Built once and simply hidden while there is work;
    -- SetCompact positions it, since the frame it centres in is being resized
    -- around it at the same time.
    local emptyTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    emptyTitle:SetJustifyH("CENTER")
    f.emptyTitle = emptyTitle
    f.emptyBullets = {}
    for index, text in ipairs(EMPTY_BULLETS) do
        local line = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        line:SetJustifyH("CENTER")
        line:SetText("- " .. text)
        f.emptyBullets[index] = line
    end

    -- No Refresh button: every source that can change this list already
    -- repaints it -- GROUP_ROSTER_UPDATE below, and RefreshActionItemsView from
    -- Sync and SetAssignedRole -- so it was a button that could only ever
    -- redraw what was already on screen.

    -- Roles move under the window while it's open (talent scans, other clients'
    -- edits, promotions), so track the same events the other roster views do.
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:SetScript("OnEvent", function(self)
        if self:IsShown() then RenderRows(self) end
    end)

    actionsFrame = f
    return f
end

-- The status bars carry an Action Items row off the same count, so anything
-- that moves this list has to move that too -- the window itself is usually
-- shut when a role changes, and the bar is the surface that says so.
-- Repaint the Action Items window if it is up, and nothing else. The WDW
-- Status row that counts action items is repainted by RefreshBoardViews, which
-- calls both -- this used to nudge WDW Status itself, so every caller that also
-- touched the buff grid repainted it twice.
function WhoDoesWhat:RefreshActionItemsView()
    if actionsFrame and actionsFrame:IsShown() then RenderRows(actionsFrame) end
end

function WhoDoesWhat:OpenActionItemsView()
    local f = EnsureFrame()
    if f:IsShown() then
        f:Hide()
        return
    end
    RenderRows(f)
    self:LogUiBuilding("Opening Action Items...")
    f:Show()
    f:Raise()
end
