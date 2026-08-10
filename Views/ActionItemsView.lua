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
--     control: the spec their talents read as and the spread we've actually
--     seen, with a Rescan button at the row's right edge to go and look again.
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
-- Four things put a player in the roles list:
--   * MISMATCH: their group role and WDW role disagree.
--   * TALENT MISMATCH: their WDW role and their last-scanned talents disagree.
--     A first sighting deliberately loses to an existing assignment
--     (AutoAssignDetectedRole), so a role picked before anyone could inspect
--     them stays on the board until someone looks at this row. Only roles
--     talents can name count -- see TalentsContradictRole.
--   * UNSET: they have a WDW role but no group role at all. A kicked-and-
--     reinvited player lands here, since a kick clears the flag.
--   * PENDING: they have no WDW role yet -- not scanned, not assigned. Blizzard
--     drops every new raider on DAMAGER, so this is the bulk of the list when a
--     raid first forms, and it's the list you actually work down.
--
-- Solo is always empty. Outside a group Blizzard reports your own flag as NONE,
-- which would show you a permanent one-row "fix" for a flag that means nothing
-- until you're grouped.
--
-- The model lives at the top of this file rather than in Assignments.lua: it is
-- a few lines of comparison used by nothing else, and splitting it would cost
-- more than it explains.

local K = WhoDoesWhat.SectionKit

local actionsFrame = nil
local RenderRows

local FRAME_W = 660
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
-- The talents column, laid out left to right inside its own width: the spec
-- icon(s) the spread reads as, then the point spread itself. Rescan is pinned
-- to the row's right edge instead, out of the column's flow.
local TALENT_COL_W = 178
local TALENT_X = NAME_COL_W + GROUP_DD_W + WDW_DD_W
local TALENT_PAD = 6
local TALENT_ICON_SIZE = 16
local RESCAN_BTN_W = 66
local CONTENT_W = TALENT_X + TALENT_COL_W
local CLASS_ICON_SIZE = 20

-- UIDropDownMenuTemplate's visible box starts inset from the frame's own left
-- edge, so every anchor below backs off by this much to line the box up with
-- the column it belongs to.
local DD_INSET = 15

-- ---------------------------------------------------------------------------
-- Model
-- ---------------------------------------------------------------------------

local BLIZZ_TO_WOW = { TANK = "tank", HEALER = "healer", DAMAGER = "dps" }
local GROUP_ROLE_ORDER = { "tank", "healer", "dps" }

local function ClassInfoForToken(englishClass)
    if not englishClass then return nil end
    for _, classInfo in ipairs(WhoDoesWhat.Classes) do
        if classInfo.name:upper() == englishClass then return classInfo end
    end
    return nil
end

local function ClassInfoForUnit(unit)
    local _, englishClass = UnitClass(unit)
    return ClassInfoForToken(englishClass)
end

-- Both lists the window shows, roster order: role rows first, promote rows
-- second. See the header for what earns a row in each.
function WhoDoesWhat:GetActionItems()
    local roleRows, promoteRows = {}, {}
    if not (self.db and UnitGroupRolesAssigned) then return roleRows, promoteRows end
    if not IsInGroup() then return roleRows, promoteRows end
    local inRaid = IsInRaid()

    local units = {}
    if inRaid then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    else
        units[1] = "player"
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end

    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local name, realm = UnitName(unit)
            local key = (realm and realm ~= "") and (name .. "-" .. realm) or name
            local classInfo = ClassInfoForUnit(unit)
            local roleId = key and self.db.profile.assignments[key]
            local _, role = nil, nil
            if roleId then _, role = self:FindRoleById(roleId) end

            local blizzRole = UnitGroupRolesAssigned(unit)
            if blizzRole == "NONE" then blizzRole = nil end
            local wanted = role and role.wowRole or nil

            local mismatched = (wanted and blizzRole
                and BLIZZ_TO_WOW[blizzRole] ~= wanted) and true or false
            local unset = (wanted and not blizzRole) and true or false
            -- No WDW role at all: the scan hasn't reached them or nobody has
            -- assigned one. Not a disagreement -- a blank waiting to be filled.
            local pending = (not roleId) and true or false
            -- The board says one spec, their talents read as another. Roles
            -- that talents can't name are excluded (TalentsContradictRole), so
            -- a Warlock Tank never sits here unfixably.
            local talentMismatch = self:TalentsContradictRole(unit, roleId)

            if classInfo and (mismatched or unset or pending or talentMismatch) then
                roleRows[#roleRows + 1] = {
                    name = key,
                    unit = unit,
                    classInfo = classInfo,
                    blizzRole = blizzRole,
                    roleId = roleId,
                    role = role,
                    mismatched = mismatched,
                    unset = unset,
                    pending = pending,
                    talentMismatch = talentMismatch,
                }
            end

            if classInfo and inRaid and wanted == "tank"
                and not GetPartyAssignment("MAINTANK", key, true) then
                promoteRows[#promoteRows + 1] = {
                    name = key,
                    classInfo = classInfo,
                    role = role,
                }
            end
        end
    end
    return roleRows, promoteRows
end

-- What the toolbar button and the status row advertise: the total, plus how
-- many of them THIS client could actually do something about. Cheap enough to
-- call from every main-window refresh -- one pass over the roster with no frame
-- work -- and always agreeing with the window by construction.
--
-- The two numbers differ for an unpermitted raider, and that gap is the whole
-- point: they still get an honest count of what's outstanding, but nothing
-- glows or turns gold at them, because none of it is theirs to fix. Promotions
-- count for anyone who could actually promote -- leader or assistant, the same
-- rule the promote-watch arrow fires on.
function WhoDoesWhat:CountActionItems()
    local roleRows, promoteRows = self:GetActionItems()
    local actionable = 0
    for _, data in ipairs(roleRows) do
        if self:CanEditRoleOf(data.name) then actionable = actionable + 1 end
    end
    if self:CanPromoteMainTank() then
        actionable = actionable + #promoteRows
    end
    return #roleRows + #promoteRows, actionable
end

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
    groupDD:SetPoint("LEFT", row, "LEFT", NAME_COL_W - DD_INSET, -2)
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
    groupText:SetPoint("LEFT", row, "LEFT", NAME_COL_W + 8, 0)
    groupText:SetWidth(GROUP_DD_W - 12)
    groupText:SetJustifyH("LEFT")
    row.groupText = groupText

    -- WhoDoesWhat role: writes the board, which pushes the flag to match.
    local wdwDD = CreateFrame("Frame", "WhoDoesWhatActionItemsWdwDD" .. index,
        row, "UIDropDownMenuTemplate")
    wdwDD:SetPoint("LEFT", row, "LEFT", NAME_COL_W + GROUP_DD_W - DD_INSET, -2)
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
    wdwText:SetPoint("LEFT", row, "LEFT", NAME_COL_W + GROUP_DD_W + 8, 0)
    wdwText:SetWidth(WDW_DD_W - 12)
    wdwText:SetJustifyH("LEFT")
    row.wdwText = wdwText

    -- Talents: what we have actually seen, not what anyone picked. The icons
    -- lead -- the spec the spread reads as, two of them for a feral druid whose
    -- tree can't distinguish cat from bear -- and the point spread follows,
    -- reading left to right in talent-tab order.
    row.talentIcons = {}
    for i = 1, 2 do
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(TALENT_ICON_SIZE, TALENT_ICON_SIZE)
        icon:SetPoint("LEFT", row, "LEFT",
            TALENT_X + TALENT_PAD + (i - 1) * (TALENT_ICON_SIZE + 2), 0)
        row.talentIcons[i] = icon
    end

    local talentText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    talentText:SetJustifyH("LEFT")
    row.talentText = talentText

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
    -- The spread starts after however many spec icons we drew, so a class the
    -- tree can only narrow to two keeps both icons and still reads as one
    -- left-aligned column.
    local snapshot = WhoDoesWhat:GetTalentSnapshot(data.unit)
    local shownIcons = 0
    for i, icon in ipairs(row.talentIcons) do
        local roleId = snapshot and snapshot.roleIds and snapshot.roleIds[i]
        local _, role = roleId and WhoDoesWhat:FindRoleById(roleId)
        if role then WhoDoesWhat:SetRoleIconTexture(icon, role.icon) end
        icon:SetShown(role ~= nil)
        if role then shownIcons = shownIcons + 1 end
    end

    local textX = TALENT_X + TALENT_PAD
        + shownIcons * (TALENT_ICON_SIZE + 2)
        + (shownIcons > 0 and 4 or 0)
    row.talentText:ClearAllPoints()
    row.talentText:SetPoint("LEFT", row, "LEFT", textX, 0)
    row.talentText:SetWidth(math.max(1,
        TALENT_X + TALENT_COL_W - RESCAN_BTN_W - 12 - textX))
    row.talentText:SetText(snapshot
        and table.concat(snapshot.points, "/")
        or "|cff909090not scanned|r")

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
    f.rolesHeader:Heading("Group role", NAME_COL_W + 8, GROUP_DD_W)
    f.rolesHeader:Heading("WhoDoesWhat", NAME_COL_W + GROUP_DD_W + 8, WDW_DD_W)
    f.rolesHeader:Heading("Talents", TALENT_X + TALENT_PAD, TALENT_COL_W)

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
function WhoDoesWhat:RefreshActionItemsView()
    if actionsFrame and actionsFrame:IsShown() then RenderRows(actionsFrame) end
    self:RefreshStatusBarsView()
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
