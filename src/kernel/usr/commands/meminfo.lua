--
-- /usr/commands/meminfo.lua
-- Per-process memory diagnostics
--
-- Usage:
--   meminfo          Overview
--   meminfo -p       Per-process details
--   meminfo -v       Verbose (include module list)
--

local tArgs = env.ARGS or {}
local C = {
    R="\27[37m", RED="\27[31m", GRN="\27[32m", YLW="\27[33m",
    CYN="\27[36m", GRY="\27[90m", MAG="\27[35m",
}

local bProcs   = false
local bVerbose = false
for _, a in ipairs(tArgs) do
    if a == "-p" then bProcs = true end
    if a == "-v" then bProcs = true; bVerbose = true end
    if a == "-h" then
        print(C.CYN .. "meminfo" .. C.R .. " — Memory diagnostics")
        print("  meminfo      Overview")
        print("  meminfo -p   Per-process details")
        print("  meminfo -v   Verbose")
        return
    end
end

local tInfo = syscall("mem_info")
if not tInfo then print("meminfo: unavailable"); return end

local function fmtKB(n)
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    return string.format("%.1f KB", n / 1024)
end

local function bar(nPct, nWidth)
    nWidth = nWidth or 30
    local nFill = math.floor(nPct / 100 * nWidth)
    local sC = C.GRN
    if nPct > 80 then sC = C.RED
    elseif nPct > 60 then sC = C.YLW end
    return sC .. string.rep("█", nFill) .. C.GRY ..
           string.rep("░", nWidth - nFill) .. C.R
end

print(C.CYN .. "AxisOS Memory Information" .. C.R)
print(C.GRY .. string.rep("-", 50) .. C.R)
print("")
print(string.format("  Total:     %s%s%s", C.CYN, fmtKB(tInfo.nTotal), C.R))
print(string.format("  Used:      %s%s%s (%d%%)",
    tInfo.nUsedPct > 80 and C.RED or C.GRN,
    fmtKB(tInfo.nUsed), C.R, tInfo.nUsedPct))
print(string.format("  Free:      %s%s%s",
    tInfo.nFree < 32768 and C.RED or C.GRN,
    fmtKB(tInfo.nFree), C.R))
print("")
print("  " .. bar(tInfo.nUsedPct) ..
    string.format(" %d%%", tInfo.nUsedPct))
print("")

print(C.CYN .. "  Kernel Overhead" .. C.R)
print(string.format("    Processes:      %d", tInfo.nProcesses))
print(string.format("    Global modules: %d", tInfo.nGlobalModules))
print(string.format("    dmesg entries:  %d", tInfo.nDmesgEntries))
print(string.format("    Boot log queue: %d", tInfo.nBootLogPending))

if tInfo.nFree < 32768 then
    print("")
    print(C.RED .. "  ⚠  LOW MEMORY — OOM killer may activate" .. C.R)
end

if bProcs then
    print("")
    print(C.CYN .. "  Per-Process Details" .. C.R)
    print(string.format("  %s%-5s %-4s %-8s %-4s %-4s %-3s %-3s %8s%s",
        C.GRY, "PID", "RING", "STATUS", "MODS", "HNDL", "SIG", "THR", "CPU", C.R))
    print("  " .. C.GRY .. string.rep("-", 50) .. C.R)

    for _, p in ipairs(tInfo.tProcesses) do
        local sRC = C.GRN
        if p.ring <= 1 then sRC = C.RED
        elseif p.ring <= 2 then sRC = C.YLW end

        print(string.format("  %-5d %s%-4s%s %-8s %-4d %-4d %-3d %-3d %7.2fs",
            p.pid, sRC, tostring(p.ring), C.R,
            p.status, p.modules, p.handles,
            p.signals, p.threads, p.cpu))
    end
end

-- GC suggestion
if tInfo.nUsedPct > 70 then
    print("")
    print(C.YLW .. "  Tip: Dead processes may hold unreleased memory." .. C.R)
    print(C.YLW .. "  The kernel GC runs on OOM (< 32KB free)." .. C.R)
end