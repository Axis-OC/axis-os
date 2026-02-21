--
-- /kernel.lua
-- AxisOS Xen XKA v0.6-HV-beta
--
local kernel = {
    tProcessTable = {},
    tPidMap = {},
    tRings = {},
    nNextPid = 1,

    tSyscallTable = {},
    tSyscallOverrides = {},

    tEventQueue = {},

    tVfs = {
        tMounts = {},
        oRootFs = nil,
        sRootUuid = nil
    },

    tDriverRegistry = {},
    tComponentDriverMap = {},
    nPipelinePid= nil,
    tBootLog = {},
    tLoadedModules = {}
}

local g_nCurrentPid = 0
local g_nDebugY = 2
local g_bLogToScreen = true
local g_oGpu = nil
local g_nWidth, g_nHeight = 80, 25
local g_nCurrentLine = 0
local tBootArgs = boot_args or {}

local g_bAxfsRoot = false
local g_oAxfsVol = nil

local g_oPreempt = nil -- loaded from /lib/preempt.lua at boot
local g_oIpc = nil -- Kernel IPC subsystem

local g_oPatchGuard = nil   -- Kernel integrity monitor
local g_oHypervisor = nil   -- Metatable protection primitives

local g_tSchedStats = {
    nTotalResumes = 0,
    nPreemptions = 0,
    nWatchdogWarnings = 0,
    nWatchdogKills = 0,
    nMaxSliceMs = 0
}

local WATCHDOG_WARN_THRESHOLD = 2.0 -- seconds warn if a single resume exceeds this
local WATCHDOG_KILL_STRIKES = 3 -- kill after this many warnings

-- Object Manager (loaded at boot from /lib/ob_manager.lua)
local g_oObManager = nil
local g_oRegistry = nil
local g_nBootTickCounter = 0
local g_bPgAutoArmed = false

-- Color constants
local C_WHITE = 0xFFFFFF
local C_GRAY = 0xAAAAAA
local C_GREEN = 0x55FF55
local C_RED = 0xFF5555
local C_YELLOW = 0xFFFF55
local C_CYAN = 0x55FFFF
local C_BLUE = 0x5555FF

local tLogLevels = {
    ok = {
        text = "[  OK  ]",
        color = C_GREEN,
        pri = 3
    },
    fail = {
        text = "[ FAIL ]",
        color = C_RED,
        pri = 4
    },
    info = {
        text = "[ INFO ]",
        color = C_CYAN,
        pri = 2
    },
    warn = {
        text = "[ WARN ]",
        color = C_YELLOW,
        pri = 3
    },
    dev = {
        text = "[ DEV  ]",
        color = C_BLUE,
        pri = 1
    },
    debug = {
        text = "[DEBUG ]",
        color = C_GRAY,
        pri = 0
    },
    sec = {
        text = "[ SEC  ]",
        color = 0xFF55FF,
        pri = 3
    },
    sched = {
        text = "[SCHED ]",
        color = 0x55AAFF,
        pri = 1
    },
    ipc = {
        text = "[ IPC  ]",
        color = 0xAAAAFF,
        pri = 1
    },
    drv = {
        text = "[ DRV  ]",
        color = 0xFFAA55,
        pri = 2
    },
    vfs = {
        text = "[ VFS  ]",
        color = 0x55FFAA,
        pri = 2
    },
    mem = {
        text = "[ MEM  ]",
        color = 0xFFFF55,
        pri = 2
    },
    proc = {
        text = "[ PROC ]",
        color = 0xAAFFAA,
        pri = 2
    },
    none = {
        text = "         ",
        color = C_WHITE,
        pri = 5
    }
}

local tLogLevelsPriority = {
    debug = 0,
    dev = 1,
    sched = 1,
    ipc = 1,
    info = 2,
    drv = 2,
    vfs = 2,
    mem = 2,
    proc = 2,
    warn = 3,
    ok = 3,
    sec = 3,
    fail = 4,
    none = 5
}

local sCurrentLogLevel = string.lower(tBootArgs.loglevel or "info")
local nMinScreenPriority = tLogLevelsPriority[sCurrentLogLevel] or 2

-- =============================================
-- DMESG RING BUFFER
-- Persistent kernel message buffer. Never drained.
-- Accessed via syscall("dmesg_read").
-- tBootLog is ALSO maintained for PM drain (backwards compat).
-- =============================================

local DMESG_MAX_ENTRIES = 1024
local g_tDmesg = {}
local g_nDmesgSeq = 0

-- Structured log entry
local function fDmesgPush(sLevel, sMessage, nPid, sSource)
    g_nDmesgSeq = g_nDmesgSeq + 1
    local tEntry = {
        seq = g_nDmesgSeq,
        time = raw_computer.uptime(),
        level = sLevel,
        msg = sMessage,
        pid = nPid or g_nCurrentPid or 0,
        src = sSource
    }
    g_tDmesg[#g_tDmesg + 1] = tEntry
    if #g_tDmesg > DMESG_MAX_ENTRIES then
        table.remove(g_tDmesg, 1)
    end
    return tEntry
end

-------------------------------------------------
-- sMLTR: SYNAPSE TOKEN GENERATION
-------------------------------------------------

-- Counter for extra entropy in token generation
local g_nSynapseCounter = 0

-- Generate a cryptographically-ish unique synapse token.
-- Uses uptime, counter, and random values for entropy.
local function fGenerateSynapseToken()
    g_nSynapseCounter = g_nSynapseCounter + 1
    local nUptime = math.floor(raw_computer.uptime() * 100000)
    local t = {}
    for i = 1, 4 do
        local nEntropy = math.random(0, 0xFFFF)
        -- mix in counter and uptime bits
        nEntropy = (nEntropy + g_nSynapseCounter * 31 + nUptime) % 0xFFFF
        t[i] = string.format("%04x", nEntropy)
        -- rotate uptime bits for next iteration
        nUptime = math.floor(nUptime / 7) + math.random(0, 0xFF)
    end
    return "SYN-" .. table.concat(t, "-")
end

-------------------------------------------------
-- EARLY BOOT & DEBUG FUNCTIONS
-------------------------------------------------

local function __gpu_dprint(sText)
    local sGpuAddr, sScreenAddr
    for sAddr in raw_component.list("gpu") do
        sGpuAddr = sAddr;
        break
    end
    for sAddr in raw_component.list("screen") do
        sScreenAddr = sAddr;
        break
    end
    if sGpuAddr and sScreenAddr then
        local oGpu = raw_component.proxy(sGpuAddr)
        pcall(oGpu.bind, sScreenAddr)
        pcall(oGpu.fill, 1, g_nDebugY, 160, 1, " ")
        pcall(oGpu.set, 1, g_nDebugY, tostring(sText))
        g_nDebugY = g_nDebugY + 1
        if g_nDebugY > 40 then
            g_nDebugY = 2
        end
    end
end

local function __logger_init()
    local sGpuAddr, sScreenAddr
    for sAddr in raw_component.list("gpu") do
        sGpuAddr = sAddr;
        break
    end
    for sAddr in raw_component.list("screen") do
        sScreenAddr = sAddr;
        break
    end
    if sGpuAddr and sScreenAddr then
        g_oGpu = raw_component.proxy(sGpuAddr)
        pcall(g_oGpu.bind, sScreenAddr)
        g_nWidth, g_nHeight = g_oGpu.getResolution()
        g_oGpu.fill(1, 1, g_nWidth, g_nHeight, " ")
        g_nCurrentLine = 0
    end
end

function kprint(sLevel, ...)
    local tLevelInfo = tLogLevels[sLevel] or tLogLevels.none
    local nMsgPriority = tLevelInfo.pri or 2

    -- Build message string
    local tMsgParts = {...}
    local sMessage = ""
    for i, v in ipairs(tMsgParts) do
        if type(v) == "table" then
            -- Inline structured data: {pid=5, ring=3} → "pid=5 ring=3"
            local tKV = {}
            for k, val in pairs(v) do
                tKV[#tKV + 1] = tostring(k) .. "=" .. tostring(val)
            end
            table.sort(tKV)
            sMessage = sMessage .. table.concat(tKV, " ")
        else
            sMessage = sMessage .. tostring(v)
        end
        if i < #tMsgParts then
            sMessage = sMessage .. " "
        end
    end

    -- Timestamp
    local nTime = raw_computer.uptime()
    local sTimestamp = string.format("[%9.4f]", nTime)

    -- Full structured line for .vbl / dmesg
    local sFullLine = string.format("%s %s PID=%-3d %s", sTimestamp, tLevelInfo.text, g_nCurrentPid or 0, sMessage)

    -- Always push to dmesg ring buffer (ALL levels)
    fDmesgPush(sLevel, sMessage, g_nCurrentPid)

    -- Always push to boot log drain (PM picks these up)
    table.insert(kernel.tBootLog, sFullLine)

    -- Screen output (filtered by boot arg log level)
    if nMsgPriority < nMinScreenPriority then
        return
    end
    if not g_bLogToScreen then
        return
    end
    if not g_oGpu then
        return
    end

    if g_nCurrentLine >= g_nHeight then
        g_oGpu.copy(1, 2, g_nWidth, g_nHeight - 1, 0, -1)
        g_oGpu.fill(1, g_nHeight, g_nWidth, 1, " ")
    else
        g_nCurrentLine = g_nCurrentLine + 1
    end

    local nPrintY = g_nCurrentLine
    local nPrintX = 1

    -- Timestamp
    g_oGpu.setForeground(C_GRAY)
    g_oGpu.set(nPrintX, nPrintY, sTimestamp)
    nPrintX = nPrintX + #sTimestamp + 1

    -- Level tag
    g_oGpu.setForeground(tLevelInfo.color)
    g_oGpu.set(nPrintX, nPrintY, tLevelInfo.text)
    nPrintX = nPrintX + #tLevelInfo.text + 1

    -- PID (if not kernel)
    if g_nCurrentPid and g_nCurrentPid > 1 then
        g_oGpu.setForeground(0x888888)
        local sPid = string.format("P%-3d ", g_nCurrentPid)
        g_oGpu.set(nPrintX, nPrintY, sPid)
        nPrintX = nPrintX + #sPid
    end

    -- Message
    g_oGpu.setForeground(C_WHITE)
    local nMaxMsg = g_nWidth - nPrintX + 1
    if #sMessage > nMaxMsg then
        sMessage = sMessage:sub(1, nMaxMsg - 3) .. "..."
    end
    g_oGpu.set(nPrintX, nPrintY, sMessage)
end

local function rawtostring(v)
    local t = type(v)
    if t == "string" then
        return v
    end
    if t == "number" then
        return tostring(v)
    end
    if t == "boolean" then
        return v and "true" or "false"
    end
    if t == "nil" then
        return "nil"
    end
    local sAddr = "?"
    pcall(function()
        sAddr = string.format("%p", v)
    end)
    return t .. ": " .. sAddr
end

-- =============================================
-- CRASH DUMP WRITER
-- Writes structured crash report to raw filesystem
-- BEFORE showing BSOD. Survives reboot.
-- Also sets crash flag in EEPROM data area.
-- =============================================

local CRASH_FLAG_NONE     = 0
local CRASH_FLAG_PANIC    = 1
local CRASH_FLAG_PGVIOLATION = 2
local CRASH_FLAG_OOM      = 3
local CRASH_FLAG_WATCHDOG = 4

local function fWriteCrashDump(sReason, nCrashType, tPgViolations, coFaulting)
    -- Get raw filesystem handle (PM is dead, use raw_component)
    local oRawFs
    pcall(function()
        if g_bAxfsRoot then
            oRawFs = g_oPrimitiveFs
        else
            oRawFs = raw_component.proxy(kernel.tVfs.sRootUuid or boot_fs_address)
        end
    end)
    if not oRawFs then return false end

    -- Ensure /log exists
    pcall(function() oRawFs.makeDirectory("/log") end)

    -- Read boot counter for crash file naming
    local nBootNum = 0
    pcall(function()
        local ep
        for addr in raw_component.list("eeprom") do
            ep = raw_component.proxy(addr); break
        end
        if ep then
            local sData = ep.getData()
            if sData and #sData >= 244 then
                nBootNum = (sData:byte(241) or 0) * 16777216
                         + (sData:byte(242) or 0) * 65536
                         + (sData:byte(243) or 0) * 256
                         + (sData:byte(244) or 0)
            end
        end
    end)

    local sCrashPath = string.format("/log/crash_%03d.dump", nBootNum % 1000)

    -- Build crash dump content
    local tDump = {}
    local function wr(s) tDump[#tDump+1] = s end

    wr("========================================")
    wr("  AXISO CRASH DUMP")
    wr("========================================")
    wr("")
    wr(string.format("Timestamp:    %.4f seconds uptime", raw_computer.uptime()))
    wr(string.format("Boot #:       %d", nBootNum))
    wr(string.format("Crash Type:   %d (%s)", nCrashType or 0,
        ({[0]="UNKNOWN",[1]="KERNEL_PANIC",[2]="PATCHGUARD",
          [3]="OOM_KILL",[4]="WATCHDOG"})[nCrashType or 0] or "?"))
    wr("")
    wr("--- REASON ---")
    wr(tostring(sReason or "No reason"))
    wr("")

    -- PatchGuard violations
    if tPgViolations and #tPgViolations > 0 then
        wr("--- PATCHGUARD VIOLATIONS ---")
        for i, v in ipairs(tPgViolations) do
            wr(string.format("  [%d] %s: %s (expected=%s actual=%s)",
                i, v.t or "?", v.d or "?",
                v.e or "N/A", v.a or "N/A"))
        end
        wr("")
    end

    -- Faulting process
    local nFaultPid = coFaulting and kernel.tPidMap[coFaulting]
    if nFaultPid then
        local p = kernel.tProcessTable[nFaultPid]
        wr("--- FAULTING PROCESS ---")
        wr(string.format("  PID:     %d", nFaultPid))
        wr(string.format("  Ring:    %s", tostring(p.ring)))
        wr(string.format("  Status:  %s", tostring(p.status)))
        wr(string.format("  UID:     %s", tostring(p.uid)))
        wr(string.format("  Synapse: %s", tostring(p.synapseToken)))
        wr(string.format("  CPU:     %.4fs", p.nCpuTime or 0))
        wr(string.format("  WD Strikes: %d", p.nWatchdogStrikes or 0))
        local sImage = "?"
        if p.env and p.env.env and p.env.env.arg then
            sImage = p.env.env.arg[0] or "?"
        end
        wr(string.format("  Image:   %s", sImage))
        wr("")

        -- Stack trace
        local bTraceOk, sTrace = pcall(debug.traceback, coFaulting)
        if bTraceOk and sTrace then
            wr("--- STACK TRACE ---")
            for line in sTrace:gmatch("[^\n]+") do
                wr("  " .. line)
            end
            wr("")
        end
    end

    -- Full process table
    wr("--- PROCESS TABLE ---")
    wr(string.format("%-5s %-5s %-6s %-10s %-6s %-8s %s",
        "PID", "PPID", "RING", "STATUS", "UID", "CPU(s)", "IMAGE"))
    local nProcCount = 0
    for pid, p in pairs(kernel.tProcessTable) do
        nProcCount = nProcCount + 1
        if nProcCount > 50 then wr("  ... truncated"); break end
        local sImg = "?"
        if p.env and p.env.env and p.env.env.arg then
            sImg = p.env.env.arg[0] or "?"
        end
        wr(string.format("%-5d %-5d %-6s %-10s %-6s %-8.3f %s",
            pid, p.parent or 0, tostring(p.ring),
            p.status or "?", tostring(p.uid),
            p.nCpuTime or 0, sImg))
    end
    wr("")

    -- Scheduler stats
    wr("--- SCHEDULER ---")
    wr(string.format("  Total resumes:    %d", g_tSchedStats.nTotalResumes))
    wr(string.format("  Preemptions:      %d", g_tSchedStats.nPreemptions))
    wr(string.format("  Watchdog warns:   %d", g_tSchedStats.nWatchdogWarnings))
    wr(string.format("  Watchdog kills:   %d", g_tSchedStats.nWatchdogKills))
    wr(string.format("  Max slice:        %.2f ms", g_tSchedStats.nMaxSliceMs))
    wr("")

    -- PatchGuard stats
    if g_oPatchGuard then
        local tPgS = g_oPatchGuard.GetStats()
        wr("--- PATCHGUARD ---")
        wr(string.format("  Armed:            %s", tostring(tPgS.bArmed)))
        wr(string.format("  Checks:           %d", tPgS.nChecksPerformed or 0))
        wr(string.format("  Violations:       %d", tPgS.nViolations or 0))
        wr(string.format("  SecureBoot:       %s", tostring(tPgS.bSecureBootActive)))
        wr(string.format("  EEPROM monitored: %s", tostring(tPgS.bEepromMonitored)))
        wr(string.format("  Syscalls watched: %d", tPgS.nSyscallsMonitored or 0))
        wr(string.format("  Frozen libs:      %d", tPgS.nFrozenLibs or 0))
        wr(string.format("  OB paths:         %d", tPgS.nObPaths or 0))
        wr("")
    end

    -- Memory
    wr("--- MEMORY ---")
    local nT = raw_computer.totalMemory and raw_computer.totalMemory() or 0
    local nF = raw_computer.freeMemory and raw_computer.freeMemory() or 0
    wr(string.format("  Total:  %d bytes (%.1f KB)", nT, nT/1024))
    wr(string.format("  Free:   %d bytes (%.1f KB)", nF, nF/1024))
    wr(string.format("  Used:   %d bytes (%.1f KB)", nT-nF, (nT-nF)/1024))
    wr("")

    -- IPC stats
    if g_oIpc then
        local tIS = g_oIpc.GetStats()
        wr("--- IPC ---")
        wr(string.format("  Signals sent:     %d", tIS.nSignalsSent or 0))
        wr(string.format("  Pipes created:    %d", tIS.nPipeCreated or 0))
        wr(string.format("  Waits issued:     %d", tIS.nWaitsIssued or 0))
        wr(string.format("  Waits timed out:  %d", tIS.nWaitsTimedOut or 0))
        wr("")
    end

    -- Last 30 dmesg entries
    wr("--- LAST 30 DMESG ENTRIES ---")
    local nStart = math.max(1, #g_tDmesg - 29)
    for i = nStart, #g_tDmesg do
        local e = g_tDmesg[i]
        wr(string.format("  [%9.4f] [%-6s] P%-3d %s",
            e.time, e.level, e.pid or 0, e.msg))
    end
    wr("")

    -- Components
    wr("--- COMPONENTS ---")
    pcall(function()
        for addr, ctype in raw_component.list() do
            wr(string.format("  [%s] %s", addr:sub(1,13), ctype))
        end
    end)
    wr("")
    wr("========================================")
    wr("  END CRASH DUMP")
    wr("========================================")

    -- Write to file
    local sDumpStr = table.concat(tDump, "\n")
    local bWriteOk = false
    pcall(function()
        local h = oRawFs.open(sCrashPath, "w")
        if h then
            oRawFs.write(h, sDumpStr)
            oRawFs.close(h)
            bWriteOk = true
        end
    end)

    -- Also append to current VBL if exists
    pcall(function()
        local tVblList = oRawFs.list("/vbl")
        if tVblList then
            local sLatest = nil
            for _, sName in ipairs(tVblList) do
                local sClean = type(sName) == "string" and sName:gsub("/$","") or ""
                if sClean:match("%.vbl$") then sLatest = sClean end
            end
            if sLatest then
                local h = oRawFs.open("/vbl/" .. sLatest, "a")
                if h then
                    oRawFs.write(h, "\n\n" .. sDumpStr)
                    oRawFs.close(h)
                end
            end
        end
    end)

    -- Set EEPROM crash flag (byte 245 = crash type, byte 246 = PG violation count)
    pcall(function()
        local ep
        for addr in raw_component.list("eeprom") do
            ep = raw_component.proxy(addr); break
        end
        if ep then
            local sData = ep.getData() or string.rep("\0", 256)
            if #sData < 256 then
                sData = sData .. string.rep("\0", 256 - #sData)
            end
            local nPgCount = tPgViolations and #tPgViolations or 0
            sData = sData:sub(1, 244)
                 .. string.char(nCrashType or 1)
                 .. string.char(math.min(255, nPgCount))
                 .. sData:sub(247)
            ep.setData(sData)
        end
    end)

    return bWriteOk, sCrashPath
end

-------------------------------------------------
-- KERNEL PANIC
-------------------------------------------------

function kernel.panic(sReason, coFaulting, tPgViolations)
    -- Write crash dump BEFORE anything visual
    local nCrashType = CRASH_FLAG_PANIC
    if tPgViolations and #tPgViolations > 0 then
        nCrashType = CRASH_FLAG_PGVIOLATION
    end

    local bDumpOk, sDumpPath = pcall(fWriteCrashDump,
        sReason, nCrashType, tPgViolations, coFaulting)

    -- Descending tritone into flatline
    raw_computer.beep(1200, 0.1)
    raw_computer.pullSignal(0.15)
    raw_computer.beep(100, 2.0)

    -- Find GPU
    local sGpuAddress, sScreenAddress
    for sAddr in raw_component.list("gpu") do
        sGpuAddress = sAddr; break
    end
    for sAddr in raw_component.list("screen") do
        sScreenAddress = sAddr; break
    end
    if not sGpuAddress or not sScreenAddress then
        while true do raw_computer.pullSignal(1) end
    end

    local oGpu = raw_component.proxy(sGpuAddress)
    pcall(oGpu.bind, sScreenAddress)
    local nW, nH = oGpu.getResolution()
    pcall(oGpu.setBackground, 0x0000AA)
    pcall(oGpu.setForeground, 0xFFFFFF)
    pcall(oGpu.fill, 1, 1, nW, nH, " ")

    local y = 1
    local function print_line(sText, sColor)
        if y > nH then return end
        local sClean = tostring(sText or ""):gsub("[%c]", " ")
        if #sClean > nW - 3 then
            sClean = sClean:sub(1, nW - 6) .. "..."
        end
        pcall(oGpu.setForeground, sColor or 0xFFFFFF)
        pcall(oGpu.set, 2, y, sClean)
        y = y + 1
    end

    -- Generate stop code
    local nStopCode = 0
    local sReasonFlat = tostring(sReason or "")
    for i = 1, math.min(#sReasonFlat, 64) do
        nStopCode = (nStopCode * 31 + sReasonFlat:byte(i)) % 0xFFFFFFFF
    end

    local tStopCodes = {
        CRITICAL_STRUCTURE_CORRUPTION = 0x00000109,
        KERNEL_SECURITY_CHECK_FAILURE = 0x00000139,
        PATCHGUARD_VIOLATION          = 0x00000109,
        OOM_KILL                      = 0x0000009F,
        WATCHDOG_TIMEOUT              = 0x00000101,
        IRQL_NOT_LESS_OR_EQUAL        = 0x0000000A,
        SYSTEM_SERVICE_EXCEPTION      = 0x0000003B,
    }
    for sName, nCode in pairs(tStopCodes) do
        if sReasonFlat:find(sName, 1, true) then
            nStopCode = nCode
            break
        end
    end

    -- Header
    print_line("")
    print_line(":( Your system ran into a problem and needs to restart.", 0xFFFFFF)
    print_line("")
    print_line(string.format(
        "*** STOP: 0x%08X", nStopCode), 0xFF5555)
    print_line("")

    -- Reason (multi-line safe)
    for sLine in (sReasonFlat .. "\n"):gmatch("([^\n]*)\n") do
        if #sLine > 0 then
            print_line("  " .. sLine, 0xFFFF55)
        end
    end
    y = y + 1

    -- System state
    local nUptime = raw_computer.uptime()
    local nTotalMem = raw_computer.totalMemory and raw_computer.totalMemory() or 0
    local nFreeMem = raw_computer.freeMemory and raw_computer.freeMemory() or 0
    local nUsedPct = nTotalMem > 0
        and math.floor((nTotalMem - nFreeMem) / nTotalMem * 100) or 0

    print_line("---[ System State ]---", 0x55FFFF)
    print_line(string.format(
        "Uptime: %d:%02d:%02d    Memory: %dKB / %dKB (%d%% used)",
        math.floor(nUptime / 3600),
        math.floor((nUptime % 3600) / 60),
        math.floor(nUptime % 60),
        math.floor((nTotalMem - nFreeMem) / 1024),
        math.floor(nTotalMem / 1024),
        nUsedPct), 0xAAAAAA)
    print_line(string.format(
        "Processes: %d    Scheduler: %d resumes, %d preemptions, %d WD kills",
        kernel.nNextPid - 1,
        g_tSchedStats.nTotalResumes,
        g_tSchedStats.nPreemptions,
        g_tSchedStats.nWatchdogKills), 0xAAAAAA)

    if g_oPatchGuard then
        local tPgS = g_oPatchGuard.GetStats()
        print_line(string.format(
            "PatchGuard: %s, %d checks, %d violations, %d files monitored",
            tPgS.bArmed and "ARMED" or "DISARMED",
            tPgS.nChecksPerformed or 0,
            tPgS.nViolations or 0,
            tPgS.nCriticalFilesHashed or 0), 0xAAAAAA)
    end
    y = y + 1

    -- PatchGuard violations (if any)
    if tPgViolations and #tPgViolations > 0 then
        print_line("---[ Integrity Violations ]---", 0xFF55FF)
        for i, v in ipairs(tPgViolations) do
            if i > 6 then
                print_line(string.format(
                    "  ... and %d more", #tPgViolations - 6), 0xAAAAAA)
                break
            end
            print_line(string.format(
                "  [%d] %s: %s", i, v.t or "?", v.d or "?"), 0xFF5555)
            if v.e then
                print_line(string.format(
                    "      expected: %s", v.e), 0xAAAAAA)
            end
            if v.a then
                print_line(string.format(
                    "      actual:   %s", v.a), 0xAAAAAA)
            end
        end
        y = y + 1
    end

    -- Faulting process
    local nFaultingPid = coFaulting and kernel.tPidMap[coFaulting]
    if nFaultingPid then
        local p = kernel.tProcessTable[nFaultingPid]
        local sPath = "N/A"
        if p.env and p.env.arg and type(p.env.arg) == "table" then
            sPath = p.env.arg[0] or "N/A"
        end

        print_line("---[ Faulting Process ]---", 0x55FFFF)
        print_line(string.format(
            "PID: %d   Ring: %s   UID: %s   Status: %s",
            nFaultingPid,
            tostring(p.ring or "?"),
            tostring(p.uid or "?"),
            tostring(p.status or "?")), 0xFFFFFF)
        print_line("Image: " .. sPath, 0xAAAAAA)
        print_line(string.format(
            "CPU: %.3fs   Preemptions: %d   WD Strikes: %d",
            p.nCpuTime or 0,
            p.nPreemptCount or 0,
            p.nWatchdogStrikes or 0), 0xAAAAAA)
        print_line("Synapse: " ..
            tostring(p.synapseToken or "N/A"):sub(1, 24) .. "...", 0x888888)
        y = y + 1

        -- Stack trace
        local bTraceOk, sTraceback = pcall(debug.traceback, coFaulting)
        if bTraceOk and sTraceback then
            print_line("---[ Stack Trace ]---", 0x55FFFF)
            for line in sTraceback:gmatch("[^\r\n]+") do
                line = line:gsub("kernel.lua", "kernel")
                line = line:gsub("pipeline_manager.lua", "pm")
                line = line:gsub("dkms.lua", "dkms")
                print_line("  " .. line, 0xAAAAAA)
                if y > nH - 12 then
                    print_line("  ... (trace truncated)", 0x888888)
                    break
                end
            end
            y = y + 1
        end
    else
        print_line("---[ Faulting Context ]---", 0x55FFFF)
        print_line(
            "Panic occurred outside a managed process (boot / scheduler).",
            0xFFFF55)
        y = y + 1
    end

    -- Process table (compact)
    local nRemaining = nH - y - 8
    if nRemaining > 3 then
        print_line("---[ Process Table ]---", 0x55FFFF)
        print_line(string.format(
            "%-5s %-5s %-6s %-10s %-8s %s",
            "PID", "PPID", "RING", "STATUS", "CPU(s)", "IMAGE"), 0xAAAAAA)

        local tSorted = {}
        for pid, p in pairs(kernel.tProcessTable) do
            tSorted[#tSorted + 1] = {pid = pid, proc = p}
        end
        table.sort(tSorted, function(a, b) return a.pid < b.pid end)

        local nShown = 0
        for _, entry in ipairs(tSorted) do
            if nShown >= nRemaining - 2 then
                print_line(string.format(
                    "  ... %d more process(es)",
                    #tSorted - nShown), 0x888888)
                break
            end
            local pid = entry.pid
            local p = entry.proc
            local sImg = "?"
            if p.env and p.env.arg and type(p.env.arg) == "table" then
                sImg = p.env.arg[0] or "?"
            end
            if #sImg > 30 then
                sImg = ".." .. sImg:sub(-28)
            end

            local sStatusColor = 0xFFFFFF
            if p.status == "dead" then sStatusColor = 0xFF5555
            elseif p.status == "sleeping" then sStatusColor = 0x888888
            elseif p.status == "running" then sStatusColor = 0x55FF55 end

            pcall(oGpu.setForeground, 0xFFFFFF)
            pcall(oGpu.set, 2, y, string.format("%-5d %-5d %-6s ",
                pid, p.parent or 0, tostring(p.ring or "?")))
            pcall(oGpu.setForeground, sStatusColor)
            pcall(oGpu.set, 20, y, string.format("%-10s", p.status or "?"))
            pcall(oGpu.setForeground, 0xAAAAAA)
            pcall(oGpu.set, 31, y, string.format("%-8.3f %s",
                p.nCpuTime or 0, sImg))
            y = y + 1
            nShown = nShown + 1
        end
        y = y + 1
    end

    -- Footer separator
    y = nH - 4
    pcall(oGpu.setForeground, 0x555555)
    pcall(oGpu.set, 2, y, string.rep("=", nW - 2))
    y = y + 1

    -- Crash dump status
    if bDumpOk and sDumpPath then
        print_line(
            "Crash dump saved: " .. tostring(sDumpPath),
            0x55FF55)
        print_line(
            "Review after reboot: cat " .. tostring(sDumpPath),
            0x55FF55)
    else
        print_line(
            "Crash dump FAILED to write. Diagnostics may be lost.",
            0xFF5555)
    end

    -- Final line
    pcall(oGpu.setForeground, 0xFFFF55)
    pcall(oGpu.set, 2, nH, string.format(
        " System halted. Power cycle to restart.          STOP 0x%08X ",
        nStopCode))

    while true do raw_computer.pullSignal(1) end
end

------------------------------------------------
-- BOOT MSG
------------------------------------------------

__logger_init()

local g_tFrozenString, g_tFrozenTable, g_tFrozenMath, g_tFrozenOs

do
    -- String (minus dump, with bounded rep)
    local fRealRep = string.rep
    g_tFrozenString = {}
    for k, v in pairs(string) do
        g_tFrozenString[k] = v
    end
    g_tFrozenString.dump = nil
    g_tFrozenString.rep = function(s, n, sep)
        local nEst = #s * n + (sep and #sep * (n - 1) or 0)
        if nEst > 1048576 then
            error("string.rep: result too large", 2)
        end
        return fRealRep(s, n, sep)
    end

    -- Table
    g_tFrozenTable = {}
    for k, v in pairs(table) do
        g_tFrozenTable[k] = v
    end

    -- Math
    g_tFrozenMath = {}
    for k, v in pairs(math) do
        g_tFrozenMath[k] = v
    end

    -- Os (safe subset)
    g_tFrozenOs = {}
    for k, v in pairs(os) do
        if k ~= "exit" and k ~= "execute" and k ~= "remove" and k ~= "rename" then
            g_tFrozenOs[k] = v
        end
    end
end

kprint("info", "AxisOS Xen XKA v0.6-HV starting...")
kprint("info", "Copyright (C) 2026 AxisOS")
kprint("none", "")

-------------------------------------------------
-- PRIMITIVE BOOTLOADER HELPERS
-------------------------------------------------

-- =============================================
-- ROOT FILESYSTEM BOOTSTRAP
-- Detects AXFS boot or falls back to managed FS
-- =============================================

local g_oPrimitiveFs

if _G.boot_fs_type == "axfs" then
    -- Booted from AXFS create minimal volume reader
    -- Load bpack inline (can't require yet)
    local function r16(s, o)
        return s:byte(o) * 256 + s:byte(o + 1)
    end
    local function r32(s, o)
        return s:byte(o) * 16777216 + s:byte(o + 1) * 65536 + s:byte(o + 2) * 256 + s:byte(o + 3)
    end
    local function rstr(s, o, n)
        local r = s:sub(o, o + n - 1);
        local z = r:find("\0", 1, true);
        return z and r:sub(1, z - 1) or r
    end

    local oDrv = raw_component.proxy(_G.boot_drive_addr)
    local nPOff = _G.boot_part_offset
    local ss = oDrv.getSectorSize()

    local function prs(n)
        return oDrv.readSector(nPOff + n + 1)
    end

    local sb = prs(0)
    local nDS = r16(sb, 20)
    local ips = math.floor(ss / 64)

    local function ri(n)
        local sec = 3 + math.floor(n / ips);
        local off = (n % ips) * 64
        local sd = prs(sec);
        if not sd then
            return nil
        end
        local o = off + 1
        local t = {
            iType = r16(sd, o),
            size = r32(sd, o + 8),
            nBlk = r16(sd, o + 22),
            dir = {},
            ind = r16(sd, o + 44)
        }
        for i = 1, 10 do
            t.dir[i] = r16(sd, o + 24 + (i - 1) * 2)
        end
        return t
    end
    local function rb(n)
        return prs(nDS + n)
    end
    local function blks(t)
        local r = {}
        for i = 1, math.min(10, t.nBlk) do
            if t.dir[i] and t.dir[i] > 0 then
                r[#r + 1] = t.dir[i]
            end
        end
        if t.nBlk > 10 and t.ind > 0 then
            local si = rb(t.ind);
            if si then
                for i = 1, math.floor(ss / 2) do
                    local p2 = r16(si, (i - 1) * 2 + 1);
                    if p2 > 0 then
                        r[#r + 1] = p2
                    end
                end
            end
        end
        return r
    end
    local function dfind(di, nm)
        local dpb = math.floor(ss / 32)
        for _, bn in ipairs(blks(di)) do
            local sd = rb(bn);
            if sd then
                for i = 0, dpb - 1 do
                    local o = i * 32 + 1;
                    local ino = r16(sd, o)
                    if ino > 0 then
                        local nl = sd:byte(o + 3);
                        if sd:sub(o + 4, o + 3 + nl) == nm then
                            return ino
                        end
                    end
                end
            end
        end
    end
    local function resolve(p)
        local c = 1;
        for seg in p:gmatch("[^/]+") do
            local t = ri(c);
            if not t or t.iType ~= 2 then
                return nil
            end
            c = dfind(t, seg);
            if not c then
                return nil
            end
        end
        return c
    end
    local function readfile(p)
        local n = resolve(p);
        if not n then
            return nil
        end
        local t = ri(n);
        if not t or t.iType ~= 1 then
            return nil
        end
        local ch = {};
        local rem = t.size
        for _, bn in ipairs(blks(t)) do
            local sd = rb(bn);
            if sd then
                ch[#ch + 1] = sd:sub(1, math.min(rem, ss));
                rem = rem - ss
            end
            if rem <= 0 then
                break
            end
        end
        return table.concat(ch)
    end

    -- Now load axfs_core + axfs_proxy properly
    local sAxCode = readfile("/lib/axfs_core.lua")
    local sBpCode = readfile("/lib/bpack.lua")
    local sPxCode = readfile("/lib/axfs_proxy.lua")

    if sAxCode and sBpCode and sPxCode then
        -- Load bpack
        local tBpEnv = {
            string = string,
            math = math,
            table = table
        }
        local fBp = load(sBpCode, "@bpack", "t", tBpEnv)
        local oBpack = fBp()

        -- Load axfs_core with bpack available
        local tAxEnv = {
            string = string,
            math = math,
            table = table,
            os = os,
            type = type,
            tostring = tostring,
            pairs = pairs,
            ipairs = ipairs,
            setmetatable = setmetatable,
            require = function(m)
                if m == "bpack" then
                    return oBpack
                end
                error("Cannot require '" .. m .. "' during AXFS boot")
            end
        }
        local fAx = load(sAxCode, "@axfs_core", "t", tAxEnv)
        local oAXFS = fAx()

        -- Load proxy module
        local tPxEnv = {
            string = string,
            math = math,
            table = table,
            tostring = tostring,
            type = type,
            pairs = pairs,
            ipairs = ipairs,
            require = function(m)
                if m == "axfs_core" then
                    return oAXFS
                end
                if m == "bpack" then
                    return oBpack
                end
            end
        }
        local fPx = load(sPxCode, "@axfs_proxy", "t", tPxEnv)
        local oProxy = fPx()

        -- Create proper AXFS volume
        local tDisk = oAXFS.wrapDrive(oDrv, nPOff, _G.boot_part_size)
        local vol, vErr = oAXFS.mount(tDisk)

        if vol then
            g_oAxfsVol = vol
            g_bAxfsRoot = true
            g_oPrimitiveFs = oProxy.createProxy(vol, "root")
            __gpu_dprint("AXFS root mounted (" .. vol.su.label .. ")")
        else
            kernel.panic("Failed to mount AXFS root: " .. tostring(vErr))
        end
    else
        kernel.panic("AXFS boot: missing core libraries on disk")
    end
else
    -- Standard managed FS boot
    g_oPrimitiveFs = raw_component.proxy(boot_fs_address)
end

local function primitive_load(sPath)
    local hFile, sReason = g_oPrimitiveFs.open(sPath, "r")
    if not hFile then
        return nil, "primitive_load failed to open: " .. tostring(sReason or "Unknown error")
    end
    local tChunks = {}
    while true do
        local sChunk = g_oPrimitiveFs.read(hFile, math.huge)
        if not sChunk then
            break
        end
        tChunks[#tChunks + 1] = sChunk
    end
    g_oPrimitiveFs.close(hFile)
    local sData = table.concat(tChunks)
    if #sData == 0 then
        return nil, "primitive_load: empty file: " .. sPath
    end
    return sData
end

local function primitive_load_lua(sPath)
    local sCode, sErr = primitive_load(sPath)
    if not sCode then
        kernel.panic("CRITICAL: Failed to load " .. sPath .. ": " .. (sErr or "File not found"))
    end
    local fFunc, sLoadErr = load(sCode, "@" .. sPath, "t", {})
    if not fFunc then
        kernel.panic("CRITICAL: Failed to parse " .. sPath .. ": " .. sLoadErr)
    end
    return fFunc()
end

-------------------------------------------------
-- OBJECT MANAGER BOOT LOAD
-------------------------------------------------

local function __load_ob_manager()
    local sCode, sErr = primitive_load("/lib/ob_manager.lua")
    if not sCode then
        kprint("warn", "Object Manager not found at /lib/ob_manager.lua: " .. tostring(sErr))
        return nil
    end
    -- Provide a minimal sandbox for ob_manager to load in
    local tObEnv = {
        string = string,
        math = math,
        os = os,
        pairs = pairs,
        type = type,
        tostring = tostring,
        table = table,
        setmetatable = setmetatable,
        pcall = pcall,
        ipairs = ipairs,
        -- Give it access to raw_computer for uptime-based entropy
        raw_computer = raw_computer
    }
    local fChunk, sLoadErr = load(sCode, "@ob_manager", "t", tObEnv)
    if not fChunk then
        kprint("fail", "Failed to parse ob_manager: " .. tostring(sLoadErr))
        return nil
    end
    local bOk, oResult = pcall(fChunk)
    if bOk and type(oResult) == "table" then
        return oResult
    else
        kprint("fail", "Failed to init ob_manager: " .. tostring(oResult))
        return nil
    end
end

local function __load_registry()
    local sCode, sErr = primitive_load("/lib/registry.lua")
    if not sCode then
        kprint("warn", "Registry not found at /lib/registry.lua: " .. tostring(sErr))
        return nil
    end
    local tRegEnv = {
        string = string,
        math = math,
        os = os,
        pairs = pairs,
        type = type,
        tostring = tostring,
        table = table,
        setmetatable = setmetatable,
        pcall = pcall,
        ipairs = ipairs,
        raw_computer = raw_computer
    }
    local fChunk, sLoadErr = load(sCode, "@registry", "t", tRegEnv)
    if not fChunk then
        kprint("fail", "Failed to parse registry: " .. tostring(sLoadErr))
        return nil
    end
    local bOk, oResult = pcall(fChunk)
    if bOk and type(oResult) == "table" then
        return oResult
    else
        kprint("fail", "Failed to init registry: " .. tostring(oResult))
        return nil
    end
end

local function __load_preempt()
    local sCode, sErr = primitive_load("/lib/preempt.lua")
    if not sCode then
        kprint("warn", "Preempt module not found at /lib/preempt.lua: " .. tostring(sErr))
        return nil
    end
    local tEnv = {
        string = string,
        math = math,
        table = table,
        pairs = pairs,
        ipairs = ipairs,
        type = type,
        tostring = tostring,
        tonumber = tonumber
    }
    local fChunk, sLoadErr = load(sCode, "@preempt", "t", tEnv)
    if not fChunk then
        kprint("fail", "Failed to parse preempt module: " .. tostring(sLoadErr))
        return nil
    end
    local bOk, oResult = pcall(fChunk)
    if bOk and type(oResult) == "table" then
        return oResult
    else
        kprint("fail", "Failed to init preempt module: " .. tostring(oResult))
        return nil
    end
end

local function __load_ke_ipc()
    local sCode, sErr = primitive_load("/lib/ke_ipc.lua")
    if not sCode then
        kprint("warn", "ke_ipc not found: " .. tostring(sErr))
        return nil
    end
    local tEnv = {
        string = string,
        math = math,
        os = os,
        table = table,
        pairs = pairs,
        ipairs = ipairs,
        type = type,
        tostring = tostring,
        tonumber = tonumber,
        pcall = pcall,
        select = select,
        next = next,
        error = error,
        setmetatable = setmetatable,
        coroutine = coroutine,
        raw_computer = raw_computer
    }
    local fChunk, sLoadErr = load(sCode, "@ke_ipc", "t", tEnv)
    if not fChunk then
        kprint("fail", "Failed to parse ke_ipc: " .. tostring(sLoadErr))
        return nil
    end
    local bOk, oResult = pcall(fChunk)
    if bOk and type(oResult) == "table" then
        return oResult
    else
        kprint("fail", "Failed to init ke_ipc: " .. tostring(oResult));
        return nil
    end
end

local function __load_hypervisor()
    local sCode, sErr = primitive_load("/lib/hypervisor.lua")
    if not sCode then
        kprint("warn", "Hypervisor not found: " .. tostring(sErr))
        return nil
    end
    local tEnv = {
        string = string, math = math, table = table,
        pairs = pairs, ipairs = ipairs, type = type,
        tostring = tostring, tonumber = tonumber,
        next = next, error = error, setmetatable = setmetatable,
        rawget = rawget, rawset = rawset,
        pcall = pcall, raw_computer = raw_computer,
    }
    local fChunk, sLoadErr = load(sCode, "@hypervisor", "t", tEnv)
    if not fChunk then
        kprint("fail", "Failed to parse hypervisor: " .. tostring(sLoadErr))
        return nil
    end
    local bOk, oResult = pcall(fChunk)
    if bOk and type(oResult) == "table" then return oResult end
    kprint("fail", "Failed to init hypervisor: " .. tostring(oResult))
    return nil
end

local function __load_patchguard()
    local sCode, sErr = primitive_load("/sys/security/patchguard.lua")
    if not sCode then
        kprint("warn", "PatchGuard not found: " .. tostring(sErr))
        return nil
    end
    local tEnv = {
        string = string, math = math, table = table,
        pairs = pairs, ipairs = ipairs, type = type,
        tostring = tostring, tonumber = tonumber,
        next = next, pcall = pcall,
    }
    local fChunk, sLoadErr = load(sCode, "@patchguard", "t", tEnv)
    if not fChunk then
        kprint("fail", "Failed to parse PatchGuard: " .. tostring(sLoadErr))
        return nil
    end
    local bOk, oResult = pcall(fChunk)
    if bOk and type(oResult) == "table" then return oResult end
    kprint("fail", "Failed to init PatchGuard: " .. tostring(oResult))
    return nil
end

-------------------------------------------------
-- PROCESS & MODULE MANAGEMENT
-------------------------------------------------

function kernel.custom_require(sModulePath, nCallingPid)
    local tProc = kernel.tProcessTable[nCallingPid]
    if not tProc then
        return nil, "No such process"
    end

    -- Per-process cache
    if not tProc._moduleCache then
        tProc._moduleCache = {}
    end
    if tProc._moduleCache[sModulePath] then
        return tProc._moduleCache[sModulePath]
    end

    -- Load from global cache or disk
    if not kernel.tLoadedModules[sModulePath] then
        local tPathsToTry = {"/lib/" .. sModulePath .. ".lua", "/usr/lib/" .. sModulePath .. ".lua",
                             "/drivers/" .. sModulePath .. ".lua", "/drivers/" .. sModulePath .. ".sys.lua",
                             "/system/" .. sModulePath .. ".lua", "/system/lib/dk/" .. sModulePath .. ".lua",
                             "/sys/security/" .. sModulePath .. ".lua"}
        local sCode, sFoundPath
        for _, sPath in ipairs(tPathsToTry) do
            sCode = kernel.syscalls.vfs_read_file(nCallingPid, sPath)
            if sCode then
                sFoundPath = sPath;
                break
            end
        end
        if not sCode then
            return nil, "Module not found: " .. sModulePath
        end

        local fFunc, sLoadErr = load(sCode, "@" .. sFoundPath, "t", tProc.env)
        if not fFunc then
            return nil, "Failed to load module " .. sModulePath .. ": " .. sLoadErr
        end
        local bOk, result = pcall(fFunc)
        if not bOk then
            return nil, "Failed to init module " .. sModulePath .. ": " .. result
        end
        kernel.tLoadedModules[sModulePath] = result
    end

    -- Give this process its own copy if it's a table
    local cached = kernel.tLoadedModules[sModulePath]
    if type(cached) == "table" then
        local tCopy = {}
        for k, v in pairs(cached) do
            tCopy[k] = v
        end
        tProc._moduleCache[sModulePath] = tCopy
        return tCopy
    end
    tProc._moduleCache[sModulePath] = cached
    return cached
end

-- ANSI escape code stripper for NO_COLOR support
local function fStripAnsi(s)
    return s:gsub("\27%[[%d;]*[a-zA-Z]", "")
end

local function shallowCopy(t)
    local c = {}
    for k, v in pairs(t) do
        c[k] = v
    end
    return c
end

function kernel.create_sandbox(nPid, nRing)
    kprint("debug", "Creating sandbox", {
        pid = nPid,
        ring = nRing
    })
    -- =========================================================
    -- THREE-LAYER PROXY SANDBOX
    --
    -- The sandbox table itself is ALWAYS EMPTY.  Every global
    -- read goes through __index, every global write through
    -- __newindex.  This is possible because:
    --
    --   a) rawset / rawget are NOT exposed to Ring ≥ 2.5
    --   b) debug library is NOT exposed to Ring ≥ 1
    --   c) __metatable = "protected" blocks getmetatable() and
    --      setmetatable() on the sandbox itself
    --
    -- Three layers (checked in order by __index):
    --
    --   1. tProtected   kernel-owned, IMMUTABLE from user code
    --                     (__pc, syscall, load, require, print, io,
    --                      standard library names, etc.)
    --
    --   2. tUserGlobals user-writable globals
    --                     (anything user code assigns goes here;
    --                      writes to protected names are silently
    --                      dropped)
    --
    --   3. tSafeGlobals read-only platform APIs
    --                     (computer, unicode, bit32; ring-gated)
    -- =========================================================

    local tProtected = {} -- immutable kernel symbols
    local tUserGlobals = {} -- user-writable globals
    local tSandbox = {} -- EMPTY proxy MUST never gain direct keys

    local tSafeComputer = {
        uptime = computer.uptime,
        freeMemory = computer.freeMemory,
        totalMemory = computer.totalMemory,
        address = computer.address,
        tmpAddress = computer.tmpAddress
    }

    -- Capture real functions before any user code can replace them.
    -- These upvalues are used inside __pc() and can never be reached
    -- or modified by user code.
    local fRealYield = coroutine.yield
    local fRealUptime = raw_computer.uptime
    local fRealResume = coroutine.resume -- [FIX] capture for wrapped coroutine
    local fRealCreate = coroutine.create -- [FIX]
    local fRealStatus = coroutine.status -- [FIX]

    -- =============================================
    -- LAYER 1: Protected kernel symbols
    -- =============================================

    -- Standard Lua (safe subset NO rawset, rawget, debug)
    tProtected.assert = assert
    tProtected.error = error
    tProtected.next = next
    tProtected.pcall = pcall
    tProtected.select = select
    tProtected.tonumber = tonumber
    tProtected.tostring = tostring
    tProtected.type = type
    tProtected.unpack = unpack
    tProtected._VERSION = _VERSION
    tProtected.xpcall = xpcall

    do
        local fRealNext = next
        tProtected.pairs = function(t)
            if type(t) ~= "table" then
                error("bad argument #1 to 'pairs' (table expected, got " .. type(t) .. ")", 2)
            end
            return fRealNext, t, nil
        end
        tProtected.ipairs = function(t)
            if type(t) ~= "table" then
                error("bad argument #1 to 'ipairs' (table expected, got " .. type(t) .. ")", 2)
            end
            local i = 0
            return function()
                i = i + 1
                local v = rawget(t, i)
                if v ~= nil then
                    return i, v
                end
            end
        end
    end

    -- Library tables
    -- [FIX] REMOVED: tProtected.coroutine = coroutine
    -- coroutine is now set inside the preempt conditional block below,
    -- either as a depth-tracking wrapper (preemptive) or raw (cooperative).
    do
        local tSafeString = shallowCopy(string)
        tSafeString.dump = nil
        -- Cap string.rep to prevent single-call memory bombs
        local fRealRep = string.rep
        tSafeString.rep = function(s, n, sep)
            local nEst = #s * n + (sep and #sep * (n - 1) or 0)
            if nEst > 1048576 then
                error("string.rep: result too large", 2)
            end
            return fRealRep(s, n, sep)
        end
        tProtected.string = tSafeString
    end
    tProtected.table = shallowCopy(table)
    tProtected.math = shallowCopy(math)

    -- Safe os (no exit/execute/remove/rename)
    do
        local tSafeOs = {}
        for k, v in pairs(os) do
            if k ~= "exit" and k ~= "execute" and k ~= "remove" and k ~= "rename" then
                tSafeOs[k] = v
            end
        end
        tProtected.os = tSafeOs
    end

    do
        local fRealSetmt = setmetatable
        tProtected.setmetatable = function(tbl, mt)
            if type(mt) == "table" then
                rawset(mt, "__gc", nil)
            end
            return fRealSetmt(tbl, mt)
        end
    end
    tProtected.getmetatable = getmetatable

    -- ---- Kernel interfaces ----

    tProtected.syscall = function(...)
        return kernel.syscall_dispatch(...)
    end

    tProtected.require = function(sModulePath)
        local mod, sErr = kernel.custom_require(sModulePath, nPid)
        if not mod then
            error(sErr, 2)
        end
        return mod
    end

    -- ---- Preemptive checkpoint: __pc() ----

    if g_oPreempt and nRing >= 2.5 then
        local nPcCounter = 0
        local nPcLastYield = fRealUptime()
        local nPcQuantum = g_oPreempt.DEFAULT_QUANTUM
        local nPcInterval = g_oPreempt.CHECK_INTERVAL

        -- Thanks to @RedstoneParkour for pointing at this:
        -- "huh @Eurythmic i believe your preemptive multitasking impl can be bypassed with recursive tail call hell and the ternary operator cond and a or b"
        --
        -- [FIX] Sub-coroutine depth tracking.
        -- When user code creates coroutines via coroutine.create/wrap and
        -- resumes them, __pc() inside that sub-coroutine can only yield
        -- the sub-coroutine not the process.  Without depth tracking,
        -- an attacker can nest coroutine.resume inside a loop and
        -- amplify the checkpoint interval (inner runs N iters, outer
        -- runs N iters → N² iterations before the process yields).
        --
        -- Exactly what changed: the wrapped resume tracks nesting depth.
        -- When __pc() fires inside a sub-coroutine it yields the sub-coroutine AND
        -- sets bForceYield.  When the wrapper returns to depth 0 it
        -- yields the process coroutine, giving the scheduler control.
        local nCoDepth = 0 -- 0 = process level, >0 = sub-coroutine
        local bForceYield = false -- set by __pc when quantum expired in sub-co

        tProtected.__pc = function()
            nPcCounter = nPcCounter + 1
            if nPcCounter < nPcInterval then
                return
            end
            nPcCounter = 0

            -- Signal delivery
            if g_oIpc then
                local tProc = kernel.tProcessTable[nPid]
                if tProc and tProc.tPendingSignals and #tProc.tPendingSignals > 0 then
                    g_oIpc.DeliverSignals(nPid)
                    if tProc.status == "dead" then
                        fRealYield()
                        return
                    end
                end
            end

            local nNow = fRealUptime()
            if nNow - nPcLastYield >= nPcQuantum then
                if nCoDepth > 0 then
                    -- [FIX] We are inside a user sub-coroutine.
                    -- fRealYield() will only yield the sub-coroutine
                    -- back to the wrapper's resume call.  Set the flag
                    -- so the wrapper also yields the process.
                    bForceYield = true
                end
                fRealYield()
                nPcLastYield = fRealUptime()
            end
        end

        -- [FIX] Wrapped coroutine library with depth tracking.
        -- create, yield, status, running are passed through unchanged.
        -- resume and wrap are intercepted to maintain nCoDepth and
        -- honour bForceYield when returning to process level.
        local tSafeCoroutine = {
            create = fRealCreate,
            yield = fRealYield,
            status = fRealStatus,
            running = coroutine.running
        }

        tSafeCoroutine.resume = function(co, ...)
            nCoDepth = nCoDepth + 1
            local tResults = {fRealResume(co, ...)}
            nCoDepth = nCoDepth - 1

            -- Back at process level: if __pc() requested a yield while
            -- we were inside the sub-coroutine, yield the process now.
            if nCoDepth == 0 and bForceYield then
                bForceYield = false
                fRealYield()
                nPcLastYield = fRealUptime()
            end

            return table.unpack(tResults)
        end

        tSafeCoroutine.wrap = function(f)
            local co = fRealCreate(f)
            return function(...)
                nCoDepth = nCoDepth + 1
                local tResults = {fRealResume(co, ...)}
                nCoDepth = nCoDepth - 1

                if nCoDepth == 0 and bForceYield then
                    bForceYield = false
                    fRealYield()
                    nPcLastYield = fRealUptime()
                end

                -- coroutine.wrap convention: error on failure
                if not tResults[1] then
                    error(tResults[2], 0)
                end
                return table.unpack(tResults, 2)
            end
        end

        tProtected.coroutine = tSafeCoroutine -- [FIX] wrapped version

        local fKernelLoad = load
        tProtected.load = function(sChunk, sName, sMode, _tUserEnv)
            if type(sChunk) == "function" then
                local tParts = {}
                while true do
                    local sPart = sChunk()
                    if not sPart or sPart == "" then
                        break
                    end
                    tParts[#tParts + 1] = sPart
                end
                sChunk = table.concat(tParts)
            end
            if type(sChunk) ~= "string" then
                return nil, "string expected"
            end
            local sInst, nInj = g_oPreempt.instrument(sChunk, sName or "[dynamic]")
            if nInj > 0 then
                sChunk = sInst
            end
            return fKernelLoad(sChunk, sName, "t", tSandbox)
        end
    else
        tProtected.__pc = function()
        end
        tProtected.coroutine = coroutine -- [FIX] no preemption = raw coroutine
        tProtected.load = load
    end

    -- ---- print / io ----

    tProtected.print = function(...)
        local tP = {}
        for i = 1, select("#", ...) do
            tP[i] = tostring(select(i, ...))
        end
        local sOut = table.concat(tP, "\t") .. "\n"
        local tE = tUserGlobals.env
        if tE and tE.NO_COLOR then
            sOut = fStripAnsi(sOut)
        end
        kernel.syscall_dispatch("vfs_write", -11, sOut)
    end

    tProtected.io = {
        write = function(...)
            local tP = {}
            for i = 1, select("#", ...) do
                tP[i] = tostring(select(i, ...))
            end
            local sOut = table.concat(tP)
            local tE = tUserGlobals.env
            if tE and tE.NO_COLOR then
                sOut = fStripAnsi(sOut)
            end
            kernel.syscall_dispatch("vfs_write", -11, sOut)
        end,
        read = function()
            local _, _, data = kernel.syscall_dispatch("vfs_read", -10)
            return data
        end
    }

    -- =============================================
    -- LAYER 3: Safe platform globals (ring-gated)
    -- =============================================

    local tSafeGlobals = {
        computer = tSafeComputer,
        unicode = unicode,
        bit32 = bit32,
        checkArg = checkArg,
        rawequal = rawequal,
        rawlen = rawlen
    }

    if nRing == 0 then
        -- God-mode
        tProtected.kernel = kernel
        tProtected.raw_component = raw_component
        tProtected.raw_computer = raw_computer
        tProtected.rawset = rawset
        tProtected.rawget = rawget
        tProtected.debug = debug
        tSafeGlobals.component = component
    elseif nRing <= 2 then
        -- Drivers / Pipeline Manager need component and raw ops
        tSafeGlobals.component = component
        tSafeGlobals.rawset = rawset
        tSafeGlobals.rawget = rawget
    end
    -- Ring 2.5, 3: NO rawset, rawget, debug, raw_component, raw_computer

    -- =============================================
    -- METATABLE the core of the protection
    -- =============================================

    -- Fast-lookup set of all protected key names
    local tProtectedSet = {}
    for k in pairs(tProtected) do
        tProtectedSet[k] = true
    end
    tProtectedSet["_G"] = true

    setmetatable(tSandbox, {
        __index = function(_, key)
            -- Priority 1: protected kernel symbols (ALWAYS win)
            local pv = tProtected[key]
            if pv ~= nil then
                return pv
            end
            -- Priority 2: _G self-reference
            if key == "_G" then
                return tSandbox
            end
            -- Priority 3: user-defined globals
            local uv = tUserGlobals[key]
            if uv ~= nil then
                return uv
            end
            -- Priority 4: safe platform globals
            return tSafeGlobals[key]
        end,

        __newindex = function(_, key, value)
            -- Writes to protected names are silently dropped.
            if tProtectedSet[key] then
                return
            end
            tUserGlobals[key] = value
        end,

        -- Makes getmetatable(sandbox) return "protected" (not the real mt).
        -- Makes setmetatable(sandbox, ...) raise an error.
        __metatable = "protected"
    })

    return tSandbox
end

function kernel.create_process(sPath, nRing, nParentPid, tPassEnv)
    local nPid = kernel.nNextPid
    kernel.nNextPid = kernel.nNextPid + 1

    kprint("info", "Creating process " .. nPid .. " ('" .. sPath .. "') at Ring " .. nRing)
    kprint("proc", "spawn", {
        pid = nPid,
        ring = nRing,
        parent = nParentPid or 0,
        image = sPath
    })

    local sCode, sErr = kernel.syscalls.vfs_read_file(0, sPath)
    if not sCode then
        kprint("fail", "Failed to create process: " .. sErr)
        return nil, sErr
    end

    kprint("debug", "Loaded source", {
        pid = nPid,
        bytes = #sCode
    })

    -- =========================================================
    -- PREEMPTIVE SCHEDULING:  instrument source for Ring ≥ 2.5
    -- Injects __pc() calls after every  do / then / repeat / else
    -- so the process yields back to the scheduler periodically.
    -- =========================================================
    if g_oPreempt and nRing >= 2.5 then
        local sInstrumented, nInjections = g_oPreempt.instrument(sCode, sPath)
        if nInjections > 0 then
            kprint("sched", "Instrumented", {
                pid = nPid,
                checkpoints = nInjections,
                image = sPath
            })
            kprint("dev", string.format("Preempt: %s → %d yield checkpoints injected", sPath, nInjections))
            sCode = sInstrumented
        else
            kprint("dev", "Preempt: " .. sPath .. " no loops/branches to instrument")
        end
    end

    local tEnv = kernel.create_sandbox(nPid, nRing)
    if tPassEnv then
        tEnv.env = tPassEnv
    end

    local fFunc, sLoadErr = load(sCode, "@" .. sPath, "t", tEnv)
    if not fFunc then
        kprint("fail", "SYNTAX ERROR in " .. sPath .. ": " .. tostring(sLoadErr))
        return nil, sLoadErr
    end

    local coProcess = coroutine.create(function()
        local bIsOk, sErr = pcall(fFunc)
        if not bIsOk then
            kprint("fail", "!!! KERNEL ALERT: PROCESS " .. nPid .. " CRASHED !!!")
            kprint("fail", "Crash reason: " .. tostring(sErr))
        else
            kprint("info", "Process " .. nPid .. " exited normally.")
        end
        kernel.tProcessTable[nPid].status = "dead"
    end)

    -- sMLTR: Generate unique synapse token for this process
    local sSynapseToken = fGenerateSynapseToken()

    kernel.tProcessTable[nPid] = {
        co = coProcess,
        status = "ready",
        ring = nRing,
        parent = nParentPid,
        env = tEnv,
        fds = {},
        wait_queue = {},
        run_queue = {},
        uid = (tPassEnv and tPassEnv.UID) or 1000,
        -- sMLTR
        synapseToken = sSynapseToken,
        -- Thread tracking
        threads = {},
        -- Preemptive scheduler per-process stats
        nCpuTime = 0,
        nPreemptCount = 0,
        nLastSlice = 0,
        nMaxSlice = 0,
        nWatchdogStrikes = 0
    }
    kernel.tPidMap[coProcess] = nPid
    kernel.tRings[nPid] = nRing

    -- Initialize IPC per-process state (signals, IRQL, process group)
    if g_oIpc then
        g_oIpc.InitProcessSignals(nPid)
    end

    -- Object Handle: Initialize per-process handle table
    if g_oObManager then
        g_oObManager.ObInitializeProcess(nPid)
        if nParentPid and nParentPid > 0 and kernel.tProcessTable[nParentPid] then
            g_oObManager.ObInheritHandles(nParentPid, nPid, sSynapseToken)
        end
    end
    kprint("debug", "Process ready", {
        pid = nPid,
        token = sSynapseToken:sub(1, 12) .. "..."
    })
    kprint("dev", "  PID " .. nPid .. " synapse token: " .. sSynapseToken:sub(1, 16) .. "...")

    return nPid
end

function kernel.create_thread(fFunc, nParentPid)
    local nPid = kernel.nNextPid
    kernel.nNextPid = kernel.nNextPid + 1

    local tParentProcess = kernel.tProcessTable[nParentPid]
    if not tParentProcess then
        return nil, "Parent died"
    end

    kprint("proc", "thread spawn", {
        tid = nPid,
        parent = nParentPid,
        ring = tParentProcess.ring
    })
    kprint("dev", "Spawning thread " .. nPid .. " for parent " .. nParentPid)

    local tSharedEnv = tParentProcess.env

    local coThread = coroutine.create(function()
        local bOk, sErr = pcall(fFunc)
        if not bOk then
            kprint("fail", "Thread " .. nPid .. " crashed: " .. tostring(sErr))
        end
        kernel.tProcessTable[nPid].status = "dead"
    end)

    local sSynapseToken = tParentProcess.synapseToken

    kernel.tProcessTable[nPid] = {
        co = coThread,
        status = "ready",
        ring = tParentProcess.ring,
        parent = nParentPid,
        env = tSharedEnv,
        fds = tParentProcess.fds,
        wait_queue = {},
        run_queue = {},
        uid = tParentProcess.uid,
        synapseToken = sSynapseToken,
        threads = {},
        is_thread = true,
        -- Preemptive scheduler stats
        nCpuTime = 0,
        nPreemptCount = 0,
        nLastSlice = 0,
        nMaxSlice = 0,
        nWatchdogStrikes = 0
    }

    kernel.tPidMap[coThread] = nPid
    kernel.tRings[nPid] = tParentProcess.ring

    if g_oObManager then
        g_oObManager.ObInitializeProcess(nPid)
        if nParentPid and nParentPid > 0 and kernel.tProcessTable[nParentPid] then
            g_oObManager.ObInheritHandles(nParentPid, nPid, sSynapseToken)
        end
    end

    -- Initialize IPC per-process state
    if g_oIpc then
        g_oIpc.InitProcessSignals(nPid)
    end

    table.insert(tParentProcess.threads, nPid)

    return nPid
end
-------------------------------------------------
-- SYSCALL DISPATCHER
-------------------------------------------------
kernel.syscalls = {}

-- =============================================
-- CROSS-BOUNDARY DATA SANITIZATION
-- =============================================

local SANITIZE_MAX_DEPTH = 16
local SANITIZE_MAX_ITEMS = 4096

local function deepSanitize(vValue, nDepth, tCounter)
    nDepth = nDepth or 0
    tCounter = tCounter or {
        n = 0
    }
    if nDepth > SANITIZE_MAX_DEPTH then
        kprint("sec", "Sanitize depth exceeded", {
            depth = nDepth
        })
        return nil
    end
    if tCounter.n > SANITIZE_MAX_ITEMS then
        kprint("sec", "Sanitize item limit", {
            items = tCounter.n
        })
        return nil
    end

    local sType = type(vValue)
    if sType == "string" or sType == "number" or sType == "boolean" or sType == "nil" then
        tCounter.n = tCounter.n + 1
        return vValue
    end
    if sType == "table" then
        tCounter.n = tCounter.n + 1
        local tClean = {}
        local key = nil
        while true do
            key = next(vValue, key)
            if key == nil then
                break
            end
            if tCounter.n > SANITIZE_MAX_ITEMS then
                break
            end
            local vRaw = rawget(vValue, key)
            local vCleanKey = deepSanitize(key, nDepth + 1, tCounter)
            local vCleanVal = deepSanitize(vRaw, nDepth + 1, tCounter)
            if vCleanKey ~= nil then
                tClean[vCleanKey] = vCleanVal
            end
        end
        return tClean
    end
    -- functions, userdata, threads: stripped
    return nil
end

function kernel.syscall_dispatch(sName, ...)
    local tProc = kernel.tProcessTable[nPid]
    if tProc then
        tProc._nSyscallCount = (tProc._nSyscallCount or 0) + 1
        local nNow = raw_computer.uptime()
        if not tProc._nSyscallWindowStart then
            tProc._nSyscallWindowStart = nNow
        end
        if nNow - tProc._nSyscallWindowStart > 1.0 then
            if tProc._nSyscallCount > 10000 and tProc.ring >= 3 then
                kprint("sec", "SYSCALL FLOOD: PID " .. nPid ..
                    " (" .. tProc._nSyscallCount .. "/sec) — killed")
                tProc.status = "dead"
                return nil, "Killed: syscall rate limit"
            end
            tProc._nSyscallCount = 0
            tProc._nSyscallWindowStart = nNow
        end
    end
    
    if type(sName) ~= "string" then
        kprint("sec", "Non-string syscall name rejected", {
            pid = g_nCurrentPid,
            type = type(sName)
        })
        return nil, "Syscall name must be a string"
    end

    local coCurrent = coroutine.running()
    local nPid = kernel.tPidMap[coCurrent]

    if not nPid then
        kernel.panic("Untracked coroutine tried to syscall: " .. sName)
    end

    g_nCurrentPid = nPid
    local nRing = kernel.tRings[nPid]

    -- PIPE FAST PATH: intercept vfs_read/vfs_write for kernel pipe handles
    -- This bypasses PM entirely, preventing PM from blocking on pipe I/O
    if g_oIpc and (sName == "vfs_read" or sName == "vfs_write") then
        local vHandle = select(1, ...)
        local bPcallOk, bIsPipe, r1, r2 = pcall(g_oIpc.TryPipeIo, nPid, sName, ...)
        if bPcallOk and bIsPipe then
            return r1, r2
        end
        if not bPcallOk then
            kprint("fail", "[IPC] Pipe fast-path error: " .. tostring(bIsPipe))
        end
    end

    -- Signal delivery point: deliver pending signals on every syscall entry
    if g_oIpc then
        local p = kernel.tProcessTable[nPid]
        if p and p.tPendingSignals and #p.tPendingSignals > 0 then
            local bKilled = g_oIpc.DeliverSignals(nPid)
            if bKilled then
                return nil, "Killed by signal"
            end
        end
    end

    -- Check for ring 1 overrides
    local nOverridePid = kernel.tSyscallOverrides[sName]
    if nOverridePid then
        local tProcess = kernel.tProcessTable[nPid]
        tProcess.status = "sleeping"
        tProcess.wait_reason = "syscall"

        local sSynapseToken = tProcess.synapseToken or "NO_TOKEN"

        -- SANITIZE when Ring >= 2.5 sends to Ring 1 PM
        local tArgs
        if kernel.tRings[nPid] >= 3 then
            tArgs = deepSanitize({...})
        else
            tArgs = {...}
        end

        if type(sName) ~= "string" then
            tProcess.status = "ready"
            return nil, "Syscall name must be a string"
        end

        local bIsOk, sErr = pcall(kernel.syscalls.signal_send, 0, nOverridePid, "syscall", {
            name = sName,
            args = tArgs,
            sender_pid = nPid,
            synapse_token = sSynapseToken
        })

        if not bIsOk then
            tProcess.status = "ready"
            return nil, "Syscall IPC failed: " .. tostring(sErr)
        end

        return coroutine.yield()
    end

    local tHandler = kernel.tSyscallTable[sName]
    if not tHandler then
        return nil, "Unknown syscall: " .. sName
    end

    -- RING CHECK
    local bIsAllowed = false
    for _, nAllowedRing in ipairs(tHandler.allowed_rings) do
        if nRing == nAllowedRing then
            bIsAllowed = true;
            break
        end
    end

    if not bIsAllowed then
        kprint("fail", "Ring violation: PID " .. nPid .. " (Ring " .. nRing .. ") tried to call " .. sName)
        kprint("sec", "RING VIOLATION", {
            pid = nPid,
            ring = nRing,
            syscall = sName
        })
        kernel.tProcessTable[nPid].status = "dead"
        return coroutine.yield()
    end

    local tReturns = {pcall(tHandler.func, nPid, ...)}
    local bIsOk = table.remove(tReturns, 1)
    if not bIsOk then
        return nil, tReturns[1]
    end
    return table.unpack(tReturns)
end

-------------------------------------------------
-- SYSCALL DEFINITIONS
-------------------------------------------------

-- Kernel (Ring 0)
kernel.tSyscallTable["kernel_panic"] = {
    func = function(nPid, sReason)
        kernel.panic(sReason)
    end,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["kernel_yield"] = {
    func = function()
        return coroutine.yield()
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["kernel_host_yield"] = {
    func = function()
        computer.pullSignal(0);
        return true
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["kernel_register_pipeline"] = {
    func = function(nPid)
        kernel.nPipelinePid = nPid
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["kernel_register_driver"] = {
    func = function(nPid, sComponentType, nHandlerPid)
        if not kernel.tDriverRegistry[sComponentType] then
            kernel.tDriverRegistry[sComponentType] = {}
        end
        table.insert(kernel.tDriverRegistry[sComponentType], nHandlerPid)
    end,
    allowed_rings = {1}
}

kernel.tSyscallTable["kernel_map_component"] = {
    func = function(nPid, sAddress, nDriverPid)
        kernel.tComponentDriverMap[sAddress] = nDriverPid
    end,
    allowed_rings = {1}
}

kernel.tSyscallTable["kernel_get_root_fs"] = {
    func = function(nPid)
        if kernel.tVfs.sRootUuid and kernel.tVfs.oRootFs then
            return kernel.tVfs.sRootUuid, kernel.tVfs.oRootFs
        else
            return nil, "Root FS not mounted in kernel"
        end
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["kernel_log"] = {
    func = function(nPid, sMessage)
        kprint("info", tostring(sMessage));
        return true
    end,
    allowed_rings = {0, 1, 2, 3}
}

kernel.tSyscallTable["kernel_get_boot_log"] = {
    func = function(nPid)
        local sLog = table.concat(kernel.tBootLog, "\n")
        kernel.tBootLog = {}
        return sLog
    end,
    allowed_rings = {1, 2}
}

kernel.tSyscallTable["kernel_set_log_mode"] = {
    func = function(nPid, bEnable)
        g_bLogToScreen = bEnable;
        return true
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["driver_load"] = {
    func = function(nPid, sPath)
        return nil, "Syscall not handled by PM"
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["syscall_override"] = {
    func = function(nPid, sSyscallName)
        kernel.tSyscallOverrides[sSyscallName] = nPid;
        return true
    end,
    allowed_rings = {1}
}

kernel.tSyscallTable["patchguard_arm"] = {
    func = function(nPid)
        if not g_oPatchGuard then return false, "PatchGuard not loaded" end
        -- Re-snapshot to capture current state (overrides registered by now)
        g_oPatchGuard.TakeSnapshot()
        return g_oPatchGuard.Arm()
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["patchguard_status"] = {
    func = function(nPid)
        if not g_oPatchGuard then
            return { bArmed = false, bAvailable = false }
        end
        local tStats = g_oPatchGuard.GetStats()
        tStats.bAvailable = true
        return tStats
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["patchguard_check"] = {
    func = function(nPid)
        if not g_oPatchGuard then return true end
        return g_oPatchGuard.Check()
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["critical_file_modified"] = {
    func = function(nPid, sPath, nWriterPid)
        kprint("sec", string.format(
            "CRITICAL FILE MODIFIED: %s by PID %d (Ring %s)",
            sPath, nWriterPid,
            tostring(kernel.tRings[nWriterPid] or "?")))

        -- Re-hash just THIS file and compare
        if g_oPatchGuard and g_fPgSha256 then
            local sContent = primitive_load(sPath)
            if sContent then
                local sHash = hex(g_fPgSha256(sContent))
                local sExpected = g_tFileHashSnap[sPath]
                if sExpected and sHash ~= sExpected then
                    kprint("sec", string.format(
                        "HASH MISMATCH: %s (boot=%s now=%s)",
                        sPath, sExpected:sub(1,16), sHash:sub(1,16)))
                    -- React: this is a real-time detection
                    -- You could panic, kill the writer, or log for audit
                end
            end
        end
        return true
    end,
    allowed_rings = {0, 1}
}

-- Process Management
kernel.tSyscallTable["process_spawn"] = {
    func = function(nPid, sPath, nRing, tPassEnv)
        local nParentRing = kernel.tRings[nPid]
        if nRing < nParentRing then
            return nil, "Permission denied: cannot spawn higher-privilege process"
        end
        local nNewPid, sErr = kernel.create_process(sPath, nRing, nPid, tPassEnv)
        if not nNewPid then
            return nil, sErr
        end
        return nNewPid
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_yield"] = {
    func = function(nPid)
        kernel.tProcessTable[nPid].status = "ready"
        coroutine.yield()
        return true
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_thread"] = {
    func = function(nPid, fFunc)
        if type(fFunc) ~= "function" then
            return nil, "Argument must be a function"
        end
        local nThreadPid, sErr = kernel.create_thread(fFunc, nPid)
        return nThreadPid, sErr
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_wait"] = {
    func = function(nPid, nTargetPid)
        if not kernel.tProcessTable[nTargetPid] then
            return nil, "Invalid PID"
        end
        if kernel.tProcessTable[nTargetPid].status == "dead" then
            return true
        end
        table.insert(kernel.tProcessTable[nTargetPid].wait_queue, nPid)
        kernel.tProcessTable[nPid].status = "sleeping"
        kernel.tProcessTable[nPid].wait_reason = "wait_pid"
        return coroutine.yield()
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_kill"] = {
    func = function(nPid, nTargetPid, nSignal)
        local tTarget = kernel.tProcessTable[nTargetPid]
        if not tTarget then
            return nil, "No such process"
        end

        local nCallerRing = kernel.tRings[nPid] or 3
        local nTargetRing = kernel.tRings[nTargetPid] or 3

        -- RULE 1: KERNEL PROTECTION — PID 0-1 only from Ring 0
        if nTargetPid <= 1 and nCallerRing > 0 then
            kprint("sec", "BLOCKED: PID " .. nPid .. " (Ring " .. nCallerRing ..
                   ") tried to kill kernel PID " .. nTargetPid)
            return nil, "Permission denied: cannot kill kernel process"
        end

        -- RULE 2: RING HIERARCHY — cannot kill more-privileged process
        if nCallerRing > nTargetRing then
            kprint("sec", "BLOCKED: PID " .. nPid .. " (Ring " .. nCallerRing ..
                   ") tried to kill PID " .. nTargetPid .. " (Ring " .. nTargetRing .. ")")
            return nil, "Permission denied: cannot kill higher-privilege process"
        end

        -- RULE 3: ANCESTOR PROTECTION
        -- A process cannot kill any of its own ancestors (parent,
        -- grandparent, etc).  Killing an ancestor destroys your own
        -- session, which is never a legitimate operation.
        -- This also protects init from being killed by its children.
        local nWalk = nPid
        local nMaxDepth = 32  -- prevent infinite loops
        local nDepth = 0
        while nWalk and nDepth < nMaxDepth do
            local tWalk = kernel.tProcessTable[nWalk]
            if not tWalk then break end
            local nParent = tWalk.parent
            if nParent == nTargetPid then
                kprint("sec", "BLOCKED: PID " .. nPid ..
                       " tried to kill ancestor PID " .. nTargetPid ..
                       " (depth=" .. (nDepth + 1) .. ")")
                return nil, "Permission denied: cannot kill ancestor process"
            end
            if nParent == nWalk then break end  -- root of tree
            nWalk = nParent
            nDepth = nDepth + 1
        end

        -- RULE 4: OWNERSHIP — Ring 3 non-root must own the target
        if nCallerRing >= 3 then
            local nCallerUid = kernel.tProcessTable[nPid]
                and kernel.tProcessTable[nPid].uid or 1000
            if nCallerUid ~= 0 then
                if tTarget.parent ~= nPid and nTargetPid ~= nPid then
                    return nil, "Permission denied: not owner"
                end
            end
        end

        if g_oIpc then
            nSignal = nSignal or g_oIpc.SIGTERM
            return g_oIpc.SignalSend(nTargetPid, nSignal)
        end
        tTarget.status = "dead"
        for _, nTid in ipairs(tTarget.threads or {}) do
            if kernel.tProcessTable[nTid] then
                kernel.tProcessTable[nTid].status = "dead"
            end
        end
        kprint("info", "Process " .. nTargetPid .. " killed by " .. nPid)
        return true
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_status"] = {
    func = function(nPid, nTargetPid)
        local tTarget = kernel.tProcessTable[nTargetPid or nPid]
        if tTarget then
            return tTarget.status
        else
            return nil
        end
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_list"] = {
    func = function(nPid)
        local tResult = {}
        for nProcPid, tProc in pairs(kernel.tProcessTable) do
            if tProc.status ~= "dead" then
                local sImage = "?"
                if tProc.env and tProc.env.env and tProc.env.env.arg then
                    sImage = tProc.env.env.arg[0] or "?"
                end
                table.insert(tResult, {
                    pid = nProcPid,
                    parent = tProc.parent or 0,
                    ring = tProc.ring or -1,
                    status = tProc.status or "?",
                    uid = tProc.uid or -1,
                    image = sImage
                })
            end
        end
        table.sort(tResult, function(a, b)
            return a.pid < b.pid
        end)
        return tResult
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_list_threads"] = {
    func = function(nPid)
        local tProc = kernel.tProcessTable[nPid]
        if not tProc then
            return {}
        end
        local tAlive = {}
        for _, nTid in ipairs(tProc.threads or {}) do
            if kernel.tProcessTable[nTid] and kernel.tProcessTable[nTid].status ~= "dead" then
                table.insert(tAlive, nTid)
            end
        end
        tProc.threads = tAlive
        return tAlive
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_elevate"] = {
    func = function(nPid, nNewRing)
        if kernel.tRings[nPid] == 3 and nNewRing == 2.5 then
            kernel.tRings[nPid] = 2.5
            kernel.tProcessTable[nPid].ring = 2.5
            kernel.tProcessTable[nPid].env = kernel.create_sandbox(nPid, 2.5)
            -- sMLTR: Rotate synapse token on elevation for security
            kernel.tProcessTable[nPid].synapseToken = fGenerateSynapseToken()
            return true
        end
        return nil, "Permission denied"
    end,
    allowed_rings = {3}
}

kernel.tSyscallTable["process_get_ring"] = {
    func = function(nPid)
        return kernel.tRings[nPid]
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_get_pid"] = {
    func = function(nPid)
        return nPid
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_get_uid"] = {
    func = function(nPid, nTargetPid)
        local tP = kernel.tProcessTable[nTargetPid or nPid]
        if tP then
            return tP.uid
        else
            return nil
        end
    end,
    allowed_rings = {0, 1}
}

-- ==========================================
-- OBJECT HANDLE SYSCALLS (Ring 1 used by PM)
-- ==========================================

kernel.tSyscallTable["ob_create_object"] = {
    func = function(nPid, sType, tBody)
        if not g_oObManager then
            return nil, "ObManager not loaded"
        end
        return g_oObManager.ObCreateObject(sType, tBody)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_reference_object"] = {
    func = function(nPid, pObj)
        if g_oObManager and pObj then
            g_oObManager.ObReferenceObject(pObj)
        end
        return true
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_dereference_object"] = {
    func = function(nPid, pObj)
        if g_oObManager and pObj then
            g_oObManager.ObDereferenceObject(pObj)
        end
        return true
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_insert_object"] = {
    func = function(nPid, pObj, sPath)
        if not g_oObManager then
            return nil
        end
        return g_oObManager.ObInsertObject(pObj, sPath)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_lookup_object"] = {
    func = function(nPid, sPath)
        if not g_oObManager then
            return nil
        end
        return g_oObManager.ObLookupObject(sPath)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_delete_object"] = {
    func = function(nPid, sPath)
        if not g_oObManager then
            return nil
        end
        return g_oObManager.ObDeleteObject(sPath)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_create_symlink"] = {
    func = function(nPid, sLink, sTarget)
        if not g_oObManager then
            return nil
        end
        return g_oObManager.ObCreateSymbolicLink(sLink, sTarget)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_delete_symlink"] = {
    func = function(nPid, sPath)
        if not g_oObManager then
            return nil
        end
        return g_oObManager.ObDeleteSymbolicLink(sPath)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_create_handle"] = {
    func = function(nPid, nTargetPid, pObj, nAccess, sSynapseToken, bInheritable)
        if not g_oObManager then
            return nil
        end
        return g_oObManager.ObCreateHandle(nTargetPid, pObj, nAccess, sSynapseToken, bInheritable)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_close_handle"] = {
    func = function(nPid, nTargetPid, vHandle)
        if not g_oObManager then
            return false
        end
        return g_oObManager.ObCloseHandle(nTargetPid, vHandle)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_reference_by_handle"] = {
    func = function(nPid, nTargetPid, vHandle, nDesiredAccess, sSynapseToken)
        if not g_oObManager then
            return nil
        end
        return g_oObManager.ObReferenceObjectByHandle(nTargetPid, vHandle, nDesiredAccess, sSynapseToken)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_set_standard_handle"] = {
    func = function(nPid, nTargetPid, nIndex, sToken)
        if not g_oObManager then
            return false
        end
        -- Security: Ring 3+ can only modify their OWN standard handles
        if kernel.tRings[nPid] >= 3 and nTargetPid ~= nPid then
            return nil, "Permission denied: can only set own standard handles"
        end
        return g_oObManager.ObSetStandardHandle(nTargetPid, nIndex, sToken)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["ob_get_standard_handle"] = {
    func = function(nPid, nTargetPid, nIndex)
        if not g_oObManager then
            return nil
        end
        -- Security: Ring 3+ can only query their OWN standard handles
        if kernel.tRings[nPid] >= 3 and nTargetPid ~= nPid then
            return nil, "Permission denied"
        end
        return g_oObManager.ObGetStandardHandle(nTargetPid, nIndex)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["ob_init_process"] = {
    func = function(nPid, nTargetPid)
        if not g_oObManager then
            return false
        end
        g_oObManager.ObInitializeProcess(nTargetPid)
        return true
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_destroy_process"] = {
    func = function(nPid, nTargetPid)
        if not g_oObManager then
            return false
        end
        g_oObManager.ObObDestroyProcess(nTargetPid)
        return true
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_inherit_handles"] = {
    func = function(nPid, nParentPid, nChildPid, sChildToken)
        if not g_oObManager then
            return false
        end
        g_oObManager.ObInheritHandles(nParentPid, nChildPid, sChildToken)
        return true
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_duplicate_handle"] = {
    func = function(nPid, nSrcPid, sSrcToken, nDstPid, nAccess, sSynToken)
        if not g_oObManager then
            return nil
        end
        return g_oObManager.ObDuplicateHandle(nSrcPid, sSrcToken, nDstPid, nAccess, sSynToken)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_list_handles"] = {
    func = function(nPid, nTargetPid)
        if not g_oObManager then
            return {}
        end
        return g_oObManager.ObListHandles(nTargetPid or nPid)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_dump_directory"] = {
    func = function(nPid)
        if not g_oObManager then
            return {}
        end
        return g_oObManager.ObDumpDirectory()
    end,
    allowed_rings = {0, 1}
}

-- ==========================================
-- REGISTRY SYSCALLS (@VT)
-- ==========================================

kernel.tSyscallTable["reg_create_key"] = {
    func = function(nPid, sPath)
        if not g_oRegistry then
            return false, "Registry not loaded"
        end
        return g_oRegistry.CreateKey(sPath)
    end,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["reg_delete_key"] = {
    func = function(nPid, sPath)
        if not g_oRegistry then
            return false
        end
        -- protect root hives
        if sPath == "@VT" or sPath == "@VT\\DEV" or sPath == "@VT\\DRV" or sPath == "@VT\\SYS" then
            return false, "Cannot delete root hive"
        end
        return g_oRegistry.DeleteKey(sPath)
    end,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["reg_key_exists"] = {
    func = function(nPid, sPath)
        if not g_oRegistry then
            return false
        end
        return g_oRegistry.KeyExists(sPath)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["reg_set_value"] = {
    func = function(nPid, sPath, sName, vValue, sType)
        if not g_oRegistry then
            return false
        end
        return g_oRegistry.SetValue(sPath, sName, vValue, sType)
    end,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["reg_get_value"] = {
    func = function(nPid, sPath, sName)
        if not g_oRegistry then
            return nil
        end
        return g_oRegistry.GetValue(sPath, sName)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["reg_delete_value"] = {
    func = function(nPid, sPath, sName)
        if not g_oRegistry then
            return false
        end
        return g_oRegistry.DeleteValue(sPath, sName)
    end,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["reg_enum_keys"] = {
    func = function(nPid, sPath)
        if not g_oRegistry then
            return {}
        end
        return g_oRegistry.EnumKeys(sPath)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["reg_enum_values"] = {
    func = function(nPid, sPath)
        if not g_oRegistry then
            return {}
        end
        return g_oRegistry.EnumValues(sPath)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["reg_query_info"] = {
    func = function(nPid, sPath)
        if not g_oRegistry then
            return nil
        end
        return g_oRegistry.QueryInfo(sPath)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["reg_dump_tree"] = {
    func = function(nPid, sPath, nMaxDepth)
        if not g_oRegistry then
            return {}
        end
        return g_oRegistry.DumpTree(sPath, nMaxDepth)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["reg_alloc_device_id"] = {
    func = function(nPid, sClass)
        if not g_oRegistry then
            return nil
        end
        return g_oRegistry.AllocateDeviceId(sClass)
    end,
    allowed_rings = {0, 1, 2}
}

-- ==========================================
-- sMLTR SYSCALLS
-- ==========================================

-- Get own synapse token
kernel.tSyscallTable["synapse_get_token"] = {
    func = function(nPid)
        local tProc = kernel.tProcessTable[nPid]
        return tProc and tProc.synapseToken or nil
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Validate a target process's synapse token
kernel.tSyscallTable["synapse_validate"] = {
    func = function(nPid, nTargetPid, sToken)
        local tTarget = kernel.tProcessTable[nTargetPid]
        if tTarget and tTarget.synapseToken == sToken then
            return true
        end
        return false
    end,
    allowed_rings = {0, 1, 2}
}

-- Rotate a process's synapse token (security measure)
-- After rotation, all old handles bound to the old token become invalid.
kernel.tSyscallTable["synapse_rotate"] = {
    func = function(nPid, nTargetPid)
        local nTarget = nTargetPid or nPid
        local tTarget = kernel.tProcessTable[nTarget]
        if not tTarget then
            return nil, "No such process"
        end
        local sOldToken = tTarget.synapseToken
        tTarget.synapseToken = fGenerateSynapseToken()
        kprint("dev", "sMLTR: Rotated token for PID " .. nTarget .. " (old: " .. sOldToken:sub(1, 12) .. "...)")
        return tTarget.synapseToken
    end,
    allowed_rings = {0, 1}
}

-- ==========================================
-- IPC SYSCALLS
-- ==========================================

-- IRQL
kernel.tSyscallTable["ke_raise_irql"] = {
    func = function(nPid, nLevel)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeRaiseIrql(nPid, nLevel)
    end,
    allowed_rings = {0, 1, 2}
}
kernel.tSyscallTable["ke_lower_irql"] = {
    func = function(nPid, nLevel)
        if not g_oIpc then
            return
        end
        g_oIpc.KeLowerIrql(nPid, nLevel)
    end,
    allowed_rings = {0, 1, 2}
}
kernel.tSyscallTable["ke_get_irql"] = {
    func = function(nPid)
        if not g_oIpc then
            return 0
        end
        return g_oIpc.KeGetCurrentIrql(nPid)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Events
kernel.tSyscallTable["ke_create_event"] = {
    func = function(nPid, bManual, bInit)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeCreateEvent(nPid, bManual, bInit)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_set_event"] = {
    func = function(nPid, sH)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeSetEvent(nPid, sH)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_reset_event"] = {
    func = function(nPid, sH)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeResetEvent(nPid, sH)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_pulse_event"] = {
    func = function(nPid, sH)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KePulseEvent(nPid, sH)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Mutexes
kernel.tSyscallTable["ke_create_mutex"] = {
    func = function(nPid, bOwned)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeCreateMutex(nPid, bOwned)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_release_mutex"] = {
    func = function(nPid, sH)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeReleaseMutex(nPid, sH)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Semaphores
kernel.tSyscallTable["ke_create_semaphore"] = {
    func = function(nPid, nInit, nMax)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeCreateSemaphore(nPid, nInit, nMax)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_release_semaphore"] = {
    func = function(nPid, sH, nCount)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeReleaseSemaphore(nPid, sH, nCount)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Timers
kernel.tSyscallTable["ke_create_timer"] = {
    func = function(nPid)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeCreateTimer(nPid)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_set_timer"] = {
    func = function(nPid, sH, nDelay, nPeriod)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeSetTimer(nPid, sH, nDelay, nPeriod)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_cancel_timer"] = {
    func = function(nPid, sH)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeCancelTimer(nPid, sH)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Pipes
kernel.tSyscallTable["ke_create_pipe"] = {
    func = function(nPid, nBuf)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeCreatePipe(nPid, nBuf)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_create_named_pipe"] = {
    func = function(nPid, sName, nBuf)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeCreateNamedPipe(nPid, sName, nBuf)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_connect_named_pipe"] = {
    func = function(nPid, sName)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeConnectNamedPipe(nPid, sName)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_pipe_write"] = {
    func = function(nPid, sH, sData)
        if not g_oIpc then
            return nil
        end
        local pH = g_oObManager.ObReferenceObjectByHandle(nPid, sH, 0x0002, kernel.tProcessTable[nPid].synapseToken)
        if not pH or not pH.pBody then
            return nil, "Invalid pipe handle"
        end
        return g_oIpc.PipeWrite(nPid, pH.pBody, sData)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_pipe_read"] = {
    func = function(nPid, sH, nCount)
        if not g_oIpc then
            return nil
        end
        local pH = g_oObManager.ObReferenceObjectByHandle(nPid, sH, 0x0001, kernel.tProcessTable[nPid].synapseToken)
        if not pH or not pH.pBody then
            return nil, "Invalid pipe handle"
        end
        return g_oIpc.PipeRead(nPid, pH.pBody, nCount)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_pipe_close"] = {
    func = function(nPid, sH, bIsWrite)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.PipeClose(nPid, sH, bIsWrite)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Wait
kernel.tSyscallTable["ke_wait_single"] = {
    func = function(nPid, sH, nTimeout)
        if not g_oIpc then
            return -1
        end
        return g_oIpc.KeWaitSingle(nPid, sH, nTimeout)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_wait_multiple"] = {
    func = function(nPid, tHandles, bAll, nTimeout)
        if not g_oIpc then
            return -1
        end
        return g_oIpc.KeWaitMultiple(nPid, tHandles, bAll, nTimeout)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Shared Memory
kernel.tSyscallTable["ke_create_section"] = {
    func = function(nPid, sName, nSize)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeCreateSection(nPid, sName, nSize)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_open_section"] = {
    func = function(nPid, sName)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeOpenSection(nPid, sName)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_map_section"] = {
    func = function(nPid, sH)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeMapSection(nPid, sH)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Message Queues
kernel.tSyscallTable["ke_create_mqueue"] = {
    func = function(nPid, sName, nMax, nSize)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeCreateMqueue(nPid, sName, nMax, nSize)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_open_mqueue"] = {
    func = function(nPid, sName)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeOpenMqueue(nPid, sName)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_mq_send"] = {
    func = function(nPid, sH, sMsg, nPri)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeMqSend(nPid, sH, sMsg, nPri)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_mq_receive"] = {
    func = function(nPid, sH, nTimeout)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.KeMqReceive(nPid, sH, nTimeout)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Signals
kernel.tSyscallTable["ke_signal_send"] = {
    func = function(nPid, nTarget, nSig)
        if not g_oIpc then return nil end

        local nCallerRing = kernel.tRings[nPid] or 3
        local tTarget = kernel.tProcessTable[nTarget]
        if not tTarget then return nil, "No such process" end

        local nTargetRing = kernel.tRings[nTarget] or 3

        -- RULE 1: KERNEL PROTECTION
        -- PID 0-1 cannot be signalled from anyone except Ring 0.
        if nTarget <= 1 and nCallerRing > 0 then
            kprint("sec", "BLOCKED: PID " .. nPid .. " (Ring " .. nCallerRing ..
                   ") tried to signal kernel PID " .. nTarget ..
                   " (sig=" .. tostring(nSig) .. ")")
            return nil, "Permission denied: cannot signal kernel process"
        end

        -- RULE 2: RING HIERARCHY
        -- A process cannot send signals to a process running at a
        -- MORE privileged ring.  Ring 3 cannot signal Ring 2, Ring 1, etc.
        -- This prevents root-at-Ring-3 from killing system services.
        if nCallerRing > nTargetRing then
            kprint("sec", "BLOCKED: PID " .. nPid .. " (Ring " .. nCallerRing ..
                   ") tried to signal PID " .. nTarget .. " (Ring " .. nTargetRing ..
                   ") — ring hierarchy violation (sig=" .. tostring(nSig) .. ")")
            return nil, "Permission denied: cannot signal higher-privilege process"
        end

        -- RULE 3: ANCESTOR PROTECTION
        -- Cannot signal any ancestor in the process tree.

        local nWalk = nPid
        local nMaxDepth = 32
        local nDepth = 0
        while nWalk and nDepth < nMaxDepth do
            local tWalk = kernel.tProcessTable[nWalk]
            if not tWalk then break end
            local nParent = tWalk.parent
            if nParent == nTarget then
                kprint("sec", "BLOCKED: PID " .. nPid ..
                       " tried to signal ancestor PID " .. nTarget ..
                       " (depth=" .. (nDepth + 1) .. ", sig=" .. tostring(nSig) .. ")")
                return nil, "Permission denied: cannot signal ancestor process"
            end
            if nParent == nWalk then break end
            nWalk = nParent
            nDepth = nDepth + 1
        end

        -- RULE 4: OWNERSHIP (Ring 3 non-root)
        -- Non-root Ring 3 can only signal own children or self.
        if nCallerRing >= 3 then
            local nCallerUid = kernel.tProcessTable[nPid]
                and kernel.tProcessTable[nPid].uid or 1000

            if nCallerUid ~= 0 then
                if tTarget.parent ~= nPid and nTarget ~= nPid then
                    kprint("sec", "BLOCKED: PID " .. nPid .. " (UID " .. nCallerUid ..
                           ") tried to signal PID " .. nTarget .. " (not owned)")
                    return nil, "Permission denied: not owner"
                end
            end
        end

        -- RULE 4: Root at Ring 3 can signal same-ring or less-privileged.
        -- (Already passed rules 1-3 if we get here.)
        return g_oIpc.SignalSend(nTarget, nSig)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["ke_signal_handler"] = {
    func = function(nPid, nSig, fHandler)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.SignalSetHandler(nPid, nSig, fHandler)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_signal_mask"] = {
    func = function(nPid, tMask)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.SignalSetMask(nPid, tMask)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["ke_signal_group"] = {
    func = function(nPid, nPgid, nSig)
        if not g_oIpc then return nil end

        local nCallerRing = kernel.tRings[nPid] or 3

        -- Filter: iterate the group and skip any process more privileged
        -- than the caller.  This prevents a Ring 3 group-kill from
        -- hitting Ring 1-2 services that share a PGID.
        local nSent, nBlocked = 0, 0
        for nTargetPid, tProc in pairs(kernel.tProcessTable) do
            if tProc.pgid == nPgid or (nPgid == 0 and tProc.parent == nPid) then
                local nTargetRing = kernel.tRings[nTargetPid] or 3

                if nTargetPid <= 1 and nCallerRing > 0 then
                    nBlocked = nBlocked + 1
                elseif nCallerRing > nTargetRing then
                    nBlocked = nBlocked + 1
                else
                    g_oIpc.SignalSend(nTargetPid, nSig)
                    nSent = nSent + 1
                end
            end
        end

        if nBlocked > 0 then
            kprint("sec", "PID " .. nPid .. " group signal: " .. nSent ..
                   " delivered, " .. nBlocked .. " blocked (ring hierarchy)")
        end
        return nSent > 0
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["ke_setpgid"] = {
    func = function(nPid, nTarget, nPgid)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.SetProcessGroup(nTarget or nPid, nPgid)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_getpgid"] = {
    func = function(nPid)
        local p = kernel.tProcessTable[nPid]
        return p and (p.nPgid or nPid) or nil
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_ipc_stats"] = {
    func = function(nPid)
        if not g_oIpc then
            return nil
        end
        return g_oIpc.GetStats()
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- ==========================================
-- SCHEDULER DIAGNOSTICS
-- ==========================================

kernel.tSyscallTable["sched_get_stats"] = {
    func = function(nPid)
        local tResult = {
            nTotalResumes = g_tSchedStats.nTotalResumes,
            nPreemptions = g_tSchedStats.nPreemptions,
            nWatchdogWarnings = g_tSchedStats.nWatchdogWarnings,
            nWatchdogKills = g_tSchedStats.nWatchdogKills,
            nMaxSliceMs = g_tSchedStats.nMaxSliceMs
        }
        if g_oPreempt then
            local tP = g_oPreempt.getStats()
            tResult.nInstrumentedFiles = tP.nTotalInstrumented
            tResult.nInjectedCheckpoints = tP.nTotalInjections
            tResult.nQuantumMs = tP.nQuantumMs
            tResult.nCheckInterval = tP.nCheckInterval
        end
        return tResult
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["mem_info"] = {
    func = function(nPid)
        local nTotal = computer.totalMemory()
        local nFree = computer.freeMemory()
        local nUsed = nTotal - nFree

        -- Count per-process overhead estimates
        local tProcs = {}
        for nProcPid, tProc in pairs(kernel.tProcessTable) do
            if tProc.status ~= "dead" then
                local nModules = 0
                if tProc._moduleCache then
                    for _ in pairs(tProc._moduleCache) do
                        nModules = nModules + 1
                    end
                end
                local nHandles = 0
                if g_oObManager then
                    local tH = g_oObManager.ObListHandles(nProcPid)
                    if tH then
                        nHandles = #tH
                    end
                end
                local nSignalQ = 0
                if tProc.signal_queue then
                    nSignalQ = #tProc.signal_queue
                end

                table.insert(tProcs, {
                    pid = nProcPid,
                    ring = tProc.ring or -1,
                    status = tProc.status or "?",
                    modules = nModules,
                    handles = nHandles,
                    signals = nSignalQ,
                    threads = tProc.threads and #tProc.threads or 0,
                    cpu = tProc.nCpuTime or 0
                })
            end
        end
        table.sort(tProcs, function(a, b)
            return a.pid < b.pid
        end)

        -- Global overhead estimates
        local nDmesgEntries = #g_tDmesg
        local nBootLogEntries = #kernel.tBootLog
        local nLoadedModules = 0
        for _ in pairs(kernel.tLoadedModules) do
            nLoadedModules = nLoadedModules + 1
        end

        return {
            nTotal = nTotal,
            nFree = nFree,
            nUsed = nUsed,
            nUsedPct = math.floor((nUsed / nTotal) * 100),
            nProcesses = #tProcs,
            nDmesgEntries = nDmesgEntries,
            nBootLogPending = nBootLogEntries,
            nGlobalModules = nLoadedModules,
            tProcesses = tProcs
        }
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["dmesg_read"] = {
    func = function(nPid, nLastSeq, nMaxEntries, sLevelFilter)
        nLastSeq = nLastSeq or 0
        nMaxEntries = nMaxEntries or 200
        if nMaxEntries > 500 then
            nMaxEntries = 500
        end

        local tResult = {}
        local nCount = 0
        for i = #g_tDmesg, 1, -1 do
            local tEntry = g_tDmesg[i]
            if tEntry.seq <= nLastSeq then
                break
            end
            if sLevelFilter and tEntry.level ~= sLevelFilter then
                goto dmesg_next
            end
            table.insert(tResult, 1, {
                seq = tEntry.seq,
                time = tEntry.time,
                level = tEntry.level,
                msg = tEntry.msg,
                pid = tEntry.pid,
                src = tEntry.src
            })
            nCount = nCount + 1
            if nCount >= nMaxEntries then
                break
            end
            ::dmesg_next::
        end
        return tResult
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["dmesg_clear"] = {
    func = function(nPid)
        local nCleared = #g_tDmesg
        g_tDmesg = {}
        kprint("info", "dmesg cleared", {
            by = nPid,
            entries = nCleared
        })
        return nCleared
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["dmesg_stats"] = {
    func = function(nPid)
        local tCounts = {}
        for _, tEntry in ipairs(g_tDmesg) do
            tCounts[tEntry.level] = (tCounts[tEntry.level] or 0) + 1
        end
        return {
            nTotal = #g_tDmesg,
            nMaxSize = DMESG_MAX_ENTRIES,
            nFirstSeq = g_tDmesg[1] and g_tDmesg[1].seq or 0,
            nLastSeq = g_nDmesgSeq,
            tLevelCounts = tCounts
        }
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_cpu_stats"] = {
    func = function(nPid, nTargetPid)
        local tTarget = kernel.tProcessTable[nTargetPid or nPid]
        if not tTarget then
            return nil
        end
        return {
            nCpuTime = tTarget.nCpuTime or 0,
            nPreemptCount = tTarget.nPreemptCount or 0,
            nLastSlice = tTarget.nLastSlice or 0,
            nMaxSlice = tTarget.nMaxSlice or 0,
            nWatchdogStrikes = tTarget.nWatchdogStrikes or 0
        }
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Raw Component (Privileged)
kernel.tSyscallTable["raw_component_list"] = {
    func = function(nPid, sFilter)
        local bIsOk, tList = pcall(function()
            local tTempList = {}
            for sAddr, sCtype in raw_component.list(sFilter) do
                tTempList[sAddr] = sCtype
            end
            return tTempList
        end)
        if bIsOk then
            return true, tList
        else
            return false, tList
        end
    end,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["raw_component_invoke"] = {
    func = function(nPid, sAddress, sMethod, ...)
        local oProxy = raw_component.proxy(sAddress)
        if not oProxy then
            return nil, "Invalid component"
        end
        return pcall(oProxy[sMethod], ...)
    end,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["raw_component_proxy"] = {
    func = function(nPid, sAddress)
        local bIsOk, oProxy = pcall(raw_component.proxy, sAddress)
        if bIsOk then
            return oProxy
        else
            return nil, "Invalid component address"
        end
    end,
    allowed_rings = {0, 1, 2}
}

-- IPC
kernel.syscalls.signal_send = function(nPid, nTargetPid, ...)
    local tTarget = kernel.tProcessTable[nTargetPid]
    if not tTarget then
        return nil, "Invalid PID"
    end

    local nSenderRing = kernel.tRings[nPid] or 3
    local nTargetRing = kernel.tRings[nTargetPid] or 3

    -- ONLY sanitize Ring 3+ user code sending to lower rings.
    -- Ring 0-2 are trusted system code that passes functions
    -- (driver dispatch tables, callbacks, etc.)
    local tSignal
    if nSenderRing >= 3 and nTargetRing < 3 then
        tSignal = {nPid}
        local tRawArgs = {...}
        for i = 1, #tRawArgs do
            tSignal[i + 1] = deepSanitize(tRawArgs[i])
        end
    else
        tSignal = {nPid, ...}
    end

    if tTarget.status == "sleeping" and (tTarget.wait_reason == "signal" or tTarget.wait_reason == "syscall") then
        tTarget.status = "ready"
        if tTarget.wait_reason == "syscall" then
            tTarget.resume_args = {tSignal[3], table.unpack(tSignal, 4)}
        else
            tTarget.resume_args = tSignal
        end
    else
        if not tTarget.signal_queue then
            tTarget.signal_queue = {}
        end
        table.insert(tTarget.signal_queue, tSignal)
    end

    return true
end

kernel.tSyscallTable["signal_send"] = {
    func = kernel.syscalls.signal_send,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["signal_pull"] = {
    func = function(nPid, nTimeout)
        local tProcess = kernel.tProcessTable[nPid]
        if tProcess.signal_queue and #tProcess.signal_queue > 0 then
            return true, table.unpack(table.remove(tProcess.signal_queue, 1))
        end
        tProcess.status = "sleeping"
        tProcess.wait_reason = "signal"
        return coroutine.yield()
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- VFS (placeholders, overridden by PM)
kernel.syscalls.vfs_read_file = function(nPid, sPath)
    return primitive_load(sPath)
end

kernel.tSyscallTable["vfs_read_file"] = {
    func = kernel.syscalls.vfs_read_file,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["vfs_open"] = {
    func = function(nPid, sPath, sMode)
        return pcall(g_oPrimitiveFs.open, sPath, sMode)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_read"] = {
    func = function(nPid, hHandle, nCount)
        return pcall(g_oPrimitiveFs.read, hHandle, nCount or math.huge)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_write"] = {
    func = function(nPid, hHandle, sData)
        return pcall(g_oPrimitiveFs.write, hHandle, sData)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_close"] = {
    func = function(nPid, hHandle)
        return pcall(g_oPrimitiveFs.close, hHandle)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_chmod"] = {
    func = function()
        return nil, "Not implemented in kernel"
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_device_control"] = {
    func = function()
        return nil, "Not implemented in kernel"
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_list"] = {
    func = function(nPid, sPath)
        local bOk, tListOrErr = pcall(g_oPrimitiveFs.list, sPath)
        if bOk then
            return true, tListOrErr
        else
            return false, tListOrErr
        end
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["vfs_delete"] = {
    func = function(nPid, sPath)
        return pcall(g_oPrimitiveFs.remove, sPath)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["vfs_mkdir"] = {
    func = function(nPid, sPath)
        return pcall(g_oPrimitiveFs.makeDirectory, sPath)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Computer
kernel.tSyscallTable["computer_shutdown"] = {
    func = function()
        if g_oAxfsVol then
            g_oAxfsVol:flush()
        end
        raw_computer.shutdown()
    end,
    allowed_rings = {0, 1, 2, 2.5}
}
kernel.tSyscallTable["computer_reboot"] = {
    func = function()
        if g_oAxfsVol then
            g_oAxfsVol:flush()
        end
        raw_computer.shutdown(true)
    end,
    allowed_rings = {0, 1, 2, 2.5}
}

-- ==========================================
-- EEPROM DATA ACCESS (for secureboot attestation)
-- ==========================================

kernel.tSyscallTable["eeprom_get_data"] = {
    func = function(nPid)
        local ep
        for addr in raw_component.list("eeprom") do
            ep = raw_component.proxy(addr); break
        end
        if not ep then return nil, "No EEPROM" end
        return ep.getData()
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["eeprom_set_data"] = {
    func = function(nPid, sData)
        local tProc = kernel.tProcessTable[nPid]
        if not tProc or (tProc.uid or 1000) ~= 0 then
            return nil, "Permission denied: root required"
        end
        local ep
        for addr in raw_component.list("eeprom") do
            ep = raw_component.proxy(addr); break
        end
        if not ep then return nil, "No EEPROM" end
        ep.setData(sData)
        return true
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Compute machine binding using SAME formula as BIOS (dc+ep+fs addresses)
kernel.tSyscallTable["secureboot_compute_binding"] = {
    func = function(nPid)
        local tProc = kernel.tProcessTable[nPid]
        if not tProc or (tProc.uid or 1000) ~= 0 then
            return nil, "Root required"
        end
        local dcAddr, epAddr, fsAddr = "", "", ""
        for addr in raw_component.list("data") do dcAddr = addr; break end
        for addr in raw_component.list("eeprom") do epAddr = addr; break end
        for addr in raw_component.list("filesystem") do
            local p = raw_component.proxy(addr)
            if p and p.exists and p.exists("/kernel.lua") then fsAddr = addr; break end
        end
        if dcAddr == "" then return nil, "No data card" end
        local dc = raw_component.proxy(dcAddr)
        local sRaw = dc.sha256(dcAddr .. epAddr .. fsAddr)
        local t = {}
        for i = 1, #sRaw do t[i] = string.format("%02x", sRaw:byte(i)) end
        return table.concat(t)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Compute kernel hash using SAME formula as BIOS
kernel.tSyscallTable["secureboot_compute_kernel_hash"] = {
    func = function(nPid)
        local tProc = kernel.tProcessTable[nPid]
        if not tProc or (tProc.uid or 1000) ~= 0 then
            return nil, "Root required"
        end
        local dcAddr = ""
        for addr in raw_component.list("data") do dcAddr = addr; break end
        if dcAddr == "" then return nil, "No data card" end
        local dc = raw_component.proxy(dcAddr)
        local kc = primitive_load("/kernel.lua")
        if not kc then return nil, "Cannot read kernel" end
        local sRaw = dc.sha256(kc)
        local t = {}
        for i = 1, #sRaw do t[i] = string.format("%02x", sRaw:byte(i)) end
        return table.concat(t)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-------------------------------------------------
-- KERNEL INITIALIZATION
-------------------------------------------------
kprint("info", "Kernel entering initialization sequence (Ring 0).")
kprint("dev", "Initializing syscall dispatcher table...")

-- 0. Load Object Manager
g_oObManager = __load_ob_manager()
if g_oObManager then
    g_oObManager.ObInitSystem()
    kprint("ok", "Object Manager initialised.  Namespace: \\, \\Device, \\DosDevices")
else
    kprint("warn", "Object Manager not available. Running without handle security.")
end
kprint("ok", "sMLTR (Synapse Message Layer Token Randomisation) active.")

-- Load Virtual Registry
g_oRegistry = __load_registry()
if g_oRegistry then
    g_oRegistry.InitSystem()
    kprint("ok", "Virtual Registry (@VT) initialised.")
else
    kprint("warn", "Virtual Registry not available.")
end

-- Load Preemptive Scheduler module
g_oPreempt = __load_preempt()
if g_oPreempt then
    kprint("ok", string.format("Preemptive scheduler active  (quantum=%dms, interval=%d, no debug hooks)",
        g_oPreempt.DEFAULT_QUANTUM * 1000, g_oPreempt.CHECK_INTERVAL))
else
    kprint("warn", "Preemptive scheduling unavailable cooperative only.")
end

-- Load Kernel IPC subsystem
g_oIpc = __load_ke_ipc()
if g_oIpc and g_oObManager then
    g_oIpc.Initialize({
        tProcessTable = kernel.tProcessTable,
        fUptime = raw_computer.uptime,
        fLog = function(s)
            kprint("info", s)
        end,
        oObManager = g_oObManager,
        fYield = coroutine.yield
    })
    -- Register new object types
    g_oObManager.ObCreateObjectType("KeMutex", {})
    g_oObManager.ObCreateObjectType("KeSemaphore", {})
    g_oObManager.ObCreateObjectType("KeTimer", {})
    g_oObManager.ObCreateObjectType("IoPipeObject", {})
    g_oObManager.ObCreateObjectType("IpcMessageQueue", {})
    kprint("ok", "Kernel IPC subsystem online (Events, Mutexes, Semaphores,")
    kprint("ok", "  Pipes, Sections, MQueues, Signals, WaitMultiple, DPC, IRQL)")
else
    kprint("warn", "Kernel IPC subsystem not available.")
end

-- Load Metatable Hypervisor
g_oHypervisor = __load_hypervisor()
if g_oHypervisor then
    kprint("ok", "Metatable Hypervisor loaded (freeze, snapshot, verify)")
else
    kprint("warn", "Hypervisor not available — no metatable-based protection")
end

-- Load PatchGuard (Kernel Integrity Monitor)
g_oPatchGuard = __load_patchguard()
if g_oPatchGuard then
    kprint("ok", "PatchGuard loaded — will arm after boot completes")
else
    kprint("warn", "PatchGuard not available — no runtime integrity monitoring")
end

-- 1. Mount Root FS
kprint("info", "Reading fstab from /etc/fstab.lua...")
local tFstab = primitive_load_lua("/etc/fstab.lua")
if not tFstab then
    kprint("fail", "Failed to load /etc/fstab.lua")
    kernel.panic("fstab is missing or corrupt.")
end

local tRootEntry = tFstab[1]
if tRootEntry.type ~= "rootfs" then
    kprint("fail", "fstab[1] is not of type 'rootfs'.")
    kernel.panic("Invalid fstab configuration.")
end

if g_bAxfsRoot then
    kernel.tVfs.sRootUuid = g_oPrimitiveFs.address
    kernel.tVfs.oRootFs = g_oPrimitiveFs
    kprint("ok", "Mounted AXFS root filesystem (" .. g_oPrimitiveFs._label .. ")")
else
    kernel.tVfs.sRootUuid = tRootEntry.uuid
    kernel.tVfs.oRootFs = raw_component.proxy(tRootEntry.uuid)
    kprint("ok", "Mounted root filesystem on " .. kernel.tVfs.sRootUuid:sub(1, 13) .. "...")
end

kernel.tVfs.tMounts["/"] = {
    type = "rootfs",
    proxy = kernel.tVfs.oRootFs,
    options = tRootEntry.options
}
kprint("ok", "Mounted root filesystem on", kernel.tVfs.sRootUuid:sub(1, 13) .. "...")

-- =============================================
-- CHECK FOR PREVIOUS CRASH
-- =============================================
do
    local bCrashDetected = false
    pcall(function()
        local ep
        for addr in raw_component.list("eeprom") do
            ep = raw_component.proxy(addr); break
        end
        if ep then
            local sData = ep.getData()
            if sData and #sData >= 246 then
                local nCrashType = sData:byte(245) or 0
                local nPgCount   = sData:byte(246) or 0
                if nCrashType > 0 then
                    bCrashDetected = true
                    local tTypeNames = {
                        [1] = "KERNEL_PANIC",
                        [2] = "PATCHGUARD_VIOLATION",
                        [3] = "OOM_KILL",
                        [4] = "WATCHDOG",
                    }
                    kprint("sec", "╔══════════════════════════════════════════╗")
                    kprint("sec", "║  PREVIOUS CRASH DETECTED                 ║")
                    kprint("sec", "╚══════════════════════════════════════════╝")
                    kprint("sec", string.format(
                        "  Type: %d (%s)", nCrashType,
                        tTypeNames[nCrashType] or "UNKNOWN"))
                    if nCrashType == 2 then
                        kprint("sec", string.format(
                            "  PatchGuard violations: %d", nPgCount))
                    end
                    kprint("sec", "  Check /log/crash_*.dump for details")
                    kprint("sec", "")

                    -- Clear crash flag
                    sData = sData:sub(1, 244)
                         .. "\0\0"
                         .. sData:sub(247)
                    ep.setData(sData)
                end
            end
        end
    end)
end

-- 2. Create PID 0 (Kernel Process)
local nKernelPid = kernel.nNextPid
kernel.nNextPid = kernel.nNextPid + 1
local coKernel = coroutine.running()
local tKernelEnv = kernel.create_sandbox(nKernelPid, 0)
kernel.tProcessTable[nKernelPid] = {
    co = coKernel,
    status = "running",
    ring = 0,
    parent = 0,
    env = tKernelEnv,
    fds = {},
    synapseToken = fGenerateSynapseToken(),
    threads = {}
}
kernel.tPidMap[coKernel] = nKernelPid
kernel.tRings[nKernelPid] = 0
g_nCurrentPid = nKernelPid
_G = tKernelEnv

if g_oObManager then
    g_oObManager.ObInitializeProcess(nKernelPid)
end

kprint("ok", "Kernel process registered as PID", nKernelPid)

-- 3. Load Ring 1 Pipeline Manager
kprint("info", "Starting Ring 1 services...")
local g_tCriticalPaths = {}
for _, s in ipairs({
    "/kernel.lua", "/lib/pipeline_manager.lua",
    "/bin/init.lua", "/etc/passwd.lua",
    "/system/dkms.lua", "/lib/ob_manager.lua",
    "/lib/ke_ipc.lua", "/lib/preempt.lua",
    "/drivers/tty.sys.lua", "/etc/perms.lua",
    "/sys/security/patchguard.lua",
    "/boot/loader.cfg", "/boot/boot.lua",
}) do
    g_tCriticalPaths[s] = true
end

local tPmEnv = {
    SAFE_MODE = (tBootArgs.safemode == "Enabled"),
    INIT_PATH = tBootArgs.init or "/bin/init.lua"
}

local nPipelinePid, sErr = kernel.create_process("/lib/pipeline_manager.lua", 1, nKernelPid, tPmEnv)

if not nPipelinePid then
    kprint("fail", "Failed to start Ring 1 Pipeline Manager:", sErr)
    kernel.panic("Critical service failure: pipeline_manager")
end
kernel.nPipelinePid = nPipelinePid
kprint("ok", "Ring 1 Pipeline Manager started as PID", nPipelinePid)

-- Initialize PatchGuard with kernel references
-- Initialize PatchGuard with FULL monitoring data
if g_oPatchGuard then
    -- Build hardware verification functions
    -- These are closures that PatchGuard stores as upvalues
    local fPgSha256 = nil
    local fPgReadEepromCode = nil
    local fPgReadEepromData = nil
    local fPgComputeBinding = nil
    local fPgHashKernel = nil

    -- Find data card and eeprom for PatchGuard
    local sPgDataAddr, sPgEepAddr
    for addr in raw_component.list("data") do sPgDataAddr = addr; break end
    for addr in raw_component.list("eeprom") do sPgEepAddr = addr; break end

    if sPgDataAddr then
        local oPgData = raw_component.proxy(sPgDataAddr)
        if oPgData and oPgData.sha256 then
            fPgSha256 = function(s) return oPgData.sha256(s) end
        end
    end

    if sPgEepAddr then
        local oPgEep = raw_component.proxy(sPgEepAddr)
        if oPgEep then
            fPgReadEepromCode = function() return oPgEep.get() end
            fPgReadEepromData = function() return oPgEep.getData() end
        end
    end

    if fPgSha256 then
        fPgComputeBinding = function()
            local t = {}
            for addr in raw_component.list("data") do t[#t+1] = addr; break end
            for addr in raw_component.list("eeprom") do t[#t+1] = addr; break end
            for addr in raw_component.list("filesystem") do
                local p = raw_component.proxy(addr)
                if p and p.exists and p.exists("/kernel.lua") then
                    t[#t+1] = addr; break
                end
            end
            local sRaw = fPgSha256(table.concat(t))
            local tHex = {}
            for i = 1, #sRaw do tHex[i] = string.format("%02x", sRaw:byte(i)) end
            return table.concat(tHex)
        end

        fPgHashKernel = function()
            local sCode = primitive_load("/kernel.lua")
            if not sCode then return nil end
            local sRaw = fPgSha256(sCode)
            local tHex = {}
            for i = 1, #sRaw do tHex[i] = string.format("%02x", sRaw:byte(i)) end
            return table.concat(tHex)
        end
    end

    g_oPatchGuard.Initialize({
        -- Tier 1: core structures
        tSyscallTable     = kernel.tSyscallTable,
        tSyscallOverrides = kernel.tSyscallOverrides,
        nPipelinePid      = kernel.nPipelinePid,
        fPanic            = function(s, co, tViol) kernel.panic(s, co, tViol) end,
        fLog              = function(s) kprint("sec", s) end,
        fUptime           = raw_computer.uptime,

        -- Tier 1: process integrity
        tProcessTable     = kernel.tProcessTable,
        tRings            = kernel.tRings,

        -- Tier 2: frozen libraries
        tFrozenLibs       = {
            string = g_tFrozenString,
            table  = g_tFrozenTable,
            math   = g_tFrozenMath,
        },

        -- Tier 2: object manager
        oObManager        = g_oObManager,

        -- Tier 3: SecureBoot attestation
        tBootSecurity     = boot_security or nil,

        -- Tier 3: hardware verification
        fSha256           = fPgSha256,
        fComputeBinding   = fPgComputeBinding,
        fHashKernel       = fPgHashKernel,
        fReadEepromCode   = fPgReadEepromCode,
        fReadEepromData   = fPgReadEepromData,
        fReadFile         = function(sPath) return primitive_load(sPath) end,
        fFlush            = function() raw_computer.pullSignal(0) end,
        fLastModified     = function(sPath)
            local bOk, nMtime = pcall(g_oPrimitiveFs.lastModified, sPath)
            return bOk and nMtime or nil
        end,
    })
    kprint("ok", "PatchGuard v2 snapshot taken — arming deferred to post-boot")
end


-- =============================================
-- COMPREHENSIVE SECURITY AUDIT AT BOOT
-- =============================================
do
    kprint("sec", "╔══════════════════════════════════════════╗")
    kprint("sec", "║  SECURITY SUBSYSTEM STATUS               ║")
    kprint("sec", "╚══════════════════════════════════════════╝")

    -- Object Manager
    kprint("sec", string.format("  ObManager:     %s",
        g_oObManager and "ACTIVE" or "UNAVAILABLE"))

    -- Hypervisor
    kprint("sec", string.format("  Hypervisor:    %s",
        g_oHypervisor and "ACTIVE" or "UNAVAILABLE"))

    -- Preemptive Scheduler
    kprint("sec", string.format("  Preemption:    %s",
        g_oPreempt and string.format("ACTIVE (Q=%dms, I=%d)",
            g_oPreempt.DEFAULT_QUANTUM * 1000,
            g_oPreempt.CHECK_INTERVAL)
        or "COOPERATIVE ONLY"))

    -- IPC
    kprint("sec", string.format("  IPC:           %s",
        g_oIpc and "ACTIVE" or "UNAVAILABLE"))

    -- PatchGuard
    if g_oPatchGuard then
        local tPgS = g_oPatchGuard.GetStats()
        kprint("sec", string.format(
            "  PatchGuard:    LOADED (%d syscalls, %d libs, SB=%s)",
            tPgS.nSyscallsMonitored or 0,
            tPgS.nFrozenLibs or 0,
            tPgS.bSecureBootActive and "YES" or "NO"))
    else
        kprint("sec", "  PatchGuard:    UNAVAILABLE")
    end

    -- Data card
    local sDataTier = "NONE"
    pcall(function()
        for addr in raw_component.list("data") do
            local p = raw_component.proxy(addr)
            if p.ecdsa then sDataTier = "TIER 3 (ECDSA)"
            elseif p.encrypt then sDataTier = "TIER 2 (AES)"
            else sDataTier = "TIER 1 (SHA)" end
            break
        end
    end)
    kprint("sec", "  Data Card:     " .. sDataTier)

    -- EEPROM
    local sEepState = "NONE"
    pcall(function()
        for addr in raw_component.list("eeprom") do
            local ep = raw_component.proxy(addr)
            local sData = ep.getData()
            if sData and #sData >= 4 and sData:sub(1,4) == "AXCF" then
                local nSbMode = sData:byte(5) or 0
                sEepState = string.format("AXCF (SB=%d, label=%s)",
                    nSbMode, ep.getLabel() or "?")
            else
                sEepState = "PRESENT (no AXCF data)"
            end
            break
        end
    end)
    kprint("sec", "  EEPROM:        " .. sEepState)

    -- SecureBoot
    if boot_security and boot_security.verified then
        kprint("sec", "  SecureBoot:    VERIFIED")
        kprint("sec", string.format("    Binding:   %s...",
            tostring(boot_security.machine_binding):sub(1,24)))
        kprint("sec", string.format("    KernHash:  %s...",
            tostring(boot_security.kernel_hash):sub(1,24)))
    else
        kprint("sec", "  SecureBoot:    " ..
            (boot_security and "PRESENT (unverified)" or "DISABLED"))
    end

    -- sMLTR
    kprint("sec", "  sMLTR:         ACTIVE")
    kprint("sec", "  Sandbox:       3-layer proxy (protected metatable)")

    kprint("sec", "")
end

-------------------------------------------------
-- MAIN KERNEL EVENT LOOP
-------------------------------------------------
kprint("info", "Handing off control to scheduler...")
kprint("ok", "Entering main event loop. Kernel is now running.")
kprint("none", "")

table.insert(kernel.tProcessTable[nPipelinePid].run_queue, "start")

-- =================================================================
-- MAIN KERNEL EVENT LOOP   Preemptive Round-Robin Scheduler
--
-- Key changes from cooperative-only:
--
--  1) After each coroutine.resume(), if the process status is still
--     "running" it was preempted by __pc() rather than yielding via
--     a syscall.  We set it back to "ready" so it runs again next
--     tick.
--
--  2) Between every process resume we call computer.pullSignal(0)
--     to RESET the OpenComputers "too long without yielding" timer.
--     Without this, the cumulative runtime of all processes in one
--     tick could exceed OC's ~5-second hard limit and crash the
--     machine.
--
--  3) We track wall-clock time per resume and maintain per-process
--     CPU accounting.  A watchdog warns (and eventually kills)
--     processes whose single resumes exceed WATCHDOG_WARN_THRESHOLD.
--
--  4) Hardware events captured during intermediate pullSignal(0)
--     calls are forwarded to the Pipeline Manager immediately,
--     improving input responsiveness.
-- =================================================================

while true do
    if g_oPatchGuard and not g_bPgAutoArmed then
        g_nBootTickCounter = g_nBootTickCounter + 1
        if g_nBootTickCounter >= 300 then
            g_bPgAutoArmed = true
            kprint("sec", "PatchGuard auto-arming (post-boot, tick " .. g_nBootTickCounter .. ")...")
            g_oPatchGuard.TakeSnapshot(false)  -- re-snapshot with PM overrides now registered
            g_oPatchGuard.Arm()
            kprint("sec", "PatchGuard ARMED — all integrity monitoring active")
        end
    end

    local nWorkDone = 0

    for nPid, tProcess in pairs(kernel.tProcessTable) do
        if tProcess.status == "ready" then
            nWorkDone = nWorkDone + 1
            g_nCurrentPid = nPid
            tProcess.status = "running"

            local nResumeStart = raw_computer.uptime()

            local tResumeParams = tProcess.resume_args
            tProcess.resume_args = nil

            local bIsOk, sErrOrSignalName
            if tResumeParams then
                bIsOk, sErrOrSignalName = coroutine.resume(tProcess.co, true, table.unpack(tResumeParams))
            else
                bIsOk, sErrOrSignalName = coroutine.resume(tProcess.co)
            end

            local nSliceTime = raw_computer.uptime() - nResumeStart

            g_nCurrentPid = nKernelPid

            -- ---------- per-process CPU accounting ----------
            tProcess.nCpuTime = (tProcess.nCpuTime or 0) + nSliceTime
            tProcess.nLastSlice = nSliceTime
            if nSliceTime > (tProcess.nMaxSlice or 0) then
                tProcess.nMaxSlice = nSliceTime
            end

            -- ---------- global scheduler accounting ----------
            g_tSchedStats.nTotalResumes = g_tSchedStats.nTotalResumes + 1
            local nSliceMs = nSliceTime * 1000
            if nSliceMs > g_tSchedStats.nMaxSliceMs then
                g_tSchedStats.nMaxSliceMs = nSliceMs
            end

            -- ---------- crash handling ----------
            if not bIsOk then
                tProcess.status = "dead"
                kernel.panic(tostring(sErrOrSignalName), tProcess.co)
            end

            -- ---------- PREEMPTION DETECTION ----------
            if tProcess.status == "running" then
                tProcess.status = "ready"
                tProcess.nPreemptCount = (tProcess.nPreemptCount or 0) + 1
                g_tSchedStats.nPreemptions = g_tSchedStats.nPreemptions + 1
            end

            -- ---------- natural exit ----------
            if coroutine.status(tProcess.co) == "dead" then
                if tProcess.status ~= "dead" then
                    kprint("info", "Process " .. nPid .. " exited normally.")
                    tProcess.status = "dead"
                end
            end

            -- ---------- watchdog ----------
            if nSliceTime > WATCHDOG_WARN_THRESHOLD and tProcess.status ~= "dead" then
                tProcess.nWatchdogStrikes = (tProcess.nWatchdogStrikes or 0) + 1
                g_tSchedStats.nWatchdogWarnings = g_tSchedStats.nWatchdogWarnings + 1
                kprint("warn",
                    string.format("WATCHDOG: PID %d ran %.2fs without yielding (strike %d/%d)", nPid, nSliceTime,
                        tProcess.nWatchdogStrikes, WATCHDOG_KILL_STRIKES))
                if tProcess.nWatchdogStrikes >= WATCHDOG_KILL_STRIKES then
                    kprint("fail",
                        "WATCHDOG: Killing PID " .. nPid .. " exceeded " .. WATCHDOG_KILL_STRIKES .. " strikes")
                    tProcess.status = "dead"
                    g_tSchedStats.nWatchdogKills = g_tSchedStats.nWatchdogKills + 1
                end
            end

            -- ---------- wake waiters / clean up dead ----------
            if tProcess.status == "dead" then
                if g_oIpc then
                    g_oIpc.NotifyChildDeath(nPid)
                end
                if g_oObManager then
                    g_oObManager.ObDestroyProcess(nPid)
                end

                for _, nWaiterPid in ipairs(tProcess.wait_queue or {}) do
                    local tWaiter = kernel.tProcessTable[nWaiterPid]
                    if tWaiter and tWaiter.status == "sleeping" and tWaiter.wait_reason == "wait_pid" then
                        tWaiter.status = "ready"
                        tWaiter.resume_args = {true}
                    end
                end

                for _, nTid in ipairs(tProcess.threads or {}) do
                    if kernel.tProcessTable[nTid] and kernel.tProcessTable[nTid].status ~= "dead" then
                        kernel.tProcessTable[nTid].status = "dead"
                        if g_oObManager then
                            g_oObManager.ObDestroyProcess(nTid)
                        end
                    end
                end
                -- fKernelGC("step", 100)
            end

            -- ======================================================
            -- CRITICAL:  Reset the OC "too long without yielding"
            -- timer.  This MUST stay inside the per-process loop so
            -- that each individual resume gets a fresh 5-second window.
            -- Also picks up hardware events for responsiveness.
            -- ======================================================
            local sIntEvt, ip1, ip2, ip3, ip4, ip5 = computer.pullSignal(0)
            if sIntEvt then
                pcall(kernel.syscalls.signal_send, nKernelPid, kernel.nPipelinePid, "os_event", sIntEvt, ip1, ip2, ip3,
                    ip4, ip5)
            end

        end -- if status == "ready"
    end -- for each process

    -- ====== IPC TICK: process DPCs and timers ONCE per iteration ======
    -- This runs AFTER all ready processes have had their turn,
    -- so DPCs queued during this tick's resumes execute here,
    -- and timers are checked exactly once per scheduler pass.
    if g_oIpc then
        g_oIpc.Tick()
    end

    if g_oPatchGuard then
        g_oPatchGuard.Tick(nWorkDone > 0)
    end


    -- ====== OOM KILLER ======
    local FREE_MEMORY_FLOOR = 32768
    local nFreeMem = computer.freeMemory()
    if nFreeMem < FREE_MEMORY_FLOOR then
        local nVictimPid = nil
        local nVictimCpu = 0
        for nKillPid, tKillProc in pairs(kernel.tProcessTable) do
            if tKillProc.status ~= "dead" and tKillProc.ring >= 3 and (tKillProc.nCpuTime or 0) > nVictimCpu then
                nVictimCpu = tKillProc.nCpuTime or 0
                nVictimPid = nKillPid
            end
        end
        if nVictimPid then
            kprint("fail", string.format("OOM KILLER: PID %d (free=%dB)", nVictimPid, nFreeMem))
            kernel.tProcessTable[nVictimPid].status = "dead"
            if g_oObManager then
                g_oObManager.ObDestroyProcess(nVictimPid)
            end
            -- fKernelGC("collect")
        end
    end

    -- Pull external events (block briefly if idle)
    local nTimeout = (nWorkDone > 0) and 0 or 0.05
    local sEventName, p1, p2, p3, p4, p5 = computer.pullSignal(nTimeout)

    if sEventName then
        pcall(kernel.syscalls.signal_send, nKernelPid, kernel.nPipelinePid, "os_event", sEventName, p1, p2, p3, p4, p5)
    end
end