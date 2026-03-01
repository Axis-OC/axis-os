--
-- /usr/commands/test_seccomp.lua
-- SECCOMP filter tester — verifies install, block, intersect, minimum set.
--
local C = {R="\27[37m",G="\27[32m",E="\27[31m",Y="\27[33m",C="\27[36m",D="\27[90m"}
local nPass, nFail = 0, 0
local function pass(s) nPass=nPass+1; print(C.G.."  [PASS] "..C.R..s) end
local function fail(s) nFail=nFail+1; print(C.E.."  [FAIL] "..C.R..s) end
local function info(s) print(C.C.."  [INFO] "..C.R..s) end
local function section(s) print(""); print(C.Y.."=== "..s.." ==="..C.R) end

print(C.C.."╔═════════════════════════════════════╗"..C.R)
print(C.C.."║  SECCOMP Filter Tester               ║"..C.R)
print(C.C.."╚═════════════════════════════════════╝"..C.R)

-- 1. Pre-filter: verify syscalls work
section("1. Pre-filter baseline")

local nPid = syscall("process_get_pid")
if nPid and nPid > 0 then
    pass("process_get_pid works: PID " .. nPid)
else
    fail("process_get_pid failed (kernel.syscall_dispatch broken)")
end

local tMemBefore = syscall("mem_info")
if tMemBefore and tMemBefore.nTotal then
    pass("mem_info works before filter")
else
    fail("mem_info failed before filter")
end

local tDmesgBefore = syscall("dmesg_stats")
if tDmesgBefore and tDmesgBefore.nTotal ~= nil then
    pass("dmesg_stats works before filter")
else
    fail("dmesg_stats failed before filter")
end

-- 2. Install a restrictive filter
section("2. Install seccomp filter")

local tAllowed = {
    "process_get_pid",
    "process_yield",
    "kernel_yield",
    "seccomp_set_filter",
    "mem_info",           -- deliberately allowed
    -- dmesg_stats is NOT in the list → should be blocked
    -- patchguard_status is NOT in the list → should be blocked
}

local bInstall = syscall("seccomp_set_filter", tAllowed)
if bInstall then
    pass("Filter installed with " .. #tAllowed .. " syscalls")
else
    fail("seccomp_set_filter returned nil (check kernel.tSyscallTable entry)")
end

-- 3. Verify allowed syscalls still work
section("3. Allowed syscalls")

local nPid2 = syscall("process_get_pid")
if nPid2 == nPid then
    pass("process_get_pid still works (minimal set)")
else
    fail("process_get_pid broken after filter install")
end

local tMemAfter = syscall("mem_info")
if tMemAfter and tMemAfter.nTotal then
    pass("mem_info still works (in whitelist)")
else
    fail("mem_info blocked despite being in whitelist — check seccomp intersection logic")
end

local bYield = syscall("process_yield")
if bYield then
    pass("process_yield works (always-allowed)")
else
    fail("process_yield blocked — minimal set not enforced")
end

-- 4. Verify BLOCKED syscalls are rejected
section("4. Blocked syscalls")

local tDmesgBlocked = syscall("dmesg_stats")
if tDmesgBlocked == nil then
    pass("dmesg_stats correctly BLOCKED by seccomp")
else
    fail("dmesg_stats NOT blocked — seccomp check in syscall_dispatch not executing")
end

local tPgBlocked = syscall("patchguard_status")
if tPgBlocked == nil then
    pass("patchguard_status correctly BLOCKED")
else
    fail("patchguard_status NOT blocked — seccomp filter lookup broken")
end

local tSchedBlocked = syscall("sched_get_stats")
if tSchedBlocked == nil then
    pass("sched_get_stats correctly BLOCKED")
else
    fail("sched_get_stats NOT blocked")
end

-- 5. Verify filter restriction (intersection)
section("5. Filter restriction (can only shrink)")

local tSmaller = {
    "process_get_pid",
    "process_yield",
    "kernel_yield",
    "seccomp_set_filter",
    -- mem_info removed from this new filter
}
local bRestrict = syscall("seccomp_set_filter", tSmaller)
if bRestrict then
    pass("Further restriction accepted")
else
    fail("seccomp_set_filter rejected restriction — intersection logic broken")
end

local tMemRestricted = syscall("mem_info")
if tMemRestricted == nil then
    pass("mem_info now BLOCKED after restriction (was allowed, now removed)")
else
    fail("mem_info still works after intersecting it out — intersection not applied")
end

-- 6. Verify minimal set survives all restrictions
section("6. Minimal set persistence")

local nPid3 = syscall("process_get_pid")
if nPid3 == nPid then
    pass("process_get_pid survives all restrictions (forced minimal set)")
else
    fail("Minimal set not enforced — check tNewFilter forced entries in seccomp_set_filter")
end

local bYield2 = syscall("process_yield")
if bYield2 then
    pass("process_yield survives all restrictions")
else
    fail("process_yield lost after restriction")
end

-- Summary
print("")
print(C.C.."═════════════════════════════════════"..C.R)
print(string.format("  %sPassed:%s %d   %sFailed:%s %d",
    C.G, C.R, nPass, nFail>0 and C.E or C.D, C.R, nFail))
if nFail == 0 then
    print(C.G.."  SECCOMP filter working correctly."..C.R)
else
    print(C.E.."  Check: kernel.lua → seccomp_set_filter, syscall_dispatch seccomp block"..C.R)
end
print(C.C.."═════════════════════════════════════"..C.R)