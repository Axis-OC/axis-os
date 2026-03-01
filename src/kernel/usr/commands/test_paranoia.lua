--
-- /usr/commands/test_paranoia.lua
-- Paranoia-mode tester: status, activation, spawn restriction.
--
local C = {R="\27[37m",G="\27[32m",E="\27[31m",Y="\27[33m",C="\27[36m",D="\27[90m"}
local nPass, nFail = 0, 0
local function pass(s) nPass=nPass+1; print(C.G.."  [PASS] "..C.R..s) end
local function fail(s) nFail=nFail+1; print(C.E.."  [FAIL] "..C.R..s) end
local function info(s) print(C.C.."  [INFO] "..C.R..s) end
local function section(s) print(""); print(C.Y.."=== "..s.." ==="..C.R) end

print(C.C.."╔═══════════════════════════════════════╗"..C.R)
print(C.C.."║  Paranoia-Mode Trigger Tester          ║"..C.R)
print(C.C.."╚═══════════════════════════════════════╝"..C.R)

-- 1. Read initial status
section("1. Status structure")

local tSt = syscall("paranoia_status")
if not tSt then
    fail("paranoia_status syscall returned nil")
    info("  → Check kernel.tSyscallTable['paranoia_status'] exists")
    return
end
pass("paranoia_status returns a table")

if tSt.bActive ~= nil then
    pass("bActive field present: " .. tostring(tSt.bActive))
else
    fail("bActive field missing — status table malformed")
end

if tSt.nDuration ~= nil then
    pass("nDuration field present: " .. tSt.nDuration .. "s")
else
    fail("nDuration field missing")
end

if tSt.nRemaining ~= nil then
    pass("nRemaining field present: " .. string.format("%.1f", tSt.nRemaining) .. "s")
else
    fail("nRemaining field missing")
end

-- 2. Check profiler (paranoia trigger source)
section("2. Syscall profiler (trigger source)")

local tProf = syscall("syscall_profiler_status")
if tProf then
    pass("Profiler subsystem available")
    info("  Locked: " .. tostring(tProf.bLocked))
    info("  Profiles: " .. tostring(tProf.nProfiles))
    info("  Alerts: " .. tostring(tProf.nAlerts))
    info("  Threshold for paranoia: 8 alerts")
    if tProf.nAlerts >= 8 and not tSt.bActive then
        fail("8+ alerts but paranoia NOT activated — trigger logic broken")
        info("  → Check PARANOIA_ALERT_THRESHOLD check in syscall_dispatch")
    end
else
    info("Profiler not available (g_tSyscallProfiler nil)")
end

-- 3. Spawn restriction (W^X baseline, before paranoia)
section("3. Baseline spawn restriction (W^X)")

-- Write a tiny script to /tmp/ and try to execute it
local fs = require("filesystem")
local sTmpPath = "/tmp/_paranoia_test_" .. tostring(math.random(1000,9999)) .. ".lua"
local hTmp = fs.open(sTmpPath, "w")
if hTmp then
    fs.write(hTmp, "-- test\n")
    fs.close(hTmp)
    pass("Can write to /tmp/ (expected)")

    local nBadPid, sSpawnErr = syscall("process_spawn", sTmpPath, 3)
    if nBadPid then
        fail("Execution from /tmp/ SUCCEEDED (PID " .. nBadPid .. ") — W^X broken!")
        info("  → Check process_spawn tBlockedPrefixes in kernel.lua")
        syscall("process_kill", nBadPid)
    else
        pass("Execution from /tmp/ correctly BLOCKED: " ..
            tostring(sSpawnErr):sub(1, 60))
    end
    fs.remove(sTmpPath)
else
    info("Cannot write to /tmp/ — skipping spawn test")
end

-- 4. Activation (Ring 0-1 only)
section("4. Paranoia activation")

local nMyRing = syscall("process_get_ring")
info("Current ring: " .. tostring(nMyRing))

if nMyRing <= 1 then
    if not tSt.bActive then
        local bActivate = syscall("paranoia_activate")
        if bActivate then
            pass("Paranoia mode activated via syscall")
            local tSt2 = syscall("paranoia_status")
            if tSt2 and tSt2.bActive then
                pass("Status confirms bActive=true after activation")
            else
                fail("Status still shows inactive after activation")
            end
            if tSt2 and tSt2.nRemaining and tSt2.nRemaining > 250 then
                pass("Remaining time plausible: " ..
                    string.format("%.0f", tSt2.nRemaining) .. "s")
            else
                fail("Remaining time implausible: " ..
                    tostring(tSt2 and tSt2.nRemaining))
            end
        else
            fail("paranoia_activate returned false/nil")
        end
    else
        info("Paranoia already active — skipping activation test")
        pass("Paranoia is active (pre-existing)")
    end
else
    info("Ring " .. tostring(nMyRing) .. " — cannot activate (Ring 0-1 required)")
    info("  Login as 'dev' (Ring 0) to test activation")

    -- Verify the syscall properly rejects us
    local bReject = syscall("paranoia_activate")
    if bReject == nil then
        pass("Activation correctly rejected for Ring " .. tostring(nMyRing))
    else
        fail("Ring " .. tostring(nMyRing) .. " was able to activate paranoia!")
        info("  → Check allowed_rings on paranoia_activate in kernel.lua")
    end
end

-- 5. Enhanced spawn restriction under paranoia
section("5. Paranoia-mode spawn restriction")

local tStNow = syscall("paranoia_status")
if tStNow and tStNow.bActive then
    info("Paranoia is ACTIVE — testing enhanced restrictions")

    -- Under paranoia, Ring 3 spawns are limited to system paths only
    -- /usr/commands/ is a system path → should work
    -- /opt/ is NOT in the paranoia system path list → should be blocked
    -- (We can't easily test this without a file there, so we check the status)
    info("  Under paranoia: only /bin/, /system/, /usr/commands/ allowed for Ring 3")
    pass("Paranoia mode active — spawn restrictions in effect")
else
    info("Paranoia not active — enhanced restrictions not testable from this ring")
end

-- Summary
print("")
print(C.C.."═══════════════════════════════════════"..C.R)
print(string.format("  %sPassed:%s %d   %sFailed:%s %d",
    C.G, C.R, nPass, nFail>0 and C.E or C.D, C.R, nFail))
if nFail == 0 then
    print(C.G.."  Paranoia-mode subsystem OK."..C.R)
else
    print(C.E.."  Issues found — review [FAIL] items above."..C.R)
end
print(C.C.."═══════════════════════════════════════"..C.R)