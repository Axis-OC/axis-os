# AxisOS Driver Model (ADM) Specification

## 1. Architectural Overview

The AxisOS Driver Model (ADM) is a unified, layered architecture for developing device drivers that run on the AxisOS kernel. It provides a structured framework that abstracts the underlying complexities of the kernel and hardware, allowing developers to write robust, event-driven code. The ADM is heavily inspired by the object-based models found in modern operating systems, particularly the Windows Driver Model (WDM).

The entire model is managed by a privileged Ring 1 service known as the **Dynamic Kernel Module System (DKMS)**. The DKMS is responsible for the entire lifecycle of a driver: loading, initialization, I/O dispatching, and unloading. It acts as the central I/O Manager for the operating system, serving as an intermediary between user-space applications, the kernel, and the drivers themselves.

Drivers in AxisOS are not monolithic blocks of code linked into the kernel. Instead, each driver runs as an isolated, sandboxed process in a specific privilege Ring (typically Ring 2 for Kernel-Mode Drivers or Ring 3 for User-Mode Drivers). This process-based model provides significant stability and security advantages, as a fault within a single driver process will not directly crash the DKMS or the kernel. Communication between the DKMS and driver processes is performed exclusively through the kernel's IPC `signal` mechanism.

The ADM defines two primary modes of driver operation:

*   **Kernel-Mode Driver Framework (KMDF):** Drivers running in Ring 2 have direct, privileged access to hardware components via the `raw_component_*` family of syscalls. They are trusted components of the system, responsible for managing physical hardware and exposing it through standardized interfaces. The TTY, GPU, and filesystem drivers are canonical examples of KMDs.

*   **User-Mode Driver Framework (UMDF):** Drivers running in Ring 3 have no direct hardware access. They operate under the supervision of a Ring 2.5 "Driver Host" process. All requests for privileged operations are marshaled as RPC-style signals to the host, which validates them and forwards them to the kernel. This model is intended for less-trusted or simpler drivers, such as those for USB devices or protocol handlers, where the security benefits of extreme isolation outweigh the performance cost of the additional IPC layer.

*   **CMD (Component Mode Driver):** A specialized KMD designed for specific OpenComputers components (e.g., `iter.sys.lua`).
    *   DKMS automatically discovers hardware matching the driver's `sSupportedComponent`.
    *   DKMS spawns a separate instance of the driver for *each* physical component found.
    *   The component address is injected into the driver's environment.
3.  **UMD (User Mode Driver):** Runs in Ring 3 under a host process.

## 2. Core Architectural Concepts

The ADM is built upon a small set of fundamental objects that represent the various components of the I/O subsystem. A thorough understanding of these objects is essential for driver development.

### 2.1 The Driver Object

A **Driver Object** (`DRIVER_OBJECT`) represents a loaded, initialized driver image. It is the primary data structure that the DKMS uses to manage a driver. A single Driver Object is created by the DKMS for each driver that is successfully loaded into the system. This object serves as the entry point for all I/O requests targeted at the devices managed by that driver.

The Driver Object contains several critical fields, most notably the `tDispatch` table. This is an array-like table, indexed by `IRP_MJ_*` (Major Function) codes, that holds function pointers to the driver's IRP handling routines. When a driver's `DriverEntry` routine is called, its primary responsibility is to populate this dispatch table with its entry points (e.g., `pDriverObject.tDispatch[IRP_MJ_CREATE] = MyCreateFunction`). The DKMS will consult this table to determine which driver function to call for any given I/O request.

### 2.2 The Device Object

A **Device Object** (`DEVICE_OBJECT`) represents a physical, logical, or virtual device that can be the target of an I/O operation. A driver creates one Device Object for each device it controls. For instance, a multi-port serial card driver would create a separate Device Object for each port (`COM1`, `COM2`, etc.). These objects are organized by the DKMS into a global device tree.

Each Device Object contains a back-pointer to its owner, the Driver Object. This allows the DKMS to easily identify which driver is responsible for a request targeted at a specific device.

A crucial component of the Device Object is the **Device Extension**. This is a table (`pDeviceExtension`) that is owned and managed exclusively by the driver. It is intended to be used as a per-device storage area for any stateful information the driver needs to maintain, such as a handle to a hardware component proxy, cursor positions, internal buffers, or pending IRPs. The DKMS allocates this structure but never reads from or writes to it.

### 2.3 The I/O Request Packet (IRP)

The **I/O Request Packet** (`IRP`) is the fundamental data structure used to describe and track an I/O request as it moves through the system. When a user-space application calls a function like `vfs_read`, the VFS service translates this call into an IRP and forwards it to the DKMS. The DKMS then uses the information within the IRP to deliver it to the correct dispatch routine in the correct driver.

An IRP contains all the information necessary for a driver to process a request, including:
*   `nMajorFunction`: A code (e.g., `IRP_MJ_READ`, `IRP_MJ_WRITE`) that specifies the type of operation being requested.
*   `pDeviceObject`: A pointer to the target Device Object for the request.
*   `tParameters`: A table containing the arguments for the operation, such as the data buffer for a write operation or the method name for a device control operation.
*   `tIoStatus`: A sub-table that the driver fills in before completing the request. It contains the final status code (e.g., `STATUS_SUCCESS`) and any information to be returned to the caller (e.g., the number of bytes read).
*   `nSenderPid`: The PID of the process that originated the request, which is necessary for the DKMS to wake the correct process upon completion.

Drivers never create IRPs; they only receive them from the DKMS, process them, and complete them.

## 3. The Driver Lifecycle

The lifecycle of a driver is a well-defined sequence of events managed by the DKMS.

### 3.1 Driver Loading and Initialization

When the Pipeline Manager detects a new hardware component, it sends a `load_driver_for_component` signal to the DKMS. This initiates the driver loading sequence:

1.  **Location and Reading:** The DKMS constructs a path to the driver file (e.g., `/drivers/gpu.sys.lua`) and reads its entire contents into memory using a privileged `vfs_read_file` syscall.
2.  **Security Validation:** The driver code is passed to the DKMS Security Subsystem (`dkms_sec`), which performs static analysis. Currently, this includes validating the structure of the `g_tDriverInfo` table. In future versions, this step could be extended to include cryptographic signature verification.
3.  **Pre-inspection:** The driver code is loaded into a temporary, isolated Lua environment. The DKMS inspects this environment to ensure the `g_tDriverInfo` table is present and valid, and that an appropriate entry point function (`DriverEntry` for KMDs) exists. This step occurs *before* the driver is granted its own process, preventing a malformed driver from consuming system resources.
4.  **Process Creation:** If the inspection passes, the DKMS uses `process_spawn` to create a new, sandboxed process for the driver, assigning it the appropriate Ring level (2 for KMDs). Any environment data, such as the component's hardware address, is passed at this stage.
5.  **Initialization Signal:** The DKMS creates a preliminary `DRIVER_OBJECT` and sends a `driver_init` signal to the newly created driver process, passing this object as an argument.
6.  **Driver Entry Execution:** Upon receiving the `driver_init` signal, the driver process executes its `DriverEntry` function.
7.  **Initialization Completion:** After `DriverEntry` returns, the driver must send a `driver_init_complete` signal back to the DKMS, reporting the final status of the initialization and passing back the now fully-configured `DRIVER_OBJECT`. If this status is `STATUS_SUCCESS`, the DKMS adds the driver to its global registry, and the driver is considered successfully loaded.

### 3.2 The `DriverEntry` Routine

The `DriverEntry` function is the main initialization routine for a Kernel-Mode Driver. It receives one argument: a pointer to the `DRIVER_OBJECT` created by the DKMS. The function must perform several critical tasks:

1.  **Populate the Dispatch Table:** The driver must fill the `pDriverObject.tDispatch` table with pointers to its IRP handler functions. At a minimum, a driver should provide handlers for `IRP_MJ_CREATE` and `IRP_MJ_CLOSE`.
2.  **Register an Unload Routine:** The driver must store a pointer to its `DriverUnload` function in `pDriverObject.fDriverUnload`. The DKMS will call this function when the driver is to be unloaded.
3.  **Create Device Objects:** The driver must call `oKMD.DkCreateDevice` for each device it intends to control. This registers the device with the DKMS.
4.  **Create Symbolic Links:** For devices that need to be visible to user-space applications, the driver must call `oKMD.DkCreateSymbolicLink`. This creates a "friendly name" in the VFS namespace (e.g., `/dev/tty`) that maps to the internal device name (e.g., `\\Device\\TTY0`).
5.  **Initialize Hardware:** The driver should perform any necessary hardware initialization, such as binding to a screen or setting initial states.

The `DriverEntry` function must return a `STATUS_*` code. A return value of `STATUS_SUCCESS` indicates successful initialization. Any other value will cause the DKMS to abort the driver load and terminate the driver process.

### 3.3 The `DriverUnload` Routine

The `DriverUnload` routine is responsible for releasing all system resources acquired by the driver. It is called by the DKMS just before the driver process is terminated. The unload routine must perform the cleanup tasks in the reverse order of creation:

1.  Delete all symbolic links created by the driver.
2.  Delete all device objects created by the driver.
3.  Perform any necessary hardware de-initialization.

## 4. I/O Processing Model

The flow of an I/O request from an application to a driver is a multi-stage process orchestrated by several system components.

1.  **User Request:** A Ring 3 application initiates an I/O operation by calling a VFS function, for example, `oFs.write(handle, data)`.
2.  **Syscall:** The VFS library translates this into a `syscall("vfs_write", fd, data)`.
3.  **VFS Service Interception:** The Ring 1 VFS service, having registered an override for `vfs_write`, receives the syscall request as an IPC signal.
4.  **IRP Creation:** The VFS service determines that the target file descriptor corresponds to a device. It allocates and initializes an IRP, setting `nMajorFunction` to `IRP_MJ_WRITE` and populating `tParameters` with the data to be written. It identifies the target `DEVICE_OBJECT` from the file descriptor.
5.  **Forward to DKMS:** The VFS service sends a `vfs_io_request` signal to the DKMS process, with the newly created IRP as the payload.
6.  **IRP Dispatch:** The DKMS receives the IRP. It inspects the target `pDeviceObject` to find its owning `pDriverObject`. It then uses the IRP's `nMajorFunction` code as an index into the driver's `tDispatch` table to find the address of the correct handler routine (e.g., `fTtyDispatchWrite`).
7.  **Signal to Driver:** The DKMS sends an `irp_dispatch` signal to the driver's process. The payload of this signal contains the IRP itself and a reference to the handler function to be executed.
8.  **Driver Handling:** The driver process receives the signal. Its main loop invokes the specified handler function, passing it the IRP. The handler performs the hardware operation.
9.  **Request Completion:** Once the operation is complete, the driver's handler function fills in the `tIoStatus` block of the IRP and calls `oKMD.DkCompleteRequest`. This function sends a `dkms_complete_irp` syscall back to the DKMS.
10. **Wake the Caller:** The DKMS receives the completion syscall. It extracts the original sender's PID and the final status from the IRP and sends a `syscall_return` signal to the VFS service. The VFS service then wakes the original application process, returning the final result of the `oFs.write` call.

This asynchronous, message-passing-based approach ensures that components are loosely coupled and that the system remains responsive, as no component blocks waiting for another, except through the kernel's explicit `signal_pull` mechanism.