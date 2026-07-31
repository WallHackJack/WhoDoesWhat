local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- PallyPower Differences window (the Paladin Buffs section's "Check" button).
-- A read-only, formatted view of how PallyPower's live or mirrored board differs from the
-- plan a Send (SyncToPallyPower) would push -- the detail behind the section's
-- drift warning icon. Entries come from WhoDoesWhat:CheckPallyPowerSync
-- (structured: paladin, target, target role, want/have blessing + icons); this
-- view sorts them into aligned WDW/PallyPower columns. A "Send to PallyPower"
-- button pushes the plan and re-renders (now in sync); "Recheck" re-runs the compare, since
-- PallyPower can change from other paladins with no repaint here. Changes that
-- cannot be safely auto-sent can open the same window in warning mode, where
-- Recheck becomes Ignore.

local diffFrame = nil

local FRAME_W = 620
local FRAME_H = 420
local COMPACT_W = 390
local COMPACT_H = 92
local MARGIN = 10
local BOTTOM_STRIP = 30
local CONTENT_W = FRAME_W - MARGIN * 2 - 20
local TARGET_W = 230
local CELL_W = 160
local HEADER_H = 24
local GROUP_H = 24
local ROW_H = 26

-- Class-colored paladin name (they're all Paladins, but this matches the log
-- view and survives someone who just left the group as neutral gray).
local function ColoredWho(name)
    local _, token = UnitClass(name)
    local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c and c.colorStr then
        return "|c" .. c.colorStr .. name .. "|r"
    end
    return "|cffc0c0c0" .. name .. "|r"
end

local function SetAssignment(icon, text, id, name, texture, isWanted)
    icon:SetShown(texture ~= nil)
    if texture then icon:SetTexture(texture) end
    text:ClearAllPoints()
    text:SetPoint("LEFT", icon, texture and "RIGHT" or "LEFT",
        texture and 5 or 0, 0)
    text:SetText(id == 0 and (isWanted and "Clear" or "None") or name)
    if id == 0 then
        text:SetTextColor(0.55, 0.55, 0.55)
    elseif isWanted then
        text:SetTextColor(0.25, 1, 0.25)
    else
        text:SetTextColor(1, 0.38, 0.38)
    end
end

local function CreateDiffRow(content, index)
    local row = CreateFrame("Frame", nil, content)
    row:SetSize(CONTENT_W, ROW_H)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.035 or 0.07)

    local targetIcon = row:CreateTexture(nil, "ARTWORK")
    targetIcon:SetSize(18, 18)
    targetIcon:SetPoint("LEFT", 4, 0)
    row.targetIcon = targetIcon

    local target = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    target:SetPoint("LEFT", targetIcon, "RIGHT", 6, 0)
    target:SetWidth(TARGET_W - 30)
    target:SetJustifyH("LEFT")
    row.target = target

    local wantIcon = row:CreateTexture(nil, "ARTWORK")
    wantIcon:SetSize(18, 18)
    wantIcon:SetPoint("LEFT", TARGET_W + 8, 0)
    row.wantIcon = wantIcon
    local want = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    want:SetWidth(CELL_W - 28)
    want:SetJustifyH("LEFT")
    row.want = want

    local haveIcon = row:CreateTexture(nil, "ARTWORK")
    haveIcon:SetSize(18, 18)
    haveIcon:SetPoint("LEFT", TARGET_W + CELL_W + 8, 0)
    row.haveIcon = haveIcon
    local have = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    have:SetWidth(CELL_W - 28)
    have:SetJustifyH("LEFT")
    row.have = have

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if not self.targetRole then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.targetName, 1, 1, 1)
        GameTooltip:AddLine(self.targetRole, 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function SortDiffs(a, b)
    local ap, bp = a.paladin:lower(), b.paladin:lower()
    if ap ~= bp then return ap < bp end
    if a.isClass ~= b.isClass then return a.isClass end
    return a.target:lower() < b.target:lower()
end

local function SetCompact(f)
    f:SetSize(COMPACT_W, COMPACT_H)
    f.titleText:SetText("WhoDoesWhat - PallyPower")
    f.scroll:Hide()
    f.sendBtn:Hide()
    f.secondaryBtn:Hide()
end

local function SetExpanded(f)
    f:SetSize(FRAME_W, FRAME_H)
    f.titleText:SetText("WhoDoesWhat - PallyPower Differences")
    f.scroll:Show()
    f.sendBtn:Show()
    f.secondaryBtn:Show()
end

local function RenderDiffs(f)
    for _, row in ipairs(f.rows) do row:Hide() end
    for _, heading in ipairs(f.headings) do heading:Hide() end
    f.scroll:SetVerticalScroll(0)
    f.columnHeader:Hide()
    f.status:SetText(f.warningText
        and ("|cffff6060PallyPower was not auto-updated.|r " .. f.warningText)
        or "Comparing the current WDW plan with PallyPower.")

    local diffs = WhoDoesWhat:CheckPallyPowerSync()
    if diffs == nil then
        SetCompact(f)
        f.status:SetText("|cff909090There are no paladins in the group"
            .. " -- nothing to compare.|r")
        f.sendBtn:Disable()
        f.content:SetHeight(1)
        return false
    end
    if #diffs == 0 then
        SetCompact(f)
        f.status:SetText("|cff40ff40PallyPower matches the current WDW plan.|r")
        f.sendBtn:Disable()
        f.content:SetHeight(1)
        return false
    end
    SetExpanded(f)
    f.sendBtn:Enable()
    if not f.warningText then
        f.status:SetText("|cffffd000PallyPower is out of date.|r Press Send to push the WDW plan.")
    end

    table.sort(diffs, SortDiffs)
    f.columnHeader:Show()
    local y, rowIndex, headingIndex, lastPally = -HEADER_H, 0, 0, nil
    for _, d in ipairs(diffs) do
        if d.paladin ~= lastPally then
            headingIndex = headingIndex + 1
            local heading = f.headings[headingIndex]
            if not heading then
                heading = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                f.headings[headingIndex] = heading
            end
            heading:ClearAllPoints()
            heading:SetPoint("TOPLEFT", 4, y - 5)
            heading:SetText(ColoredWho(d.paladin))
            heading:Show()
            y = y - GROUP_H
            lastPally = d.paladin
        end

        rowIndex = rowIndex + 1
        local row = f.rows[rowIndex]
        if not row then
            row = CreateDiffRow(f.content, rowIndex)
            f.rows[rowIndex] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, y)
        row.targetIcon:SetShown(d.targetIcon ~= nil)
        if d.targetIcon then row.targetIcon:SetTexture(d.targetIcon) end
        row.target:ClearAllPoints()
        row.target:SetPoint("LEFT", d.targetIcon and row.targetIcon or row,
            d.targetIcon and "RIGHT" or "LEFT", d.targetIcon and 6 or 4, 0)
        row.target:SetText(d.isClass and (d.target .. "s") or d.target)
        row.targetName = d.target
        row.targetRole = d.targetRole
        SetAssignment(row.wantIcon, row.want, d.want, d.wantName, d.wantIcon, true)
        SetAssignment(row.haveIcon, row.have, d.have, d.haveName, d.haveIcon, false)
        row:Show()
        y = y - ROW_H
    end
    f.content:SetHeight(math.max(1, -y))
    return true
end

local function EnsureFrame()
    if diffFrame then return diffFrame end

    local f = WhoDoesWhat:CreateWindowFrame("WhoDoesWhatPallyPowerDiffFrame",
        FRAME_W, FRAME_H, "WhoDoesWhat - PallyPower Differences")

    local sendBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sendBtn:SetSize(130, 22)
    sendBtn:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN)
    sendBtn:SetText("Send to PallyPower")
    sendBtn:SetScript("OnClick", function()
        f.warningText = nil
        f.secondaryBtn:SetText("Recheck")
        WhoDoesWhat:SyncToPallyPower()
        WhoDoesWhat:RefreshMainAssignmentsView() -- clear the section's warning
        f:Hide()
    end)
    sendBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Send to PallyPower", 1, 1, 1)
        GameTooltip:AddLine("Broadcast the computed plan to PallyPower clients"
            .. " and update WDW's local mirror.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    sendBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.sendBtn = sendBtn

    local secondary = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    secondary:SetSize(80, 22)
    secondary:SetPoint("RIGHT", sendBtn, "LEFT", -6, 0)
    secondary:SetText("Recheck")
    secondary:SetScript("OnClick", function()
        if f.warningText then
            f.warningText = nil
            f:Hide()
        else
            RenderDiffs(f)
        end
    end)
    f.secondaryBtn = secondary

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    status:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + 10))
    status:SetPoint("TOPRIGHT", -MARGIN, -(f.titleBarHeight + 10))
    status:SetHeight(46)
    status:SetJustifyH("LEFT")
    status:SetJustifyV("TOP")
    f.status = status

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + 62))
    scroll:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN + BOTTOM_STRIP)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetPoint("TOPLEFT")
    content:SetWidth(CONTENT_W)
    content:SetHeight(1)
    scroll:SetScrollChild(content)
    scroll.scrollBarHideable = 1
    f.scroll = scroll
    f.content = content

    local columnHeader = CreateFrame("Frame", nil, content)
    columnHeader:SetSize(CONTENT_W, HEADER_H)
    columnHeader:SetPoint("TOPLEFT")
    local function Header(text, x, width, r, g, b)
        local fs = columnHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", x, 0)
        fs:SetWidth(width)
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        fs:SetTextColor(r, g, b)
    end
    Header("Target", 4, TARGET_W - 4, 0.8, 0.8, 0.8)
    Header("WDW plan", TARGET_W + 8, CELL_W - 8, 0.25, 1, 0.25)
    Header("PallyPower now", TARGET_W + CELL_W + 8, CELL_W - 8, 1, 0.38, 0.38)
    for _, x in ipairs({ TARGET_W, TARGET_W + CELL_W }) do
        local divider = content:CreateTexture(nil, "BORDER")
        divider:SetColorTexture(0.4, 0.4, 0.4, 0.35)
        divider:SetWidth(1)
        divider:SetPoint("TOP", content, "TOP", x, 0)
        divider:SetPoint("BOTTOM", content, "BOTTOM", x, 0)
    end
    f.columnHeader = columnHeader
    f.rows = {}
    f.headings = {}

    WhoDoesWhat:LogUiBuilding("Building PallyPower diff content.")

    diffFrame = f
    return f
end

-- Open (or re-render + raise) the PallyPower differences window. An optional
-- warning turns the secondary action into Ignore; manual Check opens normally.
function WhoDoesWhat:OpenPallyPowerDiffView(warningText)
    local f = EnsureFrame()
    f.warningText = warningText
    f.secondaryBtn:SetText(warningText and "Ignore" or "Recheck")
    local hasDiffs = RenderDiffs(f)
    if not warningText then self:RefreshMainAssignmentsView() end
    -- Automatic warnings are advisory, so do not raise a window when a fresh
    -- comparison says there is nothing left to review.
    if warningText and not hasDiffs then return end
    self:LogUiBuilding("Opening PallyPower Differences...")
    f:Show()
    f:Raise()
end
