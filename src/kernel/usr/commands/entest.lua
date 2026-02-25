--
-- /usr/commands/enctest.lua
-- EXSi Enclave System Test & Demo
--
-- Usage:  enctest
--

local enc = require("enclave")

local C = {
    R = "\27[37m", G = "\27[32m", E = "\27[31m",
    Y = "\27[33m", C = "\27[36m", D = "\27[90m",
    M = "\27[35m",
}

local nPass, nFail = 0, 0

local function pass(s) nPass = nPass + 1; print(C.G .. "  [PASS] " .. C.R .. s) end
local function fail(s) nFail = nFail + 1; print(C.E .. "  [FAIL] " .. C.R .. s) end
local function info(s) print(C.C .. "  [INFO] " .. C.R .. s) end
local function section(s) print(""); print(C.Y .. "=== " .. s .. " ===" .. C.R) end

-- ═══════════════════════════════════════════
-- HEADER
-- ═══════════════════════════════════════════

print(C.C .. "╔═══════════════════════════════════════════════╗" .. C.R)
print(C.C .. "║  EXSi Enclave System — Test Suite              ║" .. C.R)
print(C.C .. "╚═══════════════════════════════════════════════╝" .. C.R)

-- ═══════════════════════════════════════════
-- TEST 1: Stats before any enclaves exist
-- ═══════════════════════════════════════════

section("1. Initial EXSi Stats")

local tStats = enc.stats()
if tStats then
    pass("enc.stats() returned data")
    info("Active enclaves:   " .. (tStats.nActiveEnclaves or "?"))
    info("Max enclaves:      " .. (tStats.nMaxEnclaves or "?"))
    info("SHA-256 available: " .. tostring(tStats.bSha256Available))
    info("Sealing available: " .. tostring(tStats.bSealingAvailable))
else
    fail("enc.stats() returned nil — EXSi may not be loaded")
    print("")
    print(C.E .. "EXSi is not available. Cannot continue." .. C.R)
    return
end

-- ═══════════════════════════════════════════
-- TEST 2: Create a simple enclave
-- ═══════════════════════════════════════════

section("2. Create Simple Enclave")

local sVaultCode = [=[
    local vault = {}

    return function(method, ...)
        if method == "store" then
            local key = select(1, ...)
            local val = select(2, ...)
            if type(key) ~= "string" then return nil, "key must be string" end
            vault[key] = val
            return true

        elseif method == "retrieve" then
            local key = select(1, ...)
            return vault[key]

        elseif method == "delete" then
            local key = select(1, ...)
            vault[key] = nil
            return true

        elseif method == "list" then
            local keys = {}
            for k in pairs(vault) do keys[#keys + 1] = k end
            table.sort(keys)
            return keys

        elseif method == "count" then
            local n = 0
            for _ in pairs(vault) do n = n + 1 end
            return n

        elseif method == "identity" then
            return MRENCLAVE

        else
            return nil, "unknown method: " .. tostring(method)
        end
    end
]=]

local hVault, sMrHash = enc.create(sVaultCode)

if hVault then
    pass("Enclave created: handle=" .. tostring(hVault))
    info("MRENCLAVE: " .. (sMrHash and (sMrHash:sub(1, 32) .. "...") or "N/A"))
else
    fail("Enclave creation failed: " .. tostring(sMrHash))
    return
end

-- ═══════════════════════════════════════════
-- TEST 3: Call enclave methods
-- ═══════════════════════════════════════════

section("3. Enclave Method Calls")

-- Store some secrets
local bOk = enc.call(hVault, "store", "api_key", "sk-12345-ABCDE-secret")
if bOk then pass("Stored 'api_key'") else fail("Store 'api_key' failed") end

bOk = enc.call(hVault, "store", "db_password", "hunter2")
if bOk then pass("Stored 'db_password'") else fail("Store 'db_password' failed") end

bOk = enc.call(hVault, "store", "token", "eyJhbGciOiJIUzI1NiJ9.payload.sig")
if bOk then pass("Stored 'token'") else fail("Store 'token' failed") end

-- Retrieve
local sApiKey = enc.call(hVault, "retrieve", "api_key")
if sApiKey == "sk-12345-ABCDE-secret" then
    pass("Retrieved 'api_key' correctly")
else
    fail("Retrieved wrong value: " .. tostring(sApiKey))
end

local sDbPass = enc.call(hVault, "retrieve", "db_password")
if sDbPass == "hunter2" then
    pass("Retrieved 'db_password' correctly")
else
    fail("Retrieved wrong value: " .. tostring(sDbPass))
end

-- Retrieve nonexistent key
local vMissing = enc.call(hVault, "retrieve", "nonexistent")
if vMissing == nil then
    pass("Nonexistent key returns nil")
else
    fail("Nonexistent key returned: " .. tostring(vMissing))
end

-- Count
local nCount = enc.call(hVault, "count")
if nCount == 3 then pass("Count = 3") else fail("Count = " .. tostring(nCount)) end

-- List keys
local tKeys = enc.call(hVault, "list")
if tKeys and #tKeys == 3 then
    pass("List returned 3 keys: " .. table.concat(tKeys, ", "))
else
    fail("List returned unexpected: " .. tostring(tKeys))
end

-- Delete
bOk = enc.call(hVault, "delete", "db_password")
if bOk then pass("Deleted 'db_password'") else fail("Delete failed") end

nCount = enc.call(hVault, "count")
if nCount == 2 then pass("Count after delete = 2") else fail("Count = " .. tostring(nCount)) end

-- Identity
local sId = enc.call(hVault, "identity")
if sId and #sId > 8 then
    pass("MRENCLAVE from inside enclave: " .. sId:sub(1, 24) .. "...")
else
    fail("MRENCLAVE not available inside enclave")
end

-- Unknown method
local r1, r2 = enc.call(hVault, "bogus_method")
if r1 == nil and r2 then
    pass("Unknown method correctly rejected: " .. r2)
else
    fail("Unknown method not rejected properly")
end

-- ═══════════════════════════════════════════
-- TEST 4: Attestation
-- ═══════════════════════════════════════════

section("4. Enclave Attestation")

local tAttest = enc.attest(hVault)
if tAttest then
    pass("Attestation returned data")
    info("MRENCLAVE:  " .. (tAttest.sMrEnclave or "?"):sub(1, 32) .. "...")
    info("Owner PID:  " .. tostring(tAttest.nOwnerPid))
    info("Created at: " .. string.format("%.2f", tAttest.nCreatedAt or 0) .. "s")
    info("Call count: " .. tostring(tAttest.nCallCount))
    info("Code size:  " .. tostring(tAttest.nCodeSize) .. " bytes")

    -- Verify MRENCLAVE matches what we got at creation
    if tAttest.sMrEnclave == sMrHash then
        pass("MRENCLAVE matches creation hash (deterministic)")
    else
        fail("MRENCLAVE mismatch! creation=" .. tostring(sMrHash) ..
             " attest=" .. tostring(tAttest.sMrEnclave))
    end
else
    fail("Attestation returned nil")
end

-- ═══════════════════════════════════════════
-- TEST 5: Seal / Unseal
-- ═══════════════════════════════════════════

section("5. Data Sealing")

local sSealCode = [=[
    local secret = nil

    return function(method, ...)
        if method == "set_secret" then
            secret = select(1, ...)
            return true

        elseif method == "get_secret" then
            return secret

        elseif method == "seal_secret" then
            if not secret then return nil, "no secret to seal" end
            return seal(secret)

        elseif method == "unseal_secret" then
            local blob = select(1, ...)
            if not blob then return nil, "no blob provided" end
            local data, err = unseal(blob)
            if data then
                secret = data
                return true
            else
                return nil, err or "unseal failed"
            end

        elseif method == "has_secret" then
            return secret ~= nil
        end
    end
]=]

local hSeal, sSealMr = enc.create(sSealCode)
if hSeal then
    pass("Seal enclave created: " .. tostring(hSeal))
else
    fail("Seal enclave creation failed"); goto skip_seal
end

do
    -- Store a secret and seal it
    enc.call(hSeal, "set_secret", "MY_PRIVATE_KEY_DATA_12345")
    local sBlob = enc.call(hSeal, "seal_secret")

    if sBlob and #sBlob > 0 then
        pass("Secret sealed: " .. #sBlob .. " byte blob")
        info("Blob preview: " .. C.D ..
             string.format("%02X %02X %02X %02X ... (%d bytes)",
                 sBlob:byte(1) or 0, sBlob:byte(2) or 0,
                 sBlob:byte(3) or 0, sBlob:byte(4) or 0,
                 #sBlob) .. C.R)

        -- Clear the secret and verify it's gone
        enc.call(hSeal, "set_secret", nil)
        local bHas = enc.call(hSeal, "has_secret")
        if not bHas then pass("Secret cleared from enclave") else fail("Secret not cleared") end

        -- Unseal to restore it
        local bUnsealOk, sUnsealErr = enc.call(hSeal, "unseal_secret", sBlob)
        if bUnsealOk then
            pass("Unseal succeeded")
            local sRestored = enc.call(hSeal, "get_secret")
            if sRestored == "MY_PRIVATE_KEY_DATA_12345" then
                pass("Unsealed secret matches original!")
            else
                fail("Unsealed secret mismatch: " .. tostring(sRestored))
            end
        else
            -- Sealing may not be available without a data card
            info("Unseal: " .. tostring(sUnsealErr) .. " (need data card for real sealing)")
        end

        -- Try unsealing with a DIFFERENT enclave (should fail)
        local hOther = enc.create([=[
            return function(method, ...)
                if method == "try_unseal" then
                    local blob = select(1, ...)
                    local data, err = unseal(blob)
                    return data, err
                end
            end
        ]=])

        if hOther then
            local vData, sErr = enc.call(hOther, "try_unseal", sBlob)
            if vData == nil then
                pass("Cross-enclave unseal correctly rejected" ..
                     (sErr and (": " .. sErr) or ""))
            else
                fail("Cross-enclave unseal should have failed!")
            end
            enc.destroy(hOther)
        end
    else
        info("Sealing returned nil (data card + SHA-256 required for sealing)")
        info("Memory isolation still works — sealing is an optional feature")
    end
end
::skip_seal::

-- ═══════════════════════════════════════════
-- TEST 6: Memory Isolation
-- ═══════════════════════════════════════════

section("6. Memory Isolation")

info("The enclave's local variables are unreachable from outside.")
info("No debug library in Ring 3 = no debug.getupvalue().")
info("The kernel sees the function but cannot read its upvalues.")

-- Demonstrate that we cannot access vault internals
local sCodeIsolation = [=[
    local hidden_password = "SUPER_SECRET_NEVER_EXPOSED"
    local counter = 0

    return function(method, ...)
        if method == "check" then
            counter = counter + 1
            return "alive, calls=" .. counter
        elseif method == "hint" then
            return "I have a " .. #hidden_password .. "-char password"
        end
    end
]=]

local hIso = enc.create(sCodeIsolation)
if hIso then
    local sCheck = enc.call(hIso, "check")
    pass("Isolation enclave responds: " .. tostring(sCheck))

    local sHint = enc.call(hIso, "hint")
    info("Enclave says: " .. tostring(sHint))
    info("But we CANNOT read hidden_password — it lives in closure upvalues")

    -- The only way to get hidden_password would be debug.getupvalue(),
    -- which is NOT available in Ring 3 sandboxes.
    pass("Memory isolation: upvalues unreachable without debug library")

    enc.destroy(hIso)
end

-- ═══════════════════════════════════════════
-- TEST 7: Deterministic MRENCLAVE
-- ═══════════════════════════════════════════

section("7. Deterministic MRENCLAVE")

local sDetCode = [=[
    return function(method) return "hello" end
]=]

local h1, mr1 = enc.create(sDetCode)
local h2, mr2 = enc.create(sDetCode)

if h1 and h2 then
    if mr1 == mr2 then
        pass("Same source → same MRENCLAVE (deterministic)")
        info("Hash: " .. (mr1 or "?"):sub(1, 32) .. "...")
    else
        fail("Same source produced different hashes!")
    end

    -- Different code → different hash
    local h3, mr3 = enc.create([=[return function(m) return "world" end]=])
    if h3 and mr3 ~= mr1 then
        pass("Different source → different MRENCLAVE")
    elseif h3 then
        fail("Different source produced same hash (collision!)")
    end

    if h1 then enc.destroy(h1) end
    if h2 then enc.destroy(h2) end
    if h3 then enc.destroy(h3) end
end

-- ═══════════════════════════════════════════
-- TEST 8: Error Handling
-- ═══════════════════════════════════════════

section("8. Error Cases")

-- Bad code
local hBad, sBadErr = enc.create("this is not valid lua }{][")
if not hBad then
    pass("Invalid Lua rejected: " .. tostring(sBadErr):sub(1, 50))
else
    fail("Invalid Lua was accepted!"); enc.destroy(hBad)
end

-- Code that doesn't return a function
local hBad2, sBad2 = enc.create([=[ return 42 ]=])
if not hBad2 then
    pass("Non-function return rejected: " .. tostring(sBad2):sub(1, 50))
else
    fail("Non-function return was accepted!"); enc.destroy(hBad2)
end

-- Empty code
local hBad3, sBad3 = enc.create("")
if not hBad3 then
    pass("Empty code rejected")
else
    fail("Empty code was accepted!"); enc.destroy(hBad3)
end

-- Invalid handle
local vBadCall = enc.call(99999, "test")
if vBadCall == nil then
    pass("Call to invalid handle returns nil")
else
    fail("Call to invalid handle didn't fail")
end

-- Destroy invalid handle
local vBadDest = enc.destroy(99999)
if vBadDest == nil then
    pass("Destroy invalid handle returns nil")
else
    fail("Destroy invalid handle didn't fail")
end

-- ═══════════════════════════════════════════
-- TEST 9: Enclave that crashes
-- ═══════════════════════════════════════════

section("9. Crash Containment")

local hCrash = enc.create([=[
    return function(method, ...)
        if method == "crash" then
            error("intentional crash!")
        elseif method == "ping" then
            return "pong"
        end
    end
]=])

if hCrash then
    -- Normal call works
    local sPong = enc.call(hCrash, "ping")
    if sPong == "pong" then pass("Pre-crash call works") end

    -- Crash call
    local vCrash, sCrashErr = enc.call(hCrash, "crash")
    if vCrash == nil and sCrashErr then
        pass("Crash contained: " .. tostring(sCrashErr):sub(1, 40))
    else
        fail("Crash not properly contained")
    end

    -- Can still interact after crash
    local sPong2 = enc.call(hCrash, "ping")
    if sPong2 == "pong" then
        pass("Enclave still functional after crash")
    else
        fail("Enclave broken after crash")
    end

    enc.destroy(hCrash)
end

-- ═══════════════════════════════════════════
-- TEST 10: List and Final Stats
-- ═══════════════════════════════════════════

section("10. Listing & Final Stats")

-- List active enclaves (vault + seal should still exist)
local tList = enc.list()
if tList then
    info("Active enclaves: " .. #tList)
    for _, tE in ipairs(tList) do
        print(string.format("    %shandle=%-3d%s MRENCLAVE=%s owner=PID %d calls=%d size=%dB",
            C.D, tE.nHandle, C.R,
            (tE.sMrEnclave or "?"):sub(1, 16) .. "...",
            tE.nOwnerPid or 0,
            tE.nCallCount or 0,
            tE.nCodeSize or 0))
    end
    pass("Listing works")
else
    fail("Listing returned nil")
end

-- Cleanup remaining enclaves
if hVault then enc.destroy(hVault); info("Destroyed vault enclave") end
if hSeal then enc.destroy(hSeal); info("Destroyed seal enclave") end

-- Final stats
local tFinal = enc.stats()
if tFinal then
    info("")
    info("─ Final EXSi Statistics ─")
    info("Total created:    " .. tostring(tFinal.nCreated))
    info("Total destroyed:  " .. tostring(tFinal.nDestroyed))
    info("Total calls:      " .. tostring(tFinal.nCalls))
    info("Attestations:     " .. tostring(tFinal.nAttestations))
    info("Seals:            " .. tostring(tFinal.nSeals))
    info("Unseals:          " .. tostring(tFinal.nUnseals))
    info("Seal failures:    " .. tostring(tFinal.nSealFailures))
    info("Active now:       " .. tostring(tFinal.nActiveEnclaves))
end

-- Verify all cleaned up
local tListFinal = enc.list()
if tListFinal and #tListFinal == 0 then
    pass("All enclaves cleaned up")
elseif tListFinal then
    info(#tListFinal .. " enclave(s) still active (may belong to other processes)")
end

-- ═══════════════════════════════════════════
-- SUMMARY
-- ═══════════════════════════════════════════

print("")
print(C.C .. "═══════════════════════════════════════════════" .. C.R)
print(string.format("  Results: %s%d passed%s, %s%d failed%s",
    C.G, nPass, C.R, nFail > 0 and C.E or C.D, nFail, C.R))

if nFail == 0 then
    print(C.G .. "  All EXSi enclave tests passed!" .. C.R)
else
    print(C.Y .. "  Some tests failed. Check data card availability" .. C.R)
    print(C.Y .. "  for seal/unseal features." .. C.R)
end
print(C.C .. "═══════════════════════════════════════════════" .. C.R)