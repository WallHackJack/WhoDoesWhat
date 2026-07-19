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

-- ---------------------------------------------------------------------------
-- Sync: grid -> PallyPower
-- ---------------------------------------------------------------------------

function WhoDoesWhat:SyncToPallyPower()
    local pp = _G.PallyPower
    if not (pp and _G.PallyPower_Assignments and _G.PallyPower_NormalAssignments) then
        self:Print("PallyPower is not loaded; nothing to sync to.")
        return
    end

    -- The grid's paladin columns, minus fakes.
    local paladins = {}
    for _, m in ipairs(self:GetGroupMembers("Paladin")) do
        if m.classInfo.name == "Paladin" and not IsFakeName(m.name) then
            paladins[#paladins + 1] = m.name
        end
    end
    if #paladins == 0 then
        self:Print("No paladins in the group; nothing to sync to PallyPower.")
        return
    end

    -- Raider -> PallyPower class id. Classes PallyPower doesn't track on this
    -- client (vanilla PallyPower has no Shaman slot, say) just get skipped.
    local classIdOf = {}
    for _, m in ipairs(self:GetGroupMembers(nil)) do
        if not IsFakeName(m.name) then
            classIdOf[m.name] = pp.ClassToID and pp.ClassToID[m.classInfo.name:upper()]
        end
    end

    -- Tally the grid per paladin/class: votes[pallyShort][classId][blessId]
    -- counts raiders, buffOf remembers each raider's exact cell for the
    -- exception pass.
    local plan = self.Assign.ComputeBuffGrid()
    local votes, buffOf = {}, {}
    local skipped = 0
    for raider, cells in pairs(plan) do
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

    -- Rebuild the group paladins' rows in PallyPower's tables: majority buff
    -- becomes the class (Greater) assignment, dissenters become Normal
    -- exceptions. Ties break on the lower blessing id so repeat clicks are
    -- deterministic.
    local classCount, singleCount = 0, 0
    for _, pname in ipairs(paladins) do
        local pshort = ShortName(pname)
        PallyPower_Assignments[pshort] = {}
        for c = 1, PALLYPOWER_MAXCLASSES do
            PallyPower_Assignments[pshort][c] = 0
        end
        PallyPower_NormalAssignments[pshort] = {}

        for cid, tally in pairs(votes[pshort] or {}) do
            local majority, majorityCount = nil, 0
            for bless, count in pairs(tally) do
                if count > majorityCount
                    or (count == majorityCount and bless < majority) then
                    majority, majorityCount = bless, count
                end
            end
            PallyPower_Assignments[pshort][cid] = majority
            classCount = classCount + 1

            for raider, bless in pairs(buffOf[pshort][cid]) do
                if bless ~= majority then
                    PallyPower_NormalAssignments[pshort][cid] =
                        PallyPower_NormalAssignments[pshort][cid] or {}
                    PallyPower_NormalAssignments[pshort][cid][raider] = bless
                    singleCount = singleCount + 1
                end
            end
        end
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
            .. " cell(s) skipped (class or blessing PallyPower doesn't track)."
    end
    self:Print(summary)

    -- Their clients reject rows for anyone but the sender without authority.
    if IsInRaid() and not self:IsRaidAssistant() then
        self:Print("|cffff6060Heads up:|r you are not raid lead/assist, so other"
            .. " paladins' PallyPower will only accept these if they enabled"
            .. " Free Assignment.")
    end
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

function Bridge:OnEnable()
    -- Without PallyPower loaded nobody registered the prefix, and unregistered
    -- prefixes never reach CHAT_MSG_ADDON -- register it so the log observes
    -- other paladins' traffic either way.
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PP_PREFIX)
    end

    self:RegisterEvent("CHAT_MSG_ADDON")

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

function Bridge:CHAT_MSG_ADDON(_, prefix, message, _, sender)
    if prefix ~= PP_PREFIX then return end
    local who = Ambiguate(sender, "none")
    if who == UnitName("player") then return end -- own echo; the send hook logged it
    Append("in", who, message)
end
