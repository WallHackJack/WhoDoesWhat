local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Developer timing for the addon's hot paths. Off by default and effectively
-- free while off: every entry point returns on a single upvalue read before
-- touching a table or the clock.
--
-- Two questions this answers, and they need different readouts:
--
--   * "what froze the client" -- one call that took too long. Caught live by
--     the spike warning, which prints the section and the duration the moment
--     it crosses THRESHOLD.
--   * "what is eating the frame budget" -- a section that is individually fast
--     but runs thousands of times a second. A spike warning NEVER catches this
--     (no single call is slow), so the summary tracks count and calls/sec
--     alongside the timings. The UNIT_HEALTH handler in a 40-man is exactly
--     this shape.
--
-- Timings are INCLUSIVE: a nested section's time is also counted in its
-- parent, so the totals deliberately sum past 100%.
--
-- debugprofilestop() is the client's millisecond-resolution profiling clock.
-- GetTime() is frozen for the whole frame and time() has 1-second resolution,
-- so neither can measure any of this.

local Profiling = {}
WhoDoesWhat.Profiling = Profiling

-- Mirrored out of the DB into an upvalue: this is read on every instrumented
-- call, and a settings-table walk per read is exactly the overhead a profiler
-- must not add.
local enabled = false

local THRESHOLD = 5    -- ms; a single call slower than this warns in chat
local WARN_COOLDOWN = 3 -- seconds between warnings for the SAME section

-- name -> { count, total, max, lastWarn }
local stats = {}
-- name -> debugprofilestop() at the OUTERMOST Begin, and name -> how deep we
-- are inside it. Depth matters because the wrapped view refreshes call each
-- other: without it a re-entered section would restart its own clock and
-- report only the innermost slice.
local starts, depth = {}, {}
-- name -> the frame its outermost Begin happened on, so a dangling Begin can
-- be told apart from real nesting. See Begin.
local frameOf = {}
local since = 0

local function Reset()
    wipe(stats)
    wipe(starts)
    wipe(depth)
    wipe(frameOf)
    since = GetTime()
end

function Profiling.Begin(name)
    if not enabled then return end
    local now = GetTime()
    local d = depth[name]
    if d and frameOf[name] == now then
        -- Genuine nesting, within one frame: keep the outermost clock running.
        depth[name] = d + 1
        return
    end
    -- Either the first entry, or a depth left over from a Begin whose End was
    -- skipped by an early return. Nothing here legitimately spans a frame, so
    -- a leftover from an earlier frame is discarded rather than nested into --
    -- otherwise one missed End would wedge the section's depth above zero and
    -- silently stop it recording for the rest of the session.
    depth[name] = 1
    frameOf[name] = now
    starts[name] = debugprofilestop()
end

function Profiling.End(name)
    if not enabled then return end
    local d = depth[name]
    -- No matching Begin: profiling was switched on mid-call. Skip rather than
    -- record a bogus duration.
    if not d then return end
    d = d - 1
    depth[name] = d > 0 and d or nil
    if d > 0 then return end

    local t0 = starts[name]
    if not t0 then return end
    starts[name] = nil

    local elapsed = debugprofilestop() - t0
    local s = stats[name]
    if not s then
        s = { count = 0, total = 0, max = 0, lastWarn = 0 }
        stats[name] = s
    end
    s.count = s.count + 1
    s.total = s.total + elapsed
    if elapsed > s.max then s.max = elapsed end

    if elapsed >= THRESHOLD then
        local now = GetTime()
        -- Rate-limited per section: a bad frame can spike several sections at
        -- once, and 40 lines of chat is not a diagnostic.
        if now - s.lastWarn >= WARN_COOLDOWN then
            s.lastWarn = now
            WhoDoesWhat:Print(string.format(
                "|cffff6060SPIKE|r %s took |cffffd000%.1f ms|r", name, elapsed))
        end
    end
end

function Profiling.IsEnabled()
    return enabled
end

-- ---------------------------------------------------------------------------
-- Wrapping
-- ---------------------------------------------------------------------------

-- Time an existing function in place, by name, so the hot paths that are
-- already public entry points need no edits in their own files. Wrapping is
-- permanent (there is no unwrap); when profiling is off the added cost is one
-- call through to the original.
--
-- Return values pass through untouched, via a tail call rather than
-- table.pack -- the client is Lua 5.1, which has no table.pack/unpack pair
-- that round-trips embedded nils.
local function Finish(name, ...)
    Profiling.End(name)
    return ...
end

function Profiling.Wrap(tbl, key, name)
    local original = tbl and tbl[key]
    if type(original) ~= "function" then
        -- A renamed or not-yet-defined function should not take the addon
        -- down over a developer tool; say so and move on.
        WhoDoesWhat:Print("|cffff6060Profiling:|r nothing to wrap for " .. name)
        return
    end
    tbl[key] = function(...)
        Profiling.Begin(name)
        return Finish(name, original(...))
    end
end

function Profiling.SetEnabled(value)
    enabled = value and true or false
    if WhoDoesWhat.db then
        WhoDoesWhat.db.profile.settings.profilePerformance = enabled
    end
    Reset()
end

-- Called from OnInitialize once the DB exists, so the toggle survives a
-- reload. Absent key reads nil, which is the correct default (off).
function Profiling.LoadSetting()
    enabled = WhoDoesWhat.db.profile.settings.profilePerformance and true or false
    if enabled then Reset() end
end

-- Slowest-first by total time spent, which is the ranking that answers "what
-- should I fix next" -- a section can dominate through either one slow call or
-- a great many fast ones, and total is the only column that sees both.
function Profiling.Report()
    if not enabled then
        WhoDoesWhat:Print("Profiling is off. |cff80c0ff/wdw perf on|r to start.")
        return
    end
    local rows = {}
    for name, s in pairs(stats) do rows[#rows + 1] = { name = name, s = s } end
    if #rows == 0 then
        WhoDoesWhat:Print("Profiling is on, but nothing instrumented has run yet.")
        return
    end
    table.sort(rows, function(a, b) return a.s.total > b.s.total end)

    local window = math.max(GetTime() - since, 0.001)
    WhoDoesWhat:Print(string.format(
        "|cff80c0ffPerformance|r over %.0fs -- section: total (share of elapsed), calls (/s), avg, max",
        window))
    for _, row in ipairs(rows) do
        local s = row.s
        WhoDoesWhat:Print(string.format(
            "  %s: |cffffd000%.0f ms|r (%.1f%%), %d (%.0f/s), avg %.2f ms, max |cffffd000%.2f ms|r",
            row.name, s.total, s.total / (window * 1000) * 100,
            s.count, s.count / window, s.total / s.count, s.max))
    end
    WhoDoesWhat:Print("|cff909090/wdw perf reset|r to clear these counters.")
end

-- Instrument every public entry point worth timing. Runs once from
-- OnInitialize, after every file has loaded and defined its functions.
--
-- Sections are named "<layer>.<thing>" so the report groups them by eye:
-- view.* is the repaint layer (all of it no-ops with its window closed),
-- bufftracking.* and sync.* keep running regardless, and plan.*/pallypower.*
-- are the model.
--
-- Inclusive timing means the nesting shows up as double counting on purpose:
-- view.grid contains view.statusbars, view.pallybar, view.tooltip and
-- view.ppdiff, because RefreshBuffingGridView calls all four.
function Profiling.InstrumentAll()
    local W = WhoDoesWhat
    local Wrap = Profiling.Wrap

    -- Repaint layer.
    Wrap(W, "RefreshMainAssignmentsView", "view.main")
    Wrap(W, "RefreshBuffingGridView", "view.grid")
    Wrap(W, "RefreshStatusBarsView", "view.statusbars")
    Wrap(W, "RefreshPaladinBuffingBar", "view.pallybar")
    Wrap(W, "RefreshActionItemsView", "view.actionitems")
    Wrap(W, "RefreshRaiderRolesView", "view.raiderroles")
    Wrap(W, "RefreshPallyPowerDiffView", "view.ppdiff")
    Wrap(W, "RefreshRaiderTooltip", "view.tooltip")

    -- Model work the status views drive on every repaint.
    local A = W.Assign
    Wrap(A, "ComputePaladinBuffCoverage", "plan.coverage")
    Wrap(A, "ComputeCoreRaidBuffCoverage", "plan.corecoverage")
    Wrap(A, "ComputePaladinBuffSummary", "plan.summary")
    Wrap(A, "GetPaladinBuffJobs", "plan.jobs")

    -- The PallyPower-sourced plan. Unlike ComputePaladinBuffPlan this has no
    -- cache of any kind -- it rebuilds from the PallyPower tables on every
    -- call -- so for anyone running pallyBuffSource="pallypower" this is on
    -- the same hot path the WDW plan's cache protects.
    Wrap(W, "GetPallyPowerBuffPlan", "pallypower.plan")

    -- Talent scanning: the per-inspect handler and the roster-wide sweep that
    -- GROUP_ROSTER_UPDATE schedules.
    Wrap(W, "OnTalentsReady", "talents.ready")
    Wrap(W, "SyncRosterTalents", "talents.sweep")

    -- Sync: the 2s local-change poll and every inbound addon message.
    local Sync = W.GetModule and W:GetModule("Sync", true)
    if Sync then
        Wrap(Sync, "PollLocalChanges", "sync.poll")
        Wrap(Sync, "OnCommReceived", "sync.recv")
    end
end

function Profiling.HandleCommand(arg)
    if arg == "on" then
        Profiling.SetEnabled(true)
        WhoDoesWhat:Print("Profiling |cff40ff40on|r. Spikes over "
            .. THRESHOLD .. " ms print here; |cff80c0ff/wdw perf|r for the summary.")
    elseif arg == "off" then
        Profiling.SetEnabled(false)
        WhoDoesWhat:Print("Profiling |cffff6060off|r.")
    elseif arg == "reset" then
        Reset()
        WhoDoesWhat:Print("Profiling counters cleared.")
    else
        Profiling.Report()
    end
end
