local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")
local _, ns = ...

local DumpFrameTree
--@do-not-package@
-- /wdw fdump <GlobalFrameName> - developer tool: the frame's child/region tree
-- (type, shown, size, first anchor, text or texture) in a copy window, for
-- mapping Blizzard frames from the live client.
local function Describe(obj)
    if obj == nil then return "nil" end
    return (obj.GetDebugName and obj:GetDebugName()) or obj:GetName() or tostring(obj)
end

local function DumpObject(lines, obj, depth, maxDepth)
    local indent = string.rep("    ", depth)
    local w, h = obj:GetSize()
    local line = string.format("%s%s [%s] shown=%s %dx%d",
        indent, Describe(obj), obj:GetObjectType(), tostring(obj:IsShown()),
        floor((w or 0) + 0.5), floor((h or 0) + 0.5))
    if obj:GetNumPoints() > 0 then
        local p, rel, rp, x, y = obj:GetPoint(1)
        line = line .. string.format(" @%s->%s:%s(%d,%d)", tostring(p), Describe(rel),
            tostring(rp), floor((x or 0) + 0.5), floor((y or 0) + 0.5))
    end
    if obj.GetFrameLevel then
        line = line .. string.format(" strata=%s level=%d alpha=%.2f visible=%s",
            obj:GetFrameStrata(), obj:GetFrameLevel(), obj:GetEffectiveAlpha(),
            tostring(obj:IsVisible()))
    end
    if obj.GetText and obj:GetObjectType() ~= "Frame" then
        local ok, text = pcall(obj.GetText, obj)
        if ok and text and text ~= "" then line = line .. " text=\"" .. tostring(text) .. "\"" end
    end
    if obj.GetTexture then
        local ok, tex = pcall(obj.GetTexture, obj)
        if ok and tex then line = line .. " tex=" .. tostring(tex) end
    end
    lines[#lines + 1] = line
    if depth >= maxDepth or not obj.GetChildren then return end
    for _, r in ipairs({ obj:GetRegions() }) do DumpObject(lines, r, depth + 1, maxDepth) end
    for _, c in ipairs({ obj:GetChildren() }) do DumpObject(lines, c, depth + 1, maxDepth) end
end

DumpFrameTree = function(name)
    local frame = _G[name]
    if type(frame) ~= "table" or not frame.GetObjectType then
        WhoDoesWhat:Print("fdump: no frame named " .. tostring(name))
        return
    end
    local lines = {}
    DumpObject(lines, frame, 0, 4)
    ns.UI.ShowCopyText("WhoDoesWhatFrameDump", "Frame dump: " .. name, table.concat(lines, "\n"))
end
--@end-do-not-package@

-- /wdw           - toggle the main window
-- /wdw r         - toggle the buffing grid
-- /wdw rescan    - force an inspect of every buff provider in range. Rarely
--                  needed: targeting a player refreshes them on their own.
-- /wdw sync      - manual resync: leaders push their board, everyone else
--                  pulls the leader's (same flow as joining the group)
-- /wdw ppsync    - push the computed buff grid into PallyPower and broadcast
--                  it over PallyPower's own sync (PallyPowerBridge.lua)
-- /wdw log       - toggle the WhoDoesWhat sync traffic log
-- /wdw pplog     - toggle the PallyPower traffic log window
-- /wdw ppdifftest - open the PallyPower diff grids with view-only dummy data
-- /wdw perf [on|off|reset] - developer timing for the addon's hot paths
--                  (Profiling.lua). Bare "perf" prints the summary.
function WhoDoesWhat:ToggleMainUI(input)
    local frameName = input and input:match("^%s*fdump%s+(%S+)")
    if frameName and DumpFrameTree then
        DumpFrameTree(frameName)
        return
    end
    input = input and input:trim():lower() or ""
    local perfArg = input:match("^perf%s*(%a*)$")
    if perfArg then
        self.Profiling.HandleCommand(perfArg)
        return
    end
    if input == "r" then
        self:OpenBuffingGridView()
        return
    end
    if input == "rescan" then
        self:RescanBuffingTalents()
        return
    end
    if input == "sync" then
        self:GetModule("Sync"):ForceSync()
        return
    end
    if input == "ppsync" then
        self:SyncToPallyPower()
        return
    end
    if input == "log" then
        self:OpenSyncLogView("wdw")
        return
    end
    if input == "pplog" then
        self:OpenPallyPowerLogView()
        return
    end
    if input == "ppdifftest" then
        self:OpenPallyPowerDiffTestView()
        return
    end
    -- This calls the view function inside MainAssignmentsView.lua
    self:LogUiBuilding("Toggle Main UI called")
    self:OpenMainAssignmentsView()
end
