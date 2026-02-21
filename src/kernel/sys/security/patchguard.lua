--
-- /sys/security/patchguard.lua
-- AxisOS Kernel Integrity Monitor (PatchGuard)
--
-- Periodically verifies that critical kernel structures have not been
-- tampered with.  On violation: CRITICAL_STRUCTURE_CORRUPTION panic.
--
-- Monitored structures:
--   - Syscall table (function identities + ring permissions)
--   - Syscall override table (PM registrations)
--   - Pipeline Manager PID
--
-- Check interval is RANDOMISED to frustrate timing attacks.
-- Self-contained — no external require() calls (loaded by kernel at boot).
--

local PG = {}

local g_bArmed           = false
local g_tSyscallTable    = nil
local g_tSyscallOverrides= nil
local g_nPipelinePid     = nil
local g_fPanic           = nil
local g_fLog             = nil
local g_fUptime          = nil

local g_nTickCounter     = 0
local g_nCheckInterval   = 50
local g_nChecksPerformed = 0
local g_nViolations      = 0

-- Snapshot data
local g_tSyscallIdSnap   = {}   -- sName → tostring(handler.func)
local g_tSyscallRingSnap = {}   -- sName → "0,1,2"
local g_sSyscallKeyFP    = ""   -- sorted key fingerprint
local g_tOverrideSnap    = {}   -- sName → nPid
local g_nSnapshotPMPid   = nil

local function randomize()
    g_nCheckInterval = 30 + math.random(0, 70)
end

function PG.Initialize(tCfg)
    g_tSyscallTable     = tCfg.tSyscallTable
    g_tSyscallOverrides = tCfg.tSyscallOverrides
    g_nPipelinePid      = tCfg.nPipelinePid
    g_fPanic            = tCfg.fPanic
    g_fLog              = tCfg.fLog
    g_fUptime           = tCfg.fUptime

    g_fLog("[PG] PatchGuard initializing...")
    PG.TakeSnapshot()
    randomize()
    return true
end

function PG.TakeSnapshot()
    g_tSyscallIdSnap   = {}
    g_tSyscallRingSnap = {}
    g_tOverrideSnap    = {}

    local tKeys = {}
    for sName, tH in pairs(g_tSyscallTable) do
        g_tSyscallIdSnap[sName] = tostring(tH.func)
        local tR = {}
        for _, r in ipairs(tH.allowed_rings) do tR[#tR+1] = tostring(r) end
        g_tSyscallRingSnap[sName] = table.concat(tR, ",")
        tKeys[#tKeys+1] = sName
    end
    table.sort(tKeys)
    g_sSyscallKeyFP = table.concat(tKeys, "|")

    for sName, nPid in pairs(g_tSyscallOverrides) do
        g_tOverrideSnap[sName] = nPid
    end
    g_nSnapshotPMPid = g_nPipelinePid

    local nOvr = 0
    for _ in pairs(g_tOverrideSnap) do nOvr = nOvr + 1 end
    g_fLog(string.format("[PG] Snapshot: %d syscalls, %d overrides, PM=PID %s",
        #tKeys, nOvr, tostring(g_nPipelinePid)))
end

function PG.Arm()
    if not g_sSyscallKeyFP or #g_sSyscallKeyFP == 0 then
        g_fLog("[PG] Cannot arm: no snapshot"); return false
    end
    g_bArmed = true
    g_fLog("[PG] PatchGuard ARMED — integrity monitoring active")
    return true
end

function PG.Disarm()  g_bArmed = false end
function PG.IsArmed() return g_bArmed end

-- Called once per scheduler iteration
function PG.Tick()
    if not g_bArmed then return true end
    g_nTickCounter = g_nTickCounter + 1
    if g_nTickCounter < g_nCheckInterval then return true end
    g_nTickCounter = 0
    randomize()
    return PG.Check()
end

function PG.Check()
    g_nChecksPerformed = g_nChecksPerformed + 1
    local tViol = {}

    -- 1. Syscall function identity
    for sName, sExpId in pairs(g_tSyscallIdSnap) do
        local tH = g_tSyscallTable[sName]
        if not tH then
            tViol[#tViol+1] = {t="SYSCALL_REMOVED", d=sName}
        elseif tostring(tH.func) ~= sExpId then
            tViol[#tViol+1] = {t="SYSCALL_FUNC_REPLACED", d=sName,
                e=sExpId:sub(1,20), a=tostring(tH.func):sub(1,20)}
        end
    end

    -- 2. Key set structure
    local tCK = {}
    for sN in pairs(g_tSyscallTable) do tCK[#tCK+1] = sN end
    table.sort(tCK)
    if table.concat(tCK, "|") ~= g_sSyscallKeyFP then
        tViol[#tViol+1] = {t="SYSCALL_TABLE_STRUCTURE", d="Key set changed"}
    end

    -- 3. Ring permission escalation
    for sName, sExpR in pairs(g_tSyscallRingSnap) do
        local tH = g_tSyscallTable[sName]
        if tH then
            local tR = {}
            for _, r in ipairs(tH.allowed_rings) do tR[#tR+1] = tostring(r) end
            if table.concat(tR, ",") ~= sExpR then
                tViol[#tViol+1] = {t="RING_ESCALATION", d=sName,
                    e=sExpR, a=table.concat(tR, ",")}
            end
        end
    end

    -- 4. Override hijack
    for sName, nExpPid in pairs(g_tOverrideSnap) do
        if g_tSyscallOverrides[sName] ~= nExpPid then
            tViol[#tViol+1] = {t="OVERRIDE_HIJACK", d=sName,
                e=tostring(nExpPid), a=tostring(g_tSyscallOverrides[sName])}
        end
    end
    for sName in pairs(g_tSyscallOverrides) do
        if not g_tOverrideSnap[sName] then
            tViol[#tViol+1] = {t="OVERRIDE_INJECTED", d=sName}
        end
    end

    -- 5. Pipeline Manager PID
    if g_nSnapshotPMPid and g_nPipelinePid ~= g_nSnapshotPMPid then
        tViol[#tViol+1] = {t="PM_PID_CHANGED",
            e=tostring(g_nSnapshotPMPid), a=tostring(g_nPipelinePid)}
    end

    if #tViol > 0 then
        g_nViolations = g_nViolations + #tViol
        for _, v in ipairs(tViol) do
            g_fLog(string.format("[PG] !! %s — %s (exp=%s got=%s)",
                v.t, v.d or "?", v.e or "N/A", v.a or "N/A"))
        end
        g_fPanic(string.format(
            "CRITICAL_STRUCTURE_CORRUPTION\n" ..
            "PatchGuard: %d violation(s). First: %s — %s",
            #tViol, tViol[1].t, tViol[1].d or ""))
        return false
    end
    return true
end

function PG.GetStats()
    return {
        bArmed            = g_bArmed,
        nChecksPerformed  = g_nChecksPerformed,
        nViolations       = g_nViolations,
        nCheckInterval    = g_nCheckInterval,
        nSyscallsMonitored = (function()
            local n=0; for _ in pairs(g_tSyscallIdSnap) do n=n+1 end; return n
        end)(),
    }
end

return PG