local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Injects a "WhoDoesWhat" section into the unit right-click menus via the
-- client's Menu API (same mechanism SetRoleButtons uses), inserted right
-- below the player-name title so it's the first thing in the menu:
--
--   WhoDoesWhat          (title)
--   Set Role >           (pop-out submenu, like the default menu's
--                         "Player vs. Player" in the base UI)
--     [radio rows: every WDW role for the clicked player's class,
--      spec icon + class-colored name, plus None]
--   ----------------
--
-- Selecting a role stores it in db.profile.assignments keyed by player name
-- ("Name" same-realm, "Name-Realm" foreign), so the radio state persists.
-- It also syncs the blizzard group state (see ApplyBlizzardRole): the unit's
-- tank/heal/dps role flag, and in a raid the MAINTANK assignment -- promoted
-- for tank roles, demoted for everything else.

-- Unit menu tags we extend. Tags a client build doesn't define are simply
-- never opened, so registering extras is harmless.
local MENU_TAGS = {
    "MENU_UNIT_SELF",
    "MENU_UNIT_PLAYER",
    "MENU_UNIT_TARGET",
    "MENU_UNIT_PARTY",
    "MENU_UNIT_RAID_PLAYER",
}

-- Our Classes entry for the unit's class, or nil (non-player units, unknown
-- class). Matched on the locale-independent english class token.
local function GetClassInfoForUnit(unit)
    local _, englishClass = UnitClass(unit)
    if not englishClass then return nil end
    for _, classInfo in ipairs(WhoDoesWhat.Classes) do
        if classInfo.name:upper() == englishClass then
            return classInfo
        end
    end
    return nil
end

-- Stable assignment key for a unit: "Name" for same-realm players,
-- "Name-Realm" for foreign ones.
local function GetUnitKey(unit)
    local name, realm = UnitName(unit)
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

-- ---------------------------------------------------------------------------
-- Assignment storage (db.profile.assignments: player name -> role id)
-- ---------------------------------------------------------------------------

function WhoDoesWhat:GetAssignedRole(playerName)
    return self.db.profile.assignments[playerName]
end

-- Send a message to the active group channel: RAID when in a raid, else
-- PARTY. No-op when solo, so callers never have to check group state.
function WhoDoesWhat:SendGroupMessage(msg)
    local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
    if channel then
        SendChatMessage(msg, channel)
    end
end

function WhoDoesWhat:LogRolePromotion(...)
    if self.db and self.db.profile.settings.logRolePromotion then
        self:Print("|cff80c0ffRole/promotion:|r", ...)
    end
end

-- The role id we last wrote a flag for, per player. Keying on the ROLE ID
-- rather than the blizz role means the latch invalidates itself the moment our
-- board's opinion of that player changes -- no hunting down every scattered
-- write site to clear it. See ApplyBlizzardRole's loop breaker.
local lastWritten = {}

function WhoDoesWhat:ClearRoleWriteLatch(playerName)
    if playerName then lastWritten[playerName] = nil else wipe(lastWritten) end
end

-- Sync blizzard group state to a WDW role. Two independent halves:
--   - the unit's tank/heal/dps group role flag (UnitSetRole). Needs a role
--     WITH a wowRole; roles without one (a legacy custom role saved before
--     they required a group role) leave the flag alone.
--   - in a raid, demote off MAINTANK when the player isn't a tank. This half
--     runs for ANY role INCLUDING nil -- "their role was cleared" and "their
--     role has no group role" both mean not-a-tank, and a main tank left
--     marked forever because we couldn't classify them is the worse failure.
-- We do NOT promote to MAINTANK: SetPartyAssignment is a protected action and
-- an addon calling it just trips the "only available to the Blizzard UI"
-- block. Demotion (ClearPartyAssignment) isn't protected, so that half stays.
-- The player-name + exactMatch args mirror Blizzard's own Set Main Tank button.
-- `role` may be nil (assignment cleared).
--
-- Only ever reached from something the user just did on THIS client: a role
-- picked in a menu or the main window, or re-enabling the Settings toggle.
-- Nothing schedules, sweeps or syncs its way here any more.
local function ApplyBlizzardRole(unit, playerName, role)
    -- Master opt-out (Settings > General). WDW keeps its own board either way;
    -- this only stops it writing Blizzard's.
    if not WhoDoesWhat:ManagesBlizzardRoles() then return end

    -- Writing another member's state takes the single-writer election (Core.lua
    -- BlizzardRoleWriter); your OWN role is always yours. Without this the
    -- UnitSetRole below silently no-ops on others while we act as though it
    -- took -- or, worse, several assists set it at once.
    local mayFlag = UnitIsUnit(unit, "player")
        or WhoDoesWhat:CanSetOthersBlizzardRole()
    local inCombat = InCombatLockdown()

    local meta = role and role.wowRole and WhoDoesWhat.BasicWowRoles[role.wowRole]
    if meta then
        -- Only touch the flag when it actually differs: UnitSetRole on an
        -- already-set role re-announces it to the group ("X is now Damage
        -- Dealer") and invites a tug-of-war with anything else managing flags.
        local before = mayFlag and UnitGroupRolesAssigned
            and UnitGroupRolesAssigned(unit)

        -- Loop breaker. If we already wrote this exact role id for this player
        -- and the flag now reads a DIFFERENT real role, someone else overrode
        -- us. Re-asserting is what turns a one-off disagreement into an endless
        -- ping-pong (our write fires GROUP_ROSTER_UPDATE on their client, their
        -- sweep re-writes, which fires ours...). Stand down; whoever wrote last
        -- keeps it, and the disagreement is a board problem to fix at the
        -- source. A flag reading NONE is not contested -- that's the
        -- kick/reinvite reset the roster sweep repairs -- so it re-applies
        -- freely. Only the flag stands down; the demotion below is unrelated
        -- and still runs.
        local contested = before and before ~= "NONE" and before ~= meta.blizzRole
        if contested and lastWritten[playerName] == role.id then
            WhoDoesWhat:LogRolePromotion("Blizzard role contested (stood down)",
                "player=" .. tostring(playerName),
                "ours=" .. tostring(meta.blizzRole),
                "theirs=" .. tostring(before))
        else
            local setResult
            -- UnitSetRole became protected for addon execution in combat in
            -- 2.5.6. Skip only that call; PLAYER_REGEN_ENABLED reconciles after.
            if not inCombat and mayFlag and UnitSetRole and UnitGroupRolesAssigned
                and before ~= meta.blizzRole then
                setResult = UnitSetRole(unit, meta.blizzRole)
                lastWritten[playerName] = role.id
            end
            if before ~= meta.blizzRole then
                WhoDoesWhat:LogRolePromotion("Blizzard role",
                    "player=" .. tostring(playerName),
                    "unit=" .. tostring(unit),
                    "combat=" .. tostring(inCombat),
                    "mayFlag=" .. tostring(mayFlag),
                    "before=" .. tostring(before),
                    "desired=" .. tostring(meta.blizzRole),
                    "attempted=" .. tostring(setResult ~= nil),
                    "result=" .. tostring(setResult),
                    "after=" .. tostring(setResult ~= nil
                        and UnitGroupRolesAssigned(unit) or before))
            end
        end
    end

    -- Main-tank demotion, deliberately NOT in combat. ClearPartyAssignment is
    -- callable mid-fight, but re-promoting is not: SetPartyAssignment is
    -- protected, so it costs the leader the Raid tab, a right-click and a menu
    -- -- during the pull. Fights that swap someone tank->dps->tank would pay
    -- that every time, so the mark is held for the duration.
    -- Nothing retries afterwards now that the automatic sweeps are gone: a
    -- demotion missed to combat waits for the next time you set that player's
    -- role, or for a Fix in Action Items.
    if not inCombat and mayFlag and IsInRaid()
        and not (role and role.wowRole == "tank")
        and GetPartyAssignment("MAINTANK", playerName, true) then
        WhoDoesWhat:LogRolePromotion("Main-tank demote",
            "player=" .. tostring(playerName),
            "wowRole=" .. tostring(role and role.wowRole or "none"))
        ClearPartyAssignment("MAINTANK", playerName, true)
    end
end

-- Full blizzard-side sync for a role assignment: the role flag / main-tank
-- demotion (ApplyBlizzardRole), plus -- since we can't promote to main tank
-- ourselves (protected) -- the promote-watch flow for tank roles: highlight
-- their row when the leader opens the Raid tab and clean up once promoted.
-- Skipped when they already are.
-- `unit` is optional: a group member's name is itself a valid unit for the
-- APIs involved, so callers without a token (talent auto-detection) omit it.
function WhoDoesWhat:SyncBlizzardRoleState(playerName, role, unit)
    ApplyBlizzardRole(unit or playerName, playerName, role)
    -- Only someone who could actually promote raises the arrow -- a plain
    -- raider can't promote anyone and doesn't want a useless pointer. That's
    -- every assistant, not just the flag-writer: promoting is a click a human
    -- makes in Blizzard's own UI, not a write we coordinate.
    local isTank = role and role.wowRole == "tank"
    local inRaid = IsInRaid()
    local authority = isTank and self:CanPromoteMainTank() or false
    local mainTank = authority and GetPartyAssignment("MAINTANK", playerName, true) or false
    self:LogRolePromotion("Promotion gate",
        "player=" .. tostring(playerName),
        "wowRole=" .. tostring(role and role.wowRole),
        "inRaid=" .. tostring(inRaid),
        "authority=" .. tostring(authority),
        "mainTank=" .. tostring(mainTank),
        "willPrompt=" .. tostring(isTank and inRaid and authority and not mainTank))
    if isTank and inRaid and authority and not mainTank then
        self:StartPromoteWatch(playerName)
    end
end

-- Push every group member's Blizzard role flag (and main-tank demotion) to
-- their stored WDW assignment in one pass, gated inside ApplyBlizzardRole on
-- CanSetOthersBlizzardRole so only the elected writer touches other people.
--
-- ON-DEMAND ONLY. This used to run automatically on a synced board, a member's
-- ROLE broadcast, every roster event and the end of combat, and every one of
-- those had the same defect: the flag change and the board change reach a
-- client by different routes at different speeds, so whoever swept first swept
-- with stale evidence and overwrote a player who had just set their own role.
-- Waiting first only delayed it. The remaining caller is the Settings toggle
-- being switched back on, which is a person asking for exactly this.
--
-- It no-ops on flags that already match (re-setting re-announces to the group
-- and fights other role addons) and never opens a frame (no promote-watch).
-- UnitSetRole is skipped in combat and is NOT retried afterwards.
function WhoDoesWhat:ReconcileBlizzardRoles()
    if not (UnitSetRole and UnitGroupRolesAssigned) then return end
    if not self:ManagesBlizzardRoles() then return end
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    else
        units[1] = "player"
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end
    for _, unit in ipairs(units) do
        local name = GetUnitKey(unit)
        if name then
            -- Deliberately unfiltered: members with no assignment, or one whose
            -- role carries no wowRole, still need the main-tank demotion pass.
            -- Filtering them out here is what used to leave a main tank marked
            -- forever after being switched to a wowRole-less custom role or
            -- having their role cleared. ApplyBlizzardRole no-ops the flag half
            -- for them and handles the demotion half regardless.
            local roleId = self.db.profile.assignments[name]
            local _, role = nil, nil
            if roleId then _, role = self:FindRoleById(roleId) end
            ApplyBlizzardRole(unit, name, role)
        end
    end
end

-- Assign a role to a player (roleId = nil clears the assignment) and sync
-- the blizzard role/main-tank state to match. Your own role is always yours;
-- anyone else's takes board edit permission (Permissions.lua).
function WhoDoesWhat:SetAssignedRole(playerName, roleId, unit)
    if playerName ~= UnitName("player") and not self:RequireEditPermission() then
        return
    end
    -- A custom role is only half a shared assignment until its definition is on
    -- the board, so assigning one in a group publishes it. Refused rather than
    -- assigned when it can't be -- an id nobody else can resolve is worse than
    -- no assignment at all. See EnsureRoleIsShareable in Data.lua.
    if not self:EnsureRoleIsShareable(roleId) then return end
    -- Re-selecting the already-assigned role skips the print/announce, but
    -- still syncs blizzard state below: the group flag can drift (set by
    -- someone else, lost on reload), and re-picking a main tank's non-tank
    -- role is how you demote them without changing their WDW assignment.
    local unchanged = self.db.profile.assignments[playerName] == roleId
    self:LogRolePromotion("Role request",
        "player=" .. tostring(playerName),
        "roleId=" .. tostring(roleId),
        "unit=" .. tostring(unit),
        "combat=" .. tostring(InCombatLockdown()),
        "unchanged=" .. tostring(unchanged))
    self.db.profile.assignments[playerName] = roleId
    -- Get the board moving BEFORE the flag write below: that write wakes every
    -- other client's roster sweep about a second later, and they must already
    -- have the board that justifies it or they'll "correct" us from stale
    -- evidence. Debounced, so a burst of edits is still one broadcast.
    local sync = self:GetModule("Sync", true)
    if sync then sync:PushSoon() end
    if roleId then
        local _, role = self:FindRoleById(roleId)
        self:SyncBlizzardRoleState(playerName, role, unit)
        if not unchanged then
            self:LogOperation(playerName .. " set to " .. (role and role.name or roleId) .. ".")
            if role and self.db.profile.settings.announceRoleChanges then
                self:SendGroupMessage("[WhoDoesWhat] " .. playerName .. " was changed to "
                    .. role.name .. " by " .. (UnitName("player") or "?") .. ".")
            end
        end
    else
        -- Clearing a role is still a Blizzard-side change: a cleared main tank
        -- has to lose the mark, and nothing else would ever come back for them.
        self:SyncBlizzardRoleState(playerName, nil, unit)
        self:LogOperation(playerName .. "'s role cleared.")
    end

    -- Keep the saved tank rows current even when the main window is closed.
    self.Assign.EnsureAutoRows(self.Assign.SectionByKey("tank"))

    -- Try the PallyPower delta before repainting: RefreshMainAssignmentsView
    -- checks PallyPower drift, so it must see the post-send tables rather than
    -- leave a stale warning icon behind after a successful minimal update.
    if not unchanged then
        self:PushPlayerBuffToPallyPower(playerName)
    end

    -- Role changes can affect the main view's warnings (e.g. Curse of the
    -- Elements wants its warlock marked Affliction), move players between
    -- the raider roles buckets, and reshape the buff grid (roles drive its
    -- per-raider plan; Non-raider adds/removes rows), so repaint all three.
    self:RefreshMainAssignmentsView()
    self:RefreshRaiderRolesView()
    self:RefreshBuffingGridView()
    self:RefreshActionItemsView()
end



-- ---------------------------------------------------------------------------
-- Menu building
-- ---------------------------------------------------------------------------

-- Radio row text: spec icon + class-colored role name.
local function RoleRowText(role, classInfo)
    return WhoDoesWhat:RoleIconMarkup(role.icon, 16) .. " |cff" .. classInfo.colorHex .. role.name .. "|r"
end

-- Where our section lands: below the menu's first Blizzard section (name
-- title, Set Focus, Player vs. Player, divider = indexes 1-4), same area
-- SetRoleButtons uses. Menus vary a little, so this is approximate by nature.
-- In a raid without assist rights the menu drops one of the entries above us
-- (the assist-only raid controls), so the section shifts up one index; in a
-- party or with assist it stays put.
local INSERT_INDEX = 6

local function GetInsertIndex()
    if IsInRaid() and not WhoDoesWhat:IsRaidAssistant() then
        return INSERT_INDEX - 1
    end
    return INSERT_INDEX
end

-- Assigning roles to other people takes board edit permission (the
-- leader-owned rule in Permissions.lua); your own role is always yours.
local function CanAssignRoleTo(unit)
    return UnitIsUnit(unit, "player") or WhoDoesWhat:CanEditAssignments()
end

-- The player's current assignments as plain lines, for the read-only menu:
-- one per dynamic section they hold rows in ("Tank Skull, Everything else"),
-- one per static section ("Kings, Salvation (Paladin Buffs)"). Board rights
-- gate CHANGING assignments, never seeing them.
local function CollectAssignmentSummaries(playerName)
    local A = WhoDoesWhat.Assign
    local out = {}
    for _, section in ipairs(A.DynamicSections) do
        if section.enabled ~= false then
            local text = A.PlayerEntriesText(section, playerName, A.TargetPlainText)
            if text ~= "" then
                out[#out + 1] = section.whisperLead .. text
            end
        end
    end
    for _, section in ipairs(A.Sections) do
        local labels = {}
        for _, def in ipairs(section.rows) do
            if A.GetAssignment(def.id) == playerName then
                labels[#labels + 1] = def.label
            end
        end
        if #labels > 0 then
            out[#out + 1] = table.concat(labels, ", ") .. " (" .. section.title .. ")"
        end
    end
    return out
end

local function NoOp() end

-- "Set Role" label, led by an icon in the same slot either way: the player's
-- current role icon once assigned, or the main window's (!) alert while they
-- have no role yet -- so the collapsed button shows their state without
-- opening the pop-out. A role id we can't resolve (e.g. a deleted custom role)
-- also reads as the alert, which is the honest answer: it needs attention.
-- Menu labels take inline texture escapes, so no frame work is needed here.
local function SetRoleText(playerName)
    local icon = WhoDoesWhat.WARNING_ICON
    local roleId = WhoDoesWhat:GetAssignedRole(playerName)
    if roleId then
        local _, role = WhoDoesWhat:FindRoleById(roleId)
        if role then
            icon = role.icon
        end
    end
    return WhoDoesWhat:RoleIconMarkup(icon, 16) .. " Set Role"
end

-- The row shown in place of the "Set Role" pop-out when we can't assign: the
-- player's current role, or None when they have none.
local function CurrentRoleText(playerName, classInfo)
    local roleId = WhoDoesWhat:GetAssignedRole(playerName)
    if roleId then
        local _, role = WhoDoesWhat:FindRoleById(roleId)
        if role then
            return RoleRowText(role, classInfo)
        end
    end
    return "|cff909090None|r"
end

-- Raid-marker menu-row text: icon + name (same markup the main window uses;
-- three lines isn't worth an export).
local function MarkerText(m)
    return "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_" .. m.index
        .. ":14:14:0:0|t " .. m.name
end

-- The CC spells offered for a class: theirs, or everything in Developer Mode
-- (the same lift the main window's spell dropdown gets). Empty for classes
-- with no CC -- the caller drops the CC pop-out entirely then.
local function CCSpellsForClass(classInfo)
    if WhoDoesWhat.db.profile.settings.developerMode then
        return WhoDoesWhat.CCSpells
    end
    local out = {}
    for _, spell in ipairs(WhoDoesWhat.CCSpells) do
        if spell.class == classInfo.name then
            out[#out + 1] = spell
        end
    end
    return out
end

-- "Tank Assignments" pop-out: every raid marker, skull through star, as a
-- multi-select checkbox (a tank legitimately holds several). Checking takes
-- the marker over -- creating the window row when the marker has none,
-- replacing the tank when it does; unchecking (toggling off this player's own
-- marker) deletes the row.
local function FillTankSubmenu(submenu, playerName)
    for _, m in ipairs(WhoDoesWhat.RaidTargetMarkers) do
        local index = m.index
        submenu:CreateCheckbox(
            MarkerText(m),
            function() return WhoDoesWhat:GetTankMarkerAssignee(index) == playerName end,
            function()
                if WhoDoesWhat:GetTankMarkerAssignee(index) == playerName then
                    WhoDoesWhat:RemoveTankMarker(index)
                else
                    WhoDoesWhat:SetTankMarkerPlayer(index, playerName)
                end
            end
        )
    end
end

-- "CC Assignments" pop-out: two levels, spell -> single marker pick. Each
-- spell the class can cast opens its own skull-through-star radio list plus
-- None; picking a marker overwrites the identical assignment (same spell +
-- marker) in the window or creates it, and frees any other target the player
-- held for that spell. Re-picking the marker this player already holds toggles
-- it off, deleting that row.
local function FillCCSubmenu(submenu, playerName, spells)
    for _, spell in ipairs(spells) do
        local spellMenu = submenu:CreateButton(
            "|T" .. WhoDoesWhat:GetSpellIcon(spell.spellId) .. ":14:14:0:0|t " .. spell.name,
            NoOp)
        for _, m in ipairs(WhoDoesWhat.RaidTargetMarkers) do
            local index = m.index
            spellMenu:CreateRadio(
                MarkerText(m),
                function() return WhoDoesWhat:GetCCAssignee(spell.id, index) == playerName end,
                function()
                    if WhoDoesWhat:GetCCAssignee(spell.id, index) == playerName then
                        WhoDoesWhat:RemoveCCAssignment(spell.id, index)
                    else
                        WhoDoesWhat:SetCCAssignment(spell.id, index, playerName)
                    end
                end
            )
        end
        spellMenu:CreateRadio(
            "|cff909090None|r",
            function() return WhoDoesWhat:GetPlayerCCTarget(spell.id, playerName) == nil end,
            function() WhoDoesWhat:SetCCAssignment(spell.id, nil, playerName) end
        )
    end
end

local function ClassColoredName(m)
    return "|cff" .. m.classInfo.colorHex .. m.name .. "|r"
end

-- "Misdirect Assignments" pop-out, hunter side: the group's marked tanks as
-- a single-select radio list plus None -- one tank per hunter, so picking a
-- different tank moves the misdirect rather than adding one. Below the
-- tanks, a "Target Marker" submenu optionally tags the misdirect with a
-- raid marker (which pull it's for); the marker rides along in the whisper.
local function FillHunterMisdirectSubmenu(submenu, hunterName)
    local tanks = {}
    for _, m in ipairs(WhoDoesWhat:GetGroupMembers(nil)) do
        if WhoDoesWhat:IsMarkedTank(m.name) then
            tanks[#tanks + 1] = m
        end
    end

    if #tanks == 0 then
        submenu:CreateTitle("|cff909090No tanks marked yet - assign tank roles first|r")
        return
    end
    for _, m in ipairs(tanks) do
        local tankName = m.name
        submenu:CreateRadio(
            ClassColoredName(m),
            function() return WhoDoesWhat:GetMisdirectTarget(hunterName) == tankName end,
            function() WhoDoesWhat:SetMisdirectTarget(hunterName, tankName) end
        )
    end
    submenu:CreateRadio(
        "|cff909090None|r",
        function() return WhoDoesWhat:GetMisdirectTarget(hunterName) == nil end,
        function() WhoDoesWhat:SetMisdirectTarget(hunterName, nil) end
    )

    submenu:CreateDivider()
    local markerMenu = submenu:CreateButton("Target Marker", NoOp)
    for _, m in ipairs(WhoDoesWhat.RaidTargetMarkers) do
        local index = m.index
        markerMenu:CreateRadio(
            MarkerText(m),
            function() return WhoDoesWhat:GetMisdirectMarker(hunterName) == index end,
            function() WhoDoesWhat:SetMisdirectMarker(hunterName, index) end
        )
    end
    markerMenu:CreateRadio(
        "|cff909090None|r",
        function() return WhoDoesWhat:GetMisdirectMarker(hunterName) == nil end,
        function() WhoDoesWhat:SetMisdirectMarker(hunterName, nil) end
    )
end

-- Tank side: every hunter in the group as a checkbox -- several hunters can
-- feed one tank. Checking moves that hunter's misdirect here (one tank per
-- hunter); unchecking clears it.
local function FillTankMisdirectSubmenu(submenu, tankName)
    local hunters = WhoDoesWhat:GetGroupMembers("Hunter")
    if #hunters == 0 then
        submenu:CreateTitle("|cff909090No hunters in group|r")
        return
    end
    for _, m in ipairs(hunters) do
        local hunterName = m.name
        submenu:CreateCheckbox(
            ClassColoredName(m),
            function() return WhoDoesWhat:GetMisdirectTarget(hunterName) == tankName end,
            function()
                if WhoDoesWhat:GetMisdirectTarget(hunterName) == tankName then
                    WhoDoesWhat:SetMisdirectTarget(hunterName, nil)
                else
                    WhoDoesWhat:SetMisdirectTarget(hunterName, tankName)
                end
            end
        )
    end
end

-- Insert our section into an opening unit menu. Only fires for player units
-- whose class we know; the "Set Role" pop-out lists the class's full role
-- list (never the collapsed categories) plus any custom roles assigned to it.
-- With board edit permission (Permissions.lua) the section also carries the
-- Tank Assignments pop-out (multi-select marker grid) and, for classes with
-- CC, the CC Assignments pop-out (spell -> marker) -- both write straight
-- into the main window's assignment rows, creating or overwriting them as
-- needed. Without permission the pop-outs give way to read-only summary
-- lines of the player's current assignments -- everyone can always SEE the
-- board from here, and their own "Set Role" stays live.
-- Like SetRoleButtons, the elements are built detached via MenuUtil and
-- Insert()ed at a fixed index instead of appended at the bottom -- unless
-- this client's MenuUtil lacks a detached button constructor, in which case
-- we fall back to appending the section at the bottom.
local function AddWdwSection(rootDescription, contextData)
    local unit = contextData and contextData.unit
    if not unit or not UnitIsPlayer(unit) then return end

    -- Only group members get the section: assignments are group business, and
    -- anything saved for an outsider would just be pruned the next time the
    -- window opens. Yourself always counts, so solo testing still works.
    if not (UnitIsUnit(unit, "player") or UnitInParty(unit) or UnitInRaid(unit)) then
        return
    end

    local classInfo = GetClassInfoForUnit(unit)
    if not classInfo then return end

    local playerName = GetUnitKey(unit)
    if not playerName then return end

    -- Without the rights to assign, the role row is read-only text naming
    -- their current role -- no pop-out, nothing to click.
    local readOnly = not CanAssignRoleTo(unit)

    -- Group-wide assignments (tank targets, CC, misdirects) take board edit
    -- permission -- stricter than readOnly, which still lets an unpermitted
    -- member manage their own role. Without it the pop-outs are replaced by
    -- read-only summary lines (see below). The CC pop-out is also dropped
    -- for classes with no CC to offer.
    local canAssignGroup = WhoDoesWhat:CanEditAssignments()
    local ccSpells = canAssignGroup and CCSpellsForClass(classInfo) or {}
    local summaries = not canAssignGroup and CollectAssignmentSummaries(playerName) or nil

    -- Misdirects are two-sided: a hunter picks their tank, a marked tank
    -- picks their hunters. A hunter marked as a tank gets the hunter side.
    local mdMode
    if canAssignGroup and WhoDoesWhat.ClientFeatures.misdirectAssignments then
        if classInfo.name == "Hunter" then
            mdMode = "hunter"
        elseif WhoDoesWhat:IsMarkedTank(playerName) then
            mdMode = "tank"
        end
    end

    local setRole, tankMenu, ccMenu, mdMenu
    if MenuUtil.CreateButton then
        -- The no-op responder matters: a nil callback can assert inside the
        -- menu code, and a submenu parent never invokes it anyway.
        local roleEntry
        if readOnly then
            roleEntry = MenuUtil.CreateTitle(CurrentRoleText(playerName, classInfo))
        else
            setRole = MenuUtil.CreateButton(SetRoleText(playerName), NoOp)
            roleEntry = setRole
        end
        local insertIndex = GetInsertIndex()
        rootDescription:Insert(MenuUtil.CreateTitle("WhoDoesWhat"), insertIndex)
        rootDescription:Insert(roleEntry, insertIndex + 1)
        local nextIndex = insertIndex + 2
        if canAssignGroup then
            tankMenu = MenuUtil.CreateButton("Tank Assignments", NoOp)
            rootDescription:Insert(tankMenu, nextIndex)
            nextIndex = nextIndex + 1
        end
        if #ccSpells > 0 then
            ccMenu = MenuUtil.CreateButton("CC Assignments", NoOp)
            rootDescription:Insert(ccMenu, nextIndex)
            nextIndex = nextIndex + 1
        end
        if mdMode then
            mdMenu = MenuUtil.CreateButton("Misdirect Assignments", NoOp)
            rootDescription:Insert(mdMenu, nextIndex)
            nextIndex = nextIndex + 1
        end
        if summaries then
            for _, s in ipairs(summaries) do
                rootDescription:Insert(MenuUtil.CreateTitle("|cff909090" .. s .. "|r"), nextIndex)
                nextIndex = nextIndex + 1
            end
        end
        rootDescription:Insert(MenuUtil:CreateDivider(), nextIndex)
    else
        rootDescription:CreateDivider()
        rootDescription:CreateTitle("WhoDoesWhat")
        if readOnly then
            rootDescription:CreateTitle(CurrentRoleText(playerName, classInfo))
        else
            setRole = rootDescription:CreateButton(SetRoleText(playerName), NoOp)
        end
        if canAssignGroup then
            tankMenu = rootDescription:CreateButton("Tank Assignments", NoOp)
        end
        if #ccSpells > 0 then
            ccMenu = rootDescription:CreateButton("CC Assignments", NoOp)
        end
        if mdMode then
            mdMenu = rootDescription:CreateButton("Misdirect Assignments", NoOp)
        end
        if summaries then
            for _, s in ipairs(summaries) do
                rootDescription:CreateTitle("|cff909090" .. s .. "|r")
            end
        end
    end

    if tankMenu then
        FillTankSubmenu(tankMenu, playerName)
    end
    if ccMenu then
        FillCCSubmenu(ccMenu, playerName, ccSpells)
    end
    if mdMenu then
        if mdMode == "hunter" then
            FillHunterMisdirectSubmenu(mdMenu, playerName)
        else
            FillTankMisdirectSubmenu(mdMenu, playerName)
        end
    end

    if readOnly then return end

    local function AddRoleRadio(role)
        setRole:CreateRadio(
            RoleRowText(role, classInfo),
            function() return WhoDoesWhat:GetAssignedRole(playerName) == role.id end,
            function() WhoDoesWhat:SetAssignedRole(playerName, role.id, unit) end
        )
    end

    for _, role in ipairs(classInfo.roles) do
        AddRoleRadio(role)
    end
    for _, role in ipairs(classInfo.customRoles or {}) do
        AddRoleRadio(role)
    end

    -- Non-raider (the classless pseudo-role, Data.lua): sitting out. Below a
    -- divider since it isn't one of the class's specs; gray like its meaning.
    setRole:CreateDivider()
    local nr = WhoDoesWhat.NonRaiderRole
    setRole:CreateRadio(
        "|T" .. nr.icon .. ":16:16:0:0|t |cff" .. WhoDoesWhat.NonRaiderClass.colorHex
            .. nr.name .. "|r",
        function() return WhoDoesWhat:GetAssignedRole(playerName) == nr.id end,
        function() WhoDoesWhat:SetAssignedRole(playerName, nr.id, unit) end
    )

    -- "None" only appears while the player has no role yet (it reads as the
    -- current state); once assigned, the way to change is picking another role.
    if not WhoDoesWhat:GetAssignedRole(playerName) then
        setRole:CreateRadio(
            "|cff909090None|r",
            function() return true end,
            NoOp
        )
    end
end

-- Register our extension on every unit menu tag. Called once from
-- OnInitialize; the callbacks run each time a menu opens, so they always see
-- the current assignments and custom roles.
function WhoDoesWhat:SetupUnitMenus()
    if not (Menu and Menu.ModifyMenu) then
        self:Print("Unit menu integration skipped: Menu API not available on this client.")
        return
    end
    for _, tag in ipairs(MENU_TAGS) do
        Menu.ModifyMenu(tag, function(owner, rootDescription, contextData)
            -- An error here would otherwise be swallowed and our section
            -- silently dropped from the menu; surface it in chat instead.
            local ok, err = pcall(AddWdwSection, rootDescription, contextData)
            if not ok then
                WhoDoesWhat:Print("|cffff4040Unit menu error:|r " .. tostring(err))
            end
        end)
    end
    self:LogUiBuilding("Unit right-click menus registered.")
end
