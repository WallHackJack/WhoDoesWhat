local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Shared chrome for all WhoDoesWhat windows so every view gets the same look
-- and the same title-bar / close / drag / Escape behaviour.

WhoDoesWhat.TITLEBAR_H = 22

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
