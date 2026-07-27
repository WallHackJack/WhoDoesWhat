local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Bridge to the PallyPower addon: push our computed buff grid into it, and
-- eavesdrop on its addon-channel chatter for the log window.
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
-- with SELF; CHAT_MSG_ADDON below records those replies for the info pane.
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

-- Compute the PallyPower assignment tables our grid implies, WITHOUT touching
-- the live globals or the wire: majority buff per paladin/class becomes the
-- class (Greater) assignment, dissenters and hunter pets ride along as Normal
-- exceptions. This is the single source of truth for "what a full sync would
-- write" -- SyncToPallyPower copies the result into the live tables and
-- broadcasts it, and CheckPallyPowerSync compares the live tables against it
-- (with the pet tolerance documented below). Returns
-- assignments[pshort][classId], normal[pshort][classId][target] and the
-- summary counts.
local function BuildDesired(self, pp, paladins)
    local assignments, normal = {}, {}

    -- Raider -> PallyPower class id. Classes PallyPower doesn't track on this
    -- client (vanilla PallyPower has no Shaman slot, say) just get skipped.
    local classIdOf = {}
    for _, m in ipairs(self:GetGroupMembers(nil)) do
        if not IsFakeName(m.name) then
            classIdOf[m.name] = pp.ClassToID and pp.ClassToID[m.classInfo.name:upper()]
        end
    end

    -- The virtual pet rows (one per hunter, Assignments.lua). A hunter pet is
    -- a SEPARATE blessing target -- the owner's class-wide Greater Blessing
    -- never reaches it -- so pets take no part in any class-greater tally
    -- below. Each is instead pushed as its own single-target Normal blessing,
    -- keyed by the pet's real unit name (resolved from the live pet units) and
    -- filed under the class id this client lists pets under (Warrior). Pets we
    -- can't name (out of range) and fake hunters' pets are skipped.
    local petOwner = {}
    for _, pet in ipairs(self.Assign.GetPetMembers()) do
        if not IsFakeName(pet.owner) then
            petOwner[pet.name] = pet.owner
        end
    end
    local petRealName = LivePetNames()
    local petClassId = pp.ClassToID and pp.ClassToID["WARRIOR"]

    -- Tally the grid per paladin/class: votes[pallyShort][classId][blessId]
    -- counts raiders, buffOf remembers each raider's exact cell for the
    -- exception pass.
    local plan = self.Assign.ComputeBuffGrid()
    local votes, buffOf = {}, {}
    local skipped = 0
    for raider, cells in pairs(plan) do
        if not petOwner[raider] then
            local cid = classIdOf[raider]
            for paladin, buffKey in pairs(cells) do
                local pshort = ShortName(paladin)
                local bless = BuffKeyToBlessingId(buffKey)
                if cid and bless and not IsFakeName(paladin) then
                    votes[pshort] = votes[pshort] or {}
                    votes[pshort][cid] = votes[pshort][cid] or {}
                    votes[pshort][cid][bless] = (votes[pshort][cid][bless] or 0) + 1
                    buffOf[pshort] = buffOf[pshort] or {}
                    buffOf[pshort][cid] = buffOf[pshort][cid] or {}
                    buffOf[pshort][cid][ShortName(raider)] = bless
                elseif not IsFakeName(paladin) then
                    skipped = skipped + 1
                end
            end
        end
    end

    -- Rebuild the group paladins' rows: majority buff becomes the class
    -- (Greater) assignment, dissenters become Normal exceptions. Ties break on
    -- the lower blessing id so repeat builds are deterministic (and the check
    -- never flags a stable board as drifted).
    local classCount, singleCount = 0, 0
    for _, pname in ipairs(paladins) do
        local pshort = ShortName(pname)
        assignments[pshort] = {}
        for c = 1, PALLYPOWER_MAXCLASSES do
            assignments[pshort][c] = 0
        end
        normal[pshort] = {}

        for cid, tally in pairs(votes[pshort] or {}) do
            local majority, majorityCount = nil, 0
            for bless, count in pairs(tally) do
                if count > majorityCount
                    or (count == majorityCount and bless < majority) then
                    majority, majorityCount = bless, count
                end
            end
            assignments[pshort][cid] = majority
            classCount = classCount + 1

            for raider, bless in pairs(buffOf[pshort][cid]) do
                if bless ~= majority then
                    normal[pshort][cid] = normal[pshort][cid] or {}
                    normal[pshort][cid][raider] = bless
                    singleCount = singleCount + 1
                end
            end
        end
    end

    -- PallyPower groups pets under Warrior on this client, but each planned
    -- pet cell is still a 10-minute, single-target Normal blessing.
    for petName, owner in pairs(petOwner) do
        local realName = petRealName[owner]
        local realShort = ShortName(realName)
        for paladin, buffKey in pairs(plan[petName] or {}) do
            local pshort = ShortName(paladin)
            local bless = BuffKeyToBlessingId(buffKey)
            if not IsFakeName(paladin) then
                if realShort and petClassId and bless and normal[pshort] then
                    normal[pshort][petClassId] = normal[pshort][petClassId] or {}
                    normal[pshort][petClassId][realShort] = bless
                    singleCount = singleCount + 1
                else
                    skipped = skipped + 1
                end
            end
        end
    end

    return assignments, normal, classCount, singleCount, skipped
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

-- Read-only drift check: does PallyPower's LIVE board still match what a full
-- SyncToPallyPower would write? A paladin joining/leaving or turning
-- Non-raider reshapes the whole grid but touches nothing in PallyPower (only
-- single-raider role changes push, via PushPlayerBuffToPallyPower), so the two
-- silently diverge. Rather than auto-rewriting the whole board out from under
-- everyone, the UI surfaces this as a warning icon + a Check window and lets
-- the user Send the plan when ready. Compares the desired vs. live Greater
-- assignments and Normal exceptions for the group paladins and returns a list
-- of structured difference entries the diff view formats (empty = in sync):
--   { paladin, target, targetIcon, targetRole, isClass, want, wantName,
--     wantIcon, have, haveName, haveIcon }
-- want/have are blessing ids (0 = none).
-- Returns nil when there's nothing to compare (PallyPower not loaded, or no
-- paladins in the group).
local function DiffEntry(pshort, target, isClass, want, have, targetInfo)
    return {
        paladin = pshort, target = target, isClass = isClass,
        targetIcon = targetInfo and targetInfo.icon,
        targetRole = targetInfo and targetInfo.role,
        want = want, wantName = BlessingName(want), wantIcon = BlessingIcon(want),
        have = have, haveName = BlessingName(have), haveIcon = BlessingIcon(have),
    }
end

-- Icons/labels used by the comparison view. Keep this sourced from Data.lua:
-- class-wide rows use the class icon, raiders use their assigned role, and
-- current or previously seen hunter pets use the pet pseudo-role.
local function DiffTargetInfo(self)
    local classes, targets, pets = {}, {}, {}
    for _, classInfo in ipairs(self.Classes) do
        classes[classInfo.name] = {
            icon = classInfo.classIcon,
            role = classInfo.name .. " class",
        }
    end
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
            pets[petName] = true
        end
    end
    return classes, targets, pets
end

function WhoDoesWhat:CheckPallyPowerSync()
    local pp = _G.PallyPower
    if not (pp and _G.PallyPower_Assignments and _G.PallyPower_NormalAssignments) then
        return nil
    end
    local paladins = GroupPaladins(self)
    if #paladins == 0 then return nil end

    local assignments, normal = BuildDesired(self, pp, paladins)
    local classInfo, targetInfo, petTargets = DiffTargetInfo(self)
    local might = BuffKeyToBlessingId("might")
    local kings = BuffKeyToBlessingId("kings")
    local diffs = {}
    for _, pname in ipairs(paladins) do
        local pshort = ShortName(pname)

        -- Greater (class) blessings, slot by slot.
        local liveA = PallyPower_Assignments[pshort] or {}
        local wantA = assignments[pshort] or {}
        for c = 1, PALLYPOWER_MAXCLASSES do
            local want, live = wantA[c] or 0, liveA[c] or 0
            if want ~= live then
                local target = ClassIdName(c)
                diffs[#diffs + 1] = DiffEntry(pshort, target, true, want, live,
                    classInfo[target])
            end
        end

        -- Normal (per-target) exceptions: walk the union of live + desired
        -- targets under each class so an exception that only one side has still
        -- reads as a difference (want/live 0 = "none").
        local liveN = PallyPower_NormalAssignments[pshort] or {}
        local wantN = normal[pshort] or {}
        local cids = {}
        for cid in pairs(liveN) do cids[cid] = true end
        for cid in pairs(wantN) do cids[cid] = true end
        for cid in pairs(cids) do
            local lt, wt = liveN[cid] or {}, wantN[cid] or {}
            local names = {}
            for n in pairs(lt) do names[n] = true end
            for n in pairs(wt) do names[n] = true end
            for n in pairs(names) do
                local want, live = wt[n] or 0, lt[n] or 0
                -- Pet rows are identity-sensitive in PallyPower and commonly
                -- appear/disappear as None around summons. For drift purposes,
                -- any absence/Might/Kings value is acceptable; only a different
                -- explicit PallyPower blessing is actionable.
                local acceptedPetBuff = petTargets[n]
                    and (live == 0 or live == might or live == kings)
                if want ~= live and not acceptedPetBuff then
                    diffs[#diffs + 1] = DiffEntry(pshort, n, false, want, live,
                        targetInfo[n])
                end
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
-- mutation. We auto-send only from an aligned board and only when the new
-- plan's differences are this target's Normal overrides. A role change can
-- alter raid-wide demand/primaries, and an already-drifted PallyPower board is
-- a bad baseline; either case opens the full Differences window with
-- Ignore/Send instead. Combat-safe: PallyPower parses NASSIGN in combat and
-- refreshes its protected layout after combat.
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
        local reason
        if priorDiffs and #priorDiffs > 0 then
            reason = string.format(
                "%s's role changed, but PallyPower was already out of sync."
                .. " The current plan has %d difference(s). Review them below,"
                .. " then Send the full plan or Ignore it.",
                playerName, #diffs)
        else
            reason = string.format(
                "%s's role change affects %d assignment(s) beyond that"
                .. " raider's own buffs. Review the %d total change(s) below,"
                .. " then Send the full plan or Ignore it.",
                playerName, broad, #diffs)
        end
        self:OpenPallyPowerDiffView(reason)
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

    -- This raider's blessing per paladin, from the freshly recomputed grid
    -- (empty when uncovered, e.g. after being marked Non-raider).
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
                    Append("out", target and ("whisper:" .. ShortName(tostring(target)))
                        or (chattype or "GROUP"), text)
                end
            end)
    end
end

-- Recheck when a pet identity appears. None/Might/Kings are tolerated by the
-- shared comparison; an explicit invalid blessing opens the review/send view.
function Bridge:PetRosterChanged()
    if petCheckPending then return end
    petCheckPending = true
    C_Timer.After(0.25, function()
        petCheckPending = false
        local live = LivePetNames()
        local identified = {}
        local changed = false
        for owner, petName in pairs(live) do
            if knownPetNames[owner] ~= petName then
                changed = true
                identified[ShortName(petName)] = true
            end
            seenPetNames[ShortName(petName)] = true
        end
        for owner in pairs(knownPetNames) do
            if not live[owner] then changed = true break end
        end
        knownPetNames = live
        if changed then WhoDoesWhat:RefreshMainAssignmentsView() end
        if not next(identified) or not CanBroadcastAssignments() then return end

        local diffs = WhoDoesWhat:CheckPallyPowerSync()
        if not diffs then return end
        local petDiffs = 0
        for _, d in ipairs(diffs) do
            if not d.isClass and identified[d.target] then
                petDiffs = petDiffs + 1
            end
        end
        if petDiffs > 0 then
            WhoDoesWhat:OpenPallyPowerDiffView(string.format(
                "PallyPower has %d invalid hunter-pet assignment(s). Pets may"
                .. " only use Might or Kings. Review them below, then Send"
                .. " the full plan or Ignore it.",
                petDiffs))
        end
    end)
end

function Bridge:CHAT_MSG_ADDON(_, prefix, message, _, sender)
    if prefix ~= PP_PREFIX then return end
    local who = Ambiguate(sender, "none")
    if who == UnitName("player") then return end -- own echo; the send hook logged it
    if message:find("^SELF ") then
        WhoDoesWhat.pallyPowerPeers[who] = true
        WhoDoesWhat:RefreshPaladinBuffGridView()
    end
    Append("in", who, message)
end
