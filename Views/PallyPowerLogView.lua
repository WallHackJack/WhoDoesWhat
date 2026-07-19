local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- PallyPower Log ("PP Log" in the Paladin Info + Grid title bar): a live view
-- of the PLPWR addon-channel traffic the bridge captures
-- (PallyPowerBridge.lua), so what's normally invisible hidden-chat syncing
-- reads as a plain feed. One line per message: timestamp, direction (OUT is
-- ours, IN names the sender class-colored), and the bridge's translation --
-- or the raw wire text with the Raw checkbox on. New messages append live
-- while the window is open; the history (bridge-capped) re-renders whole on
-- open, on the Raw toggle, and after the bridge sheds old entries.

local logFrame = nil
local showRaw = false

local FRAME_W = 640
local FRAME_H = 340
local MARGIN = 10

-- Class-colored sender name; group members resolve through UnitClass, anyone
-- else (left the group, cross-realm oddity) stays neutral gray.
local function ColoredWho(name)
    local _, token = UnitClass(name)
    local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c and c.colorStr then
        return "|c" .. c.colorStr .. name .. "|r"
    end
    return "|cffc0c0c0" .. name .. "|r"
end

local function FormatEntry(e)
    local dirTag, who
    if e.dir == "out" then
        dirTag = "|cff40ff40OUT|r"
        who = "|cff909090" .. e.who .. "|r" -- the channel / whisper target
    else
        dirTag = "|cffffd000IN |r"
        who = ColoredWho(e.who)
    end
    local body = showRaw and e.msg or WhoDoesWhat:TranslatePallyPowerMessage(e.msg)
    return "|cff888888" .. e.t .. "|r " .. dirTag .. " " .. who .. "  " .. body
end

local function RenderAll(f)
    f.smf:Clear()
    local entries = WhoDoesWhat.PallyPowerLog
    if #entries == 0 then
        f.smf:AddMessage("|cff909090No PallyPower traffic seen yet. Messages"
            .. " appear when any paladin's PallyPower syncs (or when you press"
            .. " PP Sync).|r")
        return
    end
    for _, e in ipairs(entries) do
        f.smf:AddMessage(FormatEntry(e))
    end
end

local function EnsureLogFrame()
    if logFrame then return logFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatPallyPowerLogFrame",
        FRAME_W, FRAME_H, "WhoDoesWhat - PallyPower Log")
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(420, 180)
    elseif f.SetMinResize then
        f:SetMinResize(420, 180)
    end

    local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clear:SetSize(50, 18)
    clear:SetPoint("TOPRIGHT", -28, -6)
    clear:SetText("Clear")
    clear:SetScript("OnClick", function()
        wipe(WhoDoesWhat.PallyPowerLog)
        RenderAll(f)
    end)

    -- Raw toggle: show the wire text instead of the translations.
    local raw = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    raw:SetSize(20, 20)
    raw:SetPoint("TOPRIGHT", -116, -5)
    raw:SetChecked(showRaw)
    raw:SetScript("OnClick", function(self)
        showRaw = self:GetChecked() and true or false
        RenderAll(f)
    end)
    local rawLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rawLabel:SetPoint("RIGHT", raw, "LEFT", 0, 0)
    rawLabel:SetText("Raw")

    local smf = CreateFrame("ScrollingMessageFrame", nil, f)
    smf:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + 10))
    smf:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN)
    smf:SetFontObject(GameFontHighlightSmall)
    smf:SetJustifyH("LEFT")
    smf:SetFading(false)
    smf:SetMaxLines(600)
    smf:SetIndentedWordWrap(true)
    smf:EnableMouseWheel(true)
    smf:SetScript("OnMouseWheel", function(self, delta)
        if IsShiftKeyDown() then
            if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
        elseif delta > 0 then
            self:ScrollUp()
        else
            self:ScrollDown()
        end
    end)
    f.smf = smf

    -- Bottom-right resize grip (the window is otherwise fixed-size chrome).
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)

    WhoDoesWhat:LogUiBuilding("Building PallyPower log content.")

    logFrame = f
    return f
end

-- Live feed from the bridge: append while open; a history trim means line
-- indices shifted, so redraw the lot instead.
function WhoDoesWhat:PallyPowerLogAppended(entry, trimmed)
    if not (logFrame and logFrame:IsShown()) then return end
    if trimmed then
        RenderAll(logFrame)
    else
        logFrame.smf:AddMessage(FormatEntry(entry))
    end
end

-- Toggle the log window open/closed.
function WhoDoesWhat:OpenPallyPowerLogView()
    local f = EnsureLogFrame()

    if f:IsShown() then
        self:LogUiBuilding("PallyPower Log open, closing it.")
        f:Hide()
        return
    end

    self:LogUiBuilding("Opening PallyPower Log...")
    RenderAll(f)
    f:Show()
    f:Raise()
end
