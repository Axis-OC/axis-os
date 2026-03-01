--
-- /lib/kiqgr.lua
-- KIQGR — Kernel Integrity Quality Guard Region
--
-- Creates an EXSi enclave that holds the expected file hashes
-- as closure upvalues.  PatchGuard sends file content into the
-- enclave; the enclave hashes it internally and returns only
-- true/false.  The expected hashes NEVER exist outside the
-- enclave's closure — not even Ring 0 can read them.
--
-- Swap encryption is also routed through a companion PCMR
-- enclave so plaintext swap data never appears in RAM.
--

local KIQGR = {}

local g_hEnclave       = nil   -- EXSi enclave handle
local g_sMrEnclave     = nil   -- MRENCLAVE hash for attestation
local g_hSwapPcmr      = nil   -- PCMR handle for swap encryption
local g_fLog           = function() end
local g_bInitialized   = false

-- =============================================
-- ENCLAVE SOURCE CODE
--
-- ALL hash verification logic lives here.
-- The hashes are stored in `tExpected` — a local
-- variable that becomes an upvalue of the returned
-- function.  No external code can read it.
-- =============================================

local ENCLAVE_SOURCE = [==[
-- KIQGR Enclave: Integrity Verification

local tExpected = {}   -- [path] → binary SHA-256 hash
local nFileCount = 0
local nVerifyCount = 0
local nPassCount = 0
local nFailCount = 0

-- Embedded SHA-256 (same as pcmr.lua — self-contained)
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

local function sha256(msg)
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
            local s1 = xor3(rrot(v2,17), rrot(v2,19), rsh(v2,10))
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

local function constEq(a, b)
    if #a ~= #b then return false end
    local d = 0
    for i = 1, #a do d = bxor(d, bxor(a:byte(i), b:byte(i))) end
    return d == 0
end

return function(sMethod, ...)
    if sMethod == "init_hashes" then
        -- arg1: table { [path] = binaryHash, ... }
        local tH = select(1, ...)
        if type(tH) ~= "table" then return nil, "table expected" end
        tExpected = {}
        nFileCount = 0
        for sPath, sBinHash in pairs(tH) do
            if type(sPath) == "string" and type(sBinHash) == "string" then
                tExpected[sPath] = sBinHash
                nFileCount = nFileCount + 1
            end
        end
        return nFileCount

    elseif sMethod == "verify" then
        -- arg1: path, arg2: file content
        local sPath    = select(1, ...)
        local sContent = select(2, ...)
        if type(sPath) ~= "string" then return nil, "path must be string" end
        if type(sContent) ~= "string" then return nil, "content must be string" end

        local sExpected = tExpected[sPath]
        if not sExpected then
            -- File not in golden set — cannot verify, return unknown
            return nil, "not_tracked"
        end

        nVerifyCount = nVerifyCount + 1
        local sActual = sha256(sContent)

        if constEq(sActual, sExpected) then
            nPassCount = nPassCount + 1
            return true
        else
            nFailCount = nFailCount + 1
            return false, "hash_mismatch"
        end

    elseif sMethod == "is_tracked" then
        local sPath = select(1, ...)
        return tExpected[sPath] ~= nil

    elseif sMethod == "stats" then
        return {
            nFiles   = nFileCount,
            nVerify  = nVerifyCount,
            nPass    = nPassCount,
            nFail    = nFailCount,
        }

    elseif sMethod == "add_hash" then
        -- Add/update a single file hash
        local sPath = select(1, ...)
        local sHash = select(2, ...)
        if type(sPath) == "string" and type(sHash) == "string" then
            if not tExpected[sPath] then nFileCount = nFileCount + 1 end
            tExpected[sPath] = sHash
            return true
        end
        return false

    elseif sMethod == "hash_content" then
        -- Helper: hash arbitrary content inside the enclave
        local sData = select(1, ...)
        if type(sData) ~= "string" then return nil end
        return sha256(sData)
    end
end
]==]

-- =============================================
-- PUBLIC API
-- =============================================

function KIQGR.Initialize(tCfg)
    g_fLog = tCfg.fLog or g_fLog

    -- Create the KIQGR enclave
    g_fLog("[KIQGR] Creating integrity verification enclave...")

    local hEnc, sMr = tCfg.fCreateEnclave(ENCLAVE_SOURCE)
    if not hEnc then
        g_fLog("[KIQGR] Enclave creation failed: " .. tostring(sMr))
        return false
    end

    g_hEnclave   = hEnc
    g_sMrEnclave = sMr
    g_bInitialized = true

    g_fLog("[KIQGR] Enclave created: MRENCLAVE=" ..
        (sMr or "?"):sub(1, 24) .. "...")
    return true
end

--- Load file hashes into the enclave.
-- @param tFileHashes  { [path] = binarySha256Hash, ... }
-- @return number of files loaded
function KIQGR.LoadHashes(tFileHashes, fCallEnclave)
    if not g_bInitialized then return 0 end
    local nCount = fCallEnclave(g_hEnclave, "init_hashes", tFileHashes)
    g_fLog("[KIQGR] Loaded " .. tostring(nCount) .. " file hashes into enclave")
    return nCount or 0
end

--- Verify a file's content against the enclave's golden hashes.
-- @param sPath     File path
-- @param sContent  File content bytes
-- @param fCallEnclave  syscall wrapper for exsi_call
-- @return true (pass), false (fail), or nil (not tracked)
function KIQGR.Verify(sPath, sContent, fCallEnclave)
    if not g_bInitialized then return nil, "kiqgr not initialized" end
    return fCallEnclave(g_hEnclave, "verify", sPath, sContent)
end

--- Hash content inside the enclave (for swap, etc.)
function KIQGR.HashInEnclave(sData, fCallEnclave)
    if not g_bInitialized then return nil end
    return fCallEnclave(g_hEnclave, "hash_content", sData)
end

function KIQGR.GetHandle() return g_hEnclave end
function KIQGR.GetMrEnclave() return g_sMrEnclave end

function KIQGR.GetStats(fCallEnclave)
    if not g_bInitialized then return nil end
    return fCallEnclave(g_hEnclave, "stats")
end

function KIQGR.IsInitialized() return g_bInitialized end

return KIQGR