local WhoDoesWhat = LibStub("AceAddon-3.0"):NewAddon("WhoDoesWhat", "AceConsole-3.0")
local UI = select(2, ...).UI

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
UI.logger = function(message) WhoDoesWhat:LogUiBuilding(message) end

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
WhoDoesWhat.WARNING_ICON = UI.WARNING_ICON

-- WDW's own icon: the minimap button wears it, and it signs the tooltips that
-- name the addon outright.
WhoDoesWhat.ADDON_ICON = "Interface\\AddOns\\WhoDoesWhat\\Media\\Icon.tga"

-- One shape for every "how is this buff doing" line WDW sends out -- the status
-- bars' raid announce, their whisper to whoever supplies the buff, and the
-- paladin buff mail from the main window -- so a check reads the same wherever
-- it arrives.
--
-- Counted forwards: "18/25 Applied" is the same fact as "7 missing" and reads
-- as progress rather than an accusation. Names of the stragglers are the
-- caller's to append, and only while there are few enough to be a list rather
-- than a wall -- MAX_NAMED_MISSING is where that stops.
WhoDoesWhat.MAX_NAMED_MISSING = 5

function WhoDoesWhat:CoverageSummary(label, applied, total)
    local percent = total > 0 and math.floor(applied * 100 / total + 0.5) or 0
    return string.format("%s -- %d/%d Applied (%d%%)", label, applied, total,
        percent)
end

-- The single letter that stands in for a name in tight spaces (status bar
-- rows, buff-grid column headers). Names are UTF-8, so an accented first
-- letter like "Ándraste" is two bytes: a plain :sub(1, 1) would hand the font
-- half a character and render nothing at all.
function WhoDoesWhat:NameInitial(name)
    if not name or name == "" then return "" end
    local lead = name:byte(1)
    local size = (lead < 0xC0 and 1) or (lead < 0xE0 and 2) or (lead < 0xF0 and 3) or 4
    return name:sub(1, size)
end

-- True while the player is in a raid with assist rights. The raid leader
-- counts: leaders hold every assistant privilege (and see the same extra
-- unit-menu entries), even though UnitIsGroupAssistant alone reports false
-- for them.
function WhoDoesWhat:IsRaidAssistant()
    return IsInRaid()
        and (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player"))
end

-- Writing OTHER members' Blizzard role flags (UnitSetRole) and main-tank state
-- goes through a SINGLE elected writer, and that exclusivity is the whole
-- point. The role flag has no range check and can be set from anywhere, and
-- every UnitSetRole fires GROUP_ROSTER_UPDATE on every client -- which drives
-- each client's reconcile sweep. Two clients with differently-stale boards
-- therefore don't just disagree once, they ping-pong the flag forever at the
-- sweep interval, announcing "X is now Damage Dealer" on every bounce.
--
-- Your OWN role is always settable regardless (callers that can target
-- themselves check UnitIsUnit(unit, "player") / UnitName("player")
-- separately), so a second writer always exists in principle -- the player
-- themselves. The write latch in UnitMenuExtensions.lua is what stops that
-- pair from looping; the election below is what stops everyone else joining in.
--
-- WDW's own assignments sync to everyone and are never gated by any of this --
-- only the Blizzard-side flag is.

-- Every current group member's name under our keying, roster order.
function WhoDoesWhat:GroupMemberNames()
    local names = {}
    local function Add(unit)
        local name, realm = UnitName(unit)
        if not name then return end
        names[#names + 1] = (realm and realm ~= "") and (name .. "-" .. realm) or name
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do Add("raid" .. i) end
    else
        Add("player")
        for i = 1, GetNumSubgroupMembers() do Add("party" .. i) end
    end
    return names
end

-- Elect the ONE player who writes other members' Blizzard role flags, or nil
-- when nobody is eligible (nobody writes then -- better than everybody).
--
-- The leader wins whenever they run our protocol. Requiring the PROTOCOL
-- match, not just presence, is the fix for the out-of-date-leader case: a
-- leader on an older build is recorded as a peer (senders are recorded before
-- the protocol check) but silently ignores every board we send, so making them
-- sole writer means their stale board stomps everyone forever.
--
-- Without such a leader we elect the alphabetically first permitted member
-- running our protocol. Name order is identical on every client, so everyone
-- elects the same writer with no negotiation round-trip -- which is what keeps
-- ten assistants from all writing at once.
function WhoDoesWhat:BlizzardRoleWriter()
    if not IsInGroup() then return UnitName("player") end -- solo
    local sync = self:GetModule("Sync", true)
    if not sync then return nil end

    local leader = sync:GroupLeaderName()
    if leader and sync:RunsCompatibleProtocol(leader) then return leader end

    -- Candidates must also hold the WoW rank that lets them set someone else's
    -- flag (Permissions.lua). Board rights alone aren't enough and read wide
    -- open in exactly this case -- an addonless leader -- so without this the
    -- election happily picks a rank-0 raider whose every write the server
    -- refuses, leaving a writer who writes nothing and a UI that offers edits
    -- that can't land.
    local best
    for _, name in ipairs(self:GroupMemberNames()) do
        if sync:RunsCompatibleProtocol(name) and self:PlayerCanEditAssignments(name)
            and self:PlayerCanSetGroupRoles(name)
            and (not best or name < best) then
            best = name
        end
    end
    return best
end

-- Master opt-out (Settings > General): whether WDW touches Blizzard group
-- state at all -- the group role flag, the main-tank demotion, and the
-- promote-to-main-tank prompt. Off is the escape hatch for a raid where flags
-- are being fought over; WDW's own board keeps working untouched. Defaults on,
-- and reads on rather than off before the DB exists (the addon's normal
-- behavior shouldn't hinge on load order).
function WhoDoesWhat:ManagesBlizzardRoles()
    if not (self.db and self.db.profile) then return true end
    return self.db.profile.settings.manageBlizzardRoles ~= false
end

-- Writing someone else's flag splits in two, and the split is the whole point.
--
-- AUTOMATIC writes -- talent detection deciding a newcomer is Restoration, the
-- reconcile sweep pushing the whole board -- go through the single-writer
-- election below. Several clients reaching the same conclusion at the same
-- moment is exactly how the flag ping-pong starts, and electing one writer is
-- what stops it.
--
-- MANUAL writes -- a person picking a group role out of a dropdown, or setting
-- a WDW role and expecting the flag to follow -- take the WoW rank instead:
-- raid assist or party lead, the same rank the server itself demands before it
-- will accept UnitSetRole for another player. There is no storm to prevent
-- here. A human clicked once, deliberately, on one player; two assistants who
-- disagree about a raider are having an argument, not a race, and the election
-- was only ever there to break races. Gating manual picks on it meant that in
-- any raid whose leader runs WhoDoesWhat -- the normal case -- every
-- assistant's dropdown was dead, and no explanation fit in a tooltip.
function WhoDoesWhat:CanSetOthersBlizzardRoleManually()
    return self:PlayerCanSetGroupRoles(UnitName("player"))
end

-- True when we're the elected writer, and so may touch someone else's flag
-- WITHOUT being asked to -- see the manual counterpart above.
function WhoDoesWhat:CanSetOthersBlizzardRole()
    local writer = self:BlizzardRoleWriter()
    return writer ~= nil and writer == UnitName("player")
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

-- ---------------------------------------------------------------------------
-- Hunter pet names
-- ---------------------------------------------------------------------------
--
-- Hunter pets are keyed "<Owner>'s Pet" everywhere internally (Assignments.lua
-- builds them, BuffTracking and the PallyPower bridge match on them). That key
-- is an identity, not a label: on screen a pet gets its real name with its
-- owner behind it -- "Broll (Rexxar)" -- for as long as the pet is visible.
--
-- ownerName -> { name = <pet's real name>, unit = <pet unit token> }, rebuilt
-- at most once per frame. The buff grid asks once per row per repaint and the
-- scan walks the whole raid, so the repeats are worth skipping -- but caching
-- across frames would need invalidation events, and nothing guarantees ours
-- runs before the view frame that repaints on the same event. GetTime() is
-- frozen for the duration of a frame, which makes it exactly the right key.
local petInfo, petInfoTime = {}, nil

-- Units that occupy the pet slot without being a pet. The Steam Tonk
-- Controller parks a "Steam Tonk" on `raidNpet` for five minutes: it takes no
-- blessing, it is not the pet any plan is about, and it vanishes as abruptly
-- as it arrived -- so every pet scan skips it and the hunter simply reads as
-- having no pet summoned. Matched by name because that is all a tonk gives us
-- (an enUS name; a localized client would see its own and let the tonk
-- through, which is the pre-existing behaviour, not a regression).
local IGNORED_PET_NAMES = { ["Steam Tonk"] = true }

function WhoDoesWhat:IsIgnoredPetName(name)
    if not name then return false end
    return IGNORED_PET_NAMES[name:match("^([^%-]+)") or name] == true
end

function WhoDoesWhat:GetPetUnitInfo()
    if petInfoTime == GetTime() then return petInfo end
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = { "raid" .. i, "raidpet" .. i } end
    else
        units[#units + 1] = { "player", "pet" }
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = { "party" .. i, "partypet" .. i } end
    end
    petInfo = {}
    for _, u in ipairs(units) do
        if UnitExists(u[2]) then
            local owner, name = GetUnitName(u[1], true), GetUnitName(u[2], true)
            if owner and name and not self:IsIgnoredPetName(name) then
                petInfo[owner] = { name = name, unit = u[2] }
            end
        end
    end
    petInfoTime = GetTime()
    return petInfo
end

-- The pet's own name, or nil while it isn't resolvable (out of range, dead and
-- not yet re-summoned, or a Developer Mode fake hunter). Realm-tagged owner
-- keys resolve too -- the roster keys pets by the same name it stores owners.
function WhoDoesWhat:GetPetName(ownerName)
    local info = ownerName and self:GetPetUnitInfo()[ownerName]
    return info and info.name or nil
end

-- Display text for any roster / plan / BuffTracking key: realm suffix dropped,
-- and a pet key resolved to "Broll (Rexxar)". `short` asks for the pet's bare
-- name instead, for the fixed-width spots that can't take the parenthetical.
-- Both forms fall back to the key's own "Rexxar's Pet" while the pet has no
-- resolvable name, so a row never goes anonymous.
function WhoDoesWhat:DisplayName(name, short)
    if not name then return name end
    local owner = name:match("^(.*)'s Pet$")
    if not owner then return name:match("^([^%-]+)") or name end
    local petName = self:GetPetName(owner)
    owner = owner:match("^([^%-]+)") or owner
    if not petName then return owner .. "'s Pet" end
    petName = petName:match("^([^%-]+)") or petName
    if short then return petName end
    return petName .. " (" .. owner .. ")"
end

-- One set of Warrior Shout Bar settings. There are two, kept per account: the
-- set in use while you play a warrior, who casts from the bar, and the set in
-- use on everything else, who asks for shouts from it
-- (Views/WarriorShoutBarView.lua). Only the defaults tell them apart.
local function ShoutBarDefaults(warrior)
    return {
        -- The bar's on switch. Off for a non-warrior out of the box, as it
        -- always was: asking for shouts is something to opt into.
        enabled = warrior,
        -- Where it was last Alt-dragged to; nil = centred.
        pos = nil,
        -- Which edge holds still as the bar changes width (a second warrior
        -- joining or leaving adds or drops the second icon): "LEFT", "CENTER"
        -- (spread from the midpoint) or "RIGHT".
        anchor = "CENTER",
        -- Chrome the bar can do without: its backdrop, and the covered/total
        -- count under each icon -- which a non-warrior, who only wants to
        -- know whether to ask, does without by default.
        hideBackground = false,
        hideNumbers = not warrior,
        -- How close the soonest-to-lapse shout gets before its countdown
        -- appears over the icon: seconds, -1 for always, or 0 for never. A
        -- non-warrior only needs to know once it is nearly time to ask.
        timerSeconds = warrior and 30 or 15,
        -- Leave raiders who are nowhere near you (UnitInRange, ~40 yards) out
        -- of the shout counts entirely. Off: someone standing a little too far
        -- back is a gap worth showing, not one worth hiding.
        ignoreOutOfRange = false,
        -- Which shout the single icon covers while the party has one warrior
        -- (a WhoDoesWhat.WarriorShouts key); right-clicking that icon swaps
        -- it. nil = Battle Shout.
        soloShout = nil,
        -- Fade each icon out while its shout is on everybody, bringing it back
        -- the moment it goes missing or a countdown starts. On for a
        -- non-warrior: the bar only needs to be seen when there is asking to do.
        hideWhenBuffed = not warrior,
        -- Fade each icon out while its shout is on YOU, whoever else is still
        -- missing it. On for a non-warrior, whose only use for the bar is
        -- asking for a shout they lack; off for a warrior, who shouts for the
        -- whole party whether or not they have it themselves.
        hideWhenSelfBuffed = not warrior,
        -- How big a shout icon is, in pixels. The bar is exactly as wide as
        -- its icons, so this sizes the whole strip.
        iconSize = 28,
        -- The glow: one of the status bars' highlight styles (HIGHLIGHT_STYLES
        -- in StatusBarsView), amber while the shout is on nobody, blue once it
        -- is on part of the party.
        glowStyle = "flash",
        glowMissingColor = { r = 0.949, g = 0.71, b = 0 },
        glowPartialColor = { r = 0.157, g = 0.561, b = 1 },
    }
end

-- Default saved settings. Stored per-profile in WhoDoesWhatDB (see the
-- SavedVariables line in WhoDoesWhat.toc), bar the shout bar's, which is per
-- account.
local defaults = {
    -- Per character: what one character carries and wields says nothing about
    -- the next. The Buff Checklist's picks -- mainHand / offHand as an item id,
    -- "none" (keep the weapon bare for Windfury) or nil (nothing picked); food,
    -- petFood, alcohol, battleElixir and guardianElixir as an item id or nil;
    -- aura, aspect, mageArmor and warlockArmor as a spell key -- and whether it
    -- tracks weapon enchants.
    char = {
        buffChecklistItems = {},
        buffChecklistWeapons = true,
        -- The battle / guardian elixir icons (TBC only); their picks share
        -- buffChecklistItems as battleElixir / guardianElixir.
        buffChecklistElixirs = true,
        -- The Scroll of Agility / Strength icons, for physical damage roles;
        -- picks as agilityScroll / strengthScroll in buffChecklistItems.
        buffChecklistScrolls = true,
        -- A hunter's pet section folded down to its divider.
        buffChecklistPetCollapsed = false,
        -- Whether this character has been shown the Forever welcome
        -- (ForeverWelcome.lua). Per character, because that is who it
        -- introduces the addon to -- and while the beta never loads its saved
        -- variables it is unsaveable, so the notice returns every session.
        foreverWelcomeSeen = false,
    },
    global = {
        shoutBar = {
            warrior = ShoutBarDefaults(true),
            nonWarrior = ShoutBarDefaults(false),
        },
    },
    profile = {
        expandRoles = false,
        -- User-created custom roles -- the local library: array of
        -- { id = "custom_a41f0c_2", name, class = "Warrior",
        --   wowRole = "dps"|"tank"|"healer"|false, icon,
        --   order = { six buff keys }, allowed = 0..6 } (false = no wow role
        -- assigned; a nil icon means the role wears its class's icon, see
        -- CustomRoleIconChoices in Data.lua). A whole definition, because the
        -- role is the user's invention -- unlike a built-in role, which has no
        -- local store at all. It only becomes something the rest of the raid can
        -- resolve once it is published to raidCustomRoles below (Data.lua,
        -- PublishCustomRole).
        customRoles = {},
        -- Monotonic id counter, kept so deletes never recycle ids. It is only
        -- half of an id now: NewCustomRoleId prefixes a random block, because
        -- a published role is keyed by its id on every client in the raid and
        -- a bare counter gave everyone the same ids for different roles.
        customRoleCounter = 0,
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
        -- Druid/Priest improvement ranks for tracked raid buffs: player name
        -- -> { gift = 0-5, thorns = 0-3 } or { fortitude = 0-2, spirit = ... }.
        -- A rank of `false` means that spec cannot cast the buff at all -- only
        -- on a buff its class does not universally get (Divine Spirit; see
        -- requiredTalent in Data.lua), where 0 and "no such spell" are
        -- different answers. Those buffs also carry the player's other talent
        -- group under an `offspec` sub-table of the same shape.
        coreBuffTalents = {},
        -- Raid assignments from the main assignments view, keyed by row id
        -- ("curse_reck", "curse_elements") -> player name. Paladin blessings
        -- are NOT in here: their coverage is derived, never stored (see
        -- ComputeBuffGrid in Assignments.lua).
        raidAssignments = {},
        -- Custom paladin-buff rules (Buffing Rules > "Add (+)"): array of
        -- { buff = key, kind = "ignore"|"assign"|"guarantee", scope, value,
        -- only, except }. Written whole from the Add (+) pop-out and never
        -- edited in place. Shared as STATE.paladinStrategy and cleared with the
        -- group-scoped board on leave. See the rule model above
        -- CompileBuffRules in Assignments.lua for the shapes and semantics.
        paladinBuffRules = {},
        -- The raid's shared roles (the Custom Roles section): array of
        -- { id, order = { six buff keys }, allowed = 0..6 }, plus
        -- { name, class, wowRole, icon } when the entry is a published custom
        -- role rather than an override of a built-in role or category.
        --
        -- This is the ONLY place a blessing order deviates from the defaults.
        -- A published custom role also carries its whole definition, so every
        -- client resolves the role -- and computes the same plan -- from the
        -- board rather than from a profile only the publisher has. Shared as
        -- STATE.customRoles and cleared with the group-scoped board on leave.
        raidCustomRoles = {},
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
            -- LibDBIcon state for the assignment-window launcher.
            minimapButton = { hide = false, minimapPos = 220 },
            -- Announce to raid/party chat "[WhoDoesWhat] X was changed to Role
            -- by Y" whenever someone's role assignment changes. Off = silent
            -- (the optional Log Operations entry and Blizzard's own role-flag
            -- message are separate and unaffected). See SetAssignedRole.
            --
            -- Off by default: setting up a board means a burst of these, and
            -- chat spam from an addon nobody else is running is a poor
            -- introduction. Raids that want the running commentary turn it on.
            announceRoleChanges = false,
            -- Append the player's WDW role to Blizzard's unit tooltip
            -- (UnitTooltipExtensions.lua). Display only, group members only.
            unitTooltipRole = true,
            -- Draw the player's WDW spec icon in the top-left corner of
            -- Blizzard's compact raid/party frames, over the group icon that
            -- normally sits there (RaidFrameExtensions.lua). Display only, and
            -- only for players whose spec we actually know.
            raidFrameRoleIcons = true,
            -- Keep those icons up while you are fighting. Nothing here is
            -- combat-restricted -- a texture carries no protected state, and
            -- the client repaints that same corner mid-fight itself -- so this
            -- is purely a "leave my raid frames alone during a pull"
            -- preference. Off hands the corner back for the fight and takes it
            -- again when the fight ends.
            raidFrameRoleIconsInCombat = true,
            -- How that icon is shaped. "corner" ("Replace WoW Icon") is a
            -- round one centred on the spot the client draws its own role icon
            -- in, standing down entirely for a player we have no role for so
            -- the client's own icon shows there; "band" is a
            -- narrow vertical strip down the left edge of the health bar,
            -- masked to the middle slice of the art and finished with a dark
            -- hairline; "bandFaded" is the same strip run out to square and
            -- dissolved inward, washing under the text instead of moving it.
            -- "bandRight"/"bandRightFaded" mirror the two onto the health
            -- bar's other edge. See RaidFrameExtensions.lua.
            raidFrameRoleIconStyle = "corner",
            -- "corner", "band" and "bandRight" only: a role-coloured outline
            -- on the icon's dark edge -- blue tanks and green healers, and red
            -- DPS under the separate switch so the most common role can stay
            -- unpainted.
            raidFrameRoleOutline = false,
            raidFrameRoleOutlineDps = false,
            -- Also append the roster hover summary (paladin blessing talents,
            -- warlock healthstone) to that tooltip. Off by default: it is
            -- several lines, and most hovers do not want them.
            unitTooltipDetail = false,
            -- `tooltipIds` (spell and item ids on tooltips) is deliberately
            -- absent here: its default depends on the client, which this file
            -- loads too early to ask. WhoDoesWhat:ShowTooltipIds() in
            -- ClientFeatures.lua resolves it, and unset means "client's call".
            -- Master switch for WDW writing Blizzard group state: the
            -- tank/healer/damager group role (UnitSetRole) and the main-tank
            -- demotion. Off = WDW keeps its own board and never touches
            -- Blizzard's, an escape hatch for a raid where role flags are
            -- being fought over by another addon or a mismatched WDW build.
            -- Local, deliberately NOT synced -- it's a per-client opt-out, and
            -- one raider disabling it must not disable everyone. See
            -- ApplyBlizzardRole.
            manageBlizzardRoles = true,
            -- Assignment dropdowns list every group member instead of only
            -- the eligible class (e.g. non-paladins for paladin buffs).
            developerMode = false,
            -- Show the combined addon-message logs as a main-window tab.
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
            -- Testing toggle: inject fake raiders into the roster so paladin
            -- buff strategies can be worked out solo. See FakeRaid.lua.
            populateFakeRaid = false,
            -- How many fakes that is: 23 or 39 (FakeRaid.SIZES).
            fakeRaidSize = 39,
--@do-not-package@
            -- Testing toggle: advertise and compare as the next patch version.
            simulateNewerAddonVersion = false,
--@end-do-not-package@
            -- How many paladins the fake roster carries (1-4; prot always,
            -- then ret, holy, a second ret). See FakeRaid.PALADINS.
            fakeRaidPaladinCount = 3,
            -- Master toggle for the Paladin Buffing Bar (the clickable Nova-style
            -- blessing bar). See Views/PaladinBuffingBarView.lua. On: it only
            -- ever appears for a paladin, so a raid of everyone else never sees
            -- it, and a paladin who installs WDW is exactly who it is for.
            buffingBarEnabled = true,
            -- Dev/testing: render the buffing bar even when the local player
            -- isn't a paladin, as the paladin named in buffingBarTestPaladin.
            buffingBarTestMode = false,
            -- Which paladin's jobs the bar renders while buffingBarTestMode is
            -- on (a real or fake paladin's name); nil = the first one found.
            buffingBarTestPaladin = nil,
            -- Whether the buffing bar lays its buttons out as a row
            -- ("HORIZONTAL") or a column ("VERTICAL"). The orientation decides
            -- which values the two grow settings below take. A column by
            -- default: one icon wide, it costs a screen edge rather than a
            -- band across the middle, which is what the bar was tuned to in
            -- actual raids -- and the three settings under it are the ones
            -- that column wants.
            buffingBarOrientation = "VERTICAL",
            -- Which way the buffing bar grows as blessings are added. Row:
            -- "RIGHT" (anchor its left edge), "LEFT" (anchor its right edge)
            -- or "CENTER" (anchor its midpoint, spreading both ways). Column:
            -- "DOWN" (anchor its top edge), "UP" (its bottom edge) or "CENTER".
            buffingBarGrow = "DOWN",
            -- Preferred direction for the per-player menu shown by hovering a
            -- class button -- "DOWN"/"UP" for a row, "RIGHT"/"LEFT" for a
            -- column. The view flips it when that side lacks screen room.
            buffingMenuGrow = "LEFT",
            -- Drop a class button off the bar while every member it covers is
            -- buffed, leaving only the work still outstanding. On: a column of
            -- outstanding work is the shape the bar is for, and a class comes
            -- straight back when its blessing runs into the warning window.
            buffingBarHideCompleted = true,
            -- How close to lapsing a blessing gets before the bar says so: a
            -- countdown over the class button and a yellow player row. 1-10.
            buffingMenuWarnMinutes = 6,
            -- The two self-buff buttons anchored at the left end of the buffing
            -- bar, ahead of the class buttons. Both act on the local player: an
            -- aura swapper, and a Righteous Fury reminder that only appears
            -- while the paladin holds a tank role.
            buffingBarAuraButton = true,
            buffingBarRighteousFury = true,
            -- Which aura the swapper currently offers (a WhoDoesWhat.PaladinAuras
            -- key); nil = the first aura this paladin knows.
            buffingBarAura = nil,
            -- How big a buffing bar button is, in pixels. Everything else on
            -- the bar is measured off this, so the whole bar grows with it.
            buffingBarIconSize = 28,
            -- The buffing bar's glow: one of the status bars' highlight styles
            -- (HIGHLIGHT_STYLES in StatusBarsView) drawn in the two colours
            -- below. "Missing" covers a class button with work still on it and
            -- a self-buff that is down; "expiring" is a self-buff inside its
            -- warning window. Amber and blue.
            buffingBarGlowStyle = "flash",
            buffingBarGlowMissingColor = { r = 0.949, g = 0.71, b = 0 },
            buffingBarGlowExpiringColor = { r = 0.157, g = 0.561, b = 1 },
            -- The Buff Checklist: a movable grid of the buffs the local player
            -- should be wearing (Views/BuffChecklistView.lua). Off until turned
            -- on from its settings page. Columns is how many icons a row holds
            -- before the grid wraps; hide-have drops buffs already on you.
            -- Align picks the corner that holds still and the side a short
            -- last row hugs. The position is nil until it is first Alt-dragged.
            buffChecklistEnabled = false,
            buffChecklistColumns = 6,
            buffChecklistIconSize = 28,
            -- How tightly the grid packs: "roomy", "snug" or "compact"
            -- (BuffChecklistSpacings).
            buffChecklistSpacing = "roomy",
            buffChecklistHideHave = false,
            -- Narrower: hide only done buffs another class casts on you.
            buffChecklistHideOthersHave = true,
            -- The checklist's glow: a status-bar highlight style in two
            -- colours, amber for missing and blue for expiring, like the
            -- Paladin Bar's.
            buffChecklistGlowStyle = "flash",
            -- Minutes left at which a buff starts to glow and count down.
            buffChecklistWarnMinutes = 6,
            buffChecklistGlowMissingColor = { r = 0.949, g = 0.71, b = 0 },
            buffChecklistGlowExpiringColor = { r = 0.157, g = 0.561, b = 1 },
            buffChecklistAlign = "RIGHT",
            -- Where the checklist's pop-out menus open against their icon
            -- (BuffChecklistPopoutDirections).
            buffChecklistPopoutDirection = "BELOWLEFT",
            -- The "Buff Checklist" title strip across the top of the grid.
            buffChecklistShowHeader = true,
            -- A "From Others" line between your own buffs and the ones other
            -- raiders cast on you.
            buffChecklistSplitOthers = false,
            buffChecklistPos = nil,
            -- Movable per-paladin live blessing coverage window. On out of the
            -- box: it is the view that says what still needs doing, and a fresh
            -- install has no reason to hunt for it in the settings.
            overviewEnabled = true,
            overviewAnchor = "TOPRIGHT",
            overviewDefaultDisplay = "percent",
            -- Which side of a hovered status bar its tooltip opens on
            -- (LEFT / RIGHT / ABOVE / BELOW).
            statusBarTooltipAnchor = "LEFT",
            -- How many names a status-bar tooltip lists before the rest
            -- collapse into "... and N more". One global number: it is a
            -- property of how much tooltip you want to read, not of any
            -- one buff, so it is not offered per-check.
            statusBarTooltipNames = 10,
            -- Which animation a status row uses when it highlights
            -- (see HIGHLIGHT_STYLES in StatusBarsView).
            statusBarHighlightStyle = "flash",
            -- The colour every highlight style is drawn in. The picker writes
            -- {r,g,b} here; the Status Bars page's Defaults button puts this
            -- amber back.
            statusBarHighlightColor = { r = 0.949, g = 0.71, b = 0 },
            -- The narrowest the window can be dragged (RESIZE_MIN_W in
            -- StatusBarsView). Defaults and the page's Defaults button hand it
            -- back at its smallest, to be widened from there.
            overviewWidth = 68,
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
    self.Profiling.LoadSetting()
    -- After every file has loaded, so the public entry points it times exist.
    self.Profiling.InstrumentAll()

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
    local settings = self.db.profile.settings
    -- The Paladin-only view went away with the tabbed main window.
    settings.paladinOnlyView = nil

    -- The shout bar's settings left the profile for two per-account sets.
    -- Whatever this profile had tuned goes into both, once, bar the two
    -- options the non-warrior set defaults differently; the old show mode
    -- becomes each set's on switch. Other profiles' shout settings are
    -- dropped unread.
    do
        local store = self.db.global.shoutBar
        if not store.migrated then
            store.migrated = true
            local moved = {
                shoutBarPos = "pos", shoutBarAnchor = "anchor",
                shoutBarHideBackground = "hideBackground",
                shoutBarHideNumbers = "hideNumbers",
                shoutBarTimerSeconds = "timerSeconds",
                shoutBarIgnoreOutOfRange = "ignoreOutOfRange",
                shoutBarSoloShout = "soloShout",
                shoutBarHideWhenBuffed = "hideWhenBuffed",
                shoutBarIconSize = "iconSize", shoutBarGlowStyle = "glowStyle",
                shoutBarGlowMissingColor = "glowMissingColor",
                shoutBarGlowPartialColor = "glowPartialColor",
            }
            local keepDefault = {
                hideNumbers = true, hideWhenBuffed = true, timerSeconds = true,
                ignoreOutOfRange = true,
            }
            for old, new in pairs(moved) do
                local value = settings[old]
                if value ~= nil then
                    local copy = type(value) == "table" and CopyTable(value) or value
                    store.warrior[new] = copy
                    if not keepDefault[new] then
                        store.nonWarrior[new] = type(value) == "table"
                            and CopyTable(value) or value
                    end
                end
                settings[old] = nil
            end
            local mode = settings.shoutBarShow
            if mode == "never" then store.warrior.enabled = false end
            if mode == "withWarrior" or mode == "always" then
                store.nonWarrior.enabled = true
            end
            settings.shoutBarShow = nil
        end
    end
    -- Migrate the short-lived native minimap-button settings to LibDBIcon.
    if settings.showMinimapButton ~= nil then
        settings.minimapButton.hide = settings.showMinimapButton == false
        settings.showMinimapButton = nil
    end
    if settings.minimapButtonAngle ~= nil then
        settings.minimapButton.minimapPos = settings.minimapButtonAngle
        settings.minimapButtonAngle = nil
    end
    local statusChecks = settings.statusBarChecks
    if statusChecks.alive and not statusChecks.dead then
        statusChecks.dead = statusChecks.alive
    end
    statusChecks.alive = nil

    -- The PallyPower row now lives in Buff Tracking with the other ordered
    -- status rows. Preserve its two former Status Bars toggles once.
    if not statusChecks.pallyPower then
        statusChecks.pallyPower = {
            bar = settings.overviewShowPallyPower ~= false,
            hideWhenSynced = settings.overviewPallyPowerOnlyDesynced == true,
            hideWhenInactive = true,
            assignmentIssuesGlow = true,
        }
    end
    if not statusChecks.paladinBuffs then
        statusChecks.paladinBuffs = {
            hideComplete = settings.overviewHideCompleted == true,
        }
    end
    settings.overviewShowPallyPower = nil
    settings.overviewPallyPowerOnlyDesynced = nil
    settings.overviewHideCompleted = nil
    if settings.statusBarPaladinModel ~= 2 then
        local statusOrder = settings.statusBarOrder
        if statusOrder then
            local corrected = { "pallyPower", "paladinBuffs" }
            for _, key in ipairs(statusOrder) do
                if key ~= "pallyPower" and key ~= "paladinBuffs"
                    and key ~= "paladinBuffProgress" then
                    corrected[#corrected + 1] = key
                end
            end
            settings.statusBarOrder = corrected
        end
        statusChecks.paladinBuffProgress = nil
        settings.statusBarPaladinModel = 2
    end

    -- The Action Items row is new and belongs at the TOP. A saved
    -- statusBarOrder has no entry for it, and GetStatusBarCheckOrder appends
    -- unknown keys to the end -- which would bury the one row that says what
    -- still needs doing under every buff row. Runs once, keyed on the check
    -- having no saved options at all.
    if not statusChecks.actionItems then
        statusChecks.actionItems = { bar = true }
        if settings.statusBarOrder then
            table.insert(settings.statusBarOrder, 1, "actionItems")
        end
    end

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

    -- One-off cache wipe: the first buff-talent scanner matched icons against
    -- live GetTalentInfo returns, which don't compare equal to the library's
    -- static fileIDs for the local player -- locally-scanned paladins were
    -- saved as all-zero ranks ("untalented" Kings on a Kings paladin). Drop
    -- the poisoned cache; talent broadcasts and inspects repopulate it.
    if (self.db.profile.buffTalentScanVersion or 1) < 2 then
        self.db.profile.paladinBuffTalents = {}
        self.db.profile.buffTalentScanVersion = 2
    end

    -- One-off wipe: the buffing rules were reshaped (ignore/prioritize/prefer
    -- became a Salvation-only ignore, guarantee, and assign) and a saved rule
    -- of an old kind is silently inert. Rules are group-scoped and rebuilt in
    -- a few clicks, so they're dropped rather than guessed at. Deliberately
    -- not in the defaults table -- a fresh profile would then read as already
    -- migrated, which is true, but this has to fire for existing ones.
    if (self.db.profile.paladinBuffRuleVersion or 1) < 2 then
        if #self.db.profile.paladinBuffRules > 0 then
            self:Print("Buffing Rules have been rebuilt in this version;"
                .. " your saved rules were cleared. Add them again from"
                .. " Paladin Buffs > Buffing Rules > Add (+).")
        end
        wipe(self.db.profile.paladinBuffRules)
        self.db.profile.paladinBuffRuleVersion = 2
    end

    -- One-off id rewrite: custom-role ids came from a per-profile counter
    -- ("custom_3"), so two raiders each owned a "custom_1" standing for
    -- different roles. A custom role can now be published to the shared board
    -- under that id, which makes cross-client uniqueness a requirement rather
    -- than a nicety. Rewrite the saved ids along with everything pointing at
    -- them. Nothing group-scoped needs fixing up: the board is cleared on
    -- leave, and a stale saved assignment is dropped by the next housekeeping
    -- pass exactly as an unknown role always was.
    if (self.db.profile.customRoleIdVersion or 1) < 2 then
        local p = self.db.profile
        for _, cr in ipairs(p.customRoles) do
            if type(cr.id) == "string" and cr.id:match("^custom_%d+$") then
                local newId = self:NewCustomRoleId()
                -- Carry the old buff-order entry across too. It is dropped a
                -- few lines below, but only AFTER being folded into the role
                -- itself, and that fold matches on the new id.
                if p.roleCustomizations then
                    p.roleCustomizations[newId] = p.roleCustomizations[cr.id]
                    p.roleCustomizations[cr.id] = nil
                end
                for player, roleId in pairs(p.assignments) do
                    if roleId == cr.id then p.assignments[player] = newId end
                end
                for _, rule in ipairs(p.paladinBuffRules) do
                    if rule.scope == "role" and rule.value == cr.id then
                        rule.value = newId
                    end
                end
                self:LogUiBuilding("Custom role '" .. tostring(cr.name)
                    .. "' re-keyed " .. cr.id .. " -> " .. newId .. ".")
                cr.id = newId
            end
        end
        p.customRoleIdVersion = 2
    end

    -- One-off migration: buff orders for BUILT-IN roles used to be editable per
    -- profile (roleCustomizations), which is exactly how a raid ended up
    -- computing as many blessing plans as it had clients. Built-in roles are no
    -- longer editable at all -- they are overridden for the raid instead.
    --
    -- A custom role's entry still means something, though: custom roles own
    -- their whole definition now, so those fold into the role itself. Only the
    -- built-in ones are dropped, and only those are counted in the notice.
    if self.db.profile.roleCustomizations then
        local p = self.db.profile
        local byId = {}
        for _, cr in ipairs(p.customRoles) do byId[cr.id] = cr end
        local dropped = 0
        for roleId, saved in pairs(p.roleCustomizations) do
            local cr = byId[roleId]
            if cr and type(saved.buffOrder) == "table" then
                cr.order = saved.buffOrder
                cr.allowed = saved.allowedCount
            else
                dropped = dropped + 1
            end
        end
        if dropped > 0 then
            self:Print("Blessing orders for built-in roles are now shared with"
                .. " the raid; " .. dropped .. " saved customization"
                .. (dropped == 1 and " was" or "s were") .. " cleared."
                .. " Re-add them from Custom Roles > Add (+).")
        end
        p.roleCustomizations = nil
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

    -- Registers at PLAYER_LOGIN, which is when the minimap-manager addons do
    -- their own setup and can therefore see ours.
    self:ScheduleMinimapButtonInitialization()

    -- Inject our section into the unit right-click menus
    self:SetupUnitMenus()
end
