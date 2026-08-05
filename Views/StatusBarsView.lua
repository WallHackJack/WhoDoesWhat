local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local K = WhoDoesWhat.SectionKit

-- Movable compact status-bars view of paladin and core raid-buff coverage:
--
--   [role icon] [Paladin name                     % / check]
--               [dark red ---------------------------> paladin pink]
--   [buff icon] [Fortitude                        % / check]
--   [   PP    ] [sync status]
--
-- It shares the Paladin Buffing Bar's small window chrome and Alt-drag
-- behavior, but is display-only. Coverage comes from the same active plan and
-- aura state as the Paladin Buffs section.

local view

local INSET = 3
local PAD = 4
local TITLE_H = 12
local CONTENT_TOP = INSET + TITLE_H + 3
local ROW_H = 19
local ICON_SIZE = 18
local BAR_H = 18
local EMPTY_ICON_SIZE = math.floor(BAR_H * 0.8 + 0.5)
local DEFAULT_W = 220
local MIN_W = 90
local RESIZE_MIN_W = 68
local HIDE_NAMES_W = 105
local ULTRA_COMPACT_W = 115
local HANDLE_W = 4
local READY_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"
local NOT_READY_ICON = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local LCG = LibStub("LibCustomGlow-1.0", true)

local function StatusBarsAnchor()
    return WhoDoesWhat.db.profile.settings.overviewAnchor or "TOPLEFT"
end

local function IsRightAnchor(anchor)
    return string.find(anchor, "RIGHT", 1, true) ~= nil
end

local function IsBottomAnchor(anchor)
    return string.find(anchor, "BOTTOM", 1, true) ~= nil
end

local paladinClass
local classColors = {}
for _, classInfo in ipairs(WhoDoesWhat.Classes) do
    classColors[classInfo.name] = classInfo.colorRGB
    if classInfo.name == "Paladin" then
        paladinClass = classInfo
    end
end

local function CoverageColor(correct, total, endpoint)
    if total == 0 then return 0.4, 0.4, 0.4 end
    local t = math.min((correct / total) / 0.8, 1)
    endpoint = endpoint or paladinClass.colorRGB
    return 0.35 + (endpoint.r - 0.35) * t,
        0.04 + (endpoint.g - 0.04) * t,
        0.08 + (endpoint.b - 0.08) * t
end

local function ClampPosition(x, y, anchor)
    local parentW, parentH = UIParent:GetWidth(), UIParent:GetHeight()
    if IsRightAnchor(anchor) then
        x = math.max(math.min(view:GetWidth(), parentW), math.min(x, parentW))
    else
        x = math.max(0, math.min(x, math.max(0, parentW - view:GetWidth())))
    end
    if IsBottomAnchor(anchor) then
        y = math.max(0, math.min(y, math.max(0, parentH - view:GetHeight())))
    else
        y = math.max(math.min(view:GetHeight(), parentH), math.min(y, parentH))
    end
    return x, y
end

local function SavePosition()
    if not view then return end
    local anchor = StatusBarsAnchor()
    local x = IsRightAnchor(anchor) and view:GetRight() or view:GetLeft()
    local y = IsBottomAnchor(anchor) and view:GetBottom() or view:GetTop()
    if x and y then
        x, y = ClampPosition(x, y, anchor)
        WhoDoesWhat.db.profile.settings.overviewPos = {
            x = x, y = y, anchor = anchor,
        }
    end
end

local function LoadPosition()
    local settings = WhoDoesWhat.db.profile.settings
    local p = settings.overviewPos
    local anchor = StatusBarsAnchor()
    view:ClearAllPoints()
    if p and p.x and p.y then
        -- Migrate either coordinate format used by the discarded scale grip.
        if p.screenPixels then
            local scale = view:GetEffectiveScale()
            p.x, p.y = p.x / scale, p.y / scale
            p.screenPixels = nil
        elseif settings.overviewScale then
            p.x = p.x * settings.overviewScale
            p.y = p.y * settings.overviewScale
        end
        local oldAnchor = p.anchor or "TOPLEFT"
        if IsRightAnchor(oldAnchor) ~= IsRightAnchor(anchor) then
            p.x = p.x + (IsRightAnchor(anchor) and view:GetWidth()
                or -view:GetWidth())
        end
        if IsBottomAnchor(oldAnchor) ~= IsBottomAnchor(anchor) then
            p.y = p.y + (IsBottomAnchor(anchor) and -view:GetHeight()
                or view:GetHeight())
        end
        p.anchor = anchor
        p.x, p.y = ClampPosition(p.x, p.y, anchor)
        view:SetPoint(anchor, UIParent, "BOTTOMLEFT", p.x, p.y)
    else
        view:SetPoint(anchor, UIParent, "CENTER", 0, -80)
    end
    settings.overviewScale = nil
end

local function AttachAltDrag(region)
    region:EnableMouse(true)
    region:RegisterForDrag("LeftButton")
    region:SetScript("OnDragStart", function()
        if not IsAltKeyDown() then return end
        view.moving = true
        view:StartMoving()
    end)
    region:SetScript("OnDragStop", function()
        if not view.moving then return end
        view.moving = nil
        view:StopMovingOrSizing()
        SavePosition()
        LoadPosition()
    end)
end

-- Shift-click anywhere in the window is a shortcut to the buff views. Shift on
-- both halves matches the Paladin Bar's title strip, and leaves the plain
-- clicks to the rows themselves (the PallyPower row opens the diff view).
local function StatusBarsClick(_, button)
    if not IsShiftKeyDown() then return end
    if button == "RightButton" then
        WhoDoesWhat:OpenAddonSettingsView("Buff Tracking")
    elseif button == "LeftButton" then
        WhoDoesWhat:OpenBuffingGridView()
    end
end

-- Same double-line shortcut layout the minimap button uses.
local function AddShortcutTooltipLines()
    GameTooltip:AddDoubleLine("Shift-Left-Click:", "Buffing Grid",
        1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Shift-Right-Click:", "Buff Settings",
        1, 0.82, 0, 1, 1, 1)
end

local function RoleIcon(name)
    local roleId = WhoDoesWhat:GetAssignedRole(name)
    if roleId then
        local _, role = WhoDoesWhat:FindRoleById(roleId)
        if role and role.icon then return role.icon end
    end
    return paladinClass and paladinClass.classIcon
end

local function SetDesyncGlow(row, shown)
    if not LCG then return end
    if shown and not row.desyncGlow then
        LCG.PixelGlow_Start(row, nil, 16, nil, 3, nil, nil, nil, nil, nil, 4)
        row.desyncGlow = true
    elseif not shown and row.desyncGlow then
        LCG.PixelGlow_Stop(row)
        row.desyncGlow = nil
    end
end

-- Progress text stays right-aligned regardless of the fill position.
local function LayoutProgressLabel(row)
    if row.correct == nil then return end

    local unavailable = row.total == 0
    local complete = not unavailable and row.correct >= row.total
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", row.status, "LEFT", 2, 0)
    row.name:SetShown(view:GetWidth() >= HIDE_NAMES_W)
    row.initial:SetShown(row.isPaladin and view:GetWidth() < HIDE_NAMES_W)

    if row.colorPreview then
        row.completeIcon:Hide()
        row.percent:SetText("...")
        row.percent:Show()
        row.percent:ClearAllPoints()
        row.percent:SetPoint("RIGHT", row.status, "RIGHT", -3, 0)
        row.name:SetPoint("RIGHT", row.percent, "LEFT", -4, 0)
        return
    end

    if complete or unavailable then
        row.percent:Hide()
        row.completeIcon:ClearAllPoints()
        row.completeIcon:SetSize(14, unavailable and 14 or math.floor(14 * 0.8 + 0.5))
        row.completeIcon:SetPoint("RIGHT", row.status, "RIGHT", -2, 0)
        local completeTexture = row.negative and row.saturatedStyle == "x"
            and NOT_READY_ICON or READY_ICON
        row.completeIcon:SetTexture(unavailable
            and (row.awaitingTalents and WhoDoesWhat.WARNING_ICON or NOT_READY_ICON)
            or completeTexture)
        row.completeIcon:Show()
        row.name:SetPoint("RIGHT", row.completeIcon, "LEFT", -4, 0)
        return
    end

    row.completeIcon:Hide()
    local ratio = row.total > 0 and row.correct / row.total or 0
    if row.display == "missing" then
        row.percent:SetText(tostring(row.total - row.correct))
    elseif row.display == "fraction" then
        row.percent:SetText(row.correct .. "/" .. row.total)
    elseif row.display == "applied" then
        row.percent:SetText(tostring(row.correct))
    else
        row.percent:SetText(math.floor(ratio * 100 + 0.5) .. "%")
    end
    row.percent:Show()
    row.percent:ClearAllPoints()
    row.percent:SetPoint("RIGHT", row.status, "RIGHT", -3, 0)
    row.name:SetPoint("RIGHT", row.percent, "LEFT", -4, 0)
end

local function LayoutPallyPowerRow(row)
    local width = view:GetWidth()
    row.inactiveMark:SetShown(width < MIN_W and row.ppState == "inactive")
    if row.ppState == "desynced" then
        row.statusText:SetText(width < MIN_W and tostring(row.ppDiffCount)
            or (row.ppDiffCount .. " issue" .. (row.ppDiffCount == 1 and "" or "s")))
        row.statusText:Show()
    elseif width < MIN_W then
        row.statusText:Hide()
    else
        row.statusText:SetText(row.ppText)
        row.statusText:Show()
    end
end

local function CreateRow(index)
    local row = CreateFrame("Frame", nil, view)
    row:SetSize(view:GetWidth() - INSET * 2 - PAD * 2, ROW_H)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("TOPLEFT", 0, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.icon = icon

    local initial = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    initial:SetPoint("CENTER", icon, "CENTER")
    local font, size = initial:GetFont()
    if font then initial:SetFont(font, size + 1, "OUTLINE") end
    initial:SetTextColor(paladinClass.colorRGB.r,
        paladinClass.colorRGB.g, paladinClass.colorRGB.b)
    initial:Hide()
    row.initial = initial

    local status = CreateFrame("StatusBar", nil, row)
    status:SetHeight(BAR_H)
    status:SetPoint("TOPLEFT", icon, "TOPRIGHT", 0, 0)
    status:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    status:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    status:SetMinMaxValues(0, 1)
    local background = status:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0.025, 0.025, 0.035, 1)
    row.background = background
    row.status = status

    local name = status:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    font, size = name:GetFont()
    if font then name:SetFont(font, size, "OUTLINE") end
    row.name = name

    local percent = status:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    font, size = percent:GetFont()
    if font then percent:SetFont(font, size, "OUTLINE") end
    row.percent = percent

    local completeIcon = status:CreateTexture(nil, "OVERLAY")
    completeIcon:SetSize(14, math.floor(14 * 0.8 + 0.5))
    completeIcon:SetTexture(READY_ICON)
    completeIcon:Hide()
    row.completeIcon = completeIcon

    view.rows[index] = row
    return row
end

local function CreatePallyPowerRow()
    local row = CreateFrame("Button", nil, view)
    row:SetSize(view:GetWidth() - INSET * 2 - PAD * 2, ROW_H)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function(self)
        -- Shift-left-click belongs to the window shortcut below, so a plain
        -- click is the only one that opens Differences.
        if IsShiftKeyDown() then return end
        if self.ppState == "desynced" then
            WhoDoesWhat:OpenPallyPowerDiffView()
        end
    end)
    row:SetScript("OnMouseUp", StatusBarsClick)
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("PallyPower status", 1, 1, 1)
        if self.ppState == "synced" then
            GameTooltip:AddLine(self.ppText or "", 0.3, 1, 0.3, true)
        else
            GameTooltip:AddLine(self.ppText or "", 1, 0.55, 0, true)
        end
        if self.ppState == "desynced" then
            GameTooltip:AddLine("Click to open PallyPower Differences.",
                0.8, 0.8, 0.8, true)
        end
        AddShortcutTooltipLines()
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.04)
    row.highlight = highlight

    local badge = K.CreatePallyPowerBadge(row, ICON_SIZE)
    badge:SetPoint("TOPLEFT", 0, 0)

    local body = CreateFrame("Frame", nil, row)
    body:SetHeight(BAR_H)
    body:SetPoint("TOPLEFT", badge, "TOPRIGHT", 0, 0)
    body:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    local bodyBg = body:CreateTexture(nil, "BACKGROUND")
    bodyBg:SetAllPoints()
    bodyBg:SetColorTexture(0.07, 0.07, 0.085, 1)

    local icon = body:CreateTexture(nil, "ARTWORK")
    icon:SetSize(14, 14)
    icon:SetPoint("LEFT", 3, 0)
    row.stateIcon = icon

    local inactiveMark = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    inactiveMark:SetPoint("CENTER", icon, "CENTER", 0, 0)
    inactiveMark:SetText("-")
    inactiveMark:SetTextColor(0.5, 0.5, 0.5)
    inactiveMark:Hide()
    row.inactiveMark = inactiveMark

    local status = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    status:SetHeight(BAR_H)
    status:SetPoint("LEFT", icon, "RIGHT", 2, 0)
    status:SetJustifyH("RIGHT")
    status:SetWordWrap(false)
    row.statusText = status

    return row
end

local function StatusCheckInScope(scope)
    if scope == "raid" then return IsInRaid() end
    if scope == "party" then
        return not IsInRaid() and GetNumSubgroupMembers() > 0
    end
    return true
end

local function ApplyResizeBounds()
    if view.SetResizeBounds then
        view:SetResizeBounds(RESIZE_MIN_W, 1)
    elseif view.SetMinResize then
        view:SetMinResize(RESIZE_MIN_W, 1)
    end
end

local function LayoutHeader()
    local compact = view:GetWidth() < MIN_W
    view.titleText:Show()
    view.titleText:SetText(view:GetWidth() < ULTRA_COMPACT_W
        and "Status" or "WDW Status")
    view.titleText:ClearAllPoints()
    view.titleText:SetPoint("LEFT", compact and 2 or 5, 0)
    view.totalPercent:ClearAllPoints()
    if compact then
        view.totalPercent:SetPoint("RIGHT", view.title, "RIGHT", -2, 0)
    else
        view.totalPercent:SetPoint("LEFT", view.titleText, "RIGHT", 4, 0)
    end
end

local function LayoutResizeHandle()
    if not view or not view.resizeHandle then return end
    local left = IsRightAnchor(StatusBarsAnchor())
    local handle, line = view.resizeHandle, view.resizeHandleLine
    handle:ClearAllPoints()
    line:ClearAllPoints()
    if left then
        handle:SetHitRectInsets(-6, -4, 0, 0)
        handle:SetPoint("TOPLEFT", 1, -(INSET + TITLE_H + 2))
        handle:SetPoint("BOTTOMLEFT", 1, INSET + 1)
        line:SetPoint("LEFT", 2, 0)
    else
        handle:SetHitRectInsets(-4, -6, 0, 0)
        handle:SetPoint("TOPRIGHT", -1, -(INSET + TITLE_H + 2))
        handle:SetPoint("BOTTOMRIGHT", -1, INSET + 1)
        line:SetPoint("RIGHT", -2, 0)
    end
end

local function ResizeEdge()
    return IsRightAnchor(StatusBarsAnchor()) and "LEFT" or "RIGHT"
end

local function EnsureView()
    if view then return view end

    view = CreateFrame("Frame", "WhoDoesWhatStatusBars", UIParent, "BackdropTemplate")
    view:SetFrameStrata("MEDIUM")
    view:SetClampedToScreen(true)
    view:SetMovable(true)
    view:SetResizable(true)
    ApplyResizeBounds()
    view:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = INSET, right = INSET, top = INSET, bottom = INSET },
    })
    view:SetBackdropColor(0.14, 0.14, 0.16, 0.97)
    view:SetBackdropBorderColor(0.4, 0.4, 0.4)
    AttachAltDrag(view)
    view:SetScript("OnMouseUp", StatusBarsClick)

    local title = CreateFrame("Frame", nil, view)
    title:SetHeight(TITLE_H)
    title:SetPoint("TOPLEFT", INSET, -INSET)
    title:SetPoint("TOPRIGHT", -INSET, -INSET)
    view.title = title
    local titleBg = title:CreateTexture(nil, "ARTWORK")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(0.09, 0.09, 0.11, 1)
    local titleText = title:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleText:SetPoint("LEFT", 5, 0)
    titleText:SetText("WDW Status")
    view.titleText = titleText
    local totalPercent = title:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    totalPercent:SetPoint("LEFT", titleText, "RIGHT", 4, 0)
    totalPercent:SetText("(0%)")
    view.totalPercent = totalPercent
    AttachAltDrag(title)
    title:SetScript("OnMouseUp", StatusBarsClick)
    title:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("WDW Status Bars", 1, 1, 1)
        GameTooltip:AddDoubleLine("Alt-Drag:", "Move",
            1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Alt-Drag-Edge:", "Resize",
            1, 0.82, 0, 1, 1, 1)
        AddShortcutTooltipLines()
        GameTooltip:Show()
    end)
    title:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- A quiet edge resize handle fits the flat status-bar style better
    -- than the chat window's diagonal corner grip.
    local handle = CreateFrame("Button", nil, view)
    handle:SetWidth(HANDLE_W)
    view.resizeHandle = handle
    local handleLine = handle:CreateTexture(nil, "ARTWORK")
    handleLine:SetSize(2, 28)
    handleLine:SetColorTexture(0.35, 0.35, 0.35, 0.8)
    view.resizeHandleLine = handleLine
    LayoutResizeHandle()
    local highlight = handle:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.06)
    local function ShowResizeTooltip(self)
        local width = math.floor(view:GetWidth() + 0.5)
        if self.tooltipWidth == width then return end
        self.tooltipWidth = width
        GameTooltip:SetOwner(self, IsRightAnchor(StatusBarsAnchor())
            and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:SetText("Resize WDW Status Bars", 1, 1, 1)
        GameTooltip:AddLine("(" .. width .. "px)", 1, 0.82, 0)
        GameTooltip:AddDoubleLine("Alt-Drag:", "Resize",
            1, 0.82, 0, 1, 1, 1)
        GameTooltip:Show()
    end
    local function FinishResize(self)
        if not view.resizing then return end
        view.resizing = nil
        view:StopMovingOrSizing()
        WhoDoesWhat.db.profile.settings.overviewWidth = view:GetWidth()
        SavePosition()
        LoadPosition()
    end
    handle:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or not IsAltKeyDown() then return end
        view:StartSizing(ResizeEdge())
        view.resizing = true
    end)
    handle:SetScript("OnUpdate", function(self)
        if view.resizing and not IsAltKeyDown() then
            FinishResize(self)
        elseif view.resizing then
            ShowResizeTooltip(self)
        end
    end)
    handle:SetScript("OnMouseUp", function(self, button)
        FinishResize(self)
        StatusBarsClick(self, button)
    end)
    handle:SetScript("OnEnter", function(self)
        handleLine:SetColorTexture(0.8, 0.8, 0.8, 1)
        self.tooltipWidth = nil
        ShowResizeTooltip(self)
    end)
    handle:SetScript("OnLeave", function()
        handleLine:SetColorTexture(0.35, 0.35, 0.35, 0.8)
        GameTooltip:Hide()
        handle.tooltipWidth = nil
    end)

    local emptyCheck = view:CreateTexture(nil, "OVERLAY")
    emptyCheck:SetSize(EMPTY_ICON_SIZE, EMPTY_ICON_SIZE)
    emptyCheck:SetTexture(READY_ICON)
    emptyCheck:Hide()
    view.emptyCheck = emptyCheck
    view.rows = {}
    view:SetScript("OnSizeChanged", function(self)
        LayoutHeader()
        local rowW = self:GetWidth() - INSET * 2 - PAD * 2
        for _, row in ipairs(self.rows) do
            row:SetWidth(rowW)
            if row:IsShown() then LayoutProgressLabel(row) end
        end
        if self.ppRow then
            self.ppRow:SetWidth(rowW)
            LayoutPallyPowerRow(self.ppRow)
        end
    end)

    view:RegisterEvent("GROUP_ROSTER_UPDATE")
    view:SetScript("OnEvent", function(self)
        if self:IsShown() then WhoDoesWhat:RefreshStatusBarsView() end
    end)
    return view
end

function WhoDoesWhat:RefreshStatusBarsView()
    if not view or not view:IsShown() then return end
    local buffPlan = self.Assign.GetActivePaladinBuffPlan()
    local summary = self.Assign.ComputePaladinBuffSummary(buffPlan)
    local paladinOptions = self:GetStatusBarCheckOptions("paladinBuffs")
    local paladinCorrect, paladinTotal, coverageByPaladin =
        self.Assign.ComputePaladinBuffCoverage(buffPlan,
            paladinOptions.hunterPets)
    local _, _, coreCoverage = self.Assign.ComputeCoreRaidBuffCoverage()
    local ppState, ppText, ppDiffCount = K.GetPallyPowerState(#summary)
    local colorPreviewMode = self.statusBarColorPreviewKey ~= nil
    local displayed = {}
    local coreCorrect, coreTotal = 0, 0
    local coreCoverageByKey = {}
    for _, coverage in ipairs(coreCoverage) do
        coreCoverageByKey[coverage.key] = coverage
    end

    local paladinPreview = colorPreviewMode
        and (paladinOptions.bar
            or self.statusBarColorPreviewKey == "paladinBuffs")
    local paladinInScope = StatusCheckInScope(paladinOptions.scope)
    local paladinRequiredAvailable = not paladinOptions.requiredClass
        or #self.Assign.MembersOfClass(paladinOptions.requiredClass) > 0
    local paladinAvailable = paladinRequiredAvailable
        or not paladinOptions.hideBarUnavailable
    local showPaladinBars = paladinPreview
        or (paladinOptions.bar and paladinInScope and paladinAvailable)
    local normalPaladinBars = paladinOptions.bar
        and paladinInScope and paladinAvailable
    local paladinEntries = {}
    if paladinOptions.combinePaladinBars then
        local coverage = { correct = paladinCorrect, total = paladinTotal }
        local complete = paladinTotal > 0 and paladinCorrect >= paladinTotal
        if (paladinPreview or paladinTotal > 0) and showPaladinBars
            and (paladinPreview or not (paladinOptions.hideComplete and complete)) then
            local definition = self.StatusBarChecks.paladinBuffs
            paladinEntries[#paladinEntries + 1] = {
                name = definition.name,
                icon = definition.icon,
                coverage = coverage,
                display = paladinOptions.display,
                colorPreview = paladinPreview,
                barColor = paladinOptions.barColor,
                colorRGB = paladinClass.colorRGB,
            }
        end
    else
        for _, paladin in ipairs(summary) do
            local coverage = coverageByPaladin[paladin.name]
                or { correct = 0, total = 0 }
            local complete = coverage.total > 0
                and coverage.correct >= coverage.total
            if showPaladinBars
                and (paladinPreview
                    or not (paladinOptions.hideComplete and complete)) then
                paladinEntries[#paladinEntries + 1] = {
                    name = paladin.name,
                    icon = RoleIcon(paladin.name),
                    isPaladin = true,
                    awaitingTalents =
                        (self.db.profile.settings.pallyBuffSource or "wdw")
                            == "wdw" and paladin.awaitingTalents,
                    coverage = coverage,
                    display = paladinOptions.display,
                    colorPreview = paladinPreview,
                    barColor = paladinOptions.barColor,
                    colorRGB = paladinClass.colorRGB,
                }
            end
        end
    end
    local pallyPowerOptions = self:GetStatusBarCheckOptions("pallyPower")
    local showPallyPower = false
    for _, key in ipairs(self:GetStatusBarCheckOrder()) do
        if key == "paladinBuffs" then
            for _, entry in ipairs(paladinEntries) do
                displayed[#displayed + 1] = entry
            end
        elseif key == "pallyPower" then
            showPallyPower = pallyPowerOptions.bar
                and StatusCheckInScope(pallyPowerOptions.scope)
                and not (pallyPowerOptions.hideWhenSynced
                    and ppState == "synced")
                and not (pallyPowerOptions.hideWhenInactive
                    and ppState == "inactive")
            if showPallyPower then
                displayed[#displayed + 1] = { pallyPower = true }
            end
        else
            local coverage = coreCoverageByKey[key]
            if coverage then
                local options = self:GetStatusBarCheckOptions(key)
                local colorPreview = colorPreviewMode
                    and (options.bar or self.statusBarColorPreviewKey == key)
                local inScope = StatusCheckInScope(options.scope)
                local complete = coverage.total > 0
                    and coverage.correct >= coverage.total
                -- "Hide bar when debuff missing" is only about the empty end
                -- of a debuff: full saturation is never a reason to hide it.
                local resolved = options.negative and coverage.correct == 0
                    or (not options.negative and complete)
                -- A fully debuffed row is hidden only by its own style option.
                local saturatedHidden = options.negative and complete
                    and options.saturatedStyle == "hide"
                local available = coverage.available
                    or not options.hideBarUnavailable
                if options.bar and inScope and available
                    and not options.negative and options.includeInTotal
                    and coverage.total > 0 then
                    coreCorrect = coreCorrect + coverage.correct
                    coreTotal = coreTotal + coverage.total
                end
                if colorPreview or (options.bar and inScope and available
                    and coverage.total > 0 and not saturatedHidden
                    and not (options.hideComplete and resolved)) then
                    local buff = WhoDoesWhat.StatusBarChecks[key]
                    displayed[#displayed + 1] = {
                        name = coverage.name,
                        icon = coverage.icon,
                        coverage = coverage,
                        display = options.display,
                        colorPreview = colorPreview,
                        barColor = options.barColor,
                        colorRGB = buff.colorRGB or classColors[buff.className],
                        negative = options.negative,
                        saturatedStyle = options.saturatedStyle,
                    }
                end
            end
        end
    end
    local countPaladinCoverage = normalPaladinBars
        and paladinOptions.includeInTotal
    local correct = (countPaladinCoverage and paladinCorrect or 0) + coreCorrect
    local total = (countPaladinCoverage and paladinTotal or 0) + coreTotal
    local totalPercent = total > 0 and math.floor(correct / total * 100 + 0.5) or 0
    view.totalPercent:SetText(total > 0 and ("(" .. totalPercent .. "%)")
        or ("|T" .. NOT_READY_ICON .. ":12:12:0:0|t"))

    local showEmptyCheck = #displayed == 0
    local rowsH = (#displayed + (showEmptyCheck and 1 or 0)) * ROW_H
    local contentH = rowsH
    ApplyResizeBounds()
    view:SetSize(math.max(self.db.profile.settings.overviewWidth or DEFAULT_W,
            RESIZE_MIN_W),
        CONTENT_TOP + contentH + PAD + INSET)
    LayoutHeader()
    if not view.moving and not view.resizing then LoadPosition() end

    if showPallyPower then
        local ppRow = view.ppRow or CreatePallyPowerRow()
        view.ppRow = ppRow
        ppRow.ppState, ppRow.ppText, ppRow.ppDiffCount =
            ppState, ppText, ppDiffCount
        local assignmentGlow = pallyPowerOptions.assignmentIssuesGlow
            and self:IsRaidAssistant() and ppState == "desynced"
        ppRow.highlight:SetAlpha(assignmentGlow and 1 or 0)
        local ppIndex
        for i, entry in ipairs(displayed) do
            if entry.pallyPower then ppIndex = i break end
        end
        ppRow:ClearAllPoints()
        ppRow:SetPoint("TOPLEFT", view, "TOPLEFT", INSET + PAD,
            -(CONTENT_TOP + (ppIndex - 1) * ROW_H))
        SetDesyncGlow(ppRow, assignmentGlow)

        ppRow.stateIcon:ClearAllPoints()
        ppRow.stateIcon:SetSize(ppState == "desynced" and 12 or 14,
            ppState == "desynced" and 12 or 14)
        ppRow.statusText:ClearAllPoints()
        if ppState == "inactive" then
            ppRow.stateIcon:SetPoint("LEFT", 3, 0)
            ppRow.stateIcon:Hide()
            ppRow.statusText:SetPoint("LEFT", 4, 0)
            ppRow.statusText:SetPoint("RIGHT", -3, 0)
            ppRow.statusText:SetTextColor(0.6, 0.6, 0.6)
        elseif ppState == "synced" then
            ppRow.stateIcon:SetTexture(READY_ICON)
            ppRow.stateIcon:SetPoint("RIGHT", -3, 0)
            ppRow.stateIcon:Show()
            ppRow.statusText:SetPoint("LEFT", 3, 0)
            ppRow.statusText:SetPoint("RIGHT", ppRow.stateIcon, "LEFT", -2, 0)
            ppRow.statusText:SetTextColor(0.3, 1, 0.3)
        else
            ppRow.stateIcon:SetTexture(self.WARNING_ICON)
            ppRow.stateIcon:SetPoint("RIGHT", -3, 0)
            ppRow.stateIcon:Show()
            ppRow.statusText:SetPoint("LEFT", 3, 0)
            ppRow.statusText:SetPoint("RIGHT", ppRow.stateIcon, "LEFT", -3, 0)
            ppRow.statusText:SetTextColor(1, 0.55, 0)
        end
        LayoutPallyPowerRow(ppRow)
        ppRow:Show()
    else
        if view.ppRow then
            SetDesyncGlow(view.ppRow, false)
            view.ppRow:Hide()
        end
    end

    local normalIndex = 0
    for displayIndex, entry in ipairs(displayed) do
        if not entry.pallyPower then
            normalIndex = normalIndex + 1
            local row = view.rows[normalIndex] or CreateRow(normalIndex)
            local coverage = entry.coverage
            row.icon:SetTexture(entry.icon)
            row.name:SetText(entry.awaitingTalents
                and ("Awaiting talents - " .. entry.name) or entry.name)
            row.initial:SetText(entry.isPaladin and entry.name:sub(1, 1) or "")
            row.isPaladin = entry.isPaladin
            row.awaitingTalents = entry.awaitingTalents
            row.colorPreview = entry.colorPreview
            row.negative = entry.negative
            row.saturatedStyle = entry.saturatedStyle or "check"
            row.correct = coverage.correct
            row.total = coverage.total
            row.display = entry.display
            if not row.display or row.display == "default" then
                row.display = self.db.profile.settings.overviewDefaultDisplay
                    or "percent"
            end
            row.status:SetMinMaxValues(0, entry.colorPreview and 1
                or math.max(coverage.total, 1))
            row.status:SetValue(entry.colorPreview and 1 or coverage.correct)
            if entry.barColor then
                row.status:SetStatusBarColor(entry.barColor.r,
                    entry.barColor.g, entry.barColor.b)
            else
                row.status:SetStatusBarColor(CoverageColor(
                    entry.colorPreview and 1 or coverage.correct,
                    entry.colorPreview and 1 or coverage.total, entry.colorRGB))
            end
            row.background:SetColorTexture(0.025, 0.025, 0.035, 1)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", view, "TOPLEFT", INSET + PAD,
                -(CONTENT_TOP + (displayIndex - 1) * ROW_H))
            row:Show()
            LayoutProgressLabel(row)
        end
    end
    for i = normalIndex + 1, #view.rows do view.rows[i]:Hide() end

    view.emptyCheck:ClearAllPoints()
    view.emptyCheck:SetPoint("TOP", view, "TOP", 0,
        -(CONTENT_TOP + (ROW_H - EMPTY_ICON_SIZE) / 2))
    view.emptyCheck:SetTexture(total > 0 and READY_ICON or NOT_READY_ICON)
    view.emptyCheck:SetShown(showEmptyCheck)
end

function WhoDoesWhat:SetStatusBarsAnchor(anchor)
    if anchor ~= "TOPLEFT" and anchor ~= "TOPRIGHT"
        and anchor ~= "BOTTOMLEFT" and anchor ~= "BOTTOMRIGHT" then return end
    local settings = self.db.profile.settings
    local oldAnchor = settings.overviewAnchor or "TOPLEFT"
    if not view and settings.overviewPos and not settings.overviewPos.anchor then
        settings.overviewPos.anchor = oldAnchor
    end
    settings.overviewAnchor = anchor
    if not view then return end
    SavePosition()
    LayoutResizeHandle()
    LoadPosition()
    self:RefreshStatusBarsView()
end

function WhoDoesWhat:UpdateStatusBarsViewVisibility()
    if not self.db.profile.settings.overviewEnabled then
        if view then view:Hide() end
        return
    end
    EnsureView():Show()
    self:RefreshStatusBarsView()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function()
    WhoDoesWhat:UpdateStatusBarsViewVisibility()
    C_Timer.After(2, function() WhoDoesWhat:UpdateStatusBarsViewVisibility() end)
end)
