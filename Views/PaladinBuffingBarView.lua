local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- The Paladin Buffing Bar: a movable Nova-style strip of one button per
-- blessing the local paladin is assigned to cast (WhoDoesWhat.Assign.
-- GetPaladinBuffJobs), each showing the blessing icon and a coloured
-- "covered/total" count. Left-clicking a button casts the blessing on the next
-- assigned target that needs it, rotating through them (Greater per class,
-- Normal per exception) -- see the secure-casting section below.
--
-- Whose jobs it renders (ResolveBarPaladin): normally the local player when
-- they're a paladin; in test mode, the paladin picked in the settings dropdown
-- (real or fake), so you can preview the bar as any raid paladin.
--
-- Styled like the other WDW windows (dark backdrop, tooltip border, a "WDW
-- Buffs" title strip). Moved by Alt-dragging; grows left or right per the
-- settings option; a pulsing red frame alerts when any assigned raider is
-- missing a blessing.

local bar = nil

local INSET = 4        -- backdrop edge inset
local PAD = 4          -- inner padding around the button row
local TITLE_H = 14     -- title strip height
local BTN_SIZE = 36
local BTN_GAP = 4
local COUNT_H = 12     -- room under a button for its count text

-- y from the bar's top down to where the button row begins.
local CONTENT_TOP = INSET + TITLE_H + 2

-- ---------------------------------------------------------------------------
-- Which paladin to render
-- ---------------------------------------------------------------------------

-- Stable key for the local player, matching the plan's raider keys.
local function LocalPlayerKey()
    local name, realm = UnitName("player")
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- Strict list of paladin names in the group (real + fake), for the settings
-- dropdown and the test-mode fallback.
function WhoDoesWhat:GetBuffingBarPaladins()
    return self.Assign.MembersOfClass("Paladin")
end

-- The paladin whose jobs the bar should show, or nil when it shouldn't show at
-- all: master toggle off, or the local player isn't a paladin and test mode is
-- off.
local function ResolveBarPaladin()
    local s = WhoDoesWhat.db.profile.settings
    -- Dev test mode is an independent override: render as the picked paladin
    -- even if the master toggle is off and the local player isn't a paladin.
    if s.buffingBarTestMode then
        if s.buffingBarTestPaladin then return s.buffingBarTestPaladin end
        return WhoDoesWhat:GetBuffingBarPaladins()[1]
    end
    if not s.buffingBarEnabled then return nil end
    local _, class = UnitClass("player")
    if class == "PALADIN" then return LocalPlayerKey() end
    return nil
end

-- ---------------------------------------------------------------------------
-- Position (Alt-drag) + growth direction
-- ---------------------------------------------------------------------------

-- Save the current on-screen rect, anchoring by the edge the bar grows away
-- from: left edge for RIGHT growth, right edge for LEFT growth, so adding
-- buttons never shifts the anchored side.
local function SavePosition()
    if not bar then return end
    local grow = WhoDoesWhat.db.profile.settings.buffingBarGrow or "RIGHT"
    local point = (grow == "LEFT") and "TOPRIGHT" or "TOPLEFT"
    local x = (grow == "LEFT") and bar:GetRight() or bar:GetLeft()
    local y = bar:GetTop()
    if not x or not y then return end
    WhoDoesWhat.db.profile.settings.buffingBarPos = { point = point, x = x, y = y }
end

local function LoadPosition()
    local p = WhoDoesWhat.db.profile.settings.buffingBarPos
    bar:ClearAllPoints()
    if p and p.x and p.y then
        bar:SetPoint(p.point or "TOPLEFT", UIParent, "BOTTOMLEFT", p.x, p.y)
    else
        bar:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
    end
end

-- Attach Alt-gated dragging to a mouse region that moves the whole bar.
local function AttachAltDrag(region)
    region:EnableMouse(true)
    region:RegisterForDrag("LeftButton")
    region:SetScript("OnDragStart", function()
        if IsAltKeyDown() then bar:StartMoving() end
    end)
    region:SetScript("OnDragStop", function()
        bar:StopMovingOrSizing()
        -- Save, then re-anchor to the growth corner so the next resize grows
        -- the chosen way (StartMoving may have left a different anchor).
        SavePosition()
        LoadPosition()
    end)
end

-- Re-anchor to the growth-appropriate edge without visually moving the bar,
-- then repaint. Called from the settings dropdown.
function WhoDoesWhat:SetBuffingBarGrow(mode)
    self.db.profile.settings.buffingBarGrow = mode
    if bar and bar:GetLeft() then
        SavePosition()
        LoadPosition()
    end
    self:RefreshPaladinBuffingBar()
end

-- ---------------------------------------------------------------------------
-- Range + "ready" glow (LibCustomGlow, same as NovaConsumesHelper)
-- ---------------------------------------------------------------------------

local LCG = LibStub("LibCustomGlow-1.0", true)

-- raider name -> group unit token, rebuilt each refresh (matches the plan's
-- Name / Name-Realm keys via GetUnitName's showServerName).
local function BuildNameToUnit()
    local map = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local u = "raid" .. i
            local nm = GetUnitName(u, true)
            if nm then map[nm] = u end
        end
    else
        local me = GetUnitName("player", true) or UnitName("player")
        if me then map[me] = "player" end
        for i = 1, GetNumSubgroupMembers() do
            local u = "party" .. i
            local nm = GetUnitName(u, true)
            if nm then map[nm] = u end
        end
    end
    return map
end

-- Is a target reachable for this blessing right now? A resolved unit is checked
-- by spell range (falling back to generic unit range); an unresolved name -- a
-- fake raider, or someone not in our group -- is assumed in range so the
-- preview still lights up.
local function TargetInRange(unit, spellId)
    if not unit then return true end
    if C_Spell and C_Spell.IsSpellInRange then
        local r = C_Spell.IsSpellInRange(spellId, unit)
        if r ~= nil then return r and true or false end
    end
    local inRange, checked = UnitInRange(unit)
    if checked then return inRange and true or false end
    return true
end

-- Does this job have at least one still-missing raider in range -- i.e. is
-- there anything to cast right now? Drives both the glow and the range-grey.
local function JobIsReady(job, nameToUnit)
    for _, r in ipairs(job.raiders) do
        if r.has ~= true and TargetInRange(nameToUnit[r.name], job.buff.spellId) then
            return true
        end
    end
    return false
end

-- Start/stop the Nova-style pixel-glow border on a button, tracking state so
-- the animation isn't restarted every refresh.
local function SetButtonGlow(btn, on)
    if not LCG then return end
    if on then
        if not btn.glowing then
            LCG.PixelGlow_Start(btn, nil, 16, nil, 3, nil, nil, nil, nil, nil, 4)
            btn.glowing = true
        end
    elseif btn.glowing then
        LCG.PixelGlow_Stop(btn)
        btn.glowing = false
    end
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

-- Colour for a covered/total count: green all, red none, yellow partial, gray
-- when there's nothing to cover.
local function CountColor(covered, total)
    if total == 0 then return 0.6, 0.6, 0.6 end
    if covered >= total then return 0.3, 1, 0.3 end
    if covered == 0 then return 1, 0.3, 0.3 end
    return 1, 0.82, 0.2
end

local function BuildTooltip(self)
    local job = self.job
    if not job then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Greater Blessing of " .. job.buff.name_long, 1, 1, 1)
    local r, g, b = CountColor(job.covered, job.total)
    GameTooltip:AddLine(job.covered .. " / " .. job.total .. " covered", r, g, b)
    GameTooltip:AddLine(" ")
    for _, cast in ipairs(job.casts) do
        local kind = cast.isGreater and "Greater" or "Normal"
        local who = cast.name
        if cast.isGreater and cast.classInfo then
            who = cast.classInfo.name .. "s (via " .. cast.name .. ")"
        end
        local mark, cr, cg, cb
        if cast.has == true then
            mark, cr, cg, cb = "|cff40ff40+|r ", 0.8, 0.8, 0.8
        elseif cast.has == false then
            mark, cr, cg, cb = "|cffff6060x|r ", 1, 0.5, 0.5
        else
            mark, cr, cg, cb = "|cff909090?|r ", 0.6, 0.6, 0.6
        end
        GameTooltip:AddLine(mark .. who .. "  |cff808080(" .. kind .. ")|r", cr, cg, cb)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-click: cast the next target that needs it.", 0.4, 0.7, 1, true)
    GameTooltip:Show()
end

-- Pooled button #index; RefreshBar fills .job and positions it. Secure so it
-- can cast blessings on click: the SecureHandler template supplies Execute /
-- WrapScript (ConfigureButtonCast), SecureActionButtonTemplate the macro cast.
local function CreateButton(index)
    local btn = CreateFrame("Button", "WhoDoesWhatBuffingBarButton" .. index, bar,
        "SecureHandlerStateTemplate, SecureActionButtonTemplate")
    btn:RegisterForClicks("AnyUp")
    btn:SetSize(BTN_SIZE, BTN_SIZE)

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 0.9)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- trim the default icon border
    btn.icon = icon

    local count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("TOP", btn, "BOTTOM", 0, -1)
    btn.count = count

    btn:SetScript("OnEnter", BuildTooltip)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    bar.buttons[index] = btn
    return btn
end

-- ---------------------------------------------------------------------------
-- Secure casting (rotate through targets) -- PallyPower's proven pattern
-- ---------------------------------------------------------------------------

-- The wrapped OnClick runs in the button's restricted environment. It reads the
-- baked-in target/spell lists, picks the current step's target (skipping to the
-- start when past the end), and -- if that target is a live friendly unit --
-- points macrotext1 at it before the macro fires, then advances the step. Set
-- up out of combat; the rotation itself works during combat.
local ROTATE_SNIPPET = [==[
    local step = self:GetAttribute("step1") or 1
    local n = table.maxn(unitNames)
    if n == 0 then return end
    if step > n then step = 1 end
    local name = unitNames[step]
    local spell = unitSpells[step]
    if name and spell and SecureCmdOptionParse("[@" .. name .. ",help,nodead]") then
        self:SetAttribute("macrotext1", "/cast [@" .. name .. ",help,nodead] " .. spell)
    end
    self:SetAttribute("step1", step + 1)
]==]

-- Build the restricted-env table assignments for a target/spell list. Names go
-- inside [=[ ]=] so spaces and realm suffixes survive.
local function BuildExecBody(names, spells)
    if #names == 0 then
        return "unitNames = newtable()\nunitSpells = newtable()\n"
    end
    return "unitNames = newtable([=[" .. table.concat(names, "]=],[=[") .. "]=])\n"
        .. "unitSpells = newtable([=[" .. table.concat(spells, "]=],[=[") .. "]=])\n"
end

-- Bake a button's cast rotation from its job's ordered casts. Secure attribute
-- writes are combat-locked, so this no-ops in combat and re-runs on the next
-- out-of-combat refresh (roster/aura changes and PLAYER_REGEN_ENABLED). Pets
-- and fake/unresolved names are skipped -- nothing castable there. Cast highest
-- known rank by using the rank-less spell name.
local function ConfigureButtonCast(btn, job, nameToUnit)
    if InCombatLockdown() then return end
    local greater = GetSpellInfo(job.buff.spellId)
    local normal = greater and (greater:gsub("^Greater ", ""))
    local names, spells = {}, {}
    for _, cast in ipairs(job.casts) do
        if not cast.isPet and nameToUnit[cast.name] then
            local spell = cast.isGreater and greater or normal
            if spell then
                names[#names + 1] = cast.name
                spells[#spells + 1] = spell
            end
        end
    end
    btn:SetAttribute("type1", "macro")
    btn:Execute(BuildExecBody(names, spells))
    if not btn.castWrapped then
        btn:SetAttribute("step1", 1)
        btn:WrapScript(btn, "OnClick", ROTATE_SNIPPET)
        btn.castWrapped = true
    end
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

local function EnsureBar()
    if bar then return bar end

    bar = CreateFrame("Frame", "WhoDoesWhatBuffingBar", UIParent, "BackdropTemplate")
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    -- Match the other WDW windows: dark fill, thin tooltip border.
    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = INSET, right = INSET, top = INSET, bottom = INSET },
    })
    bar:SetBackdropColor(0, 0, 0, 0.95)
    bar:SetBackdropBorderColor(0.4, 0.4, 0.4)
    AttachAltDrag(bar)

    -- Title strip ("WDW Buffs"), also a drag handle; hover explains Alt-drag.
    local title = CreateFrame("Frame", nil, bar)
    title:SetHeight(TITLE_H)
    title:SetPoint("TOPLEFT", INSET, -INSET)
    title:SetPoint("TOPRIGHT", -INSET, -INSET)
    local titleBg = title:CreateTexture(nil, "ARTWORK")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(0.12, 0.12, 0.15, 1)
    local titleText = title:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleText:SetPoint("LEFT", 5, 0)
    titleText:SetText("WDW Buffs")
    AttachAltDrag(title)
    title:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("WDW Buffs", 1, 1, 1)
        GameTooltip:AddLine("Alt-drag to move.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    title:SetScript("OnLeave", function() GameTooltip:Hide() end)
    bar.title = title

    -- Shown when the resolved paladin has no assigned blessings.
    local hint = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOP", 0, -CONTENT_TOP)
    hint:SetTextColor(0.6, 0.6, 0.6)
    bar.hint = hint

    bar.buttons = {}
    LoadPosition()

    -- Roster changes shift the plan; leaving combat lets us (re)bake the secure
    -- cast rotations we couldn't touch mid-fight. Repaint on both.
    bar:RegisterEvent("GROUP_ROSTER_UPDATE")
    bar:RegisterEvent("PLAYER_REGEN_ENABLED")
    bar:SetScript("OnEvent", function(self)
        if self:IsShown() then WhoDoesWhat:RefreshPaladinBuffingBar() end
    end)

    -- Range shifts as people (and you) move, which fires no events, so
    -- re-evaluate the grey/glow of the cached jobs on a light throttle. Coverage
    -- and the plan itself still only recompute on the refresh path.
    bar.rangeTick = 0
    bar:SetScript("OnUpdate", function(self, elapsed)
        self.rangeTick = self.rangeTick + elapsed
        if self.rangeTick < 0.5 or not self.lastJobs then return end
        self.rangeTick = 0
        local nameToUnit = BuildNameToUnit()
        for i, job in ipairs(self.lastJobs) do
            local btn = self.buttons[i]
            if btn and btn:IsShown() then
                local ready = JobIsReady(job, nameToUnit)
                btn.icon:SetDesaturated(not ready)
                SetButtonGlow(btn, ready)
            end
        end
    end)

    return bar
end

-- ---------------------------------------------------------------------------
-- Refresh + visibility
-- ---------------------------------------------------------------------------

-- Repaint the bar's buttons from the resolved paladin's jobs. Only touches the
-- widgets; visibility is handled by UpdatePaladinBuffingBarVisibility.
function WhoDoesWhat:RefreshPaladinBuffingBar()
    if not bar or not bar:IsShown() then return end
    local paladin = ResolveBarPaladin()
    local allJobs = paladin and self.Assign.GetPaladinBuffJobs(paladin) or {}
    -- Drop blessings with no real raiders to buff (e.g. pet-only jobs, which
    -- read 0/0) -- nothing to show or cast on the bar.
    local jobs = {}
    for _, job in ipairs(allJobs) do
        if job.total > 0 then jobs[#jobs + 1] = job end
    end
    bar.lastJobs = jobs
    local nameToUnit = BuildNameToUnit()

    for i, job in ipairs(jobs) do
        local btn = bar.buttons[i]
        if not btn then
            -- Secure buttons can't be created/registered in combat; they'll
            -- appear on the next out-of-combat refresh.
            if InCombatLockdown() then break end
            btn = CreateButton(i)
        end
        btn.job = job
        ConfigureButtonCast(btn, job, nameToUnit)
        btn.icon:SetTexture(job.buff.iconId)
        btn.count:SetText(job.covered .. "/" .. job.total)
        btn.count:SetTextColor(CountColor(job.covered, job.total))
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", bar, "TOPLEFT",
            INSET + PAD + (i - 1) * (BTN_SIZE + BTN_GAP), -CONTENT_TOP)
        btn:Show()
        -- Grey the icon when nothing's castable in range (all covered, or the
        -- missing raiders are out of range); glow it when a missing raider is
        -- reachable right now -- ready to buff.
        local ready = JobIsReady(job, nameToUnit)
        btn.icon:SetDesaturated(not ready)
        SetButtonGlow(btn, ready)
    end
    for i = #jobs + 1, #bar.buttons do
        SetButtonGlow(bar.buttons[i], false)
        bar.buttons[i]:Hide()
        bar.buttons[i].job = nil
    end

    local n = #jobs
    bar.hint:SetShown(n == 0)
    if n == 0 then
        bar.hint:SetText(paladin
            and (paladin .. " has no assigned blessings.")
            or "No paladin selected.")
        bar:SetSize(200, CONTENT_TOP + 18 + INSET)
    else
        bar:SetSize(INSET * 2 + PAD * 2 + n * BTN_SIZE + (n - 1) * BTN_GAP,
            CONTENT_TOP + BTN_SIZE + COUNT_H + INSET)
    end
end

-- Show or hide the whole bar based on the master toggle + who's resolved, then
-- repaint. Called from the settings checkboxes and on load.
function WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
    local paladin = ResolveBarPaladin()
    if not paladin then
        if bar then
            for _, b in ipairs(bar.buttons) do SetButtonGlow(b, false) end
            bar:Hide()
        end
        return
    end
    local f = EnsureBar()
    f:Show()
    self:RefreshPaladinBuffingBar()
end

-- Bring the bar up on login/reload if it was left enabled. Delayed so the
-- roster and plan are populated before the first resolve (same beat the sync
-- handshake waits for).
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function()
    C_Timer.After(2, function() WhoDoesWhat:UpdatePaladinBuffingBarVisibility() end)
end)
