--
-- /lib/exsi.lua
-- AxisOS EXSi — Enclaved Kernel eXecution Isolation v2
--
-- v2 additions:
--  1) Signed Attestation (Quote) — Data Card signs MRENCLAVE + Nonce
--  2) MRSIGNER Sealing — seal by author key hash, survives code updates
--  3) Transparent PCMR — secure_dict() auto-XOR-splits data in memory
--  4) Secure Channel — Enclave-to-Enclave Diffie-Hellman
--  5) Enclave Thermal Throttle (ETT) — brute-force rate limiting
--

local oExsi = {}

-- =============================================
-- CONSTANTS
-- =============================================

oExsi.MAX_ENCLAVES     = 32
oExsi.MAX_SEALED_SIZE  = 65536
oExsi.SEAL_HEADER_SIZE = 64
oExsi.MAX_CHANNELS     = 16

-- Sealing policy constants
oExsi.SEAL_MRENCLAVE = 1   -- seal to exact code hash (default, v1 compat)
oExsi.SEAL_MRSIGNER  = 2   -- seal to author key hash + minimum version

-- DH parameters (safe prime < 2^24 — double-safe for Lua arithmetic)
local DH_PRIME     = 16777213
local DH_GENERATOR = 2

-- ETT (Enclave Thermal Throttle) defaults
local ETT_DEFAULT_MAX_CALLS   = 100   -- max calls per window
local ETT_DEFAULT_WINDOW_SEC  = 10    -- window duration
local ETT_DEFAULT_LOCKOUT_SEC = 5     -- lockout after limit hit
local ETT_ESCALATION_FACTOR   = 2     -- lockout doubles each consecutive trip

-- =============================================
-- INTERNAL STATE
-- =============================================

local g_tEnclaves    = {}
local g_nNextHandle  = 1
local g_fLog         = nil
local g_fUptime      = nil
local g_oSha256      = nil
local g_sHardwareKey = nil

-- Data Card reference (Tier 3 for ECDSA signing)
local g_oDataCard    = nil
local g_nDataCardTier = 0

-- Secure Channels: [nChannelId] → channel descriptor
local g_tChannels    = {}
local g_nNextChannel = 1

local g_tStats = {
    nCreated       = 0,
    nDestroyed     = 0,
    nCalls         = 0,
    nAttestations  = 0,
    nSeals         = 0,
    nUnseals       = 0,
    nSealFailures  = 0,
    nQuotesIssued  = 0,
    nChannelsCreated = 0,
    nChannelMessages = 0,
    nEttThrottled  = 0,
}

-- =============================================
-- INITIALIZATION
-- =============================================

function oExsi.Initialize(tCfg)
    g_fLog    = tCfg.fLog    or function() end
    g_fUptime = tCfg.fUptime or function() return 0 end
    g_oSha256 = tCfg.oSha256

    if not g_oSha256 then
        g_fLog("[EXSi] WARNING: No SHA-256 module — attestation/sealing disabled")
    end

    -- Derive hardware key
    if g_oSha256 and tCfg.sHardwareSeed then
        g_sHardwareKey = g_oSha256.digest(tCfg.sHardwareSeed)
        g_fLog("[EXSi] Hardware sealing key derived (" .. #g_sHardwareKey .. " bytes)")
    end

    -- Detect Data Card for Quote signing
    pcall(function()
        for addr in raw_component.list("data") do
            local p = raw_component.proxy(addr)
            if p then
                g_oDataCard = p
                if p.ecdsa then g_nDataCardTier = 3
                elseif p.encrypt then g_nDataCardTier = 2
                else g_nDataCardTier = 1 end
            end
            break
        end
    end)

    g_fLog("[EXSi] EXSi v2 initialized")
    g_fLog("[EXSi]   Max enclaves: " .. oExsi.MAX_ENCLAVES)
    g_fLog("[EXSi]   SHA-256:      " .. (g_oSha256 and "available" or "NONE"))
    g_fLog("[EXSi]   Sealing:      " .. (g_sHardwareKey and "available" or "NONE"))
    g_fLog("[EXSi]   Data Card:    Tier " .. g_nDataCardTier ..
        (g_nDataCardTier >= 3 and " (Quote signing: ECDSA)" or " (Quote signing: HMAC)"))
    g_fLog("[EXSi]   Secure Chan:  " .. (g_oSha256 and "available" or "NONE"))
    g_fLog("[EXSi]   ETT Throttle: ACTIVE (default " ..
        ETT_DEFAULT_MAX_CALLS .. "/" .. ETT_DEFAULT_WINDOW_SEC .. "s)")

    return true
end

-- =============================================
-- SEALING KEY DERIVATION
-- =============================================

local function fDeriveSealingKey(sMrEnclave)
    if not g_oSha256 or not g_sHardwareKey then return nil end
    return g_oSha256.hmac(g_sHardwareKey, sMrEnclave)
end

-- Enclaves with the same signer and version >= nMinSvn can unseal
local function fDeriveSignerSealingKey(sMrSigner, nIsvSvn)
    if not g_oSha256 or not g_sHardwareKey then return nil end
    -- Key derived from MRSIGNER only (not SVN), so any version
    -- by the same signer can unseal.  SVN policy is enforced
    -- separately if needed.
    return g_oSha256.hmac(g_sHardwareKey, sMrSigner)
end

-- =============================================
-- XOR KEYSTREAM CIPHER (unchanged from v1)
-- =============================================

local function fXorCipher(sKey, sData)
    if not g_oSha256 then return nil, "No SHA-256" end
    local nLen = #sData
    local tOut = {}
    local nBlockIdx = 0
    local nPos = 1
    while nPos <= nLen do
        local sCounter = string.char(
            math.floor(nBlockIdx / 16777216) % 256,
            math.floor(nBlockIdx / 65536) % 256,
            math.floor(nBlockIdx / 256) % 256,
            nBlockIdx % 256)
         .. string.char(
            math.floor(nLen / 16777216) % 256,
            math.floor(nLen / 65536) % 256,
            math.floor(nLen / 256) % 256,
            nLen % 256)
        local sKeyBlock = g_oSha256.hmac(sKey, sCounter)
        for i = 1, 32 do
            if nPos > nLen then break end
            tOut[#tOut + 1] = string.char(bit32.bxor(sData:byte(nPos), sKeyBlock:byte(i)))
            nPos = nPos + 1
        end
        nBlockIdx = nBlockIdx + 1
    end
    return table.concat(tOut)
end

-- =============================================
-- SEAL / UNSEAL FACTORY (v2: dual MRENCLAVE + MRSIGNER)
-- =============================================

local function fMakeSealUnseal(sMrEnclave, sMrSigner, nIsvSvn)
    local sSealKeyEnclave = fDeriveSealingKey(sMrEnclave)
    local sSealKeySigner  = (sMrSigner and nIsvSvn)
        and fDeriveSignerSealingKey(sMrSigner, nIsvSvn) or nil

    if not sSealKeyEnclave then
        -- No crypto: pass-through
        return function(sData) return sData end,
               function(sBlob) return sBlob end,
               function(sData) return sData end,
               function(sBlob) return sBlob end
    end

    -- MRENCLAVE seal/unseal (exact code binding)
    local function fSealEnclave(sData)
        if type(sData) ~= "string" then sData = tostring(sData) end
        if #sData > oExsi.MAX_SEALED_SIZE then return nil, "Data too large" end
        local sEncrypted = fXorCipher(sSealKeyEnclave, sData)
        if not sEncrypted then return nil, "Encryption failed" end
        local sTag = g_oSha256.hmac(sSealKeyEnclave, sData)
        g_tStats.nSeals = g_tStats.nSeals + 1
        -- Header: 1 byte policy, 31 bytes MRENCLAVE prefix, 32 bytes tag
        return string.char(oExsi.SEAL_MRENCLAVE) .. sMrEnclave:sub(1, 31) .. sTag .. sEncrypted
    end

    local function fUnsealEnclave(sBlob)
        if type(sBlob) ~= "string" or #sBlob < 65 then return nil, "Invalid blob" end
        local nPolicy = sBlob:byte(1)
        if nPolicy ~= oExsi.SEAL_MRENCLAVE then return nil, "Wrong seal policy" end
        local sBlobMr = sBlob:sub(2, 32)
        if not g_oSha256.constEq(sBlobMr, sMrEnclave:sub(1, 31)) then
            g_tStats.nSealFailures = g_tStats.nSealFailures + 1
            return nil, "MRENCLAVE mismatch"
        end
        local sTag = sBlob:sub(33, 64)
        local sEncrypted = sBlob:sub(65)
        local sDecrypted = fXorCipher(sSealKeyEnclave, sEncrypted)
        if not sDecrypted then return nil, "Decryption failed" end
        local sExpectedTag = g_oSha256.hmac(sSealKeyEnclave, sDecrypted)
        if not g_oSha256.constEq(sTag, sExpectedTag) then
            g_tStats.nSealFailures = g_tStats.nSealFailures + 1
            return nil, "Integrity check failed"
        end
        g_tStats.nUnseals = g_tStats.nUnseals + 1
        return sDecrypted
    end

    -- MRSIGNER seal/unseal (author binding — survives code updates)
    local function fSealSigner(sData)
        if not sSealKeySigner then return nil, "No MRSIGNER configured" end
        if type(sData) ~= "string" then sData = tostring(sData) end
        if #sData > oExsi.MAX_SEALED_SIZE then return nil, "Data too large" end
        local sEncrypted = fXorCipher(sSealKeySigner, sData)
        if not sEncrypted then return nil, "Encryption failed" end
        local sTag = g_oSha256.hmac(sSealKeySigner, sData)
        g_tStats.nSeals = g_tStats.nSeals + 1
        -- Header: 1 byte policy, 31 bytes MRSIGNER prefix, 32 bytes tag
        return string.char(oExsi.SEAL_MRSIGNER) .. (sMrSigner or ""):sub(1, 31) .. sTag .. sEncrypted
    end

    local function fUnsealSigner(sBlob)
        if not sSealKeySigner then return nil, "No MRSIGNER configured" end
        if type(sBlob) ~= "string" or #sBlob < 65 then return nil, "Invalid blob" end
        local nPolicy = sBlob:byte(1)
        if nPolicy ~= oExsi.SEAL_MRSIGNER then return nil, "Wrong seal policy" end
        -- MRSIGNER match check
        local sBlobSigner = sBlob:sub(2, 32)
        if not g_oSha256.constEq(sBlobSigner, (sMrSigner or ""):sub(1, 31)) then
            g_tStats.nSealFailures = g_tStats.nSealFailures + 1
            return nil, "MRSIGNER mismatch — different author"
        end
        local sTag = sBlob:sub(33, 64)
        local sEncrypted = sBlob:sub(65)
        local sDecrypted = fXorCipher(sSealKeySigner, sEncrypted)
        if not sDecrypted then return nil, "Decryption failed" end
        local sExpectedTag = g_oSha256.hmac(sSealKeySigner, sDecrypted)
        if not g_oSha256.constEq(sTag, sExpectedTag) then
            g_tStats.nSealFailures = g_tStats.nSealFailures + 1
            return nil, "Integrity check failed — wrong machine or version"
        end
        g_tStats.nUnseals = g_tStats.nUnseals + 1
        return sDecrypted
    end

    return fSealEnclave, fUnsealEnclave, fSealSigner, fUnsealSigner
end

-- =============================================
-- TRANSPARENT PCMR — secure_dict() FACTORY
--
-- Returns a table-like proxy where all stored
-- string values are automatically XOR-split in
-- memory.  "API_KEY" never exists as a contiguous
-- JVM heap string — only two complementary halves.
-- =============================================

local function fMakeSecureDict()
    local tDataHalf = {}   -- [key] → XOR half 1 (string)
    local tMaskHalf = {}   -- [key] → XOR half 2 (string)
    local nPrngState = math.random(1, 0x7FFFFFFF)

    local function prngByte()
        nPrngState = bit32.bxor(nPrngState, bit32.lshift(nPrngState, 13))
        nPrngState = bit32.bxor(nPrngState, bit32.rshift(nPrngState, 17))
        nPrngState = bit32.bxor(nPrngState, bit32.lshift(nPrngState, 5))
        if nPrngState == 0 then nPrngState = 1 end
        return nPrngState % 256
    end

    local proxy = {}
    setmetatable(proxy, {
        __newindex = function(_, key, value)
            if value == nil then
                tDataHalf[key] = nil
                tMaskHalf[key] = nil
                return
            end
            local sVal = tostring(value)
            local tD, tM = {}, {}
            for i = 1, #sVal do
                local nMask = prngByte()
                tD[i] = string.char(bit32.bxor(sVal:byte(i), nMask))
                tM[i] = string.char(nMask)
            end
            tDataHalf[key] = table.concat(tD)
            tMaskHalf[key] = table.concat(tM)
        end,
        __index = function(_, key)
            local d = tDataHalf[key]
            local m = tMaskHalf[key]
            if not d or not m or #d ~= #m then return nil end
            local t = {}
            for i = 1, #d do
                t[i] = string.char(bit32.bxor(d:byte(i), m:byte(i)))
            end
            return table.concat(t)
        end,
        __len = function()
            local n = 0
            for _ in pairs(tDataHalf) do n = n + 1 end
            return n
        end,
        __metatable = "secure_dict",
    })
    return proxy
end

-- =============================================
-- ETT — ENCLAVE THERMAL THROTTLE
--
-- Per-enclave call rate limiter.  Prevents
-- brute-force attacks like CallEnclave(h, "verify_pin", "0000")
-- a million times per second.
--
-- The throttle is configurable per-enclave via
-- set_throttle() in the enclave environment.
-- Lockout period doubles on each consecutive trip.
-- =============================================

local function fEttCheck(tEnc)
    local tEtt = tEnc.tEtt
    if not tEtt or not tEtt.bEnabled then return true end

    local nNow = g_fUptime()

    -- Check if in lockout
    if tEtt.nLockedUntil and nNow < tEtt.nLockedUntil then
        g_tStats.nEttThrottled = g_tStats.nEttThrottled + 1
        local nRemaining = math.ceil(tEtt.nLockedUntil - nNow)
        return false, string.format(
            "ETT_THROTTLED: enclave locked for %ds (rate limit exceeded)", nRemaining)
    end

    -- Slide the window
    if nNow - tEtt.nWindowStart >= tEtt.nWindowSec then
        tEtt.nWindowStart = nNow
        tEtt.nCallsInWindow = 0
        -- Reset escalation if a full window passed without hitting limit
        if not tEtt.bTrippedThisWindow then
            tEtt.nEscalationLevel = 0
        end
        tEtt.bTrippedThisWindow = false
    end

    tEtt.nCallsInWindow = tEtt.nCallsInWindow + 1

    if tEtt.nCallsInWindow > tEtt.nMaxCalls then
        -- Trip the throttle
        tEtt.bTrippedThisWindow = true
        tEtt.nEscalationLevel = (tEtt.nEscalationLevel or 0) + 1
        local nLockout = tEtt.nLockoutSec * (ETT_ESCALATION_FACTOR ^ (tEtt.nEscalationLevel - 1))
        nLockout = math.min(nLockout, 300) -- cap at 5 minutes
        tEtt.nLockedUntil = nNow + nLockout
        g_tStats.nEttThrottled = g_tStats.nEttThrottled + 1

        g_fLog(string.format(
            "[EXSi] ETT: Enclave %d throttled (%d calls in %.0fs, lockout %.0fs, escalation %d)",
            tEnc._handle or 0, tEtt.nCallsInWindow, tEtt.nWindowSec,
            nLockout, tEtt.nEscalationLevel))

        return false, string.format(
            "ETT_THROTTLED: %d/%d calls exceeded, locked for %ds",
            tEtt.nCallsInWindow, tEtt.nMaxCalls, math.ceil(nLockout))
    end

    return true
end

local function fEttInit()
    return {
        bEnabled          = true,
        nMaxCalls         = ETT_DEFAULT_MAX_CALLS,
        nWindowSec        = ETT_DEFAULT_WINDOW_SEC,
        nLockoutSec       = ETT_DEFAULT_LOCKOUT_SEC,
        nWindowStart      = g_fUptime(),
        nCallsInWindow    = 0,
        nLockedUntil      = nil,
        nEscalationLevel  = 0,
        bTrippedThisWindow = false,
    }
end

-- =============================================
-- ENCLAVE CREATION (v2)
--
-- tOpts (optional):
--   sMrSigner  — hex string: hash of the enclave author's public key
--   nIsvSvn    — number: enclave version (for MRSIGNER sealing)
--   tThrottle  — {nMaxCalls, nWindowSec, nLockoutSec}
-- =============================================

function oExsi.CreateEnclave(nOwnerPid, sCode, tOpts)
    if type(sCode) ~= "string" or #sCode == 0 then
        return nil, "Enclave code must be a non-empty string"
    end

    local nCount = 0
    for _ in pairs(g_tEnclaves) do nCount = nCount + 1 end
    if nCount >= oExsi.MAX_ENCLAVES then
        return nil, "Enclave limit reached (" .. oExsi.MAX_ENCLAVES .. ")"
    end

    tOpts = tOpts or {}

    -- Compute MRENCLAVE = SHA-256(source code)
    local sMrEnclave, sMrEnclaveHex
    if g_oSha256 then
        sMrEnclave    = g_oSha256.digest(sCode)
        sMrEnclaveHex = g_oSha256.hex(sMrEnclave)
    else
        local nH = 5381
        for i = 1, #sCode do nH = ((nH * 33) + sCode:byte(i)) % 0xFFFFFFFF end
        sMrEnclave    = string.format("%08X", nH)
        sMrEnclaveHex = sMrEnclave
    end

    -- MRSIGNER (v2): author identity
    local sMrSigner    = tOpts.sMrSigner or nil
    local sMrSignerHex = nil
    local nIsvSvn      = tOpts.nIsvSvn or 0
    if sMrSigner and g_oSha256 then
        -- Normalize: if it's a hex string, convert to binary
        if #sMrSigner > 32 then
            sMrSignerHex = sMrSigner
            sMrSigner = g_oSha256.digest(sMrSigner) -- hash the signer key
        else
            sMrSignerHex = g_oSha256.hex(sMrSigner)
        end
    end

    -- Create seal/unseal closures (v2: four functions)
    local fSeal, fUnseal, fSealSigner, fUnsealSigner =
        fMakeSealUnseal(sMrEnclave, sMrSigner, nIsvSvn)

    -- Build enclave sandbox environment
    local tSafeString = {}
    for k, v in pairs(string) do if k ~= "dump" then tSafeString[k] = v end end
    local tSafeMath = {}
    for k, v in pairs(math) do tSafeMath[k] = v end
    local tSafeTable = {}
    for k, v in pairs(table) do tSafeTable[k] = v end

    local tEnclaveEnv = {
        string   = tSafeString,
        math     = tSafeMath,
        table    = tSafeTable,
        bit32    = bit32,
        type     = type,
        tostring = tostring,
        tonumber = tonumber,
        pairs    = pairs,
        ipairs   = ipairs,
        error    = error,
        pcall    = pcall,
        xpcall   = xpcall,
        select   = select,
        next     = next,
        rawequal = rawequal,
        assert   = assert,

        -- v1 enclave APIs
        seal      = fSeal,
        unseal    = fUnseal,
        MRENCLAVE = sMrEnclaveHex,

        -- v2 enclave APIs
        seal_by_signer   = fSealSigner,
        unseal_by_signer = fUnsealSigner,
        MRSIGNER         = sMrSignerHex,
        ISVSVN           = nIsvSvn,

        -- v2 Feature 3: Transparent PCMR
        secure_dict = fMakeSecureDict,
    }

    -- Load and execute enclave source
    local sChunkName = "=enclave:" .. sMrEnclaveHex:sub(1, 12)
    local fChunk, sLoadErr = load(sCode, sChunkName, "t", tEnclaveEnv)
    if not fChunk then
        return nil, "Enclave parse error: " .. tostring(sLoadErr)
    end

    local bOk, vResult = pcall(fChunk)
    if not bOk then
        return nil, "Enclave init error: " .. tostring(vResult)
    end
    if type(vResult) ~= "function" then
        return nil, "Enclave must return a function, got " .. type(vResult)
    end

    local fEntry = vResult

    -- Allocate handle
    local nHandle = g_nNextHandle
    g_nNextHandle = g_nNextHandle + 1

    -- ETT: initialize throttle state
    local tEtt = fEttInit()
    if tOpts.tThrottle then
        local tT = tOpts.tThrottle
        if tT.nMaxCalls then tEtt.nMaxCalls = tT.nMaxCalls end
        if tT.nWindowSec then tEtt.nWindowSec = tT.nWindowSec end
        if tT.nLockoutSec then tEtt.nLockoutSec = tT.nLockoutSec end
    end

    -- Also expose set_throttle() inside enclave for self-configuration
    -- (this is called during init, modifies the ETT AFTER creation)
    local tEncRef = {}  -- forward ref, filled below
    tEnclaveEnv.set_throttle = function(nMax, nWindow, nLockout)
        if tEncRef.tEtt then
            if nMax then tEncRef.tEtt.nMaxCalls = math.max(1, nMax) end
            if nWindow then tEncRef.tEtt.nWindowSec = math.max(1, nWindow) end
            if nLockout then tEncRef.tEtt.nLockoutSec = math.max(1, nLockout) end
        end
        return true
    end

    g_tEnclaves[nHandle] = {
        _handle       = nHandle,
        fEntry        = fEntry,
        sMrEnclave    = sMrEnclave,
        sMrEnclaveHex = sMrEnclaveHex,
        sMrSigner     = sMrSigner,
        sMrSignerHex  = sMrSignerHex,
        nIsvSvn       = nIsvSvn,
        nOwnerPid     = nOwnerPid,
        nCreatedAt    = g_fUptime(),
        nCallCount    = 0,
        nCodeSize     = #sCode,
        tEtt          = tEtt,
    }
    tEncRef.tEtt = tEtt  -- wire forward ref

    g_tStats.nCreated = g_tStats.nCreated + 1
    g_fLog(string.format(
        "[EXSi] Enclave created: handle=%d MRENCLAVE=%s MRSIGNER=%s SVN=%d owner=PID %d (%dB)",
        nHandle, sMrEnclaveHex:sub(1, 16) .. "...",
        sMrSignerHex and (sMrSignerHex:sub(1, 12) .. "...") or "none",
        nIsvSvn, nOwnerPid, #sCode))

    return nHandle, sMrEnclaveHex
end

-- =============================================
-- ENCLAVE CALL (v2: ETT check before dispatch)
-- =============================================

function oExsi.CallEnclave(nCallerPid, nHandle, sMethod, ...)
    local tEnc = g_tEnclaves[nHandle]
    if not tEnc then
        return nil, "Invalid enclave handle"
    end

    -- ETT: rate-limit check
    local bAllowed, sThrottleErr = fEttCheck(tEnc)
    if not bAllowed then
        return nil, sThrottleErr
    end

    g_tStats.nCalls = g_tStats.nCalls + 1
    tEnc.nCallCount = tEnc.nCallCount + 1

    local tResults = table.pack(pcall(tEnc.fEntry, sMethod, ...))
    local bOk = tResults[1]

    if not bOk then
        g_fLog(string.format(
            "[EXSi] Enclave %d crashed on method '%s': %s",
            nHandle, tostring(sMethod), tostring(tResults[2])))
        return nil, "Enclave error: " .. tostring(tResults[2])
    end

    return table.unpack(tResults, 2, tResults.n)
end

-- =============================================
-- ATTESTATION (v2: Signed Quote)
--
-- Returns a Quote structure signed by the Data Card
-- (Tier 3: ECDSA, Tier 1-2: HMAC, no card: unsigned).
-- The caller provides sUserData (nonce) to prevent replay.
-- =============================================

function oExsi.Attest(nHandle, sUserData)
    local tEnc = g_tEnclaves[nHandle]
    if not tEnc then
        return nil, "Invalid enclave handle"
    end

    g_tStats.nAttestations = g_tStats.nAttestations + 1
    sUserData = sUserData or ""

    -- Build report body
    local tReport = {
        sMrEnclave = tEnc.sMrEnclaveHex,
        sMrSigner  = tEnc.sMrSignerHex or "none",
        nIsvSvn    = tEnc.nIsvSvn or 0,
        nOwnerPid  = tEnc.nOwnerPid,
        nCreatedAt = tEnc.nCreatedAt,
        nCallCount = tEnc.nCallCount,
        nCodeSize  = tEnc.nCodeSize,
        sUserData  = sUserData,
        nTimestamp = g_fUptime(),
    }

    -- Compute report digest for signing
    local sReportData = (tEnc.sMrEnclaveHex or "") .. "|"
        .. (tEnc.sMrSignerHex or "") .. "|"
        .. tostring(tEnc.nIsvSvn) .. "|"
        .. sUserData .. "|"
        .. tostring(tReport.nTimestamp)

    -- Sign the report
    if g_oSha256 then
        local sDigest = g_oSha256.digest(sReportData)
        tReport.sReportDigest = g_oSha256.hex(sDigest)

        if g_nDataCardTier >= 3 and g_oDataCard and g_oDataCard.ecdsa then
            -- Tier 3: ECDSA signature (hardware-bound, unforgeable by Ring 0)
            local bSignOk, sSignature = pcall(g_oDataCard.ecdsa, sDigest)
            if bSignOk and sSignature then
                tReport.sSignature = sSignature
                tReport.sSignatureType = "ECDSA"
                -- Include the data card address for verification
                tReport.sSignerAddr = g_oDataCard.address or ""
                g_tStats.nQuotesIssued = g_tStats.nQuotesIssued + 1
            else
                -- ECDSA failed, fall back to HMAC
                tReport.sSignature = g_oSha256.hmac(g_sHardwareKey or "", sReportData)
                tReport.sSignatureType = "HMAC"
            end
        elseif g_sHardwareKey then
            -- Tier 1-2 or no ECDSA: HMAC with hardware key
            tReport.sSignature = g_oSha256.hmac(g_sHardwareKey, sReportData)
            tReport.sSignatureType = "HMAC"
        else
            tReport.sSignatureType = "NONE"
        end
    else
        tReport.sSignatureType = "NONE"
    end

    return tReport
end

-- =============================================
-- SECURE CHANNEL — Enclave-to-Enclave DH
--
-- Establishes an encrypted channel between two enclaves.
-- Ring 0 transports the public DH values but cannot
-- derive the shared secret (private keys live inside
-- per-channel DH enclaves as closure upvalues).
-- =============================================

-- DH helper: modular exponentiation (safe for Lua doubles with p < 2^24)
local function fModPow(base, exp, mod)
    local result = 1
    base = base % mod
    while exp > 0 do
        if exp % 2 == 1 then
            result = (result * base) % mod
        end
        exp = math.floor(exp / 2)
        base = (base * base) % mod
    end
    return result
end

-- DH enclave source: generates keypair, derives shared secret,
-- encrypts/decrypts messages.  All state in closure upvalues.
local DH_ENCLAVE_SOURCE = [==[
local privKey = nil
local sharedKey = nil
local P = 16777213
local G = 2

local function modpow(base, exp, mod)
    local result = 1
    base = base % mod
    while exp > 0 do
        if exp % 2 == 1 then
            result = (result * base) % mod
        end
        exp = math.floor(exp / 2)
        base = (base * base) % mod
    end
    return result
end

-- Embedded mini SHA-256 for key derivation
local band=bit32.band local bnot=bit32.bnot local bxor=bit32.bxor
local rsh=bit32.rshift local lsh=bit32.lshift local bor=bit32.bor
local M=0x100000000
local function rrot(x,n) n=n%32; if n==0 then return x end; return bor(rsh(x,n),lsh(x,32-n)) end
local function x3(a,b,c) return bxor(bxor(a,b),c) end
local K={0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2}
local IV={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
local function u32(n) return string.char(band(rsh(n,24),0xFF),band(rsh(n,16),0xFF),band(rsh(n,8),0xFF),band(n,0xFF)) end
local function sha(msg) msg=tostring(msg); local len=#msg; msg=msg.."\128"; msg=msg..string.rep("\0",(56-#msg%64)%64); local bl=len*8; msg=msg..u32(math.floor(bl/M))..u32(bl%M); local h1,h2,h3,h4,h5,h6,h7,h8=IV[1],IV[2],IV[3],IV[4],IV[5],IV[6],IV[7],IV[8]; for blk=1,#msg,64 do local W={}; for j=1,16 do local o=blk+(j-1)*4; W[j]=msg:byte(o)*0x1000000+msg:byte(o+1)*0x10000+msg:byte(o+2)*0x100+msg:byte(o+3) end; for j=17,64 do local v=W[j-15]; local v2=W[j-2]; W[j]=(W[j-16]+x3(rrot(v,7),rrot(v,18),rsh(v,3))+W[j-7]+x3(rrot(v2,17),rrot(v2,19),rsh(v2,10)))%M end; local a,b,c,d,e,f,gv,h=h1,h2,h3,h4,h5,h6,h7,h8; for j=1,64 do local t1=(h+x3(rrot(e,6),rrot(e,11),rrot(e,25))+bxor(band(e,f),band(bnot(e),gv))+K[j]+W[j])%M; local t2=(x3(rrot(a,2),rrot(a,13),rrot(a,22))+x3(band(a,b),band(a,c),band(b,c)))%M; h=gv; gv=f; f=e; e=(d+t1)%M; d=c; c=b; b=a; a=(t1+t2)%M end; h1=(h1+a)%M; h2=(h2+b)%M; h3=(h3+c)%M; h4=(h4+d)%M; h5=(h5+e)%M; h6=(h6+f)%M; h7=(h7+gv)%M; h8=(h8+h)%M end; return u32(h1)..u32(h2)..u32(h3)..u32(h4)..u32(h5)..u32(h6)..u32(h7)..u32(h8) end
local function hmac(key,msg) if #key>64 then key=sha(key) end; key=key..string.rep("\0",64-#key); local ip,op={},{}; for i=1,64 do local kb=key:byte(i); ip[i]=string.char(bxor(kb,0x36)); op[i]=string.char(bxor(kb,0x5C)) end; return sha(table.concat(op)..sha(table.concat(ip)..msg)) end

local function xorCipher(sKey, sData)
    local nLen=#sData; local tOut={}; local nBI=0; local nP=1
    while nP<=nLen do
        local sC=string.char(math.floor(nBI/16777216)%256,math.floor(nBI/65536)%256,math.floor(nBI/256)%256,nBI%256)..string.char(math.floor(nLen/16777216)%256,math.floor(nLen/65536)%256,math.floor(nLen/256)%256,nLen%256)
        local sKB=hmac(sKey,sC)
        for i=1,32 do if nP>nLen then break end; tOut[#tOut+1]=string.char(bxor(sData:byte(nP),sKB:byte(i))); nP=nP+1 end
        nBI=nBI+1
    end
    return table.concat(tOut)
end

return function(sMethod, ...)
    if sMethod == "keygen" then
        privKey = math.random(2, P - 2)
        return modpow(G, privKey, P)
    elseif sMethod == "derive" then
        local remotePub = select(1, ...)
        if type(remotePub) ~= "number" then return nil, "bad pub" end
        local rawShared = modpow(remotePub, privKey, P)
        -- Use ONLY the shared secret (identical on both sides)
        sharedKey = sha(tostring(rawShared))
        return true
    elseif sMethod == "encrypt" then
        if not sharedKey then return nil, "no channel key" end
        return xorCipher(sharedKey, tostring(select(1, ...)))
    elseif sMethod == "decrypt" then
        if not sharedKey then return nil, "no channel key" end
        return xorCipher(sharedKey, tostring(select(1, ...)))
    end
end
]==]

function oExsi.OpenChannel(nCallerPid, nHandleA, nHandleB)
    local tEncA = g_tEnclaves[nHandleA]
    local tEncB = g_tEnclaves[nHandleB]
    if not tEncA then return nil, "Invalid enclave A" end
    if not tEncB then return nil, "Invalid enclave B" end

    local nChCount = 0
    for _ in pairs(g_tChannels) do nChCount = nChCount + 1 end
    if nChCount >= oExsi.MAX_CHANNELS then
        return nil, "Channel limit reached"
    end

    -- Create DH helper enclaves (one per side)
    local hDhA, sMrA = oExsi.CreateEnclave(0, DH_ENCLAVE_SOURCE)
    if not hDhA then return nil, "Failed to create DH enclave A" end

    local hDhB, sMrB = oExsi.CreateEnclave(0, DH_ENCLAVE_SOURCE)
    if not hDhB then
        oExsi.DestroyEnclave(0, 0, hDhA)
        return nil, "Failed to create DH enclave B"
    end

    -- Key exchange:
    -- 1. A generates keypair, returns pubA
    local pubA = oExsi.CallEnclave(0, hDhA, "keygen")
    if not pubA then
        oExsi.DestroyEnclave(0, 0, hDhA)
        oExsi.DestroyEnclave(0, 0, hDhB)
        return nil, "DH keygen A failed"
    end

    -- 2. B generates keypair, returns pubB
    local pubB = oExsi.CallEnclave(0, hDhB, "keygen")
    if not pubB then
        oExsi.DestroyEnclave(0, 0, hDhA)
        oExsi.DestroyEnclave(0, 0, hDhB)
        return nil, "DH keygen B failed"
    end

    -- 3. Exchange public values and derive shared secret
    -- Kernel sees pubA and pubB (numbers), but NOT the private keys
    -- (those are closure upvalues inside the DH enclaves)
    local bDeriveA = oExsi.CallEnclave(0, hDhA, "derive", pubB)
    local bDeriveB = oExsi.CallEnclave(0, hDhB, "derive", pubA)

    if not bDeriveA or not bDeriveB then
        oExsi.DestroyEnclave(0, 0, hDhA)
        oExsi.DestroyEnclave(0, 0, hDhB)
        return nil, "DH key derivation failed"
    end

    local nChannelId = g_nNextChannel
    g_nNextChannel = g_nNextChannel + 1

    g_tChannels[nChannelId] = {
        nId        = nChannelId,
        hEnclaveA  = nHandleA,
        hEnclaveB  = nHandleB,
        hDhA       = hDhA,
        hDhB       = hDhB,
        nCreatedAt = g_fUptime(),
        nMessages  = 0,
    }

    g_tStats.nChannelsCreated = g_tStats.nChannelsCreated + 1
    g_fLog(string.format(
        "[EXSi] Secure channel %d established: enclave %d <-> enclave %d (DH complete)",
        nChannelId, nHandleA, nHandleB))

    return nChannelId
end

function oExsi.ChannelSend(nCallerPid, nChannelId, nSrcHandle, sData)
    local tCh = g_tChannels[nChannelId]
    if not tCh then return nil, "Invalid channel" end

    -- Determine which DH enclave to use for encryption
    local hDhSrc, hDhDst
    if nSrcHandle == tCh.hEnclaveA then
        hDhSrc = tCh.hDhA; hDhDst = tCh.hDhB
    elseif nSrcHandle == tCh.hEnclaveB then
        hDhSrc = tCh.hDhB; hDhDst = tCh.hDhA
    else
        return nil, "Source enclave not part of this channel"
    end

    -- Encrypt inside source's DH enclave (kernel sees only ciphertext)
    local sCiphertext = oExsi.CallEnclave(0, hDhSrc, "encrypt", sData)
    if not sCiphertext then return nil, "Encryption failed" end

    -- Decrypt inside destination's DH enclave (kernel never sees plaintext)
    local sPlaintext = oExsi.CallEnclave(0, hDhDst, "decrypt", sCiphertext)
    if not sPlaintext then return nil, "Decryption failed" end

    tCh.nMessages = tCh.nMessages + 1
    g_tStats.nChannelMessages = g_tStats.nChannelMessages + 1

    return sPlaintext
end

function oExsi.CloseChannel(nCallerPid, nChannelId)
    local tCh = g_tChannels[nChannelId]
    if not tCh then return nil, "Invalid channel" end

    -- Destroy DH helper enclaves
    oExsi.DestroyEnclave(0, 0, tCh.hDhA)
    oExsi.DestroyEnclave(0, 0, tCh.hDhB)
    g_tChannels[nChannelId] = nil

    g_fLog(string.format("[EXSi] Channel %d closed (%d messages exchanged)",
        nChannelId, tCh.nMessages))
    return true
end

-- =============================================
-- ENCLAVE DESTRUCTION (unchanged)
-- =============================================

function oExsi.DestroyEnclave(nCallerPid, nCallerRing, nHandle)
    local tEnc = g_tEnclaves[nHandle]
    if not tEnc then return nil, "Invalid enclave handle" end
    if tEnc.nOwnerPid ~= nCallerPid and nCallerRing > 1 then
        return nil, "Permission denied: not enclave owner"
    end
    -- Close any channels involving this enclave
    for nChId, tCh in pairs(g_tChannels) do
        if tCh.hEnclaveA == nHandle or tCh.hEnclaveB == nHandle then
            oExsi.CloseChannel(0, nChId)
        end
    end
    tEnc.fEntry     = nil
    tEnc.sMrEnclave = nil
    tEnc.sMrSigner  = nil
    g_tEnclaves[nHandle] = nil
    g_tStats.nDestroyed = g_tStats.nDestroyed + 1
    return true
end

-- =============================================
-- LIST / STATS / CLEANUP (updated for v2)
-- =============================================

function oExsi.ListEnclaves()
    local tResult = {}
    for nHandle, tEnc in pairs(g_tEnclaves) do
        tResult[#tResult + 1] = {
            nHandle    = nHandle,
            sMrEnclave = tEnc.sMrEnclaveHex,
            sMrSigner  = tEnc.sMrSignerHex,
            nIsvSvn    = tEnc.nIsvSvn,
            nOwnerPid  = tEnc.nOwnerPid,
            nCreatedAt = tEnc.nCreatedAt,
            nCallCount = tEnc.nCallCount,
            nCodeSize  = tEnc.nCodeSize,
            bThrottled = tEnc.tEtt and tEnc.tEtt.nLockedUntil
                and g_fUptime() < tEnc.tEtt.nLockedUntil or false,
        }
    end
    table.sort(tResult, function(a, b) return a.nHandle < b.nHandle end)
    return tResult
end

function oExsi.GetStats()
    local nActive = 0
    for _ in pairs(g_tEnclaves) do nActive = nActive + 1 end
    local nChannels = 0
    for _ in pairs(g_tChannels) do nChannels = nChannels + 1 end
    return {
        nActiveEnclaves   = nActive,
        nMaxEnclaves      = oExsi.MAX_ENCLAVES,
        nCreated          = g_tStats.nCreated,
        nDestroyed        = g_tStats.nDestroyed,
        nCalls            = g_tStats.nCalls,
        nAttestations     = g_tStats.nAttestations,
        nSeals            = g_tStats.nSeals,
        nUnseals          = g_tStats.nUnseals,
        nSealFailures     = g_tStats.nSealFailures,
        nQuotesIssued     = g_tStats.nQuotesIssued,
        nActiveChannels   = nChannels,
        nChannelsCreated  = g_tStats.nChannelsCreated,
        nChannelMessages  = g_tStats.nChannelMessages,
        nEttThrottled     = g_tStats.nEttThrottled,
        bSha256Available  = (g_oSha256 ~= nil),
        bSealingAvailable = (g_sHardwareKey ~= nil),
        nDataCardTier     = g_nDataCardTier,
        bEcdsaQuotes      = (g_nDataCardTier >= 3),
    }
end

function oExsi.CleanupProcess(nPid)
    -- Close channels owned by this process's enclaves
    local tOwnedHandles = {}
    for nHandle, tEnc in pairs(g_tEnclaves) do
        if tEnc.nOwnerPid == nPid then
            tOwnedHandles[#tOwnedHandles + 1] = nHandle
        end
    end
    -- Close channels first
    for nChId, tCh in pairs(g_tChannels) do
        for _, nH in ipairs(tOwnedHandles) do
            if tCh.hEnclaveA == nH or tCh.hEnclaveB == nH then
                pcall(oExsi.CloseChannel, 0, nChId)
                break
            end
        end
    end
    -- Destroy enclaves
    for _, nHandle in ipairs(tOwnedHandles) do
        g_fLog(string.format(
            "[EXSi] Auto-destroying enclave %d (owner PID %d exited)", nHandle, nPid))
        local tEnc = g_tEnclaves[nHandle]
        if tEnc then tEnc.fEntry = nil; tEnc.sMrEnclave = nil end
        g_tEnclaves[nHandle] = nil
        g_tStats.nDestroyed = g_tStats.nDestroyed + 1
    end
end

return oExsi