local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Cross-view repaint coordination. Not a window: it owns no frames and draws
-- nothing, it only decides who gets told when the shared board changes.
--
-- This lived in BuffingGridView.lua, where it had grown out of that view's own
-- refresh -- which is how RefreshBuffingGridView ended up secretly repainting
-- four other views, and how a call site meaning "the board changed" ended up
-- reading as "repaint the grid". Splitting it out keeps every Views/<Window>
-- file responsible for exactly one window.

-- Everything derived from the shared board and the paladin buff plan, each
-- repainted exactly once. The individual refreshes no-op while their own window
-- is closed, and none of them fans out any further, so this is the whole cost
-- of a board repaint and it is paid once per call.
--
-- Deliberately NOT including RefreshMainAssignmentsView or
-- RefreshMembersView: those two are the big editable windows, they are not
-- driven by live buff state, and the buff-tracking notify would otherwise
-- repaint them at up to 10Hz. The handful of callers that genuinely change what
-- those show still call them directly, alongside this.
--
-- That exclusion got sharper when Action Items merged into the Members window.
-- RefreshActionItemsView used to ride along here, so "the board changed" quietly
-- repainted the roster issues too; now the same job is one more reason Members
-- is a direct call. The paths that move an issue all already make one -- Sync,
-- Permissions, SetAssignedRole, and RequestFullRefresh below for talents.
--
-- WDW Status goes last: it summarizes the others, so it should read state the
-- rest of the pass has already settled.
function WhoDoesWhat:RefreshBoardViews()
    self:RefreshBuffingGridView()
    self:RefreshRaiderTooltip()
    self:RefreshPaladinBuffingBar()
    self:RefreshPallyPowerDiffView()
    self:RefreshStatusBarsView()
end

-- Ask for a repaint of everything, without insisting on one right now.
--
-- For callers that fire PER PLAYER rather than per event. The talent pipeline
-- is why this exists: SyncRosterTalents replays the inspect cache for every
-- group member in one loop, and LibClassicInspector delivers TALENTS_READY a
-- player at a time as people come into range. Repainting inside those meant a
-- 40-man roster sweep did forty full repaints in a single frame -- a quarter of
-- a second of stall on zone-in -- and walking into a crowd did one per
-- stranger, including strangers already scanned once.
--
-- Covers the two big windows as well as the board, because a talent arrival can
-- settle a role, which moves the roster lists too. That is what these callers
-- were each doing individually.
--
-- Leading edge, like the buff-tracking notify: the first request after a quiet
-- spell repaints immediately, so a single inspect still feels instant.
-- Everything inside the interval collapses into one catch-up, which is what
-- turns a roster sweep into two repaints instead of forty.
local FULL_REFRESH_INTERVAL = 0.5
local fullPending, lastFullRefresh = false, 0

local function DoFullRefresh()
    lastFullRefresh = GetTime()
    WhoDoesWhat:RefreshMainAssignmentsView()
    WhoDoesWhat:RefreshMembersView()
    WhoDoesWhat:RefreshBoardViews()
end

function WhoDoesWhat:RequestFullRefresh()
    if fullPending then return end
    local elapsed = GetTime() - lastFullRefresh
    if elapsed >= FULL_REFRESH_INTERVAL then
        DoFullRefresh()
        return
    end
    fullPending = true
    C_Timer.After(FULL_REFRESH_INTERVAL - elapsed, function()
        fullPending = false
        DoFullRefresh()
    end)
end
