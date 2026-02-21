--
-- /usr/commands/preempt_test.lua
-- AxisOS Preemptive Multitasking Verification Suite
--
-- Proves that the scheduler provides time-sliced preemption
--
-- Five tests:
--   1. Starvation prevention  — two tight busy loops, NO manual yields
--   2. Three-way fairness     — three identical hog threads
--   3. Main-thread liveness   — CPU hog vs. responsive main loop
--   4. Parallel wall-clock    — 3×0.5 s tasks sequential vs. parallel
--   5. Scheduler statistics   — confirms __pc() preemptions occurred
--
-- Usage:
--   preempt_test              Run full suite
--   preempt_test -v           Verbose (per-iteration detail)
--   preempt_test -h           Help
--

local thread   = require("thread")
local computer = require("computer")
local tArgs    = env.ARGS or {}

-- =============================================
-- ANSI PALETTE
-- =============================================
local C = {
    R   = "\27[37m",  CYN = "\27[36m",  GRN = "\27[32m",
    YLW = "\27[33m",  RED = "\27[31m",   GRY = "\27[90m",
    MAG = "\27[35m",  BLU = "\27[34m",
}

-- =============================================
-- FLAGS
-- =============================================
local bVerbose = false
for _, a in ipairs(tArgs) do
    if a == "-v" or a == "--verbose" then bVerbose = true end
    if a == "-h" or a == "--help" then
        print(C.CYN .. "preempt_test" .. C.R ..
              " — Preemptive multitasking verification suite")
        print("")
        print("  preempt_test        Run all 5 tests")
        print("  preempt_test -v     Verbose output")
        print("  preempt_test -h     This help")
        print("")
        print("Tests:")
        print("  1  Starvation prevention (two busy loops, no yields)")
        print("  2  Three-way CPU fairness")
        print("  3  Main-thread responsiveness under hog load")
        print("  4  Parallel speedup (wall-clock bounded tasks)")
        print("  5  Scheduler statistics delta")
        return
    end
end

-- =============================================
-- RESULT TRACKING
-- =============================================
local nPass, nFail, nWarn = 0, 0, 0

local function pass(s) nPass = nPass + 1; print(C.GRN .. "  [PASS] " .. C.R .. s) end
local function fail(s) nFail = nFail + 1; print(C.RED .. "  [FAIL] " .. C.R .. s) end
local function warn(s) nWarn = nWarn + 1; print(C.YLW .. "  [WARN] " .. C.R .. s) end
local function info(s) print(C.BLU .. "  [INFO] " .. C.R .. s) end
local function verb(s)
    if bVerbose then print(C.GRY .. "  [VERB] " .. s .. C.R) end
end

local function banner(sTitle)
    print("")
    print(C.CYN .. "  " .. string.rep("=", 56) .. C.R)
    print(C.CYN .. "  " .. sTitle .. C.R)
    print(C.CYN .. "  " .. string.rep("=", 56) .. C.R)
end

-- =============================================
-- HELPERS
-- =============================================

-- Wall-clock yield-sleep  (does NOT busy-burn — yields to scheduler)
local function sleep(nSec)
    local nDeadline = computer.uptime() + nSec
    while computer.uptime() < nDeadline do
        syscall("process_yield")
    end
end

-- Wall-clock busy-burn  (DOES consume CPU — used to measure throughput)
local function busyWork(nSeconds)
    local nDeadline = computer.uptime() + nSeconds
    local nCount = 0
    while computer.uptime() < nDeadline do
        nCount = nCount + 1
    end
    return nCount
end

-- =============================================
-- HEADER
-- =============================================

print("")
print(C.CYN .. "  ╔════════════════════════════════════════════════════╗" .. C.R)
print(C.CYN .. "  ║   AxisOS Preemptive Multitasking Test Suite       ║" .. C.R)
print(C.CYN .. "  ║   Method: source instrumentation (__pc)           ║" .. C.R)
print(C.CYN .. "  ║   NO debug.sethook                                ║" .. C.R)
print(C.CYN .. "  ╚════════════════════════════════════════════════════╝" .. C.R)

local nSuiteStart = computer.uptime()

-- =============================================
-- BASELINE SCHEDULER STATS
-- =============================================

local tStatsBefore = syscall("sched_get_stats") or {}
verb("Baseline preemptions: " .. tostring(tStatsBefore.nPreemptions or 0))
verb("Baseline resumes:     " .. tostring(tStatsBefore.nTotalResumes or 0))

-- =============================================================
-- TEST 1 — STARVATION PREVENTION
--
-- Two threads run tight busy loops with NO manual yield calls.
-- In a cooperative-only system thread A would monopolise the
-- CPU and thread B would never execute (or OC would crash the
-- machine with "too long without yielding").
-- With preemption, __pc() yields them both and both counters
-- advance.
-- =============================================================

banner("TEST 1: STARVATION PREVENTION")
info("Two threads with tight busy loops — ZERO manual yields.")
info("Without preemption: one thread starves (or OC crashes).")
info("With preemption:    both threads increment their counters.")
info("Running for 2 seconds...")
print("")

do
    local nCountA = 0
    local nCountB = 0
    local bStop   = false

    local tA = thread.create(function()
        while not bStop do
            nCountA = nCountA + 1
        end
    end)

    local tB = thread.create(function()
        while not bStop do
            nCountB = nCountB + 1
        end
    end)

    sleep(2)
    bStop = true

    if tA then tA:join() end
    if tB then tB:join() end

    verb(string.format("Thread A counted to %d", nCountA))
    verb(string.format("Thread B counted to %d", nCountB))

    if nCountA > 0 and nCountB > 0 then
        pass(string.format(
            "Both threads ran!  A = %d   B = %d", nCountA, nCountB))

        local nHi = math.max(nCountA, nCountB)
        local nLo = math.max(1, math.min(nCountA, nCountB))
        local nRatio = nHi / nLo

        if nRatio < 5 then
            pass(string.format("Fairness ratio %.1f:1  (< 5:1 — good)", nRatio))
        else
            warn(string.format(
                "Fairness ratio %.1f:1  (high, but neither thread starved)", nRatio))
        end
    elseif nCountA > 0 and nCountB == 0 then
        fail("Thread B STARVED (count = 0).  Preemption is NOT working!")
    elseif nCountB > 0 and nCountA == 0 then
        fail("Thread A STARVED (count = 0).  Preemption is NOT working!")
    else
        fail("Both threads stuck at 0.  Something is seriously wrong.")
    end
end

-- =============================================================
-- TEST 2 — THREE-WAY FAIRNESS
--
-- Three identical busy-loop threads.  We check that all three
-- make progress and that the fastest isn't more than ~10x the
-- slowest (a single core can't be perfectly fair but 10:1 is
-- generous).
-- =============================================================

banner("TEST 2: THREE-WAY FAIRNESS")
info("Three identical busy-loop threads competing for one CPU.")
info("Running for 2 seconds...")
print("")

do
    local tCounts = {0, 0, 0}
    local bStop   = false

    local tThreads = {}
    for i = 1, 3 do
        local nIdx = i                       -- capture loop variable
        tThreads[i] = thread.create(function()
            while not bStop do
                tCounts[nIdx] = tCounts[nIdx] + 1
            end
        end)
    end

    sleep(2)
    bStop = true

    for _, t in ipairs(tThreads) do
        if t then t:join() end
    end

    local nMin, nMax, nTotal = math.huge, 0, 0
    local nAlive = 0
    for i = 1, 3 do
        verb(string.format("  Thread %d:  %d iterations", i, tCounts[i]))
        if tCounts[i] > 0 then nAlive = nAlive + 1 end
        if tCounts[i] < nMin then nMin = tCounts[i] end
        if tCounts[i] > nMax then nMax = tCounts[i] end
        nTotal = nTotal + tCounts[i]
    end

    if nAlive == 3 then
        pass(string.format("All 3 threads ran  (total %d iterations)", nTotal))
        local nRatio = nMax / math.max(1, nMin)
        info(string.format("Min = %d   Max = %d   Ratio = %.1f:1",
                           nMin, nMax, nRatio))
        if nRatio < 3 then
            pass("Excellent fairness  (< 3:1)")
        elseif nRatio < 10 then
            pass("Acceptable fairness (< 10:1)")
        else
            warn(string.format(
                "Uneven distribution (%.1f:1) — but all three ran", nRatio))
        end
    else
        fail(nAlive .. "/3 threads ran.  Starvation detected!")
    end
end

-- =============================================================
-- TEST 3 — MAIN-THREAD RESPONSIVENESS
--
-- Spawn a CPU-hog thread and verify the main thread can still
-- execute code (read the clock, increment a counter, yield)
-- while the hog is running.
-- =============================================================

banner("TEST 3: MAIN-THREAD RESPONSIVENESS")
info("Starting a CPU hog, then checking if the main thread")
info("can still execute code alongside it.")
info("Running for 2 seconds...")
print("")

do
    local nHogCount   = 0
    local bStop       = false
    local nMainChecks = 0
    local nStartTime  = computer.uptime()

    local tHog = thread.create(function()
        while not bStop do
            nHogCount = nHogCount + 1
        end
    end)

    local nDeadline = computer.uptime() + 2

    -- Main thread: yield-sleep in a loop, counting how many
    -- times we regain control.  In a cooperative system with
    -- a tight hog, we'd get 0 or 1 check.
    while computer.uptime() < nDeadline do
        nMainChecks = nMainChecks + 1
        local nElapsed = computer.uptime() - nStartTime
        verb(string.format(
            "  Main check #%d  at %.2fs   (hog = %d)",
            nMainChecks, nElapsed, nHogCount))
        syscall("process_yield")
    end

    bStop = true
    if tHog then tHog:join() end

    local nElapsed = computer.uptime() - nStartTime
    info(string.format("Main thread executed %d checks in %.2fs",
                       nMainChecks, nElapsed))
    info(string.format("Hog thread counted to %d", nHogCount))

    if nMainChecks >= 10 then
        pass("Main thread highly responsive  (" ..
             nMainChecks .. " checks)")
    elseif nMainChecks >= 3 then
        pass("Main thread responsive  (" .. nMainChecks .. " checks)")
    elseif nMainChecks >= 1 then
        warn("Main thread sluggish  (" .. nMainChecks .. " checks)")
    else
        fail("Main thread got ZERO checks — hog monopolised CPU!")
    end

    if nHogCount > 0 then
        pass("Hog thread also made progress  (" ..
             nHogCount .. " iterations)")
    else
        warn("Hog thread didn't count at all  (scheduling anomaly)")
    end
end

-- =============================================================
-- TEST 4 — PARALLEL WALL-CLOCK SPEEDUP
--
-- Sequential:  run 3 × busyWork(0.5 s)  one after another.
-- Parallel:    run 3 × busyWork(0.5 s)  as threads.
--
-- busyWork counts iterations until a wall-clock deadline.
-- Since the wall clock advances for ALL threads even when they
-- are preempted out, parallel threads all finish at roughly
-- the same wall-clock moment.
--
-- Expected:
--   Sequential  ≈ 1.5 s
--   Parallel    ≈ 0.5 s   →  ~3× speedup
--
-- This speedup is ONLY possible with preemption; without it
-- each thread would run to completion one at a time and the
-- parallel time would also be ≈ 1.5 s.
-- =============================================================

banner("TEST 4: PARALLEL WALL-CLOCK SPEEDUP")
info("Sequential: 3 tasks × 0.5 s each → expect ~1.5 s")
info("Parallel:   3 tasks × 0.5 s each → expect ~0.5 s (preemptive)")
print("")

do
    -- ---- Sequential ----
    local nSeqStart = computer.uptime()
    local nSeqTotal = 0
    for i = 1, 3 do
        nSeqTotal = nSeqTotal + busyWork(0.5)
    end
    local nSeqTime = computer.uptime() - nSeqStart

    -- ---- Parallel ----
    local tParCounts = {0, 0, 0}
    local nParStart  = computer.uptime()

    local tParThreads = {}
    for i = 1, 3 do
        local nIdx = i
        tParThreads[i] = thread.create(function()
            tParCounts[nIdx] = busyWork(0.5)
        end)
    end
    for _, t in ipairs(tParThreads) do
        if t then t:join() end
    end

    local nParTime  = computer.uptime() - nParStart
    local nParTotal = 0
    for i = 1, 3 do nParTotal = nParTotal + tParCounts[i] end

    -- ---- Results ----
    info(string.format("Sequential : %.2f s   (%d iterations total)",
                       nSeqTime, nSeqTotal))
    info(string.format("Parallel   : %.2f s   (%d iterations total)",
                       nParTime, nParTotal))

    verb(string.format("  Thread 1: %d", tParCounts[1]))
    verb(string.format("  Thread 2: %d", tParCounts[2]))
    verb(string.format("  Thread 3: %d", tParCounts[3]))

    local nSpeedup = nSeqTime / math.max(0.001, nParTime)
    info(string.format("Speedup    : %.2f×", nSpeedup))

    if nSpeedup >= 2.0 then
        pass(string.format(
            "%.1f× speedup — threads ran concurrently!  Preemption confirmed.",
            nSpeedup))
    elseif nSpeedup >= 1.3 then
        pass(string.format(
            "%.1f× speedup — measurable concurrency benefit",
            nSpeedup))
    elseif nSpeedup >= 1.05 then
        warn(string.format(
            "Marginal speedup (%.2f×) — preemption present but high overhead",
            nSpeedup))
    else
        fail(string.format(
            "No speedup (%.2f×) — threads appear serialised",
            nSpeedup))
    end

    -- Extra check: in purely sequential execution the parallel
    -- time would be >= sequential time.  Any significant reduction
    -- proves interleaved execution.
    if nParTime < nSeqTime * 0.7 then
        pass(string.format(
            "Parallel time (%.2fs) is < 70%% of sequential (%.2fs)",
            nParTime, nSeqTime))
    end
end

-- =============================================================
-- TEST 5 — SCHEDULER STATISTICS
--
-- Query the kernel's scheduler counters and verify that
-- preemptive yields (__pc-driven) actually occurred during
-- the tests above.
-- =============================================================

banner("TEST 5: SCHEDULER STATISTICS")
print("")

do
    local tStatsAfter = syscall("sched_get_stats") or {}

    local nPreemptDelta = (tStatsAfter.nPreemptions    or 0)
                        - (tStatsBefore.nPreemptions    or 0)
    local nResumeDelta  = (tStatsAfter.nTotalResumes   or 0)
                        - (tStatsBefore.nTotalResumes   or 0)
    local nWdWarnings   = tStatsAfter.nWatchdogWarnings or 0
    local nWdKills      = tStatsAfter.nWatchdogKills    or 0
    local nMaxSlice     = tStatsAfter.nMaxSliceMs       or 0

    info(string.format("Scheduler resumes during test : %d", nResumeDelta))
    info(string.format("Preemptive yields (__pc)      : %d", nPreemptDelta))
    info(string.format("Watchdog warnings             : %d", nWdWarnings))
    info(string.format("Watchdog kills                : %d", nWdKills))
    info(string.format("Max single slice              : %.2f ms", nMaxSlice))

    if tStatsAfter.nInstrumentedFiles then
        print("")
        info(string.format("Source files instrumented      : %d",
             tStatsAfter.nInstrumentedFiles))
        info(string.format("__pc() checkpoints injected    : %d",
             tStatsAfter.nInjectedCheckpoints or 0))
        info(string.format("Quantum setting                : %d ms",
             tStatsAfter.nQuantumMs or 50))
        info(string.format("Check interval                 : %d calls",
             tStatsAfter.nCheckInterval or 256))
    end

    -- ---- Verdicts ----
    print("")

    if nPreemptDelta > 100 then
        pass(string.format(
            "%d preemptive yields — heavy time-slicing confirmed!", nPreemptDelta))
    elseif nPreemptDelta > 0 then
        pass(string.format(
            "%d preemptive yields — scheduler IS preempting.", nPreemptDelta))
    else
        fail("Zero preemptive yields detected.  Scheduler is cooperative-only!")
    end

    if nResumeDelta > 50 then
        pass(string.format(
            "%d total resumes — scheduler actively multiplexing", nResumeDelta))
    end

    if nWdKills == 0 then
        pass("No watchdog kills — all processes yielded within limits")
    else
        warn(nWdKills .. " process(es) killed by watchdog")
    end

    if nMaxSlice < 200 then
        pass(string.format(
            "Max slice %.1f ms — well within OC's 5 s hard limit", nMaxSlice))
    elseif nMaxSlice < 2000 then
        warn(string.format("Max slice %.1f ms — a bit high", nMaxSlice))
    else
        fail(string.format(
            "Max slice %.1f ms — dangerously close to OC timeout!", nMaxSlice))
    end

    -- Per-process CPU stats for our own PID
    local nMyPid = syscall("process_get_pid")
    local tMyCpu = syscall("process_cpu_stats", nMyPid)
    if tMyCpu and bVerbose then
        print("")
        verb(string.format("Our PID:           %d", nMyPid))
        verb(string.format("Our CPU time:      %.3f s", tMyCpu.nCpuTime or 0))
        verb(string.format("Our preempt count: %d", tMyCpu.nPreemptCount or 0))
        verb(string.format("Our max slice:     %.2f ms",
             (tMyCpu.nMaxSlice or 0) * 1000))
        verb(string.format("Our watchdog hits: %d", tMyCpu.nWatchdogStrikes or 0))
    end
end

-- =============================================================
-- SUMMARY
-- =============================================================

local nSuiteTime = computer.uptime() - nSuiteStart

banner("SUMMARY")
print("")
print(string.format("  %sPassed :%s  %d",   C.GRN, C.R, nPass))
print(string.format("  %sFailed :%s  %d",   C.RED, C.R, nFail))
print(string.format("  %sWarned :%s  %d",   C.YLW, C.R, nWarn))
print(string.format("  %sTime   :%s  %.2f s", C.GRY, C.R, nSuiteTime))
print("")

if nFail == 0 then
    print(C.GRN .. "  ╔══════════════════════════════════════════════════╗" .. C.R)
    print(C.GRN .. "  ║                                                  ║" .. C.R)
    print(C.GRN .. "  ║   PREEMPTIVE MULTITASKING: VERIFIED              ║" .. C.R)
    print(C.GRN .. "  ║                                                  ║" .. C.R)
    print(C.GRN .. "  ║   Method : source-code instrumentation (__pc)    ║" .. C.R)
    print(C.GRN .. "  ║   Safety : server-safe, no debug library abuse   ║" .. C.R)
    print(C.GRN .. "  ║                                                  ║" .. C.R)
    print(C.GRN .. "  ╚══════════════════════════════════════════════════╝" .. C.R)
elseif nFail <= 2 then
    print(C.YLW .. "  ╔══════════════════════════════════════════════════╗" .. C.R)
    print(C.YLW .. "  ║   PREEMPTIVE MULTITASKING: PARTIAL               ║" .. C.R)
    print(C.YLW .. "  ║   Some tests failed — review output above.       ║" .. C.R)
    print(C.YLW .. "  ╚══════════════════════════════════════════════════╝" .. C.R)
else
    print(C.RED .. "  ╔══════════════════════════════════════════════════╗" .. C.R)
    print(C.RED .. "  ║   PREEMPTIVE MULTITASKING: NOT WORKING           ║" .. C.R)
    print(C.RED .. "  ║   Multiple failures — check kernel/preempt.lua   ║" .. C.R)
    print(C.RED .. "  ╚══════════════════════════════════════════════════╝" .. C.R)
end

print("")