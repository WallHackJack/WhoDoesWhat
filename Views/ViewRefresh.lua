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
-- RefreshRaiderRolesView: those two are the big editable windows, they are not
-- driven by live buff state, and the buff-tracking notify would otherwise
-- repaint them at up to 10Hz. The handful of callers that genuinely change what
-- those show still call them directly, alongside this.
--
-- WDW Status goes last: it summarizes the others, so it should read state the
-- rest of the pass has already settled.
function WhoDoesWhat:RefreshBoardViews()
    self:RefreshBuffingGridView()
    self:RefreshRaiderTooltip()
    self:RefreshPaladinBuffingBar()
    self:RefreshPallyPowerDiffView()
    self:RefreshActionItemsView()
    self:RefreshStatusBarsView()
end
