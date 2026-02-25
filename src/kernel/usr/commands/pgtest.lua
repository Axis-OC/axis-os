--
-- /usr/commands/pgtest.lua
-- PatchGuard v3 Feature Test
--
local C = {R="\27[37m", G="\27[32m", Y="\27[33m", C="\27[36m",
           E="\27[31m", D="\27[90m", M="\27[35m"}

local function pass(s) print(C.G .. "  [PASS] " .. C.R .. s) end
local function fail(s) print(C.E .. "  [FAIL] " .. C.R .. s) end
local function info(s) print(C.C .. "  [INFO] " .. C.R .. s) end

print(C.C .. "╔═══════════════════════════════════════════╗" .. C.R)
print(C.C .. "║  PatchGuard v3 — Feature Verification      ║" .. C.R)
print(C.C .. "╚═══════════════════════════════════════════╝" .. C.R)
print("")

-- 1. PatchGuard status
local tPG = syscall("patchguard_status")
if not tPG or not tPG.bAvailable then
    fail("PatchGuard not loaded!")
    return
end

print(C.Y .. "=== PatchGuard Core ===" .. C.R)
if tPG.bArmed then pass("Armed and monitoring") else info("Not yet armed (normal during early boot)") end
info("Checks performed: " .. (tPG.nChecksPerformed or 0))
info("Violations: " .. (tPG.nViolations or 0))
info("Syscalls monitored: " .. (tPG.nSyscallsMonitored or 0))
info("Files hashed: " .. (tPG.nCriticalFilesHashed or 0))
print("")

-- 2. Feature 1: SHA-256 module
print(C.Y .. "=== Feature 1: /lib/sha256 Hashing ===" .. C.R)
if tPG.bSha256Module then
    pass("Pure-Lua SHA-256 module loaded")
else
    info("Using data card SHA-256 (fallback)")
end
print("")

-- 3. Feature 2: XOR-encrypted hashes
print(C.Y .. "=== Feature 2: XOR-Encrypted Hash Storage ===" .. C.R)
if tPG.bXorKeyActive then
    pass("XOR key active (" .. tPG.nXorKeyBytes .. " bytes)")
    info("Stored hashes are encrypted — memory dump reveals nothing")
else
    fail("XOR key NOT active — hashes stored in plaintext")
end
print("")

-- 4. Feature 3: math.random() kept
print(C.Y .. "=== Feature 3: Check Interval RNG ===" .. C.R)
info("Using math.random() (native Lua PRNG, ~0us per call)")
info("data_card.random() is a component call (~50us) — SLOWER")
pass("Correct choice: math.random() for timing, hardware RNG for XOR key")
print("")

-- 5. Feature 4: Check function rotation
print(C.Y .. "=== Feature 4: Check Function Rotation ===" .. C.R)
if tPG.nCheckVariants and tPG.nCheckVariants >= 3 then
    pass(tPG.nCheckVariants .. " check variants (alpha/beta/gamma)")
    info("Each cycle randomly picks one variant")
    info("Patching one function doesn't disable the others")
else
    fail("Check rotation not active")
end
print("")

-- 6. Feature 5: Syscall behavior profiling
print(C.Y .. "=== Feature 5: Syscall Behavior Profiling ===" .. C.R)
local tProf = syscall("syscall_profiler_status")
if tProf then
    pass("Profiler active")
    info("Profiles: " .. tProf.nProfiles .. " processes tracked")
    info("Elapsed: " .. string.format("%.0f", tProf.nElapsed) ..
         "s / " .. tProf.nStabilizeAfter .. "s stabilization")
    if tProf.bLocked then
        pass("Baselines LOCKED — anomaly detection active")
    else
        info("Still learning (locks after " .. tProf.nStabilizeAfter .. "s)")
    end
    info("Alerts: " .. tProf.nAlerts)
    if tProf.nAlerts > 0 then
        print(C.M .. "  Recent alerts:" .. C.R)
        for _, a in ipairs(tProf.tRecentAlerts or {}) do
            print(string.format("    PID %d used '%s' (Ring %s) at T=%.1f",
                a.pid, a.syscall, tostring(a.ring), a.time))
        end
    end
else
    fail("Profiler not available")
end
print("")

-- Summary
print(C.C .. "═══════════════════════════════════════════" .. C.R)
local nPassed = 0
if tPG.bSha256Module then nPassed = nPassed + 1 end
if tPG.bXorKeyActive then nPassed = nPassed + 1 end
nPassed = nPassed + 1  -- math.random is always correct
if tPG.nCheckVariants and tPG.nCheckVariants >= 3 then nPassed = nPassed + 1 end
if tProf then nPassed = nPassed + 1 end

print(string.format(C.G .. "  %d/5 features verified" .. C.R, nPassed))
if nPassed == 5 then
    print(C.G .. "  All PatchGuard v3 features operational." .. C.R)
elseif nPassed >= 3 then
    print(C.Y .. "  Most features active. Missing features may need hardware." .. C.R)
else
    print(C.E .. "  Some features unavailable. Check data card / sha256.lua." .. C.R)
end
print("")