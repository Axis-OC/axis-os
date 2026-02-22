--
-- /sys/security/patchguard.lua
-- AxisOS Kernel Integrity Monitor (PatchGuard) v2
--
-- NT-style tiered integrity verification:
--   Tier 1: Syscall table, overrides, PM PID, self-integrity, rings
--   Tier 2: Frozen libs, OB namespace, sandbox __metatable
--   Tier 3: SecureBoot attestation, EEPROM code, kernel disk hash
--
-- Check interval is RANDOMISED per cycle (30-100 ticks).
-- Self-contained — loaded by kernel at boot with minimal env.
--

local PG = {}

-- =============================================
-- STATE
-- =============================================

local g_bArmed             = false
local g_fPanic             = nil
local g_fLog               = nil
local g_fUptime            = nil
local g_bVerbose           = false  -- log every check cycle detail
local g_nLastCheckMs       = 0
local g_fFlush = nil

local g_tCriticalFileSnap   = {}  -- sPath → hex hash

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

local g_tFileHashSnap     = {}   -- sPath → sHexHash
local g_tFileSizeSnap     = {}   -- sPath → nBytes
local g_nFileCheckCursor  = 1    -- round-robin index into CRITICAL_FILES
local g_nFilesPerCheck    = 2    -- how many files to check per Tier 3 cycle (randomized 1-3)
local g_nTotalFileChecks  = 0    -- total individual file verifications performed
local g_nTotalFilePasses  = 0    -- total verifications that matched
local g_nTotalFileFails   = 0    -- total mismatches
local g_tFileLastChecked  = {}   -- sPath → uptime of last check (for audit)
local g_fLastModified     = nil  -- function(sPath) → mtime or nil
local g_tFileMtimeCache   = {}   -- sPath → last verified mtime


-- Mtime cache: skip SHA-256 when file hasn't been written to
local g_fLastModified   = nil   -- function(sPath) → mtime or nil
local g_tMtimeCache     = {}    -- sPath → verified mtime

-- Monitored references (set by Initialize)
local g_tSyscallTable      = nil
local g_tSyscallOverrides  = nil
local g_nPipelinePid       = nil
local g_tProcessTable      = nil
local g_tRings             = nil
local g_oObManager         = nil
local g_tFrozenLibs        = nil

-- SecureBoot / hardware verification functions
local g_tBootSecurity      = nil   -- boot_security table (nil if SB disabled)
local g_fComputeBinding    = nil   -- re-compute machine binding
local g_fHashKernel        = nil   -- re-hash kernel from disk
local g_fReadEepromCode    = nil   -- read EEPROM boot code
local g_fReadEepromData    = nil   -- read EEPROM data area
local g_fSha256            = nil   -- SHA-256 hash function
local g_fHex               = nil   -- binary → hex string
local g_fReadFile          = nil   -- read file from disk

-- Counters
local g_nTickCounter       = 0
local g_nCheckInterval     = 50
local g_nChecksPerformed   = 0
local g_nTier2Counter      = 0
local g_nTier3Counter      = 0
local g_nViolations        = 0

-- =============================================
-- SNAPSHOTS
-- =============================================

-- Tier 1: Syscall table
local g_tSyscallFuncSnap   = {}   -- sName → tostring(func)
local g_tSyscallBytesSnap  = {}   -- sName → string.dump(func) or nil
local g_tSyscallRingSnap   = {}   -- sName → "0,1,2"
local g_sSyscallKeyFP      = ""   -- sorted key fingerprint
local g_tOverrideSnap      = {}   -- sName → nPid
local g_nSnapshotPMPid     = nil

-- Tier 1: Self-integrity (PG's own functions)
local g_tSelfFuncSnap      = {}   -- funcName → tostring(func)

-- Tier 1: Process rings
local g_tRingSnap          = {}   -- nPid → ring (only system PIDs < 20)

-- Tier 2: Frozen library fingerprints
local g_tFrozenLibSnap     = {}   -- "string" → key count + sample keys

-- Tier 2: OB namespace critical paths
local g_tObPathSnap        = {}   -- sPath → sType

-- Tier 3: SecureBoot attestation
local g_sBootBindingSnap   = nil  -- machine binding at boot
local g_sBootKernelHash    = nil  -- kernel hash at boot
local g_sEepromCodeHash    = nil  -- EEPROM code hash at boot
local g_sEepromDataSnap    = nil  -- EEPROM data area hash at boot
local g_bSecureBootExpected = false

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
    g_nCheckInterval = 30 + math.random(0, 70)
end

local function safeDump(f)
    if type(f) ~= "function" then return nil end
    local bOk, sBytes = pcall(string.dump, f)
    return bOk and sBytes or nil
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
    -- Snapshot our own public functions
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
    -- Only snapshot system processes (PID < 20)
    -- These should NEVER change ring
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
            -- Sample specific function identities
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

    -- Hash EEPROM code
    if g_fReadEepromCode and g_fSha256 then
        local sCode = g_fReadEepromCode()
        if sCode and #sCode > 0 then
            g_sEepromCodeHash = hex(g_fSha256(sCode))
        end
    end

    -- Hash EEPROM data area
    if g_fReadEepromData and g_fSha256 then
        local sData = g_fReadEepromData()
        if sData and #sData > 0 then
            g_sEepromDataSnap = hex(g_fSha256(sData))
        end
    end
end

local function snapshotCriticalFiles()
    g_tFileHashSnap    = {}
    g_tFileSizeSnap    = {}
    g_tFileLastChecked = {}

    if not g_fReadFile or not g_fSha256 then
        g_fLog("[PG] Tier3-files: SKIPPED (no read function or no SHA-256)")
        return
    end

    -- Merge both lists for snapshotting
    local tAllFiles = {}
    for _, s in ipairs(SUPERCRITICAL_FILES) do tAllFiles[#tAllFiles + 1] = s end
    for _, s in ipairs(CRITICAL_FILES) do tAllFiles[#tAllFiles + 1] = s end

    local nHashed     = 0
    local nMissing    = 0
    local nTotalBytes = 0

    g_fLog(string.format(
        "[PG] Tier3-files: hashing %d files (%d supercritical + %d critical)...",
        #tAllFiles, #SUPERCRITICAL_FILES, #CRITICAL_FILES))

    for i, sPath in ipairs(tAllFiles) do
        local sContent = g_fReadFile(sPath)

        if sContent and #sContent > 0 then
            local sHash = hex(g_fSha256(sContent))
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
                    sShort,
                    #sContent,
                    sHash:sub(1, 12)))
            end
        else
            nMissing = nMissing + 1
            if g_bVerbose then
                local sShort = sPath:match("([^/]+)$") or sPath
                g_fLog(string.format(
                    "[PG]   [%2d/%2d]    %-28s  MISSING",
                    i, #tAllFiles, sShort))
            end
        end

        -- Yield every 3 files so screen renders
        if i % 3 == 0 then
            g_fFlush()
        end
    end

    g_fLog(string.format(
        "[PG] Tier3-files: %d/%d hashed (%d bytes, %d missing)",
        nHashed, #tAllFiles, nTotalBytes, nMissing))
end

local g_nSuperCursor = 1  -- which supercritical file to check THIS cycle
local g_nCritCursor  = 1  -- Добавляем курсор для обычных критичных файлов

local function fCheckOneFile(sPath, bSupercritical)
    if not g_fReadFile or not g_fSha256 then return {} end
    local tV = {}

    local sExpHash = g_tFileHashSnap[sPath]
    if not sExpHash then return tV end

    g_nTotalFileChecks = g_nTotalFileChecks + 1

    -- MTIME FAST PATH
    if g_fLastModified then
        local nMtime = g_fLastModified(sPath)
        if not nMtime then
            tV[#tV + 1] = {
                t = bSupercritical and "KERNEL_INTEGRITY_UNRECOVERABLE_FAIL" or "KERNEL_MODULES_INTEGRITY_FAIL",
                d = sPath, e = sExpHash:sub(1, 24), a = "(file missing)"
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
            g_tMtimeCache[sPath] = nil
            return tV
        end

        if g_tMtimeCache[sPath] == nMtime then
            g_nTotalFilePasses = g_nTotalFilePasses + 1
            g_tFileLastChecked[sPath] = g_fUptime()
            return tV  -- file untouched
        end
    end

    -- SLOW PATH
    local sContent = g_fReadFile(sPath)

    if not sContent then
        tV[#tV + 1] = {
            t = bSupercritical and "KERNEL_INTEGRITY_UNRECOVERABLE_FAIL" or "KERNEL_MODULES_INTEGRITY_FAIL",
            d = sPath, e = sExpHash:sub(1, 24), a = "(file missing)"
        }
        g_nTotalFileFails = g_nTotalFileFails + 1
        return tV
    end

    g_fFlush()

    local sCurHash = hex(g_fSha256(sContent))

    if sCurHash ~= sExpHash then
        tV[#tV + 1] = {
            t = bSupercritical and "KERNEL_INTEGRITY_HASH_FAIL" or "KERNEL_MODULES_INTEGRITY_HASH_FAIL",
            d = sPath, e = sExpHash:sub(1, 24), a = sCurHash:sub(1, 24)
        }
        g_nTotalFileFails = g_nTotalFileFails + 1
    else
        g_nTotalFilePasses = g_nTotalFilePasses + 1
        g_tFileLastChecked[sPath] = g_fUptime()
        if g_fLastModified then
            g_tMtimeCache[sPath] = g_fLastModified(sPath)
        end
    end

    return tV
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

    -- NEW: extended monitoring
    g_tProcessTable     = tCfg.tProcessTable
    g_tRings            = tCfg.tRings
    g_oObManager        = tCfg.oObManager
    g_tFrozenLibs       = tCfg.tFrozenLibs
    g_tBootSecurity     = tCfg.tBootSecurity

    -- Hardware verification functions
    g_fComputeBinding   = tCfg.fComputeBinding
    g_fHashKernel       = tCfg.fHashKernel
    g_fReadEepromCode   = tCfg.fReadEepromCode
    g_fReadEepromData   = tCfg.fReadEepromData
    g_fSha256           = tCfg.fSha256
    g_fReadFile         = tCfg.fReadFile
    g_fFlush            = tCfg.fFlush or function() end
    g_fLastModified     = tCfg.fLastModified

    g_fLog("[PG] PatchGuard v2 initializing...")
    PG.TakeSnapshot()
    randomize()
    return true
end

function PG.TakeSnapshot(bRehashFiles)
    -- bRehashFiles:
    --   nil/true  = hash files if no hashes exist yet (first boot)
    --   false     = never re-hash (reuse existing, only refresh syscall/override snapshots)
    --   "force"   = always re-hash everything

    g_fLog("[PG] Taking snapshot...")
    g_fFlush()

    -- Tier 1 (instant)
    g_fLog("[PG] Tier1: syscall table, overrides, self, rings...")
    snapshotSyscallTable()
    snapshotOverrides()
    snapshotSelf()
    snapshotRings()
    g_fFlush()

    -- Tier 2 (instant)
    g_fLog("[PG] Tier2: frozen libs, OB namespace...")
    snapshotFrozenLibs()
    snapshotObNamespace()
    g_fFlush()

    -- Tier 3: hardware attestation (fast)
    g_fLog("[PG] Tier3: SecureBoot, EEPROM...")
    snapshotSecureBoot()
    g_fFlush()

    -- Tier 3: file hashes (SLOW — only when necessary)
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

    -- Summary
    local nSc = 0
    for _ in pairs(g_tSyscallFuncSnap) do nSc = nSc + 1 end
    local nOvr = 0
    for _ in pairs(g_tOverrideSnap) do nOvr = nOvr + 1 end
    local nLibs = 0
    for _ in pairs(g_tFrozenLibSnap) do nLibs = nLibs + 1 end
    local nFiles = 0
    for _ in pairs(g_tFileHashSnap) do nFiles = nFiles + 1 end

    g_fLog(string.format(
        "[PG] Snapshot: %d syscalls, %d overrides, %d libs, %d files, PM=PID %s, SB=%s",
        nSc, nOvr, nLibs, nFiles,
        tostring(g_nPipelinePid),
        g_bSecureBootExpected and "ACTIVE" or "inactive"))
end

function PG.Arm()
    if not g_sSyscallKeyFP or #g_sSyscallKeyFP == 0 then
        g_fLog("[PG] Cannot arm: no snapshot")
        return false
    end
    g_bArmed = true
    g_fLog("[PG] PatchGuard v2 ARMED — full integrity monitoring active")
    return true
end

function PG.Disarm()  g_bArmed = false end
function PG.IsArmed() return g_bArmed end

-- =============================================
-- CHECK: TIER 1 (every cycle)
-- =============================================

local function checkTier1()
    local nStart = g_fUptime()
    local tV = {}

    -- 1a. Syscall function identity
    local nFuncOk = 0
    local nFuncTotal = 0
    for sName, sExpId in pairs(g_tSyscallFuncSnap) do
        nFuncTotal = nFuncTotal + 1
        local tH = g_tSyscallTable[sName]
        if not tH then
            tV[#tV+1] = {t="SYSCALL_REMOVED", d=sName}
        elseif tostring(tH.func) ~= sExpId then
            tV[#tV+1] = {t="SYSCALL_FUNC_REPLACED", d=sName,
                e=sExpId:sub(1,20), a=tostring(tH.func):sub(1,20)}
        else
            nFuncOk = nFuncOk + 1
        end
    end
    -- ONE line, AFTER the loop
    if g_bVerbose then
        g_fLog(string.format("[PG]   1a func_identity: %d/%d OK",
            nFuncOk, nFuncTotal))
    end

    -- 1b. Syscall bytecode
    local nByteOk = 0
    local nByteChecked = 0
    for sName, sExpBytes in pairs(g_tSyscallBytesSnap) do
        if sExpBytes then
            nByteChecked = nByteChecked + 1
            local tH = g_tSyscallTable[sName]
            if tH then
                local sCurBytes = safeDump(tH.func)
                if sCurBytes and sCurBytes ~= sExpBytes then
                    tV[#tV+1] = {t="SYSCALL_BYTECODE_MODIFIED", d=sName}
                else
                    nByteOk = nByteOk + 1
                end
            end
        end
    end
    if g_bVerbose then
        g_fLog(string.format("[PG]   1b bytecode: %d/%d OK",
            nByteOk, nByteChecked))
    end

    g_fFlush()  -- yield so other processes can run

    -- 1c. Key set structure
    local tCK = {}
    for sN in pairs(g_tSyscallTable) do tCK[#tCK+1] = sN end
    table.sort(tCK)
    local sCurFP = table.concat(tCK, "|")
    if sCurFP ~= g_sSyscallKeyFP then
        local tES = {}
        for sN in pairs(g_tSyscallFuncSnap) do tES[sN] = true end
        local tCS = {}
        for _, sN in ipairs(tCK) do tCS[sN] = true end
        for _, sN in ipairs(tCK) do
            if not tES[sN] then
                tV[#tV+1] = {t="SYSCALL_INJECTED", d=sN}
            end
        end
        for sN in pairs(tES) do
            if not tCS[sN] then
                tV[#tV+1] = {t="SYSCALL_REMOVED", d=sN}
            end
        end
    end
    if g_bVerbose then
        g_fLog(string.format("[PG]   1c key_structure: %d keys, %s",
            #tCK, sCurFP == g_sSyscallKeyFP and "OK" or "CHANGED"))
    end

    -- 1d. Ring permissions
    local nRingOk = 0
    local nRingTotal = 0
    for sName, sExpR in pairs(g_tSyscallRingSnap) do
        nRingTotal = nRingTotal + 1
        local tH = g_tSyscallTable[sName]
        if tH then
            local tR = {}
            for _, r in ipairs(tH.allowed_rings) do tR[#tR+1] = tostring(r) end
            table.sort(tR)
            if table.concat(tR, ",") ~= sExpR then
                tV[#tV+1] = {t="RING_ESCALATION", d=sName,
                    e=sExpR, a=table.concat(tR, ",")}
            else
                nRingOk = nRingOk + 1
            end
        end
    end
    if g_bVerbose then
        g_fLog(string.format("[PG]   1d ring_perms: %d/%d OK",
            nRingOk, nRingTotal))
    end

    g_fFlush()  -- yield again

    -- 1e. Override integrity
    local nOvrOk = 0
    local nOvrTotal = 0
    for sName, nExpPid in pairs(g_tOverrideSnap) do
        nOvrTotal = nOvrTotal + 1
        if g_tSyscallOverrides[sName] ~= nExpPid then
            tV[#tV+1] = {t="OVERRIDE_HIJACK", d=sName,
                e=tostring(nExpPid),
                a=tostring(g_tSyscallOverrides[sName])}
        else
            nOvrOk = nOvrOk + 1
        end
    end
    for sName in pairs(g_tSyscallOverrides) do
        if not g_tOverrideSnap[sName] then
            tV[#tV+1] = {t="OVERRIDE_INJECTED", d=sName}
        end
    end
    if g_bVerbose then
        g_fLog(string.format("[PG]   1e overrides: %d/%d OK",
            nOvrOk, nOvrTotal))
    end

    -- 1f. Pipeline Manager PID
    local bPmOk = true
    if g_nSnapshotPMPid and g_nPipelinePid ~= g_nSnapshotPMPid then
        tV[#tV+1] = {t="PM_PID_CHANGED",
            e=tostring(g_nSnapshotPMPid),
            a=tostring(g_nPipelinePid)}
        bPmOk = false
    end
    if g_bVerbose then
        g_fLog(string.format("[PG]   1f pm_pid: %s (PID %s)",
            bPmOk and "OK" or "CHANGED",
            tostring(g_nPipelinePid)))
    end

    -- 1g. Self-integrity
    local nSelfOk = 0
    local nSelfTotal = 0
    for sName, sExpId in pairs(g_tSelfFuncSnap) do
        nSelfTotal = nSelfTotal + 1
        if PG[sName] and tostring(PG[sName]) == sExpId then
            nSelfOk = nSelfOk + 1
        elseif not PG[sName] then
            tV[#tV+1] = {t="PG_FUNC_REMOVED", d=sName}
        else
            tV[#tV+1] = {t="PG_SELF_TAMPERED", d=sName}
        end
    end
    if g_bVerbose then
        g_fLog(string.format("[PG]   1g self_integrity: %d/%d OK",
            nSelfOk, nSelfTotal))
    end

    -- 1h. System process ring escalation
    local nRingProcOk = 0
    local nRingProcTotal = 0
    for nPid, nExpRing in pairs(g_tRingSnap) do
        nRingProcTotal = nRingProcTotal + 1
        local nCurRing = g_tRings[nPid]
        if nCurRing and nCurRing < nExpRing then
            tV[#tV+1] = {t="PROCESS_RING_ESCALATED",
                d="PID " .. nPid,
                e=tostring(nExpRing), a=tostring(nCurRing)}
        else
            nRingProcOk = nRingProcOk + 1
        end
    end
    if g_bVerbose then
        g_fLog(string.format("[PG]   1h proc_rings: %d/%d OK",
            nRingProcOk, nRingProcTotal))
    end

    -- Summary
    local nMs = math.floor((g_fUptime() - nStart) * 1000)
    if g_bVerbose then
        g_fLog(string.format("[PG] Tier1: %d violations, %dms", #tV, nMs))
    end

    return tV
end

-- =============================================
-- CHECK: TIER 2 (every 5th cycle)
-- =============================================

local function checkTier2()
    local nStart = g_fUptime()
    local tV = {}

    if g_bVerbose then
        g_fLog("[PG] Tier2: checking frozen libs, OB namespace, sandbox metatables")
    end

    -- 2a. Frozen libs
    local nLibsOk = 0
    if g_tFrozenLibs then
        for sLibName, tSnap in pairs(g_tFrozenLibSnap) do
            local tLib = g_tFrozenLibs[sLibName]
            if not tLib then
                tV[#tV+1] = {t="FROZEN_LIB_REMOVED", d=sLibName}
            else
                local nCount = 0
                local tCurKeys = {}
                for k in pairs(tLib) do
                    nCount = nCount + 1
                    tCurKeys[#tCurKeys+1] = tostring(k)
                end
                table.sort(tCurKeys)
                local sCurFP = table.concat(tCurKeys, "|")

                if sCurFP ~= tSnap.sKeyFP then
                    tV[#tV+1] = {t="FROZEN_LIB_KEYS_CHANGED", d=sLibName,
                        e=tostring(tSnap.nCount), a=tostring(nCount)}
                else
                    -- Check function identities
                    local bFuncsOk = true
                    for k, sExpId in pairs(tSnap.tFuncIds) do
                        if type(tLib[k]) ~= "function" then
                            tV[#tV+1] = {t="FROZEN_LIB_FUNC_TYPE",
                                d=sLibName.."."..k}
                            bFuncsOk = false
                        elseif tostring(tLib[k]) ~= sExpId then
                            tV[#tV+1] = {t="FROZEN_LIB_FUNC_REPLACED",
                                d=sLibName.."."..k}
                            bFuncsOk = false
                        end
                    end
                    if bFuncsOk then nLibsOk = nLibsOk + 1 end
                end
            end
        end
    end

    if g_bVerbose then
        g_fLog(string.format("[PG]   2a frozen_libs: %d/%d intact",
            nLibsOk,
            (function() local n=0; for _ in pairs(g_tFrozenLibSnap) do n=n+1 end; return n end)()))
    end

    -- 2b. OB namespace
    local nObOk = 0
    if g_oObManager then
        for sPath, sExpType in pairs(g_tObPathSnap) do
            local pH = g_oObManager.ObLookupObject(sPath)
            if not pH then
                tV[#tV+1] = {t="OB_PATH_REMOVED", d=sPath}
            elseif pH.sType ~= sExpType then
                tV[#tV+1] = {t="OB_PATH_TYPE_CHANGED", d=sPath,
                    e=sExpType, a=pH.sType}
            else
                nObOk = nObOk + 1
            end
        end
    end

    if g_bVerbose then
        g_fLog(string.format("[PG]   2b ob_namespace: %d/%d intact",
            nObOk,
            (function() local n=0; for _ in pairs(g_tObPathSnap) do n=n+1 end; return n end)()))
    end

    -- 2c. Sandbox metatables
    local nMtOk = 0
    local nMtChecked = 0
    if g_tProcessTable then
        for nPid, tProc in pairs(g_tProcessTable) do
            if nPid < 20 and tProc.status ~= "dead" and tProc.env ~= nil then
                nMtChecked = nMtChecked + 1
                local bOk, sMt = pcall(getmetatable, tProc.env)
                if bOk and sMt == "protected" then
                    nMtOk = nMtOk + 1
                elseif bOk then
                    tV[#tV+1] = {t="SANDBOX_MT_BROKEN",
                        d="PID " .. nPid,
                        e="protected", a=tostring(sMt)}
                end
            end
        end
    end
    if g_bVerbose then
        g_fLog(string.format("[PG]   2c sandbox_mt: %d/%d OK",
            nMtOk, nMtChecked))
    end

    if g_bVerbose then
        g_fLog(string.format("[PG]   2c sandbox_mt: %d system processes OK", nMtOk))
        local nMs = math.floor((g_fUptime() - nStart) * 1000)
        g_fLog(string.format("[PG] Tier2: %d violations, %dms", #tV, nMs))
    end

    return tV
end

-- =============================================
-- CHECK: TIER 3 (every 20th cycle)
-- =============================================

local function checkTier3()
    local nStart = g_fUptime()
    local tV = {}

    if g_bVerbose then
        g_fLog("[PG] Tier3-HW: SecureBoot, binding, EEPROM")
    end

    -- 3a. SecureBoot table presence
    if g_bSecureBootExpected then
        if g_tBootSecurity then
            if g_bVerbose then g_fLog("[PG]   3a secureboot_table: PRESENT") end
        else
            tV[#tV+1] = {t="SECUREBOOT_TABLE_REMOVED",
                d="boot_security wiped from memory"}
        end
    else
        if g_bVerbose then g_fLog("[PG]   3a secureboot: not enabled (skipping)") end
    end

    -- 3b. Machine binding re-verification
    if g_sBootBindingSnap and g_fComputeBinding then
        local sCurrentBinding = g_fComputeBinding()
        if sCurrentBinding then
            if sCurrentBinding == g_sBootBindingSnap then
                if g_bVerbose then
                    g_fLog(string.format("[PG]   3b machine_binding: MATCH (%s...)",
                        g_sBootBindingSnap:sub(1,16)))
                end
            else
                tV[#tV+1] = {t="SECUREBOOT_BINDING_MISMATCH",
                    d="Hardware fingerprint changed at runtime",
                    e=g_sBootBindingSnap:sub(1,24),
                    a=sCurrentBinding:sub(1,24)}
            end
        end
    else
        if g_bVerbose then g_fLog("[PG]   3b machine_binding: skipped") end
    end

    -- 3c. Kernel disk hash
    if g_sBootKernelHash and g_fHashKernel then
        local sCurrentHash = g_fHashKernel()
        if sCurrentHash then
            if sCurrentHash == g_sBootKernelHash then
                if g_bVerbose then
                    g_fLog(string.format("[PG]   3c kernel_hash: MATCH (%s...)",
                        g_sBootKernelHash:sub(1,16)))
                end
            else
                tV[#tV+1] = {t="SECUREBOOT_KERNEL_MISMATCH",
                    d="/kernel.lua modified on disk since boot",
                    e=g_sBootKernelHash:sub(1,24),
                    a=sCurrentHash:sub(1,24)}
            end
        end
    else
        if g_bVerbose then g_fLog("[PG]   3c kernel_hash: skipped") end
    end

    -- 3d. EEPROM code integrity
    if g_sEepromCodeHash and g_fReadEepromCode and g_fSha256 then
        local sCode = g_fReadEepromCode()
        if sCode then
            local sCurHash = hex(g_fSha256(sCode))
            if sCurHash == g_sEepromCodeHash then
                if g_bVerbose then
                    g_fLog(string.format("[PG]   3d eeprom_code: INTACT (%s...)",
                        g_sEepromCodeHash:sub(1,16)))
                end
            else
                tV[#tV+1] = {t="EEPROM_CODE_TAMPERED",
                    d="Boot ROM changed at runtime",
                    e=g_sEepromCodeHash:sub(1,24),
                    a=sCurHash:sub(1,24)}
            end
        end
    else
        if g_bVerbose then g_fLog("[PG]   3d eeprom_code: skipped") end
    end

    -- 3e. EEPROM data area
    if g_sEepromDataSnap and g_fReadEepromData and g_fSha256 then
        local sData = g_fReadEepromData()
        if sData then
            local sCurHash = hex(g_fSha256(sData))
            if sCurHash == g_sEepromDataSnap then
                if g_bVerbose then
                    g_fLog(string.format("[PG]   3e eeprom_data: INTACT (%s...)",
                        g_sEepromDataSnap:sub(1,16)))
                end
            else
                tV[#tV+1] = {t="EEPROM_DATA_TAMPERED",
                    d="Attestation data changed at runtime",
                    e=g_sEepromDataSnap:sub(1,24),
                    a=sCurHash:sub(1,24)}
            end
        end
    end

    if g_bVerbose then
        local nMs = math.floor((g_fUptime() - nStart) * 1000)
        g_fLog(string.format("[PG] Tier3-HW: %d violations, %dms", #tV, nMs))
    end

    return tV
end

--[[
local function checkTier3()
    local nStart = g_fUptime()
    local tV = {}

    if g_bVerbose then
        g_fLog("[PG] Tier3: SecureBoot attestation, EEPROM integrity, kernel hash")
    end

    -- 3a. SecureBoot table presence
    if g_bSecureBootExpected then
        if g_tBootSecurity then
            if g_bVerbose then
                g_fLog("[PG]   3a secureboot_table: PRESENT (verified=%s)",
                    tostring(g_tBootSecurity.verified))
            end
        else
            tV[#tV+1] = {t="SECUREBOOT_TABLE_REMOVED",
                d="boot_security wiped from memory"}
        end
    else
        if g_bVerbose then
            g_fLog("[PG]   3a secureboot: not enabled (skipping)")
        end
    end
    g_fFlush()

    -- 3b. Machine binding re-verification
    if g_sBootBindingSnap and g_fComputeBinding then
        local sCurrentBinding = g_fComputeBinding()
        if sCurrentBinding then
            if sCurrentBinding == g_sBootBindingSnap then
                if g_bVerbose then
                    g_fLog(string.format(
                        "[PG]   3b machine_binding: MATCH (%s...)",
                        g_sBootBindingSnap:sub(1,16)))
                end
            else
                tV[#tV+1] = {t="SECUREBOOT_BINDING_MISMATCH",
                    d="Hardware fingerprint changed at runtime",
                    e=g_sBootBindingSnap:sub(1,24),
                    a=sCurrentBinding:sub(1,24)}
                g_fLog(string.format(
                    "[PG]   3b machine_binding: MISMATCH!"))
                g_fLog(string.format(
                    "[PG]     expected: %s", g_sBootBindingSnap:sub(1,32)))
                g_fLog(string.format(
                    "[PG]     actual:   %s", sCurrentBinding:sub(1,32)))
            end
        end
    else
        if g_bVerbose then
            g_fLog("[PG]   3b machine_binding: skipped (no snapshot or no data card)")
        end
    end
    g_fFlush()

    -- 3c. Kernel disk hash
    if g_sBootKernelHash and g_fHashKernel then
        local sCurrentHash = g_fHashKernel()
        if sCurrentHash then
            if sCurrentHash == g_sBootKernelHash then
                if g_bVerbose then
                    g_fLog(string.format(
                        "[PG]   3c kernel_hash: MATCH (%s...)",
                        g_sBootKernelHash:sub(1,16)))
                end
            else
                tV[#tV+1] = {t="SECUREBOOT_KERNEL_MISMATCH",
                    d="/kernel.lua modified on disk since boot",
                    e=g_sBootKernelHash:sub(1,24),
                    a=sCurrentHash:sub(1,24)}
                g_fLog("[PG]   3c kernel_hash: MISMATCH!")
                g_fLog("[PG]     boot:    " .. g_sBootKernelHash:sub(1,32))
                g_fLog("[PG]     current: " .. sCurrentHash:sub(1,32))
            end
        end
    else
        if g_bVerbose then
            g_fLog("[PG]   3c kernel_hash: skipped (no SB or no data card)")
        end
    end
    g_fFlush()

    -- 3d. EEPROM code integrity
    if g_sEepromCodeHash and g_fReadEepromCode and g_fSha256 then
        local sCode = g_fReadEepromCode()
        if sCode then
            local sCurHash = hex(g_fSha256(sCode))
            if sCurHash == g_sEepromCodeHash then
                if g_bVerbose then
                    g_fLog(string.format(
                        "[PG]   3d eeprom_code: INTACT (%s..., %d bytes)",
                        g_sEepromCodeHash:sub(1,16), #sCode))
                end
            else
                tV[#tV+1] = {t="EEPROM_CODE_TAMPERED",
                    d="Boot ROM changed at runtime",
                    e=g_sEepromCodeHash:sub(1,24),
                    a=sCurHash:sub(1,24)}
                g_fLog("[PG]   3d eeprom_code: TAMPERED!")
            end
        end
    else
        if g_bVerbose then
            g_fLog("[PG]   3d eeprom_code: skipped (no snapshot)")
        end
    end
    g_fFlush()

    -- 3e. EEPROM data area
    if g_sEepromDataSnap and g_fReadEepromData and g_fSha256 then
        local sData = g_fReadEepromData()
        if sData then
            local sCurHash = hex(g_fSha256(sData))
            if sCurHash == g_sEepromDataSnap then
                if g_bVerbose then
                    g_fLog(string.format(
                        "[PG]   3e eeprom_data: INTACT (%s...)",
                        g_sEepromDataSnap:sub(1,16)))
                end
            else
                tV[#tV+1] = {t="EEPROM_DATA_TAMPERED",
                    d="Attestation data changed at runtime",
                    e=g_sEepromDataSnap:sub(1,24),
                    a=sCurHash:sub(1,24)}
                g_fLog("[PG]   3e eeprom_data: TAMPERED!")
            end
        end
    end
    g_fFlush()
    local tSuperV = checkOneSupercriticalFile()
    for _, v in ipairs(tSuperV) do tV[#tV + 1] = v end

    -- 3g. ONE critical file (rotates each cycle)
    local tFileV = checkOneCriticalFile()
    for _, v in ipairs(tFileV) do tV[#tV + 1] = v end

    if g_bVerbose then
        local nMs = math.floor((g_fUptime() - nStart) * 1000)
        g_fLog(string.format("[PG] Tier3: %d violations, %dms (pass/fail: %d/%d)",
            #tV, nMs, g_nTotalFilePasses, g_nTotalFileFails))
    end

    return tV
end

]]

-- =============================================
-- MAIN CHECK ORCHESTRATOR
-- =============================================


local function handleViolations(tViolations)
    if #tViolations == 0 then return true end

    g_nViolations = g_nViolations + #tViolations

    g_fLog("[PG] ╔══ INTEGRITY VIOLATION DETECTED ══╗")
    g_fLog(string.format("[PG] ║  %d violation(s) at T=%.4f       ║",
        #tViolations, g_fUptime()))
    g_fLog("[PG] ╚══════════════════════════════════╝")

    for i, v in ipairs(tViolations) do
        g_fLog(string.format("[PG] VIOLATION [%d/%d] type=%s", i, #tViolations, v.t))
        g_fLog(string.format("[PG]   detail:   %s", v.d or "(none)"))
        g_fLog(string.format("[PG]   expected: %s", v.e or "N/A"))
        g_fLog(string.format("[PG]   actual:   %s", v.a or "N/A"))
    end

    local tLines = {
        "CRITICAL_STRUCTURE_CORRUPTION",
        string.format("PatchGuard: %d violation(s) at %.4f", #tViolations, g_fUptime()),
    }
    for i, v in ipairs(tViolations) do
        if i > 8 then
            tLines[#tLines+1] = string.format("  ... and %d more", #tViolations - 8)
            break
        end
        tLines[#tLines+1] = string.format("  [%d] %s: %s", i, v.t, v.d or "?")
    end

    g_fPanic(table.concat(tLines, "\n"), nil, tViolations)
    return false
end

function PG.Check()
    g_nChecksPerformed = g_nChecksPerformed + 1
    local tViolations = checkTier1()

    local tV2 = checkTier2()
    for _, v in ipairs(tV2) do tViolations[#tViolations+1] = v end

    local tV3 = checkTier3()
    for _, v in ipairs(tV3) do tViolations[#tViolations+1] = v end

    for _, sPath in ipairs(SUPERCRITICAL_FILES) do
        local tVF = fCheckOneFile(sPath, true)
        for _, v in ipairs(tVF) do tViolations[#tViolations+1] = v end
    end
    for _, sPath in ipairs(CRITICAL_FILES) do
        local tVF = fCheckOneFile(sPath, false)
        for _, v in ipairs(tVF) do tViolations[#tViolations+1] = v end
    end

    if #tViolations > 0 then
        return handleViolations(tViolations)
    end
    return true
end

local g_nTicksSinceLastLog = 0

local function fMtimeScanAndHash()
    if not g_fReadFile or not g_fSha256 or not g_fLastModified then
        return {}
    end

    local tV = {}

    -- Scan ALL files' mtime every cycle
    -- Cost: ~0.05 ticks × 25 files ≈ 1.25 ticks total
    -- This catches external edits within one PG cycle

    -- Supercritical first
    for _, sPath in ipairs(SUPERCRITICAL_FILES) do
        local sExpHash = g_tFileHashSnap[sPath]
        if not sExpHash then goto nextFile end

        g_nTotalFileChecks = g_nTotalFileChecks + 1
        local nMtime = g_fLastModified(sPath)

        if not nMtime then
            -- File deleted externally
            tV[#tV+1] = {
                t = "KERNEL_INTEGRITY_UNRECOVERABLE_FAIL",
                d = sPath,
                e = sExpHash:sub(1, 24),
                a = "(file missing)"
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
            g_tMtimeCache[sPath] = nil
            goto nextFile
        end

        if g_tMtimeCache[sPath] == nMtime then
            -- Mtime unchanged — file not touched since last verified hash
            g_nTotalFilePasses = g_nTotalFilePasses + 1
            goto nextFile
        end

        -- Mtime CHANGED — someone wrote to this file externally
        -- This is the only case where we pay the read+hash cost
        g_fLog(string.format(
            "[PG] mtime changed: %s (cached=%s now=%s) — rehashing",
            sPath:match("([^/]+)$") or sPath,
            tostring(g_tMtimeCache[sPath]),
            tostring(nMtime)))

        local sContent = g_fReadFile(sPath)
        g_fFlush() -- yield between read and hash

        if not sContent then
            tV[#tV+1] = {
                t = "KERNEL_INTEGRITY_UNRECOVERABLE_FAIL",
                d = sPath,
                e = sExpHash:sub(1, 24),
                a = "(read failed after mtime change)"
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
            g_tMtimeCache[sPath] = nil
            goto nextFile
        end

        local sCurHash = hex(g_fSha256(sContent))

        if sCurHash ~= sExpHash then
            tV[#tV+1] = {
                t = "KERNEL_INTEGRITY_HASH_FAIL",
                d = sPath,
                e = sExpHash:sub(1, 24),
                a = sCurHash:sub(1, 24)
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
            -- DON'T update mtime cache — keep detecting on every cycle
        else
            -- File was rewritten with identical content (or our snapshot
            -- was stale). Either way, current state matches boot.
            g_tMtimeCache[sPath] = nMtime
            g_nTotalFilePasses = g_nTotalFilePasses + 1
        end

        ::nextFile::
    end

    -- Then critical files (same logic)
    for _, sPath in ipairs(CRITICAL_FILES) do
        local sExpHash = g_tFileHashSnap[sPath]
        if not sExpHash then goto nextCrit end

        g_nTotalFileChecks = g_nTotalFileChecks + 1
        local nMtime = g_fLastModified(sPath)

        if not nMtime then
            tV[#tV+1] = {
                t = "KERNEL_MODULES_INTEGRITY_FAIL",
                d = sPath,
                e = sExpHash:sub(1, 24),
                a = "(file missing)"
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
            g_tMtimeCache[sPath] = nil
            goto nextCrit
        end

        if g_tMtimeCache[sPath] == nMtime then
            g_nTotalFilePasses = g_nTotalFilePasses + 1
            goto nextCrit
        end

        g_fLog(string.format(
            "[PG] mtime changed: %s — rehashing",
            sPath:match("([^/]+)$") or sPath))

        local sContent = g_fReadFile(sPath)
        g_fFlush()

        if not sContent then
            tV[#tV+1] = {
                t = "KERNEL_MODULES_INTEGRITY_FAIL",
                d = sPath,
                e = sExpHash:sub(1, 24),
                a = "(read failed)"
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
            g_tMtimeCache[sPath] = nil
            goto nextCrit
        end

        local sCurHash = hex(g_fSha256(sContent))

        if sCurHash ~= sExpHash then
            tV[#tV+1] = {
                t = "KERNEL_MODULES_INTEGRITY_HASH_FAIL",
                d = sPath,
                e = sExpHash:sub(1, 24),
                a = sCurHash:sub(1, 24)
            }
            g_nTotalFileFails = g_nTotalFileFails + 1
        else
            g_tMtimeCache[sPath] = nMtime
            g_nTotalFilePasses = g_nTotalFilePasses + 1
        end

        ::nextCrit::
    end

    return tV
end

function PG.Tick()
    if not g_bArmed then return true end

    g_nTickCounter = g_nTickCounter + 1
    if g_nTickCounter < g_nCheckInterval then return true end
    g_nTickCounter = 0
    randomize()
    g_nChecksPerformed = g_nChecksPerformed + 1

    -- Tier 1+2: in-memory, always run, zero cost
    local tV = checkTier1()
    local tV2 = checkTier2()
    for _, v in ipairs(tV2) do tV[#tV+1] = v end

    -- Tier 3 HW: every 10th cycle
    g_nTier3Counter = g_nTier3Counter + 1
    if g_nTier3Counter >= 10 then
        g_nTier3Counter = 0
        local tV3 = checkTier3()
        for _, v in ipairs(tV3) do tV[#tV+1] = v end
    end

    -- Tier 3 FILES: Round-Robin
    if #SUPERCRITICAL_FILES > 0 then
        local sSuperPath = SUPERCRITICAL_FILES[g_nSuperCursor]
        local tVF1 = fCheckOneFile(sSuperPath, true)
        for _, v in ipairs(tVF1) do tV[#tV+1] = v end
        
        g_nSuperCursor = g_nSuperCursor + 1
        if g_nSuperCursor > #SUPERCRITICAL_FILES then g_nSuperCursor = 1 end
    end

    if #CRITICAL_FILES > 0 then
        local sCritPath = CRITICAL_FILES[g_nCritCursor]
        local tVF2 = fCheckOneFile(sCritPath, false)
        for _, v in ipairs(tVF2) do tV[#tV+1] = v end
        
        g_nCritCursor = g_nCritCursor + 1
        if g_nCritCursor > #CRITICAL_FILES then g_nCritCursor = 1 end
    end

    if #tV > 0 then
        return handleViolations(tV)
    end
    return true
end

-- =============================================
-- STATS
-- =============================================

function PG.GetStats()
    return {
        bArmed             = g_bArmed,
        nChecksPerformed   = g_nChecksPerformed,
        nViolations        = g_nViolations,
        nCheckInterval     = g_nCheckInterval,
        bSecureBootActive  = g_bSecureBootExpected,
        bEepromMonitored   = g_sEepromCodeHash ~= nil,
        nCriticalFiles       = #CRITICAL_FILES,
        nFileChecksTotal     = g_nTotalFileChecks,
        nFilePassTotal       = g_nTotalFilePasses,
        nFileFailTotal       = g_nTotalFileFails,
        nFileCheckCursor     = g_nSuperCursor,

        nCriticalFilesHashed = (function()
        local n = 0
        for _ in pairs(g_tFileHashSnap) do n = n + 1 end
        return n
        end)(),
        nSyscallsMonitored = (function()
            local n = 0
            for _ in pairs(g_tSyscallFuncSnap) do n = n + 1 end
            return n
        end)(),
        nFrozenLibs        = (function()
            local n = 0
            for _ in pairs(g_tFrozenLibSnap) do n = n + 1 end
            return n
        end)(),
        nObPaths           = (function()
            local n = 0
            for _ in pairs(g_tObPathSnap) do n = n + 1 end
            return n
        end)(),
    }
end

return PG