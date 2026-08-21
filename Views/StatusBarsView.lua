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
-- Tooltip name lists: long enough to be worth reading, short enough not to
-- cover the screen while a pull is starting. Past this many the rest collapse
-- into a count. One global number rather than a per-check option -- it is a
-- property of how much tooltip you want to read, not of any one buff.
local DEFAULT_TOOLTIP_NAMES = 10
local function TooltipNameLimit()
    return WhoDoesWhat.db.profile.settings.statusBarTooltipNames
        or DEFAULT_TOOLTIP_NAMES
end
local TOOLTIP_ANCHORS = {
    LEFT = true, RIGHT = true, ABOVE = true, BELOW = true,
}

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
local classByName = {}
for _, classInfo in ipairs(WhoDoesWhat.Classes) do
    classColors[classInfo.name] = classInfo.colorRGB
    classByName[classInfo.name] = classInfo
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

-- ---------------------------------------------------------------------------
-- Announce (shift-right-click)
-- ---------------------------------------------------------------------------
--
-- One chat line per bar: the count, what it is, and who is still missing it.
-- Names truncate the same way the tooltip's do -- it is the same question
-- asked out loud, so it answers to the same setting.
--
-- Debuffs never announce. "Here is everyone who is NOT poisoned" is a list
-- nobody needs read into raid chat, and the useful direction is already the
-- bar's own colour.

-- Chat cuts a message at 255 bytes; stop short so the "and N more" tail always
-- survives.
local ANNOUNCE_BUDGET = 240
-- A burst of SendChatMessage risks the server throttle, so several paladin
-- lines go out spaced apart. Same value the assignment mass-mail uses.
local ANNOUNCE_STAGGER = 0.25

-- Chat has no class colour and no room for realm tags. A pet answers under its
-- owner's name, which is who has to fix it.
local function AnnounceName(name)
    local owner = name:match("^(.+)'s Pet$")
    if owner then return (strsplit("-", owner)) .. " (pet)" end
    return (strsplit("-", name))
end

-- nil when there is nobody left to name. A finished bar is never announced at
-- all (see canAnnounce), and inside a combined paladin bar a paladin who is
-- done has no line of their own.
local function AnnounceLine(prefix, names)
    if #names == 0 then return nil end
    local limit = TooltipNameLimit()
    local budget = ANNOUNCE_BUDGET - #prefix
    local shown, used = {}, 0
    for _, name in ipairs(names) do
        if #shown >= limit then break end
        local text = AnnounceName(name)
        if used + #text + 2 > budget then break end
        used = used + #text + 2
        shown[#shown + 1] = text
    end
    local rest = #names - #shown
    local body = table.concat(shown, ", ")
    if rest > 0 then
        body = (#shown > 0 and body .. " " or "") .. "and " .. rest .. " more"
    end
    return prefix .. body
end

-- "[18/25] Hewmongus (Might, Wisdom): x, y, z". Which blessing each raider is
-- missing is deliberately left out -- the paladin knows their own assignment,
-- and naming it per raider turns one line into five.
local function AnnouncePaladinLine(paladin, coverage)
    local blessings = {}
    for _, buff in ipairs(paladin.buffs or {}) do
        local definition = WhoDoesWhat.PaladinBuffs[buff.key]
        blessings[#blessings + 1] = definition and definition.name_short
            or buff.key
    end
    local seen, names = {}, {}
    for _, cell in ipairs(coverage.missing or {}) do
        if not seen[cell.target] then
            seen[cell.target] = true
            names[#names + 1] = cell.target
        end
    end
    local label = AnnounceName(paladin.name)
    if #blessings > 0 then
        label = label .. " (" .. table.concat(blessings, ", ") .. ")"
    end
    return AnnounceLine(string.format("[%d/%d] %s: ",
        coverage.correct, coverage.total, label), names)
end

-- Recomputed at click time rather than read off the painted row: a combined
-- paladin bar carries one flattened list, and this wants it split back apart
-- per paladin. A click can afford the model call that a repaint could not.
local function AnnounceLines(row)
    local lines = {}
    if row.isPaladinRow then
        local Assign = WhoDoesWhat.Assign
        local plan = Assign.GetActivePaladinBuffPlan()
        local options = WhoDoesWhat:GetStatusBarCheckOptions("paladinBuffs")
        local _, _, byPaladin =
            Assign.ComputePaladinBuffCoverage(plan, options.hunterPets)
        for _, paladin in ipairs(Assign.ComputePaladinBuffSummary(plan)) do
            local coverage = byPaladin[paladin.name]
            -- The combined bar speaks for every paladin; one paladin's own row
            -- speaks only for them. Either way a paladin whose blessings are
            -- all up is skipped rather than announced as finished.
            if coverage and coverage.correct < coverage.total
                and (row.paladinName == nil
                    or row.paladinName == paladin.name) then
                local line = AnnouncePaladinLine(paladin, coverage)
                if line then lines[#lines + 1] = line end
            end
        end
    elseif row.buffKey then
        local definition = WhoDoesWhat.StatusBarChecks[row.buffKey]
        local names = {}
        for _, entry in ipairs(row.flagged or {}) do
            names[#names + 1] = entry.name
        end
        lines[1] = AnnounceLine(string.format("[%d/%d] %s: ",
            row.correct or 0, row.total or 0,
            definition and definition.name or row.buffKey), names)
    end
    return lines
end

local function SendAnnounce(lines)
    if #lines == 0 then return end
    local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
    for i, line in ipairs(lines) do
        if not channel then
            -- Solo it has nowhere to go, but seeing it is how you check the
            -- wording before a raid does.
            WhoDoesWhat:Print(line)
        elseif i == 1 then
            SendChatMessage(line, channel)
        else
            C_Timer.After((i - 1) * ANNOUNCE_STAGGER, function()
                SendChatMessage(line, channel)
            end)
        end
    end
end

local function AnnounceRow(row)
    -- State rows (PallyPower, Action Items) have an optionsKey but no
    -- coverage, so they fall out here along with the debuffs.
    if not row or not row.canAnnounce then return end
    SendAnnounce(AnnounceLines(row))
end

-- The whole window read out, in the order it is painted. What is on screen is
-- the list: a bar hidden by its own scope or "hide when complete" option is
-- one you have already said you do not want to hear about.
local function AnnounceAll()
    local lines = {}
    for _, row in ipairs(view and view.rows or {}) do
        if row:IsShown() and row.canAnnounce then
            for _, line in ipairs(AnnounceLines(row)) do
                lines[#lines + 1] = line
            end
        end
    end
    SendAnnounce(lines)
end

-- Modified clicks anywhere in the window are shortcuts to the buff views;
-- plain clicks stay with the rows themselves (the PallyPower row opens the
-- diff view). A row carries the check it draws (optionsKey), so alt-right-click
-- lands on that row's own cog options instead of the bare Buff Tracking list.
local function StatusBarsClick(self, button)
    if button == "RightButton" then
        if IsAltKeyDown() then
            local key = self and self.optionsKey
            if key then
                WhoDoesWhat:OpenBuffTrackingOptions(key)
            else
                WhoDoesWhat:OpenAddonSettingsView("Status Bars")
            end
        elseif IsShiftKeyDown() then
            -- Only a row speaks for itself; the title strip and the window
            -- behind the rows speak for all of them.
            if self and self.optionsKey then
                AnnounceRow(self)
            else
                AnnounceAll()
            end
        end
    elseif button == "LeftButton" and IsShiftKeyDown() then
        WhoDoesWhat:OpenBuffingGridView()
    end
end

-- Same double-line shortcut layout the minimap button uses. Only the title
-- strip carries these now; the bars keep their tooltips to their own status.
local function AddShortcutTooltipLines()
    GameTooltip:AddDoubleLine("Alt-Right-Click:", "Settings",
        1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Shift-Left-Click:", "Buffing Grid",
        1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Shift-Right-Click:", "Announce All",
        1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Alt-Right-Click Row:", "Edit",
        1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Shift-Right-Click Row:", "Announce",
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

-- ---------------------------------------------------------------------------
-- Repaint skips
-- ---------------------------------------------------------------------------
--
-- This view repaints in full on every buff-tracking notify -- up to 10Hz in a
-- 40-man -- but most of what it paints does not move between those repaints.
-- Icons, names and row positions only change when a bar is added, removed or
-- reordered; what actually changes is the bar value, its colour and the
-- progress label.
--
-- Widget setters are C calls, and the positioning ones dirty the frame's
-- layout, so re-applying an unchanged value is not free. These remember what
-- was last applied and skip the call when it has not moved. The cached value
-- lives on the widget, so a pooled row that is hidden and re-shown keeps it --
-- which is correct: hiding a frame does not discard its texture or its point.
local function SetTextCached(fontString, text)
    if fontString.paintedText == text then return end
    fontString.paintedText = text
    fontString:SetText(text)
end

local function SetTextureCached(texture, path)
    if texture.paintedTexture == path then return end
    texture.paintedTexture = path
    texture:SetTexture(path)
end

-- Rows are stacked from the top of the content area, so a row's position is
-- entirely its offset. Re-pointing every row on every repaint was invalidating
-- the whole frame's layout several times a second for no visual change.
local function SetRowOffsetCached(row, offset)
    if row.paintedOffset == offset then return end
    row.paintedOffset = offset
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", view, "TOPLEFT", INSET + PAD, -offset)
end

local function SetRowGlow(row, shown)
    if not LCG then return end
    if shown and not row.glowing then
        LCG.PixelGlow_Start(row, nil, 16, nil, 3, nil, nil, nil, nil, nil, 4)
        row.glowing = true
    elseif not shown and row.glowing then
        LCG.PixelGlow_Stop(row)
        row.glowing = nil
    end
end

-- ---------------------------------------------------------------------------
-- Row tooltips
-- ---------------------------------------------------------------------------

-- Names are shown the way the raid says them: no realm suffix, and a hunter
-- pet by its own name with its owner behind it.
local function ShortTargetName(name)
    return WhoDoesWhat:DisplayName(name)
end

local function ColoredName(name, classInfo)
    return "|cff" .. ((classInfo and classInfo.colorHex) or "FFFFFF")
        .. ShortTargetName(name) .. "|r"
end

local function IsLocalPlayerName(name)
    local short = name and name:match("^([^%-]+)")
    return short ~= nil and short == UnitName("player")
end

local function LocalPlayerKey()
    local name, realm = UnitName("player")
    if name and realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- The local player's class as WhoDoesWhat names it ("Priest"). A character
-- can't change class mid-session, so this is resolved once.
local localClassName
local function LocalClassName()
    if localClassName == nil then
        local _, token = UnitClass("player")
        localClassName = false
        for _, classInfo in ipairs(WhoDoesWhat.Classes) do
            if token and classInfo.name:upper() == token then
                localClassName = classInfo.name
                break
            end
        end
    end
    return localClassName
end

-- Flagged lists mix raiders with hunter pets, which ride in as "Owner's Pet".
-- A pet counts as its owner's own row, since the owner is who feeds it.
local function IsLocalPlayerEntry(entry)
    return IsLocalPlayerName(entry.name:match("^(.+)'s Pet$") or entry.name)
end

-- "Glow when responsible": the local player's class is the one that supplies
-- this buff and somebody in the group is still without it. Where the check
-- only counts the best available rank, the raid's top-rank provider is the one
-- being asked -- a weaker caster overwriting them would not move the bar, so
-- their row stays quiet.
local function ResponsibleForCheck(key, definition, options, coverage)
    if not options.responsibleGlow or options.negative then return false end
    if definition.hiddenOptions and definition.hiddenOptions.responsibleGlow then
        return false
    end
    -- Food and its like: nobody else can cast it for you, so there is no class
    -- to be. Responsibility is simply still being on the list yourself -- or
    -- your pet being, which is the same errand.
    if definition.selfSupplied then
        for _, entry in ipairs(coverage.flagged or {}) do
            if IsLocalPlayerEntry(entry) then return true end
        end
        return false
    end
    -- The check's "Requires Class" is the whole definition of whose job this
    -- is; clearing it leaves nobody in particular on the hook.
    if not options.requiredClass
        or options.requiredClass ~= LocalClassName() then
        return false
    end
    if coverage.total == 0 or coverage.correct >= coverage.total then
        return false
    end
    if coverage.bestRank == nil then return true end
    local mine = WhoDoesWhat:GetCoreBuffTalent(LocalPlayerKey(), key)
    return mine ~= nil and mine >= coverage.bestRank
end

-- "Glow when some missing": a different question from responsibility. The
-- check has almost landed -- a lust that reached all but a couple of raiders,
-- because they were dead when it went out and have been brezzed since, or
-- because a shadowfiend was summoned after it. Below the threshold nothing has
-- happened yet and a glow would only nag; at full coverage there is nothing
-- left to cast. In between is the one cast worth telling somebody about.
local PARTIAL_GLOW_RATIO = 0.8

local function PartialGlowForCheck(definition, options, coverage)
    if not definition.partialGlow or not options.partialGlow then return false end
    if coverage.total == 0 or coverage.correct >= coverage.total then
        return false
    end
    if coverage.correct / coverage.total < PARTIAL_GLOW_RATIO then return false end
    -- Off by default: anyone can see that a lust missed people, but only the
    -- class that supplies it can answer, so the narrow reading is offered too.
    if options.partialGlowOnlyClass then
        return options.requiredClass ~= false
            and options.requiredClass == LocalClassName()
    end
    return true
end

-- A hunter pet rides the paladin plan as a warrior; colour it as its owner's
-- class instead, which is how the rest of the UI shows pets.
local function TargetClassInfo(target, planClassName)
    if target:match("'s Pet$") then return classByName.Hunter end
    return planClassName and classByName[planClassName] or nil
end

local function ProgressHex(correct, total, negative)
    if total == 0 then return "999999" end
    if negative and correct == 0 or (not negative and correct >= total) then
        return "4dff4d"
    end
    if negative and correct >= total or (not negative and correct == 0) then
        return "ff4d4d"
    end
    return "ffd133"
end

-- Only the numbers that carry the state are coloured -- how many are done and
-- the percentage -- so "of N" stays white and the eye lands on the two that
-- matter.
local function AddProgressLine(correct, total, negative)
    local percent = total > 0 and math.floor(correct / total * 100 + 0.5) or 0
    local hex = "|cff" .. ProgressHex(correct, total, negative)
    GameTooltip:AddLine(hex .. correct .. "|r of " .. total
        .. "  " .. hex .. "(" .. percent .. "%)|r", 1, 1, 1)
end

-- Where a best-rank requirement is in force, one number can't tell the story:
-- somebody carrying a weaker Fortitude is in a different place from somebody
-- carrying none. Three lines split it -- what's optimal, what's buffed at all,
-- and the bare count of who has nothing.
local function AddSplitProgressLines(correct, anyCorrect, total)
    local function Percent(count)
        return math.floor(count / total * 100 + 0.5)
    end
    GameTooltip:AddLine("|cff4dff4d" .. correct .. "/" .. total
        .. " with best buff (" .. Percent(correct) .. "%)|r", 1, 1, 1)
    GameTooltip:AddLine("|cffffd133" .. anyCorrect .. "/" .. total
        .. " with any buff (" .. Percent(anyCorrect) .. "%)|r", 1, 1, 1)
    if anyCorrect < total then
        GameTooltip:AddLine("|cffff4d4d" .. (total - anyCorrect)
            .. " missing buff|r", 1, 1, 1)
    end
end

-- Your own row leads the list. A truncated list of two dozen names is a poor
-- way to answer "do I still need to eat", and on a self-supplied check that is
-- the only question the row asks. Everyone else keeps roster order.
local function SelfFirst(entries)
    local mine, rest = {}, {}
    for _, entry in ipairs(entries) do
        local bucket = IsLocalPlayerEntry(entry) and mine or rest
        bucket[#bucket + 1] = entry
    end
    if #mine == 0 then return entries end
    -- Owner above pet, whichever order the roster walk found them in.
    table.sort(mine, function(a, b) return not a.isPet and b.isPet == true end)
    for _, entry in ipairs(rest) do mine[#mine + 1] = entry end
    return mine
end

-- The actionable end of every tooltip: who still needs attention. `Format`
-- turns one entry into its line, so the paladin rows can lead with the
-- blessing icon while the raid-buff rows are just names.
local function AddEntryLines(entries, Format)
    local limit = TooltipNameLimit()
    local shown = #entries < limit and #entries or limit
    for i = 1, shown do
        local text, right = Format(entries[i])
        if right then
            GameTooltip:AddDoubleLine(text, right, 1, 1, 1, 0.6, 0.6, 0.6)
        else
            GameTooltip:AddLine(text, 1, 1, 1)
        end
    end
    if shown < #entries then
        GameTooltip:AddLine("... and " .. (#entries - shown) .. " more",
            0.6, 0.6, 0.6)
    end
end

-- The people to ask for this buff: the best-talented casters still in the
-- group, or everyone of the class while no ranks have been scanned. The rank
-- rides along so a raid-wide 0/2 is obvious; the full breakdown of who has
-- what stays in the Buffing Grid's column headers.
local function AddProviderLines(key, definition)
    local talent = definition.improvedTalent
    if not talent then return end
    local providers = WhoDoesWhat.Assign.ComputeCoreBuffProviders(key)
    local best
    for _, provider in ipairs(providers) do
        if provider.available and provider.rank ~= nil
            and (best == nil or provider.rank > best) then
            best = provider.rank
        end
    end
    local classInfo = classByName[definition.className]
    local matches = {}
    for _, provider in ipairs(providers) do
        if provider.available and provider.rank == best then
            matches[#matches + 1] = provider.name
        end
    end
    -- Nobody has spent a point, so every caster of the class is the same cast.
    -- A column of names all reading (0/5) says less than the class name does.
    if best == 0 and #matches > 1 then
        GameTooltip:AddLine("|cff" .. ((classInfo and classInfo.colorHex)
            or "FFFFFF") .. "Any " .. definition.className .. "|r", 1, 1, 1)
        return
    end
    local rankText = best and (" |cff909090(" .. best .. "/"
        .. talent.maxRank .. ")|r") or ""
    for _, name in ipairs(matches) do
        GameTooltip:AddLine(ColoredName(name, classInfo) .. rankText, 1, 1, 1)
    end
end

local function FillCoreTooltip(row)
    local definition = row.buffKey and WhoDoesWhat.StatusBarChecks[row.buffKey]
    if not definition then return end
    GameTooltip:SetText(definition.name, 1, 1, 1)
    -- With nobody present to cast it there is no progress to report and no
    -- point naming everyone who lacks it: the missing class is the whole
    -- story, and the check sits out of the raid's total coverage entirely.
    if row.unavailableClass then
        GameTooltip:AddLine("Unavailable: requires "
            .. row.unavailableClass .. ".", 1, 0.45, 0.2, true)
        GameTooltip:AddLine("Not counted toward raid coverage.",
            0.6, 0.6, 0.6, true)
        return
    end
    AddProviderLines(row.buffKey, definition)
    GameTooltip:AddLine(" ")
    -- Nothing in the group matches this check's target filters, so a 0 of 0
    -- count would say less than the words do.
    if row.total == 0 then
        GameTooltip:AddLine("No Targets", 0.6, 0.6, 0.6)
        return
    end
    local split = row.anyCorrect ~= nil and row.anyCorrect > row.correct
    if split then
        AddSplitProgressLines(row.correct, row.anyCorrect, row.total)
    else
        -- Colored to agree with the list under it rather than with the bar:
        -- for every check but mid-fight Sated these are the same thing, and
        -- there a full count is the good end, not the saturated one.
        AddProgressLine(row.correct, row.total, not row.flaggedAreMissing)
    end

    local flagged = row.flagged or {}
    if #flagged == 0 then
        -- The count above is already green; this line is just the words for it.
        -- Which emptiness this is follows the list, not the check's polarity:
        -- a debuff that lists the people missing it is empty when everyone has
        -- it (see flaggedAreMissing in Assignments.lua).
        GameTooltip:AddLine(row.flaggedAreMissing and "Everyone has it."
            or "Nobody has it.", 0.6, 0.6, 0.6)
    else
        if split then
            -- Nothing beats nothing: the unbuffed lead the list, so a truncated
            -- one names the people who actually need a cast.
            table.sort(flagged, function(a, b)
                if (a.unoptimal == true) ~= (b.unoptimal == true) then
                    return b.unoptimal == true
                end
                return a.name < b.name
            end)
        end
        flagged = SelfFirst(flagged)
        local maxRank = definition.improvedTalent
            and definition.improvedTalent.maxRank
        AddEntryLines(flagged, function(entry)
            local right
            if entry.outside then
                -- The distinction that matters: this one is not weak, it is
                -- temporary. It goes away by itself when the boss is pulled.
                right = "outside raid"
            elseif entry.unoptimal then
                right = entry.rank and maxRank
                    and ("weaker (" .. entry.rank .. "/" .. maxRank .. ")")
                    or "weaker buff"
            end
            return ColoredName(entry.name, entry.classInfo), right
        end)
    end
end

local function FillPaladinTooltip(row)
    if row.paladinName then
        GameTooltip:SetText(WhoDoesWhat:RoleIconMarkup(
            row.roleIcon or paladinClass.classIcon, 16)
            .. " " .. ColoredName(row.paladinName, paladinClass), 1, 1, 1)
    else
        GameTooltip:SetText(WhoDoesWhat.StatusBarChecks.paladinBuffs.name, 1, 1, 1)
    end
    if row.awaitingTalents then
        GameTooltip:AddLine("Waiting on this paladin's talents; the plan is"
            .. " provisional until they arrive.", 1, 0.55, 0, true)
    end
    GameTooltip:AddLine(" ")
    AddProgressLine(row.correct, row.total)

    local missing = row.missing or {}
    if row.total == 0 then
        GameTooltip:AddLine("No blessings are assigned.", 0.6, 0.6, 0.6)
    elseif #missing == 0 then
        GameTooltip:AddLine("Every assigned blessing is up.", 0.6, 0.6, 0.6)
    else
        AddEntryLines(missing, function(entry)
            local buff = WhoDoesWhat.PaladinBuffs[entry.key]
            return "|T" .. buff.icon .. ":14:14:0:0|t "
                .. ColoredName(entry.target, entry.classInfo),
                entry.isGreater and buff.name_long
                    or (buff.name_long .. " (Lesser)")
        end)
    end
end

-- Which side of the hovered bar a tooltip opens on. Left and right track the
-- hovered row so the tooltip lines up with the bar it describes; above and
-- below clear the whole window, which keeps a tall tooltip off the other bars.
local function TooltipAnchor()
    local saved = WhoDoesWhat.db.profile.settings.statusBarTooltipAnchor
    return TOOLTIP_ANCHORS[saved] and saved or "LEFT"
end

local function ShowRowTooltip(frame)
    GameTooltip:SetOwner(frame, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    local anchor = TooltipAnchor()
    if anchor == "RIGHT" then
        GameTooltip:SetPoint("TOPLEFT", frame, "TOPRIGHT", 6, 0)
    elseif anchor == "ABOVE" then
        GameTooltip:SetPoint("BOTTOMLEFT", view, "TOPLEFT", 0, 6)
    elseif anchor == "BELOW" then
        GameTooltip:SetPoint("TOPLEFT", view, "BOTTOMLEFT", 0, -6)
    else
        GameTooltip:SetPoint("TOPRIGHT", frame, "TOPLEFT", -6, 0)
    end
    frame:FillTooltip()
    -- Every row that knows which check it draws can be edited from here, so
    -- the hint rides along after each row's own content.
    if frame.optionsKey then
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Alt-Right-Click:", "Edit",
            1, 0.82, 0, 1, 1, 1)
        if frame.canAnnounce then
            GameTooltip:AddDoubleLine("Shift-Right-Click:", "Announce",
                1, 0.82, 0, 1, 1, 1)
        end
    end
    GameTooltip:Show()
end

local function HideRowTooltip(frame)
    if GameTooltip:GetOwner() == frame then GameTooltip:Hide() end
end

-- Progress text stays right-aligned regardless of the fill position.
local function LayoutProgressLabel(row)
    if row.correct == nil then return end

    -- A check whose required class is absent is not "0% done", it is
    -- unanswerable. Kept visible only because its bar opted out of hiding, so
    -- it reports why instead of showing a percentage nobody can move.
    local unavailable = row.total == 0 or row.unavailableClass ~= nil
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
        row.completeIcon:ClearAllPoints()
        row.completeIcon:SetSize(14, unavailable and 14 or math.floor(14 * 0.8 + 0.5))
        row.completeIcon:SetPoint("RIGHT", row.status, "RIGHT", -2, 0)
        local completeTexture = row.negative and row.saturatedStyle == "x"
            and NOT_READY_ICON or READY_ICON
        row.completeIcon:SetTexture(unavailable
            and ((row.awaitingTalents or row.unavailableClass)
                and WhoDoesWhat.WARNING_ICON or NOT_READY_ICON)
            or completeTexture)
        row.completeIcon:Show()
        -- The missing class goes where the percentage would have been; at
        -- ultra-compact widths the warning icon carries it alone.
        if row.unavailableClass and view:GetWidth() >= ULTRA_COMPACT_W then
            row.percent:SetText("No " .. row.unavailableClass)
            row.percent:Show()
            row.percent:ClearAllPoints()
            row.percent:SetPoint("RIGHT", row.completeIcon, "LEFT", -3, 0)
            row.name:SetPoint("RIGHT", row.percent, "LEFT", -4, 0)
        else
            row.percent:Hide()
            row.name:SetPoint("RIGHT", row.completeIcon, "LEFT", -4, 0)
        end
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

-- PallyPower and Action Items are not coverage bars: each is one line of state
-- plus a click that opens the window which fixes it. They share the builder,
-- the layout and the three visual buckets below --
--   "inactive"  grey text, no icon   (PallyPower absent / you're not grouped)
--   "ok"        green text + check   (in sync / nothing to fix)
--   "attention" orange text + warning, and the row becomes clickable
-- -- so only the icon, the tooltip wording and the target window differ.
local STATE_ROW_TYPES = {
    pallyPower = {
        title = "PallyPower status",
        openHint = "Click to open PallyPower Differences.",
        Open = function() WhoDoesWhat:OpenPallyPowerDiffView() end,
        CreateIcon = function(row)
            return K.CreatePallyPowerBadge(row, ICON_SIZE)
        end,
    },
    actionItems = {
        title = "Action Items",
        -- The window that fixes these used to be Action Items; it merged into
        -- the Members window, which is where the same rows live now. The check
        -- keeps its own key -- it is what the saved options and the bar order
        -- are stored under.
        openHint = "Click to open Group Members.",
        Open = function() WhoDoesWhat:OpenMembersView() end,
        CreateIcon = function(row)
            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(ICON_SIZE, ICON_SIZE)
            WhoDoesWhat:ApplyStatusCheckIcon(icon,
                WhoDoesWhat.StatusBarChecks.actionItems)
            return icon
        end,
    },
}

local function LayoutStateRow(row)
    local width = view:GetWidth()
    row.inactiveMark:SetShown(width < MIN_W and row.bucket == "inactive")
    if row.bucket == "attention" then
        row.statusText:SetText(width < MIN_W and tostring(row.count)
            or row.shortLabel)
        row.statusText:Show()
    elseif width < MIN_W then
        row.statusText:Hide()
    else
        row.statusText:SetText(row.label)
        row.statusText:Show()
    end
end

local function CreateRow(index)
    local row = CreateFrame("Frame", nil, view)
    row:SetSize(view:GetWidth() - INSET * 2 - PAD * 2, ROW_H)
    -- A mouse-enabled row swallows what the window behind it would have
    -- handled, so it carries the Alt-drag and shift-click shortcuts itself.
    AttachAltDrag(row)
    row:SetScript("OnMouseUp", StatusBarsClick)
    row.FillTooltip = function(self)
        if self.isPaladinRow then
            FillPaladinTooltip(self)
        else
            FillCoreTooltip(self)
        end
    end
    row:SetScript("OnEnter", ShowRowTooltip)
    row:SetScript("OnLeave", HideRowTooltip)

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

local function CreateStateRow(key)
    local kind = STATE_ROW_TYPES[key]
    local row = CreateFrame("Button", nil, view)
    row:SetSize(view:GetWidth() - INSET * 2 - PAD * 2, ROW_H)
    row.optionsKey = key
    -- Same as the bar rows: a mouse-enabled row swallows the drag the window
    -- behind it would have handled, so it has to carry Alt-drag itself.
    AttachAltDrag(row)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function(self)
        -- Shift-left-click belongs to the window shortcut below and Alt to the
        -- drag, so a plain click is the only one that opens anything.
        if IsShiftKeyDown() or IsAltKeyDown() then return end
        if self.bucket == "attention" then kind.Open() end
    end)
    row:SetScript("OnMouseUp", StatusBarsClick)
    row.FillTooltip = function(self)
        GameTooltip:SetText(kind.title, 1, 1, 1)
        if self.bucket == "ok" then
            GameTooltip:AddLine(self.label or "", 0.3, 1, 0.3, true)
        else
            GameTooltip:AddLine(self.label or "", 1, 0.55, 0, true)
        end
        if self.bucket == "attention" then
            GameTooltip:AddLine(kind.openHint, 0.8, 0.8, 0.8, true)
        end
    end
    row:SetScript("OnEnter", ShowRowTooltip)
    row:SetScript("OnLeave", HideRowTooltip)
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.04)
    row.highlight = highlight

    local badge = kind.CreateIcon(row)
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

-- The two state providers. Each returns the bucket plus the two strings the
-- row draws: `label` at full width, `shortLabel` once the count is the only
-- thing that fits.
local function PallyPowerRowState(paladinCount)
    -- The count is only returned once there is something to count; the
    -- inactive answers ("No Paladins") carry no third value at all.
    local ppState, ppText, ppDiffCount = K.GetPallyPowerState(paladinCount)
    local count = ppDiffCount or 0
    return {
        bucket = ppState == "synced" and "ok"
            or ppState == "inactive" and "inactive" or "attention",
        label = ppText,
        count = count,
        shortLabel = count .. " issue" .. (count == 1 and "" or "s"),
    }
end

local function ActionItemsRowState()
    -- Ungrouped is "inactive", not "clear": solo there is no group role to
    -- disagree with and nobody to promote, so the checks this row summarizes
    -- mostly can't fail, and a green tick for that says nothing. Short-circuits
    -- before GetRosterIssues, which does still report a roleless solo player.
    if not IsInGroup() then
        return { bucket = "inactive", label = "Not in a group.", count = 0 }
    end
    local count, actionable = WhoDoesWhat:CountActionItems()
    if count == 0 then
        return { bucket = "ok", label = "Nothing to fix.", count = 0 }
    end
    return {
        bucket = "attention",
        label = count .. " action" .. (count == 1 and "" or "s") .. " waiting.",
        count = count,
        shortLabel = count .. " to fix",
        -- Nothing here is yours to set: the row still reports the count, but
        -- it doesn't pulse about it.
        actionable = actionable > 0,
    }
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
    view.stateRows = {}
    view:SetScript("OnSizeChanged", function(self)
        LayoutHeader()
        local rowW = self:GetWidth() - INSET * 2 - PAD * 2
        for _, row in ipairs(self.rows) do
            row:SetWidth(rowW)
            if row:IsShown() then LayoutProgressLabel(row) end
        end
        for _, row in pairs(self.stateRows) do
            row:SetWidth(rowW)
            if row:IsShown() then LayoutStateRow(row) end
        end
    end)

    view:RegisterEvent("GROUP_ROSTER_UPDATE")
    -- "Consider all in combat and BGs" changes what counts as covered without
    -- a single aura moving, so the bars have to be told when it flips.
    view:RegisterEvent("PLAYER_REGEN_DISABLED")
    view:RegisterEvent("PLAYER_REGEN_ENABLED")
    view:RegisterEvent("PLAYER_ENTERING_WORLD")
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
        or self.Assign.HasMemberOfClass(paladinOptions.requiredClass)
    local paladinAvailable = paladinRequiredAvailable
        or not paladinOptions.hideBarUnavailable
    local showPaladinBars = paladinPreview
        or (paladinOptions.bar and paladinInScope and paladinAvailable)
    -- Same rule as the core checks: coverage only counts while the class that
    -- supplies it is actually here.
    local normalPaladinBars = paladinOptions.bar
        and paladinInScope and paladinRequiredAvailable
    -- Missing blessings for one paladin, greater-first: a lapsed class Greater
    -- is a single cast that fixes several raiders, so it leads the tooltip.
    local function MissingBlessings(paladinName)
        local coverage = coverageByPaladin[paladinName]
        local plan = buffPlan or {}
        local greater = plan.greaterByPaladin
            and plan.greaterByPaladin[paladinName]
        local entries = {}
        for _, cell in ipairs(coverage and coverage.missing or {}) do
            local className = plan.targetClass
                and plan.targetClass[cell.target]
            entries[#entries + 1] = {
                target = cell.target,
                key = cell.key,
                classInfo = TargetClassInfo(cell.target, className),
                isGreater = greater ~= nil and className ~= nil
                    and greater[className] == cell.key,
            }
        end
        table.sort(entries, function(a, b)
            if a.isGreater ~= b.isGreater then return a.isGreater end
            if a.target ~= b.target then return a.target < b.target end
            return a.key < b.key
        end)
        return entries
    end

    -- A paladin is responsible for their own bar only; the combined bar is the
    -- whole raid's blessings, so any paladin owns a gap in it.
    local paladinGlow = paladinOptions.responsibleGlow
        and paladinOptions.requiredClass ~= false
        and paladinOptions.requiredClass == LocalClassName()
    local paladinEntries = {}
    if paladinOptions.combinePaladinBars then
        local coverage = { correct = paladinCorrect, total = paladinTotal }
        local complete = paladinTotal > 0 and paladinCorrect >= paladinTotal
        if (paladinPreview or paladinTotal > 0) and showPaladinBars
            and (paladinPreview or not (paladinOptions.hideComplete and complete)) then
            local definition = self.StatusBarChecks.paladinBuffs
            local missing = {}
            for _, paladin in ipairs(summary) do
                for _, entry in ipairs(MissingBlessings(paladin.name)) do
                    missing[#missing + 1] = entry
                end
            end
            paladinEntries[#paladinEntries + 1] = {
                name = definition.name,
                icon = definition.icon,
                paladinRow = true,
                missing = missing,
                glow = paladinGlow and not complete and paladinTotal > 0,
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
            -- A paladin with nothing assigned has no coverage to report, and a
            -- 0/0 bar is a row that can never move. With a lot of paladins
            -- that's several rows of nothing, so they never get one.
            if showPaladinBars
                and (paladinPreview
                    or (coverage.total > 0
                        and not (paladinOptions.hideComplete and complete))) then
                paladinEntries[#paladinEntries + 1] = {
                    name = paladin.name,
                    icon = RoleIcon(paladin.name),
                    isPaladin = true,
                    paladinRow = true,
                    paladinName = paladin.name,
                    missing = MissingBlessings(paladin.name),
                    glow = paladinGlow and not complete
                        and coverage.total > 0
                        and IsLocalPlayerName(paladin.name),
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
    -- Both state rows are computed up front: their own visibility options are
    -- phrased in terms of the state ("hide when synced", "hide when clear"), so
    -- there is nothing to decide before knowing it.
    local pallyPowerOptions = self:GetStatusBarCheckOptions("pallyPower")
    local actionItemsOptions = self:GetStatusBarCheckOptions("actionItems")
    local stateData = {
        pallyPower = PallyPowerRowState(#summary),
        -- Skipped outright when the row is switched off. It walks the whole
        -- roster, and this function repaints on every buff-tracking notify.
        actionItems = actionItemsOptions.bar and ActionItemsRowState() or nil,
    }
    local showState = {}
    for _, key in ipairs(self:GetStatusBarCheckOrder()) do
        if key == "paladinBuffs" then
            for _, entry in ipairs(paladinEntries) do
                displayed[#displayed + 1] = entry
            end
        elseif key == "pallyPower" then
            local bucket = stateData.pallyPower.bucket
            showState.pallyPower = pallyPowerOptions.bar
                and StatusCheckInScope(pallyPowerOptions.scope)
                and not (pallyPowerOptions.hideWhenSynced and bucket == "ok")
                and not (pallyPowerOptions.hideWhenInactive
                    and bucket == "inactive")
            if showState.pallyPower then
                displayed[#displayed + 1] = { stateRow = "pallyPower" }
            end
        elseif key == "actionItems" then
            local state = stateData.actionItems
            local bucket = state and state.bucket
            showState.actionItems = actionItemsOptions.bar
                and StatusCheckInScope(actionItemsOptions.scope)
                and not (actionItemsOptions.hideWhenClear and bucket == "ok")
                and not (actionItemsOptions.hideWhenSolo
                    and bucket == "inactive")
                -- Only ever suppresses a row that's REPORTING work. A clear
                -- list is `ok`, and hiding that is hideWhenClear's job.
                and not (actionItemsOptions.hideWhenNotYours
                    and bucket == "attention"
                    and state.actionable == false)
            if showState.actionItems then
                displayed[#displayed + 1] = { stateRow = "actionItems" }
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
                -- An unavailable check never counts, shown or not: an
                -- unfillable 0/25 would hold the raid total down forever.
                if options.bar and inScope and coverage.available
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
                        buffKey = key,
                        flagged = coverage.flagged,
                        unavailableClass = not coverage.available
                            and options.requiredClass or nil,
                        glow = ResponsibleForCheck(key, buff, options, coverage)
                            or PartialGlowForCheck(buff, options, coverage),
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
    -- Only when the window actually changes shape. SetSize fires OnSizeChanged,
    -- which re-widths and re-lays out every row, and LoadPosition re-anchors the
    -- whole frame with a clamp calculation -- all of it was running on every
    -- repaint, though the shape only moves when a bar appears or disappears (or
    -- the width setting changes). A user drag writes overviewWidth on release,
    -- so a resize still lands here; skipping during the drag also stops this
    -- fighting the drag, which it previously did.
    local wantW = math.max(self.db.profile.settings.overviewWidth or DEFAULT_W,
        RESIZE_MIN_W)
    local wantH = CONTENT_TOP + contentH + PAD + INSET
    if view.paintedW ~= wantW or view.paintedH ~= wantH then
        view.paintedW, view.paintedH = wantW, wantH
        view:SetSize(wantW, wantH)
        LayoutHeader()
        if not view.moving and not view.resizing then LoadPosition() end
    end

    -- The two state rows draw identically off their bucket; only who is
    -- allowed to be nagged by the glow differs. PallyPower's assignments are
    -- the assistants' to push, so only they see it glow. Action Items goes
    -- finer: `state.actionable` is false when every outstanding item belongs to
    -- someone else, so a raider with no rights over anyone's role but their own
    -- still gets an honest count and no pulsing.
    local stateGlow = {
        pallyPower = pallyPowerOptions.assignmentIssuesGlow
            and self:IsRaidAssistant(),
        actionItems = actionItemsOptions.actionItemsGlow,
    }
    for key in pairs(STATE_ROW_TYPES) do
        if showState[key] then
            local row = view.stateRows[key] or CreateStateRow(key)
            view.stateRows[key] = row
            local state = stateData[key]
            row.bucket, row.label = state.bucket, state.label
            row.count, row.shortLabel = state.count, state.shortLabel
            local glow = stateGlow[key] and state.bucket == "attention"
                and state.actionable ~= false or false
            row.highlight:SetAlpha(glow and 1 or 0)
            local index
            for i, entry in ipairs(displayed) do
                if entry.stateRow == key then index = i break end
            end
            SetRowOffsetCached(row, CONTENT_TOP + (index - 1) * ROW_H)
            SetRowGlow(row, glow)

            -- Every line below is decided by the bucket alone, and the bucket
            -- changes far more rarely than this view repaints.
            if row.paintedBucket ~= state.bucket then
                row.paintedBucket = state.bucket
                local attention = state.bucket == "attention"
                row.stateIcon:ClearAllPoints()
                row.stateIcon:SetSize(attention and 12 or 14, attention and 12 or 14)
                row.statusText:ClearAllPoints()
                if state.bucket == "inactive" then
                    row.stateIcon:SetPoint("LEFT", 3, 0)
                    row.stateIcon:Hide()
                    row.statusText:SetPoint("LEFT", 4, 0)
                    row.statusText:SetPoint("RIGHT", -3, 0)
                    row.statusText:SetTextColor(0.6, 0.6, 0.6)
                elseif state.bucket == "ok" then
                    row.stateIcon:SetTexture(READY_ICON)
                    row.stateIcon:SetPoint("RIGHT", -3, 0)
                    row.stateIcon:Show()
                    row.statusText:SetPoint("LEFT", 3, 0)
                    row.statusText:SetPoint("RIGHT", row.stateIcon, "LEFT", -2, 0)
                    row.statusText:SetTextColor(0.3, 1, 0.3)
                else
                    row.stateIcon:SetTexture(self.WARNING_ICON)
                    row.stateIcon:SetPoint("RIGHT", -3, 0)
                    row.stateIcon:Show()
                    row.statusText:SetPoint("LEFT", 3, 0)
                    row.statusText:SetPoint("RIGHT", row.stateIcon, "LEFT", -3, 0)
                    row.statusText:SetTextColor(1, 0.55, 0)
                end
            end
            LayoutStateRow(row)
            row:Show()
        elseif view.stateRows[key] then
            SetRowGlow(view.stateRows[key], false)
            view.stateRows[key]:Hide()
        end
    end

    local normalIndex = 0
    for displayIndex, entry in ipairs(displayed) do
        if not entry.stateRow then
            normalIndex = normalIndex + 1
            local row = view.rows[normalIndex] or CreateRow(normalIndex)
            local coverage = entry.coverage
            SetTextureCached(row.icon, entry.icon)
            SetTextCached(row.name, entry.awaitingTalents
                and ("Awaiting talents - " .. entry.name) or entry.name)
            SetTextCached(row.initial,
                entry.isPaladin and WhoDoesWhat:NameInitial(entry.name) or "")
            row.isPaladin = entry.isPaladin
            row.isPaladinRow = entry.paladinRow
            row.paladinName = entry.paladinName
            row.roleIcon = entry.paladinName and entry.icon or nil
            row.buffKey = entry.buffKey
            row.optionsKey = entry.buffKey
                or (entry.paladinRow and "paladinBuffs" or nil)
            row.flagged = entry.flagged
            row.flaggedAreMissing = coverage.flaggedAreMissing
            row.unavailableClass = entry.unavailableClass
            row.missing = entry.missing
            row.awaitingTalents = entry.awaitingTalents
            row.colorPreview = entry.colorPreview
            row.negative = entry.negative
            -- Nothing worth announcing about a debuff, nor about a bar that
            -- has already filled -- "everyone has it" is what the green bar
            -- and its tick are already saying.
            row.canAnnounce = not entry.negative and coverage.total > 0
                and coverage.correct < coverage.total
            row.saturatedStyle = entry.saturatedStyle or "check"
            row.correct = coverage.correct
            row.anyCorrect = coverage.anyCorrect
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
            -- The background colour is a constant and CreateRow already set it.
            SetRowOffsetCached(row, CONTENT_TOP + (displayIndex - 1) * ROW_H)
            row:Show()
            LayoutProgressLabel(row)
            -- Started after Show so a freshly pooled row's glow animation
            -- begins on a visible frame.
            SetRowGlow(row, entry.glow and not entry.colorPreview)
            -- Rebuild in place so a tooltip left open while buffs land keeps
            -- showing the live list rather than the state it opened on.
            if GameTooltip:IsShown() and GameTooltip:GetOwner() == row then
                ShowRowTooltip(row)
            end
        end
    end
    for i = normalIndex + 1, #view.rows do
        SetRowGlow(view.rows[i], false)
        view.rows[i]:Hide()
    end

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
