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
    self:RefreshWarriorShoutBar()
    self:RefreshBuffChecklist()
    self:RefreshPallyPowerDiffView()
    self:RefreshStatusBarsView()
    -- Not a window of ours, but the same trigger: the spec icons we draw on
    -- Blizzard's raid frames move when the board does, and nothing on their
    -- side would ever repaint them. Throttled at its end, since this call
    -- rides the buff-tracking notify (RaidFrameExtensions.lua).
    self:RefreshRaidFrameRoleIcons()
    -- Same story for the role column on the Raid tab rows (RaidMenuExtensions.lua).
    self:RefreshRaidMenuRoles()
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

-- Hold a repaint while a dropdown menu is open, and run it once the menu
-- closes. Returns true when held: the caller skips its repaint.
--
-- A repaint that hides a row holding a dropdown closes every open dropdown in
-- the UI -- UIDropDownMenuTemplate's OnHide is a global CloseDropDownMenus(),
-- and UIDropDownMenu_Initialize on a new row hides every menu level outright.
-- Neither cares which window the menu belongs to. Mid-raid the triggers never
-- stop (talents land one inspect at a time, PallyPower traffic, buff changes),
-- so menus were yanked shut before they could be clicked.
--
-- Shared rather than per view because the close is global: one window's guard
-- does nothing while a window beside it repaints. `key` names the view, so a
-- burst of held requests flushes as one repaint each; `flush` is the view's
-- own stable function (no closure per call -- some of these ride the 10Hz
-- board notify), and checks for itself whether the view is still on screen.
--
-- A selection doesn't wait: Blizzard hides the list before running the
-- clicked button's func, so the repaint it causes finds nothing open.
local heldRepaints = {}

local function FlushHeldRepaints()
    if not next(heldRepaints) then return end
    local flushes = heldRepaints
    heldRepaints = {}
    for _, flush in pairs(flushes) do flush() end
end

if DropDownList1 then
    DropDownList1:HookScript("OnHide", FlushHeldRepaints)
end

function WhoDoesWhat:HoldRepaintWhileMenuOpen(key, flush)
    if not (DropDownList1 and DropDownList1:IsShown()) then return false end
    heldRepaints[key] = flush
    return true
end
