local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local _, ns = ...
local UI = ns.UI
local L = ns.L

-- ---------------------------------------------------------------------------
-- Party summary on the Raid tab, solo or in a party. On Forever the tab outside
-- a raid is an empty inset under the role counts; this fills it with one row
-- per party member (class, name, level, board role, talent spread) and a
-- button to the Members tab.
--
-- The panel is a child of FriendsFrame. Parented to UIParent it never drew:
-- FriendsFrame is toplevel, and on Forever an outside MEDIUM frame stayed
-- under the window even levelled above its NineSlice -- only HIGH showed it,
-- which also put it over the bags. As a child it draws and raises with the
-- window. It stays out of RaidFrame and its secure rows (the taint note in
-- RaidMenuExtensions.lua); visibility follows RaidFrame's OnShow/OnHide.
-- ---------------------------------------------------------------------------

local MAX_ROWS = 5
local ROW_HEIGHT = 38
local CLASS_ICON_SIZE = 28
local ROLE_ICON_SIZE = 14
local GROUP_ROLE_SIZE = 18
local PAD = 8

local WOW_ROLE_BY_BLIZZARD = { TANK = "tank", HEALER = "healer", DAMAGER = "dps" }

local panel
local dirty = false

local function RoleText(key)
    local roleId = key and WhoDoesWhat:GetAssignedRole(key)
    if not roleId then return "|cff909090" .. L.PARTY_NO_ROLE .. "|r" end
    local _, role = WhoDoesWhat:FindRoleById(roleId)
    if role and role.name then
        return WhoDoesWhat.Assign.RoleIconMarkup(key, ROLE_ICON_SIZE) .. role.name
    end
    return "|cff909090" .. L.PARTY_NO_ROLE .. "|r"
end

-- tank / healer / dps: the board role's group role, else the Blizzard role
-- flag, else nil.
local function GroupRole(key, unit)
    local roleId = key and WhoDoesWhat:GetAssignedRole(key)
    if roleId then
        local _, role = WhoDoesWhat:FindRoleById(roleId)
        if role and role.wowRole then return role.wowRole end
    end
    return UnitGroupRolesAssigned and WOW_ROLE_BY_BLIZZARD[UnitGroupRolesAssigned(unit)]
end

-- " (5/46/0)" from the inspect cache, or "" while nothing is read.
local function TalentText(unit)
    local snapshot = WhoDoesWhat:GetTalentSnapshot(unit)
    if not snapshot then return "" end
    local p = snapshot.points
    return string.format(" |cffffd100(%d/%d/%d)|r", p[1], p[2], p[3])
end

-- The zone a unit tooltip would name. The map lookup covers party members in
-- other zones; nil (or a secret value) just leaves the slot empty.
local function ZoneText(unit)
    if UnitIsUnit(unit, "player") then return GetRealZoneText() or "" end
    local mapId = C_Map and C_Map.GetBestMapForUnit(unit)
    if not mapId or WhoDoesWhat:IsSecret(mapId) then return "" end
    local info = C_Map.GetMapInfo(mapId)
    return info and info.name or ""
end

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent.header, "BOTTOMLEFT", 0, -PAD - (index - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, index % 2 == 1 and 0.04 or 0.08)

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(CLASS_ICON_SIZE, CLASS_ICON_SIZE)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
    row.name:SetJustifyH("LEFT")

    row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.level:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -5)
    row.level:SetJustifyH("RIGHT")

    row.role = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.role:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
    row.role:SetJustifyH("LEFT")

    row.zone = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.zone:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 5)
    row.zone:SetJustifyH("RIGHT")

    -- Group-role badge (shield / plus / sword) over the icon's bottom-right,
    -- as the role customizer overlaps its spec icon on the class icon.
    row.groupRole = row:CreateTexture(nil, "OVERLAY")
    row.groupRole:SetSize(GROUP_ROLE_SIZE, GROUP_ROLE_SIZE)
    row.groupRole:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 5, -5)

    row:SetScript("OnEnter", function(self)
        if not self.unit or not UnitExists(self.unit) then return end
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT", 12, 12)
        GameTooltip:SetUnit(self.unit)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Either click opens the unit menu a party frame's right-click would,
    -- WDW's own role/assignment entries included (UnitMenuExtensions.lua).
    -- Opened from addon code, so protected entries such as Set Focus may be
    -- blocked; targeting on left-click would need a secure button, which
    -- would make this panel protected and unable to hide in combat.
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self)
        if not (self.unit and UnitExists(self.unit) and UnitPopup_OpenMenu) then return end
        GameTooltip:Hide()
        local which = UnitIsUnit(self.unit, "player") and "SELF" or "PARTY"
        local name, server = UnitName(self.unit)
        UnitPopup_OpenMenu(which, { unit = self.unit, name = name, server = server })
    end)
    return row
end

local function PaintRow(row, unit)
    row.unit = unit
    local key = WhoDoesWhat:UnitKey(unit)
    local _, token = UnitClass(unit)
    local classInfo = token and WhoDoesWhat.Assign.GetClassInfoByToken(token)
    row.icon:SetTexture(classInfo and classInfo.classIcon or 134400)

    local online = UnitIsConnected(unit) ~= false
    local label = WhoDoesWhat:LabelName(key or UNKNOWN)
    if not online then
        label = "|cff808080" .. L.PARTY_OFFLINE:format(label) .. "|r"
    elseif classInfo then
        label = "|cff" .. classInfo.colorHex .. label .. "|r"
    end
    if online and UnitIsDeadOrGhost(unit) then
        label = label .. " |cffff4040" .. L.PARTY_DEAD .. "|r"
    end
    row.name:SetText(label)
    row.icon:SetDesaturated(not online)

    local groupRole = GroupRole(key, unit)
    if groupRole then
        WhoDoesWhat:SetRoleIconTexture(row.groupRole, WhoDoesWhat:MakeRoleIcon(groupRole))
        row.groupRole:SetDesaturated(not online)
        row.groupRole:Show()
    else
        row.groupRole:Hide()
    end

    local level = UnitLevel(unit)
    row.level:SetText(level and level > 0 and L.PARTY_LEVEL:format(level) or "")
    row.role:SetText(RoleText(key) .. TalentText(unit))
    row.zone:SetText(online and ZoneText(unit) or "")
    row:Show()
end

local function Paint()
    if InCombatLockdown() then
        dirty = true
        return
    end
    dirty = false
    local units = { "player" }
    for i = 1, math.min(GetNumSubgroupMembers(), MAX_ROWS - 1) do
        units[#units + 1] = "party" .. i
    end
    for i = 1, MAX_ROWS do
        if units[i] then
            PaintRow(panel.rows[i], units[i])
        else
            panel.rows[i]:Hide()
        end
    end
end

local function ShouldShow()
    -- Solo too: the tab is just as empty, and the rows come down to our own.
    return RaidFrame and RaidFrame:IsVisible() and not IsInRaid()
end

-- Sit just above FriendsFrame.NineSlice, which spans the whole window ~500
-- levels over FriendsFrame. Re-levelled on every show in case the window's
-- own levels moved.
local function UpdateVisibility()
    if not panel then return end
    if ShouldShow() then
        local cover = FriendsFrame.NineSlice or RaidFrame
        panel:SetFrameLevel(math.max(cover:GetFrameLevel(), RaidFrame:GetFrameLevel()) + 1)
        panel:Show()
        Paint()
    else
        panel:Hide()
    end
end

local function Build()
    panel = CreateFrame("Frame", "WhoDoesWhatRaidTabParty", FriendsFrame)
    panel:SetPoint("TOPLEFT", FriendsFrameInset, "TOPLEFT", PAD, -PAD)
    panel:SetPoint("BOTTOMRIGHT", FriendsFrameInset, "BOTTOMRIGHT", 0, PAD)
    panel:Hide()

    -- Party members change zones without an event reaching us, so re-read
    -- while the panel is open; a closed panel runs no OnUpdate at all.
    local elapsedSinceZones = 0
    panel:SetScript("OnUpdate", function(_, elapsed)
        elapsedSinceZones = elapsedSinceZones + elapsed
        if elapsedSinceZones < 2 then return end
        elapsedSinceZones = 0
        Paint()
    end)

    panel.header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.header:SetPoint("TOPLEFT", 2, -4)
    panel.header:SetText(L.PARTY_HEADER)

    local members = UI.CreateTextButton(panel, L.TAB_MEMBERS, L.TAB_MEMBERS,
        L.PARTY_MEMBERS_TIP, function()
            WhoDoesWhat:ShowMainTab("members", true)
        end)
    members:SetPoint("RIGHT", panel, "TOPRIGHT", -PAD, -10)

    panel.rows = {}
    for i = 1, MAX_ROWS do
        panel.rows[i] = CreateRow(panel, i)
    end

    RaidFrame:HookScript("OnShow", UpdateVisibility)
    RaidFrame:HookScript("OnHide", UpdateVisibility)
end

-- Board edits and talent arrivals ride RefreshBoardViews (ViewRefresh.lua);
-- a hidden panel costs one visibility check.
function WhoDoesWhat:RefreshRaidTabParty()
    if panel and panel:IsShown() then Paint() end
end

if not WhoDoesWhat.ClientFeatures.isForever then return end

-- RaidFrame may arrive with a load-on-demand Blizzard addon rather than at
-- login, so try again on every addon load until it exists.
local function TryBuild()
    if panel or not (RaidFrame and FriendsFrameInset) then return end
    Build()
    UpdateVisibility()
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:RegisterEvent("ADDON_LOADED")
watcher:RegisterEvent("GROUP_ROSTER_UPDATE")
watcher:RegisterEvent("UNIT_LEVEL")
watcher:RegisterEvent("UNIT_CONNECTION")
watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
watcher:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_LOGIN" or event == "ADDON_LOADED" then
        TryBuild()
        return
    end
    if not panel then return end
    if event == "GROUP_ROSTER_UPDATE" then
        UpdateVisibility()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if dirty and panel:IsShown() then Paint() end
    elseif panel:IsShown() and (unit == "player" or (unit and unit:match("^party%d$"))) then
        -- UNIT_LEVEL also fires for targets and nameplates.
        Paint()
    end
end)
