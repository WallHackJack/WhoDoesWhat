local L = select(2, ...).Locale:Register("enUS", "English")

-- English: every string WhoDoesWhat shows, and the fallback for any other
-- language's missing lines. Keys are grouped by where the string appears.
-- Strings with %s or %d are format strings; keep every placeholder when
-- translating. Plurals get a key per form (_ONE / _MANY).

-- Shared buttons
L["COMMON_CANCEL"] = "Cancel"
L["COMMON_RESET"] = "Reset"

-- The window kit's own words (WallhackUiKit.lua)
L["UI_WARNING"] = "Warning"
L["UI_ADD"] = "Add"
L["UI_HEX_COLOR"] = "Hex color"
L["UI_SWATCH_TIP"] = "Left-click for the WoW color picker; right-click to reset."
L["UI_HEX_TIP"] = "Enter a six-digit RGB color, with or without #, then press Enter."

-- Whispers. These go out in the recipient's Language when they run
-- WhoDoesWhat, and in the sender's Message language otherwise.
L["WHISPER_TAGGED"] = "[WhoDoesWhat] %s"
L["WHISPER_ASSIGNMENT"] = "Your assignment: %s"
-- Added to a whisper that does not already end in punctuation.
L["WHISPER_FULL_STOP"] = "."
