local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local L = select(2, ...).L
local Fill = select(2, ...).Fill

-- A short hello the first time a character runs WhoDoesWhat on WoW Forever.
-- Two things worth saying to someone arriving from PallyPower: blessings are
-- computed from roles here rather than assigned by hand, and the checklist's
-- item tables are still being filled in and reports help.
--
-- Marked seen per character, so this is once per character by design.

if not WhoDoesWhat.ClientFeatures.isForever then return end

-- The addon's own blue and gold (the same two the views use).
local BLUE, YELLOW = "|cff80c0ff", "|cffffd100"
local NAME = BLUE .. "WhoDoesWhat|r"

-- The text is set when shown: the Language is only known once the addon has
-- initialized.
StaticPopupDialogs["WHODOESWHAT_FOREVER_WELCOME"] = {
    text = "",
    button1 = OKAY or "Okay",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    -- Out of the way of Blizzard's own popups, as the addon's others are.
    preferredIndex = 3,
}

-- On PLAYER_LOGIN rather than at load: the database is open by then, and a
-- notice that beats the UI onto the screen is one nobody reads.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    if not WhoDoesWhat.db then return end
    if WhoDoesWhat.db.char.foreverWelcomeSeen then return end
    WhoDoesWhat.db.char.foreverWelcomeSeen = true
    StaticPopupDialogs["WHODOESWHAT_FOREVER_WELCOME"].text = Fill(L.FOREVER_WELCOME, {
        addon = NAME, command = YELLOW .. "/wdw|r",
        button = YELLOW .. L.FOREVER_MINIMAP_BUTTON .. "|r" })
    StaticPopup_Show("WHODOESWHAT_FOREVER_WELCOME")
end)
