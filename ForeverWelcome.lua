local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- A short hello the first time a character runs WhoDoesWhat on WoW Forever.
-- Three things worth saying to someone arriving from PallyPower: blessings are
-- computed from roles here rather than assigned by hand, the checklist's item
-- tables are still being filled in and reports help, and -- in red, because it
-- is the one that will otherwise read as a bug -- settings do not survive a
-- reload on this client.
--
-- Marked seen per character, so this is once per character by design. While the
-- beta never loads its saved variables that mark cannot persist and the notice
-- returns every session; the moment the client is fixed it behaves as intended
-- with no change here.

if not WhoDoesWhat.ClientFeatures.isForever then return end

-- The addon's own blue and gold (the same two the views use), and a red that
-- reads as a warning against the popup's dark backdrop.
local BLUE, YELLOW, RED = "|cff80c0ff", "|cffffd100", "|cffff4040"
local NAME = BLUE .. "WhoDoesWhat|r"

StaticPopupDialogs["WHODOESWHAT_FOREVER_WELCOME"] = {
    text = "Welcome to " .. NAME .. " for Forever!\n\n"
        .. "We do pally buffs a little bit differently. Assign players' roles "
        .. "(or scan them automatically in range) and their optimal blessings "
        .. "are computed automatically!\n\n"
        .. "If you notice items missing from the buff checklist, feel free to "
        .. "report their item id and spell id (from the buff).\n\n"
        .. "Use " .. YELLOW .. "/wdw|r or the " .. YELLOW
        .. "minimap button|r to open " .. NAME .. "!\n\n"
        .. RED .. "SETTINGS DO NOT SAVE YET DUE TO CLIENT RESTRICTIONS|r",
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
    StaticPopup_Show("WHODOESWHAT_FOREVER_WELCOME")
end)
