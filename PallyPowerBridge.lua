local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Bridge to the PallyPower addon: push our computed buff grid into it, and
-- eavesdrop on its addon-channel chatter for the log window and read-only
-- assignment mirror.
--
-- Sync (SyncToPallyPower): PallyPower's model is one Greater Blessing per
-- class per paladin, with per-player Normal-blessing exceptions layered on
-- top. Our grid is per-raider, so each paladin/class pair takes its majority
-- buff as the class assignment and the minority raiders ride along as Normal
-- exceptions -- the same shape PallyPower's own UI produces for a mixed
-- class. The tables (PallyPower_Assignments / PallyPower_NormalAssignments)
-- are written directly, then broadcast over PallyPower's own wire protocol
-- (CLEAR SKIP, then PASSIGN per paladin, then batched NASSIGN) through
-- PallyPower:SendMessage so its channel pick and throttling apply. Other
-- paladins' clients only accept assignments for someone besides the sender
-- when the sender is a raid leader/assist (or they run Free Assignment), so
-- the button warns when we push without that authority.
--
-- Log: every PLPWR message in or out lands in WhoDoesWhat.PallyPowerLog.
-- Outgoing is caught with a hooksecurefunc on ChatThrottleLib (all of
-- PallyPower's sends funnel through it, whispers included); incoming rides
-- CHAT_MSG_ADDON, skipping our own group-broadcast echo since the hook
-- already logged it. TranslatePallyPowerMessage turns the terse wire text
-- into a readable line for the log view (Views\PallyPowerLogView.lua).

local Bridge = WhoDoesWhat:NewModule("PallyPowerBridge", "AceEvent-3.0")

local PP_PREFIX = "PLPWR"
WhoDoesWhat.pallyPowerPeers = {}

function WhoDoesWhat:PaladinHasPallyPower(name)
    if name == UnitName("player") then return _G.PallyPower ~= nil end
    return self.pallyPowerPeers[name] == true
end

-- Ask PallyPower clients to identify themselves. Each paladin answers REQ
-- with SELF; CHAT_MSG_ADDON below records those replies for raider tooltips.
function WhoDoesWhat:RequestPallyPowerPeers()
    local channel
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        channel = "INSTANCE_CHAT"
    elseif IsInRaid() then
        channel = "RAID"
    elseif IsInGroup() then
        channel = "PARTY"
    end
    if channel and C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PP_PREFIX, "REQ", channel)
    end
end

-- ---------------------------------------------------------------------------
-- Id mapping
-- ---------------------------------------------------------------------------

-- Our buff keys -> PallyPower blessing ids. Wrath collapsed Salvation and
-- Light out of the game, so its id table is shorter and those keys don't map.
local BLESSING_ID = {
    wisdom = 1, might = 2, kings = 3, salv = 4, light = 5, sanctuary = 6,
}
local BLESSING_ID_WRATH = {
    wisdom = 1, might = 2, kings = 3, sanctuary = 4,
}

-- PallyPower's wire ids for the current client. These belong to the protocol,
-- not the co-installed addon: the observed-board view must work without its
-- globals. Era uses slot 9 for pets; TBC uses it for Shamans.
local IS_WRATH = WOW_PROJECT_WRATH_CLASSIC
    and WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC
local IS_ERA = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
local PP_MAX_CLASSES = IS_WRATH and 10 or 9
local PP_CLASS_ID = {
    Warrior = 1, Rogue = 2, Priest = 3, Druid = 4, Paladin = 5,
    Hunter = 6, Mage = 7, Warlock = 8,
}
if IS_WRATH then
    PP_CLASS_ID.Shaman = 9
    PP_CLASS_ID.DeathKnight = 10
elseif IS_ERA then
    PP_CLASS_ID.Pet = 9
elseif not IS_ERA then
    PP_CLASS_ID.Shaman = 9
end

-- Short display names by blessing id, for the log translations.
local BLESSING_NAME = {
    "Wisdom", "Might", "Kings", "Salvation", "Light", "Sanctuary", "Sacrifice", "Horn",
}
local BLESSING_NAME_WRATH = { "Wisdom", "Might", "Kings", "Sanctuary" }

local function BuffKeyToBlessingId(key)
    local pp = _G.PallyPower
    if pp and pp.isWrath then return BLESSING_ID_WRATH[key] end
    return BLESSING_ID[key]
end

local function BlessingIdToBuffKey(id)
    id = tonumber(id)
    if not id or id == 0 then return nil end
    local map = IS_WRATH and BLESSING_ID_WRATH or BLESSING_ID
    for key, value in pairs(map) do
        if value == id then return key end
    end
end

local function BlessingName(id)
    id = tonumber(id)
    if not id or id == 0 then return "none" end
    local pp = _G.PallyPower
    local names = (pp and pp.isWrath) and BLESSING_NAME_WRATH or BLESSING_NAME
    return names[id] or ("blessing " .. id)
end

-- Blessing id -> our buff key (invert whichever id table is live), and from
-- there the icon in Data.lua -- for the diff view's blessing icons. Nil for 0
-- ("none") or an id this client doesn't map.
local function BlessingIcon(id)
    id = tonumber(id)
    if not id or id == 0 then return nil end
    local pp = _G.PallyPower
    local map = (pp and pp.isWrath) and BLESSING_ID_WRATH or BLESSING_ID
    for key, v in pairs(map) do
        if v == id then
            local buff = WhoDoesWhat.PaladinBuffs and WhoDoesWhat.PaladinBuffs[key]
            return buff and buff.iconId
        end
    end
end

-- "WARRIOR" -> "Warrior" via PallyPower's class-id table; falls back to the
-- raw number so a foreign id still reads.
local function ClassIdName(id)
    id = tonumber(id)
    local pp = _G.PallyPower
    local token = pp and pp.ClassID and pp.ClassID[id]
    if not token then return "class " .. tostring(id) end
    return token:sub(1, 1) .. token:sub(2):lower()
end

-- PallyPower keys everything by realm-stripped names.
local function ShortName(name)
    return name and name:match("^([^%-]+)") or name
end

-- The wire mirror is deliberately session-only. REQ/SELF reconstructs it
-- from the PallyPower clients currently in the group.
local observedBoard = { assignments = {}, normal = {} }
WhoDoesWhat.PallyPowerMirror = observedBoard

local function SenderCanAssignOthers(sender)
    sender = ShortName(sender)
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name, rank = GetRaidRosterInfo(i)
            if name and ShortName(name) == sender then return rank and rank > 0 end
        end
    elseif IsInGroup() then
        local units = { "player" }
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
        for _, unit in ipairs(units) do
            if ShortName(GetUnitName(unit, true)) == sender then
                return UnitIsGroupLeader(unit)
            end
        end
    end
    return false
end

local function SetClassRow(board, name, row)
    name = ShortName(name)
    board.assignments[name] = {}
    for classId = 1, PP_MAX_CLASSES do
        local value = row:sub(classId, classId)
        board.assignments[name][classId] = tonumber(value) or 0
    end
end

local function CanApplyAssignment(sender, paladin, senderHasAuthority)
    return ShortName(sender) == ShortName(paladin) or senderHasAuthority
end

-- Apply only the PLPWR messages that can change the blessing grid. Aura,
-- cooldown, symbol, and UI messages are intentionally outside this mirror.
local function ApplyPallyPowerMessage(board, sender, message, authorityOverride)
    sender = ShortName(sender)
    local senderHasAuthority = authorityOverride
    if senderHasAuthority == nil then
        senderHasAuthority = SenderCanAssignOthers(sender)
    end

    local selfRow = message:match("^SELF [0-9a-fn]*@([0-9n]*)")
    if selfRow then
        SetClassRow(board, sender, selfRow)
        -- SendSelf follows SELF with every current NASSIGN row, so discard the
        -- previous exceptions before that authoritative replay arrives.
        board.normal[sender] = {}
        return true
    end

    local paladin, row = message:match("^PASSIGN (%S+)@([0-9n]*)")
    if paladin and CanApplyAssignment(sender, paladin, senderHasAuthority) then
        SetClassRow(board, paladin, row)
        return true
    end

    local classId, blessing
    paladin, classId, blessing = message:match("^ASSIGN (%S+) (%d+) (%d+)")
    if paladin and CanApplyAssignment(sender, paladin, senderHasAuthority) then
        paladin, classId = ShortName(paladin), tonumber(classId)
        board.assignments[paladin] = board.assignments[paladin] or {}
        board.assignments[paladin][classId] = tonumber(blessing) or 0
        return true
    end

    paladin, blessing = message:match("^MASSIGN (%S+) (%d+)")
    if paladin and CanApplyAssignment(sender, paladin, senderHasAuthority) then
        local rowText = string.rep(tostring(tonumber(blessing) or 0), PP_MAX_CLASSES)
        SetClassRow(board, paladin, rowText)
        return true
    end

    local body = message:match("^NASSIGN (.+)")
    if body then
        local changed = false
        for pname, cid, target, value in
            body:gmatch("([^@ ]+) ([^@ ]+) ([^@ ]+) ([^@ ]+)") do
            if CanApplyAssignment(sender, pname, senderHasAuthority) then
                pname, cid = ShortName(pname), tonumber(cid)
                value = tonumber(value)
                if cid and value then
                    board.normal[pname] = board.normal[pname] or {}
                    board.normal[pname][cid] = board.normal[pname][cid] or {}
                    board.normal[pname][cid][ShortName(target)] = value ~= 0
                        and value or nil
                    changed = true
                end
            end
        end
        return changed
    end

    if message:find("^CLEAR") and senderHasAuthority then
        wipe(board.assignments)
        wipe(board.normal)
        return true
    end
    return false
end

-- The fake testing roster must never leak onto the wire; PallyPower is real
-- even when our raid isn't.
local function IsFakeName(name)
    if not (WhoDoesWhat.FakeRaid and WhoDoesWhat:IsFakeRaidEnabled()) then
        return false
    end
    for _, fm in ipairs(WhoDoesWhat.FakeRaid.ROSTER) do
        if fm.name == name then return true end
    end
    return false
end

-- PallyPower accepts assignments for other paladins only from the group
-- leader/raid assistants (unless each receiver opted into Free Assignment).
-- Do not mutate our local PallyPower tables and pretend a rejected broadcast
-- succeeded. Non-authority WDW edits are relayed by the WDW leader in Sync.lua.
local function CanBroadcastAssignments()
    if not IsInGroup() then return true end
    if IsInRaid() then return WhoDoesWhat:IsRaidAssistant() end
    return UnitIsGroupLeader("player")
end

-- ---------------------------------------------------------------------------
-- Sync: grid -> PallyPower
-- ---------------------------------------------------------------------------

-- The grid's paladin columns, minus the fake testing roster.
local function GroupPaladins(self)
    local paladins = {}
    for _, m in ipairs(self:GetGroupMembers("Paladin")) do
        if m.classInfo.name == "Paladin" and not IsFakeName(m.name) then
            paladins[#paladins + 1] = m.name
        end
    end
    return paladins
end

-- owner name -> live pet name. Pet identities can arrive after the group
-- roster, so both the sync builder and the late-identification watcher use
-- this same resolver.
local function LivePetNames()
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            units[#units + 1] = { owner = "raid" .. i, pet = "raidpet" .. i }
        end
    else
        units[#units + 1] = { owner = "player", pet = "pet" }
        for i = 1, GetNumSubgroupMembers() do
            units[#units + 1] = { owner = "party" .. i, pet = "partypet" .. i }
        end
    end

    local names = {}
    for _, u in ipairs(units) do
        if UnitExists(u.pet) then
            local owner = GetUnitName(u.owner, true)
            local petName = GetUnitName(u.pet, true)
            if owner and petName then names[owner] = petName end
        end
    end
    return names
end

-- Keep dismissed pet names recognizable in later comparisons: PallyPower can
-- retain their Normal rows after the unit token disappears.
local seenPetNames = {}

-- Convert either the observed wire board or the co-installed addon's live
-- tables into the same plan shape consumed by Views/BuffingGridView.lua.
local function BoardToBuffPlan(self, assignments, normal)
    local plan = { grid = {}, greaterByPaladin = {}, targetClass = {} }
    local paladins = self:GetGroupMembers("Paladin")

    for _, paladin in ipairs(paladins) do
        if paladin.classInfo.name == "Paladin" then
            local pshort = ShortName(paladin.name)
            local row = assignments[pshort] or {}
            local greater = {}
            for className, classId in pairs(PP_CLASS_ID) do
                greater[className] = BlessingIdToBuffKey(row[classId])
            end
            plan.greaterByPaladin[paladin.name] = greater
        end
    end

    local function AddTarget(displayName, className, wireName)
        local classId = PP_CLASS_ID[className]
        local cells = {}
        plan.grid[displayName] = cells
        plan.targetClass[displayName] = className
        if not classId then return end

        for _, paladin in ipairs(paladins) do
            if paladin.classInfo.name == "Paladin" then
                local pshort = ShortName(paladin.name)
                local row = assignments[pshort] or {}
                local exceptions = normal[pshort] and normal[pshort][classId]
                local blessing = wireName and exceptions
                    and (exceptions[ShortName(wireName)] or exceptions[wireName]) or nil
                if not blessing or blessing == 0 then blessing = row[classId] end
                local key = BlessingIdToBuffKey(blessing)
                if key then cells[paladin.name] = key end
            end
        end
    end

    for _, member in ipairs(self:GetGroupMembers(nil)) do
        if not self:IsNonRaider(member.name) then
            AddTarget(member.name, member.classInfo.name, member.name)
        end
    end

    local petNames = LivePetNames()
    for _, pet in ipairs(self.Assign.GetPetMembers()) do
        AddTarget(pet.name, IS_ERA and "Pet" or "Warrior", petNames[pet.owner])
    end
    return plan
end

-- source: "observed" for WDW's wire mirror, "addon" for PallyPower's live
-- globals. Returns nil only when the requested co-installed addon is absent.
function WhoDoesWhat:GetPallyPowerBuffPlan(source)
    if source == "addon" then
        if not (_G.PallyPower and _G.PallyPower_Assignments
            and _G.PallyPower_NormalAssignments) then return nil end
        return BoardToBuffPlan(self, PallyPower_Assignments,
            PallyPower_NormalAssignments)
    end
    return BoardToBuffPlan(self, observedBoard.assignments, observedBoard.normal)
end

-- Small parser check, callable through LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat").
function WhoDoesWhat:TestPallyPowerMirror()
    local board = { assignments = {}, normal = {} }
    assert(ApplyPallyPowerMessage(board, "Alice", "SELF nnnnnn@3n2nnnnnn", false))
    assert(board.assignments.Alice[1] == 3 and board.assignments.Alice[3] == 2)
    assert(ApplyPallyPowerMessage(board, "Alice",
        "NASSIGN Alice 1 Bob 2@Alice 1 Cara 0", false))
    assert(board.normal.Alice[1].Bob == 2 and board.normal.Alice[1].Cara == nil)
    assert(not ApplyPallyPowerMessage(board, "Bob", "PASSIGN Alice@111111111", false))
    self:Print("PallyPower mirror parser check passed.")
end

-- Compute the PallyPower assignment tables our grid implies, WITHOUT touching
-- the live globals or the wire: majority buff per paladin/class becomes the
-- class (Greater) assignment, and dissenters ride along as Normal exceptions.
-- The assignment model supplies the shared Greater decision, including the
-- Warrior bucket inherited by pets. This is the single source of truth for
-- "what a full sync would write" -- SyncToPallyPower copies the result into
-- the live tables and broadcasts it, and CheckPallyPowerSync compares the
-- live tables against it. Returns
-- assignments[pshort][classId], normal[pshort][classId][target], the summary
-- counts, plus each active PallyPower target's class id.
local function BuildDesired(self, pp, paladins)
    local assignments, normal = {}, {}

    -- Raider -> PallyPower class id. Classes PallyPower doesn't track on this
    -- client (vanilla PallyPower has no Shaman slot, say) just get skipped.
    local classIdOf, activeTargets = {}, {}
    for _, m in ipairs(self:GetGroupMembers(nil)) do
        if not IsFakeName(m.name) then
            local cid = pp.ClassToID and pp.ClassToID[m.classInfo.name:upper()]
            classIdOf[m.name] = cid
            if cid and not self:IsNonRaider(m.name) then
                activeTargets[ShortName(m.name)] = cid
            end
        end
    end

    -- Virtual pets use PallyPower's Warrior bucket. Matching pets inherit that
    -- class Greater; only dissenters need a named Normal exception.
    local petOwner = {}
    for _, pet in ipairs(self.Assign.GetPetMembers()) do
        if not IsFakeName(pet.owner) then
            petOwner[pet.name] = pet.owner
        end
    end
    local petRealName = LivePetNames()
    local petClassId = pp.ClassToID and pp.ClassToID["WARRIOR"]

    local buffPlan = self.Assign.GetPaladinBuffPlan()
    local plan = buffPlan.grid
    local classCount, singleCount, skipped = 0, 0, 0
    for _, pname in ipairs(paladins) do
        local pshort = ShortName(pname)
        assignments[pshort] = {}
        for c = 1, PALLYPOWER_MAXCLASSES do
            assignments[pshort][c] = 0
        end
        normal[pshort] = {}

        for className, buffKey in pairs(buffPlan.greaterByPaladin[pname] or {}) do
            local cid = pp.ClassToID and pp.ClassToID[className:upper()]
            local bless = BuffKeyToBlessingId(buffKey)
            if cid and bless then
                assignments[pshort][cid] = bless
                classCount = classCount + 1
            else
                skipped = skipped + 1
            end
        end
    end

    -- Add only targets whose cell differs from their shared class Greater.
    for raider, cells in pairs(plan) do
        local owner = petOwner[raider]
        local cid = owner and petClassId or classIdOf[raider]
        local target = owner and ShortName(petRealName[owner]) or ShortName(raider)
        if owner and target and cid then activeTargets[target] = cid end
        for paladin, buffKey in pairs(cells) do
            local pshort = ShortName(paladin)
            local bless = BuffKeyToBlessingId(buffKey)
            if not IsFakeName(paladin) and assignments[pshort] then
                if cid and bless then
                    local greater = assignments[pshort][cid]
                    if bless ~= greater then
                        if target then
                            normal[pshort][cid] = normal[pshort][cid] or {}
                            normal[pshort][cid][target] = bless
                            singleCount = singleCount + 1
                        else
                            skipped = skipped + 1
                        end
                    end
                else
                    skipped = skipped + 1
                end
            end
        end
    end

    return assignments, normal, classCount, singleCount, skipped,
        activeTargets
end

function WhoDoesWhat:SyncToPallyPower()
    local pp = _G.PallyPower
    if not (pp and _G.PallyPower_Assignments and _G.PallyPower_NormalAssignments) then
        self:Print("PallyPower is not loaded; nothing to sync to.")
        return
    end

    local paladins = GroupPaladins(self)
    if #paladins == 0 then
        self:Print("No paladins in the group; nothing to sync to PallyPower.")
        return
    end

    local assignments, normal, classCount, singleCount, skipped =
        BuildDesired(self, pp, paladins)

    -- Copy the computed rows into the live tables (only the group paladins'
    -- rows, the scope BuildDesired filled) so the broadcast below reads them
    -- back out.
    for _, pname in ipairs(paladins) do
        local pshort = ShortName(pname)
        PallyPower_Assignments[pshort] = assignments[pshort]
        PallyPower_NormalAssignments[pshort] = normal[pshort]
    end

    -- Broadcast over PallyPower's own protocol, in its LoadPreset rhythm:
    -- reset everyone (SKIP keeps auras), give the tables a beat to land, then
    -- the full class rows and the exception batches. SendMessage no-ops solo,
    -- so a solo click still fills the local PallyPower for inspection.
    pp:SendMessage("CLEAR SKIP")
    C_Timer.After(0.25, function()
        for _, pname in ipairs(paladins) do
            local pshort = ShortName(pname)
            local s = ""
            for c = 1, PALLYPOWER_MAXCLASSES do
                local v = PallyPower_Assignments[pshort][c]
                s = s .. ((not v or v == 0) and "n" or v)
            end
            pp:SendMessage("PASSIGN " .. pshort .. "@" .. s)
        end

        local entries = {}
        for _, pname in ipairs(paladins) do
            local pshort = ShortName(pname)
            for cid, tnames in pairs(PallyPower_NormalAssignments[pshort]) do
                for tname, bless in pairs(tnames) do
                    entries[#entries + 1] =
                        string.format("%s %s %s %s", pshort, cid, tname, bless)
                end
            end
        end
        for offset = 1, #entries, 5 do
            pp:SendMessage("NASSIGN "
                .. table.concat(entries, "@", offset, math.min(offset + 4, #entries)))
        end

        pp:UpdateLayout()
    end)

    local summary = "Synced " .. #paladins .. " paladin(s) to PallyPower: "
        .. classCount .. " class blessing(s), " .. singleCount .. " individual exception(s)."
    if skipped > 0 then
        summary = summary .. " " .. skipped
            .. " cell(s) skipped (unresolved pet, class, or blessing)."
        self:Print(summary)
    else
        self:LogOperation(summary)
    end

    -- Their clients reject rows for anyone but the sender without authority.
    if IsInRaid() and not self:IsRaidAssistant() then
        self:Print("|cffff6060Heads up:|r you are not raid lead/assist, so other"
            .. " paladins' PallyPower will only accept these if they enabled"
            .. " Free Assignment.")
    end
end

-- Read-only drift check: does PallyPower give every active target the blessing
-- the current WDW plan wants? Compare effective blessings after Normal
-- overrides rather than the raw Greater/Normal table shape: the same coverage
-- can have several valid encodings, especially after one raider changes role.
-- Real coverage drift still surfaces as a warning icon + a Check window and
-- lets the user Send the canonical full plan when ready. Returns structured
-- difference entries for the diff view (empty = in sync):
--   { paladin, target, targetIcon, targetRole, isClass, want, wantName,
--     wantIcon, have, haveName, haveIcon }
-- want/have are blessing ids (0 = none).
-- Returns nil plus "not-loaded" or "no-paladins" when there's nothing to
-- compare. Existing callers that only read the first result remain unchanged.
local function DiffEntry(pshort, target, isClass, want, have, targetInfo)
    return {
        paladin = pshort, target = target, isClass = isClass,
        targetIcon = targetInfo and targetInfo.icon,
        targetRole = targetInfo and targetInfo.role,
        want = want, wantName = BlessingName(want), wantIcon = BlessingIcon(want),
        have = have, haveName = BlessingName(have), haveIcon = BlessingIcon(have),
    }
end

-- Icons/labels used by the comparison view. Keep this sourced from Data.lua;
-- current or previously seen hunter pets use the pet pseudo-role.
local function DiffTargetInfo(self)
    local targets, pets = {}, {}
    for _, m in ipairs(self:GetGroupMembers(nil)) do
        local roleId = self:GetAssignedRole(m.name)
        local role = roleId and self.RolesAndCategories[roleId]
        targets[ShortName(m.name)] = {
            icon = (role and role.icon) or m.classInfo.classIcon,
            role = role and role.name or (m.classInfo.name .. " (unassigned)"),
        }
    end
    local petNames = {}
    for petName in pairs(seenPetNames) do petNames[petName] = true end
    for _, petName in pairs(LivePetNames()) do
        local short = ShortName(petName)
        seenPetNames[short] = true
        petNames[short] = true
    end
    for petName in pairs(petNames) do
        if not targets[petName] then
            targets[petName] = {
                icon = self.HunterPetRole.icon,
                role = self.HunterPetRole.name,
            }
        end
        pets[petName] = true
    end
    return targets, pets
end

function WhoDoesWhat:CheckPallyPowerSync()
    local pp = _G.PallyPower
    if not (pp and _G.PallyPower_Assignments and _G.PallyPower_NormalAssignments) then
        return nil, "not-loaded"
    end
    local paladins = GroupPaladins(self)
    if #paladins == 0 then return nil, "no-paladins" end

    local assignments, normal, _, _, _, activeTargets =
        BuildDesired(self, pp, paladins)
    local targetInfo, petTargets = DiffTargetInfo(self)
    local might = BuffKeyToBlessingId("might")
    local kings = BuffKeyToBlessingId("kings")
    local diffs = {}
    for _, pname in ipairs(paladins) do
        local pshort = ShortName(pname)
        local liveA = PallyPower_Assignments[pshort] or {}
        local wantA = assignments[pshort] or {}
        local liveN = PallyPower_NormalAssignments[pshort] or {}
        local wantN = normal[pshort] or {}
        for target, cid in pairs(activeTargets) do
            local want = wantN[cid] and wantN[cid][target]
            if not want or want == 0 then want = wantA[cid] or 0 end
            local live = liveN[cid] and liveN[cid][target]
            if not live or live == 0 then live = liveA[cid] or 0 end

            -- Pet identities and rows are transient. None/Might/Kings are all
            -- safe; only an explicit unrelated blessing needs intervention.
            local acceptedPetBuff = petTargets[target]
                and (live == 0 or live == might or live == kings)
            if want ~= live and not acceptedPetBuff then
                diffs[#diffs + 1] = DiffEntry(pshort, target, false, want, live,
                    targetInfo[target])
            end
        end
    end
    return diffs
end

-- Minimal per-player push for a single raider's role change (e.g. mid-combat
-- Feral DPS -> Feral Tank, now wanting Salvation removed). PallyPower's
-- NASSIGN message can set or clear one paladin/class/target Normal-blessing
-- override, so a safe change is at most one row per paladin.
--
-- Safety: `priorDiffs` is CheckPallyPowerSync's result from BEFORE the role
-- mutation. We auto-send only from an aligned board and only when the changed
-- raider's effective blessings moved. A role change can alter raid-wide
-- demand/primaries, and an already-drifted PallyPower board is a bad baseline;
-- either case leaves PallyPower untouched for the passive status UI to report.
-- Combat-safe: PallyPower parses NASSIGN in combat and refreshes its protected
-- layout after combat.
function WhoDoesWhat:PushPlayerBuffToPallyPower(playerName, priorDiffs)
    local pp = _G.PallyPower
    if not (pp and _G.PallyPower_Assignments and _G.PallyPower_NormalAssignments) then
        return
    end
    if not playerName or IsFakeName(playerName) then return end
    if not CanBroadcastAssignments() then return end

    local diffs = self:CheckPallyPowerSync()
    if not diffs or #diffs == 0 then return end

    local xshort = ShortName(playerName)
    local broad = 0
    for _, d in ipairs(diffs) do
        if d.isClass or d.target ~= xshort then
            broad = broad + 1
        end
    end
    if (priorDiffs and #priorDiffs > 0) or broad > 0 then
        return
    end

    -- The raider's class id, as PallyPower keys it. Untracked classes (no
    -- Shaman slot on vanilla PallyPower, say) have nothing to push.
    local member
    for _, m in ipairs(self:GetGroupMembers(nil)) do
        if m.name == playerName then member = m break end
    end
    if not member then return end
    local classId = pp.ClassToID and pp.ClassToID[member.classInfo.name:upper()]
    if not classId then return end

    -- This raider's blessing per paladin from the current shared plan (empty
    -- when uncovered, e.g. after being marked Non-raider).
    local cells = self.Assign.ComputeBuffGrid()[playerName] or {}

    local entries = {}
    for _, m in ipairs(self:GetGroupMembers("Paladin")) do
        if m.classInfo.name == "Paladin" and not IsFakeName(m.name) then
            local pshort = ShortName(m.name)
            local newBless = BuffKeyToBlessingId(cells[m.name]) -- nil if uncovered
            local greater = PallyPower_Assignments[pshort]
                and PallyPower_Assignments[pshort][classId]
            -- Want an exception only when this raider differs from the class row.
            local desired = (newBless and newBless ~= 0 and newBless ~= greater)
                and newBless or nil

            local bucket = PallyPower_NormalAssignments[pshort]
            local current = bucket and bucket[classId] and bucket[classId][xshort]

            if desired ~= current then
                -- Mirror into the local tables so the sender's own PallyPower
                -- and the next diff stay in step (nil clears the exception).
                PallyPower_NormalAssignments[pshort] = PallyPower_NormalAssignments[pshort] or {}
                PallyPower_NormalAssignments[pshort][classId] =
                    PallyPower_NormalAssignments[pshort][classId] or {}
                PallyPower_NormalAssignments[pshort][classId][xshort] = desired
                entries[#entries + 1] =
                    string.format("%s %s %s %s", pshort, classId, xshort, desired or 0)
            end
        end
    end

    if #entries == 0 then return end

    for offset = 1, #entries, 5 do
        pp:SendMessage("NASSIGN "
            .. table.concat(entries, "@", offset, math.min(offset + 4, #entries)))
    end
    pp:UpdateLayout() -- self-guards in combat; refreshes the sender's grid otherwise
end

-- ---------------------------------------------------------------------------
-- The PLPWR traffic log
-- ---------------------------------------------------------------------------

local MAX_LOG = 500
local log = {}
WhoDoesWhat.PallyPowerLog = log
local statusRefreshPending

local function Append(dir, who, msg)
    local trimmed = false
    if #log >= MAX_LOG then
        -- Shed the oldest chunk in one go so the shift isn't per-message.
        for _ = 1, 100 do table.remove(log, 1) end
        trimmed = true
    end
    local entry = { t = date("%H:%M:%S"), dir = dir, who = who, msg = msg }
    log[#log + 1] = entry
    if WhoDoesWhat.PallyPowerLogAppended then
        WhoDoesWhat:PallyPowerLogAppended(entry, trimmed)
    end
    if not statusRefreshPending and WhoDoesWhat.RefreshStatusBarsView then
        statusRefreshPending = true
        C_Timer.After(0.1, function()
            statusRefreshPending = nil
            WhoDoesWhat:RefreshStatusBarsView()
            WhoDoesWhat:RefreshMainAssignmentsView()
        end)
    end
end

-- Decode a PASSIGN/SELF-style per-class blessing string ("3n2n...") into
-- "Warrior=Kings, Priest=Wisdom, ...".
local function DecodeClassRow(s)
    local parts = {}
    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch ~= "n" and ch ~= "0" then
            parts[#parts + 1] = ClassIdName(i) .. "=" .. BlessingName(ch)
        end
    end
    if #parts == 0 then return "nothing assigned" end
    return table.concat(parts, ", ")
end

local function AuraName(id)
    id = tonumber(id)
    if not id or id == 0 then return "none" end
    local pp = _G.PallyPower
    local name = pp and pp.Auras and pp.Auras[id]
    return (name and name ~= "") and name or ("aura " .. id)
end

-- One readable line per wire message. Anything unrecognized falls through
-- as the raw text so nothing is ever hidden.
function WhoDoesWhat:TranslatePallyPowerMessage(msg)
    if msg == "REQ" then
        return "asks everyone to report their status"
    end

    local name = msg:match("^PPLEADER (.+)")
    if name then
        return "announces " .. ShortName(name) .. " as a PallyPower leader"
    end

    local assign = msg:match("^SELF [0-9a-fn]*@([0-9n]*)")
    if assign then
        return "reports own blessings; class row: " .. DecodeClassRow(assign)
    end

    local aura = msg:match("^ASELF [0-9a-fn]*@([0-9n]*)")
    if aura then
        return "reports own auras (assigned aura: " .. AuraName(aura) .. ")"
    end

    local p, s = msg:match("^PASSIGN (%S+)@(%S+)")
    if p then
        return "sets " .. p .. "'s full class row: " .. DecodeClassRow(s)
    end

    local p2, c2, b2 = msg:match("^ASSIGN (%S+) (%S+) (%S+)")
    if p2 then
        return "sets " .. p2 .. ": " .. ClassIdName(c2) .. " -> " .. BlessingName(b2)
    end

    local p3, b3 = msg:match("^MASSIGN (%S+) (%S+)")
    if p3 then
        return "sets " .. p3 .. ": ALL classes -> " .. BlessingName(b3)
    end

    local body = msg:match("^NASSIGN (.+)")
    if body then
        local parts = {}
        for pn, cid, tn, bless in body:gmatch("([^@]*) ([^@]*) ([^@]*) ([^@]*)") do
            if tonumber(bless) == 0 then
                parts[#parts + 1] = pn .. " stops single-buffing " .. tn
            else
                parts[#parts + 1] = pn .. " single-buffs " .. tn .. " ("
                    .. ClassIdName(cid) .. ") with " .. BlessingName(bless)
            end
        end
        return "normal blessings: " .. table.concat(parts, "; ")
    end

    local p4, a4 = msg:match("^AASSIGN (%S+) (%S+)")
    if p4 then
        return "sets " .. p4 .. "'s aura -> " .. AuraName(a4)
    end

    if msg:find("^CLEAR") then
        return msg:find("SKIP") and "clears all blessing assignments (auras kept)"
            or "clears ALL assignments"
    end

    local free = msg:match("FREEASSIGN (%u+)")
    if free then
        local sym = msg:match("SYMCOUNT (%d+)")
        return "free-assign " .. (free == "YES" and "ON" or "OFF")
            .. (sym and (", " .. sym .. " symbol(s) in bags") or "")
            .. ", cooldown info"
    end

    return msg
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

local knownPetNames = {}
local petCheckPending = false
local mirrorRefreshPending = false

local function QueueMirrorRefresh()
    if mirrorRefreshPending then return end
    mirrorRefreshPending = true
    C_Timer.After(0.1, function()
        mirrorRefreshPending = false
        WhoDoesWhat:RefreshBuffingGridView()
    end)
end

function Bridge:OnEnable()
    -- Without PallyPower loaded nobody registered the prefix, and unregistered
    -- prefixes never reach CHAT_MSG_ADDON -- register it so the log observes
    -- other paladins' traffic either way.
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PP_PREFIX)
    end

    self:RegisterEvent("CHAT_MSG_ADDON")
    self:RegisterEvent("UNIT_PET", "PetRosterChanged")
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "PetRosterChanged")
    knownPetNames = LivePetNames()
    for _, petName in pairs(knownPetNames) do
        seenPetNames[ShortName(petName)] = true
    end

    -- Outgoing side: everything PallyPower sends (whispers included) goes
    -- through the shared ChatThrottleLib singleton. All addons finished
    -- loading before OnEnable, so the winning library revision is final and
    -- the hook can't be replaced out from under us.
    if _G.ChatThrottleLib then
        hooksecurefunc(_G.ChatThrottleLib, "SendAddonMessage",
            function(_, _, prefix, text, chattype, target)
                if prefix == PP_PREFIX then
                    if ApplyPallyPowerMessage(observedBoard, UnitName("player"), text) then
                        QueueMirrorRefresh()
                    end
                    Append("out", target and ("whisper:" .. ShortName(tostring(target)))
                        or (chattype or "GROUP"), text)
                end
            end)
    end
end

-- Refresh the passive plan/status UI when a pet identity appears or disappears.
function Bridge:PetRosterChanged()
    if petCheckPending then return end
    petCheckPending = true
    C_Timer.After(0.25, function()
        petCheckPending = false
        if not IsInGroup()
            and (next(observedBoard.assignments) or next(observedBoard.normal)) then
            wipe(observedBoard.assignments)
            wipe(observedBoard.normal)
            QueueMirrorRefresh()
        end
        local live = LivePetNames()
        local changed = false
        for owner, petName in pairs(live) do
            if knownPetNames[owner] ~= petName then
                changed = true
            end
            seenPetNames[ShortName(petName)] = true
        end
        for owner in pairs(knownPetNames) do
            if not live[owner] then changed = true break end
        end
        knownPetNames = live
        if changed then
            WhoDoesWhat:RefreshMainAssignmentsView()
            WhoDoesWhat:RefreshBuffingGridView()
        end
    end)
end

function Bridge:CHAT_MSG_ADDON(_, prefix, message, _, sender)
    if prefix ~= PP_PREFIX then return end
    local who = Ambiguate(sender, "none")
    if who == UnitName("player") then return end -- own echo; the send hook logged it
    if ApplyPallyPowerMessage(observedBoard, who, message) then
        QueueMirrorRefresh()
    end
    if message:find("^SELF ") then
        WhoDoesWhat.pallyPowerPeers[who] = true
    end
    Append("in", who, message)
end
