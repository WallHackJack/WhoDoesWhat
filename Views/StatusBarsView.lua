local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local K = WhoDoesWhat.SectionKit

-- Movable compact status-bars view of paladin and core raid-buff coverage:
--
--   [role icon] [Paladin name                     % / check]
--               [dark red ---------------------------> paladin pink]
--   [buff icon] [Fortitude                        % / check]
--   [   PP    ] [sync status                       actions]
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
local NO_PP_MIN_W = 65
local HIDE_NAMES_W = 105
local COMPACT_PP_W = 150
local SHORT_PP_W = 125
local COUNT_ONLY_PP_W = 105
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

-- Keep the percentage entirely on one side of the status-bar fill boundary.
-- It stays at the far right while it fits in the unfilled area, then follows
-- the fill edge with its right side inset into the filled area.
local function LayoutProgressLabel(row)
    if row.correct == nil then return end

    local unavailable = row.total == 0
    local complete = not unavailable and row.correct >= row.total
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", row.status, "LEFT", 2, 0)
    row.name:SetShown(view:GetWidth() >= HIDE_NAMES_W)
    row.initial:SetShown(row.isPaladin and view:GetWidth() < HIDE_NAMES_W)

    if complete or unavailable then
        row.percent:Hide()
        row.completeIcon:ClearAllPoints()
        row.completeIcon:SetSize(14, unavailable and 14 or math.floor(14 * 0.8 + 0.5))
        row.completeIcon:SetPoint("RIGHT", row.status, "RIGHT", -2, 0)
        row.completeIcon:SetTexture(unavailable
            and (row.awaitingTalents and WhoDoesWhat.WARNING_ICON or NOT_READY_ICON)
            or READY_ICON)
        row.completeIcon:Show()
        row.name:SetPoint("RIGHT", row.completeIcon, "LEFT", -4, 0)
        return
    end

    row.completeIcon:Hide()
    local ratio = row.total > 0 and row.correct / row.total or 0
    row.percent:SetText(math.floor(ratio * 100 + 0.5) .. "%")
    row.percent:Show()
    row.percent:ClearAllPoints()

    local statusW = row.status:GetWidth()
    local textW = row.percent:GetStringWidth()
    local fillW = statusW * ratio
    if statusW - fillW >= textW + 6 then
        row.percent:SetPoint("RIGHT", row.status, "RIGHT", -3, 0)
    else
        row.percent:SetPoint("RIGHT", row.status, "LEFT",
            math.max(textW + 3, fillW - 3), 0)
    end
    row.name:SetPoint("RIGHT", row.percent, "LEFT", -4, 0)
end

local function LayoutPallyPowerActions(row)
    local width = view:GetWidth()
    local compact = width < COMPACT_PP_W
    row.diffBtn:SetWidth(compact and 16 or 30)
    row.diffBtn.label:SetText(compact and "?" or "Diff")
    row.fixBtn:SetWidth(compact and 16 or 26)
    row.fixBtn.label:SetText(compact and "F" or "Fix")
    if row.actionFont then
        local size = row.actionFontSize + (compact and 2 or 0)
        row.diffBtn.label:SetFont(row.actionFont, size, row.actionFontFlags)
        row.fixBtn.label:SetFont(row.actionFont, size, row.actionFontFlags)
    end
    row.inactiveMark:SetShown(width < MIN_W and row.ppState == "inactive")
    if row.ppState ~= "desynced" and width < MIN_W then
        row.statusText:Hide()
    elseif row.ppState ~= "desynced" then
        row.statusText:SetText(row.ppText)
        row.statusText:Show()
    elseif width >= COMPACT_PP_W then
        row.statusText:SetText(row.ppText)
        row.statusText:Show()
    elseif width >= SHORT_PP_W then
        row.statusText:SetText(row.ppDiffCount .. " Buff"
            .. (row.ppDiffCount == 1 and "" or "s"))
        row.statusText:Show()
    elseif width >= COUNT_ONLY_PP_W then
        row.statusText:SetText(row.ppDiffCount)
        row.statusText:Show()
    else
        row.statusText:Hide()
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
    local row = CreateFrame("Frame", nil, view)
    row:SetSize(view:GetWidth() - INSET * 2 - PAD * 2, ROW_H)

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

    local iconHit = CreateFrame("Frame", nil, body)
    iconHit:SetAllPoints(icon)
    iconHit:EnableMouse(true)
    iconHit:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("PallyPower out of sync", 1, 0.55, 0.55)
        GameTooltip:AddLine(row.ppText or "", 1, 1, 1)
        GameTooltip:AddLine("Inspect the differences or apply the current WDW plan using the actions to the right.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    iconHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    iconHit:Hide()
    row.stateIconHit = iconHit

    local status = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetHeight(BAR_H)
    status:SetPoint("LEFT", icon, "RIGHT", 2, 0)
    status:SetJustifyH("LEFT")
    status:SetWordWrap(false)
    row.statusText = status

    local fix = K.CreatePallyPowerActionButton(body, "Fix", 26,
        "Fix PallyPower", "Broadcast the current WDW blessing plan and update the local PP mirror.", function()
            WhoDoesWhat:SyncToPallyPower()
            WhoDoesWhat:RefreshMainAssignmentsView()
            WhoDoesWhat:RefreshStatusBarsView()
        end)
    fix:SetPoint("RIGHT", -2, 0)
    row.fixBtn = fix

    local diff = K.CreatePallyPowerActionButton(body, "Diff", 30,
        "Show PallyPower differences",
        "Open the detailed comparison between WDW and PallyPower.", function()
            WhoDoesWhat:OpenPallyPowerDiffView()
        end)
    diff:SetPoint("RIGHT", fix, "LEFT", -2, 0)
    row.diffBtn = diff
    row.actionFont, row.actionFontSize, row.actionFontFlags = fix.label:GetFont()

    return row
end

local function ShowPallyPowerRow(ppState)
    local settings = WhoDoesWhat.db.profile.settings
    if settings.overviewShowPallyPower == false then return false end
    return not settings.overviewPallyPowerOnlyDesynced
        or not ppState or ppState == "desynced"
end

local function StatusCheckInScope(scope)
    if scope == "raid" then return IsInRaid() end
    if scope == "party" then
        return not IsInRaid() and GetNumSubgroupMembers() > 0
    end
    return true
end

local function MinimumWidth(ppState)
    return ShowPallyPowerRow(ppState) and (not ppState or ppState == "desynced")
        and MIN_W or NO_PP_MIN_W
end

local function ApplyResizeBounds(ppState)
    local minWidth = MinimumWidth(ppState)
    if view.SetResizeBounds then
        view:SetResizeBounds(minWidth, 1)
    elseif view.SetMinResize then
        view:SetMinResize(minWidth, 1)
    end
end

local function LayoutHeader()
    local percentageOnly = view:GetWidth() < MIN_W
    view.titleText:SetShown(not percentageOnly)
    view.totalPercent:ClearAllPoints()
    if percentageOnly then
        view.totalPercent:SetPoint("CENTER", view.title, "CENTER", 0, 0)
    else
        view.titleText:SetText(view:GetWidth() < ULTRA_COMPACT_W
            and "Status" or "WDW Status")
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
    title:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("WDW Status", 1, 1, 1)
        GameTooltip:AddLine("Alt-drag to move.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Alt-drag the marked edge to resize.", 0.7, 0.7, 0.7)
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
        GameTooltip:SetText("Resize WDW Status", 1, 1, 1)
        GameTooltip:AddLine("(" .. width .. "px)", 1, 0.82, 0)
        GameTooltip:AddLine("Hold Alt and drag horizontally.", 0.7, 0.7, 0.7)
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
    handle:SetScript("OnMouseUp", FinishResize)
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
            LayoutPallyPowerActions(self.ppRow)
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
    local paladinCorrect, paladinTotal, coverageByPaladin =
        self.Assign.ComputePaladinBuffCoverage(buffPlan)
    local _, _, coreCoverage = self.Assign.ComputeCoreRaidBuffCoverage()
    local ppState, ppText, ppDiffCount = K.GetPallyPowerState(#summary)
    local showPallyPower = ShowPallyPowerRow(ppState)
    local displayed = {}
    local hideCompleted = self.db.profile.settings.overviewHideCompleted
    local coreCorrect, coreTotal = 0, 0
    for _, paladin in ipairs(summary) do
        local coverage = coverageByPaladin[paladin.name] or { correct = 0, total = 0 }
        local complete = coverage.total > 0 and coverage.correct >= coverage.total
        if not (hideCompleted and complete) then
            displayed[#displayed + 1] = {
                name = paladin.name,
                icon = RoleIcon(paladin.name),
                isPaladin = true,
                awaitingTalents = (self.db.profile.settings.pallyBuffSource or "wdw")
                    == "wdw" and paladin.awaitingTalents,
                coverage = coverage,
                colorRGB = paladinClass.colorRGB,
            }
        end
    end
    for _, coverage in ipairs(coreCoverage) do
        local enabled, neverHide, scope = self:GetStatusBarCheckOptions(coverage.key)
        local inScope = StatusCheckInScope(scope)
        local complete = coverage.total > 0 and coverage.correct >= coverage.total
        if enabled and inScope and coverage.total > 0 then
            coreCorrect = coreCorrect + coverage.correct
            coreTotal = coreTotal + coverage.total
        end
        if enabled and inScope and coverage.total > 0
            and not (hideCompleted and complete and not neverHide) then
            local buff = WhoDoesWhat.StatusBarChecks[coverage.key]
            displayed[#displayed + 1] = {
                name = coverage.name,
                icon = coverage.icon,
                coverage = coverage,
                colorRGB = buff.colorRGB or classColors[buff.className],
            }
        end
    end
    local correct, total = paladinCorrect + coreCorrect, paladinTotal + coreTotal
    local totalPercent = total > 0 and math.floor(correct / total * 100 + 0.5) or 0
    view.totalPercent:SetText(total > 0 and ("(" .. totalPercent .. "%)")
        or ("|T" .. NOT_READY_ICON .. ":12:12:0:0|t"))

    local ppHeight = showPallyPower and ROW_H or 0
    local showEmptyCheck = #displayed == 0 and not showPallyPower
    local rowsH = (#displayed + (showEmptyCheck and 1 or 0)) * ROW_H
    local contentH = ppHeight + rowsH
    ApplyResizeBounds(ppState)
    local minWidth = MinimumWidth(ppState)
    view:SetSize(math.max(self.db.profile.settings.overviewWidth or DEFAULT_W, minWidth),
        CONTENT_TOP + contentH + PAD + INSET)
    LayoutHeader()
    if not view.moving and not view.resizing then LoadPosition() end

    if showPallyPower then
        -- PallyPower sync leads the status list when enabled.
        local ppRow = view.ppRow or CreatePallyPowerRow()
        view.ppRow = ppRow
        ppRow.ppState, ppRow.ppText, ppRow.ppDiffCount =
            ppState, ppText, ppDiffCount
        ppRow.diffBtn.tooltipDetail = ppText
        ppRow.fixBtn.tooltipDetail = ppText
        ppRow:ClearAllPoints()
        ppRow:SetPoint("TOPLEFT", view, "TOPLEFT", INSET + PAD, -CONTENT_TOP)
        SetDesyncGlow(ppRow, ppState == "desynced")

        ppRow.stateIcon:ClearAllPoints()
        ppRow.stateIcon:SetPoint("LEFT", ppState == "desynced" and 4 or 3,
            ppState == "desynced" and -1 or 0)
        ppRow.stateIconHit:SetShown(ppState == "desynced")
        ppRow.statusText:ClearAllPoints()
        if ppState == "inactive" then
            ppRow.stateIcon:Hide()
            ppRow.statusText:SetPoint("LEFT", 4, 0)
            ppRow.statusText:SetPoint("RIGHT", -3, 0)
            ppRow.statusText:SetTextColor(0.6, 0.6, 0.6)
            ppRow.diffBtn:Hide()
            ppRow.fixBtn:Hide()
        elseif ppState == "synced" then
            ppRow.stateIcon:SetTexture(READY_ICON)
            ppRow.stateIcon:Show()
            ppRow.statusText:SetPoint("LEFT", ppRow.stateIcon, "RIGHT", 2, 0)
            ppRow.statusText:SetPoint("RIGHT", -3, 0)
            ppRow.statusText:SetTextColor(0.3, 1, 0.3)
            ppRow.diffBtn:Hide()
            ppRow.fixBtn:Hide()
        else
            ppRow.stateIcon:SetTexture(self.WARNING_ICON)
            ppRow.stateIcon:Show()
            ppRow.statusText:SetPoint("LEFT", ppRow.stateIcon, "RIGHT", 2, 0)
            ppRow.statusText:SetPoint("RIGHT", ppRow.diffBtn, "LEFT", -3, 0)
            ppRow.statusText:SetTextColor(1, 0.55, 0.55)
            ppRow.diffBtn:Show()
            ppRow.fixBtn:Show()
        end
        LayoutPallyPowerActions(ppRow)
        ppRow:Show()
    else
        if view.ppRow then
            SetDesyncGlow(view.ppRow, false)
            view.ppRow:Hide()
        end
    end

    for i, entry in ipairs(displayed) do
        local row = view.rows[i] or CreateRow(i)
        local coverage = entry.coverage
        row.icon:SetTexture(entry.icon)
        row.name:SetText(entry.awaitingTalents
            and ("Awaiting talents - " .. entry.name) or entry.name)
        row.initial:SetText(entry.isPaladin and entry.name:sub(1, 1) or "")
        row.isPaladin = entry.isPaladin
        row.awaitingTalents = entry.awaitingTalents
        row.correct = coverage.correct
        row.total = coverage.total
        row.status:SetMinMaxValues(0, math.max(coverage.total, 1))
        row.status:SetValue(coverage.correct)
        row.status:SetStatusBarColor(CoverageColor(
            coverage.correct, coverage.total, entry.colorRGB))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", view, "TOPLEFT", INSET + PAD,
            -(CONTENT_TOP + ppHeight + (i - 1) * ROW_H))
        row:Show()
        LayoutProgressLabel(row)
    end
    for i = #displayed + 1, #view.rows do view.rows[i]:Hide() end

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
