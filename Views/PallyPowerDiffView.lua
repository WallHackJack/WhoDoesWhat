local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- PallyPower Differences window (the Paladin Buffs section's "Check" button).
-- A read-only, formatted view of how PallyPower's LIVE board differs from the
-- plan a Send (SyncToPallyPower) would push -- the detail behind the section's
-- drift warning icon. Entries come from WhoDoesWhat:CheckPallyPowerSync
-- (structured: paladin, target, want/have blessing + icon); this view only
-- groups them by paladin and renders. A "Send to PallyPower" button pushes the
-- plan and re-renders (now in sync); "Recheck" re-runs the compare, since
-- PallyPower can change from other paladins with no repaint here. Changes that
-- cannot be safely auto-sent can open the same window in warning mode, where
-- Recheck becomes Ignore.

local diffFrame = nil

local FRAME_W = 470
local FRAME_H = 380
local MARGIN = 10
local BOTTOM_STRIP = 30

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

-- "want" side: blessing icon + green name, or a gray "(clear)" when the plan
-- wants no exception there (want id 0) -- i.e. Send would remove it.
local function WantMarkup(d)
    if d.want == 0 then return "|cff808080(clear)|r" end
    local icon = d.wantIcon and ("|T" .. d.wantIcon .. ":14:14:0:0|t ") or ""
    return icon .. "|cff40ff40" .. d.wantName .. "|r"
end

-- "have" side: what PallyPower shows now, in red.
local function HaveMarkup(d)
    if d.have == 0 then return "|cffa0a0a0none|r" end
    local icon = d.haveIcon and ("|T" .. d.haveIcon .. ":12:12:0:0|t ") or ""
    return icon .. "|cffff6060" .. d.haveName .. "|r"
end

local function RenderDiffs(f)
    local smf = f.smf
    smf:Clear()

    if f.warningText then
        smf:AddMessage("|cffff6060PallyPower was not auto-updated.|r "
            .. f.warningText)
        smf:AddMessage(" ")
    end

    local diffs = WhoDoesWhat:CheckPallyPowerSync()
    if diffs == nil then
        smf:AddMessage("|cff909090PallyPower isn't loaded, or there are no"
            .. " paladins in the group -- nothing to compare.|r")
        f.sendBtn:Disable()
        return
    end
    if #diffs == 0 then
        smf:AddMessage("|cff40ff40PallyPower matches the current plan.|r")
        f.sendBtn:Disable()
        return
    end
    f.sendBtn:Enable()

    smf:AddMessage("|cffffd000PallyPower is out of date.|r  |cff40ff40Green|r ="
        .. " what the plan wants, |cffff6060red|r = what PallyPower has now."
        .. " Press |cffffffffSend|r to push the plan.")
    smf:AddMessage(" ")

    -- Group by paladin, first-seen order (CheckPallyPowerSync walks paladins in
    -- roster order, greaters before that paladin's exceptions).
    local order, byPally = {}, {}
    for _, d in ipairs(diffs) do
        if not byPally[d.paladin] then
            byPally[d.paladin] = {}
            order[#order + 1] = d.paladin
        end
        local g = byPally[d.paladin]
        g[#g + 1] = d
    end

    for _, pally in ipairs(order) do
        smf:AddMessage(ColoredWho(pally) .. ":")
        for _, d in ipairs(byPally[pally]) do
            -- Class-wide greater vs. a single raider's exception.
            local target = d.isClass
                and ("|cffffd100" .. d.target .. "s|r")   -- "Warriors" (whole class)
                or ("|cffffffff" .. d.target .. "|r")      -- one raider
            smf:AddMessage(string.format("    %s   %s  |cff707070(now %s)|r",
                target, WantMarkup(d), HaveMarkup(d)))
        end
        smf:AddMessage(" ")
    end
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
        RenderDiffs(f) -- SyncToPallyPower writes the live tables synchronously,
                       -- so the recheck now reads as in sync.
        WhoDoesWhat:RefreshMainAssignmentsView() -- clear the section's warning
    end)
    sendBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Send to PallyPower", 1, 1, 1)
        GameTooltip:AddLine("Push the computed plan into PallyPower and"
            .. " broadcast it to the other paladins.", 0.8, 0.8, 0.8, true)
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

    local smf = CreateFrame("ScrollingMessageFrame", nil, f)
    smf:SetPoint("TOPLEFT", MARGIN, -(f.titleBarHeight + 10))
    smf:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN + BOTTOM_STRIP)
    smf:SetFontObject(GameFontHighlight)
    smf:SetJustifyH("LEFT")
    smf:SetFading(false)
    smf:SetMaxLines(400)
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

    WhoDoesWhat:LogUiBuilding("Building PallyPower diff content.")

    diffFrame = f
    return f
end

-- Open (or re-render + raise) the PallyPower differences window. An optional
-- warning turns the secondary action into Ignore; manual Check opens normally.
function WhoDoesWhat:OpenPallyPowerDiffView(warningText)
    local f = EnsureFrame()
    self:LogUiBuilding("Opening PallyPower Differences...")
    f.warningText = warningText
    f.secondaryBtn:SetText(warningText and "Ignore" or "Recheck")
    RenderDiffs(f)
    f:Show()
    f:Raise()
end
