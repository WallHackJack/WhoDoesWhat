local WhoDoesWhat = LibStub("AceAddon-3.0"):NewAddon("WhoDoesWhat", "AceConsole-3.0")

local GetMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
WhoDoesWhat.VERSION = GetMetadata and GetMetadata("WhoDoesWhat", "Version") or "?"

-- Developer logging toggles, mirrored from saved settings once the DB loads
-- (see OnInitialize / AddonSettingsView.lua). These values only cover calls
-- that happen before OnInitialize.
WhoDoesWhat.LOG_UI_BUILDING = true
WhoDoesWhat.LOG_OPERATIONS = false

-- Verbose logging for UI building / layout lifecycle. No-op when the flag is off.
-- Forwards its args straight to AceConsole's Print (space-joined).
function WhoDoesWhat:LogUiBuilding(...)
    if self.LOG_UI_BUILDING then
        self:Print(...)
    end
end

-- Routine user and automatic state changes. Off by default so assignment
-- edits and similar successful operations do not fill chat during normal use.
function WhoDoesWhat:LogOperation(...)
    if self.LOG_OPERATIONS then
        self:Print(...)
    end
end

-- The (!) alert used wherever something needs the user's attention: the main
-- window's per-row warnings (MainAssignmentsView) and the unit menu's "no role
-- yet" hint (UnitMenu). Shared so the two stay visually identical.
WhoDoesWhat.WARNING_ICON = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"

-- True while the player is in a raid with assist rights. The raid leader
-- counts: leaders hold every assistant privilege (and see the same extra
-- unit-menu entries), even though UnitIsGroupAssistant alone reports false
-- for them.
function WhoDoesWhat:IsRaidAssistant()
    return IsInRaid()
        and (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player"))
end

-- True when the local player is the SINGLE authority for writing OTHER
-- members' Blizzard role flags (UnitSetRole) and main-tank state. The group
-- LEADER owns this exclusively -- and that exclusivity is the point. The role
-- flag has no range check and can be set from anywhere, so if every raid
-- assistant wrote it, several clients (each with its own, differently-stale
-- talent cache) would tug one player's flag back and forth. Routing every
-- other-member write through the one leader means exactly one UnitSetRole
-- happens. Solo counts. Your OWN role is always settable regardless, so
-- callers that can target themselves check UnitIsUnit(unit, "player") /
-- UnitName("player") separately. WDW's own assignments sync to everyone and
-- are never gated by this -- only the Blizzard-side flag is.
--
-- Fallback: when no leader can own the board -- a battleground, or a raid
-- whose leader doesn't run WhoDoesWhat (the same conditions that stand the
-- editing rule down, PermissionsOpenReason) -- raid-assist rights are honoured
-- instead, so the flags are still managed by someone rather than nobody.
function WhoDoesWhat:CanSetOthersBlizzardRole()
    if not IsInGroup() then return true end -- solo
    if UnitIsGroupLeader("player") then return true end
    if self:PermissionsOpenReason() then return self:IsRaidAssistant() end
    return false
end

-- Whether a player's WDW role assignment (unit right-click menu) is a tank
-- role. Drives tank-preference floats and misdirect targets in the main view
-- and the unit menu's misdirect pop-outs.
function WhoDoesWhat:IsMarkedTank(name)
    local roleId = self:GetAssignedRole(name)
    if not roleId then return false end
    local _, role = self:FindRoleById(roleId)
    return (role and role.wowRole == "tank") and true or false
end

-- Whether a player is marked Non-raider (the unit-menu pseudo-role, Data.lua):
-- sitting out. Non-raiders stay in the plain group lists but drop out of the
-- paladin-buff demand votes, buff pools/dropdowns, and the buff grid.
function WhoDoesWhat:IsNonRaider(name)
    return self:GetAssignedRole(name) == self.NON_RAIDER_ROLE_ID
end

-- Default saved settings. Stored per-profile in WhoDoesWhatDB (see the
-- SavedVariables line in WhoDoesWhat.toc).
local defaults = {
    profile = {
        expandRoles = false,
        -- Per-role saved buff-order customizations, keyed by role id. Each entry
        -- is { buffOrder = { six buff keys }, allowedCount = 0..6 }. Roles on
        -- their defaults have no entry here; see SetRoleCustomization in Data.lua.
        roleCustomizations = {},
        -- User-created custom roles: array of
        -- { id = "custom_N", name, class = "Warrior", wowRole = "dps"|"tank"|"healer"|false }
        -- (false = no wow role assigned). Listed inside their class's role list
        -- with the "?" icon; buff orders live in roleCustomizations like any
        -- other role (default = canonical order).
        customRoles = {},
        customRoleCounter = 0, -- monotonic id source so deletes never recycle ids
        -- Per-player role assignments from the unit right-click menu, keyed by
        -- player name ("Name" or "Name-Realm") -> role id. See UnitMenuExtensions.lua.
        assignments = {},
        -- Last talent-detected role per player (same name keys as assignments),
        -- written by Talents.lua as talent data arrives. Comparing a fresh
        -- detection against this is what lets auto-assignment fill blanks and
        -- follow respecs without ever fighting a manual override: an override
        -- only yields when the detected spec actually *changes*.
        talentSpecs = {},
        -- Buff-talent ranks per paladin, scanned by Talents.lua as talent data
        -- arrives (same name keys as assignments): name -> { might = 0-5,
        -- wisdom = 0-2, kings = 0-1, sanctuary = 0-1 }. A missing player means
        -- their talents haven't been seen yet.
        paladinBuffTalents = {},
        -- Improved Healthstone rank per warlock (0-2), keyed like assignments.
        -- A missing player has not had their talent confirmed yet.
        warlockHealthstoneTalents = {},
        -- Druid/Priest improvement ranks for the raid-wide buffs tracked in
        -- CoreRaidBuffs: player name -> { gift = 0-5 } or { fortitude = 0-2 }.
        coreBuffTalents = {},
        -- Raid assignments from the main assignments view, keyed by row id
        -- ("curse_reck", "curse_elements") -> player name. Paladin blessings
        -- are NOT in here: their coverage is derived, never stored (see
        -- ComputeBuffGrid in Assignments.lua).
        raidAssignments = {},
        -- Custom paladin-buff rules (Buffing Rules > "Add (+)"): array of
        -- { buff = key, kind = "ignore"|"prioritize"|"prefer", scope, value }.
        -- One rule per buff, six at most. Shared as STATE.paladinStrategy and
        -- cleared with the group-scoped board on leave. See
        -- CompileBuffRules in Assignments.lua for the shapes and semantics.
        paladinBuffRules = {},
        -- Dynamic assignment rows in the main view, one array per section
        -- (see DynamicSections in Assignments.lua). Tank rows are one per
        -- tank, auto-managed from the marked tanks:
        -- { player = name, markers = { any mix of 1..8 | "all" | "custom" },
        --   custom = text }. CC rows are user-added:
        -- { player = name or nil, marker = 1..8 | "all" | "custom",
        --   custom = text, spell = CCSpells id }.
        tankAssignments = {},
        ccAssignments = {},
        -- Misdirect rows: { player = hunter name or nil, target = tank name
        -- or nil, marker = 1..8 or nil (optional, "which pull") }. One tank
        -- per hunter; several hunters may share a tank.
        mdAssignments = {},
        -- Who may edit the shared assignments board in a raid; owned by the
        -- raid leader and synced with the board. See Permissions.lua for the
        -- modes and rules ("assistant" mode names its one editor in
        -- `assistant`; false = none named).
        permissions = { mode = "assists", assistant = false },
        -- Addon settings, edited in AddonSettingsView.lua.
        settings = {
            -- Announce to raid/party chat "[WhoDoesWhat] X was changed to Role
            -- by Y" whenever someone's role assignment changes. Off = silent
            -- (the optional Log Operations entry and Blizzard's own role-flag
            -- message are separate and unaffected). See SetAssignedRole.
            announceRoleChanges = true,
            -- Whether the main-window Full view checkbox is off, showing only
            -- Paladin Buffs. Local view preference (not synced).
            paladinOnlyView = false,
            -- Assignment dropdowns list every group member instead of only
            -- the eligible class (e.g. non-paladins for paladin buffs).
            developerMode = false,
            -- Show the combined addon-message log button in the main toolbar.
            showLogsButton = false,
            -- Raid-wide source for paladin buff assignments. This field rides
            -- the permission-gated synchronized board state.
            pallyBuffSource = "wdw",
            -- Persisted source for LOG_UI_BUILDING above.
            logUiUpdates = false,
            -- Print routine assignment, reset, auto-assign, role, customization,
            -- whisper, and other successful operation messages to chat.
            logOperations = false,
            -- Print automatic WhoDoesWhat board/role sync status to chat.
            logSyncStatus = false,
            -- Session-only sync traffic capture and detailed chat diagnostics.
            logSyncTraffic = false,
            -- Print Paladin Buffing Bar click diagnostics to chat.
            logBuffingBarClicks = false,
            -- Trace WDW role edits through Blizzard role sync and the
            -- main-tank promotion window/highlight flow.
            logRolePromotion = false,
            -- TBC: auto-place an Affliction warlock on Curse of the Elements.
            -- Classic: let the Auto button fill Elements and Shadow.
            autoAssignAfflictionElements = true,
            -- Let auto-assign fill Curse of Recklessness. It raises the boss's
            -- damage taken *and* dealt, so the leader can opt out of it.
            allowRecklessnessAutoAssign = true,
            -- Testing toggle: inject 23 fake raiders into the roster so paladin
            -- buff strategies can be worked out solo. See FakeRaid.lua.
            populateFakeRaid = false,
--@do-not-package@
            -- Testing toggle: advertise and compare as the next patch version.
            simulateNewerAddonVersion = false,
--@end-do-not-package@
            -- How many paladins the fake roster carries (1-4; prot always,
            -- then ret, holy, a second ret). See FakeRaid.PALADINS.
            fakeRaidPaladinCount = 3,
            -- Master toggle for the Paladin Buffing Bar (the clickable Nova-style
            -- blessing bar). Off by default. See Views/PaladinBuffingBarView.lua.
            buffingBarEnabled = false,
            -- Dev/testing: render the buffing bar even when the local player
            -- isn't a paladin, as the paladin named in buffingBarTestPaladin.
            buffingBarTestMode = false,
            -- Which paladin's jobs the bar renders while buffingBarTestMode is
            -- on (a real or fake paladin's name); nil = the first one found.
            buffingBarTestPaladin = nil,
            -- Which way the buffing bar grows as blessings are added: "RIGHT"
            -- (anchor its left edge) or "LEFT" (anchor its right edge).
            buffingBarGrow = "RIGHT",
            -- Preferred direction for the per-player menu shown by hovering a
            -- class button. The view flips it when that side lacks screen room.
            buffingMenuGrow = "DOWN",
            -- Highlight active blessings yellow during their final five minutes.
            buffingMenuWarnExpiring = true,
            -- Movable per-paladin live blessing coverage window.
            overviewEnabled = false,
            overviewShowPallyPower = true,
            overviewPallyPowerOnlyDesynced = false,
            overviewAnchor = "TOPLEFT",
            overviewHideCompleted = false,
            overviewWidth = 220,
            statusBarChecks = {},
        },
    },
}

-- This runs when the game client finishes loading UI frames
function WhoDoesWhat:OnInitialize()
    -- Persistent configuration database
    self.db = LibStub("AceDB-3.0"):New("WhoDoesWhatDB", defaults, true)
    self.LOG_UI_BUILDING = self.db.profile.settings.logUiUpdates
    self.LOG_OPERATIONS = self.db.profile.settings.logOperations
    self:SetSyncLoggingEnabled(false)

    -- One-off migrations: buffAssignments briefly held the paladin buff picks
    -- before raidAssignments generalized it -- drop it outright. Then paladin
    -- blessings stopped being assigned at all (coverage is computed now), so
    -- strip any retired buff rows and the old override store from raid
    -- profiles that predate that.
    self.db.profile.buffAssignments = nil
    for _, key in ipairs(self.CanonicalBuffOrder) do
        self.db.profile.raidAssignments[key] = nil
    end
    self.db.profile.raidAssignmentOverrides = nil

    -- Alive became the inverse Dead status; keep any per-row preferences under
    -- the new key while the grid option itself remains hard-disabled in Data.
    local statusChecks = self.db.profile.settings.statusBarChecks
    if statusChecks.alive and not statusChecks.dead then
        statusChecks.dead = statusChecks.alive
    end
    statusChecks.alive = nil

    -- tankAssignments migrated from one-row-per-marker { player, marker } to
    -- one-row-per-tank { player, markers = { ... } } (multi-select markers on
    -- auto-populated rows). Old rows merge by player; rows that had a marker
    -- but no tank held nothing worth keeping and drop.
    do
        local store = self.db.profile.tankAssignments
        local out, byPlayer, migrated = {}, {}, false
        for _, e in ipairs(store) do
            if e.markers then
                out[#out + 1] = e
            else
                migrated = true
                if e.player then
                    local row = byPlayer[e.player]
                    if not row then
                        row = { player = e.player, markers = {}, custom = "" }
                        byPlayer[e.player] = row
                        out[#out + 1] = row
                    end
                    if e.marker ~= nil then
                        row.markers[#row.markers + 1] = e.marker
                    end
                    if e.custom and e.custom ~= "" then
                        row.custom = e.custom
                    end
                end
            end
        end
        if migrated then
            for _, row in ipairs(out) do
                self.Assign.NormalizeMarkers(row.markers)
            end
            wipe(store)
            for _, row in ipairs(out) do store[#store + 1] = row end
        end
    end

    -- hunter_pets stopped being an assignable role: every hunter's pet is
    -- now derived automatically (Assignments.lua), so a hunter still saved
    -- on it goes back to roleless (talent auto-detect refills them), and any
    -- saved buff-order customization for it drops -- the role is no longer
    -- offered anywhere, including Role Preferences.
    for name, roleId in pairs(self.db.profile.assignments) do
        if roleId == self.HUNTER_PET_ROLE_ID then
            self.db.profile.assignments[name] = nil
        end
    end
    self.db.profile.roleCustomizations[self.HUNTER_PET_ROLE_ID] = nil

    -- One-off cache wipe: the first buff-talent scanner matched icons against
    -- live GetTalentInfo returns, which don't compare equal to the library's
    -- static fileIDs for the local player -- locally-scanned paladins were
    -- saved as all-zero ranks ("untalented" Kings on a Kings paladin). Drop
    -- the poisoned cache; talent broadcasts and inspects repopulate it.
    if (self.db.profile.buffTalentScanVersion or 1) < 2 then
        self.db.profile.paladinBuffTalents = {}
        self.db.profile.buffTalentScanVersion = 2
    end
    self:LogUiBuilding("WhoDoesWhat database ready. expandRoles = " .. tostring(self.db.profile.expandRoles))

    -- Populate the cached roles and categories lookup
    self:PopulateRolesAndCategories()

    -- Re-write the fake raiders' roles/talents when the testing toggle is on:
    -- the group-leave wipe (Sync.lua) can fire around reload/logout while solo
    -- and clear them out of the saved board. See FakeRaid.lua.
    self:ReapplyFakeRaid()

    self:LogUiBuilding("WhoDoesWhat initialized! Type /wdw to open.")

    -- Register our slash commands
    self:RegisterChatCommand("wdw", "ToggleMainUI")

    -- Inject our section into the unit right-click menus
    self:SetupUnitMenus()
end
