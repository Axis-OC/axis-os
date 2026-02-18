# ADM: Shared Data Structures and Constants

---

## 1. Core Objects

### 1.1. The Driver Object (`DRIVER_OBJECT`)

The Driver Object represents an instance of a loaded driver. It is created by the DKMS during the driver loading process and passed to the driver's `DriverEntry` routine. It serves as the root object for a driver, linking together all devices that the driver controls.

**Structure Definition:**

| Field | Type | Description |
| :--- | :--- | :--- |
| `sDriverPath` | `string` | **[Read-Only]** The absolute VFS path to the driver's source file. Set by the DKMS. |
| `nDriverPid` | `number` | **[Read-Only]** The Process ID (PID) of the process executing the driver's code. Set by the DKMS. |
| `pDeviceObject` | `table` | **[Managed by Driver]** A pointer to the first `DEVICE_OBJECT` in a singly-linked list of devices owned by this driver. The driver populates this field by creating device objects. |
| `fDriverUnload` | `function` | **[Set by Driver]** A pointer to the driver's `DriverUnload` routine. The driver **must** set this field within its `DriverEntry` function. The DKMS will call this function prior to unloading the driver. |
| `tDispatch` | `table` | **[Set by Driver]** An array-like table indexed by `IRP_MJ_*` constants. The driver **must** populate this table with pointers to its IRP dispatch routines. This table is the primary mechanism for routing I/O requests to the driver. |
| `tDriverInfo` | `table` | **[Read-Only]** A copy of the static `g_tDriverInfo` table that was read from the driver's source file during pre-inspection. Set by the DKMS. |

### 1.2. The Device Object (`DEVICE_OBJECT`)

The Device Object represents a physical or logical device that is a target for I/O operations. Drivers create one device object for each device they manage.

**Structure Definition:**

| Field | Type | Description |
| :--- | :--- | :--- |
| `pDriverObject` | `table` | **[Read-Only]** A back-pointer to the `DRIVER_OBJECT` that owns this device. Set by `DkCreateDevice`. |
| `pNextDevice` | `table` | **[Read-Only]** A pointer to the next device object owned by the same driver, forming a linked list. Managed by `DkCreateDevice`. |
| `sDeviceName` | `string` | **[Read-Only]** The internal, canonical name of the device (e.g., `\Device\TTY0`). This name resides in the I/O Manager's private namespace. Set by `DkCreateDevice`. |
| `pDeviceExtension`| `table` | **[Driver-Owned]** A driver-specific data storage area. The DKMS allocates an empty table for this field, but it is exclusively for the driver's use. Drivers should use this to store any per-device state, such as hardware proxy objects, buffers, or status flags. |
| `nFlags` | `number` | Reserved for future use. Must be initialized to 0. |

### 1.3. The I/O Request Packet (`IRP`)

The IRP is the fundamental data structure for all I/O in the system. It is created by the I/O Manager (or a component acting on its behalf) and is passed down through the driver stack to be processed.

**Structure Definition:**

| Field | Type | Description |
| :--- | :--- | :--- |
| `nMajorFunction` | `number` | **[Read-Only]** An `IRP_MJ_*` constant that specifies the primary I/O function to be performed. |
| `pDeviceObject` | `table` | **[Read-Only]** A pointer to the target `DEVICE_OBJECT` for this request. |
| `tParameters` | `table` | **[Read-Only]** A table containing parameters specific to the major function. For `IRP_MJ_WRITE`, this contains the data to be written. For `IRP_MJ_DEVICE_CONTROL`, this contains the control code and associated buffers. |
| `tIoStatus` | `table` | **[Set by Driver]** A sub-table that the driver must fill before completing the IRP. It contains the final status of the operation. |
| `tIoStatus.nStatus` | `number` | The final `STATUS_*` code for the operation (e.g., `STATUS_SUCCESS`). |
| `tIoStatus.vInformation` | `any` | An operation-specific value. For `IRP_MJ_READ` or `IRP_MJ_WRITE`, this should be the number of bytes transferred. For other operations, it can be any value that needs to be returned to the caller. |
| `nSenderPid` | `number` | **[Read-Only]** The PID of the process that originated the I/O request. |

## 2. System Constants

### 2.1. IRP Major Function Codes (`IRP_MJ_*`)

These constants are used as indices into a driver's dispatch table and to identify the type of an IRP.

| Constant | Value | Description |
| :--- | :--- | :--- |
| `IRP_MJ_CREATE` | `0x00` | Indicates a request to open a handle to a device or file. Sent when a user calls `vfs_open`. |
| `IRP_MJ_CLOSE` | `0x02` | Indicates a request to close a handle. Sent when a user calls `vfs_close`. |
| `IRP_MJ_READ` | `0x03` | Indicates a request to transfer data from the device. |
| `IRP_MJ_WRITE` | `0x04` | Indicates a request to transfer data to the device. |
| `IRP_MJ_DEVICE_CONTROL` | `0x0E` | Indicates a request to perform a device-specific control operation, typically initiated via a `vfs_device_control` syscall. |

### 2.2. Driver Types

These constants are used in the `g_tDriverInfo` table to declare the driver's execution mode.

| Constant | Value | Description |
| :--- | :--- | :--- |
| `DRIVER_TYPE_KMD` | `"KernelModeDriver"` | The driver is a Kernel-Mode Driver, intended to run in Ring 2 with privileged hardware access. |
| `DRIVER_TYPE_UMD` | `"UserModeDriver"` | The driver is a User-Mode Driver, intended to run in Ring 3 under the supervision of a host process. |
| `DRIVER_TYPE_CMD` | `"ComponentModeDriver"` | Ring 2. **Auto-Discovery Driver.** Requires `sSupportedComponent` in info. DKMS automatically loads one instance of this driver for every matching component address found on the bus. |