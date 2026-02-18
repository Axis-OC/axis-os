
---

# AxisOS System Call Interface Specification

## 1. Introduction and Core Philosophy

The System Call, or "syscall," serves as the canonical, mandatory, and sole interface between user-space processes (Rings 1-3) and the AxisOS kernel (Ring 0). This interface is the fundamental mechanism for requesting privileged operations, such as hardware interaction, process management, or inter-process communication (IPC). The entire security and stability model of the operating system is predicated on the strict enforcement of this boundary.

All interactions are funneled through a single, globally available function, `syscall()`, which acts as a gateway to the kernel's dispatcher. The dispatcher is responsible for identifying the calling process, validating its privileges, and routing its request to the appropriate kernel subsystem or registered Ring 1 service. This design intentionally abstracts the kernel's internal complexity from user-space applications, presenting a stable and well-defined API while allowing the underlying kernel implementation to evolve.

The architecture borrows principles from both monolithic and microkernel designs. While core scheduling and process management reside within the kernel monolith, complex services like the Virtual File System (VFS) or the Dynamic Kernel Module System (DKMS) are implemented as Ring 1 processes. The syscall interface facilitates this hybrid model through a mechanism known as "syscall overriding," allowing these privileged services to intercept and handle specific syscalls, effectively extending the kernel's functionality from user-space.

## 2. The Syscall Dispatch Mechanism

Every invocation of `syscall(name, ...)` from any process triggers a sequence of operations within the `kernel.syscall_dispatch` function. This sequence is critical to the integrity of the system.

Upon invocation, the dispatcher first identifies the execution context. It retrieves the coroutine of the currently running code via `coroutine.running()` and uses the kernel's internal `tPidMap` table to resolve this coroutine to a Process ID (PID). This PID is the immutable identity of the caller for the duration of the syscall. If the coroutine is not tracked by the kernel, this indicates a severe integrity violation, and the system will immediately trigger a kernel panic.

With the caller's PID and its associated privilege Ring established, the dispatcher proceeds to the request routing phase. The first check is against the `tSyscallOverrides` table. This table maps syscall names to the PID of a Ring 1 service that has registered to handle that specific call. If an entry exists for the requested syscall, the dispatcher does not execute any kernel code directly. Instead, it marshals the syscall name and its arguments into an IPC signal and sends it to the registered handler process. The original calling process is then put into a `sleeping` state, pending a response from the handler. The handler service is now fully responsible for processing the request and, crucially, for waking the original caller with the appropriate return values. This mechanism is the foundation of the microkernel-like services in AxisOS.

If no override is registered for the syscall, the dispatcher proceeds with the standard kernel path. It consults the main `tSyscallTable` to find the handler function associated with the syscall name. A critical security check is then performed: the caller's Ring level is validated against the `allowed_rings` array defined for that syscall. Any attempt by a process to invoke a syscall from a privilege level not explicitly permitted in this array constitutes a Ring violation. Such violations are considered fatal for the offending process; it is immediately terminated, and the syscall fails.

Assuming the Ring check passes, the kernel invokes the handler function within a protected call (`pcall`). This ensures that an error within the syscall's implementation itself does not crash the entire kernel. The PID of the caller is always passed as the first argument to the handler function, providing it with the necessary context to perform its operations. The return values from the handler function are then transparently passed back to the original caller, completing the syscall lifecycle.

## 3. Defining a New System Call

Adding a new system call to the AxisOS kernel is a straightforward process that involves defining a handler function and registering it in the `kernel.tSyscallTable`.

A system call registration is a table with two required keys:
*   `func`: The Lua function that will be executed when the syscall is invoked. This function will always receive the caller's PID as its first argument, followed by any arguments passed by the user-space process.
*   `allowed_rings`: A table (array) of numbers representing the Ring levels that are permitted to invoke this syscall.

Consider a hypothetical syscall, `kernel_get_version`, which returns the kernel's version string. Its implementation and registration would appear as follows:

```lua
-- Within kernel.lua, in the syscall definitions section

-- 1. Define the handler function.
-- The function's name is arbitrary, but a descriptive convention is recommended.
local function syscall_get_kernel_version(nCallingPid)
  -- This syscall is simple and doesn't use the nCallingPid,
  -- but the parameter must be present to accept the dispatcher's argument.
  
  -- The version is hardcoded for this example.
  local KERNEL_VERSION = "AxisOS v0.3"
  
  -- Syscall handlers should return values that will be passed
  -- back to the user-space caller.
  return KERNEL_VERSION
end

-- 2. Register the syscall in the main table.
kernel.tSyscallTable["kernel_get_version"] = {
  func = syscall_get_kernel_version,
  
  -- We allow any process, regardless of privilege, to query the version.
  allowed_rings = {0, 1, 2, 2.5, 3} 
}
```

Once registered, any process running in a permitted ring can invoke this new functionality:

```lua
-- In a user-space application (e.g., Ring 3)
local version = syscall("kernel_get_version")
print("Running on kernel version: " .. version)
```

The handler function must be carefully designed to be robust and secure, as it executes with the full authority of the kernel. It must validate all incoming parameters and handle potential error conditions gracefully.

## 4. System Call Catalogue

### **Process Management Syscalls**

#### `process_spawn`
**Synopsis:** Creates and starts a new process.
*   **Signature:** `syscall("process_spawn", path, ring, pass_env)`
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** Spawns a process from `path` at the specified `ring`. A process can only spawn children with equal or lower privilege (higher Ring number).

#### `process_thread`
**Synopsis:** Spawns a thread sharing the parent's environment.
*   **Signature:** `syscall("process_thread", func)`
*   **Parameters:** `func` (function) - The entry point for the thread.
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** Creates a new coroutine/process entry that shares the `env` and file descriptors of the parent. Used by the `thread` library.

#### `process_kill`
**Synopsis:** Terminates a process.
*   **Signature:** `syscall("process_kill", target_pid)`
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** Marks the target process as `dead`. Security checks apply (usually restricted to owner or Ring 0/1).

#### `process_elevate`
**Synopsis:** Elevates a Ring 3 process to Ring 2.5.
*   **Signature:** `syscall("process_elevate", new_ring)`
*   **Allowed Rings:** `{3}`
*   **Description:** Used by `su` to transition to the Driver Host ring level after authentication. Only allows transition to Ring 2.5.

### **Kernel & System Syscalls**

#### `syscall_override`
**Synopsis:** Intercepts a syscall.
*   **Signature:** `syscall("syscall_override", syscall_name)`
*   **Allowed Rings:** `{1}`
*   **Description:** Registers the calling process (usually Pipeline Manager) as the handler for `syscall_name`. Future calls to this syscall will be routed to the caller via IPC signals.

#### `driver_load`
**Synopsis:** Requests a driver load.
*   **Signature:** `syscall("driver_load", path)`
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** A generic entry point for loading drivers. In the current architecture, this is typically overridden by the Pipeline Manager to route the request to DKMS.

#### `kernel_register_pipeline`
**Synopsis:** Registers the Pipeline Manager PID.
*   **Signature:** `syscall("kernel_register_pipeline")`
*   **Allowed Rings:** `{0, 1}`
*   **Description:** Tells the kernel which PID should receive raw `os_event` signals.

#### `kernel_set_log_mode`
**Synopsis:** Toggles on-screen kernel logging.
*   **Signature:** `syscall("kernel_set_log_mode", enable)`
*   **Allowed Rings:** `{0, 1}`
*   **Description:** Used by the PM to silence the boot log once the TTY driver takes over.

### **Raw Component Syscalls**

#### `raw_component_list`
**Synopsis:** Lists hardware components.
*   **Signature:** `syscall("raw_component_list", filter)`
*   **Allowed Rings:** `{0, 1, 2}`
*   **Description:** Returns a table of component addresses. Restricted to Ring 2 and above (Drivers/DKMS).

#### `raw_component_proxy`
**Synopsis:** Gets a direct component proxy.
*   **Signature:** `syscall("raw_component_proxy", address)`
*   **Allowed Rings:** `{0, 1, 2}`
*   **Description:** Returns the OpenComputers proxy object. Essential for KMDs and CMDs.