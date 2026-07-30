local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Combined traffic log for WhoDoesWhat's own sync and the PallyPower bridge.
-- Both histories are live, capped in their respective network modules, and
-- switchable here without opening competing debug windows.

local logFrame = nil
local source = "wdw"
local SOURCE_LABELS = { wdw = "WhoDoesWhat", pp = "PallyPower" }
local display = { wdw = "summary", pp = "summary" }
local DISPLAY_OPTIONS = {
    wdw = {
        { key = "summary", label = "Summary" },
        { key = "decoded", label = "Decoded payload" },
        { key = "encoded", label = "Raw encoded (hex)" },
    },
    pp = {
        { key = "summary", label = "Summary" },
        { key = "raw", label = "Raw payload" },
    },
}

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

local function Hex(text)
    return string.format("%d bytes: %s", #text,
        (text:gsub(".", function(c) return string.format("%02X", string.byte(c)) end)))
end

local function DisplayLabel(kind)
    for _, option in ipairs(DISPLAY_OPTIONS[kind]) do
        if option.key == display[kind] then return option.label end
    end
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
        if display.pp == "raw" then
            body = e.msg
        else
            e.translated = e.translated or WhoDoesWhat:TranslatePallyPowerMessage(e.msg)
            body = e.translated
        end
    elseif display.wdw == "encoded" then
        e.encodedHex = e.encodedHex or Hex(e.encoded)
        body = e.encodedHex
    elseif display.wdw == "decoded" then
        e.decoded = e.decoded or WhoDoesWhat:DecodeSyncLogEntry(e.encoded)
        body = e.decoded
    else
        body = e.msg
    end
    local channel = e.channel and (" |cff707070[" .. e.channel .. "]|r") or ""
    return "|cff888888" .. e.t .. "|r " .. dirTag .. " " .. who .. channel .. "  " .. body
end

local function RenderAll(f)
    f.smf:Clear()
    local entries = source == "pp" and WhoDoesWhat.PallyPowerLog or WhoDoesWhat.SyncLog
    if #entries == 0 then
        if not WhoDoesWhat.LOG_SYNC then
            f.smf:AddMessage("|cff909090Logging is off. Enable Log to capture new traffic.|r")
        else
            f.smf:AddMessage(source == "pp"
                and "|cff909090No PallyPower traffic seen yet.|r"
                or "|cff909090No WhoDoesWhat sync traffic seen yet.|r")
        end
        return
    end
    for _, e in ipairs(entries) do
        f.smf:AddMessage(FormatEntry(e, source))
    end
end

local function SelectSource(f, selected)
    source = selected
    UIDropDownMenu_SetSelectedValue(f.sourceDD, source)
    UIDropDownMenu_SetText(f.sourceDD, SOURCE_LABELS[source])
    UIDropDownMenu_SetSelectedValue(f.displayDD, display[source])
    UIDropDownMenu_SetText(f.displayDD, DisplayLabel(source))
    RenderAll(f)
end

local function SelectDisplay(f, selected)
    display[source] = selected
    UIDropDownMenu_SetSelectedValue(f.displayDD, selected)
    UIDropDownMenu_SetText(f.displayDD, DisplayLabel(source))
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

    local logging = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    logging:SetSize(20, 20)
    logging:SetPoint("RIGHT", clear, "LEFT", -22, 0)
    logging:SetChecked(WhoDoesWhat.LOG_SYNC)
    logging:SetScript("OnClick", function(self)
        WhoDoesWhat:SetSyncLoggingEnabled(self:GetChecked())
    end)
    logging:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Sync traffic logging", 1, 1, 1)
        GameTooltip:AddLine("Capture WhoDoesWhat and PallyPower traffic and print WDW"
            .. " sync diagnostics to chat. Resets off on reload.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    logging:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local loggingLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    loggingLabel:SetPoint("LEFT", logging, "RIGHT", 0, 0)
    loggingLabel:SetText("Log")
    logging:SetHitRectInsets(0, -loggingLabel:GetStringWidth() - 4, 0, 0)
    f.loggingCheck = logging

    local sourceDD = CreateFrame("Frame", "WhoDoesWhatSyncLogSourceDD", f,
        "UIDropDownMenuTemplate")
    sourceDD:SetPoint("TOPLEFT", MARGIN - 15, -(f.titleBarHeight + 1))
    UIDropDownMenu_SetWidth(sourceDD, 125)
    UIDropDownMenu_Initialize(sourceDD, function(_, level)
        for _, key in ipairs({ "wdw", "pp" }) do
            local selected = key
            local info = UIDropDownMenu_CreateInfo()
            info.text = SOURCE_LABELS[selected]
            info.value = selected
            info.checked = source == selected
            info.func = function() SelectSource(f, selected) end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.sourceDD = sourceDD

    local displayDD = CreateFrame("Frame", "WhoDoesWhatSyncLogDisplayDD", f,
        "UIDropDownMenuTemplate")
    displayDD:SetPoint("LEFT", sourceDD, "RIGHT", -25, 0)
    UIDropDownMenu_SetWidth(displayDD, 145)
    UIDropDownMenu_Initialize(displayDD, function(_, level)
        for _, option in ipairs(DISPLAY_OPTIONS[source]) do
            local selected = option.key
            local info = UIDropDownMenu_CreateInfo()
            info.text = option.label
            info.value = selected
            info.checked = display[source] == selected
            info.func = function() SelectDisplay(f, selected) end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.displayDD = displayDD

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

function WhoDoesWhat:RefreshSyncLogLoggingCheck()
    if logFrame and logFrame.loggingCheck then
        logFrame.loggingCheck:SetChecked(self.LOG_SYNC)
        RenderAll(logFrame)
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
