# Kernel Component Mode Driver (KCMD) Reference

## 1. Overview

The **Kernel Component Mode Driver (KCMD)** is a specialized extension of the standard Kernel-Mode Driver Framework (KMDF). While standard KMDs are typically singletons responsible for managing shared resources (like the TTY) or virtual devices (like `/dev/null`), KCMDs are designed specifically to interface with physical OpenComputers components attached to the system bus.

The KCMD architecture relies on a **One-Process-Per-Component** model. When the Dynamic Kernel Module System (DKMS) encounters a KCMD, it does not load it as a single instance. Instead, it enumerates the hardware bus for components matching the driver's signature and spawns a unique, isolated driver process for each matching physical component.

### 1.1. KMD vs. KCMD Architecture

| Feature | Standard KMD | Component Mode (KCMD) |
| :--- | :--- | :--- |
| **Driver Type** | `DRIVER_TYPE_KMD` | `DRIVER_TYPE_CMD` |
| **Cardinality** | Singleton (usually one process per system). | Multi-Instance (one process per physical component). |
| **Loading Mechanism** | Explicit load via `insmod` or autoload. | **Mass-Load / Auto-Discovery** triggered by `insmod`. |
| **Hardware Binding** | Driver must manually scan or be hardcoded. | Address is **injected** into the process environment by DKMS. |
| **Device Naming** | Manual (e.g., `\Device\Gpu0`). | **Automated** (e.g., `\Device\iter_a1b2c3`). |
| **Use Case** | System services, virtual devices, singleton hardware. | Mass-produced hardware (e.g., Reactors, Capacitor Banks). |

## 2. The Mass-Load and Auto-Discovery Mechanism

The defining feature of the KCMD framework is the "Mass-Load" sequence managed by the DKMS. This sequence ensures that drivers do not need to implement complex iteration logic to handle multiple devices.

### 2.1. The Enumeration Sequence

When a request is made to load a driver file (e.g., `/drivers/capacitor.sys.lua`), the DKMS performs the following steps:

1.  **Pre-Inspection:** The DKMS loads the driver's metadata table (`g_tDriverInfo`) in a temporary sandbox.
2.  **Type Identification:** If `sDriverType` is set to `DRIVER_TYPE_CMD`, the DKMS looks for the `sSupportedComponent` field (e.g., `"capacitor_bank"`).
3.  **Bus Scanning:** The DKMS executes a privileged `raw_component_list` syscall, filtering for the component type specified in `sSupportedComponent`.
4.  **Instantiation Loop:** For *every* unique address found on the bus:
    *   The DKMS prepares a custom environment table.
    *   The specific component address is injected into `env.address`.
    *   A new process is spawned from the driver source code with Ring 2 privileges.
    *   The process is registered with the DKMS using the standard `driver_init` handshake.

### 2.2. Environment Injection

Unlike standard drivers, a KCMD process is guaranteed to have the `address` field populated in its global `env` table upon startup.

```lua
-- Inside a KCMD process
local sMyComponentAddress = env.address
-- sMyComponentAddress will contain "c7bd352c-..." specific to THIS instance.
```

> **Note:** A KCMD attempting to load without an address in `env` (e.g., if manually spawned via `process_spawn` without the correct parameters) should fail its validation check in `DriverEntry` or will be rejected by the DKMS security subsystem before execution.

## 3. Developing a KCMD: Step-by-Step

This section details the implementation of a driver for a hypothetical component, the "Flux Capacitor" (`flux_cap`).

### Step 1: Metadata Definition

The driver must explicitly declare itself as a CMD and specify the OpenComputers component name it supports.

```lua
local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
  sDriverName = "AxisFlux",
  sDriverType = tDKStructs.DRIVER_TYPE_CMD, -- Critical: Declares KCMD mode
  nLoadPriority = 300,
  sVersion = "1.0.0",
  
  -- Critical: The OC component type string. 
  -- DKMS uses this to scan the bus.
  sSupportedComponent = "flux_cap" 
}

local g_pDeviceObject = nil
```

### Step 2: The Driver Entry Point

In `DriverEntry`, the KCMD deviates from the standard KMD pattern. Instead of manually choosing a device name (which would cause collisions if multiple Flux Capacitors are present), it uses the `DkCreateComponentDevice` helper.

```lua
function DriverEntry(pDriverObject)
  oKMD.DkPrint("AxisFlux: Initializing instance.")
  
  -- 1. Setup Dispatch Table (Standard KMD logic)
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE] = fFluxDispatchCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fFluxDispatchClose
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fFluxDispatchControl
  
  -- 2. Auto-Create Device and Symlink
  -- The second argument "flux" is the prefix for the device name.
  -- DKMS will generate names like "\Device\flux_a1b2c3"
  local nStatus, pDeviceObj = oKMD.DkCreateComponentDevice(pDriverObject, "flux")

  if nStatus ~= tStatus.STATUS_SUCCESS then 
    oKMD.DkPrint("AxisFlux: Failed to create auto-device.")
    return nStatus 
  end
  g_pDeviceObject = pDeviceObj
  
  -- 3. Acquire Hardware Proxy
  -- The address is GUARANTEED by the DKMS Mass-Load logic.
  local sMyAddress = env.address
  local nProxyStatus, oProxy = oKMD.DkGetHardwareProxy(sMyAddress)
  
  if nProxyStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkPrint("AxisFlux: Failed to bind to hardware at " .. tostring(sMyAddress))
    return nProxyStatus
  end
  
  -- 4. Store State in Device Extension
  g_pDeviceObject.pDeviceExtension.oProxy = oProxy
  g_pDeviceObject.pDeviceExtension.sAddress = sMyAddress
  
  oKMD.DkPrint("AxisFlux: Online for " .. sMyAddress:sub(1,8))
  return tStatus.STATUS_SUCCESS
end
```

### Step 3: Device Naming Strategy

The `DkCreateComponentDevice` API uses a deterministic naming strategy to ensure uniqueness and predictability.

Given a component type `flux` and an address `5980c87d-xxxx...`:

1.  **Internal Device Name:** `\Device\flux_5980c8`
    *   Constructed from the type prefix and the first 6 characters of the UUID.
2.  **Symbolic Link:** `/dev/flux_5980c8_0`
    *   Constructed from the type prefix, partial UUID, and a collision index (incremented by DKMS if multiple devices share the same prefix/short-uuid combination, though unlikely with UUIDs).

This allows user-space scripts to easily identify specific devices if they know the UUID, or iterate through `/dev/` looking for the `flux_` prefix.

### Step 4: Implementing Device Control

Interaction with KCMDs is primarily done via `IRP_MJ_DEVICE_CONTROL` (mapped to `component.invoke`).

```lua
local function fFluxDispatchDeviceControl(pDeviceObject, pIrp)
  local tParams = pIrp.tParameters
  local sMethod = tParams.sMethod
  local tArgs = tParams.tArgs or {}
  
  -- Retrieve the specific proxy for THIS instance
  local oProxy = pDeviceObject.pDeviceExtension.oProxy
  
  if not oProxy then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_DEVICE_NOT_READY)
    return
  end
  
  -- Invoke the hardware method safely
  local bIsOk, result1, result2 = pcall(oProxy[sMethod], table.unpack(tArgs))
  
  if bIsOk then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, {result1, result2})
  else
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, result1) -- result1 contains error
  end
end
```

### Step 5: Unloading Logic

The unload routine must clean up the automatically generated resources. The `pDeviceExtension` contains the path to the auto-generated symlink, stored by `DkCreateComponentDevice` under the key `sAutoSymlink`.

```lua
function DriverUnload(pDriverObject)
  -- 1. Delete the Symlink
  if g_pDeviceObject and g_pDeviceObject.pDeviceExtension.sAutoSymlink then
     oKMD.DkDeleteSymbolicLink(g_pDeviceObject.pDeviceExtension.sAutoSymlink)
  end
  
  -- 2. Delete the Device Object
  oKMD.DkDeleteDevice(g_pDeviceObject)
  
  return tStatus.STATUS_SUCCESS
end
```

## 4. User-Space Interaction

To interact with a KCMD from user space (e.g., `init.lua` or a shell script), the application must locate the generated `/dev/` entry.

### Example: Iterating all Flux Capacitors

```lua
local fs = require("filesystem")

-- 1. List /dev to find all flux devices
local tList = fs.list("/dev")
for _, sName in ipairs(tList) do
   if sName:match("^flux_") then
      print("Found Flux Capacitor: " .. sName)
      
      -- 2. Open the device
      local hDevice = fs.open("/dev/" .. sName, "r")
      
      -- 3. Invoke a method (e.g., "getFlow")
      -- This sends an IRP_MJ_DEVICE_CONTROL to the specific driver process
      -- responsible for this specific hardware component.
      local bOk, tRes = fs.deviceControl(hDevice, "getFlow")
      
      if bOk then
         print("  Flow Rate: " .. tostring(tRes[1]))
      end
      
      fs.close(hDevice)
   end
end
```

## 5. Summary of KCMD Benefits

1.  **Isolation:** If one Flux Capacitor malfunctions and causes its driver process to crash (e.g., due to a malformed hardware response), only that specific driver instance dies. Other capacitors (managed by separate processes) remain operational.
2.  **Scalability:** The driver developer writes code for *one* device. The DKMS scales it to *n* devices automatically.
3.  **Simplicity:** No complex tables mapping UUIDs to internal states are required inside the driver. `env.address` and `g_pDeviceObject` are always 1:1 mapped to the running process.