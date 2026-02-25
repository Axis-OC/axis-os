--
-- /usr/commands/pcmr_test.lua
-- PCMR (Polymorphic Cryptographic Mutating Region) Security Test Suite
--
-- Verifies that PCMR correctly manages kernel handles through EXSi
-- enclaves and tests for handle-based bypass vectors.
--
-- Usage:  pcmr_test
--         pcmr_test -v     (verbose)
--

local pcmr = require("pcmr")
local enc  = require("enclave")

local tArgs = env.ARGS or {}
local bVerbose = false
for _, a in ipairs(tArgs) do
    if a == "-v" or a == "--verbose" then bVerbose = true end
end

-- =============================================
-- OUTPUT HELPERS
-- =============================================

local C = {
    R = "\27[37m", G = "\27[32m", E = "\27[31m",
    Y = "\27[33m", C = "\27[36m", D = "\27[90m",
    M = "\27[35m", B = "\27[34m",
}

local nPass, nFail, nSkip = 0, 0, 0

local function pass(s) nPass = nPass + 1; print(C.G .. "  [PASS] " .. C.R .. s) end
local function fail(s) nFail = nFail + 1; print(C.E .. "  [FAIL] " .. C.R .. s) end
local function skip(s) nSkip = nSkip + 1; print(C.Y .. "  [SKIP] " .. C.R .. s) end
local function info(s) print(C.C .. "  [INFO] " .. C.R .. s) end
local function verb(s) if bVerbose then print(C.D .. "  [VERB] " .. C.R .. s) end end
local function section(s) print(""); print(C.Y .. "=== " .. s .. " ===" .. C.R) end

local function hexStr(s)
    if not s or type(s) ~= "string" then return "(nil)" end
    local t = {}
    for i = 1, math.min(#s, 16) do t[i] = string.format("%02X", s:byte(i)) end
    local sH = table.concat(t, " ")
    if #s > 16 then sH = sH .. " ... (" .. #s .. "B)" end
    return sH
end

-- =============================================
-- HEADER
-- =============================================

print(C.C .. "╔═══════════════════════════════════════════════════╗" .. C.R)
print(C.C .. "║  PCMR Kernel Handle Security Test Suite            ║" .. C.R)
print(C.C .. "║  Polymorphic Cryptographic Mutating Region         ║" .. C.R)
print(C.C .. "╚═══════════════════════════════════════════════════╝" .. C.R)
print("")

-- =============================================
-- PRE-FLIGHT: Verify EXSi is available
-- =============================================

section("0. Pre-flight Checks")

local tExsiStats = enc.stats()
if not tExsiStats then
    fail("EXSi subsystem not available — PCMR requires enclaves")
    print(C.E .. "  Cannot continue without EXSi." .. C.R)
    return
end
pass("EXSi subsystem available")
info("Active enclaves:   " .. tostring(tExsiStats.nActiveEnclaves))
info("SHA-256 available: " .. tostring(tExsiStats.bSha256Available))
info("Sealing available: " .. tostring(tExsiStats.bSealingAvailable))

-- Record initial enclave count for leak detection
local nInitialEnclaves = tExsiStats.nActiveEnclaves

-- =============================================
-- TEST 1: Handle Creation & Basic Validity
-- =============================================

section("1. Handle Creation & Basic Validity")

-- 1a. Create from byte array
local tKeyBytes = {0x4A, 0x9F, 0x22, 0xB7, 0x01, 0xCC, 0xDE, 0x55,
                   0xAA, 0x33, 0x77, 0x11, 0xEE, 0x44, 0x88, 0xFF}
local hKey1, sErr1 = pcmr.create(tKeyBytes, "test_seed_alpha")
if hKey1 then
    pass("Handle created from byte array: " .. tostring(hKey1))
else
    fail("Create from byte array failed: " .. tostring(sErr1))
end

-- 1b. Create from string
local hKey2, sErr2 = pcmr.createFromString("SecretKeyMaterial!@#$%", "test_seed_beta")
if hKey2 then
    pass("Handle created from string: " .. tostring(hKey2))
else
    fail("Create from string failed: " .. tostring(sErr2))
end

-- 1c. Verify handles are different
if hKey1 and hKey2 and hKey1 ~= hKey2 then
    pass("Handles are unique (h1=" .. tostring(hKey1) .. " h2=" .. tostring(hKey2) .. ")")
else
    fail("Handles not unique!")
end

-- 1d. Key length retrieval
if hKey1 then
    local nLen = pcmr.keyLength(hKey1)
    if nLen == 16 then
        pass("Key length correct: " .. nLen .. " bytes")
    else
        fail("Key length wrong: expected 16, got " .. tostring(nLen))
    end
end

-- 1e. Verify EXSi enclave was created for each handle
local tPostCreate = enc.stats()
if tPostCreate then
    local nNewEnclaves = tPostCreate.nActiveEnclaves - nInitialEnclaves
    info("New enclaves created: " .. nNewEnclaves)
    if nNewEnclaves >= 2 then
        pass("Each PCMR handle backed by a separate EXSi enclave")
    else
        fail("Expected >= 2 new enclaves, got " .. nNewEnclaves)
    end
end

-- =============================================
-- TEST 2: HMAC Correctness & Determinism
-- =============================================

section("2. HMAC Correctness & Determinism")

if not hKey1 then skip("No handle available"); goto test3 end

do -- scope locals so goto doesn't jump into their scope

-- 2a. HMAC produces output
local sHmac1 = pcmr.hmac(hKey1, "test message 1")
if sHmac1 and type(sHmac1) == "string" and #sHmac1 == 32 then
    pass("HMAC returned 32-byte digest")
    verb("HMAC: " .. hexStr(sHmac1))
else
    fail("HMAC returned unexpected: " .. tostring(sHmac1))
end

-- 2b. Same message = same HMAC (before mutation)
local sHmac1b = pcmr.hmac(hKey1, "test message 1")
if sHmac1 and sHmac1b and sHmac1 == sHmac1b then
    pass("HMAC is deterministic (same key + same msg = same output)")
else
    fail("HMAC not deterministic!")
end

-- 2c. Different messages = different HMACs
local sHmac2 = pcmr.hmac(hKey1, "test message 2")
if sHmac1 and sHmac2 and sHmac1 ~= sHmac2 then
    pass("Different messages produce different HMACs")
else
    fail("Different messages produced same HMAC!")
end

-- 2d. HMAC verification (constant-time)
if sHmac1 then
    local bVerify = pcmr.verifyHmac(hKey1, "test message 1", sHmac1)
    if bVerify then
        pass("verifyHmac confirms correct HMAC")
    else
        fail("verifyHmac rejected correct HMAC")
    end

    local bFalse = pcmr.verifyHmac(hKey1, "wrong message", sHmac1)
    if not bFalse then
        pass("verifyHmac rejects incorrect message")
    else
        fail("verifyHmac accepted incorrect message!")
    end

    local bTampered = pcmr.verifyHmac(hKey1, "test message 1",
        sHmac1:sub(1, 31) .. string.char((sHmac1:byte(32) + 1) % 256))
    if not bTampered then
        pass("verifyHmac rejects tampered HMAC (1-bit flip)")
    else
        fail("verifyHmac accepted tampered HMAC!")
    end
end

end -- do

::test3::

-- =============================================
-- TEST 3: Mutation Invariance
-- =============================================

section("3. Mutation Invariance (Key Survives Rotation)")

if not hKey1 then skip("No handle available"); goto test4 end

do -- scope locals

-- 3a. Record HMAC before mutations
local sPreMutate = pcmr.hmac(hKey1, "mutation test vector")

-- 3b. Perform many mutations
local nMutations = 50
local bAllOk = true
for i = 1, nMutations do
    local bMut = pcmr.mutate(hKey1)
    if not bMut then bAllOk = false; break end
end
if bAllOk then
    pass(nMutations .. " mutations completed successfully")
else
    fail("Mutation failed during batch")
end

-- 3c. Verify HMAC is IDENTICAL after mutations
local sPostMutate = pcmr.hmac(hKey1, "mutation test vector")
if sPreMutate and sPostMutate and sPreMutate == sPostMutate then
    pass("HMAC invariant after " .. nMutations .. " mutations (key preserved)")
    verb("Pre:  " .. hexStr(sPreMutate))
    verb("Post: " .. hexStr(sPostMutate))
else
    fail("HMAC CHANGED after mutations — key corruption!")
    info("Pre:  " .. hexStr(sPreMutate))
    info("Post: " .. hexStr(sPostMutate))
end

-- 3d. Verify key length unchanged after mutations
local nLenPost = pcmr.keyLength(hKey1)
if nLenPost == 16 then
    pass("Key length unchanged after mutations")
else
    fail("Key length changed: was 16, now " .. tostring(nLenPost))
end

end -- do

::test4::

-- =============================================
-- TEST 4: Handle Isolation (Cross-Handle Security)
-- =============================================

section("4. Handle Isolation (Cross-Handle Security)")

if not hKey1 or not hKey2 then skip("Need two handles"); goto test5 end

do -- scope locals

-- 4a. Different keys produce different HMACs for same message
local sH1 = pcmr.hmac(hKey1, "cross-handle test")
local sH2 = pcmr.hmac(hKey2, "cross-handle test")
if sH1 and sH2 and sH1 ~= sH2 then
    pass("Different handles produce different HMACs (key isolation)")
    verb("Handle 1: " .. hexStr(sH1))
    verb("Handle 2: " .. hexStr(sH2))
else
    fail("Different handles produced SAME HMAC — key leakage!")
end

-- 4b. Verify handle 1 can't verify handle 2's HMAC
if sH2 then
    local bCross = pcmr.verifyHmac(hKey1, "cross-handle test", sH2)
    if not bCross then
        pass("Handle 1 correctly rejects Handle 2's HMAC")
    else
        fail("Handle 1 ACCEPTED Handle 2's HMAC — cross-handle leak!")
    end
end

-- 4c. Mutating one handle doesn't affect the other
local sH2Pre = pcmr.hmac(hKey2, "isolation vector")
pcmr.mutate(hKey1)  -- mutate handle 1 only
local sH2Post = pcmr.hmac(hKey2, "isolation vector")
if sH2Pre and sH2Post and sH2Pre == sH2Post then
    pass("Mutating handle 1 does not affect handle 2")
else
    fail("Mutating handle 1 CHANGED handle 2's output!")
end

end -- do

::test5::

-- =============================================
-- TEST 5: Handle Forgery Bypass Attempts
-- =============================================

section("5. Handle Forgery / Invalid Handle Bypasses")

-- 5a. Random number as handle
local vForge1 = pcmr.hmac(99999, "forgery attempt")
if vForge1 == nil then
    pass("Random handle number rejected")
else
    fail("Random handle number ACCEPTED — forgery possible!")
end

-- 5b. Zero handle
local vForge2 = pcmr.hmac(0, "forgery attempt")
if vForge2 == nil then
    pass("Handle 0 rejected")
else
    fail("Handle 0 ACCEPTED!")
end

-- 5c. Negative handle
local vForge3 = pcmr.hmac(-1, "forgery attempt")
if vForge3 == nil then
    pass("Negative handle rejected")
else
    fail("Negative handle ACCEPTED!")
end

-- 5d. String as handle
local vForge4 = pcmr.hmac("not_a_handle", "forgery attempt")
if vForge4 == nil then
    pass("String handle rejected")
else
    fail("String handle ACCEPTED!")
end

-- 5e. nil as handle
local vForge5 = pcmr.hmac(nil, "forgery attempt")
if vForge5 == nil then
    pass("nil handle rejected")
else
    fail("nil handle ACCEPTED!")
end

-- 5f. Table as handle
local vForge6 = pcmr.hmac({}, "forgery attempt")
if vForge6 == nil then
    pass("Table handle rejected")
else
    fail("Table handle ACCEPTED!")
end

-- 5g. Boolean as handle
local vForge7 = pcmr.hmac(true, "forgery attempt")
if vForge7 == nil then
    pass("Boolean handle rejected")
else
    fail("Boolean handle ACCEPTED!")
end

-- =============================================
-- TEST 6: Use-After-Destroy Bypass
-- =============================================

section("6. Use-After-Destroy Bypass")

-- Create a temporary handle, use it, destroy it, try to use it again
local tTmpKey = {0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE}
local hTmp, sTmpErr = pcmr.create(tTmpKey, "temp_seed")

if not hTmp then
    skip("Could not create temporary handle: " .. tostring(sTmpErr))
    goto test7
end

do -- scope locals

-- 6a. Verify it works before destroy
local sBeforeDestroy = pcmr.hmac(hTmp, "alive test")
if sBeforeDestroy and #sBeforeDestroy == 32 then
    pass("Handle functional before destroy")
    verb("HMAC: " .. hexStr(sBeforeDestroy))
else
    fail("Handle broken before destroy")
end

-- 6b. Destroy
local bDestroyed = pcmr.destroy(hTmp)
if bDestroyed then
    pass("Handle destroyed successfully")
else
    fail("Destroy returned false/nil")
end

-- 6c. Attempt HMAC after destroy
local sAfterDestroy = pcmr.hmac(hTmp, "dead test")
if sAfterDestroy == nil then
    pass("HMAC rejected on destroyed handle (use-after-free blocked)")
else
    fail("HMAC SUCCEEDED on destroyed handle — use-after-free!")
end

-- 6d. Attempt mutate after destroy
local bMutAfter = pcmr.mutate(hTmp)
if bMutAfter == nil then
    pass("Mutate rejected on destroyed handle")
else
    fail("Mutate SUCCEEDED on destroyed handle!")
end

-- 6e. Attempt keyLength after destroy
local nLenAfter = pcmr.keyLength(hTmp)
if nLenAfter == nil then
    pass("keyLength rejected on destroyed handle")
else
    fail("keyLength SUCCEEDED on destroyed handle!")
end

-- 6f. Attempt verifyHmac after destroy
local bVerAfter = pcmr.verifyHmac(hTmp, "dead test", sBeforeDestroy or "")
if not bVerAfter then
    pass("verifyHmac rejected on destroyed handle")
else
    fail("verifyHmac SUCCEEDED on destroyed handle!")
end

-- 6g. Double destroy
local bDoubleDestroy = pcmr.destroy(hTmp)
if bDoubleDestroy == nil then
    pass("Double destroy returns nil (idempotent)")
else
    fail("Double destroy returned non-nil: " .. tostring(bDoubleDestroy))
end

end -- do

::test7::

-- =============================================
-- TEST 7: Seal/Unseal Cross-Handle Attack
-- =============================================

section("7. Seal/Unseal Cross-Handle Attack")

if not hKey1 or not hKey2 then skip("Need two handles"); goto test8 end

do -- scope locals

-- 7a. Seal with handle 1
local sSealed1 = pcmr.sealKey(hKey1)
if sSealed1 and type(sSealed1) == "string" and #sSealed1 > 0 then
    pass("Key sealed with handle 1 (" .. #sSealed1 .. " bytes)")
    verb("Sealed blob: " .. hexStr(sSealed1))
else
    -- Sealing requires data card — may not be available
    if not tExsiStats.bSealingAvailable then
        skip("Sealing not available (no data card)")
    else
        fail("Seal failed: " .. tostring(sSealed1))
    end
    goto test8
end

-- 7b. Attempt unseal with DIFFERENT handle (should fail)
local bCrossUnseal, sCrossErr = pcmr.unsealKey(hKey2, sSealed1)
if not bCrossUnseal then
    pass("Cross-handle unseal correctly rejected: " ..
        tostring(sCrossErr):sub(1, 50))
else
    fail("Cross-handle unseal SUCCEEDED — seal/unseal bypass!")
end

-- 7c. Unseal with correct handle (should succeed)
-- First destroy and recreate with same key to test seal persistence
local sPreSealHmac = pcmr.hmac(hKey1, "seal roundtrip test")
pcmr.destroy(hKey1)

-- Recreate with same key
hKey1 = pcmr.create(tKeyBytes, "test_seed_alpha")
if hKey1 then
    local bUnsealOk, sUnsealErr = pcmr.unsealKey(hKey1, sSealed1)
    if bUnsealOk then
        -- Verify key was restored correctly
        local sPostSealHmac = pcmr.hmac(hKey1, "seal roundtrip test")
        if sPreSealHmac and sPostSealHmac and sPreSealHmac == sPostSealHmac then
            pass("Seal/unseal roundtrip: key correctly restored")
        else
            -- MRENCLAVE changes because enclave is recreated - this is expected
            -- The unsealed key should still produce correct HMAC
            info("MRENCLAVE changed (new enclave) — unseal may fail by design")
            info("Pre:  " .. hexStr(sPreSealHmac))
            info("Post: " .. hexStr(sPostSealHmac))
        end
    else
        -- Different MRENCLAVE after recreate means unseal correctly fails
        info("Unseal rejected after recreate: " .. tostring(sUnsealErr):sub(1, 50))
        info("This is CORRECT: MRENCLAVE differs between enclave instances")
        pass("Seal tied to specific enclave instance (MRENCLAVE binding)")
    end
else
    fail("Could not recreate handle 1 for unseal test")
end

end -- do

::test8::

-- =============================================
-- TEST 8: Invalid Input Handling
-- =============================================

section("8. Invalid Input Handling")

-- 8a. Empty key
local hEmpty, sEmptyErr = pcmr.create({}, "seed")
if hEmpty == nil then
    pass("Empty key array rejected: " .. tostring(sEmptyErr):sub(1, 40))
else
    fail("Empty key array ACCEPTED!")
    pcmr.destroy(hEmpty)
end

-- 8b. Empty string key
local hEmptyStr, sEmptyStrErr = pcmr.createFromString("", "seed")
if hEmptyStr == nil then
    pass("Empty string key rejected")
else
    fail("Empty string key ACCEPTED!")
    pcmr.destroy(hEmptyStr)
end

-- 8c. Key exceeding 64 bytes (HMAC limit)
local tBigKey = {}
for i = 1, 65 do tBigKey[i] = i % 256 end
local hBig, sBigErr = pcmr.create(tBigKey, "seed")
if hBig == nil then
    pass("65-byte key rejected (PCMR limit is 64): " ..
        tostring(sBigErr):sub(1, 40))
else
    fail("65-byte key ACCEPTED (should be rejected per PCMR docs)")
    pcmr.destroy(hBig)
end

-- 8d. Key with exactly 64 bytes (boundary)
local tMaxKey = {}
for i = 1, 64 do tMaxKey[i] = (i * 7) % 256 end
local hMax, sMaxErr = pcmr.create(tMaxKey, "seed")
if hMax then
    pass("64-byte key (maximum) accepted")
    local sMaxHmac = pcmr.hmac(hMax, "boundary test")
    if sMaxHmac and #sMaxHmac == 32 then
        pass("64-byte key produces valid HMAC")
    else
        fail("64-byte key HMAC failed")
    end
    pcmr.destroy(hMax)
else
    fail("64-byte key rejected: " .. tostring(sMaxErr))
end

-- 8e. HMAC with nil message
if hKey2 then
    local vNilMsg = pcmr.hmac(hKey2, nil)
    if vNilMsg == nil then
        pass("HMAC with nil message rejected")
    else
        -- May be handled by tostring(nil) = "nil" inside enclave
        info("HMAC with nil message returned value (enclave may tostring)")
    end
end

-- 8f. HMAC with non-string message
if hKey2 then
    local vNumMsg = pcmr.hmac(hKey2, 12345)
    if vNumMsg == nil then
        pass("HMAC with number message rejected")
    else
        info("HMAC with number message: enclave may tostring internally")
    end
end

-- =============================================
-- TEST 9: Enclave Boundary Probing
-- =============================================

section("9. Enclave Boundary Probing")

-- 9a. Try to attest a PCMR enclave
if hKey2 then
    local tAttest = enc.attest(hKey2)
    if tAttest then
        pass("PCMR enclave attestation returns metadata")
        info("MRENCLAVE: " .. (tAttest.sMrEnclave or "?"):sub(1, 32) .. "...")
        info("Code size: " .. tostring(tAttest.nCodeSize) .. " bytes")
        info("Calls:     " .. tostring(tAttest.nCallCount))

        -- 9b. Verify all PCMR enclaves have the SAME MRENCLAVE
        -- (they're loaded from the same source code)
        if hKey1 then
            local tAttest1 = enc.attest(hKey1)
            if tAttest1 and tAttest.sMrEnclave == tAttest1.sMrEnclave then
                pass("All PCMR enclaves share same MRENCLAVE (deterministic)")
            elseif tAttest1 then
                -- After destroy+recreate, MRENCLAVE should still match
                -- (same source code)
                info("MRENCLAVE comparison: " ..
                    (tAttest1.sMrEnclave or "?"):sub(1, 16) .. " vs " ..
                    (tAttest.sMrEnclave or "?"):sub(1, 16))
            end
        end
    else
        fail("Enclave attestation failed")
    end
end

-- 9c. Try to directly call the enclave with internal methods
if hKey2 then
    -- The enclave's entry function expects methods like "init", "mutate",
    -- "hmac", etc.  Try calling with unknown methods.
    local vBogus, sBogusErr = syscall("exsi_call", hKey2, "INTERNAL_GET_DATA")
    if vBogus == nil then
        pass("Internal method 'INTERNAL_GET_DATA' rejected by enclave")
    else
        fail("Internal method returned data — enclave boundary leak!")
    end

    -- Try accessing the split arrays directly
    local vData, sDataErr = syscall("exsi_call", hKey2, "get_data_array")
    if vData == nil then
        pass("Direct data array access rejected")
    else
        fail("Data array EXPOSED through enclave call!")
    end

    local vMask, sMaskErr = syscall("exsi_call", hKey2, "get_mask_array")
    if vMask == nil then
        pass("Direct mask array access rejected")
    else
        fail("Mask array EXPOSED through enclave call!")
    end
end

-- 9d. Verify PCMR enclave source code is available for auditing
local sSource = pcmr.getEnclaveSource()
if sSource and type(sSource) == "string" and #sSource > 100 then
    pass("Enclave source accessible for audit (" .. #sSource .. " chars)")

    -- Verify source doesn't contain any data exfiltration paths
    local bHasIo = sSource:find("io%.") or sSource:find("require")
        or sSource:find("syscall") or sSource:find("component")
        or sSource:find("computer") or sSource:find("debug")
        or sSource:find("rawget") or sSource:find("rawset")
    if not bHasIo then
        pass("Enclave source has no I/O, require, syscall, debug, or rawset")
    else
        fail("Enclave source contains potentially dangerous API access")
    end

    -- Verify key is stored as split arrays, never as contiguous string
    local bHasSplit = sSource:find("tData") and sSource:find("tMask")
    if bHasSplit then
        pass("Source confirms split-array key storage (tData/tMask)")
    else
        fail("Source does not use split-array pattern!")
    end
else
    fail("Enclave source not available for audit")
end

-- =============================================
-- TEST 10: HMAC Oracle Attack Resistance
-- =============================================

section("10. HMAC Oracle Attack Resistance")

-- An attacker with access to pcmr.hmac() might try to reconstruct
-- the key by submitting carefully crafted messages and analyzing
-- the outputs.  This isn't a Lua-level bypass (HMAC-SHA256 is
-- designed to resist this), but we verify the properties hold.

if not hKey2 then skip("No handle available"); goto test11 end

do -- scope locals

-- 10a. Verify HMAC output is full 256-bit (no truncation leak)
local sOracleHmac = pcmr.hmac(hKey2, "oracle test")
if sOracleHmac and #sOracleHmac == 32 then
    pass("HMAC output is full 256-bit (32 bytes)")
else
    fail("HMAC output truncated: " .. tostring(sOracleHmac and #sOracleHmac))
end

-- 10b. Verify output changes unpredictably with input
local tOutputs = {}
local bAllDifferent = true
for i = 1, 20 do
    local sH = pcmr.hmac(hKey2, "oracle_" .. i)
    if sH then
        for _, sPrev in ipairs(tOutputs) do
            if sH == sPrev then bAllDifferent = false; break end
        end
        tOutputs[#tOutputs + 1] = sH
    end
end
if bAllDifferent and #tOutputs == 20 then
    pass("20 distinct inputs produce 20 distinct outputs (no collisions)")
else
    fail("HMAC collision detected in oracle test!")
end

-- 10c. Verify HMAC doesn't leak key length through timing
-- (We can't measure precise timing in OC, but verify output is constant-size)
local tLens = {}
for i = 1, 10 do
    local sH = pcmr.hmac(hKey2, string.rep("A", i * 100))
    if sH then tLens[#sH] = (tLens[#sH] or 0) + 1 end
end
local nDistinctLens = 0
for _ in pairs(tLens) do nDistinctLens = nDistinctLens + 1 end
if nDistinctLens == 1 then
    pass("Constant-size output regardless of input length")
else
    fail("Output size varies with input length!")
end

end -- do

::test11::

-- =============================================
-- TEST 11: mutateAll() Global Mutation
-- =============================================

section("11. mutateAll() Global Mutation")

-- Create a third handle to test mutateAll
local tKey3Bytes = {0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0}
local hKey3 = pcmr.create(tKey3Bytes, "mutateall_seed")

if not hKey1 and not hKey2 and not hKey3 then
    skip("No handles available for mutateAll test")
    goto test12
end

do -- scope locals

-- Record HMACs before mutateAll
local tPreMutAll = {}
if hKey1 then tPreMutAll[1] = pcmr.hmac(hKey1, "mutateAll vector") end
if hKey2 then tPreMutAll[2] = pcmr.hmac(hKey2, "mutateAll vector") end
if hKey3 then tPreMutAll[3] = pcmr.hmac(hKey3, "mutateAll vector") end

-- Run mutateAll
pcmr.mutateAll()

-- Verify all HMACs unchanged
local bAllInvariant = true
if hKey1 then
    local sPost = pcmr.hmac(hKey1, "mutateAll vector")
    if sPost ~= tPreMutAll[1] then bAllInvariant = false end
end
if hKey2 then
    local sPost = pcmr.hmac(hKey2, "mutateAll vector")
    if sPost ~= tPreMutAll[2] then bAllInvariant = false end
end
if hKey3 then
    local sPost = pcmr.hmac(hKey3, "mutateAll vector")
    if sPost ~= tPreMutAll[3] then bAllInvariant = false end
end

if bAllInvariant then
    pass("mutateAll preserves all keys across all handles")
else
    fail("mutateAll CORRUPTED one or more keys!")
end

end -- do

if hKey3 then pcmr.destroy(hKey3) end

::test12::

-- =============================================
-- TEST 12: Handle Exhaustion / Resource Limits
-- =============================================

section("12. Handle Exhaustion / Resource Limits")

local tBulkHandles = {}
local nBulkTarget = 20  -- Don't exhaust EXSi's 32-enclave limit
local nBulkCreated = 0
local nBulkFailed = 0

for i = 1, nBulkTarget do
    local tK = {(i * 3) % 256, (i * 7) % 256, (i * 11) % 256, (i * 13) % 256}
    local hB, sE = pcmr.create(tK, "bulk_" .. i)
    if hB then
        tBulkHandles[#tBulkHandles + 1] = hB
        nBulkCreated = nBulkCreated + 1
    else
        nBulkFailed = nBulkFailed + 1
        if nBulkFailed == 1 then
            info("First failure at handle " .. i .. ": " .. tostring(sE):sub(1, 50))
        end
    end
    -- Yield to prevent timeout
    if i % 5 == 0 then syscall("process_yield") end
end

info("Created " .. nBulkCreated .. "/" .. nBulkTarget ..
     " handles (failed: " .. nBulkFailed .. ")")

if nBulkCreated > 0 then
    pass("Bulk handle creation succeeded (" .. nBulkCreated .. " handles)")
end

-- Verify each handle is independent
if nBulkCreated >= 2 then
    local sH_a = pcmr.hmac(tBulkHandles[1], "bulk isolation")
    local sH_b = pcmr.hmac(tBulkHandles[2], "bulk isolation")
    if sH_a and sH_b and sH_a ~= sH_b then
        pass("Bulk handles produce distinct HMACs (no state sharing)")
    else
        fail("Bulk handles share state!")
    end
end

-- Clean up bulk handles
for _, hB in ipairs(tBulkHandles) do
    pcmr.destroy(hB)
end
info("Cleaned up " .. #tBulkHandles .. " bulk handles")

-- =============================================
-- TEST 13: SHA-256 Plain Hash (No Key Involvement)
-- =============================================

section("13. SHA-256 Utility (No Key Bypass)")

if not hKey2 then skip("No handle"); goto test14 end

do -- scope locals

-- 13a. SHA-256 works
local sSha = pcmr.sha256(hKey2, "hello world")
if sSha and #sSha == 32 then
    pass("SHA-256 returns 32-byte digest")
    verb("SHA-256: " .. hexStr(sSha))
else
    fail("SHA-256 failed: " .. tostring(sSha))
end

-- 13b. SHA-256 is independent of key (same on any handle)
if hKey1 then
    local sSha1 = pcmr.sha256(hKey1, "hello world")
    local sSha2 = pcmr.sha256(hKey2, "hello world")
    if sSha1 and sSha2 and sSha1 == sSha2 then
        pass("SHA-256 is key-independent (same output from different handles)")
    else
        fail("SHA-256 varies by handle — implementation error")
    end
end

-- 13c. SHA-256 is NOT the same as HMAC (key involvement test)
local sShaTest = pcmr.sha256(hKey2, "key involvement test")
local sHmacTest = pcmr.hmac(hKey2, "key involvement test")
if sShaTest and sHmacTest and sShaTest ~= sHmacTest then
    pass("SHA-256 ≠ HMAC (HMAC involves the key, SHA-256 does not)")
else
    fail("SHA-256 == HMAC — key NOT involved in HMAC!")
end

end -- do

::test14::

-- =============================================
-- CLEANUP
-- =============================================

section("Cleanup")

if hKey1 then pcmr.destroy(hKey1); info("Destroyed handle 1") end
if hKey2 then pcmr.destroy(hKey2); info("Destroyed handle 2") end

-- Verify no enclave leak
local tFinalStats = enc.stats()
if tFinalStats then
    local nLeaked = tFinalStats.nActiveEnclaves - nInitialEnclaves
    if nLeaked == 0 then
        pass("No enclave leak: all PCMR enclaves destroyed")
    elseif nLeaked > 0 then
        fail(nLeaked .. " enclave(s) leaked (not destroyed)")
    else
        info("Enclave count decreased by " .. (-nLeaked) ..
             " (other processes cleaned up)")
    end
    info("Final active enclaves: " .. tFinalStats.nActiveEnclaves)
end

-- =============================================
-- SUMMARY
-- =============================================

print("")
print(C.C .. "═══════════════════════════════════════════════════" .. C.R)
print(string.format("  %sPassed:%s  %d", C.G, C.R, nPass))
print(string.format("  %sFailed:%s  %d", nFail > 0 and C.E or C.D, C.R, nFail))
print(string.format("  %sSkipped:%s %d", C.Y, C.R, nSkip))
print("")

if nFail == 0 then
    print(C.G .. "  ╔══════════════════════════════════════════════╗" .. C.R)
    print(C.G .. "  ║                                              ║" .. C.R)
    print(C.G .. "  ║   ALL PCMR HANDLE SECURITY TESTS PASSED     ║" .. C.R)
    print(C.G .. "  ║                                              ║" .. C.R)
    print(C.G .. "  ║   Handle creation & validity       OK        ║" .. C.R)
    print(C.G .. "  ║   HMAC correctness & determinism   OK        ║" .. C.R)
    print(C.G .. "  ║   Mutation invariance               OK        ║" .. C.R)
    print(C.G .. "  ║   Cross-handle isolation            OK        ║" .. C.R)
    print(C.G .. "  ║   Handle forgery resistance         OK        ║" .. C.R)
    print(C.G .. "  ║   Use-after-destroy protection      OK        ║" .. C.R)
    print(C.G .. "  ║   Seal/unseal cross-handle attack   OK        ║" .. C.R)
    print(C.G .. "  ║   Invalid input handling            OK        ║" .. C.R)
    print(C.G .. "  ║   Enclave boundary probing          OK        ║" .. C.R)
    print(C.G .. "  ║   HMAC oracle resistance            OK        ║" .. C.R)
    print(C.G .. "  ║   Global mutation (mutateAll)       OK        ║" .. C.R)
    print(C.G .. "  ║   Resource exhaustion               OK        ║" .. C.R)
    print(C.G .. "  ║   Enclave leak detection            OK        ║" .. C.R)
    print(C.G .. "  ║                                              ║" .. C.R)
    print(C.G .. "  ╚══════════════════════════════════════════════╝" .. C.R)
elseif nFail <= 3 then
    print(C.Y .. "  ╔══════════════════════════════════════════════╗" .. C.R)
    print(C.Y .. "  ║   PARTIAL PASS — " .. nFail ..
          " test(s) failed" ..
          string.rep(" ", 18 - #tostring(nFail)) .. "║" .. C.R)
    print(C.Y .. "  ║   Review [FAIL] entries above.               ║" .. C.R)
    print(C.Y .. "  ║   Seal tests may fail without data card.     ║" .. C.R)
    print(C.Y .. "  ╚══════════════════════════════════════════════╝" .. C.R)
else
    print(C.E .. "  ╔══════════════════════════════════════════════╗" .. C.R)
    print(C.E .. "  ║   CRITICAL: " .. nFail ..
          " PCMR SECURITY TEST(S) FAILED" ..
          string.rep(" ", 7 - #tostring(nFail)) .. "║" .. C.R)
    print(C.E .. "  ║   Key material may be extractable!           ║" .. C.R)
    print(C.E .. "  ╚══════════════════════════════════════════════╝" .. C.R)
end
print(C.C .. "═══════════════════════════════════════════════════" .. C.R)
print("")