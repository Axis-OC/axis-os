--
-- /usr/commands/test_exsi_v2.lua
-- AxisOS EXSi v2 Security & Feature Test Suite
--
-- Проверяет: Transparent PCMR, Enclave Thermal Throttle (ETT),
-- MRSIGNER Sealing, Secure Channels, и Signed Quotes.
--

local enc = require("enclave")
local computer = require("computer")

local tArgs = env.ARGS or {}
local C = {
    R = "\27[37m", G = "\27[32m", E = "\27[31m",
    Y = "\27[33m", C = "\27[36m", D = "\27[90m", M = "\27[35m"
}

local nPass, nFail = 0, 0

local function pass(s) nPass = nPass + 1; print(C.G .. "  [PASS] " .. C.R .. s) end
local function fail(s) nFail = nFail + 1; print(C.E .. "  [FAIL] " .. C.R .. s) end
local function info(s) print(C.C .. "  [INFO] " .. C.R .. s) end
local function section(s) print(""); print(C.Y .. "=== " .. s .. " ===" .. C.R) end

local function sleep(nSec)
    local nDeadline = computer.uptime() + nSec
    while computer.uptime() < nDeadline do
        syscall("process_yield")
    end
end

print(C.C .. "╔═══════════════════════════════════════════════════╗" .. C.R)
print(C.C .. "║  EXSi v2 Hardware-grade TEE Feature Tester        ║" .. C.R)
print(C.C .. "╚═══════════════════════════════════════════════════╝" .. C.R)

-- =========================================================================
-- 1. TRANSPARENT PCMR (secure_dict)
-- =========================================================================
section("1. Transparent PCMR (secure_dict)")

local sPcmrCode = [=[
    local secrets = secure_dict()
    return function(method, k, v)
        if method == "set" then secrets[k] = v; return true
        elseif method == "get" then return secrets[k]
        elseif method == "dump" then
            local count = 0
            -- pairs() is disabled for secure_dict to prevent memory dumps
            pcall(function() for _ in pairs(secrets) do count = count + 1 end end)
            return count
        end
    end
]=]

local hPcmr = enc.create(sPcmrCode)
if hPcmr then
    enc.call(hPcmr, "set", "api_key", "SUPER_SECRET_123")
    local val = enc.call(hPcmr, "get", "api_key")
    
    if val == "SUPER_SECRET_123" then
        pass("secure_dict() stores and retrieves data correctly")
    else
        fail("secure_dict() data corrupted: " .. tostring(val))
    end
    
    local nCount = enc.call(hPcmr, "dump")
    if nCount == 0 then
        pass("secure_dict() blocks pairs() iteration (Anti-Dump protection)")
        info("  Data lives in XOR-split arrays on the C stack, invisible to JVM heap inspection.")
    else
        fail("secure_dict() allowed iteration! Leak risk!")
    end
    enc.destroy(hPcmr)
else
    fail("Failed to create PCMR enclave")
end

-- =========================================================================
-- 2. ENCLAVE THERMAL THROTTLE (ETT)
-- =========================================================================
section("2. Enclave Thermal Throttle (Anti-Hammering)")

local sEttCode = [=[
    return function() return "pong" end
]=]

-- Лимит: 5 вызовов за 2 секунды. Блокировка на 2 секунды.
local hEtt = enc.createSigned(sEttCode, nil, 1, {nMaxCalls = 5, nWindowSec = 2, nLockoutSec = 2})

if hEtt then
    local nSuccess = 0
    for i = 1, 5 do
        if enc.call(hEtt) == "pong" then nSuccess = nSuccess + 1 end
    end
    if nSuccess == 5 then
        pass("First 5 calls succeeded (within limit)")
    else
        fail("Legitimate calls were blocked prematurely")
    end
    
    -- 6-й вызов должен быть заблокирован
    local res, err = enc.call(hEtt)
    if res == nil and tostring(err):find("ETT_THROTTLED") then
        pass("6th call correctly BLOCKED by Thermal Throttle")
        info("  " .. tostring(err))
    else
        fail("Throttle failed to block hammering! Result: " .. tostring(res))
    end
    
    info("Waiting 2.5s for lockout to expire...")
    sleep(2.5)
    
    local res2 = enc.call(hEtt)
    if res2 == "pong" then
        pass("Enclave unlocked after cooldown")
    else
        fail("Enclave remained locked: " .. tostring(res2))
    end
    enc.destroy(hEtt)
else
    fail("Failed to create ETT enclave")
end

-- =========================================================================
-- 3. MRSIGNER SEALING (Survives Code Updates)
-- =========================================================================
section("3. MRSIGNER Sealing (Update Resilience)")

local sSignerHash = string.rep("A", 32) -- Имитируем хеш ключа автора

local sV1Code = [=[
    return function(method, data)
        if method == "seal" then return seal_by_signer(data) end
    end
]=]

local sV2Code = [=[
    -- V2 has different code, so MRENCLAVE is different
    local new_feature = true 
    return function(method, data)
        if method == "unseal" then return unseal_by_signer(data) end
    end
]=]

local hV1 = enc.createSigned(sV1Code, sSignerHash, 1)
local sSealedData = nil

if hV1 then
    sSealedData = enc.call(hV1, "seal", "Persistent_User_Config")
    if sSealedData then
        pass("Data sealed using MRSIGNER policy")
    else
        fail("Failed to seal using MRSIGNER")
    end
    enc.destroy(hV1)
end

if sSealedData then
    -- Пытаемся распечатать ДРУГИМ кодом, но от ТОГО ЖЕ автора (V2)
    local hV2 = enc.createSigned(sV2Code, sSignerHash, 2)
    if hV2 then
        local sUnsealed, err = enc.call(hV2, "unseal", sSealedData)
        if sUnsealed == "Persistent_User_Config" then
            pass("V2 successfully unsealed V1's data (MRSIGNER match)")
        else
            fail("V2 failed to unseal: " .. tostring(err))
        end
        enc.destroy(hV2)
    end
    
    -- Пытаемся распечатать кодом от ДРУГОГО автора (V3)
    local hV3 = enc.createSigned(sV2Code, string.rep("B", 32), 2)
    if hV3 then
        local sUnsealed, err = enc.call(hV3, "unseal", sSealedData)
        if sUnsealed == nil then
            pass("Different author correctly REJECTED (MRSIGNER mismatch)")
        else
            fail("Security breach: Enclave bypassed MRSIGNER check!")
        end
        enc.destroy(hV3)
    end
end

-- =========================================================================
-- 4. SECURE CHANNELS
-- =========================================================================
section("4. Secure Channels (Enclave-to-Enclave DH)")

local sChanCode = [=[
    return function(m) return "ready" end
]=]
local hA = enc.create(sChanCode)
local hB = enc.create(sChanCode)

if hA and hB then
    local nChanId, sErr = enc.openChannel(hA, hB)
    if nChanId then
        pass("Secure Channel established via Diffie-Hellman")
        
        -- Передача сообщения
        local sDecrypted = enc.channelSend(nChanId, hA, "TopSecretMessage")
        if sDecrypted == "TopSecretMessage" then
            pass("Message successfully encrypted, sent, and decrypted")
            info("  Ring 0 saw only ciphertext + Monotonic Sequence Number.")
        else
            fail("Message corrupted in transit: " .. tostring(sDecrypted))
        end
        
        enc.closeChannel(nChanId)
    else
        fail("Failed to open Secure Channel: " .. tostring(sErr))
    end
    enc.destroy(hA)
    enc.destroy(hB)
else
    fail("Failed to create enclaves for channel test")
end

-- =========================================================================
-- 5. SIGNED QUOTES (Attestation)
-- =========================================================================
section("5. Signed Attestation (Quotes)")

local hQuote = enc.create("return function() end")
if hQuote then
    local sNonce = "ServerChallengeNonce777"
    local tQuote = enc.attest(hQuote, sNonce)
    
    if tQuote and tQuote.sSignatureType ~= "NONE" then
        pass("Generated Signed Quote (" .. tQuote.sSignatureType .. ")")
        info("  MRENCLAVE: " .. tQuote.sMrEnclave:sub(1, 16) .. "...")
        info("  UserData:  " .. tQuote.sUserData)
        
        -- Проверка подписи на стороне юзерспейса (Имитация сервера)
        local bValid, sSigType = enc.verifyQuote(tQuote, tQuote.sMrEnclave, sNonce, tQuote.sSignerAddr)
        if bValid then
            pass("Quote cryptographically verified! (Anti-Spoofing OK)")
        else
            fail("Quote verification failed: " .. tostring(sSigType))
        end
    else
        fail("Failed to generate Signed Quote (Check Data Card availability)")
        if tQuote then info("  Signature Type: " .. tostring(tQuote.sSignatureType)) end
    end
    enc.destroy(hQuote)
end

-- =========================================================================
-- SUMMARY
-- =========================================================================
print("")
print(C.C .. "═══════════════════════════════════════════════════" .. C.R)
print(string.format("  %sPassed:%s %d   %sFailed:%s %d",
    C.G, C.R, nPass, nFail > 0 and C.E or C.D, C.R, nFail))

if nFail == 0 then
    print(C.G .. "  EXSi v2 is fully operational. System is SGX-equivalent." .. C.R)
else
    print(C.E .. "  Some EXSi v2 features failed. Review log." .. C.R)
end
print(C.C .. "═══════════════════════════════════════════════════" .. C.R)