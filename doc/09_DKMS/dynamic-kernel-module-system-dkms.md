## 9. Dynamic Kernel Module System (DKMS)

### 9.1 Overview

DKMS (`/system/dkms.lua`) is a Ring 1 process responsible for:

- Loading and initializing driver processes
- Managing the kernel device tree
- Managing symbolic links (`/dev/*` → `\Device\*`)
- Routing IRPs to the correct driver
- Hardware interrupt forwarding

### 9.2 Device Tree

```lua
g_tDeviceTree = {
    ["\\Device\\TTY0"]    = <DEVICE_OBJECT>,
    ["\\Device\\Gpu0"]    = <DEVICE_OBJECT>,
    ["\\Device\\Net0"]    = <DEVICE_OBJECT>,
    ["\\Device\\ringlog"] = <DEVICE_OBJECT>,
}

g_tSymbolicLinks = {
    ["/dev/tty"]     = "\\Device\\TTY0",
    ["/dev/gpu0"]    = "\\Device\\Gpu0",
    ["/dev/net"]     = "\\Device\\Net0",
    ["/dev/ringlog"] = "\\Device\\ringlog",
}
```

### 9.3 Driver Loading Pipeline

```
  1. Inspect            2. Validate         3. Spawn           4. Init
 ┌──────────┐        ┌──────────────┐    ┌──────────────┐   ┌──────────────┐
 │ Read file│        │ Security     │    │ process_spawn│   │ signal_send  │
 │ Extract  │───────►│ Signature?   │───►│ at Ring 2    │──►│ "driver_init"│
 │ DriverInfo        │ Hash valid?  │    │              │   │ + DriverObj  │
 └──────────┘        └──────────────┘    └──────────────┘   └──────┬───────┘
                                                                    │
  7. Register          6. Store            5. Receive               │
 ┌──────────────┐   ┌──────────────┐    ┌──────────────┐          │
 │ Registry     │   │ g_tDriver    │    │ driver_init_ │◄─────────┘
 │ @VT\DRV\... │◄──│ Registry[path│◄───│ complete     │
 │              │   │ ]=DriverObj  │    │ + status     │
 └──────────────┘   └──────────────┘    └──────────────┘
```

### 9.4 Component Auto-Discovery (CMD Drivers)

When `insmod` or DKMS encounters a CMD driver with `sSupportedComponent`, it:

1. Scans hardware for matching component types.
2. For **each** matching address, spawns a separate driver instance with `env.address = sAddr`.
3. Reports the number of instances loaded.

```lua
-- Example: iter.sys.lua declares sSupportedComponent = "ntm_fusion"
-- If 3 fusion reactors are connected:
--   → 3 driver processes spawned
--   → 3 device objects: \Device\iter_a1b2c3, \Device\iter_d4e5f6, etc.
--   → 3 symlinks: /dev/iter_a1b2c3_0, /dev/iter_d4e5f6_1, etc.
```

### 9.5 IRP Dispatch

When PM sends a `vfs_io_request`, DKMS:

1. Looks up the device name in `g_tDeviceTree`.
2. If not found, tries `g_tSymbolicLinks` resolution.
3. Finds the driver object and the appropriate dispatch function.
4. Sends `signal_send(driverPid, "irp_dispatch", irp, handler)`.
5. Returns `STATUS_PENDING` to PM.
6. When the driver calls `DkCompleteRequest()`, it signals back through DKMS to PM, which wakes the original caller.

---