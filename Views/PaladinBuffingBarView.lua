local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- The Paladin Buffing Bar: a movable Nova-style strip of one button per CLASS
-- the local paladin is assigned to buff (WhoDoesWhat.Assign.GetPaladinBuffJobs),
-- each showing the class icon and a coloured "buffed/total" count. Left-click
-- casts the class's Greater Blessing on a class member (buffs the whole class);
-- right-click cycles that class's individual Normal-blessing exceptions -- see
-- the secure-casting section below.
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

local INSET = 3        -- backdrop edge inset
local PAD = 3          -- inner padding around the button row
local TITLE_H = 12     -- title strip height
local BTN_SIZE = 28
local BTN_GAP = 3
local COUNT_H = 10     -- room under a button for its count text

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

-- Resolve the test selection against the current roster. A departed paladin
-- clears the saved override so test mode falls back to the first paladin.
function WhoDoesWhat:GetBuffingBarTestPaladin()
    local paladins = self:GetBuffingBarPaladins()
    local settings = self.db.profile.settings
    local saved = settings.buffingBarTestPaladin
    if saved then
        for _, name in ipairs(paladins) do
            if name == saved then return saved end
        end
        settings.buffingBarTestPaladin = nil
    end
    return paladins[1]
end

-- The paladin whose jobs the bar should show, or nil when it shouldn't show at
-- all: master toggle off, or the local player isn't a paladin and test mode is
-- off.
local function ResolveBarPaladin()
    local s = WhoDoesWhat.db.profile.settings
    -- Dev test mode is an independent override: render as the picked paladin
    -- even if the master toggle is off and the local player isn't a paladin.
    if s.buffingBarTestMode then
        return WhoDoesWhat:GetBuffingBarTestPaladin()
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

-- The unit token to target for a member: a pet's own unit, else the raider's
-- resolved group unit. Both work as [@unit] in a cast macro and for range.
local function CastUnit(member, nameToUnit)
    if member.isPet then return member.petUnit end
    return nameToUnit[member.name]
end

-- Does this class job have at least one still-missing member in range -- i.e.
-- is there anything to cast right now? Drives both the glow and the range-grey.
local function JobIsReady(job, nameToUnit)
    for _, r in ipairs(job.raiders) do
        if r.has ~= true then
            local meta = WhoDoesWhat.PaladinBuffs[r.key]
            if TargetInRange(CastUnit(r, nameToUnit), meta and meta.spellId) then
                return true
            end
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

-- Status mark + colour for a live buff state (true/false/nil).
local function StatusMark(has)
    if has == true then return "|cff40ff40+|r ", 0.8, 0.8, 0.8 end
    if has == false then return "|cffff6060x|r ", 1, 0.5, 0.5 end
    return "|cff909090?|r ", 0.6, 0.6, 0.6
end

local function BuildTooltip(self)
    local job = self.job
    if not job then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    local title = job.classInfo.name
    if job.hasPets and not job.hasNonPets then
        title = "Hunter Pets"
    elseif job.hasPets then
        title = title .. " + Pets"
    end
    GameTooltip:SetText("|cff" .. job.classInfo.colorHex .. title .. "|r", 1, 1, 1)
    local r, g, b = CountColor(job.covered, job.total)
    GameTooltip:AddLine(job.covered .. " / " .. job.total .. " buffed", r, g, b)
    if job.greaterBuff then
        GameTooltip:AddLine("Left-click: Greater Blessing of "
            .. job.greaterBuff.name_long .. " (whole class)", 0.4, 0.7, 1, true)
    end
    if #job.normals > 0 then
        GameTooltip:AddLine("Right-click: cycle individual blessings", 0.4, 0.7, 1, true)
        GameTooltip:AddLine(" ")
        for _, nrm in ipairs(job.normals) do
            local mark, cr, cg, cb = StatusMark(WhoDoesWhat:HasBuff(nrm.name, nrm.key))
            GameTooltip:AddLine(mark .. nrm.name .. "  |cff808080("
                .. nrm.buff.name_long .. ")|r", cr, cg, cb)
        end
    end
    GameTooltip:Show()
end

-- Pooled button #index; RefreshBar fills .job and positions it. Secure so it
-- can cast blessings on click: the SecureHandler template supplies Execute /
-- WrapScript (ConfigureButtonCast), SecureActionButtonTemplate the macro cast.
local function CreateButton(index)
    local btn = CreateFrame("Button", "WhoDoesWhatBuffingBarButton" .. index, bar,
        "SecureHandlerStateTemplate, SecureActionButtonTemplate")
    -- Secure action buttons obey ActionButtonUseKeyDown. Register both so the
    -- cast works with either client setting (PallyPower does the same).
    btn:RegisterForClicks("AnyUp", "AnyDown")
    btn:SetSize(BTN_SIZE, BTN_SIZE)

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 0.9)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- trim the default icon border
    btn.icon = icon

    -- Small hunter-pet badge tucked into the bottom-right corner (inside the
    -- button), shown when a class button also carries pets (Warrior + pets). A
    -- 1px black frame matches the main icon's border; same icon-trim TexCoord.
    local petBadge = CreateFrame("Frame", nil, btn)
    petBadge:SetSize(BTN_SIZE * 0.44, BTN_SIZE * 0.44)
    petBadge:SetPoint("BOTTOMRIGHT", -1, 1)
    local badgeBorder = petBadge:CreateTexture(nil, "OVERLAY", nil, 1)
    badgeBorder:SetPoint("TOPLEFT", -1, 1)
    badgeBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    badgeBorder:SetColorTexture(0, 0, 0, 0.9)
    local badgeIcon = petBadge:CreateTexture(nil, "OVERLAY", nil, 2)
    badgeIcon:SetAllPoints()
    badgeIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    badgeIcon:SetTexture(WhoDoesWhat.HunterPetRole and WhoDoesWhat.HunterPetRole.icon)
    petBadge:Hide()
    btn.petBadge = petBadge

    local count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    count:SetPoint("TOP", btn, "BOTTOM", 0, -1)
    btn.count = count

    btn:SetScript("OnEnter", BuildTooltip)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btn:SetScript("PostClick", function(self, mouseButton)
        if not WhoDoesWhat.db.profile.settings.logBuffingBarClicks then return end
        local job = self.job
        if not job then
            WhoDoesWhat:Print("Buffing bar click: " .. tostring(mouseButton)
                .. " (no job configured).")
            return
        end

        local action, choices
        if mouseButton == "LeftButton" then
            action = job.greaterBuff
                and ("Greater Blessing of " .. job.greaterBuff.name_long)
                or "no Greater Blessing"
            choices = self.gCastCount or 0
        elseif mouseButton == "RightButton" then
            action = "individual blessing"
            choices = self.nCastCount or 0
        else
            action = "unmapped input"
            choices = 0
        end

        local test = WhoDoesWhat.db.profile.settings.buffingBarTestMode
            and " [test mode]" or ""
        WhoDoesWhat:Print("Buffing bar click: " .. tostring(mouseButton) .. " -> "
            .. job.classInfo.name .. " " .. action .. " (" .. choices
            .. " castable target" .. (choices == 1 and "" or "s") .. ")." .. test)
    end)

    bar.buttons[index] = btn
    return btn
end

-- ---------------------------------------------------------------------------
-- Secure casting (rotate through targets) -- PallyPower's proven pattern
-- ---------------------------------------------------------------------------

-- The wrapped OnClick runs in the button's restricted environment. Left-click
-- casts the class Greater (gSpell) on the next class member (gNames); right
-- click cycles the individual Normal exceptions (nNames/nSpells). Each side
-- rotates its own step and points its macrotext at a live friendly target
-- before the matching macro fires. Set up out of combat; rotation works during
-- combat off the baked-in lists.
local ROTATE_SNIPPET = [==[
    if button == "LeftButton" then
        local n = table.maxn(gNames)
        if n > 0 and gSpell ~= "" then
            local step = self:GetAttribute("gstep") or 1
            if step > n then step = 1 end
            local name = gNames[step]
            if name and SecureCmdOptionParse("[@" .. name .. ",help,nodead]") then
                self:SetAttribute("macrotext1", "/cast [@" .. name .. ",help,nodead] " .. gSpell)
            end
            self:SetAttribute("gstep", step + 1)
        end
    elseif button == "RightButton" then
        local n = table.maxn(nNames)
        if n > 0 then
            local step = self:GetAttribute("nstep") or 1
            if step > n then step = 1 end
            local name = nNames[step]
            local spell = nSpells[step]
            if name and spell and SecureCmdOptionParse("[@" .. name .. ",help,nodead]") then
                self:SetAttribute("macrotext2", "/cast [@" .. name .. ",help,nodead] " .. spell)
            end
            self:SetAttribute("nstep", step + 1)
        end
    end
]==]

-- newtable(...) from a list of strings ("" -> empty), inside [=[ ]=] so spaces
-- and realm suffixes survive.
local function NewTable(list)
    if #list == 0 then return "newtable()" end
    return "newtable([=[" .. table.concat(list, "]=],[=[") .. "]=])"
end

-- Bake a button's two cast rotations from its class job. Secure attribute writes
-- are combat-locked, so this no-ops in combat and re-runs on the next
-- out-of-combat refresh (roster/aura changes and PLAYER_REGEN_ENABLED).
-- Fake/unresolved names are skipped -- nothing castable there. Rank-less spell
-- names cast the highest rank the paladin knows.
local function ConfigureButtonCast(btn, job, nameToUnit)
    if InCombatLockdown() then return end
    local gSpell = (job.greaterBuff and GetSpellInfo(job.greaterBuff.spellId)) or ""

    -- Left: any resolvable class member is a valid Greater target (non-pets
    -- come first, so a warrior is preferred over a pet when both are present).
    local gNames = {}
    for _, m in ipairs(job.raiders) do
        local unit = CastUnit(m, nameToUnit)
        if unit then gNames[#gNames + 1] = unit end
    end
    -- Right: the individual Normal exceptions and their (rank-less) spells.
    local nNames, nSpells = {}, {}
    for _, nrm in ipairs(job.normals) do
        local unit = CastUnit(nrm, nameToUnit)
        local greater = GetSpellInfo(nrm.buff.spellId)
        local normal = greater and (greater:gsub("^Greater ", ""))
        if unit and normal then
            nNames[#nNames + 1] = unit
            nSpells[#nSpells + 1] = normal
        end
    end
    btn.gCastCount = #gNames
    btn.nCastCount = #nNames

    btn:SetAttribute("type1", "macro")
    btn:SetAttribute("type2", "macro")
    btn:Execute("gSpell = [=[" .. gSpell .. "]=]\n"
        .. "gNames = " .. NewTable(gNames) .. "\n"
        .. "nNames = " .. NewTable(nNames) .. "\n"
        .. "nSpells = " .. NewTable(nSpells) .. "\n")
    if not btn.castWrapped then
        btn:SetAttribute("gstep", 1)
        btn:SetAttribute("nstep", 1)
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
    -- Drop classes with no real raiders to buff (read 0/0) -- nothing to show.
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
        -- Pets-only (no warriors) shows the pet icon; a mixed class shows its
        -- class icon with a small pet badge.
        if job.hasPets and not job.hasNonPets and WhoDoesWhat.HunterPetRole then
            btn.icon:SetTexture(WhoDoesWhat.HunterPetRole.icon)
        else
            btn.icon:SetTexture(job.classInfo.classIcon)
        end
        btn.petBadge:SetShown(job.hasPets and job.hasNonPets)
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
            or "No Paladin selected for testing.")
        bar:SetSize(200, CONTENT_TOP + 18 + INSET)
    else
        bar:SetSize(INSET * 2 + PAD * 2 + n * BTN_SIZE + (n - 1) * BTN_GAP,
            CONTENT_TOP + BTN_SIZE + COUNT_H + INSET)
    end
end

-- Show or hide the whole bar based on the master/test toggles, then repaint.
-- Test mode stays visible without a paladin so roster updates can fill it in.
function WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
    local paladin = ResolveBarPaladin()
    if not paladin and not self.db.profile.settings.buffingBarTestMode then
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

-- Bring the bar up immediately on login/reload if it was left enabled, then
-- repaint once more after the roster and synced plan have had time to arrive.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function()
    WhoDoesWhat:UpdatePaladinBuffingBarVisibility()
    C_Timer.After(2, function() WhoDoesWhat:UpdatePaladinBuffingBarVisibility() end)
end)
