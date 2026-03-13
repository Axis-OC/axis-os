--
-- /system/lib/dk/shared_structs.lua
-- v2: Device stack support (filter drivers)
--

local oDK = {}

oDK.IRP_MJ_CREATE = 0x00
oDK.IRP_MJ_CLOSE = 0x02
oDK.IRP_MJ_READ = 0x03
oDK.IRP_MJ_WRITE = 0x04
oDK.IRP_MJ_DEVICE_CONTROL = 0x0E

-- GPU Extension IRP types (GX_AX)
oDK.IRP_MJ_GPU_PRESENT       = 0x10
oDK.IRP_MJ_GPU_CMD_SUBMIT    = 0x11
oDK.IRP_MJ_GPU_FENCE_WAIT    = 0x12
oDK.IRP_MJ_GPU_BUFFER_ALLOC  = 0x13

-- Async I/O flags
oDK.IRP_FLAG_ASYNC_COMPLETION = 0x20  -- route completion through IOCP
oDK.IRP_FLAG_FENCE_ON_COMPLETE = 0x40  -- auto-signal fence when IRP completes

oDK.DRIVER_TYPE_KMD = "KernelModeDriver"
oDK.DRIVER_TYPE_UMD = "UserModeDriver"
oDK.DRIVER_TYPE_CMD = "ComponentModeDriver"

oDK.IRP_FLAG_NO_REPLY = 0x10

function oDK.fNewDriverObject()
  return {
    sDriverPath = nil,
    nDriverPid = nil,
    pDeviceObject = nil,
    fDriverUnload = nil,
    tDispatch = {},
    tDriverInfo = {},
  }
end

function oDK.fNewDeviceObject()
  return {
    pDriverObject = nil,
    pNextDevice = nil,
    sDeviceName = nil,
    pDeviceExtension = {},
    nFlags = 0,
    pAttachedDevice = nil,   -- device attached ON TOP of this one (filter above us)
    pLowerDevice = nil,      -- device we are attached TO (function driver below us)
    pTopOfStack = nil,       -- cached pointer to top of stack (updated on attach/detach)
  }
end

function oDK.fNewIrp(nMajorFunction)
  return {
    nMajorFunction = nMajorFunction,
    pDeviceObject = nil,
    tParameters = {},
    tIoStatus = { nStatus = 0, vInformation = nil },
    nSenderPid = nil,
    nFlags = 0,
    pCurrentDevice = nil,      -- current device in stack (tracks IRP position)
    tCompletionStack = {},     -- stack of {fCompletion, pDeviceObject} for unwind
    nStackLocation = 0,        -- current index in device stack
  }
end

function oDK.fGetTopOfStack(pDeviceObject)
    if not pDeviceObject then return nil end
    local pTop = pDeviceObject
    while pTop.pAttachedDevice do
        pTop = pTop.pAttachedDevice
    end
    return pTop
end

return oDK