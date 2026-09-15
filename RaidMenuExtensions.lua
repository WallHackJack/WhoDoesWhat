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
local lastKlaxon           -- GetTime() of the last promote ping, to coalesce bursts

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
    -- Audible "action required" ping (raid-warning klaxon). Coalesced: a sweep
    -- that turns up three unpromoted tanks at once is ONE piece of news, and
    -- three overlapping raid warnings is just noise.
    if PlaySound and SOUNDKIT
        and (not lastKlaxon or GetTime() - lastKlaxon > 1) then
        lastKlaxon = GetTime()
        PlaySound(SOUNDKIT.RAID_WARNING)
    end
    self:PointArrowAtRaidMember(playerName)
    promoteWatcher:RegisterEvent("GROUP_ROSTER_UPDATE")
end

-- Catch up on every tank already waiting. Both the normal entry points are
-- EDGE-triggered -- a watch starts when this client sets a tank role, or when a
-- talent scan lands -- and neither fires when OUR OWN rank changes. So an
-- assistant promoted after the tanks were assigned had an empty pending set and
-- saw nothing on opening the Raid tab, indefinitely: opening the tab only draws
-- pending entries, it never discovers them.
--
-- Idempotent through StartPromoteWatch, so a tank already pending or already
-- promoted costs nothing and never re-klaxons.
function WhoDoesWhat:SweepPromoteWatch()
    if not self.db then return end
    if not self:CanPromoteMainTank() then return end
    for _, name in ipairs(self:GroupMemberNames()) do
        if self:IsMarkedTank(name)
            and not GetPartyAssignment("MAINTANK", name, true) then
            self:StartPromoteWatch(name)
        end
    end
end

-- Watch the one transition that leaves the flow stranded: gaining the rank
-- that lets us promote. Only on the false -> true edge, so the sweep isn't
-- paying for a roster walk on every GROUP_ROSTER_UPDATE -- and that event
-- fires on every UnitSetRole anyone makes.
local rankWatcher = CreateFrame("Frame")
local couldPromote = false
rankWatcher:RegisterEvent("GROUP_ROSTER_UPDATE")
rankWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
rankWatcher:SetScript("OnEvent", function()
    local now = WhoDoesWhat.db and WhoDoesWhat:CanPromoteMainTank() or false
    if now and not couldPromote then
        WhoDoesWhat:SweepPromoteWatch()
    end
    couldPromote = now
end)


-- ---------------------------------------------------------------------------
-- Role column on the Raid tab rows. Blizzard's row reads Name | Level | Class;
-- out of combat the Level fontstring is stretched across both the Level and
-- Class columns and shows the member's role icon and role name instead (a
-- question mark and their class name when the board has no role for them),
-- nudged right a little so it clears the name. It keeps Blizzard's own
-- colouring: class colour, red when dead, grey when offline.
--
-- The Class button's text is only hidden, never changed -- dragging it spawns
-- a class pullout titled with that text. Regions only: no new frames and
-- nothing re-parented (see the taint note in ShowHighlight). Combat gets
-- Blizzard's layout back, since RaidGroupFrame_Update keeps writing level
-- numbers into these rows through a fight.
-- ---------------------------------------------------------------------------

local LEVEL_WIDTH, LEVEL_HEIGHT, LEVEL_GAP = 23, 8, 2 -- Blizzard_RaidUI.xml
local ROLE_COLUMN_SHIFT = 8 -- ~10% further right; the right edge stays put
local ROLE_COLUMN_WIDTH = 75 - ROLE_COLUMN_SHIFT -- Level (23) + gap (2) + Class (50)
local ROLE_ICON_SIZE = 11
local UNKNOWN_ICON = 134400 -- INV_Misc_QuestionMark

local roleColumnInstalled = false
local taken = {}   -- row index -> true while the row wears the role column
local painted = {} -- row index -> text we last wrote into its Level string

-- Same name(-realm) key the board's assignments are stored under.
local function RosterKey(unit)
    local name, realm = UnitName(unit)
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function RoleColumnText(i)
    local unit = "raid" .. i
    local key = RosterKey(unit)
    local roleId = key and WhoDoesWhat:GetAssignedRole(key)
    if roleId then
        local _, role = WhoDoesWhat:FindRoleById(roleId)
        if role and role.name then
            local icon = role.icon and (WhoDoesWhat:RoleIconMarkup(role.icon, ROLE_ICON_SIZE) .. " ") or ""
            return icon .. role.name
        end
    end
    return WhoDoesWhat:RoleIconMarkup(UNKNOWN_ICON, ROLE_ICON_SIZE) .. " " .. (UnitClass(unit) or "")
end

-- Level hangs off the Name string; only the x offset changes.
local function AnchorLevel(i, level, x)
    level:ClearAllPoints()
    level:SetPoint("LEFT", _G["RaidGroupButton" .. i .. "Name"], "RIGHT", x, 0)
end

-- `force` rewrites the text even when it matches what we last painted, for
-- the paths where Blizzard has just overwritten it with a level.
local function PaintRow(i, force)
    local level = _G["RaidGroupButton" .. i .. "Level"]
    local class = _G["RaidGroupButton" .. i .. "Class"]
    if not (level and class and class.text) then return end
    if not taken[i] then
        taken[i] = true
        AnchorLevel(i, level, LEVEL_GAP + ROLE_COLUMN_SHIFT)
        level:SetSize(ROLE_COLUMN_WIDTH, 14)
        level:SetJustifyH("LEFT")
        class.text:SetAlpha(0)
        force = true
    end
    local text = RoleColumnText(i)
    if force or painted[i] ~= text then
        level:SetText(text)
        painted[i] = text
    end
end

local function RestoreRow(i)
    local level = _G["RaidGroupButton" .. i .. "Level"]
    local class = _G["RaidGroupButton" .. i .. "Class"]
    taken[i], painted[i] = nil, nil
    if not (level and class and class.text) then return end
    AnchorLevel(i, level, LEVEL_GAP)
    level:SetSize(LEVEL_WIDTH, LEVEL_HEIGHT)
    level:SetJustifyH("CENTER")
    local lvl = UnitLevel("raid" .. i)
    level:SetText(lvl and lvl > 0 and lvl or "")
    class.text:SetAlpha(1)
end

local function PaintRoleColumn(force)
    if not (roleColumnInstalled and WhoDoesWhat.db) or InCombatLockdown() then return end
    if not IsInRaid() then return end
    for i = 1, GetNumGroupMembers() do
        PaintRow(i, force)
    end
end

-- Board edits (roles, syncs, talent scans) ride RefreshBoardViews, which can
-- fire at 10Hz; a hidden Raid tab costs one visibility check, and a shown one
-- only rewrites rows whose text actually changed. OnShow catches up on edits
-- made while it was closed.
function WhoDoesWhat:RefreshRaidMenuRoles()
    if not (RaidFrame and RaidFrame:IsVisible()) then return end
    PaintRoleColumn(false)
end

local function InstallRoleColumn()
    if roleColumnInstalled or type(RaidGroupFrame_Update) ~= "function" then return end
    roleColumnInstalled = true
    hooksecurefunc("RaidGroupFrame_Update", function() PaintRoleColumn(true) end)
    hooksecurefunc("RaidGroupFrame_UpdateLevel", function(id)
        local i = tonumber(id)
        if i and taken[i] and not InCombatLockdown() then PaintRow(i, true) end
    end)
    if RaidFrame then
        RaidFrame:HookScript("OnShow", function() PaintRoleColumn(true) end)
    end
    PaintRoleColumn(true)
end

-- Blizzard_RaidUI is load-on-demand: it arrives the first time the Raid tab
-- opens. PLAYER_REGEN_DISABLED still runs before the lockdown starts, so the
-- rows are handed back while that's allowed.
local roleColumnWatcher = CreateFrame("Frame")
roleColumnWatcher:RegisterEvent("ADDON_LOADED")
roleColumnWatcher:RegisterEvent("PLAYER_REGEN_DISABLED")
roleColumnWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
roleColumnWatcher:SetScript("OnEvent", function(_, event, addon)
    if event == "ADDON_LOADED" then
        if addon == "Blizzard_RaidUI" or type(RaidGroupFrame_Update) == "function" then
            InstallRoleColumn()
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        for i in pairs(taken) do RestoreRow(i) end
    else
        PaintRoleColumn(true)
    end
end)
