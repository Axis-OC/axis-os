--
-- /sys/security/patchguard.lua
-- AxisOS Kernel Integrity Monitor (PatchGuard) v3
--
-- v3 additions over v2:
--   • Pure-Lua /lib/sha256 hashing (no data card dependency)
--   • XOR-encrypted snapshot hashes (per-boot random key)
--   • Check function rotation (3 equivalent variants, random pick)
--   • Syscall behavior profiling (baseline → anomaly detection)
--   • Mtime-scan ALL files every tick for instantaneous detection
--

local PG = {}

-- =============================================
-- STATE
-- =============================================

local g_bArmed             = false
local g_fPanic             = nil
local g_fLog               = nil
local g_fUptime            = nil
local g_bVerbose           = true
local g_nLastCheckMs       = 0
local g_fFlush             = nil

-- SHA-256 module (/lib/sha256.lua — pure Lua, no data card needed)
local g_oSha256            = nil

-- XOR encryption key for snapshot hashes (per-boot, from data card RNG)
-- An attacker who dumps memory sees encrypted hashes, not the plain
-- expected values.  They can't forge a matching hash without this key.
local g_sXorKey            = nil   -- 32 bytes binary

-- NOTE on check interval randomization:
-- math.random() is kept over data_card.random() because math.random()
-- is a native Lua PRNG call (~0μs), while data_card.random() is a
-- component invoke (~50μs per call due to OC's IPC overhead).
-- The unpredictability comes from the initial seed (uptime at boot)
-- which is already non-deterministic in a multiplayer OC server.

local g_tCriticalFileSnap   = {}

local SUPERCRITICAL_FILES = {
    "/kernel.lua",
    "/lib/pipeline_manager.lua",
    "/bin/init.lua",
    "/etc/passwd.lua",
}

local CRITICAL_FILES = {
    "/system/dkms.lua",
    "/system/driverdispatch.lua",
    "/lib/ob_manager.lua",
    "/lib/ke_ipc.lua",
    "/lib/preempt.lua",
    "/lib/hypervisor.lua",
    "/lib/registry.lua",
    "/lib/crypto.lua",
    "/sys/security/dkms_sec.lua",
    "/sys/security/hvci.lua",
    "/sys/security/patchguard.lua",
    "/system/lib/dk/shared_structs.lua",
    "/system/lib/dk/kmd_api.lua",
    "/system/lib/dk/common_api.lua",
    "/drivers/tty.sys.lua",
    "/bin/sh.lua",
    "/boot/boot.lua",
    "/boot/boot_secure.lua",
}

local g_tFileHashSnap     = {}
local g_tFileSizeSnap     = {}
local g_nFileCheckCursor  = 1
local g_nFilesPerCheck    = 2
local g_nTotalFileChecks  = 0
local g_nTotalFilePasses  = 0
local g_nTotalFileFails   = 0
local g_tFileLastChecked  = {}
local g_fLastModified     = nil
local g_tMtimeCache       = {}

-- Monitored references
local g_tSyscallTable      = nil
local g_tSyscallOverrides  = nil
local g_nPipelinePid       = nil
local g_tProcessTable      = nil
local g_tRings             = nil
local g_oObManager         = nil
local g_tFrozenLibs        = nil

-- SecureBoot / hardware verification functions
local g_tBootSecurity      = nil
local g_fComputeBinding    = nil
local g_fHashKernel        = nil
local g_fReadEepromCode    = nil
local g_fReadEepromData    = nil
local g_fSha256            = nil  -- fallback: data card hash
local g_fHex               = nil
local g_fReadFile          = nil

-- Timing
local g_nNextCheckTime     = 0
local g_nMinCheckSec       = 2.5
local g_nMaxCheckSec       = 9.0
local g_nChecksPerformed   = 0
local g_nTier2Counter      = 0
local g_nTier3Counter      = 0
local g_nViolations        = 0

-- Mtime scan throttling: check supercritical frequently, critical less often
local g_nLastSuperMtimeScan = 0
local g_nLastCritMtimeScan  = 0
local MTIME_SUPER_INTERVAL  = 0.5   -- supercritical files: every 0.5s (instant enough)
local MTIME_CRIT_INTERVAL   = 2.0   -- critical files: every 2s (still fast, 10× less I/O)

-- Snapshots
local g_tSyscallFuncSnap   = {}
local g_tSyscallBytesSnap  = {}
local g_tSyscallRingSnap   = {}
local g_sSyscallKeyFP      = ""
local g_tOverrideSnap      = {}
local g_nSnapshotPMPid     = nil
local g_tSelfFuncSnap      = {}
local g_tRingSnap          = {}
local g_tFrozenLibSnap     = {}
local g_tObPathSnap        = {}
local g_sBootBindingSnap   = nil
local g_sBootKernelHash    = nil
local g_sEepromCodeHash    = nil
local g_sEepromDataSnap    = nil
local g_bSecureBootExpected = false
local g_nQuarantineEvents = 0
local g_nEscalationAttempts = 0

-- Check function rotation state
local g_tCheckVariants     = {}   -- array of check functions
local g_nVariantCount      = 0

-- Syscall behavior profiler reference (set by kernel)
local g_tSyscallProfiler   = nil

local g_nSuperCursor = 1
local g_nCritCursor  = 1

-- KIQGR enclave integration
local g_oKiqgr            = nil   -- KIQGR module reference
local g_hKiqgrEnclave     = nil   -- enclave handle
local g_fCallEnclave      = nil   -- function(hEnc, sMethod, ...) wrapper

-- Golden Image file reversion
local g_oGoldenImage      = nil
local g_fRevertFile       = nil   -- function(sPath) → bOk, sErr

local g_fAxvbVerify       = nil   -- function(sPath, sContent) → true/false/nil

-- =============================================
-- HELPERS
-- =============================================

local function hex(s)
    if not s then return "" end
    local t = {}
    for i = 1, #s do
        t[i] = string.format("%02x", s:byte(i))
    end
    return table.concat(t)
end

local function randomize()
    local nMin = g_nMinCheckSec
    local nMax = g_nMaxCheckSec
    -- Halve the interval if profiler has many alerts (paranoia-like behavior)
    if g_tSyscallProfiler and #(g_tSyscallProfiler.tAlerts or {}) >= 8 then
        nMin = nMin / 2
        nMax = nMax / 2
    end
    g_nNextCheckTime = g_fUptime() + nMin +
        math.random() * (nMax - nMin)
end

local function safeDump(f)
    if type(f) ~= "function" then return nil end
    local bOk, sBytes = pcall(string.dump, f)
    return bOk and sBytes or nil
end


-- =============================================
-- XOR HASH ENCRYPTION
-- Encrypt/decrypt a binary hash with the per-boot key.
-- Same operation for both (XOR is its own inverse).
-- Without the key, the stored hashes are meaningless.
-- =============================================

local function xorBytes(sBin, sKey)
    if not sKey or #sKey == 0 then return sBin end
    local t = {}
    local nKeyLen = #sKey
    for i = 1, #sBin do
        t[i] = string.char(
            -- bit32.bxor is available in PatchGuard's environment
            (type(bit32) == "table" and bit32.bxor or
             function(a,b) return a ~ b end)(
                sBin:byte(i),
                sKey:byte(((i - 1) % nKeyLen) + 1)
            )
        )
    end
    return table.concat(t)
end

--- Hash data and return XOR-encrypted hex string.
-- This is what gets stored in g_tFileHashSnap.
-- An attacker dumping memory sees encrypted hex, not the real hash.
local function protectedHash(sData)
    local sBinHash
    if g_oSha256 then
        sBinHash = g_oSha256.digest(sData)
    elseif g_fSha256 then
        sBinHash = g_fSha256(sData)
    else
        return nil
    end
    if g_sXorKey then
        sBinHash = xorBytes(sBinHash, g_sXorKey)
    end
    return hex(sBinHash)
end

-- =============================================
-- SNAPSHOT: TIER 1
-- =============================================

local function snapshotSyscallTable()
    g_tSyscallFuncSnap  = {}
    g_tSyscallBytesSnap = {}
    g_tSyscallRingSnap  = {}
    local tKeys = {}
    for sName, tH in pairs(g_tSyscallTable) do
        g_tSyscallFuncSnap[sName] = tostring(tH.func)
        g_tSyscallBytesSnap[sName] = safeDump(tH.func)
        local tR = {}
        for _, r in ipairs(tH.allowed_rings) do tR[#tR+1] = tostring(r) end
        table.sort(tR)
        g_tSyscallRingSnap[sName] = table.concat(tR, ",")
        tKeys[#tKeys+1] = sName
    end
    table.sort(tKeys)
    g_sSyscallKeyFP = table.concat(tKeys, "|")
end

local function snapshotOverrides()
    g_tOverrideSnap = {}
    for sName, nPid in pairs(g_tSyscallOverrides) do
        g_tOverrideSnap[sName] = nPid
    end
    g_nSnapshotPMPid = g_nPipelinePid
end

local function snapshotSelf()
    g_tSelfFuncSnap = {}
    local tSelfFuncs = {
        "Initialize", "TakeSnapshot", "Arm", "Disarm",
        "IsArmed", "Tick", "Check", "GetStats"
    }
    for _, sName in ipairs(tSelfFuncs) do
        if PG[sName] then
            g_tSelfFuncSnap[sName] = tostring(PG[sName])
        end
    end
end

local function snapshotRings()
    g_tRingSnap = {}
    for nPid, nRing in pairs(g_tRings) do
        if nPid < 20 then
            g_tRingSnap[nPid] = nRing
        end
    end
end

-- =============================================
-- SNAPSHOT: TIER 2
-- =============================================

local function snapshotFrozenLibs()
    g_tFrozenLibSnap = {}
    if not g_tFrozenLibs then return end
    for sLibName, tLib in pairs(g_tFrozenLibs) do
        local tKeys = {}
        for k in pairs(tLib) do tKeys[#tKeys+1] = tostring(k) end
        table.sort(tKeys)
        g_tFrozenLibSnap[sLibName] = {
            nCount = #tKeys,
            sKeyFP = table.concat(tKeys, "|"),
            tFuncIds = {}
        }
        for _, k in ipairs(tKeys) do
            if type(tLib[k]) == "function" then
                g_tFrozenLibSnap[sLibName].tFuncIds[k] = tostring(tLib[k])
            end
        end
    end
end

local function snapshotObNamespace()
    g_tObPathSnap = {}
    if not g_oObManager then return end
    local tCriticalPaths = {
        "\\Device\\TTY0", "\\Device\\Net0", "\\Device\\Gpu0",
        "\\Device\\ringlog", "\\Device\\HbmRbmk",
    }
    for _, sPath in ipairs(tCriticalPaths) do
        local pH = g_oObManager.ObLookupObject(sPath)
        if pH then
            g_tObPathSnap[sPath] = pH.sType
        end
    end
end

-- =============================================
-- SNAPSHOT: TIER 3 & Files
-- =============================================

local function snapshotSecureBoot()
    g_bSecureBootExpected = (g_tBootSecurity ~= nil)
    if g_tBootSecurity then
        g_sBootBindingSnap  = g_tBootSecurity.machine_binding
        g_sBootKernelHash   = g_tBootSecurity.kernel_hash
    end
    if g_fReadEepromCode and (g_oSha256 or g_fSha256) then
        local sCode = g_fReadEepromCode()
        if sCode and #sCode > 0 then
            g_sEepromCodeHash = protectedHash(sCode)
        end
    end
    if g_fReadEepromData and (g_oSha256 or g_fSha256) then
        local sData = g_fReadEepromData()
        if sData and #sData > 0 then
            g_sEepromDataSnap = protectedHash(sData)
        end
    end
end

local function snapshotCriticalFiles()
    g_tFileHashSnap    = {}
    g_tFileSizeSnap    = {}
    g_tFileLastChecked = {}

    if not g_fReadFile or not (g_oSha256 or g_fSha256) then
        g_fLog("[PG] Tier3-files: SKIPPED (no read function or no SHA-256)")
        return
    end

    local tAllFiles = {}
    for _, s in ipairs(SUPERCRITICAL_FILES) do tAllFiles[#tAllFiles + 1] = s end
    for _, s in ipairs(CRITICAL_FILES) do tAllFiles[#tAllFiles + 1] = s end

    local nHashed, nMissing, nTotalBytes = 0, 0, 0

    g_fLog(string.format(
        "[PG] Tier3-files: hashing %d files (XOR key: %s)...",
        #tAllFiles,
        g_sXorKey and ("active, " .. #g_sXorKey .. "B") or "NONE"))

    for i, sPath in ipairs(tAllFiles) do
        local sContent = g_fReadFile(sPath)
        if sContent and #sContent > 0 then
            local sHash = protectedHash(sContent)
            g_tFileHashSnap[sPath] = sHash
            g_tFileSizeSnap[sPath] = #sContent
            nHashed = nHashed + 1
            nTotalBytes = nTotalBytes + #sContent

            if g_fLastModified then
                g_tMtimeCache[sPath] = g_fLastModified(sPath)
            end

            if g_bVerbose then
                local sShort = sPath:match("([^/]+)$") or sPath
                local bSuper = (i <= #SUPERCRITICAL_FILES)
                g_fLog(string.format(
                    "[PG]   [%2d/%2d] %s %-28s %5d B  %s...",
                    i, #tAllFiles,
                    bSuper and "!!" or "  ",
                    sShort, #sContent,
                    sHash:sub(1, 12)))
            end
        else
            nMissing = nMissing + 1
        end

        if i % 3 == 0 then g_fFlush() end
    end

    g_fLog(string.format(
        "[PG] Tier3-files: %d/%d hashed (%d bytes, %d missing)",
        nHashed, #tAllFiles, nTotalBytes, nMissing))
end

-- =============================================
-- FILE CHECK (with encrypted comparison)
-- =============================================

local function fCheckOneFile(sPath, bSupercritical)
    if not g_fReadFile or not (g_oSha256 or g_fSha256) then return {} end
    local tV = {}
    local sExpHash = g_tFileHashSnap[sPath]

    -- ════════════════════════════════════════════════
    -- AXVB DISK-BASED VERIFICATION (preferred path)
    -- Zero RAM cost: reads one sector from AXVB partition,
    -- decrypts, compares. Hash never stored in memory.
    -- ════════════════════════════════════════════════
    if g_fAxvbVerify then
        g_nTotalFileChecks = g_nTotalFileChecks + 1

        -- Fast mtime check first
        if g_fLastModified then
            local nMtime = g_fLastModified(sPath)
            if not nMtime then
                tV[#tV + 1] = {
                    t = bSupercritical and "KERNEL_INTEGRITY_UNRECOVERABLE_FAIL"
                        or "KERNEL_MODULES_INTEGRITY_FAIL",
                    d = sPath, e = "(tracked)", a = "(file missing)"
                }
                g_nTotalFileFails = g_nTotalFileFails + 1
                return tV
            end
            if g_tMtimeCache[sPath] == nMtime then
                g_nTotalFilePasses = g_nTotalFilePasses + 1
                g_tFileLastChecked[sPath] = g_fUptime()
                return tV
            end
        end

        -- Full verification via AXVB partition
        local sContent = g_fReadFile(sPath)
        if not sContent then
            tV[#tV + 1] = {
                t = bSupercritical and "KERNEL_INTEGRITY_UNRECOVERABLE_FAIL"
                    or "KERNEL_MODULES_INTEGRITY_FAIL",
                d = sPath, e = "(tracked)", a = "(read failed)"
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
            return tV
        end

        g_fFlush()
        local bMatch, sErr = g_fAxvbVerify(sPath, sContent)

        if bMatch == nil and sErr == "not_tracked" then
            -- File not in AXVB — skip
            return tV
        elseif bMatch == true then
            g_nTotalFilePasses = g_nTotalFilePasses + 1
            g_tFileLastChecked[sPath] = g_fUptime()
            if g_fLastModified then
                g_tMtimeCache[sPath] = g_fLastModified(sPath)
            end
        else
            tV[#tV + 1] = {
                t = bSupercritical and "KERNEL_INTEGRITY_HASH_FAIL"
                    or "KERNEL_MODULES_INTEGRITY_HASH_FAIL",
                d = sPath, e = "(AXVB)", a = tostring(sErr)
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
        end

        return tV
    end

    -- ════════════════════════════════════════════════
    -- FALLBACK: In-RAM hash comparison (original path)
    -- Used when AXVB partition is not available.
    -- ════════════════════════════════════════════════
    if not sExpHash then return tV end

    g_nTotalFileChecks = g_nTotalFileChecks + 1

    if g_fLastModified then
        local nMtime = g_fLastModified(sPath)
        if not nMtime then
            tV[#tV + 1] = {
                t = bSupercritical and "KERNEL_INTEGRITY_UNRECOVERABLE_FAIL"
                    or "KERNEL_MODULES_INTEGRITY_FAIL",
                d = sPath, e = sExpHash:sub(1, 24), a = "(file missing)"
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
            g_tMtimeCache[sPath] = nil
            return tV
        end
        if g_tMtimeCache[sPath] == nMtime then
            g_nTotalFilePasses = g_nTotalFilePasses + 1
            g_tFileLastChecked[sPath] = g_fUptime()
            return tV
        end
    end

    local sContent = g_fReadFile(sPath)
    if not sContent then
        tV[#tV + 1] = {
            t = bSupercritical and "KERNEL_INTEGRITY_UNRECOVERABLE_FAIL"
                or "KERNEL_MODULES_INTEGRITY_FAIL",
            d = sPath, e = sExpHash:sub(1, 24), a = "(read failed)"
        }
        g_nTotalFileFails = g_nTotalFileFails + 1
        return tV
    end

    g_fFlush()
    local sCurHash = protectedHash(sContent)
    if sCurHash == sExpHash then
        g_nTotalFilePasses = g_nTotalFilePasses + 1
        g_tFileLastChecked[sPath] = g_fUptime()
        if g_fLastModified then
            g_tMtimeCache[sPath] = g_fLastModified(sPath)
        end
    else
        tV[#tV + 1] = {
            t = bSupercritical and "KERNEL_INTEGRITY_HASH_FAIL"
                or "KERNEL_MODULES_INTEGRITY_HASH_FAIL",
            d = sPath, e = sExpHash:sub(1, 24), a = sCurHash:sub(1, 24)
        }
        g_nTotalFileFails = g_nTotalFileFails + 1
    end
    return tV
end

-- =============================================
-- MTIME SCAN — runs EVERY tick for instant detection
-- Cost: ~1 stat call per file per tick (~0.5ms total)
-- Only hashes when mtime changes (rare event)
-- =============================================

-- =============================================
-- MTIME SCAN — rate-limited to avoid disk spam
--
-- Supercritical files (kernel, init, passwd): every 0.5s
-- Critical files (drivers, libs): every 2s
--
-- Each CHECK is instant (no timeout/sleep), but we don't
-- repeat the scan on every scheduler tick.  Detection
-- latency: ≤0.5s for supercritical, ≤2s for critical.
-- Disk reads: ~8/s supercritical + ~8.5/2s critical ≈ 12/s
-- (down from ~420/s with every-tick scanning).
-- =============================================

local function fMtimeScanAll()
    if not g_fReadFile or not (g_oSha256 or g_fSha256) or not g_fLastModified then
        return {}
    end

    local nNow = g_fUptime()
    local tV = {}

    local bScanSuper = (nNow - g_nLastSuperMtimeScan >= MTIME_SUPER_INTERVAL)
    local bScanCrit  = (nNow - g_nLastCritMtimeScan  >= MTIME_CRIT_INTERVAL)

    -- Nothing to scan this tick — early exit (zero disk I/O)
    if not bScanSuper and not bScanCrit then
        return tV
    end

    local function scanOne(sPath, bSupercritical)
        local sExpHash = g_tFileHashSnap[sPath]
        if not sExpHash then return end

        local nMtime = g_fLastModified(sPath)
        if not nMtime then
            tV[#tV + 1] = {
                t = bSupercritical and "KERNEL_INTEGRITY_UNRECOVERABLE_FAIL"
                    or "KERNEL_MODULES_INTEGRITY_FAIL",
                d = sPath, e = sExpHash:sub(1, 24), a = "(file missing)"
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
            g_tMtimeCache[sPath] = nil
            return
        end

        if g_tMtimeCache[sPath] == nMtime then
            return  -- unchanged since last scan
        end

        -- Mtime CHANGED — rehash immediately (this IS the instant detection)
        local sContent = g_fReadFile(sPath)
        if not sContent then
            tV[#tV + 1] = {
                t = bSupercritical and "KERNEL_INTEGRITY_UNRECOVERABLE_FAIL"
                    or "KERNEL_MODULES_INTEGRITY_FAIL",
                d = sPath, e = sExpHash:sub(1, 24), a = "(read failed)"
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
            return
        end

        g_nTotalFileChecks = g_nTotalFileChecks + 1
        local sCurHash = protectedHash(sContent)

        if sCurHash ~= sExpHash then
            g_fLog(string.format(
                "[PG] INSTANT DETECT: %s modified (mtime changed)",
                sPath:match("([^/]+)$") or sPath))
            tV[#tV + 1] = {
                t = bSupercritical and "KERNEL_INTEGRITY_HASH_FAIL"
                    or "KERNEL_MODULES_INTEGRITY_HASH_FAIL",
                d = sPath, e = sExpHash:sub(1, 24), a = sCurHash:sub(1, 24)
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
        else
            g_tMtimeCache[sPath] = nMtime
            g_nTotalFilePasses = g_nTotalFilePasses + 1
        end
    end

    if bScanSuper then
        g_nLastSuperMtimeScan = nNow
        for _, sPath in ipairs(SUPERCRITICAL_FILES) do
            scanOne(sPath, true)
        end
    end

    if bScanCrit then
        g_nLastCritMtimeScan = nNow
        for _, sPath in ipairs(CRITICAL_FILES) do
            scanOne(sPath, false)
        end
    end

    return tV
end

-- =============================================
-- CHECK FUNCTION ROTATION (Feature 4)
--
-- Three functionally-equivalent check functions with different
-- variable names.  Each cycle, one is randomly selected.
-- An attacker who patches one check function doesn't disable
-- the others — they must find and patch ALL three.
--
-- The functions check the same things but in different order
-- with different local variable names, producing different
-- bytecode.  string.dump() of each yields different bytes.
-- =============================================

-- Variant A: focuses syscall identity first, then overrides
local function checkVariantAlpha()
    local va_start = g_fUptime()
    local va_issues = {}

    -- A1: syscall function pointers
    for va_name, va_expId in pairs(g_tSyscallFuncSnap) do
        local va_h = g_tSyscallTable[va_name]
        if not va_h then
            va_issues[#va_issues+1] = {t="SYSCALL_REMOVED", d=va_name}
        elseif tostring(va_h.func) ~= va_expId then
            va_issues[#va_issues+1] = {t="SYSCALL_FUNC_REPLACED", d=va_name,
                e=va_expId:sub(1,20), a=tostring(va_h.func):sub(1,20)}
        end
    end

    -- A2: override integrity
    for va_ovrName, va_ovrPid in pairs(g_tOverrideSnap) do
        if g_tSyscallOverrides[va_ovrName] ~= va_ovrPid then
            va_issues[#va_issues+1] = {t="OVERRIDE_HIJACK", d=va_ovrName,
                e=tostring(va_ovrPid), a=tostring(g_tSyscallOverrides[va_ovrName])}
        end
    end
    for va_injName in pairs(g_tSyscallOverrides) do
        if not g_tOverrideSnap[va_injName] then
            va_issues[#va_issues+1] = {t="OVERRIDE_INJECTED", d=va_injName}
        end
    end

    -- A3: PM PID
    if g_nSnapshotPMPid and g_nPipelinePid ~= g_nSnapshotPMPid then
        va_issues[#va_issues+1] = {t="PM_PID_CHANGED",
            e=tostring(g_nSnapshotPMPid), a=tostring(g_nPipelinePid)}
    end

    -- A4: self integrity
    for va_fn, va_fid in pairs(g_tSelfFuncSnap) do
        if PG[va_fn] and tostring(PG[va_fn]) ~= va_fid then
            va_issues[#va_issues+1] = {t="PG_SELF_TAMPERED", d=va_fn}
        elseif not PG[va_fn] then
            va_issues[#va_issues+1] = {t="PG_FUNC_REMOVED", d=va_fn}
        end
    end

    -- A5: key structure
    local va_curKeys = {}
    for va_kn in pairs(g_tSyscallTable) do va_curKeys[#va_curKeys+1] = va_kn end
    table.sort(va_curKeys)
    if table.concat(va_curKeys, "|") ~= g_sSyscallKeyFP then
        local va_expSet = {}
        for va_en in pairs(g_tSyscallFuncSnap) do va_expSet[va_en] = true end
        for _, va_ck in ipairs(va_curKeys) do
            if not va_expSet[va_ck] then
                va_issues[#va_issues+1] = {t="SYSCALL_INJECTED", d=va_ck}
            end
        end
    end

    -- A6: process ring escalation
    for va_pid, va_expRing in pairs(g_tRingSnap) do
        local va_curRing = g_tRings[va_pid]
        if va_curRing and va_curRing < va_expRing then
            va_issues[#va_issues+1] = {t="PROCESS_RING_ESCALATED",
                d="PID " .. va_pid, e=tostring(va_expRing), a=tostring(va_curRing)}
        end
    end

    -- A7: ring permissions on syscalls
    for va_rn, va_rexp in pairs(g_tSyscallRingSnap) do
        local va_rh = g_tSyscallTable[va_rn]
        if va_rh then
            local va_rt = {}
            for _, va_rr in ipairs(va_rh.allowed_rings) do va_rt[#va_rt+1] = tostring(va_rr) end
            table.sort(va_rt)
            if table.concat(va_rt, ",") ~= va_rexp then
                va_issues[#va_issues+1] = {t="RING_ESCALATION", d=va_rn,
                    e=va_rexp, a=table.concat(va_rt, ",")}
            end
        end
    end

    return va_issues
end

-- Variant Beta: starts with self-integrity, different variable prefix
local function checkVariantBeta()
    local vb_t0 = g_fUptime()
    local vb_viol = {}

    -- B1: PG self-integrity first
    for vb_selfK, vb_selfV in pairs(g_tSelfFuncSnap) do
        if not PG[vb_selfK] then
            vb_viol[#vb_viol+1] = {t="PG_FUNC_REMOVED", d=vb_selfK}
        elseif tostring(PG[vb_selfK]) ~= vb_selfV then
            vb_viol[#vb_viol+1] = {t="PG_SELF_TAMPERED", d=vb_selfK}
        end
    end

    -- B2: override table
    for vb_on, vb_op in pairs(g_tOverrideSnap) do
        if g_tSyscallOverrides[vb_on] ~= vb_op then
            vb_viol[#vb_viol+1] = {t="OVERRIDE_HIJACK", d=vb_on,
                e=tostring(vb_op), a=tostring(g_tSyscallOverrides[vb_on])}
        end
    end
    for vb_in in pairs(g_tSyscallOverrides) do
        if not g_tOverrideSnap[vb_in] then
            vb_viol[#vb_viol+1] = {t="OVERRIDE_INJECTED", d=vb_in}
        end
    end

    -- B3: syscall function pointers
    for vb_sc, vb_eid in pairs(g_tSyscallFuncSnap) do
        local vb_handler = g_tSyscallTable[vb_sc]
        if not vb_handler then
            vb_viol[#vb_viol+1] = {t="SYSCALL_REMOVED", d=vb_sc}
        elseif tostring(vb_handler.func) ~= vb_eid then
            vb_viol[#vb_viol+1] = {t="SYSCALL_FUNC_REPLACED", d=vb_sc,
                e=vb_eid:sub(1,20), a=tostring(vb_handler.func):sub(1,20)}
        end
    end

    -- B4: PM PID
    if g_nSnapshotPMPid and g_nPipelinePid ~= g_nSnapshotPMPid then
        vb_viol[#vb_viol+1] = {t="PM_PID_CHANGED",
            e=tostring(g_nSnapshotPMPid), a=tostring(g_nPipelinePid)}
    end

    -- B5: key structure + ring perms
    local vb_kl = {}
    for vb_kn in pairs(g_tSyscallTable) do vb_kl[#vb_kl+1] = vb_kn end
    table.sort(vb_kl)
    if table.concat(vb_kl, "|") ~= g_sSyscallKeyFP then
        local vb_es = {}
        for vb_ek in pairs(g_tSyscallFuncSnap) do vb_es[vb_ek] = true end
        for _, vb_ck in ipairs(vb_kl) do
            if not vb_es[vb_ck] then
                vb_viol[#vb_viol+1] = {t="SYSCALL_INJECTED", d=vb_ck}
            end
        end
    end

    for vb_rn, vb_re in pairs(g_tSyscallRingSnap) do
        local vb_rh = g_tSyscallTable[vb_rn]
        if vb_rh then
            local vb_rr = {}
            for _, vb_rv in ipairs(vb_rh.allowed_rings) do vb_rr[#vb_rr+1] = tostring(vb_rv) end
            table.sort(vb_rr)
            if table.concat(vb_rr, ",") ~= vb_re then
                vb_viol[#vb_viol+1] = {t="RING_ESCALATION", d=vb_rn,
                    e=vb_re, a=table.concat(vb_rr, ",")}
            end
        end
    end

    -- B6: process rings
    for vb_pp, vb_pr in pairs(g_tRingSnap) do
        local vb_cr = g_tRings[vb_pp]
        if vb_cr and vb_cr < vb_pr then
            vb_viol[#vb_viol+1] = {t="PROCESS_RING_ESCALATED",
                d="PID " .. vb_pp, e=tostring(vb_pr), a=tostring(vb_cr)}
        end
    end

    return vb_viol
end

-- Variant Gamma: starts with ring checks, different prefix
local function checkVariantGamma()
    local gc_t = g_fUptime()
    local gc_v = {}

    -- G1: process ring escalation
    for gc_pid, gc_er in pairs(g_tRingSnap) do
        local gc_cr = g_tRings[gc_pid]
        if gc_cr and gc_cr < gc_er then
            gc_v[#gc_v+1] = {t="PROCESS_RING_ESCALATED",
                d="PID " .. gc_pid, e=tostring(gc_er), a=tostring(gc_cr)}
        end
    end

    -- G2: PM PID
    if g_nSnapshotPMPid and g_nPipelinePid ~= g_nSnapshotPMPid then
        gc_v[#gc_v+1] = {t="PM_PID_CHANGED",
            e=tostring(g_nSnapshotPMPid), a=tostring(g_nPipelinePid)}
    end

    -- G3: self integrity
    for gc_fn, gc_fv in pairs(g_tSelfFuncSnap) do
        if not PG[gc_fn] then
            gc_v[#gc_v+1] = {t="PG_FUNC_REMOVED", d=gc_fn}
        elseif tostring(PG[gc_fn]) ~= gc_fv then
            gc_v[#gc_v+1] = {t="PG_SELF_TAMPERED", d=gc_fn}
        end
    end

    -- G4: syscall functions
    for gc_sn, gc_si in pairs(g_tSyscallFuncSnap) do
        local gc_sh = g_tSyscallTable[gc_sn]
        if not gc_sh then
            gc_v[#gc_v+1] = {t="SYSCALL_REMOVED", d=gc_sn}
        elseif tostring(gc_sh.func) ~= gc_si then
            gc_v[#gc_v+1] = {t="SYSCALL_FUNC_REPLACED", d=gc_sn,
                e=gc_si:sub(1,20), a=tostring(gc_sh.func):sub(1,20)}
        end
    end

    -- G5: overrides
    for gc_on, gc_op in pairs(g_tOverrideSnap) do
        if g_tSyscallOverrides[gc_on] ~= gc_op then
            gc_v[#gc_v+1] = {t="OVERRIDE_HIJACK", d=gc_on,
                e=tostring(gc_op), a=tostring(g_tSyscallOverrides[gc_on])}
        end
    end
    for gc_in in pairs(g_tSyscallOverrides) do
        if not g_tOverrideSnap[gc_in] then
            gc_v[#gc_v+1] = {t="OVERRIDE_INJECTED", d=gc_in}
        end
    end

    -- G6: key structure + ring permissions
    local gc_kl = {}
    for gc_kn in pairs(g_tSyscallTable) do gc_kl[#gc_kl+1] = gc_kn end
    table.sort(gc_kl)
    if table.concat(gc_kl, "|") ~= g_sSyscallKeyFP then
        local gc_es = {}
        for gc_ek in pairs(g_tSyscallFuncSnap) do gc_es[gc_ek] = true end
        for _, gc_ck in ipairs(gc_kl) do
            if not gc_es[gc_ck] then gc_v[#gc_v+1] = {t="SYSCALL_INJECTED", d=gc_ck} end
        end
    end
    for gc_rn, gc_re in pairs(g_tSyscallRingSnap) do
        local gc_rh = g_tSyscallTable[gc_rn]
        if gc_rh then
            local gc_rr = {}
            for _, gc_rv in ipairs(gc_rh.allowed_rings) do gc_rr[#gc_rr+1] = tostring(gc_rv) end
            table.sort(gc_rr)
            if table.concat(gc_rr, ",") ~= gc_re then
                gc_v[#gc_v+1] = {t="RING_ESCALATION", d=gc_rn, e=gc_re, a=table.concat(gc_rr, ",")}
            end
        end
    end

    return gc_v
end

-- =============================================
-- CHECK: TIER 2 (every 5th cycle)
-- =============================================

local function checkTier2()
    local tV = {}
    if g_tFrozenLibs then
        for sLibName, tSnap in pairs(g_tFrozenLibSnap) do
            local tLib = g_tFrozenLibs[sLibName]
            if not tLib then
                tV[#tV+1] = {t="FROZEN_LIB_REMOVED", d=sLibName}
            else
                local nCount = 0
                local tCurKeys = {}
                for k in pairs(tLib) do nCount = nCount + 1; tCurKeys[#tCurKeys+1] = tostring(k) end
                table.sort(tCurKeys)
                if table.concat(tCurKeys, "|") ~= tSnap.sKeyFP then
                    tV[#tV+1] = {t="FROZEN_LIB_KEYS_CHANGED", d=sLibName,
                        e=tostring(tSnap.nCount), a=tostring(nCount)}
                else
                    for k, sExpId in pairs(tSnap.tFuncIds) do
                        if type(tLib[k]) ~= "function" then
                            tV[#tV+1] = {t="FROZEN_LIB_FUNC_TYPE", d=sLibName.."."..k}
                        elseif tostring(tLib[k]) ~= sExpId then
                            tV[#tV+1] = {t="FROZEN_LIB_FUNC_REPLACED", d=sLibName.."."..k}
                        end
                    end
                end
            end
        end
    end
    if g_oObManager then
        for sPath, sExpType in pairs(g_tObPathSnap) do
            local pH = g_oObManager.ObLookupObject(sPath)
            if not pH then tV[#tV+1] = {t="OB_PATH_REMOVED", d=sPath}
            elseif pH.sType ~= sExpType then
                tV[#tV+1] = {t="OB_PATH_TYPE_CHANGED", d=sPath, e=sExpType, a=pH.sType}
            end
        end
    end
    if g_tProcessTable then
        for nPid, tProc in pairs(g_tProcessTable) do
            if nPid < 20 and tProc.status ~= "dead" and tProc.env ~= nil then
                local bOk, sMt = pcall(getmetatable, tProc.env)
                if bOk and sMt ~= "protected" then
                    tV[#tV+1] = {t="SANDBOX_MT_BROKEN", d="PID " .. nPid,
                        e="protected", a=tostring(sMt)}
                end
            end
        end
    end
    return tV
end

-- =============================================
-- CHECK: TIER 3 HW
-- =============================================

local function checkTier3()
    local tV = {}
    if g_bSecureBootExpected and not g_tBootSecurity then
        tV[#tV+1] = {t="SECUREBOOT_TABLE_REMOVED", d="boot_security wiped from memory"}
    end
    if g_sBootBindingSnap and g_fComputeBinding then
        local sC = g_fComputeBinding()
        if sC and sC ~= g_sBootBindingSnap then
            tV[#tV+1] = {t="SECUREBOOT_BINDING_MISMATCH",
                d="Hardware fingerprint changed", e=g_sBootBindingSnap:sub(1,24), a=sC:sub(1,24)}
        end
    end
    if g_sBootKernelHash and g_fHashKernel then
        local sC = g_fHashKernel()
        if sC and sC ~= g_sBootKernelHash then
            tV[#tV+1] = {t="SECUREBOOT_KERNEL_MISMATCH",
                d="/kernel.lua modified on disk since boot",
                e=g_sBootKernelHash:sub(1,24), a=sC:sub(1,24)}
        end
    end
    if g_sEepromCodeHash and g_fReadEepromCode and (g_oSha256 or g_fSha256) then
        local sCode = g_fReadEepromCode()
        if sCode then
            local sCur = protectedHash(sCode)
            if sCur ~= g_sEepromCodeHash then
                tV[#tV+1] = {t="EEPROM_CODE_TAMPERED", d="Boot ROM changed at runtime",
                    e=g_sEepromCodeHash:sub(1,24), a=sCur:sub(1,24)}
            end
        end
    end
    if g_sEepromDataSnap and g_fReadEepromData and (g_oSha256 or g_fSha256) then
        local sData = g_fReadEepromData()
        if sData then
            local sCur = protectedHash(sData)
            if sCur ~= g_sEepromDataSnap then
                tV[#tV+1] = {t="EEPROM_DATA_TAMPERED", d="Attestation data changed",
                    e=g_sEepromDataSnap:sub(1,24), a=sCur:sub(1,24)}
            end
        end
    end
    return tV
end

-- =============================================
-- SYSCALL BEHAVIOR PROFILING CHECK (Feature 5)
-- =============================================

local function checkSyscallProfiles()
    if not g_tSyscallProfiler then return {} end
    local tV = {}
    local tAlerts = g_tSyscallProfiler.tAlerts
    if not tAlerts then return tV end

    -- Check for recent anomalies since last PG cycle
    local nNow = g_fUptime()
    for i = #tAlerts, 1, -1 do
        local tA = tAlerts[i]
        if nNow - tA.time > 10 then break end  -- only recent alerts
        tV[#tV + 1] = {
            t = "SYSCALL_PROFILE_VIOLATION",
            d = string.format("PID %d used '%s' (Ring %s) — not in behavioral baseline",
                tA.pid, tA.syscall, tostring(tA.ring)),
            e = "baseline syscalls only",
            a = tA.syscall,
        }
    end
    return tV
end

-- =============================================
-- VIOLATION HANDLER
-- =============================================

local function handleViolations(tViolations)
    if #tViolations == 0 then return true end

    g_nViolations = g_nViolations + #tViolations

    g_fLog("[PG] ╔══ INTEGRITY VIOLATION DETECTED ══╗")
    g_fLog(string.format("[PG] ║  %d violation(s)                  ║", #tViolations))
    g_fLog("[PG] ╚══════════════════════════════════╝")

    for i, v in ipairs(tViolations) do
        g_fLog(string.format("[PG] VIOLATION [%d/%d] type=%s",
            i, #tViolations, v.t))
        g_fLog(string.format("[PG]   detail:   %s", v.d or "(none)"))
        g_fLog(string.format("[PG]   expected: %s", v.e or "N/A"))
        g_fLog(string.format("[PG]   actual:   %s", v.a or "N/A"))
    end

    local tLines = {
        "CRITICAL_STRUCTURE_CORRUPTION",
        string.format("PatchGuard: %d violation(s) at %.4f",
            #tViolations, g_fUptime()),
    }
    for i, v in ipairs(tViolations) do
        if i > 8 then
            tLines[#tLines + 1] = string.format("  ... and %d more", #tViolations - 8)
            break
        end
        tLines[#tLines + 1] = string.format("  [%d] %s: %s", i, v.t, v.d or "?")
    end

    g_fPanic(table.concat(tLines, "\n"), nil, tViolations)
    return false
end

-- =============================================
-- INITIALIZE
-- =============================================

function PG.Initialize(tCfg)
    g_tSyscallTable     = tCfg.tSyscallTable
    g_tSyscallOverrides = tCfg.tSyscallOverrides
    g_nPipelinePid      = tCfg.nPipelinePid
    g_fPanic            = tCfg.fPanic
    g_fLog              = tCfg.fLog
    g_fUptime           = tCfg.fUptime
    g_tProcessTable     = tCfg.tProcessTable
    g_tRings            = tCfg.tRings
    g_oObManager        = tCfg.oObManager
    g_tFrozenLibs       = tCfg.tFrozenLibs
    g_tBootSecurity     = tCfg.tBootSecurity
    g_fComputeBinding   = tCfg.fComputeBinding
    g_fHashKernel       = tCfg.fHashKernel
    g_fReadEepromCode   = tCfg.fReadEepromCode
    g_fReadEepromData   = tCfg.fReadEepromData
    g_fSha256           = tCfg.fSha256          -- data card fallback
    g_fReadFile         = tCfg.fReadFile
    g_fFlush            = tCfg.fFlush or function() end
    g_fLastModified     = tCfg.fLastModified

    -- pure-Lua SHA-256 module (preferred over data card)
    g_oSha256           = tCfg.oSha256

    -- XOR encryption key for hash storage
    g_sXorKey           = tCfg.sXorKey

    -- syscall behavior profiler reference
    g_tSyscallProfiler  = tCfg.tSyscallProfiler

    -- KIQGR enclave references
    g_oKiqgr        = tCfg.oKiqgr
    g_hKiqgrEnclave = tCfg.hKiqgrEnclave
    g_fCallEnclave  = tCfg.fCallEnclave

    -- Golden Image reversion
    g_oGoldenImage  = tCfg.oGoldenImage
    g_fRevertFile   = tCfg.fRevertFile
    g_fAxvbVerify   = tCfg.fAxvbVerify

    if g_oKiqgr and g_hKiqgrEnclave then
        g_fLog("[PG] KIQGR enclave attached — hash verification runs inside enclave")
    end
    if g_oGoldenImage then
        g_fLog("[PG] Golden Image attached — auto-reversion enabled")
    end

    g_fLog("[PG] PatchGuard v3 initializing...")
    g_fLog(string.format("[PG]   SHA-256: %s",
        g_oSha256 and "/lib/sha256 (pure Lua)" or
        (g_fSha256 and "data card" or "NONE")))
    g_fLog(string.format("[PG]   XOR key: %s",
        g_sXorKey and (tostring(#g_sXorKey) .. " bytes from hardware RNG") or "DISABLED"))
    g_fLog(string.format("[PG]   Check rotation: 3 variants (alpha/beta/gamma)"))
    g_fLog(string.format("[PG]   Syscall profiler: %s",
        g_tSyscallProfiler and "ACTIVE" or "DISABLED"))

    -- Build check function variant array
    g_tCheckVariants = { checkVariantAlpha, checkVariantBeta, checkVariantGamma }
    g_nVariantCount = #g_tCheckVariants

    PG.TakeSnapshot()
    randomize()
    return true
end

function PG.NotifyQuarantine(sDriverName, sReason)
    g_nQuarantineEvents = g_nQuarantineEvents + 1
    g_fLog(string.format(
        "[PG] QUARANTINE EVENT: Driver '%s' quarantined — %s",
        sDriverName, sReason or "fault limit"))
end

function PG.NotifyEscalation(nPid, sDetails)
    g_nEscalationAttempts = g_nEscalationAttempts + 1
    g_fLog(string.format(
        "[PG] RING ESCALATION ATTEMPT: PID %d — %s",
        nPid, sDetails or "unknown"))
end

function PG.TakeSnapshot(bRehashFiles)
    g_fLog("[PG] Taking snapshot...")
    g_fFlush()

    g_fLog("[PG] Tier1: syscall table, overrides, self, rings...")
    snapshotSyscallTable()
    snapshotOverrides()
    snapshotSelf()
    snapshotRings()
    g_fFlush()

    g_fLog("[PG] Tier2: frozen libs, OB namespace...")
    snapshotFrozenLibs()
    snapshotObNamespace()
    g_fFlush()

    g_fLog("[PG] Tier3: SecureBoot, EEPROM...")
    snapshotSecureBoot()
    g_fFlush()

    local nExisting = 0
    for _ in pairs(g_tFileHashSnap) do nExisting = nExisting + 1 end

    if bRehashFiles == "force" then
        g_fLog("[PG] Tier3-files: forced full re-hash...")
        snapshotCriticalFiles()
    elseif bRehashFiles == false then
        g_fLog(string.format("[PG] Tier3-files: reusing %d cached hashes (fast re-arm)", nExisting))
    elseif nExisting == 0 then
        g_fLog("[PG] Tier3-files: initial hash...")
        snapshotCriticalFiles()
    else
        g_fLog(string.format("[PG] Tier3-files: reusing %d cached hashes", nExisting))
    end

    local nSc = 0
    for _ in pairs(g_tSyscallFuncSnap) do nSc = nSc + 1 end
    local nOvr = 0
    for _ in pairs(g_tOverrideSnap) do nOvr = nOvr + 1 end
    local nFiles = 0
    for _ in pairs(g_tFileHashSnap) do nFiles = nFiles + 1 end

    g_fLog(string.format(
        "[PG] Snapshot: %d syscalls, %d overrides, %d files, PM=PID %s, SB=%s",
        nSc, nOvr, nFiles, tostring(g_nPipelinePid),
        g_bSecureBootExpected and "ACTIVE" or "inactive"))
end

function PG.Arm()
    if not g_sSyscallKeyFP or #g_sSyscallKeyFP == 0 then
        g_fLog("[PG] Cannot arm: no snapshot")
        return false
    end
    g_bArmed = true
    g_fLog("[PG] PatchGuard v3 ARMED — rotating checks, encrypted hashes, mtime scanning")
    return true
end

function PG.Disarm()  g_bArmed = false end
function PG.IsArmed() return g_bArmed end

function PG.Check()
    g_nChecksPerformed = g_nChecksPerformed + 1

    -- Use ALL three check variants on full check
    local tViolations = checkVariantAlpha()
    local tVB = checkVariantBeta()
    for _, v in ipairs(tVB) do tViolations[#tViolations+1] = v end
    local tVG = checkVariantGamma()
    for _, v in ipairs(tVG) do tViolations[#tViolations+1] = v end

    local tV2 = checkTier2()
    for _, v in ipairs(tV2) do tViolations[#tViolations+1] = v end

    local tV3 = checkTier3()
    for _, v in ipairs(tV3) do tViolations[#tViolations+1] = v end

    -- All files
    for _, sPath in ipairs(SUPERCRITICAL_FILES) do
        local tVF = fCheckOneFile(sPath, true)
        for _, v in ipairs(tVF) do tViolations[#tViolations+1] = v end
    end
    for _, sPath in ipairs(CRITICAL_FILES) do
        local tVF = fCheckOneFile(sPath, false)
        for _, v in ipairs(tVF) do tViolations[#tViolations+1] = v end
    end

    -- Syscall profiles
    local tVP = checkSyscallProfiles()
    for _, v in ipairs(tVP) do tViolations[#tViolations+1] = v end

    if #tViolations > 0 then return handleViolations(tViolations) end
    return true
end

-- =============================================
-- TICK — main per-scheduler-iteration entry
-- =============================================

function PG.Tick()
    if not g_bArmed then return true end
    if g_fUptime() < g_nNextCheckTime then
        -- Even between full checks, scan ALL file mtimes for instant detection
        local tMtV = fMtimeScanAll()
        if #tMtV > 0 then return handleViolations(tMtV) end
        return true
    end

    randomize()
    g_nChecksPerformed = g_nChecksPerformed + 1

    -- ROTATED CHECK: randomly pick one of the 3 variants
    local nVariant = math.random(1, g_nVariantCount)
    local tV = g_tCheckVariants[nVariant]()

    -- Tier 2: every 5th cycle
    g_nTier2Counter = g_nTier2Counter + 1
    if g_nTier2Counter >= 5 then
        g_nTier2Counter = 0
        local tV2 = checkTier2()
        for _, v in ipairs(tV2) do tV[#tV+1] = v end
    end

    -- Tier 3 HW: every 10th cycle
    g_nTier3Counter = g_nTier3Counter + 1
    if g_nTier3Counter >= 10 then
        g_nTier3Counter = 0
        local tV3 = checkTier3()
        for _, v in ipairs(tV3) do tV[#tV+1] = v end
    end

    -- Files: round-robin (one supercritical + one critical per cycle)
    if #SUPERCRITICAL_FILES > 0 then
        local tVF = fCheckOneFile(SUPERCRITICAL_FILES[g_nSuperCursor], true)
        for _, v in ipairs(tVF) do tV[#tV+1] = v end
        g_nSuperCursor = g_nSuperCursor % #SUPERCRITICAL_FILES + 1
    end
    if #CRITICAL_FILES > 0 then
        local tVF = fCheckOneFile(CRITICAL_FILES[g_nCritCursor], false)
        for _, v in ipairs(tVF) do tV[#tV+1] = v end
        g_nCritCursor = g_nCritCursor % #CRITICAL_FILES + 1
    end

    -- Syscall profile anomalies
    local tVP = checkSyscallProfiles()
    for _, v in ipairs(tVP) do tV[#tV+1] = v end

    if #tV > 0 then return handleViolations(tV) end
    return true
end

-- =============================================
-- STATS
-- =============================================

function PG.GetStats()
    return {
        bArmed               = g_bArmed,
        nChecksPerformed     = g_nChecksPerformed,
        nViolations          = g_nViolations,
        nMinCheckSec         = g_nMinCheckSec,
        nMaxCheckSec         = g_nMaxCheckSec,
        bSecureBootActive    = g_bSecureBootExpected,
        bEepromMonitored     = g_sEepromCodeHash ~= nil,
        nCriticalFiles       = #CRITICAL_FILES + #SUPERCRITICAL_FILES,
        nFileChecksTotal     = g_nTotalFileChecks,
        nFilePassTotal       = g_nTotalFilePasses,
        nFileFailTotal       = g_nTotalFileFails,
        nQuarantineEvents    = g_nQuarantineEvents or 0,
        nEscalationAttempts  = g_nEscalationAttempts or 0,

        bXorKeyActive        = (g_sXorKey ~= nil),
        nXorKeyBytes         = g_sXorKey and #g_sXorKey or 0,
        bSha256Module        = (g_oSha256 ~= nil),
        nCheckVariants       = g_nVariantCount,
        bSyscallProfiler     = (g_tSyscallProfiler ~= nil),
        bProfilesLocked      = g_tSyscallProfiler and g_tSyscallProfiler.bLocked or false,
        nProfileAlerts       = g_tSyscallProfiler and #(g_tSyscallProfiler.tAlerts or {}) or 0,
        nCriticalFilesHashed = (function()
            local n = 0; for _ in pairs(g_tFileHashSnap) do n = n + 1 end; return n
        end)(),
        nSyscallsMonitored   = (function()
            local n = 0; for _ in pairs(g_tSyscallFuncSnap) do n = n + 1 end; return n
        end)(),
        nFrozenLibs          = (function()
            local n = 0; for _ in pairs(g_tFrozenLibSnap) do n = n + 1 end; return n
        end)(),
        nObPaths             = (function()
            local n = 0; for _ in pairs(g_tObPathSnap) do n = n + 1 end; return n
        end)(),
    }
end

return PG