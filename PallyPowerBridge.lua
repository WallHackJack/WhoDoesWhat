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
-- are written directly when PallyPower is installed, then broadcast over its
-- wire protocol (CLEAR SKIP, then PASSIGN per paladin, then batched NASSIGN).
-- WDW sends the protocol itself when PallyPower is absent. Other
-- paladins' clients only accept assignments for someone besides the sender
-- when the sender is a raid leader/assist (or they run Free Assignment), so
-- the button warns when we push without that authority.
--
-- Log: while session logging is enabled, every PLPWR message in or out lands
-- in WhoDoesWhat.PallyPowerLog.
-- Outgoing is caught with a hooksecurefunc on ChatThrottleLib (all of
-- PallyPower's sends funnel through it, whispers included); incoming rides
-- CHAT_MSG_ADDON, skipping our own group-broadcast echo since the hook
-- already logged it. TranslatePallyPowerMessage turns the terse wire text
-- into a readable line for the log view (Views\PallyPowerLogView.lua).

local Bridge = WhoDoesWhat:NewModule("PallyPowerBridge", "AceEvent-3.0")

local PP_PREFIX = "PLPWR"
local PEER_REQUEST_COOLDOWN = 10
WhoDoesWhat.pallyPowerPeers = {}
local lastPeerRequestAt
local lastPeerRequestChannel
local Append

local function GroupChannel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
end

function WhoDoesWhat:PaladinHasPallyPower(name)
    if name == UnitName("player") then return _G.PallyPower ~= nil end
    return self.pallyPowerPeers[name] == true
end

-- Ask PallyPower clients to identify themselves. Each paladin answers REQ
-- with SELF; CHAT_MSG_ADDON below records those replies for raider tooltips.
function WhoDoesWhat:RequestPallyPowerPeers()
    local channel = GroupChannel()
    if channel and C_ChatInfo and C_ChatInfo.SendAddonMessage then
        local now = GetTime()
        if lastPeerRequestChannel == channel and lastPeerRequestAt
            and now - lastPeerRequestAt < PEER_REQUEST_COOLDOWN then return end
        lastPeerRequestAt = now
        lastPeerRequestChannel = channel
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
    if (pp and pp.isWrath) or IS_WRATH then return BLESSING_ID_WRATH[key] end
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
    local names = ((pp and pp.isWrath) or IS_WRATH)
        and BLESSING_NAME_WRATH or BLESSING_NAME
    return names[id] or ("blessing " .. id)
end

-- Blessing id -> our buff key (invert whichever id table is live), and from
-- there the icon in Data.lua -- for the diff view's blessing icons. Nil for 0
-- ("none") or an id this client doesn't map.
local function BlessingIcon(id)
    id = tonumber(id)
    if not id or id == 0 then return nil end
    local pp = _G.PallyPower
    local map = ((pp and pp.isWrath) or IS_WRATH)
        and BLESSING_ID_WRATH or BLESSING_ID
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
    if token then return token:sub(1, 1) .. token:sub(2):lower() end
    for className, classId in pairs(PP_CLASS_ID) do
        if classId == id then return className end
    end
    return "class " .. tostring(id)
end

-- PallyPower keys everything by realm-stripped names.
local function ShortName(name)
    return name and name:match("^([^%-]+)") or name
end

-- SELF's first field is six rank/talent hex pairs in blessing order:
-- Wisdom, Might, Kings, Salvation, Light, Sanctuary. PallyPower only records
-- improvement ranks for Wisdom/Might; the learned spell is the talent proof
-- for Kings/Sanctuary. This is useful provisional evidence, but unlike WDW's
-- native row/column scan it carries no talent-tree totals or spec identity.
local function DecodePallyPowerBuffTalents(numbers)
    if type(numbers) ~= "string" or #numbers < 12 then return nil end
    local function HexAt(index)
        local ch = numbers:sub(index, index)
        return ch ~= "n" and tonumber(ch, 16) or nil
    end
    local wisdom, might = HexAt(2), HexAt(4)
    if wisdom == nil or might == nil then return nil end
    return {
        wisdom = math.min(wisdom, 2),
        might = math.min(might, 5),
        kings = HexAt(5) and 1 or 0,
        sanctuary = HexAt(11) and 1 or 0,
        _source = "pallypower",
    }
end

local function GroupPaladinKey(sender)
    local short = ShortName(sender)
    local match
    for _, member in ipairs(WhoDoesWhat:GetGroupMembers("Paladin")) do
        if member.classInfo.name == "Paladin" then
            if member.name == sender then return member.name end
            if ShortName(member.name) == short then
                if match then return nil end -- same name on two realms
                match = member.name
            end
        end
    end
    return match
end

local function ImportPallyPowerBuffTalents(sender, message)
    local numbers = message:match("^SELF ([0-9a-fn]*)@")
    local playerKey = numbers and GroupPaladinKey(sender)
    local ranks = playerKey and DecodePallyPowerBuffTalents(numbers)
    if not ranks then return false end

    local current = WhoDoesWhat:GetPaladinBuffTalents(playerKey)
    if current and current._source ~= "pallypower" then return false end
    WhoDoesWhat.db.profile.paladinBuffTalents[playerKey] = ranks
    WhoDoesWhat:RefreshMainAssignmentsView()
    WhoDoesWhat:RefreshBuffingGridView()
    return true
end

function WhoDoesWhat:TestPallyPowerTalentDecode()
    local ranks = DecodePallyPowerBuffTalents("727510405011")
    assert(ranks and ranks.wisdom == 2 and ranks.might == 5)
    assert(ranks.kings == 1 and ranks.sanctuary == 1)
    ranks = DecodePallyPowerBuffTalents("7170nn4050nn")
    assert(ranks and ranks.wisdom == 1 and ranks.might == 0)
    assert(ranks.kings == 0 and ranks.sanctuary == 0)
    assert(DecodePallyPowerBuffTalents("nnnnnnn4n5nn") == nil)
    self:Print("PallyPower talent-decode check passed.")
end

-- The wire mirror is deliberately session-only. REQ/SELF reconstructs it
-- from the PallyPower clients currently in the group.
local observedBoard = { assignments = {}, normal = {}, freeAssign = {} }
WhoDoesWhat.PallyPowerMirror = observedBoard

local function CurrentPallyPowerBoard()
    if _G.PallyPower and _G.PallyPower_Assignments
        and _G.PallyPower_NormalAssignments then
        return _G.PallyPower_Assignments, _G.PallyPower_NormalAssignments
    end
    return observedBoard.assignments, observedBoard.normal
end

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

local function CanApplyAssignment(board, sender, paladin, senderHasAuthority)
    paladin = ShortName(paladin)
    return ShortName(sender) == paladin or senderHasAuthority
        or board.freeAssign and board.freeAssign[paladin]
end

-- Apply the PLPWR messages that can change the blessing grid, plus the
-- FREEASSIGN permission needed to accept another player's edits. Aura,
-- cooldown, symbol, and UI messages are intentionally outside this mirror.
local function ApplyPallyPowerMessage(board, sender, message, authorityOverride)
    sender = ShortName(sender)
    local senderHasAuthority = authorityOverride
    if senderHasAuthority == nil then
        senderHasAuthority = SenderCanAssignOthers(sender)
    end

    local freeAssign = message:match("^FREEASSIGN (%u+)")
    if freeAssign then
        board.freeAssign = board.freeAssign or {}
        local enabled = freeAssign == "YES" or nil
        local changed = board.freeAssign[sender] ~= enabled
        board.freeAssign[sender] = enabled
        return changed
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
    if paladin and CanApplyAssignment(board, sender, paladin, senderHasAuthority) then
        SetClassRow(board, paladin, row)
        return true
    end

    local classId, blessing
    paladin, classId, blessing = message:match("^ASSIGN (%S+) (%d+) (%d+)")
    if paladin and CanApplyAssignment(board, sender, paladin, senderHasAuthority) then
        paladin, classId = ShortName(paladin), tonumber(classId)
        board.assignments[paladin] = board.assignments[paladin] or {}
        board.assignments[paladin][classId] = tonumber(blessing) or 0
        return true
    end

    paladin, blessing = message:match("^MASSIGN (%S+) (%d+)")
    if paladin and CanApplyAssignment(board, sender, paladin, senderHasAuthority) then
        local rowText = string.rep(tostring(tonumber(blessing) or 0), PP_MAX_CLASSES)
        SetClassRow(board, paladin, rowText)
        return true
    end

    local body = message:match("^NASSIGN (.+)")
    if body then
        local changed = false
        for pname, cid, target, value in
            body:gmatch("([^@ ]+) ([^@ ]+) ([^@ ]+) ([^@ ]+)") do
            if CanApplyAssignment(board, sender, pname, senderHasAuthority) then
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

    if message:find("^CLEAR") then
        if senderHasAuthority then
            wipe(board.assignments)
            wipe(board.normal)
            return true
        end
        local changed = false
        for paladin in pairs(board.freeAssign or {}) do
            changed = board.assignments[paladin] ~= nil
                or board.normal[paladin] ~= nil or changed
            board.assignments[paladin] = nil
            board.normal[paladin] = nil
        end
        return changed
    end
    return false
end

-- Use PallyPower's sender when available; otherwise speak its public wire
-- protocol directly and apply the same message to WDW's local mirror.
local function SendPallyPowerMessage(message)
    local pp = _G.PallyPower
    if pp and pp.SendMessage then
        pp:SendMessage(message)
        return
    end

    ApplyPallyPowerMessage(observedBoard, UnitName("player"), message)
    local channel = GroupChannel()
    if channel and C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PP_PREFIX, message, channel)
    end
    if Append then Append("out", channel or "LOCAL", message) end
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

function WhoDoesWhat:CanFixPallyPowerPaladin(paladin)
    local pshort = ShortName(paladin)
    return CanBroadcastAssignments() or pshort == ShortName(UnitName("player"))
        or observedBoard.freeAssign[pshort] == true
end

local function BlockedPallyPowerPaladin(self, playerName, diffs)
    if CanBroadcastAssignments() then return nil end
    diffs = diffs or self:CheckPallyPowerSync()
    for _, diff in ipairs(diffs or {}) do
        local target = diff.planTarget or diff.target
        if (target == playerName or ShortName(target) == ShortName(playerName))
            and not self:CanFixPallyPowerPaladin(diff.paladin) then
            return diff.paladin
        end
    end
end

function WhoDoesWhat:CanFixAllPallyPowerAssignments()
    for _, member in ipairs(self:GetGroupMembers("Paladin")) do
        if member.classInfo.name == "Paladin" and not IsFakeName(member.name)
            and not self:CanFixPallyPowerPaladin(member.name) then
            return false, ShortName(member.name)
        end
    end
    return true
end

function WhoDoesWhat:CanFixPlayerBuffsInPallyPower(playerName, diffs)
    local blocked = BlockedPallyPowerPaladin(self, playerName, diffs)
    return blocked == nil, blocked
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

local function TargetedAssignment(newBless, currentGreater, soleClassTarget)
    if soleClassTarget then return "greater", newBless or 0 end
    return "normal", newBless and newBless ~= currentGreater and newBless or nil
end

-- Small parser check, callable through LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat").
function WhoDoesWhat:TestPallyPowerMirror()
    local board = { assignments = {}, normal = {}, freeAssign = {} }
    assert(ApplyPallyPowerMessage(board, "Alice", "SELF nnnnnn@3n2nnnnnn", false))
    assert(board.assignments.Alice[1] == 3 and board.assignments.Alice[3] == 2)
    assert(ApplyPallyPowerMessage(board, "Alice", "ASSIGN Alice 1 4", false))
    assert(board.assignments.Alice[1] == 4)
    assert(ApplyPallyPowerMessage(board, "Alice",
        "NASSIGN Alice 1 Bob 2@Alice 1 Cara 0", false))
    assert(board.normal.Alice[1].Bob == 2 and board.normal.Alice[1].Cara == nil)
    assert(not ApplyPallyPowerMessage(board, "Bob", "PASSIGN Alice@111111111", false))
    assert(ApplyPallyPowerMessage(board, "Alice", "FREEASSIGN YES", false))
    assert(ApplyPallyPowerMessage(board, "Bob", "ASSIGN Alice 1 3", false))
    assert(board.assignments.Alice[1] == 3)
    assert(ApplyPallyPowerMessage(board, "Bob", "NASSIGN Alice 1 Cara 4", false))
    assert(board.normal.Alice[1].Cara == 4)
    assert(ApplyPallyPowerMessage(board, "Bob", "CLEAR SKIP", false))
    assert(board.assignments.Alice == nil and board.normal.Alice == nil)
    assert(ApplyPallyPowerMessage(board, "Bob", "ASSIGN Alice 1 3", false))
    assert(ApplyPallyPowerMessage(board, "Alice", "FREEASSIGN NO", false))
    assert(not ApplyPallyPowerMessage(board, "Bob", "CLEAR SKIP", false))
    assert(board.assignments.Alice[1] == 3)
    assert(not ApplyPallyPowerMessage(board, "Bob", "ASSIGN Alice 1 2", false))
    local kind, value = TargetedAssignment(3, 4, true)
    assert(kind == "greater" and value == 3)
    kind, value = TargetedAssignment(3, 4, false)
    assert(kind == "normal" and value == 3)
    kind, value = TargetedAssignment(4, 4, false)
    assert(kind == "normal" and value == nil)
    self:Print("PallyPower mirror parser check passed.")
end

-- Compute the PallyPower assignment tables our grid implies, WITHOUT touching
-- the live globals or the wire: majority buff per paladin/class becomes the
-- class (Greater) assignment, and dissenters ride along as Normal exceptions.
-- The assignment model supplies the shared Greater decision, including the
-- Warrior bucket inherited by pets. This is the single source of truth for
-- "what a full sync would write" -- SyncToPallyPower copies the result into
-- co-installed live tables when present and always broadcasts it;
-- CheckPallyPowerSync compares it with those tables or WDW's wire mirror.
-- Returns
-- assignments[pshort][classId], normal[pshort][classId][target], the summary
-- counts, plus each active PallyPower target's class id and its WDW grid key.
local function BuildDesired(self, paladins)
    local assignments, normal = {}, {}

    -- Raider -> PallyPower class id. Classes PallyPower doesn't track on this
    -- client (vanilla PallyPower has no Shaman slot, say) just get skipped.
    local classIdOf, activeTargets, planTargetByWire = {}, {}, {}
    for _, m in ipairs(self:GetGroupMembers(nil)) do
        if not IsFakeName(m.name) then
            local cid = PP_CLASS_ID[m.classInfo.name]
            classIdOf[m.name] = cid
            if cid and not self:IsNonRaider(m.name) then
                local target = ShortName(m.name)
                activeTargets[target] = cid
                planTargetByWire[target] = m.name
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
    local petClassId = PP_CLASS_ID.Warrior

    local buffPlan = self.Assign.GetPaladinBuffPlan()
    local plan = buffPlan.grid
    local classCount, singleCount, skipped = 0, 0, 0
    for _, pname in ipairs(paladins) do
        local pshort = ShortName(pname)
        assignments[pshort] = {}
        for c = 1, PP_MAX_CLASSES do
            assignments[pshort][c] = 0
        end
        normal[pshort] = {}

        for className, buffKey in pairs(buffPlan.greaterByPaladin[pname] or {}) do
            local cid = PP_CLASS_ID[className]
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
        if owner and target and cid then
            activeTargets[target] = cid
            planTargetByWire[target] = raider
        end
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
        activeTargets, planTargetByWire
end

function WhoDoesWhat:SyncToPallyPower()
    local pp = _G.PallyPower
    local paladins = GroupPaladins(self)
    if #paladins == 0 then
        self:Print("No paladins in the group; nothing to sync to PallyPower.")
        return
    end
    local canFix, blocked = self:CanFixAllPallyPowerAssignments()
    if not canFix then
        self:Print(blocked .. " has Free Assignment disabled; the complete"
            .. " PallyPower plan cannot be applied.")
        return false
    end

    local assignments, normal, classCount, singleCount, skipped =
        BuildDesired(self, paladins)

    -- Keep a co-installed PallyPower's local tables in step. The broadcast
    -- below uses WDW's computed tables directly and does not depend on them.
    if pp and _G.PallyPower_Assignments and _G.PallyPower_NormalAssignments then
        for _, pname in ipairs(paladins) do
            local pshort = ShortName(pname)
            PallyPower_Assignments[pshort] = assignments[pshort]
            PallyPower_NormalAssignments[pshort] = normal[pshort]
        end
    end

    -- Broadcast over PallyPower's own protocol, in its LoadPreset rhythm:
    -- reset everyone (SKIP keeps auras), give the tables a beat to land, then
    -- the full class rows and the exception batches. Without PallyPower, WDW
    -- sends these messages itself and updates its local wire mirror.
    SendPallyPowerMessage("CLEAR SKIP")
    C_Timer.After(0.25, function()
        for _, pname in ipairs(paladins) do
            local pshort = ShortName(pname)
            local s = ""
            for c = 1, PP_MAX_CLASSES do
                local v = assignments[pshort][c]
                s = s .. ((not v or v == 0) and "n" or v)
            end
            SendPallyPowerMessage("PASSIGN " .. pshort .. "@" .. s)
        end

        local entries = {}
        for _, pname in ipairs(paladins) do
            local pshort = ShortName(pname)
            for cid, tnames in pairs(normal[pshort]) do
                for tname, bless in pairs(tnames) do
                    entries[#entries + 1] =
                        string.format("%s %s %s %s", pshort, cid, tname, bless)
                end
            end
        end
        for offset = 1, #entries, 5 do
            SendPallyPowerMessage("NASSIGN "
                .. table.concat(entries, "@", offset, math.min(offset + 4, #entries)))
        end

        if pp and pp.UpdateLayout then pp:UpdateLayout() end
        self:RefreshMainAssignmentsView()
        self:RefreshBuffingGridView()
        self:RefreshStatusBarsView()
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
    return true
end

-- Read-only drift check: does PallyPower give every active target the blessing
-- the current WDW plan wants? Compare effective blessings after Normal
-- overrides rather than the raw Greater/Normal table shape: the same coverage
-- can have several valid encodings, especially after one raider changes role.
-- Real coverage drift still surfaces as a warning icon + a Check window and
-- lets the user Send the canonical full plan when ready. Returns structured
-- difference entries for the diff view (empty = in sync):
--   { paladin, target, planTarget, targetIcon, targetRole, isClass, want, wantName,
--     wantIcon, have, haveName, haveIcon }
-- want/have are blessing ids (0 = none).
-- Returns nil plus "no-paladins" when there's nothing to compare.
local function DiffEntry(pshort, target, isClass, want, have, targetInfo, planTarget)
    return {
        paladin = pshort, target = target, isClass = isClass,
        planTarget = planTarget,
        targetIcon = targetInfo and targetInfo.icon,
        targetRole = targetInfo and targetInfo.role,
        want = want, wantName = BlessingName(want), wantIcon = BlessingIcon(want),
        have = have, haveName = BlessingName(have), haveIcon = BlessingIcon(have),
    }
end

-- PP source mode only needs a quiet quality signal: provider swaps are fine
-- when the same blessing remains covered. Count a desired blessing only when
-- nobody supplies it, or when its confirmed provider talent is worse than
-- the provider WDW would use. Unknown ranks are deliberately non-alarming.
local function CountUnoptimizedBlessings(wanted, current, petTargets, talentRanks)
    local count = 0
    local function Rank(paladin, key)
        local ranks = talentRanks and talentRanks[paladin]
        if not talentRanks then
            ranks = WhoDoesWhat:GetPaladinBuffTalents(paladin)
        end
        return ranks and ranks[key]
    end
    for target, wantedBuffs in pairs(wanted) do
        if not petTargets[target] then
            local currentBuffs = current[target] or {}
            for blessing, wantedPaladin in pairs(wantedBuffs) do
                local providers = currentBuffs[blessing]
                if not providers then
                    count = count + 1
                else
                    local key = BlessingIdToBuffKey(blessing)
                    local talent = key and WhoDoesWhat.Assign.BuffTalents[key]
                    local wantedRank = talent and Rank(wantedPaladin, key)
                    if wantedRank ~= nil then
                        local bestRank, unknown = nil, false
                        for _, paladin in ipairs(providers) do
                            local rank = Rank(paladin, key)
                            if rank == nil then
                                unknown = true
                            elseif not bestRank or rank > bestRank then
                                bestRank = rank
                            end
                        end
                        if not unknown and bestRank ~= nil and bestRank < wantedRank then
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
    return count
end

function WhoDoesWhat:TestPallyPowerOptimizationCount()
    local wanted = { Raider = { [2] = "MightFive", [1] = "Wisdom" } }
    local current = { Raider = { [2] = { "MightOne" }, [1] = { "Wisdom" } } }
    local ranks = {
        MightFive = { might = 5 }, MightOne = { might = 1 },
        Wisdom = { wisdom = 2 }, OtherFive = { might = 5 },
    }
    assert(CountUnoptimizedBlessings(wanted, current, {}, ranks) == 1)
    current.Raider[2] = { "OtherFive" }
    assert(CountUnoptimizedBlessings(wanted, current, {}, ranks) == 0)
    current.Raider[1] = nil
    assert(CountUnoptimizedBlessings(wanted, current, {}, ranks) == 1)
    self:Print("PallyPower optimization-count check passed.")
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
    local paladins = GroupPaladins(self)
    if #paladins == 0 then return nil, "no-paladins" end

    local assignments, normal, _, _, _, activeTargets, planTargetByWire =
        BuildDesired(self, paladins)
    local currentAssignments, currentNormal = CurrentPallyPowerBoard()
    local targetInfo, petTargets = DiffTargetInfo(self)
    local might = BuffKeyToBlessingId("might")
    local kings = BuffKeyToBlessingId("kings")
    local diffs = {}
    local wantedByTarget, currentByTarget = {}, {}
    for _, pname in ipairs(paladins) do
        local pshort = ShortName(pname)
        local liveA = currentAssignments[pshort] or {}
        local wantA = assignments[pshort] or {}
        local liveN = currentNormal[pshort] or {}
        local wantN = normal[pshort] or {}
        for target, cid in pairs(activeTargets) do
            local want = wantN[cid] and wantN[cid][target]
            if not want or want == 0 then want = wantA[cid] or 0 end
            local live = liveN[cid] and liveN[cid][target]
            if not live or live == 0 then live = liveA[cid] or 0 end

            if want ~= 0 then
                wantedByTarget[target] = wantedByTarget[target] or {}
                wantedByTarget[target][want] = pname
            end
            if live ~= 0 then
                currentByTarget[target] = currentByTarget[target] or {}
                local providers = currentByTarget[target][live]
                if not providers then
                    providers = {}
                    currentByTarget[target][live] = providers
                end
                providers[#providers + 1] = pname
            end

            -- Pet identities and rows are transient. None/Might/Kings are all
            -- safe; only an explicit unrelated blessing needs intervention.
            local acceptedPetBuff = petTargets[target]
                and (live == 0 or live == might or live == kings)
            if want ~= live and not acceptedPetBuff then
                diffs[#diffs + 1] = DiffEntry(pshort, target, false, want, live,
                    targetInfo[target], planTargetByWire[target])
            end
        end
    end
    return diffs, nil, CountUnoptimizedBlessings(
        wantedByTarget, currentByTarget, petTargets)
end

-- Recompute one raider's whole WDW row after a role change. With classmates,
-- use Normal (lesser) overrides so nobody else's coverage moves. When this is
-- the only group target in its class, change the class Greater assignment and
-- clear any stale Normal override instead.
local function PushPlayerBuffs(self, playerName, explicit)
    local pp = _G.PallyPower
    local function Refuse(message)
        if explicit then self:Print(message) end
        return false
    end
    if not playerName or IsFakeName(playerName) then
        return Refuse("That simulated player cannot be sent to PallyPower.")
    end
    if not explicit
        and (self.db.profile.settings.pallyBuffSource or "wdw") ~= "wdw" then
        return false
    end
    if not explicit and not CanBroadcastAssignments() then return false end
    if explicit then
        local canFix, blocked = self:CanFixPlayerBuffsInPallyPower(playerName)
        if not canFix then
            return Refuse(blocked .. " has Free Assignment disabled; this row"
                .. " cannot be fixed.")
        end
    end

    -- The raider's class id, as PallyPower keys it. Untracked classes (no
    -- Shaman slot on vanilla PallyPower, say) have nothing to push.
    local member, classId, wireTarget
    for _, m in ipairs(self:GetGroupMembers(nil)) do
        if m.name == playerName then member = m break end
    end
    if member then
        classId = PP_CLASS_ID[member.classInfo.name]
        wireTarget = ShortName(playerName)
    else
        for _, pet in ipairs(self.Assign.GetPetMembers()) do
            if pet.name == playerName then
                member = pet
                classId = PP_CLASS_ID.Warrior
                wireTarget = ShortName(LivePetNames()[pet.owner])
                break
            end
        end
    end
    if not member or not classId or not wireTarget then
        return Refuse("That target cannot be represented in PallyPower.")
    end
    local xshort = wireTarget
    local currentAssignments, currentNormal = CurrentPallyPowerBoard()
    local paladins = GroupPaladins(self)
    local classTargetCount = 0
    for _, groupMember in ipairs(self:GetGroupMembers(nil)) do
        if not IsFakeName(groupMember.name)
            and PP_CLASS_ID[groupMember.classInfo.name] == classId then
            classTargetCount = classTargetCount + 1
        end
    end
    if classId == PP_CLASS_ID.Warrior then
        local livePets = LivePetNames()
        for _, pet in ipairs(self.Assign.GetPetMembers()) do
            if not IsFakeName(pet.owner) and livePets[pet.owner] then
                classTargetCount = classTargetCount + 1
            end
        end
    end
    local soleClassTarget = classTargetCount == 1
        and (member.isPet or not self:IsNonRaider(member.name))

    -- This raider's blessing per paladin from the current shared plan (empty
    -- when uncovered, e.g. after being marked Non-raider).
    local cells = self.Assign.GetPaladinBuffPlan().grid[playerName] or {}

    local greaterMessages, normalEntries = {}, {}
    for _, paladin in ipairs(paladins) do
        local pshort = ShortName(paladin)
        local assignmentRow = currentAssignments[pshort] or {}
        currentAssignments[pshort] = assignmentRow
        local currentGreater = assignmentRow[classId]
        local kind, desired = TargetedAssignment(
            BuffKeyToBlessingId(cells[paladin]), currentGreater, soleClassTarget)
        local normalByPaladin = currentNormal[pshort] or {}
        local normalByClass = normalByPaladin[classId] or {}
        currentNormal[pshort] = normalByPaladin
        normalByPaladin[classId] = normalByClass
        local currentSingle = normalByClass[xshort]

        if kind == "greater" and desired ~= currentGreater then
            assignmentRow[classId] = desired
            greaterMessages[#greaterMessages + 1] =
                string.format("ASSIGN %s %s %s", pshort, classId, desired)
        end
        if (kind == "normal" and desired ~= currentSingle)
            or (kind == "greater" and currentSingle ~= nil) then
            normalByClass[xshort] = kind == "normal" and desired or nil
            normalEntries[#normalEntries + 1] = string.format("%s %s %s %s",
                pshort, classId, xshort, kind == "normal" and (desired or 0) or 0)
        end
    end

    if #greaterMessages == 0 and #normalEntries == 0 then return false end

    for _, message in ipairs(greaterMessages) do SendPallyPowerMessage(message) end
    for offset = 1, #normalEntries, 5 do
        SendPallyPowerMessage("NASSIGN "
            .. table.concat(normalEntries, "@", offset,
                math.min(offset + 4, #normalEntries)))
    end
    if pp and pp.UpdateLayout then
        pp:UpdateLayout() -- self-guards in combat; refreshes the sender's grid otherwise
    end
    return true
end

function WhoDoesWhat:PushPlayerBuffToPallyPower(playerName)
    return PushPlayerBuffs(self, playerName, false)
end

function WhoDoesWhat:FixPlayerBuffsInPallyPower(playerName)
    return PushPlayerBuffs(self, playerName, true)
end

-- ---------------------------------------------------------------------------
-- The PLPWR traffic log
-- ---------------------------------------------------------------------------

local MAX_LOG = 500
local log = {}
WhoDoesWhat.PallyPowerLog = log
local statusRefreshPending

Append = function(dir, who, msg)
    if WhoDoesWhat.LOG_SYNC then
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
        WhoDoesWhat:RefreshMainAssignmentsView()
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
        if not IsInGroup() and (next(observedBoard.assignments)
            or next(observedBoard.normal) or next(observedBoard.freeAssign)) then
            wipe(observedBoard.assignments)
            wipe(observedBoard.normal)
            wipe(observedBoard.freeAssign)
            QueueMirrorRefresh()
        end
        if not IsInGroup() then
            lastPeerRequestAt = nil
            lastPeerRequestChannel = nil
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
    ImportPallyPowerBuffTalents(who, message)
    if ApplyPallyPowerMessage(observedBoard, who, message) then
        QueueMirrorRefresh()
    end
    if message:find("^SELF ") then
        WhoDoesWhat.pallyPowerPeers[who] = true
    end
    Append("in", who, message)
end
