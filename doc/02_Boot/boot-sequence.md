## 2. Boot Sequence

### 2.1 Overview

AxisOS boots in five distinct phases. Understanding this sequence is critical for diagnosing startup failures and writing early-boot drivers.

```
  Phase 1          Phase 2          Phase 3          Phase 4          Phase 5
  EEPROM           Kernel Init      Ring 1 Start     Driver Load      Userspace
 ┌────────┐      ┌────────────┐   ┌────────────┐   ┌────────────┐   ┌──────────┐
 │ BIOS / │      │ Load sub-  │   │ PM spawns  │   │ TTY,GPU    │   │ init.lua │
 │ Secure │ ──►  │ systems:   │──►│ DKMS scans │──►│ NET,RING   │──►│ sh.lua   │
 │ Boot   │      │ Ob,Reg,IPC │   │ components │   │ autoload   │   │ login    │
 └────────┘      └────────────┘   └────────────┘   └────────────┘   └──────────┘
```

### 2.2 Phase 1: EEPROM

The EEPROM (`boot.lua` or `eeprom_secureboot_axfs.lua`) executes first. It:

1. Discovers GPU and screen components.
2. Locates the boot filesystem (AXFS partition or managed FS).
3. **(Secure Boot only)** Validates machine binding, kernel hash, and boot manifest.
4. Loads `/kernel.lua` into memory.
5. Calls `load()` with `_G` as the environment, providing `boot_fs_address`, `boot_args`, and optionally `boot_security`.

**Boot arguments** (`boot_args`) are populated from the BIOS setup menu:

| Key | Values | Default |
|-----|--------|---------|
| `lvl` | `Debug`, `Info`, `Warn`, `Error` | `Info` |
| `safe` | `Enabled`, `Disabled` | `Disabled` |
| `init` | Path string | `/bin/init.lua` |
| `quick` | `Enabled`, `Disabled` | `Disabled` |

### 2.3 Phase 2: Kernel Initialization

`kernel.lua` executes at Ring 0 and performs:

1. **GPU/Logger init** — finds GPU, binds screen, sets up `kprint()`.
2. **Root FS bootstrap** — detects AXFS or managed FS, creates `g_oPrimitiveFs`.
3. **Subsystem loading** — loads four critical modules from disk using `primitive_load()`:
   - **Object Manager** (`ob_manager.lua`) — handle tables, kernel namespace
   - **Virtual Registry** (`registry.lua`) — `@VT` key-value store
   - **Preempt Module** (`preempt.lua`) — source-code instrumenter
   - **Kernel IPC** (`ke_ipc.lua`) — synchronization primitives
4. **Mounts root FS** — reads `/etc/fstab.lua`, mounts entry #1 as rootfs.
5. **Creates PID 0** — the kernel process itself.
6. **Spawns Pipeline Manager** — PID 2 at Ring 1.

### 2.4 Phase 3: Pipeline Manager Bootstrap

The Pipeline Manager (`/lib/pipeline_manager.lua`) starts at Ring 1 and:

1. Registers syscall overrides for all VFS operations (`vfs_open`, `vfs_read`, etc.).
2. Spawns DKMS (`/system/dkms.lua`) at Ring 1.
3. Explicitly loads the TTY driver (`/drivers/tty.sys.lua`).
4. Scans all hardware components and requests DKMS load drivers for each.
5. Processes `/etc/fstab.lua` — loads RingFS, resizes buffers.
6. Initializes the log rotation system from `/etc/sys.cfg`.
7. Processes `/etc/autoload.lua` — loads additional drivers.
8. Populates `@VT\SYS` registry entries.
9. Disables screen logging (`kernel_set_log_mode(false)`).
10. Spawns `/bin/init.lua` at Ring 3.

### 2.5 Phase 4: Driver Loading

For each hardware component, DKMS:

1. Looks for `/drivers/<component_type>.sys.lua`.
2. Inspects the file for `g_tDriverInfo`.
3. Validates the driver signature (if security is enabled).
4. Spawns the driver process at Ring 2.
5. Sends `driver_init` signal with a DRIVER_OBJECT.
6. Waits for `driver_init_complete` response.
7. Registers the driver in `g_tDriverRegistry`.

> **Important:** The TTY driver **must** load before any other driver because all console output flows through it. PM loads it explicitly before the component scan.

### 2.6 Phase 5: Userspace

`init.lua` displays the login prompt, authenticates users against `/etc/passwd.lua`, and spawns the shell (`sh.lua`) for authenticated sessions.

---