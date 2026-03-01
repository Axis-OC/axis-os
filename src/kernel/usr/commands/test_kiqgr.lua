--
-- /usr/commands/test_kiqgr.lua
-- KIQGR (Kernel Integrity Quality Guard Region) enclave tester.
-- Verifies the integrity enclave exists, EXSi works, hashes are sealed.
--
local C = {R="\27[37m",G="\27[32m",E="\27[31m",Y="\27[33m",C="\27[36m",D="\27[90m",M="\27[35m"}
local nPass, nFail = 0, 0
local function pass(s) nPass=nPass+1; print(C.G.."  [PASS] "..C.R..s) end
local function fail(s) nFail=nFail+1; print(C.E.."  [FAIL] "..C.R..s) end
local function info(s) print(C.C.."  [INFO] "..C.R..s) end
local function section(s) print(""); print(C.Y.."=== "..s.." ==="..C.R) end

print(C.C.."╔═════════════════════════════════════════════╗"..C.R)
print(C.C.."║  KIQGR Enclave Integrity Tester              ║"..C.R)
print(C.C.."╚═════════════════════════════════════════════╝"..C.R)

-- 1. EXSi subsystem
section("1. EXSi subsystem")

local tExsi = syscall("exsi_stats")
if not tExsi then
    fail("exsi_stats returned nil — EXSi not loaded")
    info("  → Check __load_exsi() in kernel.lua")
    info("  → Verify /lib/exsi.lua exists on disk")
    return
end
pass("EXSi subsystem available")
info("  Active enclaves: " .. tostring(tExsi.nActiveEnclaves))
info("  Max enclaves:    " .. tostring(tExsi.nMaxEnclaves))
info("  SHA-256:         " .. tostring(tExsi.bSha256Available))
info("  Sealing:         " .. tostring(tExsi.bSealingAvailable))

if not tExsi.bSha256Available then
    fail("SHA-256 not available — KIQGR cannot hash files")
    info("  → Check /lib/sha256.lua exists and loads in kernel boot")
end

-- 2. KIQGR enclave presence
section("2. KIQGR enclave in enclave list")

local tEnclaves = syscall("exsi_list")
if not tEnclaves or #tEnclaves == 0 then
    fail("No active enclaves — KIQGR not created")
    info("  → Check KIQGR initialization block in kernel.lua")
    info("  → g_oExsi and g_oSha256Lib must both be non-nil")
else
    pass(#tEnclaves .. " active enclave(s)")

    -- KIQGR enclave should have a large code size (the embedded SHA-256)
    local bFoundKiqgr = false
    local bFoundPrng = false
    for _, tE in ipairs(tEnclaves) do
        info(string.format("  handle=%-3d owner=PID %-2d code=%dB calls=%d  MR=%s",
            tE.nHandle, tE.nOwnerPid, tE.nCodeSize,
            tE.nCallCount, (tE.sMrEnclave or "?"):sub(1, 16) .. "..."))
        -- KIQGR enclave is >2000 bytes (has embedded SHA-256)
        if tE.nCodeSize > 2000 and tE.nOwnerPid == 0 then
            bFoundKiqgr = true
        end
        -- Handle PRNG enclave is ~800 bytes
        if tE.nCodeSize > 500 and tE.nCodeSize < 2000 and tE.nOwnerPid == 0 then
            bFoundPrng = true
        end
    end

    if bFoundKiqgr then
        pass("Found likely KIQGR enclave (>2000B code, owner=PID 0)")
    else
        fail("No KIQGR-sized enclave found (expected >2000B from PID 0)")
        info("  → KIQGR needs EXSi + SHA-256 at boot time")
    end
    if bFoundPrng then
        pass("Found likely Handle-PRNG enclave (500-2000B, owner=PID 0)")
    end
end

-- 3. PatchGuard reports KIQGR integration
section("3. PatchGuard ↔ KIQGR integration")

local tPG = syscall("patchguard_status")
if tPG then
    local nFiles = tPG.nCriticalFilesHashed or 0
    if nFiles > 0 then
        pass("PatchGuard has " .. nFiles .. " file hashes (fed to KIQGR)")
    else
        fail("PatchGuard has 0 file hashes — KIQGR has nothing to verify")
    end

    -- Check that KIQGR enclave call count is > 0 (PG has used it)
    if tEnclaves then
        for _, tE in ipairs(tEnclaves) do
            if tE.nCodeSize > 2000 and tE.nOwnerPid == 0 then
                if tE.nCallCount > 0 then
                    pass("KIQGR enclave has " .. tE.nCallCount ..
                        " calls (PatchGuard is using it)")
                else
                    info("KIQGR enclave has 0 calls — PG may not have run a file check yet")
                end
            end
        end
    end
else
    info("PatchGuard status not available — cannot verify integration")
end

-- 4. EXSi functional test (create + call + attest + destroy)
section("4. EXSi functional test (user-created enclave)")

local sTestCode = [=[
    local nSecret = 42
    return function(method, ...)
        if method == "get" then return nSecret
        elseif method == "set" then nSecret = select(1, ...); return true
        elseif method == "identity" then return MRENCLAVE
        end
    end
]=]

local hTest, sMr = syscall("exsi_create", sTestCode)
if hTest then
    pass("Test enclave created: handle=" .. tostring(hTest))
    info("  MRENCLAVE: " .. (sMr or "?"):sub(1, 32) .. "...")

    -- Call
    local nVal = syscall("exsi_call", hTest, "get")
    if nVal == 42 then
        pass("Enclave call returns correct value (42)")
    else
        fail("Enclave call returned: " .. tostring(nVal))
    end

    -- Attest
    local tAttest = syscall("exsi_attest", hTest)
    if tAttest and tAttest.sMrEnclave == sMr then
        pass("Attestation matches creation hash (deterministic)")
    else
        fail("Attestation mismatch or nil")
    end

    -- Verify isolation: secret is unreachable from outside
    -- (We can only call methods, not read nSecret directly)
    syscall("exsi_call", hTest, "set", 99)
    local nVal2 = syscall("exsi_call", hTest, "get")
    if nVal2 == 99 then
        pass("Enclave state mutation works (42 → 99)")
    else
        fail("State mutation failed: expected 99, got " .. tostring(nVal2))
    end

    -- Destroy
    local bDest = syscall("exsi_destroy", hTest)
    if bDest then
        pass("Test enclave destroyed")
    else
        fail("Enclave destruction failed")
    end

    -- Use-after-destroy
    local vDead = syscall("exsi_call", hTest, "get")
    if vDead == nil then
        pass("Call to destroyed enclave correctly returns nil")
    else
        fail("Destroyed enclave still responds!")
    end
else
    fail("Cannot create test enclave: " .. tostring(sMr))
    info("  → EXSi.CreateEnclave may be at enclave limit or broken")
end

-- 5. Deterministic MRENCLAVE
section("5. Deterministic MRENCLAVE")

local h1, mr1 = syscall("exsi_create", [=[return function() return 1 end]=])
local h2, mr2 = syscall("exsi_create", [=[return function() return 1 end]=])
if h1 and h2 then
    if mr1 == mr2 then
        pass("Same source → same MRENCLAVE (deterministic hashing)")
    else
        fail("Same source produced different hashes!")
        info("  → Check SHA-256 in EXSi.CreateEnclave")
    end
    syscall("exsi_destroy", h1)
    syscall("exsi_destroy", h2)
else
    fail("Could not create pair of test enclaves")
end

-- Summary
print("")
print(C.C.."═════════════════════════════════════════════"..C.R)
print(string.format("  %sPassed:%s %d   %sFailed:%s %d",
    C.G, C.R, nPass, nFail>0 and C.E or C.D, C.R, nFail))
if nFail == 0 then
    print(C.G.."  KIQGR enclave infrastructure fully operational."..C.R)
else
    print(C.E.."  KIQGR issues found — review [FAIL] items."..C.R)
    print(C.E.."  Code paths: kernel.lua KIQGR init, /lib/kiqgr.lua, /lib/exsi.lua"..C.R)
end
print(C.C.."═════════════════════════════════════════════"..C.R)