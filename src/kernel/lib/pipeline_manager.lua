--
-- /lib/pipeline_manager.lua
-- AxisOS Pipeline Manager — Thin Coordinator
-- v4: Split architecture. VFS I/O delegated to io_manager,
--     permission checks to security_monitor, session bootstrap
--     to session_manager. PM retains boot sequence, log plumbing,
--     signal buffering, and driver-load (long-wait) handling.
--

local syscall = syscall

syscall("kernel_register_pipeline")
syscall("kernel_log", "[PM] Ring 1 Pipeline Manager started.")

local nMyPid = syscall("process_get_pid")

-- ==========================================
-- SPAWN DKMS
-- ==========================================

local nDkmsPid, sDkmsErr = syscall("process_spawn", "/system/dkms.lua", 1)
if not nDkmsPid then
    syscall("kernel_panic", "Could not spawn DKMS: " .. tostring(sDkmsErr))
end
syscall("kernel_log", "[PM] DKMS process started as PID " .. tostring(nDkmsPid))

-- ==========================================
-- INTERNAL STATE
-- ==========================================

local vfs_state = { oRootFs = nil }

local g_tPmInternal    = {}       -- [nId] → {type, devname, driverPid, rawHandle}
local g_nPmNextInternal = 1
local g_tPmSignalBuffer = {}
local g_nRingFsId       = nil     -- persistent ringfs handle
local g_tLogState        = nil    -- {hLogFile, hVblFile, sLogPath, sVblPath}
local g_tSysConfig       = nil    -- parsed /etc/sys.cfg

-- ==========================================
-- LOAD SUB-MODULES
-- They execute in PM's Ring 1 context.
-- io_manager registers its own syscall overrides
-- at require() time (vfs_open … driver_load).
-- ==========================================

local oIoManager  = require("io_manager")
local oSecMonitor = require("security_monitor")
local oSessManager = require("session_manager")

-- PM additionally overrides vfs_chmod (security_monitor handles it)
syscall("syscall_override", "vfs_chmod")

-- ==========================================
-- HELPERS
-- ==========================================

local function parse_options(sOptions)
    local tOpts = {}
    if not sOptions then return tOpts end
    for sPart in string.gmatch(sOptions, "[^,]+") do
        local k, v = sPart:match("([^=]+)=(.*)")
        if k then tOpts[k] = tonumber(v) or v
        else tOpts[sPart] = true end
    end
    return tOpts
end

-- ==========================================
-- DKMS COMMUNICATION (with signal buffering)
-- ==========================================

local function wait_for_dkms()
    while true do
        local bOk, nSender, sSig, p1, p2, p3, p4, p5 = syscall("signal_pull")
        if bOk then
            if sSig == "syscall_return" and nSender == nDkmsPid then
                return p1, p2
            elseif sSig == "os_event" then
                syscall("signal_send", nDkmsPid, "os_event", p1, p2, p3, p4, p5)
            else
                table.insert(g_tPmSignalBuffer, {nSender, sSig, p1, p2, p3, p4, p5})
            end
        end
    end
end

-- ==========================================
-- INTERNAL VFS OPS (used by PM during boot)
-- ==========================================

local function _resolveDeviceName(sPath)
    if sPath == "/dev/tty"  then return "\\Device\\TTY0" end
    if sPath == "/dev/gpu0" then return "\\Device\\Gpu0" end
    return sPath
end

local function _sendDeviceCreate(sDevName)
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_CREATE)
    pIrp.sDeviceName = sDevName
    pIrp.nSenderPid  = nMyPid
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    local nStatus, vInfo = wait_for_dkms()
    return nStatus, (type(vInfo) == "number") and vInfo or nDkmsPid
end

local function _sendDeviceWrite(sDevName, nDriverPid, sData)
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_WRITE)
    pIrp.sDeviceName      = sDevName
    pIrp.nSenderPid       = nMyPid
    pIrp.tParameters.sData = sData
    if sDevName == "\\Device\\TTY0" then
        pIrp.nFlags = tDKStructs.IRP_FLAG_NO_REPLY
        syscall("signal_send", nDriverPid, "irp_dispatch", pIrp)
        return true, #sData
    end
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    local nSt, vInfo = wait_for_dkms()
    return (nSt == 0), vInfo
end

local function _sendDeviceRead(sDevName)
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_READ)
    pIrp.sDeviceName = sDevName
    pIrp.nSenderPid  = nMyPid
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    local nSt, vInfo = wait_for_dkms()
    return (nSt == 0), vInfo
end

local function _sendDeviceClose(sDevName)
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_CLOSE)
    pIrp.sDeviceName = sDevName
    pIrp.nSenderPid  = nMyPid
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    wait_for_dkms()
end

local function _sendDeviceControl(sDevName, sMethod, tArgs)
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_DEVICE_CONTROL)
    pIrp.sDeviceName         = sDevName
    pIrp.nSenderPid          = nMyPid
    pIrp.tParameters.sMethod = sMethod
    pIrp.tParameters.tArgs   = tArgs or {}
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    local nSt, vInfo = wait_for_dkms()
    return (nSt == 0), vInfo
end

function _doInternalOpen(sPath, sMode)
    local nId = g_nPmNextInternal
    g_nPmNextInternal = g_nPmNextInternal + 1
    if sPath:sub(1, 5) == "/dev/" then
        local sDevName = _resolveDeviceName(sPath)
        local nSt, nDrvPid = _sendDeviceCreate(sDevName)
        if nSt ~= 0 then return nil, "Device open failed" end
        g_tPmInternal[nId] = { type = "device", devname = sDevName, driverPid = nDrvPid }
        return true, nId
    end
    local bOk, hRaw, sReason = syscall("raw_component_invoke",
        vfs_state.oRootFs.address, "open", sPath, sMode)
    if not hRaw then return nil, sReason end
    g_tPmInternal[nId] = { type = "file", rawHandle = hRaw }
    return true, nId
end

function _doInternalWrite(nId, sData)
    local t = g_tPmInternal[nId]
    if not t then return nil end
    if t.type == "file" then
        return syscall("raw_component_invoke",
            vfs_state.oRootFs.address, "write", t.rawHandle, sData)
    else
        return _sendDeviceWrite(t.devname, t.driverPid, sData)
    end
end

function _doInternalRead(nId, nCount)
    local t = g_tPmInternal[nId]
    if not t then return nil end
    if t.type == "file" then
        local r1, r2 = syscall("raw_component_invoke",
            vfs_state.oRootFs.address, "read", t.rawHandle, nCount)
        if type(r2) == "boolean" then r2 = nil end
        return r1, r2
    else
        return _sendDeviceRead(t.devname)
    end
end

function _doInternalClose(nId)
    local t = g_tPmInternal[nId]
    if not t then return end
    if t.type == "file" then
        syscall("raw_component_invoke",
            vfs_state.oRootFs.address, "close", t.rawHandle)
    else
        _sendDeviceClose(t.devname)
    end
    g_tPmInternal[nId] = nil
end

-- ==========================================
-- LOG SYSTEM
-- Config loading delegated to session_manager.
-- Ringfs plumbing and permanent-file writes
-- stay here because they need internal VFS ops.
-- ==========================================

local function _rotateLogDir(sDir, nMax)
    local bOk, tList = syscall("raw_component_invoke",
        vfs_state.oRootFs.address, "list", sDir)
    if not bOk or not tList then return 1 end
    local tFiles, nMaxNum = {}, 0
    for _, sName in ipairs(tList) do
        local sClean = sName:gsub("/$", "")
        local sNum = sClean:match("syslog_(%d+)")
        if sNum then
            local n = tonumber(sNum)
            table.insert(tFiles, { name = sClean, num = n })
            if n > nMaxNum then nMaxNum = n end
        end
    end
    table.sort(tFiles, function(a, b) return a.num < b.num end)
    while #tFiles >= nMax do
        syscall("raw_component_invoke",
            vfs_state.oRootFs.address, "remove", sDir .. "/" .. tFiles[1].name)
        table.remove(tFiles, 1)
    end
    return nMaxNum + 1
end

local function _setupLogRotation(tConfig)
    local tLog = tConfig and tConfig.logging
    if not tLog or not tLog.enable_log_rotation_saver then
        syscall("kernel_log", "[PM] Log rotation disabled in sys.cfg.")
        return nil
    end
    local sLogDir = tLog.log_dir or "/log"
    local sVblDir = tLog.vbl_dir or "/vbl"
    local nMax    = tLog.max_log_files or 5
    pcall(function() syscall("raw_component_invoke",
        vfs_state.oRootFs.address, "makeDirectory", sLogDir) end)
    pcall(function() syscall("raw_component_invoke",
        vfs_state.oRootFs.address, "makeDirectory", sVblDir) end)
    local nLogNum = _rotateLogDir(sLogDir, nMax)
    local nVblNum = _rotateLogDir(sVblDir, nMax)
    local nNum    = math.max(nLogNum, nVblNum)
    local sNumStr = string.format("%03d", nNum)
    local sLogPath = sLogDir .. "/syslog_" .. sNumStr .. ".log"
    local sVblPath = sVblDir .. "/syslog_" .. sNumStr .. ".vbl"
    local bOk1, hLog = syscall("raw_component_invoke",
        vfs_state.oRootFs.address, "open", sLogPath, "w")
    local bOk2, hVbl = syscall("raw_component_invoke",
        vfs_state.oRootFs.address, "open", sVblPath, "w")
    if bOk1 and hLog then
        syscall("raw_component_invoke",
            vfs_state.oRootFs.address, "write", hLog, "=== LOG SESSION START ===\n")
    end
    if bOk2 and hVbl then
        syscall("raw_component_invoke",
            vfs_state.oRootFs.address, "write", hVbl, "=== VBL SESSION START ===\n")
    end
    return {
        hLogFile = (bOk1 and hLog) or nil,
        hVblFile = (bOk2 and hVbl) or nil,
        sLogPath = sLogPath,
        sVblPath = sVblPath,
    }
end

local function _writeToLogFiles(sText)
    if not g_tLogState or not sText or #sText == 0 then return end
    if g_tLogState.hVblFile then
        syscall("raw_component_invoke",
            vfs_state.oRootFs.address, "write", g_tLogState.hVblFile, sText)
    end
    if g_tLogState.hLogFile then
        local sFiltered = ""
        for sLine in (sText .. "\n"):gmatch("([^\n]*)\n") do
            if #sLine > 0
               and not sLine:find("%[DEBUG %]")
               and not sLine:find("%[ DEV  %]")
               and not sLine:find("%[SCHED %]")
               and not sLine:find("%[ IPC  %]")
               and not sLine:find("%[DK%]") then
                sFiltered = sFiltered .. sLine .. "\n"
            end
        end
        if #sFiltered > 0 then
            syscall("raw_component_invoke",
                vfs_state.oRootFs.address, "write", g_tLogState.hLogFile, sFiltered)
        end
    end
end

local function _drainKernelLog()
    local sNewLog = syscall("kernel_get_boot_log")
    if not sNewLog or #sNewLog == 0 then return end
    if g_nRingFsId then
        pcall(function() _doInternalWrite(g_nRingFsId, sNewLog) end)
    end
    _writeToLogFiles(sNewLog)
end

local function flush_boot_log(sLogDevice)
    syscall("kernel_log", "[PM] Initializing log system on " .. sLogDevice)
    g_tSysConfig = oSessManager._loadSysConfig(vfs_state.oRootFs)
    g_tLogState  = _setupLogRotation(g_tSysConfig)
    local bOk, nId = _doInternalOpen(sLogDevice, "w")
    if bOk then
        g_nRingFsId = nId
        syscall("kernel_log", "[PM] Ringfs handle opened (persistent).")
    else
        syscall("kernel_log", "[PM] Warning: Could not open " .. sLogDevice)
    end
    _drainKernelLog()
    syscall("kernel_log", "[PM] Log system initialized.")
end

-- ==========================================
-- DRIVER LOAD (kept in PM for signal buffering)
-- ==========================================

local function handle_driver_load(nSenderPid, sPath)
    local nUid = syscall("process_get_uid", nSenderPid) or 1000
    if nUid ~= 0 then
        return nil, "Permission denied: only root can load drivers"
    end
    syscall("kernel_log", "[PM] User (PID " .. nSenderPid .. ") requested load of: " .. sPath)
    syscall("signal_send", nDkmsPid, "load_driver_path_request", sPath, nSenderPid)
    while true do
        local bOk, nSender, sSig, p1, p2, p3, p4 = syscall("signal_pull")
        if bOk and nSender == nDkmsPid then
            if sSig == "load_driver_result" and p1 == nSenderPid then
                if p2 == 0 then
                    local sMsg = p4 and p4 > 0
                        and string.format("[PM] Loaded '%s' (PID %d)", p3 or "?", p4)
                        or  string.format("[PM] Success: %s", p3 or "?")
                    syscall("kernel_log", sMsg)
                    return true, sMsg
                else
                    local sMsg = "[PM] Driver load failed. Status: " .. tostring(p2)
                    syscall("kernel_log", sMsg)
                    return nil, sMsg
                end
            elseif sSig == "os_event" then
                syscall("signal_send", nDkmsPid, "os_event", p1, p2, p3, p4)
            else
                table.insert(g_tPmSignalBuffer, {nSender, sSig, p1, p2, p3, p4})
            end
        elseif bOk then
            table.insert(g_tPmSignalBuffer, {nSender, sSig, p1, p2, p3, p4})
        end
    end
end

-- ==========================================
-- BOOT HELPERS
-- ==========================================

local function get_gpu_proxy()
    local bOk, tList = syscall("raw_component_list", "gpu")
    if not bOk or not tList then return nil end
    for sAddr in pairs(tList) do return syscall("raw_component_proxy", sAddr) end
end

local function get_screen_addr()
    local bOk, tList = syscall("raw_component_list", "screen")
    if not bOk or not tList then return nil end
    for sAddr in pairs(tList) do return sAddr end
end

local function wait_with_throbber(sMessage, nSeconds)
    local oGpu    = get_gpu_proxy()
    local sScreen = get_screen_addr()
    local nW, nH  = 80, 25
    if oGpu and sScreen then
        oGpu.bind(sScreen)
        nW, nH = oGpu.getResolution()
    end
    local nDeadline = computer.uptime() + nSeconds
    local nFrame, nTW = 0, 12
    syscall("kernel_log", "[PM] " .. sMessage)
    while computer.uptime() < nDeadline do
        if oGpu then
            local nPos = math.floor(nFrame / 1.5) % (nTW * 2 - 2)
            if nPos >= nTW then nPos = (nTW * 2 - 2) - nPos end
            local sLine = "("
            for i = 0, nTW - 1 do
                sLine = sLine .. ((i >= nPos and i < nPos + 3) and "*" or " ")
            end
            sLine = sLine .. ") Driver loading..."
            oGpu.set(1, nH, sLine .. string.rep(" ", nW - #sLine))
            nFrame = nFrame + 1
        end
        syscall("process_yield")
    end
    if oGpu then oGpu.fill(1, nH, nW, 1, " ") end
end

-- ==========================================
-- BOOT SEQUENCE
-- ==========================================

local function __scandrvload()
    syscall("kernel_log", "[PM] Loading TTY Driver explicitly...")
    syscall("signal_send", nDkmsPid, "load_driver_path", "/drivers/tty.sys.lua")
    _drainKernelLog()
    local deadline = computer.uptime() + 0.0
    while computer.uptime() < deadline do syscall("process_yield") end

    syscall("kernel_log", "[PM] Scanning components...")
    local sRootUuid, oRootProxy = syscall("kernel_get_root_fs")
    if not oRootProxy then
        syscall("kernel_panic", "Pipeline could not get root FS info.")
    end
    vfs_state.oRootFs = oRootProxy

    local bListOk, tCompList = syscall("raw_component_list")
    if not bListOk then return end
    for sAddr, sCtype in pairs(tCompList) do
        if sCtype ~= "screen" and sCtype ~= "gpu" and sCtype ~= "keyboard" then
            syscall("kernel_log", "[PM] Loading driver for " .. sCtype)
            syscall("signal_send", nDkmsPid, "load_driver_for_component", sCtype, sAddr)
        end
    end

    -- Registry: enumerate hardware
    if bListOk and tCompList then
        for sAddr, sCtype in pairs(tCompList) do
            local sHwPath = "@VT\\SYS\\HARDWARE\\" .. sCtype .. "_" .. sAddr:sub(1, 6)
            syscall("reg_create_key", sHwPath)
            syscall("reg_set_value", sHwPath, "Address", sAddr, "STR")
            syscall("reg_set_value", sHwPath, "ComponentType", sCtype, "STR")
            syscall("reg_set_value", sHwPath, "ShortAddress", sAddr:sub(1, 8), "STR")
        end
    end
end

local function process_fstab()
    syscall("kernel_log", "[PM] Processing fstab...")
    local bOpenOk, hFstab = syscall("raw_component_invoke",
        vfs_state.oRootFs.address, "open", "/etc/fstab.lua", "r")
    if bOpenOk and hFstab then
        local bReadOk, sData = syscall("raw_component_invoke",
            vfs_state.oRootFs.address, "read", hFstab, math.huge)
        syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", hFstab)
        if bReadOk and type(sData) == "string" then
            local f, sErr = load(sData, "fstab", "t", {})
            if f then
                local tFstab = f()
                if type(tFstab) == "table" then
                    for _, tEntry in ipairs(tFstab) do
                        if tEntry.type == "ringfs" then
                            if not bRingFsLoaded then
                                local bProbe, nProbeId = _doInternalOpen("/dev/ringlog", "w")
                                if bProbe then
                                    _doInternalClose(nProbeId)
                                else
                                    syscall("kernel_log", "[PM] Loading RingFS driver...")
                                    syscall("signal_send", nDkmsPid, "load_driver_path",
                                        "/drivers/ringfs.sys.lua")
                                    syscall("process_wait", 0)
                                end
                                bRingFsLoaded = true
                            end
                            local tOpts = parse_options(tEntry.options)
                            if tOpts.size then
                                local tDKStructs = require("shared_structs")
                                local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_DEVICE_CONTROL)
                                pIrp.sDeviceName         = "\\Device\\ringlog"
                                pIrp.nSenderPid          = nMyPid
                                pIrp.tParameters.sMethod  = "resize"
                                pIrp.tParameters.tArgs    = {tOpts.size}
                                syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
                                wait_for_dkms()
                            end
                            if string.sub(tEntry.path, 1, 5) == "/dev/" then
                                flush_boot_log(tEntry.path)
                            end
                        end
                    end
                end
            else
                syscall("kernel_log", "[PM] Syntax error in fstab: " .. tostring(sErr))
            end
        end
    else
        syscall("kernel_log", "[PM] Warning: /etc/fstab.lua not found.")
    end
end

-- ==========================================
-- DRIVER AUTOLOAD (dependency-sorted)
-- ==========================================

local function _loadDriverWithResult(sPath)
    syscall("kernel_log", "[PM] Loading driver: " .. sPath)
    syscall("signal_send", nDkmsPid, "load_driver_path_request", sPath, nMyPid)
    while true do
        local bOk, nSender, sSig, p1, p2, p3, p4, p5 = syscall("signal_pull")
        if bOk then
            if nSender == nDkmsPid and sSig == "load_driver_result" and p1 == nMyPid then
                return p2, p3, p4
            elseif sSig == "os_event" then
                syscall("signal_send", nDkmsPid, "os_event", p1, p2, p3, p4, p5)
            else
                table.insert(g_tPmSignalBuffer, {nSender, sSig, p1, p2, p3, p4, p5})
            end
        end
    end
end

local function _topoSortDrivers(tEnabled, tByName)
    local tResult, tVisited, tInStack = {}, {}, {}
    local function visit(sName)
        if tVisited[sName] then return true end
        if tInStack[sName] then return false, "Circular dependency: " .. sName end
        local tEntry = tByName[sName]
        if not tEntry then return true end
        tInStack[sName] = true
        for _, sDep in ipairs(tEntry.depends or {}) do
            local bOk, sErr = visit(sDep)
            if not bOk then return false, sErr end
        end
        tInStack[sName] = nil
        tVisited[sName] = true
        tResult[#tResult + 1] = tEntry
        return true
    end
    local tPri = {}
    for _, e in ipairs(tEnabled) do tPri[#tPri + 1] = e end
    table.sort(tPri, function(a, b) return (a.priority or 500) < (b.priority or 500) end)
    for _, tEntry in ipairs(tPri) do
        local bOk, sErr = visit(tEntry.name)
        if not bOk then return nil, sErr end
    end
    return tResult
end

local function _checkDriverFileExists(sPath)
    local bOk, hTest = syscall("raw_component_invoke",
        vfs_state.oRootFs.address, "open", sPath, "r")
    if bOk and hTest then
        syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", hTest)
        return true
    end
    return false
end

local function process_autoload()
    syscall("kernel_log", "[PM] Processing driver autoload...")

    -- Read drivers_cfg path from /boot/loader.cfg
    local sDriversCfgPath = nil
    local bLcOk, hLoaderCfg = syscall("raw_component_invoke",
        vfs_state.oRootFs.address, "open", "/boot/loader.cfg", "r")
    if bLcOk and hLoaderCfg then
        local _, sLcData = syscall("raw_component_invoke",
            vfs_state.oRootFs.address, "read", hLoaderCfg, math.huge)
        syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", hLoaderCfg)
        if sLcData and #sLcData > 0 then
            local fLc = load(sLcData, "loader.cfg", "t", {})
            if fLc then
                local bP, tLc = pcall(fLc)
                if bP and type(tLc) == "table" and tLc.drivers_cfg then
                    sDriversCfgPath = tLc.drivers_cfg
                end
            end
        end
    end

    local tCfgPaths = {}
    if sDriversCfgPath then tCfgPaths[#tCfgPaths + 1] = sDriversCfgPath end
    tCfgPaths[#tCfgPaths + 1] = "/boot/sys/drivers.cfg"
    tCfgPaths[#tCfgPaths + 1] = "/etc/drivers.cfg"

    local tDrivers, bNewFormat, sUsedPath
    for _, sCfgPath in ipairs(tCfgPaths) do
        local bOk, hFile = syscall("raw_component_invoke",
            vfs_state.oRootFs.address, "open", sCfgPath, "r")
        if bOk and hFile then
            local _, sData = syscall("raw_component_invoke",
                vfs_state.oRootFs.address, "read", hFile, math.huge)
            syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", hFile)
            if sData and #sData > 0 then
                local f = load(sData, "drivers.cfg", "t", {})
                if f then
                    local bP, tR = pcall(f)
                    if bP and type(tR) == "table" then
                        tDrivers = tR; bNewFormat = true; sUsedPath = sCfgPath
                        syscall("kernel_log", "[PM] Loaded " .. sCfgPath ..
                            " (" .. #tR .. " entries)")
                        break
                    end
                end
            end
        end
    end

    -- Legacy fallback
    if not bNewFormat then
        syscall("kernel_log", "[PM] No drivers.cfg, trying legacy autoload.lua...")
        local bAOk, hAuto = syscall("raw_component_invoke",
            vfs_state.oRootFs.address, "open", "/etc/autoload.lua", "r")
        if bAOk and hAuto then
            local _, sAData = syscall("raw_component_invoke",
                vfs_state.oRootFs.address, "read", hAuto, math.huge)
            syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", hAuto)
            if sAData then
                local fA = load(sAData, "autoload", "t", {})
                if fA then
                    local tList = fA()
                    if tList then
                        for _, sDrvPath in ipairs(tList) do
                            syscall("signal_send", nDkmsPid, "load_driver_path", sDrvPath)
                            syscall("process_wait", 0)
                        end
                    end
                end
            end
        end
        return
    end

    -- Filter and sort
    local tEnabled, tByName, nSkipped = {}, {}, 0
    for _, tEntry in ipairs(tDrivers) do
        if not tEntry.name or not tEntry.path then
            -- skip
        elseif tEntry.enabled == false then
            nSkipped = nSkipped + 1
        else
            tEnabled[#tEnabled + 1] = tEntry
            tByName[tEntry.name] = tEntry
        end
    end
    syscall("kernel_log", "[PM] Drivers: " .. #tEnabled .. " enabled, " .. nSkipped .. " disabled")
    if #tEnabled == 0 then return end

    local tSorted, sSortErr = _topoSortDrivers(tEnabled, tByName)
    if not tSorted then
        syscall("kernel_log", "[PM] Dependency resolution failed: " .. tostring(sSortErr))
        tSorted = tEnabled
        table.sort(tSorted, function(a, b) return (a.priority or 500) < (b.priority or 500) end)
    end

    local tLoaded, nOk, nFail = {}, 0, 0
    for nIdx, tEntry in ipairs(tSorted) do
        local bDepsMet = true
        for _, sDep in ipairs(tEntry.depends or {}) do
            if tByName[sDep] and not tLoaded[sDep] then
                bDepsMet = false
                syscall("kernel_log", "[PM] SKIP: '" .. tEntry.name ..
                    "' — dependency '" .. sDep .. "' failed")
                break
            end
        end
        if not bDepsMet then nFail = nFail + 1; goto next_driver end
        if not _checkDriverFileExists(tEntry.path) then
            syscall("kernel_log", "[PM] FAIL: '" .. tEntry.name ..
                "' — file not found: " .. tEntry.path)
            nFail = nFail + 1; goto next_driver
        end
        syscall("kernel_log", string.format("[PM] [%d/%d] Loading '%s' (pri=%d) %s",
            nIdx, #tSorted, tEntry.name, tEntry.priority or 500, tEntry.path))
        local nStatus, sDrvName, nDrvPid = _loadDriverWithResult(tEntry.path)
        if nStatus == 0 then
            tLoaded[tEntry.name] = true; nOk = nOk + 1
            local sMsg = sDrvName or tEntry.name
            if nDrvPid and nDrvPid > 0 then sMsg = sMsg .. " (PID " .. nDrvPid .. ")" end
            syscall("kernel_log", "[PM] OK: " .. sMsg)
        else
            nFail = nFail + 1
            syscall("kernel_log", "[PM] FAIL: '" .. tEntry.name ..
                "' — status " .. tostring(nStatus))
        end
        _drainKernelLog()
        ::next_driver::
    end
    syscall("kernel_log", string.format(
        "[PM] Autoload complete: %d loaded, %d failed, %d disabled", nOk, nFail, nSkipped))
end

-- ==========================================
-- BOOT EXECUTION
-- ==========================================

__scandrvload()
process_fstab()

if env.SAFE_MODE then
    syscall("kernel_log", "[PM] SAFE MODE: Skipping autoload")
else
    process_autoload()
end

-- ==========================================
-- NETWORK INITIALIZATION
-- ==========================================
do
    local bNetInitExists = false
    pcall(function()
        local bOk, hTest = syscall("raw_component_invoke",
            vfs_state.oRootFs.address, "open", "/system/netinit.lua", "r")
        if bOk and hTest then
            syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", hTest)
            bNetInitExists = true
        end
    end)
    
    if bNetInitExists then
        syscall("kernel_log", "[PM] Spawning network initialization service...")
        local nNetPid = syscall("process_spawn", "/system/netinit.lua", 2, {
            PWD = "/",
            PATH = "/usr/commands",
        })
        if nNetPid then
            -- CRITICAL: Do NOT process_wait() here!
            -- netinit uses fs.open() which routes back to PM via
            -- syscall override. Blocking here deadlocks the system:
            --   PM sleeps (wait_pid) → netinit vfs_open signal queued
            --   → netinit sleeps (syscall) → both stuck forever.
            -- Let netinit run asynchronously. It will finish on its own.
            syscall("kernel_log", "[PM] Network init spawned as PID " ..
                tostring(nNetPid) .. " (async)")
        else
            syscall("kernel_log", "[PM] Warning: Failed to spawn netinit")
        end
    end
end

wait_with_throbber("Waiting for system stabilization...", 1.0)

-- ==========================================
-- INITIALIZE SUB-MODULES
-- ==========================================

oIoManager.Start(nDkmsPid, vfs_state.oRootFs)
oSecMonitor.Init(vfs_state.oRootFs)
oSessManager.Init(vfs_state.oRootFs)

-- ==========================================
-- REGISTRY: populate system info
-- ==========================================

pcall(function()
    if g_tSysConfig then
        syscall("reg_set_value", "@VT\\SYS\\CONFIG", "Hostname",
            g_tSysConfig.hostname or "AxisBox", "STR")
        if g_tSysConfig.logging then
            for k, v in pairs(g_tSysConfig.logging) do
                syscall("reg_set_value", "@VT\\SYS\\CONFIG",
                    "logging." .. k, tostring(v), "STR")
            end
        end
    end
    syscall("reg_set_value", "@VT\\SYS\\BOOT", "SafeMode",
        env.SAFE_MODE and "true" or "false", "STR")
    syscall("reg_set_value", "@VT\\SYS\\BOOT", "InitPath",
        env.INIT_PATH or "/bin/init.lua", "STR")
end)

-- ==========================================
-- SPAWN INIT
-- ==========================================

syscall("kernel_log", "[PM] Silence on deck. Handing off to userspace.")
syscall("kernel_set_log_mode", false)

local sInitPath = env.INIT_PATH or "/bin/init.lua"
syscall("kernel_log", "[PM] Spawning " .. sInitPath .. "...")
local nInitPid, sInitErr = syscall("process_spawn", sInitPath, 3)
if not nInitPid then
    syscall("kernel_log", "[PM] FAILED TO SPAWN INIT: " .. tostring(sInitErr))
else
    syscall("kernel_log", "[PM] Init spawned as PID " .. tostring(nInitPid))
end

-- ==========================================
-- MAIN DISPATCH LOOP
-- ==========================================

while true do
    _drainKernelLog()

    -- Drain buffered signals first
    while #g_tPmSignalBuffer > 0 do
        local tSig = table.remove(g_tPmSignalBuffer, 1)
        local nBufSender, sBufSig = tSig[1], tSig[2]
        local bp1, bp2, bp3, bp4, bp5 = tSig[3], tSig[4], tSig[5], tSig[6], tSig[7]

        if sBufSig == "syscall" then
            local tData        = bp1
            local sName        = tData.name
            local tArgs        = tData.args
            local nCaller      = tData.sender_pid
            local sSynToken    = tData.synapse_token
            local result1, result2

            -- vfs_chmod → security_monitor directly
            if sName == "vfs_chmod" then
                result1, result2 = oSecMonitor.Chmod(tArgs[1], tArgs[2], nCaller)

            -- driver_load → PM (needs signal buffering)
            elseif sName == "driver_load" then
                result1, result2 = handle_driver_load(nCaller, tArgs[1])

            else
                -- Security checks before delegating to io_manager
                if sName == "vfs_open" and tArgs[1]
                   and tArgs[1]:sub(1, 5) ~= "/dev/" then
                    if not oSecMonitor.CheckAccess(nCaller, tArgs[1], tArgs[2] or "r") then
                        syscall("signal_send", nCaller, "syscall_return", nil, "Permission denied")
                        goto buf_continue
                    end
                elseif sName == "vfs_delete" and tArgs[1]
                       and tArgs[1]:sub(1, 5) ~= "/tmp/" then
                    if not oSecMonitor.CheckAccess(nCaller, tArgs[1], "w") then
                        syscall("signal_send", nCaller, "syscall_return", nil, "Permission denied")
                        goto buf_continue
                    end
                elseif sName == "vfs_mkdir" and tArgs[1]
                       and tArgs[1]:sub(1, 5) ~= "/tmp/" then
                    if not oSecMonitor.CheckAccess(nCaller, tArgs[1], "w") then
                        syscall("signal_send", nCaller, "syscall_return", nil, "Permission denied")
                        goto buf_continue
                    end
                end

                result1, result2 = oIoManager.HandleSyscall(tData)
            end

            syscall("signal_send", nCaller, "syscall_return", result1, result2)
            ::buf_continue::

        elseif sBufSig == "os_event" then
            syscall("signal_send", nDkmsPid, "os_event", bp1, bp2, bp3, bp4, bp5)
        end
    end

    -- Pull fresh signals
    local bOk, nSender, sSignal, p1, p2, p3, p4, p5 = syscall("signal_pull")
    if bOk then
        if sSignal == "syscall" then
            local tData        = p1
            local sName        = tData.name
            local tArgs        = tData.args
            local nCaller      = tData.sender_pid
            local sSynToken    = tData.synapse_token
            local result1, result2

            if sName == "vfs_chmod" then
                result1, result2 = oSecMonitor.Chmod(tArgs[1], tArgs[2], nCaller)

            elseif sName == "driver_load" then
                result1, result2 = handle_driver_load(nCaller, tArgs[1])

            else
                -- Security checks
                if sName == "vfs_open" and tArgs[1]
                   and tArgs[1]:sub(1, 5) ~= "/dev/" then
                    if not oSecMonitor.CheckAccess(nCaller, tArgs[1], tArgs[2] or "r") then
                        syscall("signal_send", nCaller, "syscall_return", nil, "Permission denied")
                        goto main_continue
                    end
                elseif sName == "vfs_delete" and tArgs[1]
                       and tArgs[1]:sub(1, 5) ~= "/tmp/" then
                    if not oSecMonitor.CheckAccess(nCaller, tArgs[1], "w") then
                        syscall("signal_send", nCaller, "syscall_return", nil, "Permission denied")
                        goto main_continue
                    end
                elseif sName == "vfs_mkdir" and tArgs[1]
                       and tArgs[1]:sub(1, 5) ~= "/tmp/" then
                    if not oSecMonitor.CheckAccess(nCaller, tArgs[1], "w") then
                        syscall("signal_send", nCaller, "syscall_return", nil, "Permission denied")
                        goto main_continue
                    end
                end

                result1, result2 = oIoManager.HandleSyscall(tData)
            end

            syscall("signal_send", nCaller, "syscall_return", result1, result2)

        elseif sSignal == "os_event" then
            syscall("signal_send", nDkmsPid, "os_event", p1, p2, p3, p4, p5)
        end

        ::main_continue::
    end
end