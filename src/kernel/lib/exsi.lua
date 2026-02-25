--
-- /lib/exsi.lua
-- AxisOS EXSi — Enclaved Kernel eXecution Isolation
--
-- SGX-like enclave protection for Lua:
--  • Memory isolation via closures (locals unreachable without debug)
--  • Cryptographic attestation (MRENCLAVE = SHA-256 of source code)
--  • Data sealing (encrypt with key derived from enclave hash + hardware)
--
-- Enclaves are functions that store secrets in local variables.
-- The kernel can call an enclave but cannot read its internal state.
--
-- Enclave source code must return a function(sMethod, ...) → values.
-- All secrets live as upvalues of that function — invisible to Ring 0.
--

local oExsi = {}

-- =============================================
-- CONSTANTS
-- =============================================

oExsi.MAX_ENCLAVES     = 32
oExsi.MAX_SEALED_SIZE  = 65536
oExsi.SEAL_HEADER_SIZE = 64     -- 32B MRENCLAVE + 32B HMAC tag

-- =============================================
-- INTERNAL STATE
-- =============================================

local g_tEnclaves   = {}        -- [nHandle] → enclave descriptor
local g_nNextHandle  = 1
local g_fLog         = nil
local g_fUptime      = nil
local g_oSha256      = nil      -- /lib/sha256.lua module
local g_sHardwareKey = nil      -- SHA-256(hardware_seed) — machine-specific

local g_tStats = {
    nCreated       = 0,
    nDestroyed     = 0,
    nCalls         = 0,
    nAttestations  = 0,
    nSeals         = 0,
    nUnseals       = 0,
    nSealFailures  = 0,
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
        g_fLog("[EXSi]   Enclaves still provide memory isolation via closures")
    end

    -- Derive hardware key from machine identity seed.
    -- The kernel passes a pre-computed seed that mixes
    -- computer address + EEPROM address + data card address.
    -- This key is unique per machine and never leaves the kernel.
    if g_oSha256 and tCfg.sHardwareSeed then
        g_sHardwareKey = g_oSha256.digest(tCfg.sHardwareSeed)
        g_fLog("[EXSi] Hardware sealing key derived (" .. #g_sHardwareKey .. " bytes)")
    end

    g_fLog("[EXSi] Enclaved Kernel eXecution Isolation initialized")
    g_fLog("[EXSi]   Max enclaves: " .. oExsi.MAX_ENCLAVES)
    g_fLog("[EXSi]   SHA-256:      " .. (g_oSha256 and "available" or "NONE"))
    g_fLog("[EXSi]   Sealing:      " .. (g_sHardwareKey and "available" or "NONE"))

    return true
end

-- =============================================
-- SEALING KEY DERIVATION
--
-- sealingKey = HMAC-SHA256(hardwareKey, MRENCLAVE)
--
-- This ensures:
--  • Different enclaves get different sealing keys
--  • Same enclave on different machines gets different keys
--  • Only the SAME enclave on the SAME machine can unseal
-- =============================================

local function fDeriveSealingKey(sMrEnclave)
    if not g_oSha256 or not g_sHardwareKey then return nil end
    return g_oSha256.hmac(g_sHardwareKey, sMrEnclave)
end

-- =============================================
-- XOR KEYSTREAM CIPHER
--
-- Counter-mode HMAC keystream, XOR with data.
-- Same operation for encrypt and decrypt.
-- Matches the pattern used in efi_partition.lua.
-- =============================================

local function fXorCipher(sKey, sData)
    if not g_oSha256 then return nil, "No SHA-256" end
    local nLen = #sData
    local tOut = {}
    local nBlockIdx = 0
    local nPos = 1

    while nPos <= nLen do
        -- Counter = block index (4B BE) + data length (4B BE)
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

        -- XOR up to 32 bytes of data with this keystream block
        for i = 1, 32 do
            if nPos > nLen then break end
            local bData = sData:byte(nPos)
            local bKey  = sKeyBlock:byte(i)
            tOut[#tOut + 1] = string.char(bit32.bxor(bData, bKey))
            nPos = nPos + 1
        end

        nBlockIdx = nBlockIdx + 1
    end

    return table.concat(tOut)
end

-- =============================================
-- SEAL / UNSEAL FACTORY
--
-- Creates per-enclave seal/unseal closures that
-- capture the enclave's sealing key in an upvalue.
-- The sealing key itself is NEVER exposed — it lives
-- only inside these closures' upvalue slots.
--
-- Sealed blob format:
--  [32B MRENCLAVE] [32B HMAC-SHA256 tag] [encrypted data]
--
-- The tag is computed over the PLAINTEXT, so after
-- decryption we can verify integrity.
-- =============================================

local function fMakeSealUnseal(sMrEnclave)
    local sSealingKey = fDeriveSealingKey(sMrEnclave)

    if not sSealingKey then
        -- No crypto available: seal/unseal pass data through unchanged.
        -- Memory isolation still works; only sealing is degraded.
        return function(sData) return sData end,
               function(sBlob) return sBlob end
    end

    -- ---- SEAL: encrypt data and prepend MRENCLAVE + integrity tag ----
    local function fSeal(sData)
        if type(sData) ~= "string" then
            sData = tostring(sData)
        end
        if #sData > oExsi.MAX_SEALED_SIZE then
            return nil, "Data too large to seal (" .. #sData .. "/" .. oExsi.MAX_SEALED_SIZE .. ")"
        end

        local sEncrypted = fXorCipher(sSealingKey, sData)
        if not sEncrypted then return nil, "Encryption failed" end

        -- Integrity tag over plaintext (MAC-then-Encrypt)
        local sTag = g_oSha256.hmac(sSealingKey, sData)

        g_tStats.nSeals = g_tStats.nSeals + 1
        return sMrEnclave .. sTag .. sEncrypted
    end

    -- ---- UNSEAL: verify MRENCLAVE + integrity, then decrypt ----
    local function fUnseal(sBlob)
        if type(sBlob) ~= "string" or #sBlob < oExsi.SEAL_HEADER_SIZE then
            return nil, "Invalid sealed blob (too short)"
        end

        -- Verify MRENCLAVE matches this enclave
        local sBlobMr = sBlob:sub(1, 32)
        if not g_oSha256.constEq(sBlobMr, sMrEnclave) then
            g_tStats.nSealFailures = g_tStats.nSealFailures + 1
            return nil, "MRENCLAVE mismatch — wrong enclave or tampered blob"
        end

        local sTag       = sBlob:sub(33, 64)
        local sEncrypted = sBlob:sub(65)

        -- Decrypt
        local sDecrypted = fXorCipher(sSealingKey, sEncrypted)
        if not sDecrypted then
            g_tStats.nSealFailures = g_tStats.nSealFailures + 1
            return nil, "Decryption failed"
        end

        -- Verify integrity: recompute tag over decrypted plaintext
        local sExpectedTag = g_oSha256.hmac(sSealingKey, sDecrypted)
        if not g_oSha256.constEq(sTag, sExpectedTag) then
            g_tStats.nSealFailures = g_tStats.nSealFailures + 1
            return nil, "Integrity check failed — data tampered or wrong machine"
        end

        g_tStats.nUnseals = g_tStats.nUnseals + 1
        return sDecrypted
    end

    return fSeal, fUnseal
end

-- =============================================
-- ENCLAVE CREATION
--
-- sCode must be Lua source that returns a function:
--
--  local sMySecret = nil
--  local tMyState  = {}
--
--  return function(sMethod, ...)
--      if sMethod == "store_secret" then
--          sMySecret = select(1, ...)
--          return true
--      elseif sMethod == "use_secret" then
--          return "result computed with " .. sMySecret
--      elseif sMethod == "seal_state" then
--          return seal(sMySecret)
--      elseif sMethod == "unseal_state" then
--          sMySecret = unseal(select(1, ...))
--          return true
--      end
--  end
--
-- The returned function is the enclave entry point.
-- sMySecret and tMyState live as upvalues — invisible
-- to Ring 0 (debug library is disabled for Ring >= 1).
--
-- The enclave environment provides:
--  string, math, table, bit32 (safe subsets)
--  type, tostring, tonumber, pairs, ipairs, etc.
--  seal(data) → sealed blob
--  unseal(blob) → data
--  MRENCLAVE — hex string of own hash (read-only)
--
-- NOT provided (isolation):
--  debug, rawset, rawget, load, require, dofile
--  io, os, component, computer, syscall, coroutine
--
-- Returns: nHandle, sMrEnclaveHex, or nil + error
-- =============================================

function oExsi.CreateEnclave(nOwnerPid, sCode)
    if type(sCode) ~= "string" or #sCode == 0 then
        return nil, "Enclave code must be a non-empty string"
    end

    -- Enforce enclave limit
    local nCount = 0
    for _ in pairs(g_tEnclaves) do nCount = nCount + 1 end
    if nCount >= oExsi.MAX_ENCLAVES then
        return nil, "Enclave limit reached (" .. oExsi.MAX_ENCLAVES .. ")"
    end

    -- ---- Compute MRENCLAVE = SHA-256(source code) ----
    local sMrEnclave
    local sMrEnclaveHex

    if g_oSha256 then
        sMrEnclave    = g_oSha256.digest(sCode)
        sMrEnclaveHex = g_oSha256.hex(sMrEnclave)
    else
        -- Fallback: weak hash when no SHA-256 is available.
        -- Memory isolation still works; attestation is degraded.
        local nH = 5381
        for i = 1, #sCode do
            nH = ((nH * 33) + sCode:byte(i)) % 0xFFFFFFFF
        end
        sMrEnclave    = string.format("%08X", nH)
        sMrEnclaveHex = sMrEnclave
    end

    -- ---- Create per-enclave seal/unseal closures ----
    local fSeal, fUnseal = fMakeSealUnseal(sMrEnclave)

    -- ---- Build minimal enclave sandbox environment ----
    -- Each enclave gets its OWN shallow copy of safe libraries.
    -- No shared mutable state between enclaves.

    local tSafeString = {}
    for k, v in pairs(string) do
        if k ~= "dump" then tSafeString[k] = v end
    end
    local tSafeMath = {}
    for k, v in pairs(math) do tSafeMath[k] = v end
    local tSafeTable = {}
    for k, v in pairs(table) do tSafeTable[k] = v end

    local tEnclaveEnv = {
        -- Safe standard library subsets
        string   = tSafeString,
        math     = tSafeMath,
        table    = tSafeTable,
        bit32    = bit32,

        -- Safe builtins
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

        -- Enclave-specific APIs
        seal      = fSeal,
        unseal    = fUnseal,
        MRENCLAVE = sMrEnclaveHex,

        -- Explicit exclusions (documented for clarity):
        -- NO: debug, rawset, rawget, load, require, dofile, loadfile
        -- NO: io, os, computer, component, raw_computer, raw_component
        -- NO: syscall, coroutine, setmetatable, getmetatable
    }

    -- ---- Load enclave source in isolated environment ----
    local sChunkName = "=enclave:" .. sMrEnclaveHex:sub(1, 12)
    local fChunk, sLoadErr = load(sCode, sChunkName, "t", tEnclaveEnv)
    if not fChunk then
        return nil, "Enclave parse error: " .. tostring(sLoadErr)
    end

    -- ---- Execute the enclave setup ----
    -- The source code runs and must return a function.
    -- Any local variables declared at module scope become
    -- upvalues of the returned function — permanently sealed.
    local bOk, vResult = pcall(fChunk)
    if not bOk then
        return nil, "Enclave init error: " .. tostring(vResult)
    end
    if type(vResult) ~= "function" then
        return nil, "Enclave must return a function, got " .. type(vResult)
    end

    -- ---- The closure IS the enclave ----
    -- Its internal state (local variables / upvalues) is now
    -- sealed inside the Lua closure. No code path reaches
    -- those values without the debug library, which is
    -- disabled for Ring >= 1.
    local fEntry = vResult

    -- Allocate handle
    local nHandle = g_nNextHandle
    g_nNextHandle = g_nNextHandle + 1

    g_tEnclaves[nHandle] = {
        fEntry        = fEntry,       -- the sealed closure
        sMrEnclave    = sMrEnclave,   -- binary hash (for sealing)
        sMrEnclaveHex = sMrEnclaveHex,-- hex hash (for display)
        nOwnerPid     = nOwnerPid,
        nCreatedAt    = g_fUptime(),
        nCallCount    = 0,
        nCodeSize     = #sCode,
    }

    g_tStats.nCreated = g_tStats.nCreated + 1
    g_fLog(string.format(
        "[EXSi] Enclave created: handle=%d MRENCLAVE=%s owner=PID %d (%dB)",
        nHandle, sMrEnclaveHex:sub(1, 16) .. "...", nOwnerPid, #sCode))

    return nHandle, sMrEnclaveHex
end

-- =============================================
-- ENCLAVE CALL
--
-- Routes a method call into the enclave.
-- The kernel sees only the arguments and return values —
-- the enclave's internal state is invisible.
-- =============================================

function oExsi.CallEnclave(nCallerPid, nHandle, sMethod, ...)
    local tEnc = g_tEnclaves[nHandle]
    if not tEnc then
        return nil, "Invalid enclave handle"
    end

    g_tStats.nCalls = g_tStats.nCalls + 1
    tEnc.nCallCount = tEnc.nCallCount + 1

    -- pcall prevents enclave crashes from killing the kernel.
    -- table.pack preserves the exact return count (including nils)
    -- so table.unpack(t, 2, t.n) returns them faithfully.
    -- Plain {pcall(...)} + table.unpack loses values after a nil.
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
-- ATTESTATION
--
-- Returns the MRENCLAVE hash and metadata so callers
-- (or remote servers) can verify that a specific piece
-- of code is running inside the enclave.
--
-- The returned hash is deterministic: same source code
-- always produces the same MRENCLAVE on any machine.
-- =============================================

function oExsi.Attest(nHandle)
    local tEnc = g_tEnclaves[nHandle]
    if not tEnc then
        return nil, "Invalid enclave handle"
    end

    g_tStats.nAttestations = g_tStats.nAttestations + 1

    return {
        sMrEnclave = tEnc.sMrEnclaveHex,
        nOwnerPid  = tEnc.nOwnerPid,
        nCreatedAt = tEnc.nCreatedAt,
        nCallCount = tEnc.nCallCount,
        nCodeSize  = tEnc.nCodeSize,
    }
end

-- =============================================
-- ENCLAVE DESTRUCTION
-- Only the owner or Ring 0-1 can destroy an enclave.
-- =============================================

function oExsi.DestroyEnclave(nCallerPid, nCallerRing, nHandle)
    local tEnc = g_tEnclaves[nHandle]
    if not tEnc then
        return nil, "Invalid enclave handle"
    end

    -- Access control: owner or privileged ring
    if tEnc.nOwnerPid ~= nCallerPid and nCallerRing > 1 then
        return nil, "Permission denied: not enclave owner"
    end

    g_fLog(string.format(
        "[EXSi] Enclave destroyed: handle=%d MRENCLAVE=%s",
        nHandle, tEnc.sMrEnclaveHex:sub(1, 16) .. "..."))

    -- Nil all references → GC collects closure + upvalues + sealing key
    tEnc.fEntry    = nil
    tEnc.sMrEnclave = nil
    g_tEnclaves[nHandle] = nil

    g_tStats.nDestroyed = g_tStats.nDestroyed + 1
    return true
end

-- =============================================
-- LIST ENCLAVES
-- Returns public metadata only.
-- No secrets, no entry points, no sealing keys.
-- =============================================

function oExsi.ListEnclaves()
    local tResult = {}
    for nHandle, tEnc in pairs(g_tEnclaves) do
        tResult[#tResult + 1] = {
            nHandle    = nHandle,
            sMrEnclave = tEnc.sMrEnclaveHex,
            nOwnerPid  = tEnc.nOwnerPid,
            nCreatedAt = tEnc.nCreatedAt,
            nCallCount = tEnc.nCallCount,
            nCodeSize  = tEnc.nCodeSize,
        }
    end
    table.sort(tResult, function(a, b) return a.nHandle < b.nHandle end)
    return tResult
end

-- =============================================
-- STATISTICS
-- =============================================

function oExsi.GetStats()
    local nActive = 0
    for _ in pairs(g_tEnclaves) do nActive = nActive + 1 end
    return {
        nActiveEnclaves  = nActive,
        nMaxEnclaves     = oExsi.MAX_ENCLAVES,
        nCreated         = g_tStats.nCreated,
        nDestroyed       = g_tStats.nDestroyed,
        nCalls           = g_tStats.nCalls,
        nAttestations    = g_tStats.nAttestations,
        nSeals           = g_tStats.nSeals,
        nUnseals         = g_tStats.nUnseals,
        nSealFailures    = g_tStats.nSealFailures,
        bSha256Available  = (g_oSha256 ~= nil),
        bSealingAvailable = (g_sHardwareKey ~= nil),
    }
end

-- =============================================
-- PROCESS CLEANUP
-- Destroy all enclaves owned by a dead process.
-- Called by the kernel when a process exits.
-- =============================================

function oExsi.CleanupProcess(nPid)
    local tToRemove = {}
    for nHandle, tEnc in pairs(g_tEnclaves) do
        if tEnc.nOwnerPid == nPid then
            tToRemove[#tToRemove + 1] = nHandle
        end
    end
    for _, nHandle in ipairs(tToRemove) do
        g_fLog(string.format(
            "[EXSi] Auto-destroying enclave %d (owner PID %d exited)",
            nHandle, nPid))
        local tEnc = g_tEnclaves[nHandle]
        if tEnc then
            tEnc.fEntry    = nil
            tEnc.sMrEnclave = nil
        end
        g_tEnclaves[nHandle] = nil
        g_tStats.nDestroyed = g_tStats.nDestroyed + 1
    end
end

return oExsi