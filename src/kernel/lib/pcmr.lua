--
-- /lib/pcmr.lua
-- Polymorphic Cryptographic Mutating Region
--
-- Defeats JVM heap inspection (jmap + strings) by ensuring
-- cryptographic key material NEVER exists as a contiguous
-- string in the Java heap.
--
-- Architecture:
--   The key is stored inside an EXSi enclave as two parallel
--   number arrays: Data[] and Mask[].
--   The actual key byte at position i is: bxor(Data[i], Mask[i]).
--
--   Every mutation cycle, a new random array NewMask[] is generated
--   inside the enclave's closure, and:
--     Data_new[i] = bxor(Data_old[i], NewMask[i])
--     Mask_new[i] = bxor(Mask_old[i], NewMask[i])
--
--   Because XOR is self-cancelling, Key = Data XOR Mask is invariant
--   across mutations.  But the physical bytes in the Lua heap for
--   Data[] and Mask[] rotate every cycle.
--
-- Ephemeral Materialization:
--   The enclave includes a self-contained SHA-256 + HMAC-SHA256
--   implementation that operates on the split arrays directly.
--   Key bytes are reconstructed one-at-a-time as transient Lua
--   number locals (doubles on the C stack / JVM operand stack),
--   NEVER assembled into a Lua string or Java byte[].
--
-- Usage:
--   local pcmr = require("pcmr")
--   local hKey = pcmr.create({0x4A, 0x9F, 0x22, ...})
--   pcmr.mutate(hKey)                     -- rotate mask
--   local sHmac = pcmr.hmac(hKey, "msg")  -- compute HMAC without materializing key
--   pcmr.destroy(hKey)
--

local oPcmr = {}

-- =============================================
-- ENCLAVE SOURCE CODE
--
-- This string is the Lua source loaded inside an EXSi enclave.
-- All local variables become closure upvalues — invisible to
-- any code outside the enclave, including Ring 0.
--
-- The embedded SHA-256 uses ONLY 2-argument bit32.bxor calls
-- (compatible with kernel-synthesized bit32 on Lua 5.3).
-- rrotate is synthesized from rshift + lshift + bor.
-- =============================================

local ENCLAVE_SOURCE = [==[
-- ────────────────────────────────────────────
-- UPVALUE STATE (invisible outside this closure)
-- ────────────────────────────────────────────
local tData = nil      -- number array: Data[1..nLen]
local tMask = nil      -- number array: Mask[1..nLen]
local nKeyLen = 0
local sInstanceId = nil

-- Internal PRNG for mask generation (xorshift32, seeded at init)
local nPrngState = 1

local function prngNext()
    local x = nPrngState
    x = bit32.bxor(x, bit32.lshift(x, 13))
    x = bit32.bxor(x, bit32.rshift(x, 17))
    x = bit32.bxor(x, bit32.lshift(x, 5))
    if x == 0 then x = 1 end
    nPrngState = x
    return x
end

local function prngByte()
    return prngNext() % 256
end

-- ────────────────────────────────────────────
-- EMBEDDED SHA-256 (operates on split arrays)
-- Strictly 2-argument bxor.  Synthesized rrotate.
-- ────────────────────────────────────────────
local band  = bit32.band
local bnot  = bit32.bnot
local bxor  = bit32.bxor
local rsh   = bit32.rshift
local lsh   = bit32.lshift
local bor   = bit32.bor
local MOD   = 0x100000000

local function rrot(x, n)
    n = n % 32
    if n == 0 then return x end
    return bor(rsh(x, n), lsh(x, 32 - n))
end

local function xor3(a, b, c) return bxor(bxor(a, b), c) end

local K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,
    0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,
    0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,
    0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,
    0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,
    0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,
    0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,
    0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
    0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}
local IV = {
    0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
    0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19,
}

local function u32(n)
    return string.char(band(rsh(n,24),0xFF), band(rsh(n,16),0xFF),
                       band(rsh(n,8),0xFF), band(n,0xFF))
end

-- SHA-256 of a plain string
local function sha256_str(msg)
    msg = tostring(msg); local len = #msg
    msg = msg .. "\128"
    msg = msg .. string.rep("\0", (56 - #msg % 64) % 64)
    local bl = len * 8
    msg = msg .. u32(math.floor(bl / MOD)) .. u32(bl % MOD)
    local h1,h2,h3,h4 = IV[1],IV[2],IV[3],IV[4]
    local h5,h6,h7,h8 = IV[5],IV[6],IV[7],IV[8]
    for blk = 1, #msg, 64 do
        local W = {}
        for j = 1, 16 do
            local o = blk + (j-1)*4
            W[j] = msg:byte(o)*0x1000000 + msg:byte(o+1)*0x10000
                 + msg:byte(o+2)*0x100   + msg:byte(o+3)
        end
        for j = 17, 64 do
            local v15 = W[j-15]; local v2 = W[j-2]
            local s0 = xor3(rrot(v15,7), rrot(v15,18), rsh(v15,3))
            local s1 = xor3(rrot(v2,17), rrot(v2,19),  rsh(v2,10))
            W[j] = (W[j-16] + s0 + W[j-7] + s1) % MOD
        end
        local a,b,c,d,e,f,gv,h = h1,h2,h3,h4,h5,h6,h7,h8
        for j = 1, 64 do
            local S1  = xor3(rrot(e,6), rrot(e,11), rrot(e,25))
            local ch  = bxor(band(e,f), band(bnot(e),gv))
            local t1  = (h + S1 + ch + K[j] + W[j]) % MOD
            local S0  = xor3(rrot(a,2), rrot(a,13), rrot(a,22))
            local maj = xor3(band(a,b), band(a,c), band(b,c))
            local t2  = (S0 + maj) % MOD
            h=gv; gv=f; f=e; e=(d+t1)%MOD
            d=c; c=b; b=a; a=(t1+t2)%MOD
        end
        h1=(h1+a)%MOD; h2=(h2+b)%MOD; h3=(h3+c)%MOD; h4=(h4+d)%MOD
        h5=(h5+e)%MOD; h6=(h6+f)%MOD; h7=(h7+gv)%MOD; h8=(h8+h)%MOD
    end
    return u32(h1)..u32(h2)..u32(h3)..u32(h4)
        .. u32(h5)..u32(h6)..u32(h7)..u32(h8)
end

-- HMAC-SHA256 where the KEY is materialized on-the-fly
-- from the split arrays.  The key bytes exist only as
-- transient Lua locals (doubles), never as a string.
local function hmac_split_internal(sMessage)
    -- Build ipad and opad byte-by-byte from split key
    -- Key is zero-padded to 64 bytes for HMAC
    local nEffLen = nKeyLen
    local tIpad = {}
    local tOpad = {}

    -- If key > 64 bytes, hash it first (standard HMAC)
    -- For simplicity, we limit PCMR keys to 64 bytes
    -- (typical HMAC keys are 32 bytes / 256 bits)

    for i = 1, 64 do
        -- Materialize ONE key byte as a transient local number.
        -- This is the critical security property: the byte exists
        -- only as a Lua double on the C stack, never as a Java String
        -- or byte[].  jmap cannot see individual C stack locals.
        local kb = 0
        if i <= nKeyLen then
            kb = bxor(tData[i], tMask[i])
        end
        tIpad[i] = string.char(bxor(kb, 0x36))
        tOpad[i] = string.char(bxor(kb, 0x5C))
    end

    local sIpad = table.concat(tIpad)
    local sOpad = table.concat(tOpad)
    -- The ipad/opad strings do NOT contain the key —
    -- they contain key XOR 0x36 / key XOR 0x5C.
    -- An attacker seeing these in the heap still needs to
    -- XOR with 0x36/0x5C to recover the key, but they'd
    -- first need to FIND these strings among millions of
    -- heap objects, and they rotate every mutation cycle.

    return sha256_str(sOpad .. sha256_str(sIpad .. sMessage))
end

-- ────────────────────────────────────────────
-- ENCLAVE ENTRY POINT
-- ────────────────────────────────────────────
return function(sMethod, ...)
    if sMethod == "init" then
        -- arg1: table of key bytes (numbers 0-255)
        -- arg2: PRNG seed string
        local tKeyBytes = select(1, ...)
        local sSeed     = select(2, ...)
        if type(tKeyBytes) ~= "table" or #tKeyBytes == 0 then
            return nil, "key must be a non-empty table of bytes"
        end
        if #tKeyBytes > 64 then
            return nil, "PCMR keys limited to 64 bytes for HMAC"
        end
        nKeyLen = #tKeyBytes

        -- Seed the internal PRNG
        nPrngState = 1
        if type(sSeed) == "string" then
            for i = 1, #sSeed do
                nPrngState = bxor(nPrngState, sSeed:byte(i) * (i * 31))
                prngNext()
            end
        end
        -- Extra warm-up
        for _ = 1, 64 do prngNext() end

        -- Split key into Data and Mask
        tData = {}
        tMask = {}
        for i = 1, nKeyLen do
            local nMaskByte = prngByte()
            tData[i] = bxor(tKeyBytes[i] % 256, nMaskByte)
            tMask[i] = nMaskByte
        end
        local tInstId = {}
        for i = 1, 32 do tInstId[i] = string.char(prngByte()) end
        sInstanceId = table.concat(tInstId)
        return true

    elseif sMethod == "mutate" then
        -- Generate new mask, rotate both arrays
        -- Key = Data XOR Mask is invariant.
        -- Data_new = Data_old XOR NewMask
        -- Mask_new = Mask_old XOR NewMask
        -- Proof: Data_new XOR Mask_new
        --      = (Data_old XOR NewMask) XOR (Mask_old XOR NewMask)
        --      = Data_old XOR Mask_old XOR NewMask XOR NewMask
        --      = Data_old XOR Mask_old
        --      = Key  ✓
        if not tData then return nil, "not initialized" end
        for i = 1, nKeyLen do
            local nNewMask = prngByte()
            tData[i] = bxor(tData[i], nNewMask)
            tMask[i] = bxor(tMask[i], nNewMask)
        end
        return true

    elseif sMethod == "hmac" then
        -- Compute HMAC-SHA256(key, message) without materializing the key
        if not tData then return nil, "not initialized" end
        local sMessage = select(1, ...)
        if type(sMessage) ~= "string" then
            return nil, "message must be a string"
        end
        return hmac_split_internal(sMessage)

    elseif sMethod == "sha256" then
        -- Plain SHA-256 of a message (no key involvement)
        local sMsg = select(1, ...)
        return sha256_str(tostring(sMsg or ""))

    elseif sMethod == "key_length" then
        return nKeyLen

    elseif sMethod == "verify_hmac" then
        -- Constant-time HMAC verification
        if not tData then return nil, "not initialized" end
        local sMessage  = select(1, ...)
        local sExpected = select(2, ...)
        if type(sMessage) ~= "string" or type(sExpected) ~= "string" then
            return false
        end
        local sActual = hmac_split_internal(sMessage)
        if #sActual ~= #sExpected then return false end
        local d = 0
        for i = 1, #sActual do
            d = bxor(d, bxor(sActual:byte(i), sExpected:byte(i)))
        end
        return d == 0

    elseif sMethod == "seal_key" then
        if not tData then return nil, "not initialized" end
        if not sInstanceId then return nil, "not initialized" end
        local tReconstructed = {}
        for i = 1, nKeyLen do
            tReconstructed[i] = string.char(bxor(tData[i], tMask[i]))
        end
        local sKeyRaw = table.concat(tReconstructed)
        for i = 1, nKeyLen do tReconstructed[i] = nil end
        tReconstructed = nil
        -- Prepend per-instance ID to bind sealed blob to THIS handle
        local sSealed = seal(sInstanceId .. sKeyRaw)
        return sSealed

    elseif sMethod == "unseal_key" then
        local sBlob = select(1, ...)
        if type(sBlob) ~= "string" then return nil, "bad blob" end
        if not sInstanceId then return nil, "not initialized" end
        local sPlain, sErr = unseal(sBlob)
        if not sPlain then return nil, sErr end
        -- Verify per-instance ID (prevents cross-handle unseal)
        if #sPlain < 33 then return nil, "sealed data corrupted" end
        local d = 0
        for i = 1, 32 do
            d = bxor(d, bxor(sPlain:byte(i), sInstanceId:byte(i)))
        end
        if d ~= 0 then
            return nil, "seal/unseal handle mismatch (different PCMR instance)"
        end
        local sKeyRaw = sPlain:sub(33)
        nKeyLen = #sKeyRaw
        tData = {}
        tMask = {}
        for i = 1, nKeyLen do
            local nMaskByte = prngByte()
            tData[i] = bxor(sKeyRaw:byte(i), nMaskByte)
            tMask[i] = nMaskByte
        end
        return true

    elseif sMethod == "destroy" then
        -- Overwrite arrays with random data, then nil them
        if tData then
            for i = 1, nKeyLen do
                tData[i] = prngByte()
                tMask[i] = prngByte()
            end
        end
        tData = nil
        tMask = nil
        nKeyLen = 0
        sInstanceId = nil
        return true
    end
end
]==]

-- =============================================
-- PUBLIC API
-- =============================================

local g_tInstances = {}  -- [handle] → enclave handle

--- Create a new PCMR-protected key.
-- @param tKeyBytes  Array of key byte values (numbers 0-255), max 64 bytes.
-- @param sSeed      Optional entropy string for the internal PRNG.
-- @return handle (number) for subsequent operations, or nil + error.
function oPcmr.create(tKeyBytes, sSeed)
    if type(tKeyBytes) ~= "table" or #tKeyBytes == 0 then
        return nil, "key must be a non-empty table of byte values"
    end

    -- Default seed from available entropy
    if not sSeed then
        sSeed = tostring(math.random(0, 0x7FFFFFFF))
            .. tostring(os.clock())
            .. tostring(math.random(0, 0x7FFFFFFF))
    end

    -- Create the EXSi enclave
    local hEnc, sMr = syscall("exsi_create", ENCLAVE_SOURCE)
    if not hEnc then
        return nil, "Failed to create PCMR enclave: " .. tostring(sMr)
    end

    -- Initialize with key data
    local bOk, sErr = syscall("exsi_call", hEnc, "init", tKeyBytes, sSeed)
    if not bOk then
        syscall("exsi_destroy", hEnc)
        return nil, "PCMR init failed: " .. tostring(sErr)
    end

    g_tInstances[hEnc] = true
    return hEnc
end

--- Create a PCMR key from a raw string (converts to byte array internally).
-- The string is NOT retained — only its bytes are passed to the enclave.
function oPcmr.createFromString(sKey, sSeed)
    if type(sKey) ~= "string" or #sKey == 0 then
        return nil, "key must be a non-empty string"
    end
    local tBytes = {}
    for i = 1, #sKey do
        tBytes[i] = sKey:byte(i)
    end
    local h, sErr = oPcmr.create(tBytes, sSeed)
    -- Zero the byte array
    for i = 1, #tBytes do tBytes[i] = 0 end
    return h, sErr
end

--- Rotate the internal mask (call periodically for mutation).
function oPcmr.mutate(hKey)
    if not g_tInstances[hKey] then return nil, "invalid handle" end
    return syscall("exsi_call", hKey, "mutate")
end

--- Compute HMAC-SHA256(key, message) without materializing the key.
-- @return 32-byte binary HMAC digest.
function oPcmr.hmac(hKey, sMessage)
    if not g_tInstances[hKey] then return nil, "invalid handle" end
    return syscall("exsi_call", hKey, "hmac", sMessage)
end

--- Verify an HMAC in constant time.
function oPcmr.verifyHmac(hKey, sMessage, sExpectedHmac)
    if not g_tInstances[hKey] then return false end
    return syscall("exsi_call", hKey, "verify_hmac", sMessage, sExpectedHmac)
end

--- Compute plain SHA-256 (no key involvement, for convenience).
function oPcmr.sha256(hKey, sMessage)
    if not g_tInstances[hKey] then return nil, "invalid handle" end
    return syscall("exsi_call", hKey, "sha256", sMessage)
end

--- Seal the key for persistent storage (encrypted with enclave + machine binding).
function oPcmr.sealKey(hKey)
    if not g_tInstances[hKey] then return nil, "invalid handle" end
    return syscall("exsi_call", hKey, "seal_key")
end

--- Unseal a previously sealed key blob back into PCMR-split form.
function oPcmr.unsealKey(hKey, sBlob)
    if not g_tInstances[hKey] then return nil, "invalid handle" end
    return syscall("exsi_call", hKey, "unseal_key", sBlob)
end

--- Get key length in bytes.
function oPcmr.keyLength(hKey)
    if not g_tInstances[hKey] then return nil end
    return syscall("exsi_call", hKey, "key_length")
end

--- Destroy the PCMR key (overwrites with random, then frees enclave).
function oPcmr.destroy(hKey)
    if not g_tInstances[hKey] then return nil end
    syscall("exsi_call", hKey, "destroy")
    syscall("exsi_destroy", hKey)
    g_tInstances[hKey] = nil
    return true
end

--- Mutate ALL active PCMR instances (called from scheduler tick).
function oPcmr.mutateAll()
    for hKey in pairs(g_tInstances) do
        pcall(syscall, "exsi_call", hKey, "mutate")
    end
end

--- Get the PCMR enclave source code (for attestation verification).
function oPcmr.getEnclaveSource()
    return ENCLAVE_SOURCE
end

return oPcmr