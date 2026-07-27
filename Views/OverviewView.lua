local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local K = WhoDoesWhat.SectionKit

-- Movable compact overview of every paladin's live blessing coverage:
--
--   [role icon] [Paladin name                     % / check]
--               [dark red ---------------------------> paladin pink]
--   [   PP    ] [sync status                       actions]
--
-- It shares the Paladin Buffing Bar's small window chrome and Alt-drag
-- behavior, but is display-only. Coverage comes from the same computed plan
-- and aura state as the Paladin Buffs section.

local view

local INSET = 3
local PAD = 4
local TITLE_H = 12
local CONTENT_TOP = INSET + TITLE_H + 3
local ROW_H = 19
local ICON_SIZE = 18
local BAR_H = 18
local DEFAULT_W = 220
local MIN_W = 170
local HANDLE_W = 10
local HANDLE_SPACE = 8
local READY_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"

local paladinClass
for _, classInfo in ipairs(WhoDoesWhat.Classes) do
    if classInfo.name == "Paladin" then
        paladinClass = classInfo
        break
    end
end

local function CoverageColor(correct, total)
    if total == 0 then return 0.4, 0.4, 0.4 end
    local t = math.min((correct / total) / 0.8, 1)
    local pink = paladinClass.colorRGB
    return 0.35 + (pink.r - 0.35) * t,
        0.04 + (pink.g - 0.04) * t,
        0.08 + (pink.b - 0.08) * t
end

local function ClampPosition(x, y)
    local parentW, parentH = UIParent:GetWidth(), UIParent:GetHeight()
    x = math.max(0, math.min(x, math.max(0, parentW - view:GetWidth())))
    y = math.max(math.min(view:GetHeight(), parentH), math.min(y, parentH))
    return x, y
end

local function SavePosition()
    if not view then return end
    local x, y = view:GetLeft(), view:GetTop()
    if x and y then
        x, y = ClampPosition(x, y)
        WhoDoesWhat.db.profile.settings.overviewPos = { x = x, y = y }
    end
end

local function LoadPosition()
    local settings = WhoDoesWhat.db.profile.settings
    local p = settings.overviewPos
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
        p.x, p.y = ClampPosition(p.x, p.y)
        view:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p.x, p.y)
    else
        view:SetPoint("CENTER", UIParent, "CENTER", 0, -80)
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

-- Keep the percentage entirely on one side of the status-bar fill boundary.
-- It stays at the far right while it fits in the unfilled area, then follows
-- the fill edge with its right side inset into the filled area.
local function LayoutProgressLabel(row)
    if row.correct == nil then return end

    local complete = row.total > 0 and row.correct >= row.total
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", row.status, "LEFT", 2, 0)

    if complete then
        row.percent:Hide()
        row.completeIcon:ClearAllPoints()
        row.completeIcon:SetPoint("RIGHT", row.status, "RIGHT", -2, 0)
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

local function CreateRow(index)
    local row = CreateFrame("Frame", nil, view)
    row:SetSize(view:GetWidth() - INSET * 2 - PAD * 2 - HANDLE_SPACE, ROW_H)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("TOPLEFT", 0, 0)
    row.icon = icon

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
    row.name = name

    local percent = status:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.percent = percent

    local completeIcon = status:CreateTexture(nil, "OVERLAY")
    completeIcon:SetSize(14, 14)
    completeIcon:SetTexture(READY_ICON)
    completeIcon:Hide()
    row.completeIcon = completeIcon

    view.rows[index] = row
    return row
end

local function CreatePallyPowerRow()
    local row = CreateFrame("Frame", nil, view)
    row:SetSize(view:GetWidth() - INSET * 2 - PAD * 2 - HANDLE_SPACE, ROW_H)

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

    local status = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetHeight(BAR_H)
    status:SetPoint("LEFT", icon, "RIGHT", 2, 0)
    status:SetJustifyH("LEFT")
    row.statusText = status

    local fix = K.CreatePallyPowerActionButton(body, "Fix", 26,
        "Fix PallyPower", "Write the current WDW blessing plan into PallyPower.", function()
            WhoDoesWhat:SyncToPallyPower()
            WhoDoesWhat:RefreshMainAssignmentsView()
            WhoDoesWhat:RefreshOverviewView()
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

    return row
end

local function EnsureView()
    if view then return view end

    view = CreateFrame("Frame", "WhoDoesWhatOverview", UIParent, "BackdropTemplate")
    view:SetFrameStrata("MEDIUM")
    view:SetClampedToScreen(true)
    view:SetMovable(true)
    view:SetResizable(true)
    if view.SetResizeBounds then
        view:SetResizeBounds(MIN_W, 1)
    elseif view.SetMinResize then
        view:SetMinResize(MIN_W, 1)
    end
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
    local titleBg = title:CreateTexture(nil, "ARTWORK")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(0.09, 0.09, 0.11, 1)
    local titleText = title:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleText:SetPoint("LEFT", 5, 0)
    titleText:SetText("WDW Status")
    AttachAltDrag(title)
    title:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("WDW Status", 1, 1, 1)
        GameTooltip:AddLine("Alt-drag to move.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Alt-drag the right edge to resize.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    title:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- A quiet right-edge resize handle fits the flat status-bar style better
    -- than the chat window's diagonal corner grip.
    local handle = CreateFrame("Button", nil, view)
    handle:SetPoint("TOPRIGHT", -1, -(INSET + TITLE_H + 2))
    handle:SetPoint("BOTTOMRIGHT", -1, INSET + 1)
    handle:SetWidth(HANDLE_W)
    local handleLine = handle:CreateTexture(nil, "ARTWORK")
    handleLine:SetSize(2, 28)
    handleLine:SetPoint("RIGHT", -2, 0)
    handleLine:SetColorTexture(0.35, 0.35, 0.35, 0.8)
    local highlight = handle:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.06)
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
        view:StartSizing("RIGHT")
        view.resizing = true
    end)
    handle:SetScript("OnUpdate", function(self)
        if view.resizing and not IsAltKeyDown() then FinishResize(self) end
    end)
    handle:SetScript("OnMouseUp", FinishResize)
    handle:SetScript("OnEnter", function(self)
        handleLine:SetColorTexture(0.8, 0.8, 0.8, 1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Resize WDW Status", 1, 1, 1)
        GameTooltip:AddLine("Hold Alt and drag horizontally.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    handle:SetScript("OnLeave", function()
        handleLine:SetColorTexture(0.35, 0.35, 0.35, 0.8)
        GameTooltip:Hide()
    end)

    local hint = view:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOP", 0, -CONTENT_TOP)
    hint:SetText("No paladins in the group.")
    hint:SetTextColor(0.6, 0.6, 0.6)
    view.hint = hint
    view.rows = {}
    view:SetScript("OnSizeChanged", function(self)
        local rowW = self:GetWidth() - INSET * 2 - PAD * 2 - HANDLE_SPACE
        for _, row in ipairs(self.rows) do
            row:SetWidth(rowW)
            if row:IsShown() then LayoutProgressLabel(row) end
        end
        if self.ppRow then self.ppRow:SetWidth(rowW) end
    end)

    view:RegisterEvent("GROUP_ROSTER_UPDATE")
    view:SetScript("OnEvent", function(self)
        if self:IsShown() then WhoDoesWhat:RefreshOverviewView() end
    end)
    return view
end

function WhoDoesWhat:RefreshOverviewView()
    if not view or not view:IsShown() then return end
    local summary = self.Assign.ComputePaladinBuffSummary()
    local _, _, coverageByPaladin = self.Assign.ComputePaladinBuffCoverage()
    local displayed = {}
    local hideCompleted = self.db.profile.settings.overviewHideCompleted
    for _, paladin in ipairs(summary) do
        local coverage = coverageByPaladin[paladin.name] or { correct = 0, total = 0 }
        local complete = coverage.total > 0 and coverage.correct >= coverage.total
        if not (hideCompleted and complete) then
            displayed[#displayed + 1] = { paladin = paladin, coverage = coverage }
        end
    end

    local paladinH = (#displayed > 0) and (#displayed * ROW_H) or 18
    local contentH = paladinH + ROW_H
    view:SetSize(self.db.profile.settings.overviewWidth or DEFAULT_W,
        CONTENT_TOP + contentH + PAD + INSET)
    if not view.moving and not view.resizing then LoadPosition() end

    for i, entry in ipairs(displayed) do
        local row = view.rows[i] or CreateRow(i)
        local paladin = entry.paladin
        local coverage = entry.coverage
        row.icon:SetTexture(RoleIcon(paladin.name))
        row.name:SetText(paladin.name)
        row.correct = coverage.correct
        row.total = coverage.total
        row.status:SetMinMaxValues(0, math.max(coverage.total, 1))
        row.status:SetValue(coverage.correct)
        row.status:SetStatusBarColor(CoverageColor(coverage.correct, coverage.total))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", view, "TOPLEFT", INSET + PAD,
            -(CONTENT_TOP + (i - 1) * ROW_H))
        row:Show()
        LayoutProgressLabel(row)
    end
    for i = #displayed + 1, #view.rows do view.rows[i]:Hide() end

    if #summary == 0 then
        view.hint:SetText("No paladins in the group.")
        view.hint:Show()
    elseif #displayed == 0 then
        view.hint:SetText("All paladin buffs complete.")
        view.hint:Show()
    else
        view.hint:Hide()
    end

    local ppRow = view.ppRow or CreatePallyPowerRow()
    view.ppRow = ppRow
    ppRow:ClearAllPoints()
    ppRow:SetPoint("TOPLEFT", view, "TOPLEFT", INSET + PAD,
        -(CONTENT_TOP + paladinH))

    local ppState, ppText = K.GetPallyPowerState(#summary)
    ppRow.stateIcon:ClearAllPoints()
    ppRow.stateIcon:SetPoint("LEFT", 3, 0)
    ppRow.statusText:ClearAllPoints()
    if ppState == "inactive" then
        ppRow.stateIcon:Hide()
        ppRow.statusText:SetPoint("LEFT", 4, 0)
        ppRow.statusText:SetPoint("RIGHT", -3, 0)
        ppRow.statusText:SetText(ppText)
        ppRow.statusText:SetTextColor(0.6, 0.6, 0.6)
        ppRow.diffBtn:Hide()
        ppRow.fixBtn:Hide()
    elseif ppState == "synced" then
        ppRow.stateIcon:SetTexture(READY_ICON)
        ppRow.stateIcon:Show()
        ppRow.statusText:SetPoint("LEFT", ppRow.stateIcon, "RIGHT", 2, 0)
        ppRow.statusText:SetPoint("RIGHT", -3, 0)
        ppRow.statusText:SetText(ppText)
        ppRow.statusText:SetTextColor(0.3, 1, 0.3)
        ppRow.diffBtn:Hide()
        ppRow.fixBtn:Hide()
    else
        ppRow.stateIcon:SetTexture(self.WARNING_ICON)
        ppRow.stateIcon:Show()
        ppRow.statusText:SetPoint("LEFT", ppRow.stateIcon, "RIGHT", 2, 0)
        ppRow.statusText:SetPoint("RIGHT", ppRow.diffBtn, "LEFT", -3, 0)
        ppRow.statusText:SetText(ppText)
        ppRow.statusText:SetTextColor(1, 0.55, 0.55)
        ppRow.diffBtn:Show()
        ppRow.fixBtn:Show()
    end
    ppRow:Show()
end

function WhoDoesWhat:UpdateOverviewViewVisibility()
    if not self.db.profile.settings.overviewEnabled then
        if view then view:Hide() end
        return
    end
    EnsureView():Show()
    self:RefreshOverviewView()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function()
    WhoDoesWhat:UpdateOverviewViewVisibility()
    C_Timer.After(2, function() WhoDoesWhat:UpdateOverviewViewVisibility() end)
end)
