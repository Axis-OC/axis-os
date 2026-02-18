
# UMDF API Reference

---

## Architectural Considerations

UMDF drivers operate in a restricted environment and have no direct access to privileged syscalls. All operations that would require elevated privileges are brokered through the driver's Ring 2.5 host process. The UMDF API functions are therefore thin wrappers that send IPC signals to the host process, which then performs the requested operation on the driver's behalf.

---

### `oUMD.DkPrint`

Prints a message to the kernel's primary diagnostic log.

**Synopsis**
```lua
oUMD.DkPrint(message)
```

**Parameters**
- `message` (`string`): The diagnostic message to be logged.

**Remarks**
This function is inherited from the common driver API. It functions identically to its KMDF counterpart, as the underlying `kernel_log` syscall is accessible from the host process's privilege level.

---

### `oUMD.UmdCompleteRequest`

Completes an I/O Request Packet (IRP) by proxying the request to the driver's host process.

**Synopsis**
```lua
oUMD.UmdCompleteRequest(pIrp, nStatus, vInformation)
```

**Parameters**
- `pIrp` (`table`): The IRP that is being completed.
- `nStatus` (`number`): The final status code for the operation.
- `vInformation` (`any`): The final information value for the operation.

**Remarks**
This is the UMDF equivalent of `oKMD.DkCompleteRequest`. It does not make a syscall directly. Instead, it sends a `umd_complete_irp` signal to the driver's host process. The host process is then responsible for calling the privileged `dkms_complete_irp` syscall to finalize the I/O operation.

---

### Unavailable Functions

The following KMDF functions are **not available** in the UMDF and have no direct equivalent. These operations must be managed by a higher-level component, such as the driver's host process or a dedicated device manager service.

- `DkCreateDevice`
- `DkDeleteDevice`
- `DkCreateSymbolicLink`
- `DkDeleteSymbolicLink`
- `DkGetHardwareProxy`
- `DkRegisterInterrupt`

A UMDF driver's role is to provide the I/O processing logic (the dispatch routines), not to manage system resources or hardware directly.

# Standard Libraries Reference

The `errcheck` library is the central repository for system-wide status and error codes. All system calls and driver functions that report status use the codes defined in this library.

### `oErrCheck.fGetErrorString`

Retrieves a human-readable description for a given status code.

**Synopsis**
```lua
local sDescription = oErrCheck.fGetErrorString(nStatusCode)
```

**Parameters**
- `nStatusCode` (`number`): A `STATUS_*` code.

**Return Values**
- `sDescription` (`string`): A descriptive string for the status code, or a generic "Unknown error" message if the code is not defined.

### Status and Error Codes (`STATUS_*`)

The following table lists all defined status codes.

#### Success Codes
| Constant | Value | Description |
| :--- | :--- | :--- |
| `STATUS_SUCCESS` | `0` | The operation completed successfully. |
| `STATUS_PENDING` | `1` | The operation has been initiated but has not yet completed. The driver will complete the request at a later time. This is common for asynchronous operations. |

#### Error Codes: General
| Constant | Value | Description |
| :--- | :--- | :--- |
| `STATUS_UNSUCCESSFUL` | `300` | A generic failure has occurred. |
| `STATUS_NOT_IMPLEMENTED`| `301` | The requested operation or feature is not implemented by the target driver or subsystem. |

#### Error Codes: Driver-Specific
| Constant | Value | Description |
| :--- | :--- | :--- |
| `STATUS_INVALID_DRIVER_OBJECT` | `400` | The driver object structure is malformed or invalid. |
| `STATUS_INVALID_DRIVER_ENTRY` | `401` | The driver does not export a valid `DriverEntry` or `UMDriverEntry` function. |
| ... | ... | ... |
| `STATUS_DEVICE_ALREADY_EXISTS`| `406` | An attempt was made to create a device with a name that is already in use. |

#### Error Codes: Security
| Constant | Value | Description |
| :--- | :--- | :--- |
| `STATUS_ACCESS_DENIED` | `500` | The caller does not have sufficient permissions to perform the requested action. |
| `STATUS_PRIVILEGE_NOT_HELD` | `501` | The operation requires a higher privilege Ring level than the caller possesses. |

#### Error Codes: VFS and I/O
| Constant | Value | Description |
| :--- | :--- | :--- |
| `STATUS_INVALID_HANDLE` | `600` | The provided file or device handle is not valid, has been closed, or does not exist. |
| `STATUS_END_OF_FILE` | `602` | An attempt to read from a file or device failed because there is no more data available. |
| `STATUS_NO_SUCH_FILE` | `603` | The specified file or directory does not exist. |
| `STATUS_DEVICE_BUSY` | `604` | The device cannot process the request at this time because it is already handling another, conflicting request. |

## 2. `filesystem.lua` (Conceptual User-Space API)

The `filesystem` library provides the primary user-space interface to the VFS.

### `oFs.deviceControl` (Conceptual)

Sends a device-specific control code (an `IRP_MJ_DEVICE_CONTROL` request) to a device driver.

**Synopsis**
```lua
local bOk, tResult, sErr = oFs.deviceControl(hFile, tControlParams)
```

**Parameters**
- `hFile` (`table`): A valid file handle returned from `oFs.open` for a device file.
- `tControlParams` (`table`): A table containing the parameters for the driver. The structure of this table is defined by the target driver. For the ADM, it is expected to have the following format:
  - `sMethod` (`string`): The name of the method/operation to invoke.
  - `tArgs` (`table`): An array of arguments for the method.

**Return Values**
- `bOk` (`boolean`): `true` if the IRP was completed with `STATUS_SUCCESS`, `false` otherwise.
- `tResult` (`table`): On success, a table containing the values from the `vInformation` field of the completed IRP.
- `sErr` (`string`): On failure, a string describing the error.

### `oFs.open`

Opens a handle to a file or device.

**Synopsis**
```lua
local hFile, sErr = oFs.open(sPath, sMode)
```

**Parameters**
- `sPath` (`string`): The absolute path in the VFS to the file or device to be opened.
- `sMode` (`string`): A string specifying the access mode. Common values include `"r"` (read-only), `"w"` (write-only), and `"rw"` (read-write).

**Return Values**
- `hFile` (`table`): On success, an opaque handle object that must be used in subsequent I/O calls. On failure, `nil`.
- `sErr` (`string`): On failure, a string describing the error. On success, `nil`.

**Remarks**
This function is the entry point for all handle-based I/O. It translates the user request into a `vfs_open` syscall, which is typically intercepted by the VFS service and results in an `IRP_MJ_CREATE` being sent to the appropriate driver. The returned handle contains a system-wide unique file descriptor (FD).

---

### `oFs.read`

Reads data from an open file or device handle.

**Synopsis**
```lua
local sData, sErr = oFs.read(hFile, nCount)
```

**Parameters**
- `hFile` (`table`): A valid handle returned by `oFs.open`.
- `nCount` (`number`, optional): The maximum number of bytes to read. If omitted, the function attempts to read all available data until the end of the file.

**Return Values**
- `sData` (`string`): On success, a string containing the data that was read. This may be less than `nCount` if the end of the file was reached. On failure, `nil`.
- `sErr` (`string`): On failure, a string describing the error (e.g., if the handle is invalid or was not opened for reading). On success, `nil`.

**Remarks**
This function may block if the underlying device is asynchronous. For example, calling `read` on a TTY device handle will cause the process to enter a `sleeping` state until the user has entered a line of text. This corresponds to an `IRP_MJ_READ` request.

---

### `oFs.write`

Writes data to an open file or device handle.

**Synopsis**
```lua
local nBytesWritten, sErr = oFs.write(hFile, sData)
```

**Parameters**
- `hFile` (`table`): A valid handle returned by `oFs.open`.
- `sData` (`string`): The data to be written.

**Return Values**
- `nBytesWritten` (`number`): On success, the number of bytes that were successfully written. On failure, `nil`.
- `sErr` (`string`): On failure, a string describing the error. On success, `nil`.

**Remarks**
The number of bytes written may be less than the length of `sData` if the underlying storage medium is full or if the device has internal buffers that are filled. This corresponds to an `IRP_MJ_WRITE` request.

---

### `oFs.close`

Closes an open file or device handle, releasing associated system resources.

**Synopsis**
```lua
local bOk, sErr = oFs.close(hFile)
```

**Parameters**
- `hFile` (`table`): The handle to be closed.

**Return Values**
- `bOk` (`boolean`): `true` on success, `nil` on failure.
- `sErr` (`string`): On failure, a string describing the error. On success, `nil`.

**Remarks**
It is imperative that applications close all handles they open. Failure to do so can result in resource leaks. Once a handle is closed, it becomes invalid and cannot be used for any further I/O operations. This corresponds to an `IRP_MJ_CLOSE` request.

---

### `oFs.list`

Retrieves a list of entries in a directory.

**Synopsis**
```lua
local tContents, sErr = oFs.list(sPath)
```

**Parameters**
- `sPath` (`string`): The absolute path to the directory to be listed.

**Return Values**
- `tContents` (`table`): On success, an array of strings, where each string is the name of a file or subdirectory. On failure, `nil`.
- `sErr` (`string`): On failure, a string describing the error. On success, `nil`.

**Remarks**
This function corresponds to the `vfs_list` syscall. It is primarily applicable to filesystem components. Attempting to call `list` on a device file will typically result in an error.

### 3 A User-Mode "Echo" Driver (Conceptual)

We will now outline the creation of a User-Mode Driver. This driver will implement a `/dev/echo` device. Any string written to this device will be echoed to the main kernel log. This demonstrates the UMD pattern of using the host process as a proxy for privileged operations. Our objective is to create a `/dev/echo` device. Any data written to this device will be printed to the main kernel diagnostic log. This simple goal effectively illustrates the core UMD pattern: receiving a request in Ring 3 and using an IPC-based mechanism to ask a more privileged process (the host) to perform an action on its behalf.

#### Step 1: UMD Structure and Dependencies

The initial structure of a UMD is very similar to a KMD. It requires the same core libraries but with one crucial difference: it uses the User-Mode Driver API (`umd_api`) instead of the Kernel-Mode one.

Create a new file at `/drivers/echo.umd.lua`. The `.umd.lua` extension is a convention to distinguish user-mode drivers.

```lua
-- /drivers/echo.umd.lua
-- A simple UMD that implements a /dev/echo device.

local tStatus = require("errcheck")
-- Note the critical difference: we require the User-Mode API.
local oUMD = require("umd_api") 
local tDKStructs = require("shared_structs")

-- The rest of our driver code will follow.
```
By including `umd_api`, we are explicitly choosing a set of functions that are safe for Ring 3 execution. These functions do not perform privileged syscalls directly; they send signals to the host process.

#### Step 2: Declaring the UMD Identity

Just like a KMD, a UMD must declare its identity via the `g_tDriverInfo` table. The DKMS reads this table to understand how to manage the driver. The most important field here is `sDriverType`.

```lua
-- ... (requires from Step 1)

-- Define driver metadata. Note the DRIVER_TYPE.
g_tDriverInfo = {
  sDriverName = "AxisEcho",
  -- This declaration informs the DKMS that this driver must be
  -- loaded into a User-Mode Driver Host process at Ring 3.
  sDriverType = tDKStructs.DRIVER_TYPE_UMD, 
  nLoadPriority = 901,
  sVersion = "1.0.0",
}

-- This variable is still present, but it will be managed differently.
local g_pDeviceObject = nil
```
By setting `sDriverType` to `DRIVER_TYPE_UMD`, we instruct the DKMS *not* to create a Ring 2 process for this driver. Instead, the DKMS will delegate the loading task to a `driverhost` process, which will then spawn our driver's code in Ring 3.

#### Step 3: The UMD Main Loop

The main loop of a UMD is structurally identical to a KMD's loop, but the signals it receives come from a different source. Instead of receiving signals directly from the DKMS (Ring 1), it receives them from its parent **Driver Host** process (Ring 2.5).

The signals have slightly different names by convention to reflect this relationship:
-   `umd_initialize`: The host's command to begin initialization.
-   `irp_dispatch`: The host's command to process an IRP that has been forwarded from the DKMS.

```lua
-- ... (g_tDriverInfo from Step 2)

-------------------------------------------------
-- MAIN DRIVER LOOP
-------------------------------------------------
-- The UMD loop waits for signals from its Driver Host process.
while true do
  local bOk, nSenderPid, sSignalName, p1, p2 = syscall("signal_pull")
  if bOk then
    if sSignalName == "umd_initialize" then -- Signal from the host
      local pDriverObject = p1
      -- By convention, the entry point is named UMDriverEntry.
      local nStatus = UMDriverEntry(pDriverObject) 
      -- Report completion back to the host process, not DKMS.
      syscall("signal_send", nSenderPid, "umd_init_complete", nStatus, pDriverObject)
    elseif sSignalName == "irp_dispatch" then -- Signal from the host
      local pIrp = p1
      local fHandler = p2
      fHandler(g_pDeviceObject, pIrp)
    end
  end
end
```

#### Step 4: Implementing the `UMDriverEntry` Routine

The entry point for a UMD, conventionally named `UMDriverEntry`, has a significantly reduced set of responsibilities compared to its kernel-mode counterpart. **A UMD does not manage system resources.** It does not create device objects or symbolic links. That is the responsibility of the host process or another higher-level manager.

The sole purpose of a UMD's entry routine is to provide the I/O processing logic. It does this by populating the dispatch table, just as a KMD would.

```lua
-- ... (g_tDriverInfo from Step 2)

-------------------------------------------------
-- IRP HANDLERS (shells)
-------------------------------------------------
local function fEchoDispatchCreate(pDeviceObject, pIrp) end
local function fEchoDispatchWrite(pDeviceObject, pIrp) end

-------------------------------------------------
-- DRIVER ENTRY
-------------------------------------------------
-- UMDs have a different entry point name by convention.
function UMDriverEntry(pDriverObject)
  oUMD.DkPrint("AxisEcho UMDriverEntry starting.")
  
  -- 1. Populate the dispatch table. This is the primary responsibility.
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE] = fEchoDispatchCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_WRITE] = fEchoDispatchWrite
  
  -- 2. A UMD does NOT create its own device object or symlink.
  -- It does NOT register an unload routine in the same way.
  -- Its job is simply to provide the I/O logic. The host manages its lifecycle.
  
  oUMD.DkPrint("AxisEcho UMDriverEntry completed successfully.")
  return tStatus.STATUS_SUCCESS
end

-- ... (Main loop from Step 3)
```

#### Step 5: Implementing the UMD IRP Handlers

Implementing the IRP handlers is where the core logic resides. The key difference is in how requests are completed. A UMD cannot directly notify the DKMS. It must use the `oUMD.UmdCompleteRequest` function, which sends a signal to its host. The host then performs the privileged action of completing the IRP with the DKMS.

For our `echo` driver, the `fEchoDispatchWrite` function needs to perform a privileged action: writing to the kernel log. It achieves this by calling `oUMD.DkPrint`. This function is available in the common API and works because the host process (running at Ring 2.5) has permission to call the `kernel_log` syscall. The UMD's call is effectively proxied through the host.

```lua
-- ... (g_tDriverInfo)

-------------------------------------------------
-- IRP HANDLERS
-------------------------------------------------

-- For a UMD, IRP handlers are the same, but completion is different.
local function fEchoDispatchCreate(pDeviceObject, pIrp)
  oUMD.DkPrint("ECHO: IRP_MJ_CREATE received.")
  -- We complete the request via the UMD API, which sends a signal to our host.
  oUMD.UmdCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fEchoDispatchWrite(pDeviceObject, pIrp)
  local sData = pIrp.tParameters.sData or ""
  oUMD.DkPrint("ECHO: IRP_MJ_WRITE received. Echoing to kernel log.")
  
  -- This call to DkPrint is a proxied operation. Our Ring 3 process
  -- cannot call kernel_log directly. The `oUMD` library function is
  -- implemented to send a request to the host, which then performs
  -- the actual syscall.
  oUMD.DkPrint("[ECHO DRIVER] " .. sData)

  -- Complete the request by notifying the host.
  oUMD.UmdCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, #sData)
end

-- ... (UMDriverEntry and Main Loop)
```

So we have:

**File: `/drivers/echo.umd.lua`**
```lua
-- /drivers/echo.umd.lua
-- A simple UMD that implements a /dev/echo device.

local tStatus = require("errcheck")
local oUMD = require("umd_api") -- Note: using the User-Mode API
local tDKStructs = require("shared_structs")

-- 1. Define driver metadata. Note the DRIVER_TYPE.
g_tDriverInfo = {
  sDriverName = "AxisEcho",
  sDriverType = tDKStructs.DRIVER_TYPE_UMD, -- This is a User-Mode Driver.
  nLoadPriority = 901,
  sVersion = "1.0.0",
}

local g_pDeviceObject = nil

-------------------------------------------------
-- IRP HANDLERS
-------------------------------------------------

-- For a UMD, IRP handlers are the same, but completion is different.
local function fEchoDispatchCreate(pDeviceObject, pIrp)
  oUMD.DkPrint("ECHO: IRP_MJ_CREATE received.")
  -- We complete the request via the UMD API, which sends a signal to our host.
  oUMD.UmdCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fEchoDispatchWrite(pDeviceObject, pIrp)
  local sData = pIrp.tParameters.sData or ""
  oUMD.DkPrint("ECHO: IRP_MJ_WRITE received. Echoing to kernel log.")
  
  -- A UMD cannot call kernel_log directly. It must ask its host.
  -- This would be a custom RPC call (signal) to the host process.
  -- For this example, we'll assume a custom API function exists.
  -- oUMD.HostProxyCall("kernel_log", "[ECHO DRIVER] " .. sData)
  
  -- For now, we just print via the common API, which will work if the host
  -- has a kernel_log syscall available to it (which it does at Ring 2.5).
  oUMD.DkPrint("[ECHO DRIVER] " .. sData)

  oUMD.UmdCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, #sData)
end

-------------------------------------------------
-- DRIVER ENTRY
-------------------------------------------------

-- UMDs have a different entry point name by convention.
function UMDriverEntry(pDriverObject)
  oUMD.DkPrint("AxisEcho UMDriverEntry starting.")
  
  -- 2. Populate the dispatch table, just like a KMD.
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE] = fEchoDispatchCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_WRITE] = fEchoDispatchWrite
  
  -- 3. A UMD does NOT create its own device object or symlink.
  -- The host process or a higher-level manager is responsible for this.
  -- The UMD's job is simply to provide the logic (the dispatch table).
  
  oUMD.DkPrint("AxisEcho UMDriverEntry completed successfully.")
  return tStatus.STATUS_SUCCESS
end

-------------------------------------------------
-- MAIN DRIVER LOOP
-------------------------------------------------
-- The UMD loop waits for signals from its Driver Host process.
while true do
  local bOk, nSenderPid, sSignalName, p1, p2 = syscall("signal_pull")
  if bOk then
    if sSignalName == "umd_initialize" then -- Signal from the host
      local pDriverObject = p1
      local nStatus = UMDriverEntry(pDriverObject)
      -- Report completion back to the host process.
      syscall("signal_send", nSenderPid, "umd_init_complete", nStatus, pDriverObject)
    elseif sSignalName == "irp_dispatch" then -- Signal from the host
      local pIrp = p1
      local fHandler = p2
      fHandler(g_pDeviceObject, pIrp)
    end
  end
end
```



**Remarks**
This function is the bridge between user-space applications and the `IRP_MJ_DEVICE_CONTROL` handlers in drivers. It allows applications to invoke the custom functionality exposed by drivers, such as getting the status of a fusion reactor or setting the resolution of a GPU.