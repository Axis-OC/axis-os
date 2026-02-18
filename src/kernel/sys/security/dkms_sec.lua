-- /sys/security/dkms_sec.lua
-- AxisOS Driver Security Validator v2
-- Now with REAL cryptographic signature verification

local tStatus = require("errcheck")
local tDKStructs = require("shared_structs")

local oSec = {}

-- Signature block format embedded in driver files:
-- Last lines of the file contain:
--   --@SIGNATURE:base64_encoded_ecdsa_signature
--   --@SIGNER:fingerprint_of_signing_key
--   --@HASH:sha256_of_code_without_signature_block

local g_oCrypto = nil
local g_tApprovedKeys = {}
local g_bInitialized = false
local g_nSecurityLevel = 0  -- 0=disabled, 1=warn, 2=enforce

function oSec.Initialize(tConfig)
    if g_bInitialized then return true end

    local nStart = os.clock()
    syscall("kernel_log", "[SEC] ── Security Subsystem Init ──")

    -- =============================================
    -- STEP 1: Crypto provider
    -- crypto.lua uses component.list() which works via
    -- the sandbox metatable chain. No PM round-trip.
    -- =============================================
    syscall("kernel_log", "[SEC] [1/3] Crypto provider...")
    local bOk, oCrypto = pcall(require, "crypto")
    if bOk and oCrypto then
        local bInit, nTier = oCrypto.Init()
        if bInit then
            g_oCrypto = oCrypto
            syscall("kernel_log", "[SEC] [1/3] Data Card Tier " .. nTier)
        else
            syscall("kernel_log", "[SEC] [1/3] No data card. Hash-only mode.")
        end
    else
        syscall("kernel_log", "[SEC] [1/3] crypto.lua unavailable. UNSIGNED mode.")
    end

    -- =============================================
    -- STEP 2: Security policy (direct kernel read — NO PM)
    -- syscall("vfs_read_file") is NOT overridden to PM,
    -- it calls primitive_load() = raw filesystem access.
    -- =============================================
    syscall("kernel_log", "[SEC] [2/3] Security policy...")
    g_nSecurityLevel = (tConfig and tConfig.security_level) or 0

    local sCfgCode = syscall("vfs_read_file", "/etc/pki.cfg")
    if sCfgCode then
        local fCfg = load(sCfgCode, "pki.cfg", "t", {})
        if fCfg then
            local bCfgOk, tCfg = pcall(fCfg)
            if bCfgOk and type(tCfg) == "table" then
                g_nSecurityLevel = tCfg.security_level or g_nSecurityLevel
            end
        end
    end

    local tLevelNames = {
        [0] = "DISABLED", [1] = "WARN", [2] = "ENFORCE",
    }
    syscall("kernel_log", "[SEC] [2/3] Level " ..
            g_nSecurityLevel .. " (" ..
            (tLevelNames[g_nSecurityLevel] or "?") .. ")")

    -- =============================================
    -- STEP 3: Approved key store (direct kernel read — NO PM)
    -- We do NOT require("pki_client") here because it
    -- pulls in http → filesystem → PM round-trips.
    -- Instead we read the keystore file directly.
    -- =============================================
    syscall("kernel_log", "[SEC] [3/3] Key store...")
    g_tApprovedKeys = {}

    local sKeyCode = syscall("vfs_read_file", "/etc/pki_keystore.lua")
    if sKeyCode and #sKeyCode > 0 then
        local fKeys = load(sKeyCode, "keystore", "t", {})
        if fKeys then
            local bKeysOk, tKeys = pcall(fKeys)
            if bKeysOk and type(tKeys) == "table" then
                g_tApprovedKeys = tKeys
            end
        end
    end

    local nKeys = 0
    for _ in pairs(g_tApprovedKeys) do nKeys = nKeys + 1 end
    syscall("kernel_log", "[SEC] [3/3] " .. nKeys .. " approved key(s)")

    local nMs = math.floor((os.clock() - nStart) * 1000)
    syscall("kernel_log", "[SEC] ── Ready in " .. nMs .. "ms ──")

    g_bInitialized = true
    return true
end

-- Extract signature block from driver source code
local function fExtractSignature(sCode)
    local sSig, sSigner, sHash
    local sCodeBody = sCode
    
    -- Find and extract signature lines from end of file
    local tLines = {}
    for line in sCode:gmatch("[^\n]+") do
        tLines[#tLines + 1] = line
    end
    
    -- Scan last 5 lines for signature block
    local nSigStart = nil
    for i = math.max(1, #tLines - 4), #tLines do
        local line = tLines[i]
        if not sSig then
            local s = line:match("^%-%-@SIGNATURE:(.+)$")
            if s then sSig = s; nSigStart = nSigStart or i end
        end
        if not sSigner then
            local s = line:match("^%-%-@SIGNER:(.+)$")
            if s then sSigner = s; nSigStart = nSigStart or i end
        end
        if not sHash then
            local s = line:match("^%-%-@HASH:(.+)$")
            if s then sHash = s; nSigStart = nSigStart or i end
        end
    end
    
    -- Reconstruct code body without signature block
    if nSigStart then
        local tBody = {}
        for i = 1, nSigStart - 1 do
            tBody[#tBody + 1] = tLines[i]
        end
        sCodeBody = table.concat(tBody, "\n")
    end
    
    return sSig, sSigner, sHash, sCodeBody
end

-- Validate driver signature
function oSec.fValidateDriverSignature(sDriverCode)
    if not g_bInitialized then oSec.Initialize() end
    
    -- Security level 0 = no enforcement
    if g_nSecurityLevel == 0 then
        return tStatus.STATUS_SUCCESS
    end
    
    -- No crypto available
    if not g_oCrypto then
        if g_nSecurityLevel >= 2 then
            return tStatus.STATUS_DRIVER_VALIDATION_FAILED, 
                   "No data card: cannot verify signatures (enforcement mode)"
        end
        syscall("kernel_log", "[SEC] WARN: Loading unsigned driver (no data card)")
        return tStatus.STATUS_SUCCESS
    end
    
    -- Extract signature
    local sSig, sSigner, sExpectedHash, sCodeBody = fExtractSignature(sDriverCode)
    
    if not sSig or not sSigner then
        if g_nSecurityLevel >= 2 then
            return tStatus.STATUS_DRIVER_VALIDATION_FAILED,
                   "Driver is NOT SIGNED. Blocked by security policy."
        end
        syscall("kernel_log", "[SEC] WARN: Loading UNSIGNED driver")
        return tStatus.STATUS_SUCCESS
    end
    
    -- Verify hash matches code body
    local sActualHash = g_oCrypto.Encode64(g_oCrypto.SHA256(sCodeBody))
    if sExpectedHash and sActualHash ~= sExpectedHash then
        return tStatus.STATUS_DRIVER_VALIDATION_FAILED,
               "Hash mismatch: driver code was MODIFIED after signing"
    end
    
    -- Look up signer in approved keys
    local tKeyInfo = g_tApprovedKeys[sSigner]
    if not tKeyInfo then
        -- Try cloud lookup
        local bPkiOk, oPki = pcall(require, "pki_client")
        if bPkiOk then
            local sStatus = oPki.CheckKeyStatus(sSigner)
            if sStatus ~= "approved" then
                if g_nSecurityLevel >= 2 then
                    return tStatus.STATUS_DRIVER_VALIDATION_FAILED,
                           "Signing key " .. sSigner:sub(1,12) .. "... is NOT APPROVED (status: " .. sStatus .. ")"
                end
                syscall("kernel_log", "[SEC] WARN: Signer key not approved: " .. sSigner:sub(1,12))
                return tStatus.STATUS_SUCCESS
            end
        else
            if g_nSecurityLevel >= 2 then
                return tStatus.STATUS_DRIVER_VALIDATION_FAILED,
                       "Unknown signer and PKI unavailable"
            end
        end
    end
    
    -- ECDSA signature verification (Tier 3 only)
    if g_oCrypto.GetTier() >= 3 and tKeyInfo then
        local oPubKey = g_oCrypto.DeserializeKey(tKeyInfo.public_key, "ec-public")
        if oPubKey then
            local sSigRaw = g_oCrypto.Decode64(sSig)
            local bValid = g_oCrypto.Verify(sCodeBody, sSigRaw, oPubKey)
            
            if bValid then
                syscall("kernel_log", "[SEC] ✓ Signature VALID (signer: " .. 
                        (tKeyInfo.username or "?") .. ", key: " .. sSigner:sub(1,12) .. "...)")
                return tStatus.STATUS_SUCCESS
            else
                return tStatus.STATUS_DRIVER_VALIDATION_FAILED,
                       "Signature INVALID! Code may be tampered."
            end
        else
            syscall("kernel_log", "[SEC] WARN: Could not deserialize signer public key")
        end
    end
    
    -- If we get here with enforcement, hash-only verification passed
    syscall("kernel_log", "[SEC] Hash verified, ECDSA skipped (Tier < 3 or key unavailable)")
    return tStatus.STATUS_SUCCESS
end

-- Unchanged from original
function oSec.fValidateDriverInfo(tDriverInfo)
    if type(tDriverInfo) ~= "table" then
        return tStatus.STATUS_INVALID_DRIVER_INFO, "g_tDriverInfo is not a table"
    end
    if type(tDriverInfo.sDriverName) ~= "string" or #tDriverInfo.sDriverName == 0 then
        return tStatus.STATUS_INVALID_DRIVER_INFO, "Missing or invalid sDriverName"
    end
    if type(tDriverInfo.sDriverType) ~= "string" then
        return tStatus.STATUS_INVALID_DRIVER_INFO, "Missing sDriverType"
    end
    if tDriverInfo.sDriverType ~= tDKStructs.DRIVER_TYPE_KMD and 
       tDriverInfo.sDriverType ~= tDKStructs.DRIVER_TYPE_UMD and
       tDriverInfo.sDriverType ~= tDKStructs.DRIVER_TYPE_CMD then
        return tStatus.STATUS_INVALID_DRIVER_TYPE, "Unknown sDriverType"
    end
    if type(tDriverInfo.nLoadPriority) ~= "number" then
        return tStatus.STATUS_INVALID_DRIVER_INFO, "Missing nLoadPriority"
    end
    return tStatus.STATUS_SUCCESS
end

return oSec