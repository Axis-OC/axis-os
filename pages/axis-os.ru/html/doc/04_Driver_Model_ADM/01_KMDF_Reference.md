
# KMDF API Reference

---

### `oKMD.DkPrint`

Prints a message to the kernel's primary diagnostic log.

**Synopsis**
```lua
oKMD.DkPrint(message)
```

**Parameters**
- `message` (`string`): The diagnostic message to be logged.

**Remarks**
This function is a wrapper around the `kernel_log` syscall. It should be used by drivers for all diagnostic output during development and operation. Messages are prefixed with `[DK]` to distinguish them from other kernel messages.

---

### `oKMD.DkCreateDevice`

Creates a device object.

**Synopsis**
```lua
local nStatus, pDeviceObject = oKMD.DkCreateDevice(pDriverObject, sDeviceName)
```

**Parameters**
- `pDriverObject` (`table`): A pointer to the driver's `DRIVER_OBJECT`.
- `sDeviceName` (`string`): The desired canonical name for the device. This name must be unique within the `\Device\` namespace (e.g., `\Device\FusionReactor0`).

**Return Values**
- `nStatus` (`number`): A `STATUS_*` code indicating the result of the operation. `STATUS_SUCCESS` on success.
- `pDeviceObject` (`table`): On success, a pointer to the newly created `DEVICE_OBJECT`. On failure, `nil`.

**Remarks**
This function is the primary mechanism for a driver to declare a new device to the I/O Manager (DKMS). The DKMS allocates the device object, initializes its system-owned fields (`pDriverObject`, `sDeviceName`), and links it into the driver's device list.

---

### `oKMD.DkCreateSymbolicLink`

Creates a symbolic link between a user-visible VFS path and a canonical device name.

**Synopsis**
```lua
local nStatus = oKMD.DkCreateSymbolicLink(sLinkName, sDeviceName)
```

**Parameters**
- `sLinkName` (`string`): The desired user-visible path in the VFS (e.g., `/dev/iter0`).
- `sDeviceName` (`string`): The canonical device name to which the link should point (e.g., `\Device\FusionReactor0`). This must match the name used in `DkCreateDevice`.

**Return Values**
- `nStatus` (`number`): `STATUS_SUCCESS` on success, or an appropriate error code on failure.

**Remarks**
This function makes a device accessible to user-space applications. Without a symbolic link, a device object is known only to the I/O system and cannot be opened from an application.

---

### `oKMD.DkCompleteRequest`

Completes an I/O Request Packet (IRP) and sends it back to the I/O Manager.

**Synopsis**
```lua
oKMD.DkCompleteRequest(pIrp, nStatus, vInformation)
```

**Parameters**
- `pIrp` (`table`): The IRP that is being completed.
- `nStatus` (`number`): The final status code for the operation (e.g., `STATUS_SUCCESS`, `STATUS_DEVICE_BUSY`).
- `vInformation` (`any`): The final information value for the operation. The meaning of this value is IRP-specific. For read/write operations, it is the number of bytes transferred.

**Remarks**
This is one of the most critical functions in the KMDF. **Every IRP that a driver receives must eventually be completed via this function.** Failure to complete an IRP will result in the originating user-space process blocking indefinitely. This function populates the `pIrp.tIoStatus` block and then makes a `dkms_complete_irp` syscall to notify the DKMS that the request is finished.

---

### `oKMD.DkGetHardwareProxy`

Retrieves a raw proxy object for a hardware component.

**Synopsis**
```lua
local nStatus, oProxy = oKMD.DkGetHardwareProxy(sAddress)
```

**Parameters**
- `sAddress` (`string`): The UUID address of the hardware component.

**Return Values**
- `nStatus` (`number`): `STATUS_SUCCESS` on success.
- `oProxy` (`table`): On success, a raw component proxy object. On failure, an error message.

**Remarks**
This function is a wrapper around the `raw_component_proxy` syscall. It is a privileged operation available only to KMDs, providing the direct hardware access necessary to implement driver logic.

---

### `oKMD.DkDeleteDevice`

Deletes a device object that was previously created by `DkCreateDevice`.

**Synopsis**
```lua
local nStatus = oKMD.DkDeleteDevice(pDeviceObject)
```

**Parameters**
- `pDeviceObject` (`table`): A pointer to the `DEVICE_OBJECT` to be deleted.

**Return Values**
- `nStatus` (`number`): `STATUS_SUCCESS` on success, or an appropriate error code on failure.

**Remarks**
This function is a critical part of a driver's unload routine. It removes the device object from the I/O Manager's device tree and unlinks it from the parent driver's device list. Before calling this function, a driver **must** have already deleted any symbolic links that point to this device object by calling `DkDeleteSymbolicLink`. Failure to do so will leave a dangling link in the VFS namespace.

---

### `oKMD.DkDeleteSymbolicLink`

Deletes a symbolic link that was previously created by `DkCreateSymbolicLink`.

**Synopsis**
```lua
local nStatus = oKMD.DkDeleteSymbolicLink(sLinkName)
```

**Parameters**
- `sLinkName` (`string`): The user-visible VFS path of the symbolic link to delete (e.g., `/dev/tty`).

**Return Values**
- `nStatus` (`number`): `STATUS_SUCCESS` on success, or an appropriate error code on failure.

**Remarks**
This function removes a device's name from the user-visible VFS namespace, making it inaccessible to applications via that path. This function must be called in a driver's `DriverUnload` routine for every symbolic link it created, and it must be called **before** calling `DkDeleteDevice` for the corresponding device object.

---

### `oKMD.DkRegisterInterrupt`

Registers the calling driver to receive notifications for a specific raw hardware event.

**Synopsis**
```lua
local nStatus = oKMD.DkRegisterInterrupt(sEventName)
```

**Parameters**
- `sEventName` (`string`): The name of the raw host event to subscribe to (e.g., `"key_down"`, `"component_added"`).

**Return Values**
- `nStatus` (`number`): `STATUS_SUCCESS` on success, or an appropriate error code on failure.

**Remarks**
This function provides the foundation for event-driven I/O. The driver's PID is registered with the DKMS as a listener for the specified event. When the kernel forwards a raw `os_event` to the DKMS, the DKMS will dispatch it as a `hardware_interrupt` signal to all drivers that have registered for that event. This allows a driver to process hardware events asynchronously without polling. This is the preferred mechanism for handling input devices, component hot-plugging, and other asynchronous hardware notifications.

### `oKMD.DkCreateComponentDevice`

Helper function for **CMD** drivers to auto-generate device names and symlinks based on their bound component address.

**Synopsis**
```lua
local nStatus, pDeviceObject = oKMD.DkCreateComponentDevice(pDriverObject, sDeviceTypeName)
```

**Parameters**
- `pDriverObject`: The driver object passed to `DriverEntry`.
- `sDeviceTypeName` (`string`): A short name for the device type (e.g., `"iter"`).

**Return Values**
- `nStatus`: `STATUS_SUCCESS` on success.
- `pDeviceObject`: The created device object.

**Remarks**
This function automates the naming convention for drivers that handle multiple hardware instances.
1. It verifies the driver has a component address in its environment (injected by DKMS during auto-discovery).
2. It generates an internal name: `\Device\<Type>_<ShortAddr>` (e.g., `\Device\iter_a1b2c3`).
3. It generates a user symlink: `/dev/<Type>_<ShortAddr>_<Index>` (e.g., `/dev/iter_a1b2c3_0`).
4. It stores the symlink in `pDeviceExtension.sAutoSymlink` for automatic cleanup.

---


### 5.1 A Kernel-Mode "Null" Driver

We will create a `/dev/null` device. This device will successfully accept all write operations but discard the data. All read operations will immediately return an end-of-file status. This is a classic "hello world" for driver development. Our objective is to create a `/dev/null` device. This is a standard virtual device in UNIX-like systems that serves two purposes: it discards all data written to it, and it immediately returns an end-of-file (EOF) condition on any attempt to read from it. This makes it an ideal "hello world" project for driver development, as it touches upon the core concepts of the AxisOS Driver Model (ADM) without requiring any actual hardware interaction.

#### Step 1: The Basic Driver Structure and Dependencies

Every driver, regardless of its function, begins with the same foundational structure. It must include the necessary ADM libraries to interact with the DKMS and the I/O subsystem.

Create a new file at `/drivers/null.sys.lua`. The `.sys.lua` extension is a convention that helps the DKMS identify potential kernel-mode drivers.

The first lines of our driver will load its dependencies:
-   `errcheck`: Provides the standardized `STATUS_*` codes for reporting success or failure.
-   `kmd_api`: The Kernel-Mode Driver Framework API, which contains all the functions necessary for a Ring 2 driver to communicate with the DKMS (e.g., `DkCreateDevice`).
-   `shared_structs`: Defines the core data structures of the ADM, such as `DRIVER_OBJECT`, `DEVICE_OBJECT`, and the `IRP_MJ_*` constants.

```lua
-- /drivers/null.sys.lua
-- A simple KMD that implements a /dev/null device.

local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

-- The rest of our driver code will follow.
```

#### Step 2: Declaring the Driver's Identity

Before the DKMS loads and executes our driver's code, it performs a pre-inspection step to read its metadata. This metadata must be provided in a globally-scoped table named `g_tDriverInfo`. This table is the driver's "resume," informing the DKMS of its name, type, and desired load order.

We will add this table to our file:

```lua
-- ... (requires from Step 1)

-- Define the driver's metadata for DKMS.
g_tDriverInfo = {
  sDriverName = "AxisNull",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD,
  nLoadPriority = 900, -- Very low priority, not essential.
  sVersion = "1.0.0",
}

-- Module-level variable to hold our device object pointer.
local g_pDeviceObject = nil
```
-   `sDriverName`: A human-readable string used for logging and diagnostics.
-   `sDriverType`: This is a critical field. We set it to `tDKStructs.DRIVER_TYPE_KMD` to declare that this is a Kernel-Mode Driver that requires Ring 2 privileges.
-   `nLoadPriority`: An integer that influences the order in which drivers are loaded during boot. Lower numbers indicate higher priority. A high number like `900` signifies that this driver is not critical to the system's core functionality and can be loaded late in the sequence.
-   We also define a module-level local variable, `g_pDeviceObject`, which will hold a pointer to our device object once it is created.

#### Step 3: The Driver's Main Loop

Unlike a standard application, a driver does not execute a linear set of instructions and then exit. Instead, it enters a passive state, waiting for the DKMS to send it commands. This is implemented as an infinite loop that perpetually calls the `signal_pull` syscall.

This loop is the heart of the driver process. It listens for two primary types of signals:
-   `driver_init`: A command from the DKMS to begin the initialization sequence.
-   `irp_dispatch`: A command from the DKMS to process a specific I/O Request Packet (IRP).

Let's add this standard main loop to the end of our file. The functions it calls (`DriverEntry`, `fHandler`) will be defined in the subsequent steps.

```lua
-- ... (g_tDriverInfo from Step 2)

-------------------------------------------------
-- MAIN DRIVER LOOP
-------------------------------------------------
-- This standard loop waits for signals from the DKMS.
while true do
  local bOk, nSenderPid, sSignalName, p1, p2 = syscall("signal_pull")
  if bOk then
    if sSignalName == "driver_init" then
      -- DKMS is telling us to initialize.
      local pDriverObject = p1
      local nStatus = DriverEntry(pDriverObject)
      -- Report the result of our initialization back to DKMS.
      syscall("signal_send", nSenderPid, "driver_init_complete", nStatus, pDriverObject)
    elseif sSignalName == "irp_dispatch" then
      -- DKMS has a job for us (an IRP).
      local pIrp = p1
      local fHandler = p2 -- DKMS tells us which of our functions to run.
      -- We pass the IRP to the designated handler.
      fHandler(g_pDeviceObject, pIrp)
    end
  end
end
```

#### Step 4: Implementing the `DriverEntry` Routine

The `DriverEntry` function is the main initialization entry point for the driver. The DKMS calls it once, immediately after creating the driver process. Its purpose is to register the driver's capabilities with the I/O system and create the necessary objects to represent its device.

Our `DriverEntry` must perform five tasks:
1.  Define the IRP handler functions that will perform the actual I/O work.
2.  Populate the `tDispatch` table in the `DRIVER_OBJECT` with pointers to these handler functions.
3.  Register our `DriverUnload` routine for clean shutdown.
4.  Create a `DEVICE_OBJECT` to represent `\Device\Null0`.
5.  Create a symbolic link to make the device accessible at `/dev/null`.

First, let's define the empty shells for our IRP handlers. These will be filled in later.

```lua
-- ... (g_tDriverInfo from Step 2)

-------------------------------------------------
-- IRP HANDLERS
-------------------------------------------------
local function fNullDispatchCreate(pDeviceObject, pIrp) end
local function fNullDispatchClose(pDeviceObject, pIrp) end
local function fNullDispatchWrite(pDeviceObject, pIrp) end
local function fNullDispatchRead(pDeviceObject, pIrp) end

-------------------------------------------------
-- DRIVER ENTRY & EXIT
-------------------------------------------------
function DriverEntry(pDriverObject)
  oKMD.DkPrint("AxisNull DriverEntry starting.")
  
  -- 2. Populate the dispatch table.
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE] = fNullDispatchCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fNullDispatchClose
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_WRITE] = fNullDispatchWrite
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_READ] = fNullDispatchRead
  
  -- 3. Register our unload routine.
  pDriverObject.fDriverUnload = DriverUnload -- We will define DriverUnload later.
  
  -- 4. Create the device object.
  local nStatus, pDeviceObj = oKMD.DkCreateDevice(pDriverObject, "\\Device\\Null0")
  if nStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkPrint("NULL: Failed to create device object. Status: " .. nStatus)
    return nStatus -- Abort initialization.
  end
  g_pDeviceObject = pDeviceObj
  
  -- 5. Create the symbolic link for user-space access.
  nStatus = oKMD.DkCreateSymbolicLink("/dev/null", "\\Device\\Null0")
  if nStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkPrint("NULL: Failed to create symbolic link. Status: " .. nStatus)
    -- If creating the link fails, we must clean up the device object we just made.
    oKMD.DkDeleteDevice(pDeviceObj) 
    return nStatus
  end
  
  oKMD.DkPrint("AxisNull DriverEntry completed successfully.")
  return tStatus.STATUS_SUCCESS
end

-- ... (Main loop from Step 3)
```
The `tDispatch` table is the core routing mechanism. When the DKMS receives an IRP with the major function code `IRP_MJ_CREATE`, it will look up `pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE]` and call the function it finds there—in this case, `fNullDispatchCreate`.

#### Step 5: Implementing the IRP Handlers

Now we will implement the logic for the IRP handlers we defined in the previous step. For our null device, this logic is very simple. The most important rule is that **every IRP handler must eventually call `oKMD.DkCompleteRequest`**. Failure to do so will cause the application that initiated the I/O to hang indefinitely.

```lua
-- ... (g_tDriverInfo)

-------------------------------------------------
-- IRP HANDLERS
-------------------------------------------------

-- Handles IRP_MJ_CREATE (e.g., fs.open("/dev/null"))
local function fNullDispatchCreate(pDeviceObject, pIrp)
  oKMD.DkPrint("NULL: IRP_MJ_CREATE received.")
  -- We don't need to do any special setup, so we just approve the request.
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

-- Handles IRP_MJ_CLOSE (e.g., handle:close())
local function fNullDispatchClose(pDeviceObject, pIrp)
  oKMD.DkPrint("NULL: IRP_MJ_CLOSE received.")
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

-- Handles IRP_MJ_WRITE (e.g., handle:write("data"))
local function fNullDispatchWrite(pDeviceObject, pIrp)
  local nDataLength = #(pIrp.tParameters.sData or "")
  oKMD.DkPrint("NULL: IRP_MJ_WRITE received, discarding " .. nDataLength .. " bytes.")
  -- We successfully "wrote" all the data by doing nothing with it.
  -- The third argument to DkCompleteRequest is the 'Information' field,
  -- which for a write operation should be the number of bytes written.
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, nDataLength)
end

-- Handles IRP_MJ_READ (e.g., handle:read())
local function fNullDispatchRead(pDeviceObject, pIrp)
  oKMD.DkPrint("NULL: IRP_MJ_READ received, returning EOF.")
  -- Reading from /dev/null immediately results in end-of-file.
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_END_OF_FILE, 0) -- 0 bytes read.
end

-- ... (DriverEntry and Main Loop)
```

#### Step 6: Implementing the `DriverUnload` Routine

The final piece of the driver is the `DriverUnload` function. This function is called by the DKMS when the system is shutting down or when the driver is being manually unloaded. Its purpose is to release all system resources that `DriverEntry` acquired.

Cleanup must be performed in the **reverse order of allocation**. We created the device object and then the symbolic link, so we must delete the symbolic link and then the device object.

```lua
-- ... (IRP Handlers from Step 5)

-------------------------------------------------
-- DRIVER ENTRY & EXIT
-------------------------------------------------

function DriverEntry(pDriverObject)
  -- ... (as defined in Step 4)
end

function DriverUnload(pDriverObject)
  oKMD.DkPrint("AxisNull DriverUnload starting.")
  -- Cleanup in reverse order of creation.
  oKMD.DkDeleteSymbolicLink("/dev/null")
  oKMD.DkDeleteDevice(g_pDeviceObject)
  oKMD.DkPrint("AxisNull DriverUnload completed.")
  return tStatus.STATUS_SUCCESS
end

-- ... (Main Loop from Step 3)
```

So we have:

**File: `/drivers/null.sys.lua`**
```lua
-- /drivers/null.sys.lua
-- A simple KMD that implements a /dev/null device.

local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

-- 1. Define the driver's metadata for DKMS.
g_tDriverInfo = {
  sDriverName = "AxisNull",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD,
  nLoadPriority = 900, -- Very low priority, not essential.
  sVersion = "1.0.0",
}

-- Module-level variable to hold our device object pointer.
local g_pDeviceObject = nil

-------------------------------------------------
-- IRP HANDLERS
-------------------------------------------------

-- Handles IRP_MJ_CREATE (e.g., fs.open("/dev/null"))
local function fNullDispatchCreate(pDeviceObject, pIrp)
  -- We don't need to do any special setup, so we just approve the request.
  oKMD.DkPrint("NULL: IRP_MJ_CREATE received.")
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

-- Handles IRP_MJ_CLOSE (e.g., handle:close())
local function fNullDispatchClose(pDeviceObject, pIrp)
  oKMD.DkPrint("NULL: IRP_MJ_CLOSE received.")
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

-- Handles IRP_MJ_WRITE (e.g., handle:write("data"))
local function fNullDispatchWrite(pDeviceObject, pIrp)
  local nDataLength = #(pIrp.tParameters.sData or "")
  oKMD.DkPrint("NULL: IRP_MJ_WRITE received, discarding " .. nDataLength .. " bytes.")
  -- We successfully "wrote" all the data by doing nothing with it.
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, nDataLength)
end

-- Handles IRP_MJ_READ (e.g., handle:read())
local function fNullDispatchRead(pDeviceObject, pIrp)
  oKMD.DkPrint("NULL: IRP_MJ_READ received, returning EOF.")
  -- Reading from /dev/null immediately results in end-of-file.
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_END_OF_FILE, 0) -- 0 bytes read.
end

-------------------------------------------------
-- DRIVER ENTRY & EXIT
-------------------------------------------------

function DriverEntry(pDriverObject)
  oKMD.DkPrint("AxisNull DriverEntry starting.")
  
  -- 2. Populate the dispatch table.
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE] = fNullDispatchCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fNullDispatchClose
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_WRITE] = fNullDispatchWrite
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_READ] = fNullDispatchRead
  
  -- 3. Register our unload routine.
  pDriverObject.fDriverUnload = DriverUnload
  
  -- 4. Create the device object.
  local nStatus, pDeviceObj = oKMD.DkCreateDevice(pDriverObject, "\\Device\\Null0")
  if nStatus ~= tStatus.STATUS_SUCCESS then
    return nStatus -- Abort initialization.
  end
  g_pDeviceObject = pDeviceObj
  
  -- 5. Create the symbolic link for user-space access.
  nStatus = oKMD.DkCreateSymbolicLink("/dev/null", "\\Device\\Null0")
  if nStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkDeleteDevice(pDeviceObj) -- Clean up the device object we just made.
    return nStatus
  end
  
  oKMD.DkPrint("AxisNull DriverEntry completed successfully.")
  return tStatus.STATUS_SUCCESS
end

function DriverUnload(pDriverObject)
  oKMD.DkPrint("AxisNull DriverUnload starting.")
  -- Cleanup in reverse order of creation.
  oKMD.DkDeleteSymbolicLink("/dev/null")
  oKMD.DkDeleteDevice(g_pDeviceObject)
  oKMD.DkPrint("AxisNull DriverUnload completed.")
  return tStatus.STATUS_SUCCESS
end

-------------------------------------------------
-- MAIN DRIVER LOOP
-------------------------------------------------
-- This standard loop waits for signals from the DKMS.
while true do
  local bOk, nSenderPid, sSignalName, p1, p2 = syscall("signal_pull")
  if bOk then
    if sSignalName == "driver_init" then
      local pDriverObject = p1
      local nStatus = DriverEntry(pDriverObject)
      syscall("signal_send", nSenderPid, "driver_init_complete", nStatus, pDriverObject)
    elseif sSignalName == "irp_dispatch" then
      local pIrp = p1
      local fHandler = p2
      fHandler(g_pDeviceObject, pIrp)
    end
  end
end
```
