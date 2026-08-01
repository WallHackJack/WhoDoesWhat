local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- /wdw           - toggle the main window
-- /wdw r         - toggle the buffing grid
-- /wdw sync      - manual resync: leaders push their board, everyone else
--                  pulls the leader's (same flow as joining the group)
-- /wdw ppsync    - push the computed buff grid into PallyPower and broadcast
--                  it over PallyPower's own sync (PallyPowerBridge.lua)
-- /wdw log       - toggle the WhoDoesWhat sync traffic log
-- /wdw pplog     - toggle the PallyPower traffic log window
-- /wdw ppdifftest - open the PallyPower diff grids with view-only dummy data
function WhoDoesWhat:ToggleMainUI(input)
    input = input and input:trim():lower() or ""
    if input == "r" then
        self:OpenBuffingGridView()
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
