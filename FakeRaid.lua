local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Populate Fake Raid: a testing toggle (Settings window) that stuffs 23 or 39
-- make-believe raiders (settings.fakeRaidSize) into the roster so paladin-buff
-- strategies can be developed solo. The local player is the last seat, so any
-- class works as the tester.
--
-- How it plugs in: GetEligibleMembers (Assignments.lua) -- the one choke point
-- every dropdown, the demand math, the auto-assigns, the buff grid, the roles
-- view and the paladin-info view read the roster through -- appends
-- FakeRaid.ROSTER when the toggle is on. The fakes' *roles* live in
-- db.profile.assignments and the paladins' buff-talent ranks in
-- db.profile.paladinBuffTalents, warlocks' Improved Healthstone ranks, and
-- Priest/Druid improved-buff ranks, keyed by fake name like real players.
--
-- The roster is deliberately shaped for buff testing: 3 tanks (one of each
-- kind), 5 healers (one of each healer kind), a DPS spread to fill, and 3
-- paladins (prot / holy / ret) whose buff talents are complementary -- exactly
-- one is talented in Kings+Sanctuary, one in Improved Wisdom, one in Improved
-- Might -- so scarcity-first auto-assign produces a clean, meaningful result.
--
-- Note: entering *and* leaving the mode wipes the assignment board
-- (raidAssignments + tank/CC/misdirect rows) to keep the state easy to reason
-- about, per the design. Real players' saved roles are left untouched.

WhoDoesWhat.FakeRaid = WhoDoesWhat.FakeRaid or {}
local FakeRaid = WhoDoesWhat.FakeRaid

-- Roster building blocks. Each entry: name (bare, same-realm keying), class
-- (English UnitClass token), role (a role id from Data.lua), and for paladins
-- buffTalents in the paladinBuffTalents shape { might=0-5, wisdom=0-2,
-- kings=0-1, sanctuary=0-1 }. Rebuild() assembles FakeRaid.ROSTER (always
-- settings.fakeRaidSize fakes) from these, honoring settings.fakeRaidPaladinCount. Everything is
-- deterministic -- no random elements -- so any two clients with the same
-- setting compute the identical roster.

-- Non-paladin members always present: 2 tanks + 4 healers.
FakeRaid.CORE = {
    { name = "Ironhide",     class = "WARRIOR", role = "warrior_prot" },
    { name = "Bearback",     class = "DRUID",   role = "druid_feral_tank",
      coreBuffTalents = { gift = 0, thorns = 0 } },
    -- The two priests cover both sides of the Divine Spirit gate: `false` is
    -- a spec without the talent that grants it at all, and Lightwell keeps it
    -- in the other talent group, which is the offspec provider case.
    { name = "Lightwell",    class = "PRIEST",  role = "priest_holy",
      coreBuffTalents = { fortitude = 0, spirit = false,
        offspec = { spirit = 2 } } },
    { name = "Painsuppress", class = "PRIEST",  role = "priest_disc",
      coreBuffTalents = { fortitude = 2, spirit = 1,
        offspec = { spirit = false } } },
    { name = "Tidecaller",   class = "SHAMAN",  role = "shaman_resto" },
    { name = "Lifebloom",    class = "DRUID",   role = "druid_resto",
      coreBuffTalents = { gift = 5, thorns = 0 } },
}

-- Paladins in inclusion order for fakeRaidPaladinCount: the Prot tank is the
-- 1-paladin minimum, then Ret, then Holy, then a second Ret with BOTH Improved
-- Might and Improved Wisdom maxed -- overlapping the other two Improved
-- carriers, so the 4th-paladin case exercises the auto-assign's tie-breaking
-- instead of handing everyone a unique specialty.
FakeRaid.PALADINS = {
    { name = "Lightward",    class = "PALADIN", role = "paladin_prot",
      buffTalents = { might = 0, wisdom = 0, kings = 1, sanctuary = 1 } },
    { name = "Hammertime",   class = "PALADIN", role = "paladin_ret",
      buffTalents = { might = 5, wisdom = 0, kings = 0, sanctuary = 0 } },
    { name = "Handoflight",  class = "PALADIN", role = "paladin_holy",
      buffTalents = { might = 0, wisdom = 2, kings = 0, sanctuary = 0 } },
    { name = "Vindicator",   class = "PALADIN", role = "paladin_ret",
      buffTalents = { might = 5, wisdom = 2, kings = 0, sanctuary = 0 } },
}

-- Substitute healer keeping the raid at 5 healers while the Holy paladin is
-- excluded (paladin count < 3).
FakeRaid.HEALER_FILLER =
    { name = "Chainheal",    class = "SHAMAN",  role = "shaman_resto" }

-- DPS in fill order; Rebuild() takes however many top the roster up to its
-- size. At 23, the tail entries are the expendable ones: Falconeye drops out
-- for the 4th paladin, Poisontip only appears down at 1 paladin. Everything
-- after Poisontip is the 39-fake raid only, with three more healers so a
-- 40-man isn't carried by five; its last two drop out the same way.
FakeRaid.DPS_POOL = {
    { name = "Rendwar",      class = "WARRIOR", role = "warrior_fury" },
    { name = "Sunder",       class = "WARRIOR", role = "warrior_arms" },
    { name = "Backstabby",   class = "ROGUE",   role = "rogue_combat" },
    { name = "Arcanum",      class = "MAGE",    role = "mage_arcane" },
    { name = "Corruption",   class = "WARLOCK", role = "warlock_affl", healthstoneRank = 2 },
    { name = "Immolate",     class = "WARLOCK", role = "warlock_destro", healthstoneRank = 1 },
    { name = "Beastly",      class = "HUNTER",  role = "hunter_bm" },
    { name = "Steadyshot",   class = "HUNTER",  role = "hunter_mm" },
    { name = "Trapmaster",   class = "HUNTER",  role = "hunter_surv" },
    { name = "Lavaburst",    class = "SHAMAN",  role = "shaman_ele" },
    { name = "Stormstrike",  class = "SHAMAN",  role = "shaman_enh" },
    { name = "Windfury",     class = "SHAMAN",  role = "shaman_enh" },
    { name = "Moonfire",     class = "DRUID",   role = "druid_balance",
      coreBuffTalents = { gift = 0, thorns = 3 } },
    { name = "Falconeye",    class = "HUNTER",  role = "hunter_mm" },
    { name = "Poisontip",    class = "ROGUE",   role = "rogue_assassin" },
    { name = "Renewal",      class = "PRIEST",  role = "priest_holy",
      coreBuffTalents = { fortitude = 2, spirit = false } },
    { name = "Mendwater",    class = "SHAMAN",  role = "shaman_resto" },
    { name = "Regrowth",     class = "DRUID",   role = "druid_resto",
      coreBuffTalents = { gift = 0, thorns = 0 } },
    { name = "Mindflay",     class = "PRIEST",  role = "priest_shadow",
      coreBuffTalents = { fortitude = 0, spirit = false } },
    { name = "Fireball",     class = "MAGE",    role = "mage_fire" },
    { name = "Frostnova",    class = "MAGE",    role = "mage_frost" },
    { name = "Blizzardo",    class = "MAGE",    role = "mage_frost" },
    { name = "Shadowbolt",   class = "WARLOCK", role = "warlock_demo", healthstoneRank = 0 },
    { name = "Bloodthirst",  class = "WARRIOR", role = "warrior_fury" },
    { name = "Whirlwind",    class = "WARRIOR", role = "warrior_fury" },
    { name = "Shiv",         class = "ROGUE",   role = "rogue_combat" },
    { name = "Shred",        class = "DRUID",   role = "druid_feral_dps",
      coreBuffTalents = { gift = 0, thorns = 0 } },
    { name = "Aimedshot",    class = "HUNTER",  role = "hunter_mm" },
    { name = "Serpentsting", class = "HUNTER",  role = "hunter_surv" },
    { name = "Scorch",       class = "MAGE",    role = "mage_fire" },
    { name = "Cloakndagger", class = "ROGUE",   role = "rogue_sub" },
}

-- Roster sizes the settings dropdown offers: a 24-man and a 40-man with you.
FakeRaid.SIZES = { 23, 39 }

local function TotalFakes()
    return WhoDoesWhat.db.profile.settings.fakeRaidSize == 23 and 23 or 39
end

-- The saved paladin count, clamped to what PALADINS can serve.
local function PaladinCount()
    local n = WhoDoesWhat.db.profile.settings.fakeRaidPaladinCount or 3
    return math.max(1, math.min(#FakeRaid.PALADINS, n))
end

-- Assemble FakeRaid.ROSTER for the current paladin count: core, the first N
-- paladins, the substitute healer while Holy is out, then DPS to the size.
function FakeRaid.Rebuild()
    local r = {}
    for _, fm in ipairs(FakeRaid.CORE) do r[#r + 1] = fm end
    local count = PaladinCount()
    for i = 1, count do r[#r + 1] = FakeRaid.PALADINS[i] end
    if count < 3 then r[#r + 1] = FakeRaid.HEALER_FILLER end
    for i = 1, TotalFakes() - #r do r[#r + 1] = FakeRaid.DPS_POOL[i] end
    FakeRaid.ROSTER = r
end

FakeRaid.ROSTER = {} -- filled by Rebuild() once the DB is up (ReapplyFakeRaid)

-- Every fake that could exist under ANY paladin count -- removal must cover
-- names the current roster no longer includes (e.g. after a count change).
local function EachPossibleFake(fn)
    for _, list in ipairs({ FakeRaid.CORE, FakeRaid.PALADINS,
                            { FakeRaid.HEALER_FILLER }, FakeRaid.DPS_POOL }) do
        for _, fm in ipairs(list) do fn(fm) end
    end
end

-- Whether the fake raid is currently populated.
function WhoDoesWhat:IsFakeRaidEnabled()
    return self.db.profile.settings.populateFakeRaid and true or false
end

-- Wipe the shared assignment board (buff/curse picks + the dynamic tank/CC/
-- misdirect rows). Role assignments (db.profile.assignments) are intentionally
-- left alone -- SetFakeRaidEnabled manages only the fake names in there.
local function WipeBoard(profile)
    wipe(profile.raidAssignments)
    wipe(profile.tankAssignments)
    wipe(profile.ccAssignments)
    wipe(profile.mdAssignments)
end

-- Repaint every window that reads the roster or the board.
local function RefreshViews()
    WhoDoesWhat:RefreshMainAssignmentsView()
    WhoDoesWhat:RefreshMembersView()
    WhoDoesWhat:RefreshBoardViews()
end

-- Re-write the fakes' roles and utility-talent ranks into the DB. No-op
-- while the toggle is off. Beyond the enable transition, this also heals the
-- fakes after anything wipes the board out from under them -- the group-leave
-- wipe (Sync.lua) can fire around reload/logout while solo and eat the roles.
function WhoDoesWhat:ReapplyFakeRaid()
    if not self:IsFakeRaidEnabled() then return end
    FakeRaid.Rebuild()
    local profile = self.db.profile
    for _, fm in ipairs(FakeRaid.ROSTER) do
        profile.assignments[fm.name] = fm.role
        if fm.buffTalents then
            profile.paladinBuffTalents[fm.name] = CopyTable(fm.buffTalents)
        end
        if fm.healthstoneRank ~= nil then
            profile.warlockHealthstoneTalents[fm.name] = fm.healthstoneRank
        end
        if fm.coreBuffTalents then
            profile.coreBuffTalents[fm.name] = CopyTable(fm.coreBuffTalents)
        end
    end
end

-- Turn the fake raid on or off. Either transition wipes the board. Turning on
-- writes the fakes' roles and utility-talent ranks; turning off removes
-- every trace of the fake names so nothing lingers in the DB.
function WhoDoesWhat:SetFakeRaidEnabled(value)
    value = value and true or false
    local profile = self.db.profile

    WipeBoard(profile)
    profile.settings.populateFakeRaid = value

    if value then
        self:ReapplyFakeRaid()
    else
        EachPossibleFake(function(fm)
            profile.assignments[fm.name] = nil
            profile.talentSpecs[fm.name] = nil
            profile.paladinBuffTalents[fm.name] = nil
            profile.warlockHealthstoneTalents[fm.name] = nil
            profile.coreBuffTalents[fm.name] = nil
        end)
    end

    if self.Assign then self.Assign.ReconcileRosterAssignments() end
    RefreshViews()

    self:LogUiBuilding("Populate Fake Raid "
        .. (value and ("enabled -- " .. #FakeRaid.ROSTER .. " fake raiders added.")
                   or "disabled -- fake raiders removed."))
end

-- A live roster change: names come and go, so the board wipes and every old
-- fake trace is cleared before the new roster is injected, same rules as
-- toggling.
local function ReshuffleLiveRoster(self)
    local profile = self.db.profile
    WipeBoard(profile)
    EachPossibleFake(function(fm)
        profile.assignments[fm.name] = nil
        profile.talentSpecs[fm.name] = nil
        profile.paladinBuffTalents[fm.name] = nil
        profile.warlockHealthstoneTalents[fm.name] = nil
        profile.coreBuffTalents[fm.name] = nil
    end)
    self:ReapplyFakeRaid()
    if self.Assign then self.Assign.ReconcileRosterAssignments() end
    RefreshViews()
end

-- Change how many paladins the fake roster carries (1-4, see PALADINS for the
-- inclusion order). While the fake raid is live this reshuffles the roster.
function WhoDoesWhat:SetFakeRaidPaladinCount(n)
    n = math.max(1, math.min(#FakeRaid.PALADINS, tonumber(n) or 3))
    local profile = self.db.profile
    if profile.settings.fakeRaidPaladinCount == n then return end
    profile.settings.fakeRaidPaladinCount = n

    if self:IsFakeRaidEnabled() then
        ReshuffleLiveRoster(self)
        self:LogUiBuilding("Fake raid rebuilt with " .. n .. " paladin" .. (n == 1 and "" or "s") .. ".")
    end
end

-- Change how many fakes the roster carries (one of FakeRaid.SIZES). While the
-- fake raid is live this reshuffles the roster.
function WhoDoesWhat:SetFakeRaidSize(n)
    n = (tonumber(n) == 23) and 23 or 39
    local settings = self.db.profile.settings
    if settings.fakeRaidSize == n then return end
    settings.fakeRaidSize = n

    if self:IsFakeRaidEnabled() then
        ReshuffleLiveRoster(self)
        self:LogUiBuilding("Fake raid rebuilt with " .. n .. " fake raiders.")
    end
end
