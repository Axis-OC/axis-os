--
-- /lib/io_manager.lua
-- AxisOS I/O Manager — VFS open/read/write/close/list/mkdir/delete + device dispatch
-- Split from pipeline_manager.lua (Feature 5)
--

local nMyPid = syscall("process_get_pid")
local nDkmsPid = nil

syscall("syscall_override", "vfs_open")
syscall("syscall_override", "vfs_read")
syscall("syscall_override", "vfs_write")
syscall("syscall_override", "vfs_close")
syscall("syscall_override", "vfs_list")
syscall("syscall_override", "vfs_delete")
syscall("syscall_override", "vfs_mkdir")
syscall("syscall_override", "vfs_device_control")
syscall("syscall_override", "driver_load")

local OB_ACCESS_READ  = 0x0001
local OB_ACCESS_WRITE = 0x0002
local OB_ACCESS_DEVCTL = 0x0008

local g_oRootFs = nil


-- ==========================================
-- RING ESCALATION DETECTION
-- Validates argument types before processing.
-- Catches metamethod exploitation attempts.
-- ==========================================

local function fValidateStringArg(v, sArgName)
    if type(v) ~= "string" then
        local sType = type(v)
        syscall("kernel_log", string.format(
            "[IO_MGR] !! RING ESCALATION ATTEMPT: %s is %s (expected string) — PID %d",
            sArgName, sType, nMyPid))
        -- Notify PatchGuard
        pcall(function()
            syscall("kernel_log",
                "[SEC] STATUS_RING_ESCALATION_TYPE_MISMATCH: " ..
                sArgName .. " received " .. sType ..
                " — possible metamethod injection")
        end)
        return false, "TYPE_MISMATCH: " .. sArgName .. " must be string, got " .. sType
    end
    return true
end

-- ==========================================
-- SAFE HANDLER WRAPPER
-- Wraps all VFS handlers in pcall to catch
-- nil method calls from metamethod exploits.
-- ==========================================

local function fSafeHandler(sName, fHandler, ...)
    local tResults = table.pack(pcall(fHandler, ...))
    if not tResults[1] then
        local sErr = tostring(tResults[2] or "unknown")
        -- Detect nil method call pattern (metamethod exploitation)
        if sErr:find("attempt to call a nil value") or
           sErr:find("attempt to index a nil value") or
           sErr:find("attempt to call a table value") then
            syscall("kernel_log", string.format(
                "[IO_MGR] ╔══ RING ESCALATION CAUGHT ══╗"))
            syscall("kernel_log", string.format(
                "[IO_MGR] ║ Syscall: %-18s ║", sName))
            syscall("kernel_log", string.format(
                "[IO_MGR] ║ Error: %-20s ║", sErr:sub(1,20)))
            syscall("kernel_log", string.format(
                "[IO_MGR] ╚═════════════════════════════╝"))
            return nil, "RING_ESCALATION_BLOCKED: " .. sErr
        end
        -- Other errors: still return safely (no kernel panic)
        syscall("kernel_log", "[IO_MGR] Handler '" .. sName .. "' error: " .. sErr)
        return nil, sErr
    end
    return table.unpack(tResults, 2, tResults.n)
end

local function fResolveObject(nCallerPid, sSynapseToken, vHandle, nAccess)
    local pObj, nSt = syscall("ob_reference_by_handle", nCallerPid, vHandle, nAccess, sSynapseToken)
    if not pObj then return nil, "Handle invalid or access denied" end
    return pObj
end

local function fResolveDeviceName(sPath)
    if sPath == "/dev/tty" then return "\\Device\\TTY0" end
    if sPath == "/dev/gpu0" then return "\\Device\\Gpu0" end
    return sPath
end

-- Wait for DKMS to respond
local function wait_for_dkms()
    while true do
        local bOk, nSender, sSig, p1, p2 = syscall("signal_pull")
        if bOk then
            if sSig == "syscall_return" and nSender == nDkmsPid then
                return p1, p2
            elseif sSig == "os_event" then
                syscall("signal_send", nDkmsPid, "os_event", p1, p2)
            end
        end
    end
end

local function sendDeviceCreate(sDevName)
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_CREATE)
    pIrp.sDeviceName = sDevName
    pIrp.nSenderPid = nMyPid
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    return wait_for_dkms()
end

local function sendDeviceWrite(sDevName, nDrvPid, sData)
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_WRITE)
    pIrp.sDeviceName = sDevName
    pIrp.nSenderPid = nMyPid
    pIrp.tParameters.sData = sData
    if sDevName == "\\Device\\TTY0" then
        pIrp.nFlags = tDKStructs.IRP_FLAG_NO_REPLY
        syscall("signal_send", nDrvPid, "irp_dispatch", pIrp)
        return true, #sData
    end
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    return wait_for_dkms()
end

local function sendDeviceRead(sDevName)
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_READ)
    pIrp.sDeviceName = sDevName
    pIrp.nSenderPid = nMyPid
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    return wait_for_dkms()
end

local function sendDeviceClose(sDevName)
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_CLOSE)
    pIrp.sDeviceName = sDevName
    pIrp.nSenderPid = nMyPid
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    wait_for_dkms()
end

local function sendDeviceControl(sDevName, sMethod, tArgs)
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_DEVICE_CONTROL)
    pIrp.sDeviceName = sDevName
    pIrp.nSenderPid = nMyPid
    pIrp.tParameters.sMethod = sMethod
    pIrp.tParameters.tArgs = tArgs or {}
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    return wait_for_dkms()
end

-- ==========================================
-- ENSURE PARENT DIRECTORIES EXIST
-- Called before opening a file for writing.
-- Creates each missing segment of the path.
-- ==========================================

local function fEnsureParentDirs(sPath)
    if not g_oRootFs then return end
    local sParent = sPath:match("^(.+)/[^/]+$")
    if not sParent or sParent == "" then return end

    -- Quick check: does the parent already exist?
    local bCheckOk, bIsDir = syscall("raw_component_invoke",
        g_oRootFs.address, "isDirectory", sParent)
    if bCheckOk and bIsDir then return end  -- parent exists, nothing to do

    -- Walk path segments and create each missing directory
    local sBuilt = ""
    for sSeg in sParent:gmatch("[^/]+") do
        sBuilt = sBuilt .. "/" .. sSeg
        -- makeDirectory is idempotent (returns false if already exists)
        syscall("raw_component_invoke", g_oRootFs.address, "makeDirectory", sBuilt)
    end
end

-- ==========================================
-- VFS HANDLERS
-- ==========================================

local tHandlers = {}

function tHandlers.vfs_open(nSenderPid, sSynapseToken, sPath, sMode)
    local tBody = { sPath = sPath, sMode = sMode }

    local bValid, sValErr = fValidateStringArg(sPath, "sPath")
    if not bValid then return nil, sValErr end
    if sMode ~= nil then
        bValid, sValErr = fValidateStringArg(sMode, "sMode")
        if not bValid then return nil, sValErr end
    end

    if sPath:sub(1, 5) == "/dev/" then
        local sDevName = fResolveDeviceName(sPath)
        local nSt, nDrvPid = sendDeviceCreate(sDevName)
        if nSt ~= 0 then return nil, "Device open failed" end
        tBody.sCategory = "device"
        tBody.sDeviceName = sDevName
        tBody.nDriverPid = nDrvPid
    else
        -- For write/append modes, ensure parent directories exist
        -- before attempting to open.  This fixes file creation failures
        -- when the parent directory hasn't been created yet (e.g. /root,
        -- /log, /vbl on first boot).
        if sMode == "w" or sMode == "a" then
            fEnsureParentDirs(sPath)
        end

        local bOk, hRaw = syscall("raw_component_invoke", g_oRootFs.address, "open", sPath, sMode)
        if not hRaw then return nil, "Cannot open file: " .. tostring(sPath) end
        tBody.sCategory = "file"
        tBody.hRawHandle = hRaw
    end

    local pObj = syscall("ob_create_object", "IoFileObject", tBody)
    if not pObj then return nil, "ObCreateObject failed" end

    local nAccess = OB_ACCESS_READ
    if sMode == "w" or sMode == "a" then nAccess = OB_ACCESS_WRITE end
    if sMode == "rw" then nAccess = OB_ACCESS_READ + OB_ACCESS_WRITE end
    nAccess = nAccess + OB_ACCESS_DEVCTL

    local sToken = syscall("ob_create_handle", nSenderPid, pObj, nAccess, sSynapseToken)
    if not sToken then return nil, "ObCreateHandle failed" end

    if sPath == "/dev/tty" then
        if sMode == "r" then
            if not syscall("ob_get_standard_handle", nSenderPid, -10) then
                syscall("ob_set_standard_handle", nSenderPid, -10, sToken)
            end
        end
        if sMode == "w" or sMode == "rw" then
            if not syscall("ob_get_standard_handle", nSenderPid, -11) then
                syscall("ob_set_standard_handle", nSenderPid, -11, sToken)
            end
            if not syscall("ob_get_standard_handle", nSenderPid, -12) then
                syscall("ob_set_standard_handle", nSenderPid, -12, sToken)
            end
        end
    end
    return true, sToken
end

function tHandlers.vfs_write(nSenderPid, sSynapseToken, vHandle, sData)
    local pObj, sErr = fResolveObject(nSenderPid, sSynapseToken, vHandle, OB_ACCESS_WRITE)
    if not pObj then return nil, sErr end
    local b = pObj.pBody
    if b.sCategory == "device" then
        return sendDeviceWrite(b.sDeviceName, b.nDriverPid, sData)
    else
        return syscall("raw_component_invoke", g_oRootFs.address, "write", b.hRawHandle, sData)
    end
end

function tHandlers.vfs_read(nSenderPid, sSynapseToken, vHandle, nCount)
    local pObj, sErr = fResolveObject(nSenderPid, sSynapseToken, vHandle, OB_ACCESS_READ)
    if not pObj then return nil, sErr end
    local b = pObj.pBody
    if b.sCategory == "device" then
        return sendDeviceRead(b.sDeviceName)
    else
        local r1, r2 = syscall("raw_component_invoke", g_oRootFs.address, "read", b.hRawHandle, nCount)
        if type(r2) == "boolean" then r2 = nil end
        return r1, r2
    end
end

function tHandlers.vfs_close(nSenderPid, sSynapseToken, vHandle)
    local pObj, sErr = fResolveObject(nSenderPid, sSynapseToken, vHandle, 0)
    if not pObj then return nil end
    local b = pObj.pBody
    if b.sCategory == "device" then
        sendDeviceClose(b.sDeviceName)
    elseif b.hRawHandle then
        syscall("raw_component_invoke", g_oRootFs.address, "close", b.hRawHandle)
    end
    syscall("ob_close_handle", nSenderPid, vHandle)
    return true
end

function tHandlers.vfs_list(nSenderPid, sPath)
    local sClean = sPath
    if #sClean > 1 and sClean:sub(-1) == "/" then sClean = sClean:sub(1, -2) end
    if sClean == "/dev" then
        syscall("signal_send", nDkmsPid, "dkms_list_devices_request", nSenderPid)
        while true do
            local bOk, nSender, sSig, p1, p2 = syscall("signal_pull")
            if bOk and nSender == nDkmsPid and sSig == "dkms_list_devices_result" then
                return true, p2
            end
        end
    end
    local bOk, tList = syscall("raw_component_invoke", g_oRootFs.address, "list", sPath)
    return bOk and true or nil, tList
end

function tHandlers.vfs_delete(nSenderPid, sPath)
    if not sPath or sPath == "/" or sPath:sub(1,5) == "/dev/" then
        return nil, "Cannot delete"
    end
    local bOk, sR = syscall("raw_component_invoke", g_oRootFs.address, "remove", sPath)
    return bOk and true or nil, tostring(sR)
end

function tHandlers.vfs_mkdir(nSenderPid, sPath)
    if sPath:sub(1, 5) == "/dev/" then return nil, "Cannot mkdir in /dev" end
    -- FIX: Ensure parent directories exist for mkdir too
    fEnsureParentDirs(sPath)
    local bOk, sR = syscall("raw_component_invoke", g_oRootFs.address, "makeDirectory", sPath)
    return bOk and true or nil, tostring(sR)
end

function tHandlers.vfs_device_control(nSenderPid, sSynapseToken, vHandle, sMethod, tArgs)
    local pObj, sErr = fResolveObject(nSenderPid, sSynapseToken, vHandle, OB_ACCESS_DEVCTL)
    if not pObj then return nil, sErr end
    local b = pObj.pBody
    if b.sCategory ~= "device" then return nil, "Not a device" end
    return sendDeviceControl(b.sDeviceName, sMethod, tArgs)
end

function tHandlers.vfs_chmod(nSenderPid, sPath, nMode)
    -- Delegate to security_monitor
    return syscall("sec_chmod", sPath, nMode, nSenderPid)
end

function tHandlers.driver_load(nSenderPid, sPath)
    syscall("signal_send", nDkmsPid, "load_driver_path_request", sPath, nSenderPid)
    while true do
        local bOk, nSender, sSig, p1, p2, p3, p4 = syscall("signal_pull")
        if bOk and nSender == nDkmsPid and sSig == "load_driver_result" then
            if p2 == 0 then return true, p3 else return nil, "Load failed: " .. tostring(p2) end
        end
    end
end

-- ==========================================
-- INITIALIZATION
-- ==========================================

local oIoM = {}

function oIoM.Start(nDkms, oRootFs)
    nDkmsPid = nDkms
    g_oRootFs = oRootFs
    syscall("kernel_log", "[IO_MGR] I/O Manager started (PID " .. nMyPid .. ")")
end

function oIoM.HandleSyscall(tData)
    local sName = tData.name
    local tArgs = tData.args
    local nCaller = tData.sender_pid
    local sSynToken = tData.synapse_token
    local fH = tHandlers[sName]
    if not fH then return nil, "Unknown VFS op: " .. sName end

    if sName == "vfs_open" then
        return fSafeHandler(sName, fH, nCaller, sSynToken, tArgs[1], tArgs[2])
    elseif sName == "vfs_write" then
        return fSafeHandler(sName, fH, nCaller, sSynToken, tArgs[1], tArgs[2])
    elseif sName == "vfs_read" then
        return fSafeHandler(sName, fH, nCaller, sSynToken, tArgs[1], tArgs[2])
    elseif sName == "vfs_close" then
        return fSafeHandler(sName, fH, nCaller, sSynToken, tArgs[1])
    elseif sName == "vfs_list" then
        return fSafeHandler(sName, fH, nCaller, tArgs[1])
    elseif sName == "vfs_delete" then
        return fSafeHandler(sName, fH, nCaller, tArgs[1])
    elseif sName == "vfs_mkdir" then
        return fSafeHandler(sName, fH, nCaller, tArgs[1])
    elseif sName == "vfs_chmod" then
        return fSafeHandler(sName, fH, nCaller, tArgs[1], tArgs[2])
    elseif sName == "vfs_device_control" then
        return fSafeHandler(sName, fH, nCaller, sSynToken, tArgs[1], tArgs[2], tArgs[3])
    elseif sName == "driver_load" then
        return fSafeHandler(sName, fH, nCaller, tArgs[1])
    end
    return nil, "Unhandled"
end

return oIoM