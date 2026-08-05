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
    h.button = nil
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

local function ShowHighlight(playerName, btn, attempt)
    WhoDoesWhat:LogRolePromotion("Raid row resolved",
        "player=" .. tostring(playerName),
        "attempt=" .. tostring(attempt),
        "button=" .. tostring(btn:GetName()))
    local h = highlights[playerName]
    if not h then
        h = tremove(highlightPool) or CreateHighlight()
        highlights[playerName] = h
    end
    -- Keep addon frames outside Blizzard's protected RaidFrame tree; parenting
    -- them to RaidGroupButton taints a later in-combat show.
    h.button = btn
    local a = h.arrow
    a:ClearAllPoints()
    a:SetPoint("LEFT", btn, "RIGHT", 6, 0)
    a:Show()
    a.anim:Play()
    local g = h.glow
    g:ClearAllPoints()
    g:SetPoint("TOPLEFT", btn, "TOPLEFT", -6, 3)
    g:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 6, -3)
    g:Show()
    g.anim:Play()
end

-- Point at a visible raid row without loading or opening Blizzard's Raid UI.
-- Addon-driven panel opens can taint a later native in-combat RaidFrame:Show,
-- so the leader opens the Raid tab and this watcher notices its rows.
function WhoDoesWhat:PointArrowAtRaidMember(playerName)
    if not C_Timer then return end

    local delays = { 0.1, 0.5, 1.0 }
    local function try(attempt)
        if not pendingPromotes[playerName] then return end -- promoted / cancelled meanwhile
        local btn = FindRaidMemberButton(playerName)
        if btn then
            ShowHighlight(playerName, btn, attempt)
        elseif attempt < #delays then
            C_Timer.After(delays[attempt + 1], function() try(attempt + 1) end)
        else
            self:LogRolePromotion("Raid row unresolved",
                "player=" .. tostring(playerName),
                "attempts=" .. tostring(attempt),
                "button1Exists=" .. tostring(_G["RaidGroupButton1"] ~= nil))
            self:LogUiBuilding("Promote arrow: no visible raid-tab row for " .. tostring(playerName)
                .. " (RaidGroupButton1 exists: " .. tostring(_G["RaidGroupButton1"] ~= nil) .. ")")
        end
    end
    C_Timer.After(delays[1], function() try(1) end)
end

-- Tear the whole flow down without touching Blizzard's protected panel state.
function WhoDoesWhat:StopPromoteWatch()
    for name in pairs(pendingPromotes) do pendingPromotes[name] = nil end
    for name in pairs(highlights) do HideHighlight(name) end
    promoteWatcher:UnregisterAllEvents()
end

-- Roster watcher: as tanks get promoted, drop each one's highlight. Rows can
-- shift index as the roster changes, so re-point whoever is still waiting.
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

-- UIParent-owned highlights do not inherit the raid row's visibility, so
-- mirror it without modifying the protected row or RaidFrame hierarchy.
local rowPollElapsed = 0
promoteWatcher:SetScript("OnUpdate", function(_, elapsed)
    rowPollElapsed = rowPollElapsed + elapsed
    if rowPollElapsed < 0.25 then return end
    rowPollElapsed = 0
    for name in pairs(pendingPromotes) do
        if not highlights[name] then
            local btn = FindRaidMemberButton(name)
            if btn then ShowHighlight(name, btn, "poll") end
        end
    end
    for _, h in pairs(highlights) do
        local visible = h.button and h.button:IsVisible()
        if visible and not h.arrow:IsShown() then
            h.arrow:Show()
            h.arrow.anim:Play()
            h.glow:Show()
            h.glow.anim:Play()
        elseif not visible and h.arrow:IsShown() then
            h.arrow.anim:Stop()
            h.arrow:Hide()
            h.glow.anim:Stop()
            h.glow:Hide()
        end
    end
end)

-- Add a tank to the "please promote this player to main tank" flow. The leader
-- opens Blizzard's Raid tab; we point at the row once it becomes visible and
-- watch the roster until promotion. Idempotent per player -- a tank
-- already pending, or already MAINTANK, is a no-op, so the 60s talent
-- rebroadcast that re-runs the scan won't re-nag or replay the klaxon.
function WhoDoesWhat:StartPromoteWatch(playerName)
    -- Same master opt-out as the role flags (Settings > General): a raid that
    -- has told WDW to keep its hands off Blizzard group state doesn't want the
    -- klaxon and the arrow either. Guarded here rather than at each caller so
    -- both the direct tank-role set and the first-scan sweep are covered.
    if not self:ManagesBlizzardRoles() then return end
    local mainTank = GetPartyAssignment("MAINTANK", playerName, true)
    local pending = pendingPromotes[playerName] and true or false
    self:LogRolePromotion("Promotion watch",
        "player=" .. tostring(playerName),
        "mainTank=" .. tostring(mainTank),
        "pending=" .. tostring(pending),
        "combat=" .. tostring(InCombatLockdown()))
    if mainTank then return end -- already main tank
    if pending then return end -- already waiting on them

    pendingPromotes[playerName] = true

    self:LogRolePromotion("Raid window observed",
        "shown=" .. tostring(FriendsFrame and FriendsFrame:IsShown()),
        "selectedTab=" .. tostring(FriendsFrame and FriendsFrame.selectedTab),
        "raidButton1Exists=" .. tostring(_G["RaidGroupButton1"] ~= nil))
    -- Audible "action required" ping (raid-warning klaxon)
    if PlaySound and SOUNDKIT then
        PlaySound(SOUNDKIT.RAID_WARNING)
    end
    self:PointArrowAtRaidMember(playerName)
    promoteWatcher:RegisterEvent("GROUP_ROSTER_UPDATE")
end
