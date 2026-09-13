local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local UI = select(2, ...).UI

-- Combined traffic log for WhoDoesWhat's own sync and the PallyPower bridge.
-- Both histories are live, capped in their respective network modules, and
-- switchable here without opening competing debug windows.

local logFrame = nil
local source = "wdw"
local SOURCE_LABELS = { wdw = "WhoDoesWhat", pp = "PallyPower" }
local display = { wdw = "summary", pp = "summary" }
-- Per-source inbound sender filter; nil means everyone. Our own outbound
-- traffic and the push markers always survive the filter -- the whole point of
-- picking one sender is reading their replies AGAINST what we sent.
local senderFilter = { wdw = nil, pp = nil }
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

local function Entries()
    return source == "pp" and WhoDoesWhat.PallyPowerLog or WhoDoesWhat.SyncLog
end

-- Distinct inbound senders in the active log, sorted, for the filter dropdown.
local function KnownSenders()
    local seen, names = {}, {}
    for _, e in ipairs(Entries()) do
        if e.dir == "in" and e.who and not seen[e.who] then
            seen[e.who] = true
            names[#names + 1] = e.who
        end
    end
    table.sort(names)
    return names
end

local function PassesFilter(e)
    local want = senderFilter[source]
    return not want or e.dir ~= "in" or e.who == want
end

local function FormatEntry(e, kind)
    -- Push brackets written by the PallyPower bridge: no sender, full width,
    -- so an explicit push and PallyPower's answer to it are visually separated.
    if e.dir == "mark" then
        return "|cff888888" .. e.t .. "|r |cff00d0ff== " .. e.msg .. " ==|r"
    end

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

local function SenderLabel()
    return "From: " .. (senderFilter[source] or "All")
end

local function RenderAll(f)
    f.smf:Clear()
    UIDropDownMenu_SetText(f.senderDD, SenderLabel())
    local entries = Entries()
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
    local shown = 0
    for _, e in ipairs(entries) do
        if PassesFilter(e) then
            f.smf:AddMessage(FormatEntry(e, source))
            shown = shown + 1
        end
    end
    if shown == 0 then
        f.smf:AddMessage("|cff909090Nothing from " .. tostring(senderFilter[source])
            .. " in the captured traffic.|r")
    end
end

local function SelectSource(f, selected)
    source = selected
    UIDropDownMenu_SetSelectedValue(f.sourceDD, source)
    UIDropDownMenu_SetText(f.sourceDD, SOURCE_LABELS[source])
    UIDropDownMenu_SetSelectedValue(f.displayDD, display[source])
    UIDropDownMenu_SetText(f.displayDD, DisplayLabel(source))
    UIDropDownMenu_SetSelectedValue(f.senderDD, senderFilter[source] or "")
    RenderAll(f)
end

local function SelectSender(f, selected)
    senderFilter[source] = selected ~= "" and selected or nil
    UIDropDownMenu_SetSelectedValue(f.senderDD, selected)
    RenderAll(f)
end

local function SelectDisplay(f, selected)
    display[source] = selected
    UIDropDownMenu_SetSelectedValue(f.displayDD, selected)
    UIDropDownMenu_SetText(f.displayDD, DisplayLabel(source))
    RenderAll(f)
end

-- Build the page into the Logs tab; the log fills the page.
function WhoDoesWhat:BuildSyncLogPage(page)
    local f = CreateFrame("Frame", nil, page)
    f:SetAllPoints(page)
    f.titleBarHeight = 0

    local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clear:SetSize(50, 18)
    clear:SetPoint("TOPRIGHT", -MARGIN, -(f.titleBarHeight + 8))
    clear:SetText("Clear")
    clear:SetScript("OnClick", function()
        wipe(source == "pp" and WhoDoesWhat.PallyPowerLog or WhoDoesWhat.SyncLog)
        RenderAll(f)
    end)

    local logging = UI.CreateCheckbox(f, "Log", "Sync traffic logging",
        "Capture WhoDoesWhat and PallyPower traffic and print WDW sync"
        .. " diagnostics to chat. Resets off on reload.",
        function(self) WhoDoesWhat:SetSyncLoggingEnabled(self:GetChecked()) end,
        { size = 20, font = "GameFontNormalSmall", gap = 0, labelParent = f })
    logging:SetPoint("RIGHT", clear, "LEFT", -22, 0)
    logging:SetChecked(WhoDoesWhat.LOG_SYNC)
    logging:SetHitRectInsets(0, -logging.label:GetStringWidth() - 4, 0, 0)
    f.loggingCheck = logging

    local sourceDD = UI.CreateMenuDropdown(f, "WhoDoesWhatSyncLogSourceDD", 125)
    sourceDD:SetPoint("TOPLEFT", MARGIN - 15, -(f.titleBarHeight + 1))
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

    local displayDD = UI.CreateMenuDropdown(f, "WhoDoesWhatSyncLogDisplayDD", 145)
    displayDD:SetPoint("LEFT", sourceDD, "RIGHT", -25, 0)
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

    -- Rebuilt on every open: who has spoken changes as the raid fills up.
    local senderDD = UI.CreateMenuDropdown(f, "WhoDoesWhatSyncLogSenderDD", 110)
    senderDD:SetPoint("LEFT", displayDD, "RIGHT", -25, 0)
    UIDropDownMenu_Initialize(senderDD, function(_, level)
        local info = UIDropDownMenu_CreateInfo()
        info.text = "All senders"
        info.value = ""
        info.checked = senderFilter[source] == nil
        info.func = function() SelectSender(f, "") end
        UIDropDownMenu_AddButton(info, level)
        for _, name in ipairs(KnownSenders()) do
            local selected = name
            info = UIDropDownMenu_CreateInfo()
            info.text = ColoredWho(selected)
            info.value = selected
            info.checked = senderFilter[source] == selected
            info.func = function() SelectSender(f, selected) end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    f.senderDD = senderDD

    local smf = CreateFrame("ScrollingMessageFrame", nil, f)
    smf:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + 34))
    smf:SetPoint("BOTTOMRIGHT", -MARGIN, 0)
    smf:SetFontObject(GameFontHighlightSmall)
    smf:SetJustifyH("LEFT")
    smf:SetFading(false)
    smf:SetMaxLines(4000) -- must not undercut the bridge's history cap
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

    -- Redrawn whenever the page comes up: history kept arriving while it was away.
    f:SetScript("OnShow", function(self) SelectSource(self, source) end)

    WhoDoesWhat:LogUiBuilding("Building sync traffic log content.")

    logFrame = f
    return f
end

-- Live feed from the bridge: append while open; a history trim means line
-- indices shifted, so redraw the lot instead.
function WhoDoesWhat:PallyPowerLogAppended(entry, trimmed)
    if not (logFrame and logFrame:IsVisible() and source == "pp") then return end
    if trimmed then
        RenderAll(logFrame)
    elseif PassesFilter(entry) then
        logFrame.smf:AddMessage(FormatEntry(entry, "pp"))
    end
end

function WhoDoesWhat:SyncLogAppended(entry, trimmed)
    if not (logFrame and logFrame:IsVisible() and source == "wdw") then return end
    if trimmed then
        RenderAll(logFrame)
    elseif PassesFilter(entry) then
        logFrame.smf:AddMessage(FormatEntry(entry, "wdw"))
    end
end

function WhoDoesWhat:RefreshSyncLogLoggingCheck()
    if logFrame and logFrame.loggingCheck then
        logFrame.loggingCheck:SetChecked(self.LOG_SYNC)
        RenderAll(logFrame)
    end
end

-- Open the main window on the Logs tab, or close it if it is already there.
-- Asking for the other source while the logs are up switches source instead of
-- unexpectedly closing them.
function WhoDoesWhat:OpenSyncLogView(selected)
    local switching = selected and selected ~= source
    if self:ShowMainTab("logs", switching) and selected then
        SelectSource(logFrame, selected)
    end
end

function WhoDoesWhat:OpenPallyPowerLogView()
    self:OpenSyncLogView("pp")
end
