local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Shared chrome for all WhoDoesWhat windows so every view gets the same look
-- and the same title-bar / close / drag / Escape behaviour.

WhoDoesWhat.TITLEBAR_H = 22

-- Apply the addon's compact treatment to Blizzard's legacy dropdown chrome.
-- Its three housing textures are 64px tall (with transparent padding) around
-- a 24px arrow. Trim and position that housing without scaling any click
-- target or menu content, then place its label and arrow independently.
function WhoDoesWhat:StyleDropdown(dd, leftAlign)
    local name = dd:GetName()
    if not name then return end

    if not dd.wdwHousingStyled then
        for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
            local texture = _G[name .. suffix]
            if texture then texture:SetHeight(57) end
        end
        local left = _G[name .. "Left"]
        local button = _G[name .. "Button"]
        local label = _G[name .. "Text"]
        -- Middle and Right are chained from Left, so moving Left shifts the
        -- entire housing. Its dependent arrow/text anchors follow it; leave
        -- the arrow 0.5px and text 2.8px lower, then nudge the arrow right.
        if left then left:AdjustPointsOffset(0, -3) end
        if button then button:AdjustPointsOffset(2, 2.5) end
        if label then label:AdjustPointsOffset(0, 0.2) end
        dd.wdwHousingStyled = true
    end

    if leftAlign and not dd.wdwTextAligned then
        local label = _G[name .. "Text"]
        if label then
            label:SetJustifyH("LEFT")
            label:SetWidth(label:GetWidth() + 5)
            label:AdjustPointsOffset(0, -1)
        end
        dd.wdwTextAligned = true
    end
end

-- Create a standard WDW window frame: solid black backdrop, a title bar with
-- text, a close button, draggable, closes on Escape. Returns the frame; the
-- caller anchors its own content below the title bar (offset f.titleBarHeight).
-- `globalName` must be unique per window (used for the Escape-close registry).
function WhoDoesWhat:CreateWindowFrame(globalName, width, height, titleText)
    WhoDoesWhat:LogUiBuilding("Creating window frame: " .. globalName)

    local f = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)

    -- Solid black background with a thin border
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.95)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4)

    -- Draggable by the whole frame
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Close with Escape
    tinsert(UISpecialFrames, globalName)

    -- Title bar strip
    local titlebar = f:CreateTexture(nil, "ARTWORK")
    titlebar:SetColorTexture(0.12, 0.12, 0.15, 1)
    titlebar:SetPoint("TOPLEFT", 5, -5)
    titlebar:SetPoint("TOPRIGHT", -5, -5)
    titlebar:SetHeight(WhoDoesWhat.TITLEBAR_H)
    f.titleBarTexture = titlebar

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", titlebar, "LEFT", 10, 0)
    title:SetText(titleText or "")
    f.titleText = title

    -- Close button
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 1, 1)
    close:SetScript("OnClick", function() f:Hide() end)
    f.closeButton = close

    f.titleBarHeight = WhoDoesWhat.TITLEBAR_H
    f:Hide()
    return f
end
