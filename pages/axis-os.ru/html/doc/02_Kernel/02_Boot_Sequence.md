---

# 2.2. The Boot Sequence

The process of starting AxisOS involves a multi-stage sequence, beginning with the BIOS and culminating in the execution of the first user-space process.

## Stage 1: BIOS Execution (`eeprom.lua`)

1.  **Power-On Self-Test (POST)**: The BIOS initializes and attempts to locate a primary GPU/screen.
2.  **Kernel Loading**: It searches for `/kernel.lua` on attached filesystems and loads it into memory.
3.  **Handoff**: The BIOS executes the kernel within a protected call.

## Stage 2: Kernel Initialization (`kernel.lua`)

1.  **Root FS Mount**: The kernel reads `/etc/fstab.lua` (using a primitive loader) to identify and mount the root filesystem.
2.  **PID 0 Creation**: The kernel registers itself as PID 0.
3.  **Ring 1 Service Launch**: The kernel spawns the **Pipeline Manager** (`/lib/pipeline_manager.lua`) as PID 1.
4.  **Scheduler Handoff**: The kernel enters its main scheduler loop.

## Stage 3: Pipeline Initialization (`pipeline_manager.lua`)

1.  **DKMS Spawn**: The PM immediately spawns the **DKMS** process (`/system/dkms.lua`).
2.  **Syscall Override**: The PM registers overrides for all VFS syscalls (`vfs_open`, `vfs_write`, etc.), effectively taking control of all I/O from the kernel.
3.  **Driver Loading**:
    - The PM instructs DKMS to load essential drivers (e.g., `tty.sys.lua`).
    - The PM scans for hardware components and instructs DKMS to load corresponding Component Mode Drivers (CMDs).
    - The PM processes `/etc/fstab.lua` and `/etc/autoload.lua` to load filesystem drivers and auxiliary modules.
4.  **User Space Handoff**: Once the system is stable, the PM spawns the init process (`/bin/init.lua`) in Ring 3.