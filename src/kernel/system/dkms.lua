--
-- /system/dkms.lua
-- Dynamic Kernel Module System (Buffered)
--
local syscall = syscall
local tStatus = require("errcheck")
local tDKStructs = require("shared_structs")
local oSec = require("dkms_sec")
local oDispatcher = require("driverdispatch")

syscall("kernel_log", "[DKMS] Ring 1 Driver Manager starting.")

syscall("kernel_log", "[DKMS] Ring 1 Driver Manager starting.")

-- Initialize security subsystem EAGERLY (before any driver loads)
-- This prevents a stall during the first load_driver() call.
oSec.Initialize()

local g_tDriverRegistry = {}
local g_tDeviceTree = {}
local g_tSymbolicLinks = {}
local g_tPendingIrps = {}
local g_tSignalQueue = {}

local g_tDeviceTypeCounters = {}
-- ====================================

-- Syscall Overrides
syscall("syscall_override", "dkms_create_device")
syscall("syscall_override", "dkms_create_symlink")
syscall("syscall_override", "dkms_delete_device")
syscall("syscall_override", "dkms_delete_symlink")
syscall("syscall_override", "dkms_complete_irp")
syscall("syscall_override", "dkms_register_interrupt")

syscall("syscall_override", "dkms_get_next_index")

local tSyscallHandlers = {}

function tSyscallHandlers.dkms_create_device(nCallerPid, sDeviceName)
    local pDriverObject
    for _, pObj in pairs(g_tDriverRegistry) do
        if pObj.nDriverPid == nCallerPid then
            pDriverObject = pObj;
            break
        end
    end
    if not pDriverObject then
        return nil, tStatus.STATUS_ACCESS_DENIED
    end
    if g_tDeviceTree[sDeviceName] then
        return nil, tStatus.STATUS_DEVICE_ALREADY_EXISTS
    end

    local pDeviceObject = tDKStructs.fNewDeviceObject()
    pDeviceObject.pDriverObject = pDriverObject
    pDeviceObject.sDeviceName = sDeviceName
    pDeviceObject.pNextDevice = pDriverObject.pDeviceObject
    pDriverObject.pDeviceObject = pDeviceObject
    g_tDeviceTree[sDeviceName] = pDeviceObject
    syscall("kernel_log", "[DKMS] Device '" .. sDeviceName .. "' created.")

    -- === REGISTRY: register device ===
    local tInfo = pDriverObject.tDriverInfo or {}
    local bPhysical = (tInfo.sDriverType == tDKStructs.DRIVER_TYPE_CMD)
    local sClass = bPhysical and "physical" or "virtual"
    local sDevId = syscall("reg_alloc_device_id", sClass)

    if sDevId then
        local sRegPath = "@VT\\DEV\\" .. sDevId
        syscall("reg_create_key", sRegPath)
        syscall("reg_set_value", sRegPath, "DeviceName", sDeviceName, "STR")
        syscall("reg_set_value", sRegPath, "DriverName", tInfo.sDriverName or "Unknown", "STR")
        syscall("reg_set_value", sRegPath, "DriverPID", nCallerPid, "NUM")
        syscall("reg_set_value", sRegPath, "DriverType", tInfo.sDriverType or "Unknown", "STR")
        syscall("reg_set_value", sRegPath, "DriverVersion", tInfo.sVersion or "N/A", "STR")
        syscall("reg_set_value", sRegPath, "DeviceClass", sClass, "STR")
        syscall("reg_set_value", sRegPath, "Status", "online", "STR")
        syscall("reg_set_value", sRegPath, "Ring", 2, "NUM")

        -- store the registry ID in the device object for later cleanup
        pDeviceObject.sRegistryId = sDevId
        pDeviceObject.sRegistryPath = sRegPath

        syscall("kernel_log", "[DKMS] Registered in @VT\\DEV\\" .. sDevId)
    end

    return pDeviceObject, tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_create_symlink(nCallerPid, sLinkName, sDeviceName)
    if not g_tDeviceTree[sDeviceName] then
        return tStatus.STATUS_NO_SUCH_DEVICE
    end
    g_tSymbolicLinks[sLinkName] = sDeviceName
    syscall("kernel_log", "[DKMS] Symlink '" .. sLinkName .. "' -> '" .. sDeviceName .. "' created.")

    -- === REGISTRY: store symlink on the device node ===
    local pDev = g_tDeviceTree[sDeviceName]
    if pDev and pDev.sRegistryPath then
        syscall("reg_set_value", pDev.sRegistryPath, "Symlink", sLinkName, "STR")
        -- extract friendly name from symlink: /dev/tty → tty
        local sFriendly = sLinkName:match("^/dev/(.+)$") or sLinkName
        syscall("reg_set_value", pDev.sRegistryPath, "FriendlyName", sFriendly, "STR")
    end

    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_delete_device(nCallerPid, sDeviceName)
    local pDeviceObject = g_tDeviceTree[sDeviceName]
    if not pDeviceObject then
        return tStatus.STATUS_NO_SUCH_DEVICE
    end

    -- === REGISTRY: mark offline then delete ===
    if pDeviceObject.sRegistryPath then
        syscall("reg_set_value", pDeviceObject.sRegistryPath, "Status", "offline", "STR")
        syscall("reg_delete_key", pDeviceObject.sRegistryPath)
    end

    g_tDeviceTree[sDeviceName] = nil
    pDeviceObject.pDriverObject.pDeviceObject = nil
    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_delete_symlink(nCallerPid, sLinkName)
    g_tSymbolicLinks[sLinkName] = nil
    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_complete_irp(nCallerPid, pIrp, nStatusOverride)
    if not pIrp then
        return tStatus.STATUS_INVALID_PARAMETER
    end
    if nStatusOverride then
        pIrp.tIoStatus.nStatus = nStatusOverride
    end

    if pIrp.nMajorFunction == 0x00 then -- IRP_MJ_CREATE
        local pDev = g_tDeviceTree[pIrp.sDeviceName]
        if pDev and pDev.pDriverObject then
            pIrp.tIoStatus.vInformation = pDev.pDriverObject.nDriverPid
        end
    end
    -- [[ END FIX ]]

    local bNoReply = false
    if pIrp.nFlags and type(pIrp.nFlags) == "number" then
        local nFlagVal = tDKStructs.IRP_FLAG_NO_REPLY
        local nRem = pIrp.nFlags % (nFlagVal * 2)
        if nRem >= nFlagVal then
            bNoReply = true
        end
    end

    if not bNoReply then
        syscall("signal_send", pIrp.nSenderPid, "syscall_return", pIrp.tIoStatus.nStatus, pIrp.tIoStatus.vInformation)
    end

    g_tPendingIrps[pIrp.nSenderPid] = nil
    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_register_interrupt(nCallerPid, sEventName)
    syscall("kernel_log", "[DKMS] PID " .. nCallerPid .. " registered for interrupt '" .. sEventName .. "'")
    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_get_next_index(nCallerPid, sDeviceType)
    if not sDeviceType then
        return nil, tStatus.STATUS_INVALID_PARAMETER
    end

    if not g_tDeviceTypeCounters[sDeviceType] then
        g_tDeviceTypeCounters[sDeviceType] = 0
    end

    local nIndex = g_tDeviceTypeCounters[sDeviceType]
    g_tDeviceTypeCounters[sDeviceType] = nIndex + 1

    return nIndex, tStatus.STATUS_SUCCESS
end

local function inspect_driver(sDriverPath)
    local sCode, sErr = syscall("vfs_read_file", sDriverPath)
    if not sCode then
        return nil, tStatus.STATUS_NO_SUCH_FILE
    end

    -- give the inspection sandbox access to require, 
    -- otherwise drivers calling require() at the top level will crash here.
    local tTempEnv = {
        require = require
    }

    local fChunk, sLoadErr = load(sCode, "@" .. sDriverPath, "t", tTempEnv)
    if not fChunk then
        return nil, tStatus.STATUS_INVALID_DRIVER_OBJECT
    end

    -- run the chunk. it might fail if it tries to do actual work, 
    -- but we only care if it defines g_tDriverInfo.
    pcall(fChunk)

    if type(tTempEnv.g_tDriverInfo) ~= "table" then
        return nil, tStatus.STATUS_INVALID_DRIVER_INFO
    end

    return tTempEnv.g_tDriverInfo
end

function load_driver(sDriverPath, tDriverEnv)
    syscall("kernel_log", "[DKMS] Loading: " .. sDriverPath)

    local sCode, sErr = syscall("vfs_read_file", sDriverPath)
    if not sCode then
        return tStatus.STATUS_NO_SUCH_FILE
    end

    local nStatus = oSec.fValidateDriverSignature(sCode)
    if nStatus ~= tStatus.STATUS_SUCCESS then
        return nStatus
    end

    local tTempEnv = {
        require = require
    }
    local fChunk, sLoadErr = load(sCode, "@" .. sDriverPath, "t", tTempEnv)
    if not fChunk then
        return tStatus.STATUS_INVALID_DRIVER_OBJECT
    end
    pcall(fChunk)

    local tDriverInfo = tTempEnv.g_tDriverInfo
    nStatus, sErr = oSec.fValidateDriverInfo(tDriverInfo)
    if nStatus ~= tStatus.STATUS_SUCCESS then
        return nStatus
    end

    -- ISOLATION LOGIC HERE
    -- if it's a component driver, verify we actually have a component address.
    if tDriverInfo.sDriverType == tDKStructs.DRIVER_TYPE_CMD then
        if not tDriverEnv or not tDriverEnv.address then
            syscall("kernel_log", "[DKMS] SECURITY: Blocked loading of CMD '" .. tDriverInfo.sDriverName ..
                "' without component address.")
            return tStatus.STATUS_INVALID_PARAMETER
        end
    end

    -- CMDs run at Ring 2 (Kernel Mode), same as KMDs, but with stricter init reqs.
    local nRing = (tDriverInfo.sDriverType == tDKStructs.DRIVER_TYPE_UMD) and 3 or 2
    local nPid, sSpawnErr = syscall("process_spawn", sDriverPath, nRing, tDriverEnv)
    if not nPid then
        return tStatus.STATUS_DRIVER_INIT_FAILED
    end

    local pDriverObject = tDKStructs.fNewDriverObject()
    pDriverObject.sDriverPath = sDriverPath
    pDriverObject.nDriverPid = nPid
    pDriverObject.tDriverInfo = tDriverInfo

    -- register the driver IMMEDIATELY so that it can call DkCreateDevice
    g_tDriverRegistry[sDriverPath] = pDriverObject

    syscall("signal_send", nPid, "driver_init", pDriverObject)

    while true do
        local bOk, nSenderPid, sSignalName, p1, p2, p3, p4, p5 = syscall("signal_pull")
        if bOk then
            if sSignalName == "driver_init_complete" and nSenderPid == nPid then
                local nEntryStatus = p1
                local pInitializedDriverObject = p2

                if nEntryStatus == tStatus.STATUS_SUCCESS and pInitializedDriverObject then
                    syscall("kernel_log", "[DKMS] Loaded '" .. tDriverInfo.sDriverName .. "' (PID " .. nPid .. ")")
                    g_tDriverRegistry[sDriverPath] = pInitializedDriverObject
                    -- === REGISTRY: register driver ===
                    local sDrvRegPath = "@VT\\DRV\\" .. tDriverInfo.sDriverName
                    syscall("reg_create_key", sDrvRegPath)
                    syscall("reg_set_value", sDrvRegPath, "Path", sDriverPath, "STR")
                    syscall("reg_set_value", sDrvRegPath, "PID", nPid, "NUM")
                    syscall("reg_set_value", sDrvRegPath, "Type", tDriverInfo.sDriverType or "?", "STR")
                    syscall("reg_set_value", sDrvRegPath, "LoadPriority", tDriverInfo.nLoadPriority or 0, "NUM")
                    syscall("reg_set_value", sDrvRegPath, "Version", tDriverInfo.sVersion or "N/A", "STR")
                    syscall("reg_set_value", sDrvRegPath, "Status", "loaded", "STR")
                    if tDriverInfo.sSupportedComponent then
                        syscall("reg_set_value", sDrvRegPath, "Component", tDriverInfo.sSupportedComponent, "STR")
                    end
                    return tStatus.STATUS_SUCCESS
                else
                    syscall("kernel_log", "[DKMS] Err: DriverEntry failed: " .. tostring(nEntryStatus))
                    g_tDriverRegistry[sDriverPath] = nil
                    return nEntryStatus or tStatus.STATUS_DRIVER_INIT_FAILED
                end

            elseif sSignalName == "syscall" then
                local tData = p1
                local fHandler = tSyscallHandlers[tData.name]
                if fHandler then
                    local ret1, ret2 = fHandler(tData.sender_pid, table.unpack(tData.args))
                    syscall("signal_send", tData.sender_pid, "syscall_return", ret1, ret2)
                end

            else
                table.insert(g_tSignalQueue, {nSenderPid, sSignalName, p1, p2, p3, p4, p5})
            end
        end
    end
end

-- Main Loop
while true do
    local nSenderPid, sSignalName, p1, p2, p3, p4

    -- CHECKING SIGNAL BUFFER!!!!!!
    if #g_tSignalQueue > 0 then
        local tSig = table.remove(g_tSignalQueue, 1)
        nSenderPid = tSig[1]
        sSignalName = tSig[2]
        p1 = tSig[3]
        p2 = tSig[4]
        p3 = tSig[5]
        p4 = tSig[6]
        p5 = tSig[7]
    else
        -- if buffer empty then wait
        local bOk
        bOk, nSenderPid, sSignalName, p1, p2, p3, p4, p5 = syscall("signal_pull")
        if not bOk then
            goto continue
        end
    end

    if sSignalName == "syscall" then
        local tData = p1
        local fHandler = tSyscallHandlers[tData.name]
        if fHandler then
            local ret1, ret2 = fHandler(tData.sender_pid, table.unpack(tData.args))
            syscall("signal_send", tData.sender_pid, "syscall_return", ret1, ret2)
        end

    elseif sSignalName == "vfs_io_request" then
        local pIrp = p1
        if pIrp and type(pIrp) == "table" then
            g_tPendingIrps[pIrp.nSenderPid] = pIrp
            local nDispatchStatus = oDispatcher.DispatchIrp(pIrp, g_tDeviceTree, g_tSymbolicLinks)

            if pIrp.nMajorFunction == 0x00 then -- IRP_MJ_CREATE
                local pDevice = g_tDeviceTree[pIrp.sDeviceName]
                if pDevice and pDevice.pDriverObject then
                    pIrp.tIoStatus.vInformation = pDevice.pDriverObject.nDriverPid
                end
            end

            if nDispatchStatus ~= tStatus.STATUS_PENDING then
                tSyscallHandlers.dkms_complete_irp(0, pIrp, nDispatchStatus)
            end
        end
    elseif sSignalName == "dkms_list_devices_request" then
        local nOriginalRequester = p1

        local tList = {}
        -- g_tSymbolicLinks keys are like "/dev/tty", "/dev/gpu0"
        for sLinkPath, sDeviceName in pairs(g_tSymbolicLinks) do
            -- we strip the "/dev/" prefix to get just the filename
            local sName = string.match(sLinkPath, "^/dev/(.+)$")
            if sName then
                table.insert(tList, sName)
            end
        end

        -- send the list back to PM
        syscall("signal_send", nSenderPid, "dkms_list_devices_result", nOriginalRequester, tList)

    elseif sSignalName == "load_driver_for_component" then
        local sComponentType = p1
        local sComponentAddress = p2
        local sDriverPath = "/drivers/" .. sComponentType .. ".sys.lua"
        load_driver(sDriverPath, {
            address = sComponentAddress
        })

    elseif sSignalName == "load_driver_path" then
        local sPath = p1
        -- loading via path implies generic KMD/UMD. 
        -- if the driver at sPath is a CMD, load_driver will reject it because env is empty.
        load_driver(sPath, {})

    elseif sSignalName == "load_driver_path_request" then
        local sPath = p1
        local nOriginalRequester = p2

        -- 1. inspect the driver first
        local tInfo, nInspectErr = inspect_driver(sPath)

        if not tInfo then
            -- file broken or missing
            syscall("signal_send", nSenderPid, "load_driver_result", nOriginalRequester,
                nInspectErr or tStatus.STATUS_UNSUCCESSFUL, "Unknown", -1)
            goto continue
        end

        -- 2. check for Auto-Discovery (CMD + sSupportedComponent)
        if tInfo.sDriverType == tDKStructs.DRIVER_TYPE_CMD and tInfo.sSupportedComponent then

            syscall("kernel_log", "[DKMS] Auto-discovery for type: " .. tInfo.sSupportedComponent)

            -- scan hardware
            local bOk, tList = syscall("raw_component_list", tInfo.sSupportedComponent)
            local nLoadedCount = 0
            local nLastStatus = tStatus.STATUS_NO_SUCH_DEVICE

            if bOk and tList then
                for sAddr, _ in pairs(tList) do
                    -- try to load for THIS specific address
                    -- we pass the address in the environment
                    local nSt = load_driver(sPath, {
                        address = sAddr
                    })
                    if nSt == tStatus.STATUS_SUCCESS then
                        nLoadedCount = nLoadedCount + 1
                    end
                    nLastStatus = nSt
                end
            end

            if nLoadedCount > 0 then
                local sMsg = string.format("Auto-loaded %d instances of %s", nLoadedCount, tInfo.sDriverName)
                -- return success (0) and our custom message as the "Name"
                syscall("signal_send", nSenderPid, "load_driver_result", nOriginalRequester, tStatus.STATUS_SUCCESS,
                    sMsg, 0)
            else
                -- found nothing or failed all
                syscall("signal_send", nSenderPid, "load_driver_result", nOriginalRequester, nLastStatus,
                    tInfo.sDriverName, -1)
            end

        else
            -- 3. standard Load (KMD, UMD, or manual CMD)
            -- pass empty env (CMD will fail here if not manual, which is correct security)
            local nStatus = load_driver(sPath, {})

            -- find the object to get PID
            local pObj = g_tDriverRegistry[sPath]
            local sName = tInfo.sDriverName
            local nPid = pObj and pObj.nDriverPid or -1

            syscall("signal_send", nSenderPid, "load_driver_result", nOriginalRequester, nStatus, sName, nPid)
        end

        ::continue::

    elseif sSignalName == "os_event" and p1 == "clipboard" then
        -- p2 = keyboard address, p3 = pasted text
        for _, pDriver in pairs(g_tDriverRegistry) do
            if pDriver.tDriverInfo.sDriverName == "AxisTTY" then
                syscall("signal_send", pDriver.nDriverPid, "hardware_interrupt", "clipboard", p3)
            end
        end

    elseif sSignalName == "os_event" and p1 == "key_down" then
        for _, pDriver in pairs(g_tDriverRegistry) do
            if pDriver.tDriverInfo.sDriverName == "AxisTTY" then
                syscall("signal_send", pDriver.nDriverPid, "hardware_interrupt", "key_down", p2, p3, p4)
            end
        end
    elseif sSignalName == "os_event" and p1 == "touch" then
        -- p2=screenAddr, p3=x, p4=y, p5=button, p6=player
        for _, pDriver in pairs(g_tDriverRegistry) do
            if pDriver.tDriverInfo.sDriverName == "AxisTTY" then
                syscall("signal_send", pDriver.nDriverPid, "hardware_interrupt", "touch", p3, p4, p5)
            end
        end

    elseif sSignalName == "os_event" and p1 == "drag" then
        for _, pDriver in pairs(g_tDriverRegistry) do
            if pDriver.tDriverInfo.sDriverName == "AxisTTY" then
                syscall("signal_send", pDriver.nDriverPid, "hardware_interrupt", "drag", p3, p4, p5)
            end
        end

    elseif sSignalName == "os_event" and p1 == "scroll" then
        -- p2=screenAddr, p3=x, p4=y, p5=direction
        for _, pDriver in pairs(g_tDriverRegistry) do
            if pDriver.tDriverInfo.sDriverName == "AxisTTY" then
                syscall("signal_send", pDriver.nDriverPid, "hardware_interrupt", "scroll", p5, p3, p4)
            end
        end
    end

    ::continue::
end
