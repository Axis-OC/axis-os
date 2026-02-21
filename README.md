<p align="center">
  <img src="./img/banner.jpg"  alt="AxisOS Logo">
</p>

# Axis OS

![Version](https://img.shields.io/badge/version-0.4--Xen-blue) ![License](https://img.shields.io/badge/license-MIT-green) ![Platform](https://img.shields.io/badge/platform-OpenComputers-orange)

| Feature | Specification |
| :--- | :--- |
| **Kernel** | **Xen XKA** (eXtensible Kernel Architecture) |
| **Driver Model** | **AXON** (Abstract Xen Object Network) |
| **IPC** | **Synapse** Protocol |
| **Security** | **RKA** (Ringed Kernel Authority) |

**Axis OS** is a multitasking, microkernel-like operating system for the OpenComputers mod. Unlike OpenOS, which wraps raw Lua libraries behind a thin POSIX-ish veneer, Axis OS implements a strict separation of concerns: privilege rings, an IRP driver model, per-process handle tables, Access Control Lists, preemptive scheduling via source instrumentation, and a full NT/POSIX hybrid IPC subsystem. It ships with its own bootloader, BIOS setup, package manager, text editor, TUI framework, network stack, and optional SecureBoot with ECDSA attestation.

> **Warning:** This is not a drop-in replacement for OpenOS. Programs written for OpenOS will not run here without porting. The entire I/O path goes through the Pipeline Manager and DKMS — there is no `component.invoke` in userspace.

---

## Table of Contents

- [Architecture Overview](#-architecture-overview)
  - [Xen XKA (Kernel)](#1-xen-xka-kernel)
  - [AXON Driver Model](#2-axon-driver-model)
  - [Synapse IPC](#3-synapse-ipc)
  - [RKA Security](#4-rka-security)
- [Features](#-features)
  - [Preemptive Scheduling](#preemptive-scheduling)
  - [Object Manager & Handle Tables](#object-manager--handle-tables)
  - [Virtual File System](#virtual-file-system)
  - [AXFS Filesystem & Partitioning](#axfs-filesystem--partitioning)
  - [Networking](#networking)
  - [XE Graphics Library](#xe-graphics-library)
  - [Text Editors](#text-editors)
  - [Package Manager (xpm)](#package-manager-xpm)
  - [Virtual Registry](#virtual-registry)
  - [SecureBoot & PKI](#secureboot--pki)
  - [Mod Integration](#mod-integration)
- [Included Commands](#-included-commands)
- [Boot Process](#-boot-process)
- [Installation](#-installation)
- [Roadmap](#-roadmap)
- [Infrastructure](#-infrastructure)

---

## 🏗 Architecture Overview

### 1. Xen XKA (Kernel)

The kernel runs at Ring 0 and stays minimal. It handles:

- **Process Scheduling** — Cooperative *and* preemptive multitasking. User processes (Ring ≥ 2.5) are source-instrumented at load time: yield checkpoints (`__pc()`) are injected after every `do`, `then`, `repeat`, `else`, `function`, `goto`, and `return`. No debug hooks. The scheduler enforces a configurable time quantum per slice and includes a watchdog that warns — then kills — processes that refuse to yield.

- **Memory Sandboxing** — Every process gets a three-layer proxy sandbox. The sandbox table itself is always empty; all reads go through `__index` (protected kernel symbols → user globals → platform APIs), all writes through `__newindex` (protected names silently dropped). `rawset`, `rawget`, and `debug` are stripped for Ring ≥ 2.5. Sub-coroutine depth tracking prevents preemption bypass via nested `coroutine.resume` loops.

- **Privilege Rings:**

  | Ring | Role | Access |
  |------|------|--------|
  | **0** | Kernel | Full hardware, raw_component, raw_computer, debug |
  | **1** | System Services | Pipeline Manager, component access, syscall override |
  | **2** | Drivers (KMD/CMD) | Component proxies, device creation |
  | **2.5** | Driver Hosts (UMD) | Elevated user, no raw hardware |
  | **3** | User Applications | Sandboxed, no raw access |

- **Threads** — Kernel-level threads that share the parent process sandbox, file descriptors, and synapse token. Created via `process_thread` syscall, exposed through `/lib/thread.lua`.

- **OOM Killer** — When free memory drops below 32KB, the kernel kills the Ring 3 process with the highest accumulated CPU time.

- **Cross-Boundary Sanitization** — When Ring 3 code sends data to Ring 1 (Pipeline Manager), all arguments are deep-sanitized: functions, userdata, and metatables are stripped. Depth and item count are capped to prevent denial-of-service via nested table bombs.

### 2. AXON Driver Model

The **Abstract Xen Object Network** replaces direct component access with a WDM-inspired driver model.

- **Three Driver Types:**
  - **KMD** (Kernel Mode Driver) — Ring 2, full power. TTY, GPU, Internet, RingFS.
  - **CMD** (Component Mode Driver) — Ring 2, hardware-bound. Must be passed a component address at load time. One instance per physical component. Block device, RBMK reactor.
  - **UMD** (User Mode Driver) — Ring 3, sandboxed inside a driver host process.

- **Virtual Devices** — Programs write to `/dev/tty`, `/dev/gpu0`, `/dev/net`, `/dev/ringlog`, `/dev/hbm_rbmk` instead of calling `component.invoke`. The Pipeline Manager resolves VFS paths to kernel device objects; DKMS routes IRPs to the correct driver process.

- **IRP Flow** — Every I/O operation creates an I/O Request Packet. A `write()` call in userspace becomes `vfs_write` → PM creates IRP → DKMS dispatches to driver → driver calls `DkCompleteRequest` → PM returns result to caller.

- **DKMS** — The Dynamic Kernel Module System manages driver lifecycles: validation, spawning, signal routing, watchdog restart. It auto-discovers hardware components and loads matching CMD drivers. Configuration lives in `/etc/drivers.cfg` (or `/boot/sys/drivers.cfg`), editable via the `drvconf` tool.

- **Driver Security** — Before loading, DKMS runs the driver source through `dkms_sec.lua` which:
  1. Validates `g_tDriverInfo` structure
  2. Computes SHA-256 of the code body
  3. Verifies ECDSA signature against the approved keystore (`/etc/pki_keystore.lua`)
  4. Enforces policy (disabled / warn / enforce) from `/etc/pki.cfg`

- **Shipped Drivers:**
  - `tty.sys.lua` — Terminal with color-tracked scrollback (500 lines), cooked/raw mode, mouse input (SGR encoding), text selection, clipboard, PgUp/PgDn, alt-screen
  - `gpu.sys.lua` — GPU passthrough with IRP-based method invocation
  - `internet.sys.lua` — HTTP + TCP with session management, connection pooling, netfilter integration
  - `blkdev.sys.lua` — Unmanaged drive block I/O with batch read/write
  - `ringfs.sys.lua` — Circular buffer device for live log streaming
  - `hbm_rbmk.sys.lua` — HBM Nuclear Tech RBMK reactor control (console, crane, fuel rods, boilers, etc.)
  - Stub drivers for keyboard, screen, computer, eeprom, filesystem

### 3. Synapse IPC

Processes are fully isolated — they share no globals, no file descriptors, no memory. All communication goes through Synapse, a kernel message bus.

**Signal Layer** — The basic transport. Processes send typed signals to each other by PID. The kernel routes signals, buffers them in per-process queues, and wakes sleeping processes. System services (PM, DKMS) use signals for syscall forwarding and IRP dispatch.

**Kernel Executive IPC** (`/lib/ke_ipc.lua`) — A full NT/POSIX hybrid subsystem built on top of signals and the Object Manager:

| Primitive | Description |
|-----------|-------------|
| **Events** | Manual-reset and auto-reset, with Set/Reset/Pulse |
| **Mutexes** | Owned, recursive, with proper deadlock-free release |
| **Semaphores** | Counted permits with configurable maximum |
| **Timers** | One-shot and periodic, with optional DPC callback |
| **Pipes** | Blocking read/write with configurable buffer size, named pipes via namespace |
| **Shared Memory** | Named sections, mapped as shared Lua tables |
| **Message Queues** | Priority-ordered, blocking send/receive with timeout |
| **Signals** | POSIX-style (SIGKILL, SIGTERM, SIGCHLD, SIGUSR1...), catchable handlers, signal masks |
| **WaitForMultipleObjects** | Wait-any and wait-all with timeout, across any combination of the above |
| **DPC Queue** | Deferred Procedure Calls processed once per scheduler tick |
| **IRQL** | Passive, APC, Dispatch, Device levels; blocks sleeping at Dispatch+ |
| **Process Groups** | Group-wide signal delivery |

**sMLTR** (Synapse Message Layer Token Randomization) — Every process gets a unique cryptographic-ish token at creation. Handle operations validate the caller's token against the token stored in the handle entry. Token rotation on privilege elevation invalidates stale handles. System processes (PID < 20) bypass sMLTR for boot-time operations.

### 4. RKA Security

The **Ringed Kernel Authority** replaces UNIX-style file descriptors with a Windows NT-inspired object model.

- **Object Manager** — Kernel namespace (`\Device\TTY0`, `\DosDevices`, `\Pipe\...`), reference-counted object headers, typed objects, symbolic links. The PM creates `IoFileObject` instances on `vfs_open` and mints handle tokens via `ObCreateHandle`.

- **Handles** — Opaque strings, not integers. A process cannot guess another process's handles. Each handle entry stores: object reference, granted access mask, synapse token, inheritability flag. Standard handle slots (-10 stdin, -11 stdout, -12 stderr) are mapped per-process.

- **ACLs** — `/etc/perms.lua` stores per-path permissions as `{uid, gid, mode}`. The Pipeline Manager checks these on every `vfs_open`, `vfs_delete`, `vfs_mkdir`, and `vfs_chmod`. UID 0 bypasses all checks.

- **RPL Checks** — The syscall dispatcher verifies the caller's ring against each syscall's `allowed_rings` table before execution. Ring violations are logged and the offending process is killed.

- **Handle Inheritance** — On `process_spawn`, inheritable handles from the parent are duplicated into the child's handle table with the child's synapse token. Standard handle slots are remapped.

---

## ⚡ Features

### Preemptive Scheduling

AxisOS does not use Lua's `debug.sethook`. Instead, `/lib/preempt.lua` performs a source-to-source transformation at process load time, injecting `__pc()` calls after loop and branch keywords. The `__pc()` function:

1. Increments a counter
2. Every N calls (configurable, default 128), checks wall-clock time
3. If the process has exceeded its quantum (default 50ms), yields
4. Also delivers pending POSIX signals at each checkpoint

Sub-coroutine depth tracking (added after a community member pointed out the coroutine.resume bypass vector) ensures that `__pc()` inside a nested coroutine propagates the yield to the process level.

The watchdog runs in the scheduler loop. If any single `coroutine.resume` exceeds 2 seconds, the process gets a strike. Three strikes and it's killed.

```
sched              — Global scheduler statistics
sched -p           — Per-process CPU stats
sched -v           — Instrumentation details
```

### Object Manager & Handle Tables

Every opened file, device, pipe, event, mutex, semaphore, shared memory section, and message queue is an object in the kernel namespace. The Object Manager provides:

- `ObCreateObject` / `ObDeleteObject` — Lifecycle
- `ObInsertObject` / `ObLookupObject` — Namespace registration
- `ObCreateHandle` / `ObCloseHandle` — Per-process handle minting
- `ObReferenceObjectByHandle` — Token + access mask validation
- `ObInheritHandles` — Fork-time handle duplication
- `ObDuplicateHandle` — Explicit handle sharing between processes

All handles are sMLTR-bound. The Object Manager is loaded at boot from `/lib/ob_manager.lua` before any processes start.

### Virtual File System

The VFS is split between the Pipeline Manager (Ring 1) and DKMS (Ring 2):

- **Files** — PM reads/writes through `raw_component_invoke` on the root filesystem proxy
- **Devices** — PM resolves `/dev/*` paths to kernel device objects, creates IRPs, forwards to DKMS
- **Permissions** — PM loads `/etc/perms.lua`, checks UID/mode on every operation
- **Pipes** — Shell pipelines use temp files (`/tmp/.pipe_*`); kernel pipes use the IPC subsystem directly
- **Device Control** — `fs.deviceControl(handle, method, args)` sends `IRP_MJ_DEVICE_CONTROL` to the driver
- **Buffered I/O** — `/lib/filesystem.lua` maintains per-coroutine write buffers, flushed on newline or `\f`

### AXFS Filesystem & Partitioning

AXFS is a custom inode-based filesystem for unmanaged OC drives:

- 256 max inodes, 64-byte inode entries, 32-byte directory entries
- Direct + indirect block pointers (10 direct + 1 indirect)
- Superblock, inode bitmap, block bitmap, inode table, data blocks
- Files, directories, symlinks

The partition table uses an Amiga-inspired Rigid Disk Block (RDB) format:

```
axfs scan                         — List block devices
axfs init /dev/drive_xxx_0        — Write empty RDB
axfs addpart /dev/drive_xxx_0 SYSTEM 900  — Create partition
axfs format /dev/drive_xxx_0 0 AxisOS     — Format with AXFS
axfs ls /dev/drive_xxx_0 0 /              — List root directory
```

`axfs_install` copies the entire OS tree onto an AXFS partition. `axfs_flash` writes the AXFS bootloader to EEPROM. The kernel detects AXFS boot at startup and creates a compatibility proxy so the rest of the system doesn't care which filesystem type it's running on.

### Networking

The internet driver (`internet.sys.lua`) provides:

- **HTTP** — Streaming and simple API. `http.get(url)`, `http.post(url, body)`, `http.open(url)` for streaming, `http.download(url, path)` with progress callback.
- **TCP** — `net.connect(host, port)` returns a socket with `:read()`, `:write()`, `:close()`.
- **Ping** — TCP connect timing (`ping host` or `net.ping(host, port, count)`). Falls back to HTTP if TCP is disabled.
- **Session Management** — Up to 32 concurrent sessions, stale session cleanup, per-session byte tracking.
- **Netfilter** — Application-level firewall loaded from `/etc/netpolicy.lua`:
  - Rule matching by protocol, host pattern, port, ring, UID
  - Actions: allow, deny, log
  - `/etc/hosts` rewriting (block domains by pointing to 0.0.0.0)
  - Per-UID connection limits
  - Audit log with timestamps
  - Managed via `nfw` command

### XE Graphics Library

XE (`/lib/xe.lua`) is an immediate-mode GUI framework with diff-based rendering:

- **Shadow Buffer** — Byte-array front buffer, sparse delta buffer. Only changed cells reach the GPU. Run-length grouping with gap-bridging minimizes batch entries.
- **Widgets** — Buttons, checkboxes, text inputs (with cursor and scrolling), scroll containers with scrollbars, dropdowns, selectables, progress bars.
- **Modals** — Stacked modal system with solid/dim/transparent backdrops. Pre-built: alert, confirm, prompt, select, command palette.
- **Toasts** — Auto-dismissing notifications at screen edge.
- **Graphs** — Line graphs, multi-line graphs, bar charts, sparklines, heat rows. All backed by a half-block pixel canvas (2× vertical resolution using ▀ characters).
- **Pages** — Suspend/resume with GPU snapshot for instant page switching.
- **Mouse** — Click, drag, scroll wheel via SGR mouse encoding from the TTY driver.
- **Themes** — Built-in dark and light themes, plugin-extensible.
- **Extensions** — 20+ optional features, auto-resolved dependencies.

```lua
local xe = require("xe")
local ctx = xe.createContext({
    theme = xe.THEMES.dark,
    extensions = { "XE_ui_shadow_buffering_render_batch", "XE_ui_diff_render_feature",
                   "XE_ui_alt_screen_query", "XE_ui_imgui_navigation", "XE_ui_toast" },
})

while running do
    ctx:beginFrame()
    ctx:clear(ctx:c("bg"))
    ctx:text(2, 2, "Hello", ctx:c("accent"))
    if ctx:button("quit", 2, 4, " Quit ", 0xFFFFFF, 0xAA0000) then running = false end
    ctx:endFrame()
end
ctx:destroy()
```

### Text Editors

**xevi** — A vim-like editor built on XE:
- Normal, insert, command, search modes
- Diff-based undo (tracks edit operations, not full snapshots)
- Syntax highlighting with per-line caching (Lua, C, Shell)
- Fuzzy command dropdown with descriptions
- Tab bar for multiple buffers
- Plugin system (`/lib/xevi/plug.lua`) with vim-plug-style management: `:PlugInstall`, `:PlugUpdate`, `:PlugStatus`
- Config auto-generation and migration (`/etc/xevi.cfg`)
- Command palette (F5)

**xvi** — A simpler vi clone using the batch render API directly. Same syntax highlighting engine, no plugins.

### Package Manager (xpm)

```
xpm sync                  — Fetch package index from repo.axis.ru
xpm install <pkg>         — Download and install
xpm remove <pkg>          — Uninstall
xpm search <term>         — Search available packages
xpm list                  — Show installed
xpm info <pkg>            — Package details
xpm update                — Re-download all installed packages
```

Also accepts pacman-style flags: `-Sy`, `-S`, `-R`, `-Ss`, `-Q`, `-Qi`, `-Syu`.

Packages are categorized as drivers, executables, modules, or multilib. The index lives at `repo.axis.ru/_sys/pkgindex`. Installed packages are tracked in `/etc/xpm/installed.lua`.

### Virtual Registry

The `@VT` namespace is a hierarchical key-value store for runtime metadata:

```
@VT\DEV\VIRT_001          — Device: TTY0, online, Ring 2
@VT\DEV\PHYS_002          — Device: blkdev, drive address
@VT\DRV\AxisTTY           — Driver: path, PID, version, status
@VT\SYS\BOOT              — KernelVersion, BootTime, SafeMode
@VT\SYS\CONFIG            — Hostname, logging settings
@VT\SYS\HARDWARE\gpu_xxx  — Component addresses
```

CLI: `reg query @VT\DEV`, `reg tree`, `reg set`, `reg find`.
TUI: `regedit` — full-screen registry editor with tree navigation, search, and value display.

### SecureBoot & PKI

The secure boot chain:

1. **EEPROM** — Two boot ROMs: `boot.lua` (plain) and `boot_secure.lua` (with verification). SecureBoot computes machine binding (SHA-256 of data card + EEPROM + filesystem addresses) and kernel hash, then compares against values stored in the EEPROM data area.

2. **BIOS Setup** — Press DEL during boot splash. Full TUI with boot entry management, driver configuration, EEPROM parameters, SecureBoot provisioning.

3. **Machine Binding** — Hardware fingerprint that detects disk cloning between machines.

4. **Kernel Signing** — `sign -g` generates ECDSA-384 key pairs. `sign <file>` appends a signature block. `sign -r` registers the public key with `pki.axis.ru`.

5. **Boot Manifest** — `manifest -g` hashes all critical system files and optionally signs the manifest. `manifest -v` verifies integrity.

6. **Provisioning** — `provision` walks through the checklist: data card, keys, kernel hash, machine binding, EEPROM flash. `provision --seal` makes the EEPROM permanently read-only.

### Mod Integration

**HBM Nuclear Tech — RBMK Reactor:**

The `hbm_rbmk.sys.lua` CMD driver auto-discovers all RBMK components (console, crane, fuel rods, control rods, boilers, heaters, coolers, outgassers). The `/lib/hbm/rbmk.lua` library wraps it in an ergonomic API:

```lua
local rbmk = require("hbm.rbmk")
local reactor = rbmk.open()
reactor:az5()                           -- Emergency shutdown
for gx, gy, col in reactor:eachFuel() do
    print(col.enrichment, col.xenon)
end
reactor:close()
```

---

## 📦 Included Commands

| Category | Commands |
|----------|----------|
| **Core** | `ls` `cat` `cp` `mv` `rm` `mkdir` `touch` `echo` `grep` `head` `tail` `wc` `chmod` `clear` |
| **System** | `ps` `kill` `free` `uptime` `uname` `id` `whoami` `printenv` `reboot` `shutdown` `su` |
| **Network** | `curl` `wget` `ping` `nfw` |
| **Diagnostics** | `dmesg` `logread` `meminfo` `sched` `ipcs` |
| **Security** | `sign` `secureboot` `provision` `manifest` |
| **Drivers** | `insmod` `drvconf` |
| **Filesystem** | `axfs` `axfs_install` `axfs_flash` |
| **Package** | `xpm` |
| **Registry** | `reg` `regedit` |
| **Editors** | `xvi` `xevi` |
| **XE Demos** | `graph` `modal` `xe_dashboard` `xe_pages` |
| **Fun** | `donut` (donut.c but Lua) |

---

## 🔧 Boot Process

```
EEPROM (4KB)
  ├─ Reads /boot/loader.cfg
  ├─ Shows boot menu (if multiple entries)
  ├─ DEL → loads /boot/setup.lua (BIOS Setup)
  ├─ SecureBoot verification (if enabled)
  └─ Loads /kernel.lua

Kernel (Ring 0)
  ├─ Loads Object Manager, Registry, Preempt, IPC
  ├─ Mounts root filesystem (managed or AXFS)
  ├─ Creates PID 0 (kernel process)
  └─ Spawns Pipeline Manager (Ring 1, PID 2)

Pipeline Manager (Ring 1)
  ├─ Spawns DKMS (Ring 1)
  ├─ Loads TTY driver
  ├─ Scans components → loads matching drivers
  ├─ Processes /etc/fstab.lua (RingFS, log rotation)
  ├─ Processes /etc/drivers.cfg (dependency-ordered autoload)
  ├─ Populates Virtual Registry
  └─ Spawns /bin/init.lua (Ring 3)

Init (Ring 3)
  ├─ Opens /dev/tty
  ├─ Loads /etc/passwd.lua
  ├─ Login prompt → password verification
  └─ Spawns /bin/sh.lua with user environment
```

---

## ⚡ Installation

**Requirements:**
- Tier 3 CPU (APU recommended)
- Tier 3 RAM (minimum 2 sticks)
- Tier 3 HDD or RAID
- Internet card (for networking / package manager)
- Data card Tier 3 (for SecureBoot / driver signing — optional)

**Install via xpm (from an existing AxisOS machine):**
```
xpm sync
xpm install <package>
```

**Manual install:** Copy the contents of `src/kernel/` to the root of your OpenComputers filesystem. Flash `/boot/boot.lua` to the EEPROM.

**AXFS install (to unmanaged drive):**
```
insmod blkdev
axfs init /dev/drive_xxx_0
axfs addpart /dev/drive_xxx_0 SYSTEM 900
axfs format /dev/drive_xxx_0 0 AxisOS
axfs_install /dev/drive_xxx_0 0
axfs_flash
```

> There is no automated installer yet. One is planned.

---

## 📋 Roadmap

- [x] Microkernel architecture with privilege rings (0, 1, 2, 2.5, 3)
- [x] WDM-like driver model (KMD / UMD / CMD)
- [x] IRP (I/O Request Packets) abstraction
- [x] DKMS with driver auto-discovery and dependency resolution
- [x] Preemptive scheduling via source instrumentation
- [x] NT-style Object Manager with per-process handle tables
- [x] sMLTR (Synapse Message Layer Token Randomization)
- [x] Full IPC subsystem (Events, Mutexes, Semaphores, Pipes, Shared Memory, Message Queues, Signals, WaitForMultiple)
- [x] ACL-based file permissions
- [x] Virtual File System with device nodes
- [x] AXFS inode filesystem + RDB partition table
- [x] Boot from AXFS partitions on unmanaged drives
- [x] Pipes and output redirection in shell
- [x] Memory management with OOM killer
- [x] Multitasking + threads in userspace
- [x] Namespace separation (sandboxing with three-layer proxy)
- [x] Network stack (Internet card: HTTP, TCP, ping)
- [x] Application-level firewall (netfilter)
- [x] SecureBoot with EEPROM attestation + machine binding
- [x] PKI infrastructure with ECDSA driver signing
- [x] XE immediate-mode GUI framework with diff rendering
- [x] Graph API (line, multi-line, bar, sparkline, heatmap)
- [x] Modal system, toast notifications, command palette
- [x] Plugin-extensible text editor (xevi)
- [x] Package manager (xpm) with remote repository
- [x] Virtual Registry (@VT) with CLI and TUI tools
- [x] BIOS Setup utility with SecureBoot provisioning
- [x] Structured kernel log (dmesg) with level filtering
- [x] Persistent log rotation (.log / .vbl)
- [x] HBM Nuclear Tech RBMK reactor driver + library
- [x] Cross-boundary data sanitization (Ring 3 → Ring 1)
- [x] Sub-coroutine depth tracking (preemption bypass fix)
- [ ] Modem / Linked Card network driver
- [ ] Automated installer
- [ ] Full user/group management (useradd, groupadd)
- [ ] Kernel paravirtualization over Lua VM
- [ ] Proper filesystem journaling
- [ ] Shell scripting (conditionals, variables, loops)
- [ ] Background jobs (`&`, `fg`, `bg`, `jobs`)
- [ ] Process priority / nice levels
- [ ] Display server (multi-screen / multi-GPU)

---

## 🌐 Infrastructure

| URL | Purpose |
|-----|---------|
| [axis.ru](https://axis.ru/) | Main site |
| [repo.axis.ru](https://repo.axis.ru/) | Package repository |
| [auth.axis.ru](https://auth.axis.ru/) | Developer account portal |
| [pki.axis.ru](https://pki.axis.ru/) | Verification server (key registration, attestation) |