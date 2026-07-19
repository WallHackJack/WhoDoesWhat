local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")


-- ---------------------------------------------------------------------------
-- "Promote this player" highlight: a pulsing pointer plus an animated glow,
-- both anchored to a raid member's row in the Raid tab of the social frame,
-- since we can't promote for them.
-- ---------------------------------------------------------------------------

local promoteArrow
local promoteGlow
local promoteWatcher = CreateFrame("Frame")
local pendingPromote -- player name we're waiting to see promoted to MAINTANK
local openedRaidTab  -- true when we opened the raid window (so we may close it)

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

-- Build the arrow once: Blizzard's quest arrow, rotated to point left and
-- given a gentle horizontal bounce so it reads as "this row here." It lives
-- in its own TOOLTIP-strata frame -- a texture parented straight to UIParent
-- would draw underneath the Friends/Raid window no matter where we anchor it.
local function EnsurePromoteArrow()
    if promoteArrow then return promoteArrow end

    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("TOOLTIP")
    f:SetSize(32, 32)

    local a = f:CreateTexture(nil, "OVERLAY")
    a:SetAllPoints(f)
    a:SetTexture("Interface\\MINIMAP\\MiniMap-QuestArrow")
    if a.SetRotation then pcall(a.SetRotation, a, math.pi / 2) end -- up -> left

    local ag = f:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local move = ag:CreateAnimation("Translation")
    move:SetOffset(10, 0)
    move:SetDuration(0.5)
    move:SetSmoothing("IN_OUT")
    f.anim = ag

    f:Hide()
    promoteArrow = f
    return f
end

-- Build the glow once: Blizzard's quest-log row highlight -- a soft glow
-- built for wide list rows, so it stretches cleanly over the raid-tab row
-- (unlike the square action-button glows) -- tinted gold, ADD-blended, with
-- a looping alpha pulse. Same TOOLTIP-strata treatment as the arrow, for the
-- same reason.
local function EnsurePromoteGlow()
    if promoteGlow then return promoteGlow end

    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("TOOLTIP")

    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints(f)
    t:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    t:SetVertexColor(1, 0.82, 0.2)
    t:SetBlendMode("ADD")

    local ag = f:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local pulse = ag:CreateAnimation("Alpha")
    pulse:SetFromAlpha(0.25)
    pulse:SetToAlpha(1)
    pulse:SetDuration(0.5)
    pulse:SetSmoothing("IN_OUT")
    f.anim = ag

    f:Hide()
    promoteGlow = f
    return f
end

function WhoDoesWhat:HidePromoteArrow()
    if promoteArrow then
        promoteArrow.anim:Stop()
        promoteArrow:Hide()
    end
    if promoteGlow then
        promoteGlow.anim:Stop()
        promoteGlow:Hide()
    end
end

-- Point the arrow at a raid member's row (best effort). The raid grid lives
-- in Blizzard_RaidUI, a load-on-demand addon that only loads when the Raid
-- tab first shows -- so force-load it, then retry with growing delays while
-- the tab builds its rows. Auto-hides after a few seconds.
function WhoDoesWhat:PointArrowAtRaidMember(playerName)
    if not C_Timer then return end

    if RaidFrame_LoadUI then
        RaidFrame_LoadUI()
    end

    local delays = { 0.1, 0.5, 1.0 }
    local function try(attempt)
        local btn = FindRaidMemberButton(playerName)
        if btn then
            local a = EnsurePromoteArrow()
            -- Parent to the row itself so closing the raid window takes the
            -- arrow with it (re-assert strata: SetParent can reset it).
            a:SetParent(btn)
            a:SetFrameStrata("TOOLTIP")
            a:ClearAllPoints()
            a:SetPoint("LEFT", btn, "RIGHT", 6, 0) -- sit right of the row, pointing in
            a:Show()
            a.anim:Play()
            local g = EnsurePromoteGlow()
            g:SetParent(btn)
            g:SetFrameStrata("TOOLTIP")
            g:ClearAllPoints()
            g:SetPoint("TOPLEFT", btn, "TOPLEFT", -6, 3)
            g:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 6, -3)
            g:Show()
            g.anim:Play()
            C_Timer.After(8, function() self:HidePromoteArrow() end)
        elseif attempt < #delays then
            C_Timer.After(delays[attempt + 1], function() try(attempt + 1) end)
        else
            self:LogUiBuilding("Promote arrow: no visible raid-tab row for " .. tostring(playerName)
                .. " (RaidGroupButton1 exists: " .. tostring(_G["RaidGroupButton1"] ~= nil) .. ")")
        end
    end
    C_Timer.After(delays[1], function() try(1) end)
end

function WhoDoesWhat:StopPromoteWatch()
    pendingPromote = nil
    openedRaidTab = nil
    promoteWatcher:UnregisterAllEvents()
end

-- The payoff for the watcher: the moment the roster shows our pending player
-- as MAINTANK, drop the arrow and close the raid window (only if we were the
-- ones who opened it).
promoteWatcher:SetScript("OnEvent", function()
    if pendingPromote and GetPartyAssignment("MAINTANK", pendingPromote, true) then
        WhoDoesWhat:HidePromoteArrow()
        if openedRaidTab and FriendsFrame and FriendsFrame:IsShown() then
            HideUIPanel(FriendsFrame)
        end
        WhoDoesWhat:StopPromoteWatch()
    end
end)

-- Kick off the "please promote this tank" flow: open the social frame's Raid
-- tab (without toggling it closed when it's already there), point the arrow
-- at the player, and watch the roster so everything cleans itself up the
-- moment they actually get promoted.
function WhoDoesWhat:StartPromoteWatch(playerName)
    pendingPromote = playerName
    openedRaidTab = not (FriendsFrame and FriendsFrame:IsShown())
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