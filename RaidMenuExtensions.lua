local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")


-- ---------------------------------------------------------------------------
-- "Promote this player" highlight: a pulsing pointer plus an animated glow,
-- both anchored to a raid member's row in the Raid tab of the social frame,
-- since we can't promote for them. Several tanks can be pending at once (a
-- fresh raid scan turns up all its main tanks together), so each pending
-- player gets their OWN arrow+glow and the raid window stays open until the
-- LAST of them is promoted.
-- ---------------------------------------------------------------------------

local promoteWatcher = CreateFrame("Frame")
local pendingPromotes = {} -- set: player name -> true, tanks awaiting MAINTANK
local highlights = {}      -- player name -> { arrow = frame, glow = frame } shown now
local highlightPool = {}   -- released highlight pairs, reused for the next tank
local openedRaidTab        -- true when WE opened the raid window (so we may close it)

-- Find the Raid-tab row for a player. Blizzard_RaidUI names the member rows
-- RaidGroupButton<i> where i is the player's raid roster index (the
-- RaidGroup<g>Slot<s> frames are just empty layout slots), so look the index
-- up in the roster and grab that button. Returns nil when the player isn't in
-- the raid or their row isn't currently shown.
local function FindRaidMemberButton(playerName)
    local target = strsplit("-", playerName) -- match on name, ignore realm
    for i = 1, MAX_RAID_MEMBERS or 40 do
        local name = GetRaidRosterInfo(i)
        if name and strsplit("-", name) == target then
            local btn = _G["RaidGroupButton" .. i]
            if btn and btn:IsVisible() then
                return btn
            end
            return nil
        end
    end
    return nil
end

-- Build one arrow+glow pair. The arrow is Blizzard's quest arrow, rotated to
-- point left with a gentle horizontal bounce ("this row here"); the glow is
-- the quest-log row highlight, tinted gold and ADD-blended so it stretches
-- cleanly over a wide list row and pulses. Both live in their own TOOLTIP-
-- strata frames -- a texture parented straight to UIParent would draw
-- underneath the Friends/Raid window no matter where we anchor it.
local function CreateHighlight()
    local a = CreateFrame("Frame", nil, UIParent)
    a:SetFrameStrata("TOOLTIP")
    a:SetSize(32, 32)
    local at = a:CreateTexture(nil, "OVERLAY")
    at:SetAllPoints(a)
    at:SetTexture("Interface\\MINIMAP\\MiniMap-QuestArrow")
    if at.SetRotation then pcall(at.SetRotation, at, math.pi / 2) end -- up -> left
    local aag = a:CreateAnimationGroup()
    aag:SetLooping("BOUNCE")
    local move = aag:CreateAnimation("Translation")
    move:SetOffset(10, 0)
    move:SetDuration(0.5)
    move:SetSmoothing("IN_OUT")
    a.anim = aag
    a:Hide()

    local g = CreateFrame("Frame", nil, UIParent)
    g:SetFrameStrata("TOOLTIP")
    local gt = g:CreateTexture(nil, "OVERLAY")
    gt:SetAllPoints(g)
    gt:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    gt:SetVertexColor(1, 0.82, 0.2)
    gt:SetBlendMode("ADD")
    local gag = g:CreateAnimationGroup()
    gag:SetLooping("BOUNCE")
    local pulse = gag:CreateAnimation("Alpha")
    pulse:SetFromAlpha(0.25)
    pulse:SetToAlpha(1)
    pulse:SetDuration(0.5)
    pulse:SetSmoothing("IN_OUT")
    g.anim = gag
    g:Hide()

    return { arrow = a, glow = g }
end

-- Frames can't be destroyed, so retire a highlight to the pool (stop, hide,
-- unparent) instead of leaking a new pair per tank across a session.
local function ReleaseHighlight(h)
    h.arrow.anim:Stop()
    h.arrow:Hide()
    h.arrow:SetParent(UIParent)
    h.arrow:ClearAllPoints()
    h.glow.anim:Stop()
    h.glow:Hide()
    h.glow:SetParent(UIParent)
    h.glow:ClearAllPoints()
    highlightPool[#highlightPool + 1] = h
end

-- Drop a single player's highlight (they got promoted, or we're stopping).
local function HideHighlight(playerName)
    local h = highlights[playerName]
    if h then
        highlights[playerName] = nil
        ReleaseHighlight(h)
    end
end

-- Point a pending tank's arrow+glow at their raid row (best effort). The raid
-- grid lives in Blizzard_RaidUI, a load-on-demand addon that only loads when
-- the Raid tab first shows -- so force-load it, then retry with growing delays
-- while the tab builds its rows. No auto-hide: the highlight stays put until
-- the tank is promoted (roster watcher) so it keeps pointing while the leader
-- works through several of them.
function WhoDoesWhat:PointArrowAtRaidMember(playerName)
    if not C_Timer then return end

    if RaidFrame_LoadUI then
        RaidFrame_LoadUI()
    end

    local delays = { 0.1, 0.5, 1.0 }
    local function try(attempt)
        if not pendingPromotes[playerName] then return end -- promoted / cancelled meanwhile
        local btn = FindRaidMemberButton(playerName)
        if btn then
            local h = highlights[playerName]
            if not h then
                h = tremove(highlightPool) or CreateHighlight()
                highlights[playerName] = h
            end
            -- Parent to the row itself so closing the raid window takes the
            -- highlight with it (re-assert strata: SetParent can reset it).
            local a = h.arrow
            a:SetParent(btn)
            a:SetFrameStrata("TOOLTIP")
            a:ClearAllPoints()
            a:SetPoint("LEFT", btn, "RIGHT", 6, 0) -- sit right of the row, pointing in
            a:Show()
            a.anim:Play()
            local g = h.glow
            g:SetParent(btn)
            g:SetFrameStrata("TOOLTIP")
            g:ClearAllPoints()
            g:SetPoint("TOPLEFT", btn, "TOPLEFT", -6, 3)
            g:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 6, -3)
            g:Show()
            g.anim:Play()
        elseif attempt < #delays then
            C_Timer.After(delays[attempt + 1], function() try(attempt + 1) end)
        else
            self:LogUiBuilding("Promote arrow: no visible raid-tab row for " .. tostring(playerName)
                .. " (RaidGroupButton1 exists: " .. tostring(_G["RaidGroupButton1"] ~= nil) .. ")")
        end
    end
    C_Timer.After(delays[1], function() try(1) end)
end

-- Tear the whole flow down: clear every pending tank and its highlight, stop
-- watching, and close the raid window if we were the ones who opened it. The
-- close is skipped in combat (HideUIPanel on a protected frame would error) --
-- the window simply stays open, harmless, until the leader closes it.
function WhoDoesWhat:StopPromoteWatch()
    for name in pairs(pendingPromotes) do pendingPromotes[name] = nil end
    for name in pairs(highlights) do HideHighlight(name) end
    promoteWatcher:UnregisterAllEvents()
    if openedRaidTab and not InCombatLockdown()
        and FriendsFrame and FriendsFrame:IsShown() then
        HideUIPanel(FriendsFrame)
    end
    openedRaidTab = nil
end

-- Roster watcher: as tanks get promoted, drop each one's highlight; only once
-- the LAST pending tank is MAINTANK do we close up. Rows can shift index as
-- the roster changes, so re-point whoever's still waiting.
promoteWatcher:SetScript("OnEvent", function()
    -- Retire a pending tank once they're promoted -- or once they stop being a
    -- tank at all (role changed, or they left the raid and their assignment was
    -- pruned), so a since-departed tank can't hold the window open forever.
    for name in pairs(pendingPromotes) do
        if GetPartyAssignment("MAINTANK", name, true) or not WhoDoesWhat:IsMarkedTank(name) then
            pendingPromotes[name] = nil
            HideHighlight(name)
        end
    end
    if not next(pendingPromotes) then
        WhoDoesWhat:StopPromoteWatch()
        return
    end
    for name in pairs(pendingPromotes) do
        WhoDoesWhat:PointArrowAtRaidMember(name)
    end
end)

-- Opening the social/raid panel is blocked in combat (protected frame), so a
-- tank role assigned mid-fight would throw an "action blocked" error. Defer
-- the promote flow to the moment combat ends; one reused frame queues every
-- name requested during the fight so nothing is lost.
local promoteCombatDefer = CreateFrame("Frame")
promoteCombatDefer.pending = {}
promoteCombatDefer:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
    local names = self.pending
    self.pending = {}
    for name in pairs(names) do WhoDoesWhat:StartPromoteWatch(name) end
end)

-- Add a tank to the "please promote this player to main tank" flow: open the
-- social frame's Raid tab (without toggling it closed when it's already there),
-- point an arrow at them, and watch the roster so everything cleans itself up
-- the moment the last pending tank is promoted. Idempotent per player -- a tank
-- already pending, or already MAINTANK, is a no-op, so the 60s talent
-- rebroadcast that re-runs the scan won't re-nag or replay the klaxon.
function WhoDoesWhat:StartPromoteWatch(playerName)
    if GetPartyAssignment("MAINTANK", playerName, true) then return end -- already main tank
    if pendingPromotes[playerName] then return end -- already waiting on them

    if InCombatLockdown() then
        promoteCombatDefer.pending[playerName] = true
        promoteCombatDefer:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    -- Only note that WE opened the window on the FIRST pending tank; a later
    -- addition must not flip openedRaidTab and make us close a window the
    -- leader had open themselves.
    if not next(pendingPromotes) then
        openedRaidTab = not (FriendsFrame and FriendsFrame:IsShown())
    end
    pendingPromotes[playerName] = true

    if not (FriendsFrame and FriendsFrame:IsShown() and FriendsFrame.selectedTab == 4) then
        ToggleFriendsFrame(4)
    end
    -- Audible "action required" ping (raid-warning klaxon)
    if PlaySound and SOUNDKIT then
        PlaySound(SOUNDKIT.RAID_WARNING)
    end
    self:PointArrowAtRaidMember(playerName)
    promoteWatcher:RegisterEvent("GROUP_ROSTER_UPDATE")
end