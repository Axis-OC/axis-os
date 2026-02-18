--
-- /usr/commands/sched.lua
-- AxisOS Preemptive Scheduler Diagnostics
--
-- Usage:
--   sched              Show global scheduler stats
--   sched -p           Include per-process CPU stats
--   sched -v           Verbose (include instrumentation info)
--

local tArgs = env.ARGS or {}

local C = {
    R = "\27[37m", CYN = "\27[36m", GRN = "\27[32m",
    YLW = "\27[33m", RED = "\27[31m", GRY = "\27[90m",
}

local bProcs   = false
local bVerbose = false
for _, a in ipairs(tArgs) do
    if a == "-p" or a == "--procs"   then bProcs   = true end
    if a == "-v" or a == "--verbose" then bVerbose = true end
    if a == "-h" or a == "--help" then
        print(C.CYN .. "sched" .. C.R .. " — Preemptive scheduler diagnostics")
        print("  sched            Global stats")
        print("  sched -p         Per-process CPU stats")
        print("  sched -v         Include instrumentation info")
        return
    end
end

local tStats = syscall("sched_get_stats")
if not tStats then
    print("sched: could not retrieve scheduler stats")
    return
end

print(C.CYN .. "AxisOS Preemptive Scheduler" .. C.R)
print(C.GRY .. string.rep("-", 50) .. C.R)

print(string.format("  Total resumes:        %s%d%s",
    C.GRN, tStats.nTotalResumes or 0, C.R))
print(string.format("  Preemptive yields:    %s%d%s",
    C.YLW, tStats.nPreemptions or 0, C.R))
print(string.format("  Watchdog warnings:    %s%d%s",
    (tStats.nWatchdogWarnings or 0) > 0 and C.RED or C.GRN,
    tStats.nWatchdogWarnings or 0, C.R))
print(string.format("  Watchdog kills:       %s%d%s",
    (tStats.nWatchdogKills or 0) > 0 and C.RED or C.GRN,
    tStats.nWatchdogKills or 0, C.R))
print(string.format("  Max single slice:     %s%.2f ms%s",
    C.YLW, tStats.nMaxSliceMs or 0, C.R))

if bVerbose and tStats.nInstrumentedFiles then
    print("")
    print(C.CYN .. "Instrumentation" .. C.R)
    print(string.format("  Files instrumented:   %d", tStats.nInstrumentedFiles))
    print(string.format("  Checkpoints injected: %d", tStats.nInjectedCheckpoints or 0))
    print(string.format("  Quantum:              %d ms", tStats.nQuantumMs or 50))
    print(string.format("  Check interval:       %d calls", tStats.nCheckInterval or 256))
end

if bProcs then
    print("")
    print(C.CYN .. "Per-Process CPU Statistics" .. C.R)
    print(string.format("  %s%-5s %-8s %-8s %-10s %-8s %-4s  %s%s",
        C.GRY, "PID", "CPU(s)", "Preempt", "Last(ms)", "Max(ms)", "WD", "IMAGE", C.R))
    print("  " .. C.GRY .. string.rep("-", 65) .. C.R)

    local tProcs = syscall("process_list")
    if tProcs then
        for _, p in ipairs(tProcs) do
            local tCpu = syscall("process_cpu_stats", p.pid)
            if tCpu then
                local sWdColor = tCpu.nWatchdogStrikes > 0 and C.RED or C.GRN
                print(string.format(
                    "  %-5d %-8.3f %-8d %-10.2f %-8.2f %s%-4d%s  %s",
                    p.pid,
                    tCpu.nCpuTime or 0,
                    tCpu.nPreemptCount or 0,
                    (tCpu.nLastSlice or 0) * 1000,
                    (tCpu.nMaxSlice or 0) * 1000,
                    sWdColor, tCpu.nWatchdogStrikes or 0, C.R,
                    p.image or "?"))
            end
        end
    end
end

print("")
print(C.GRY .. "Usage: sched [-p] [-v]  |  sched -h for help" .. C.R)