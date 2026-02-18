## 12. Driver Development Guide

### 12.1 Minimal KMD Driver

This is the simplest possible driver that creates a device and handles basic I/O:

```lua
--
-- /drivers/example.sys.lua
-- Minimal KMD Example
--

local tStatus   = require("errcheck")
local oKMD      = require("kmd_api")
local tDKStructs = require("shared_structs")

-- ==========================================
-- STEP 1: Declare driver metadata (REQUIRED)
-- ==========================================
g_tDriverInfo = {
    sDriverName  = "ExampleDriver",
    sDriverType  = tDKStructs.DRIVER_TYPE_KMD,
    nLoadPriority = 400,
    sVersion     = "1.0.0",
}

local g_pDeviceObject = nil

-- ==========================================
-- STEP 2: Define IRP handlers
-- ==========================================

local function fCreate(pDeviceObject, pIrp)
    -- Called when someone opens our device
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fClose(pDeviceObject, pIrp)
    -- Called when handle is closed
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fRead(pDeviceObject, pIrp)
    local sData = "Hello from ExampleDriver!\n"
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, sData)
end

local function fWrite(pDeviceObject, pIrp)
    local sData = pIrp.tParameters.sData
    oKMD.DkPrint("ExampleDriver received: " .. tostring(sData))
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, #(sData or ""))
end

local function fDeviceControl(pDeviceObject, pIrp)
    local sMethod = pIrp.tParameters.sMethod
    local tArgs   = pIrp.tParameters.tArgs or {}

    if sMethod == "greet" then
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS,
            "Hello, " .. (tArgs[1] or "World") .. "!")
    else
        oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_NOT_IMPLEMENTED)
    end
end

-- ==========================================
-- STEP 3: DriverEntry — initialization
-- ==========================================

function DriverEntry(pDriverObject)
    oKMD.DkPrint("ExampleDriver: Initializing")

    -- Register dispatch handlers
    pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE]         = fCreate
    pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE]          = fClose
    pDriverObject.tDispatch[tDKStructs.IRP_MJ_READ]           = fRead
    pDriverObject.tDispatch[tDKStructs.IRP_MJ_WRITE]          = fWrite
    pDriverObject.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fDeviceControl

    -- Create device object
    local nStatus, pDevObj = oKMD.DkCreateDevice(pDriverObject, "\\Device\\Example0")
    if nStatus ~= tStatus.STATUS_SUCCESS then return nStatus end
    g_pDeviceObject = pDevObj

    -- Create user-facing symlink
    oKMD.DkCreateSymbolicLink("/dev/example", "\\Device\\Example0")

    oKMD.DkPrint("ExampleDriver: Ready at /dev/example")
    return tStatus.STATUS_SUCCESS
end

-- ==========================================
-- STEP 4: DriverUnload — cleanup
-- ==========================================

function DriverUnload(pDriverObject)
    oKMD.DkDeleteSymbolicLink("/dev/example")
    oKMD.DkDeleteDevice(g_pDeviceObject)
    return tStatus.STATUS_SUCCESS
end

-- ==========================================
-- STEP 5: Main event loop (REQUIRED)
-- ==========================================

while true do
    local bOk, nSenderPid, sSignalName, p1, p2 = syscall("signal_pull")
    if bOk then
        if sSignalName == "driver_init" then
            local pDriverObject = p1
            pDriverObject.fDriverUnload = DriverUnload
            local nStatus = DriverEntry(pDriverObject)
            syscall("signal_send", nSenderPid,
                "driver_init_complete", nStatus, pDriverObject)

        elseif sSignalName == "irp_dispatch" then
            local pIrp    = p1
            local fHandler = p2
            fHandler(g_pDeviceObject, pIrp)
        end
    end
end
```

### 12.2 CMD Driver (Component-Bound)

A CMD driver is bound to a specific hardware component. DKMS passes the component address via `env.address`.

```lua
g_tDriverInfo = {
    sDriverName        = "MyHardwareDriver",
    sDriverType        = tDKStructs.DRIVER_TYPE_CMD,
    nLoadPriority      = 300,
    sSupportedComponent = "my_component_type",  -- OC component type name
}

function DriverEntry(pDriverObject)
    -- Register dispatch table...

    -- CMD auto-creates device + symlink:
    local nStatus, pDevObj = oKMD.DkCreateComponentDevice(
        pDriverObject, "my_component_type")
    if nStatus ~= tStatus.STATUS_SUCCESS then return nStatus end
    g_pDeviceObject = pDevObj

    -- Get hardware proxy (guaranteed available for CMD):
    local sAddr = env.address
    local nProxySt, oProxy = oKMD.DkGetHardwareProxy(sAddr)
    pDevObj.pDeviceExtension.oProxy = oProxy

    return tStatus.STATUS_SUCCESS
end
```

`DkCreateComponentDevice` automatically:
1. Queries DKMS for the next available index for this component type.
2. Creates `\\Device\\<type>_<short_addr>`.
3. Creates `/dev/<type>_<short_addr>_<index>`.
4. Stores the symlink name in `pDeviceExtension.sAutoSymlink`.

### 12.3 Using a Driver from User Space

```lua
local fs = require("filesystem")

-- Open device
local hDev = fs.open("/dev/example", "r")

-- Read
local sData = fs.read(hDev, math.huge)
print(sData)  -- "Hello from ExampleDriver!"

-- Device control (ioctl)
local bOk, sResult = fs.deviceControl(hDev, "greet", {"AxisOS"})
print(sResult)  -- "Hello, AxisOS!"

-- Close
fs.close(hDev)
```

### 12.4 Hardware Interrupt Registration

Drivers that need hardware events (key presses, scroll, etc.) register with DKMS:

```lua
oKMD.DkRegisterInterrupt("key_down")
oKMD.DkRegisterInterrupt("scroll")
```

DKMS forwards matching OC events to the driver as `"hardware_interrupt"` signals:

```lua
elseif sig == "hardware_interrupt" and p1 == "key_down" then
    local ch, code = p3, p4
    processKey(ch, code)
end
```

---