local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Combined traffic log for WhoDoesWhat's own sync and the PallyPower bridge.
-- Both histories are live, capped in their respective network modules, and
-- switchable here without opening competing debug windows.

local logFrame = nil
local showRaw = false
local source = "wdw"

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

local function FormatEntry(e, kind)
    local dirTag, who
    if e.dir == "out" then
        dirTag = "|cff40ff40OUT|r"
        who = "|cff909090" .. e.who .. "|r"
    else
        dirTag = "|cffffd000IN |r"
        who = ColoredWho(e.who)
    end
    local body
    if kind == "pp" then
        body = showRaw and e.msg or WhoDoesWhat:TranslatePallyPowerMessage(e.msg)
    else
        body = showRaw and e.raw or e.msg
    end
    local channel = e.channel and (" |cff707070[" .. e.channel .. "]|r") or ""
    return "|cff888888" .. e.t .. "|r " .. dirTag .. " " .. who .. channel .. "  " .. body
end

local function RenderAll(f)
    f.smf:Clear()
    local entries = source == "pp" and WhoDoesWhat.PallyPowerLog or WhoDoesWhat.SyncLog
    if #entries == 0 then
        f.smf:AddMessage(source == "pp"
            and "|cff909090No PallyPower traffic seen yet.|r"
            or "|cff909090No WhoDoesWhat sync traffic seen yet.|r")
        return
    end
    for _, e in ipairs(entries) do
        f.smf:AddMessage(FormatEntry(e, source))
    end
end

local function SelectSource(f, selected)
    source = selected
    f.wdwBtn:SetEnabled(source ~= "wdw")
    f.ppBtn:SetEnabled(source ~= "pp")
    RenderAll(f)
end

local function EnsureLogFrame()
    if logFrame then return logFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatPallyPowerLogFrame",
        FRAME_W, FRAME_H, "WhoDoesWhat - Sync Traffic")
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(420, 180)
    elseif f.SetMinResize then
        f:SetMinResize(420, 180)
    end

    local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clear:SetSize(50, 18)
    clear:SetPoint("TOPRIGHT", -MARGIN, -(f.titleBarHeight + 8))
    clear:SetText("Clear")
    clear:SetScript("OnClick", function()
        wipe(source == "pp" and WhoDoesWhat.PallyPowerLog or WhoDoesWhat.SyncLog)
        RenderAll(f)
    end)

    -- Raw toggle: show the wire text instead of the translations.
    local raw = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    raw:SetSize(20, 20)
    raw:SetPoint("RIGHT", clear, "LEFT", -40, 0)
    raw:SetChecked(showRaw)
    raw:SetScript("OnClick", function(self)
        showRaw = self:GetChecked() and true or false
        RenderAll(f)
    end)
    local rawLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rawLabel:SetPoint("RIGHT", raw, "LEFT", 0, 0)
    rawLabel:SetText("Raw")

    local wdwBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    wdwBtn:SetSize(92, 18)
    wdwBtn:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + 8))
    wdwBtn:SetText("WhoDoesWhat")
    wdwBtn:SetScript("OnClick", function() SelectSource(f, "wdw") end)
    f.wdwBtn = wdwBtn

    local ppBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    ppBtn:SetSize(82, 18)
    ppBtn:SetPoint("LEFT", wdwBtn, "RIGHT", 5, 0)
    ppBtn:SetText("PallyPower")
    ppBtn:SetScript("OnClick", function() SelectSource(f, "pp") end)
    f.ppBtn = ppBtn

    local smf = CreateFrame("ScrollingMessageFrame", nil, f)
    smf:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + 34))
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

    WhoDoesWhat:LogUiBuilding("Building sync traffic log content.")

    logFrame = f
    return f
end

-- Live feed from the bridge: append while open; a history trim means line
-- indices shifted, so redraw the lot instead.
function WhoDoesWhat:PallyPowerLogAppended(entry, trimmed)
    if not (logFrame and logFrame:IsShown() and source == "pp") then return end
    if trimmed then
        RenderAll(logFrame)
    else
        logFrame.smf:AddMessage(FormatEntry(entry, "pp"))
    end
end

function WhoDoesWhat:SyncLogAppended(entry, trimmed)
    if not (logFrame and logFrame:IsShown() and source == "wdw") then return end
    if trimmed then
        RenderAll(logFrame)
    else
        logFrame.smf:AddMessage(FormatEntry(entry, "wdw"))
    end
end

-- Toggle the combined log window. Asking for the other source while it is
-- already open switches tabs instead of unexpectedly closing it.
function WhoDoesWhat:OpenSyncLogView(selected)
    local f = EnsureLogFrame()

    if f:IsShown() then
        if selected and selected ~= source then
            SelectSource(f, selected)
            f:Raise()
            return
        end
        self:LogUiBuilding("Sync Traffic open, closing it.")
        f:Hide()
        return
    end

    self:LogUiBuilding("Opening Sync Traffic...")
    SelectSource(f, selected or source)
    f:Show()
    f:Raise()
end

function WhoDoesWhat:OpenPallyPowerLogView()
    self:OpenSyncLogView("pp")
end
