<p align="center">
  <img src="./img/banner.jpg"  alt="AxisOS Logo">
</p>

# Axis OS

![Version](https://img.shields.io/badge/version-0.82--DQA--beta-blue) ![License](https://img.shields.io/badge/license-MIT-green) ![Platform](https://img.shields.io/badge/platform-OpenComputers-orange)

| Feature | Specification |
| :--- | :--- |
| **Kernel** | **Xen XKA** (eXtensible Kernel Architecture) |
| **Driver Model** | **AXON** (Abstract Xen Object Network) |
| **IPC** | **Synapse** Protocol |
| **Security** | **RKA** (Ringed Kernel Authority) |
| **Graphics** | **GDI** (Graphics Device Interface) |
| **Enclaves** | **EXSi** (Enclaved Kernel eXecution Isolation) |

**Axis OS** is a multitasking, microkernel-like operating system for the OpenComputers mod. Unlike OpenOS, which wraps raw Lua libraries behind a thin POSIX-ish veneer, Axis OS implements a strict separation of concerns: privilege rings, an IRP driver model, per-process handle tables, Access Control Lists, preemptive scheduling via source instrumentation, a full NT/POSIX hybrid IPC subsystem, a surface-based GPU compositor, and SGX-like enclave isolation. It ships with its own bootloader, BIOS setup, package manager, text editor, TUI framework, windowing system, display manager, network stack, and optional SecureBoot with ECDSA attestation and encrypted EFI partitions.

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
  - [GDI Compositor & Windowing](#gdi-compositor--windowing)
  - [Display Manager & Desktop](#display-manager--desktop)
  - [EXSi Enclaves](#exsi-enclaves)
  - [PCMR (Polymorphic Cryptographic Mutating Region)](#pcmr-polymorphic-cryptographic-mutating-region)
  - [Networking](#networking)
  - [XE Graphics Library](#xe-graphics-library)
  - [Text Editors](#text-editors)
  - [Package Manager (xpm)](#package-manager-xpm)
  - [Virtual Registry](#virtual-registry)
  - [SecureBoot & PKI](#secureboot--pki)
  - [PatchGuard v3](#patchguard-v3)
  - [HVCI & Driver Quarantine](#hvci--driver-quarantine)
  - [D-Bus Message Bus](#d-bus-message-bus)
  - [Crash Dump System](#crash-dump-system)
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

- **Memory Sandboxing** — Every process gets a three-layer proxy sandbox. The sandbox table itself is always empty; all reads go through `__index` (protected kernel symbols → user globals → platform APIs), all writes through `__newindex` (protected names silently dropped). `rawset`, `rawget`, and `debug` are stripped for Ring ≥ 2.5. Sub-coroutine depth tracking prevents preemption bypass via nested `coroutine.resume` loops. Standard library tables (`string`, `table`, `math`, `os`) are frozen via read-only proxies — writes throw `SECURITY VIOLATION`.

- **Privilege Rings:**

  | Ring | Role | Access |
  |------|------|--------|
  | **0** | Kernel | Full hardware, raw_component, raw_computer, debug |
  | **1** | System Services | Pipeline Manager, component access, syscall override |
  | **2** | Drivers (KMD/CMD) | Component proxies, device creation |
  | **2.5** | Driver Hosts (UMD) | Elevated user, no raw hardware |
  | **3** | User Applications | Sandboxed, no raw access |

- **Threads** — Kernel-level threads that share the parent process sandbox, file descriptors, and synapse token. Created via `process_thread` syscall, exposed through `/lib/thread.lua`.

- **vfork** — Copy-on-Write process creation. The child's sandbox reads from the parent's environment via metatable `__index`; writes go to a child-local table. No memory duplication until the child modifies a value.

- **OOM Killer** — When free memory drops below 2KB, the kernel kills the Ring 3 process with the highest accumulated CPU time.

- **Swap Space** — Sleeping Ring 3 processes idle for >30 seconds (with free memory below 32KB) have their module cache serialized to `/tmp/.kswap/` with HMAC-SHA256 integrity tags. On wake, the swap file is verified and modules reload on demand.

- **Syscall ASLR** — On first Ring ≥ 2.5 sandbox creation, every syscall name is mapped to a per-boot random token. Ring 3 code calls `syscall("_s4a7f2b1c", ...)` instead of `syscall("vfs_open", ...)`. The mapping rotates every reboot. Ring 0–2 can still use raw names.

- **Syscall Rate Limiting** — Ring 3 processes exceeding 10,000 syscalls/second are killed.

- **Cross-Boundary Sanitization** — When Ring 3 code sends data to Ring 1 (Pipeline Manager), all arguments are deep-sanitized: functions, userdata, metatables, and tables-with-metatables are stripped. Depth and item count are capped to prevent denial-of-service via nested table bombs. Metatables trigger `STATUS_RING_ESCALATION_METAMETHOD`.

- **Ancestor Protection** — A process cannot kill or signal any of its ancestors (parent, grandparent, etc.). This prevents session destruction and protects init from being killed by its children.

- **D-Bus Kernel Message Bus** — Publish/subscribe event notifications. Processes subscribe to named channels (`system.component.added`, `system.memory.low`, custom app channels) and receive messages without polling. Hardware events (component added/removed) are automatically published.

- **Crash Dump Writer** — On kernel panic, a structured crash report is written to `/log/crash_NNN.dump` *before* the BSOD screen. The dump includes: reason, PatchGuard violations, faulting process stack trace, full process table, scheduler stats, IPC stats, memory state, and last 30 dmesg entries. An EEPROM flag is set so the next boot detects the previous crash.

### 2. AXON Driver Model

The **Abstract Xen Object Network** replaces direct component access with a WDM-inspired driver model.

- **Three Driver Types:**
  - **KMD** (Kernel Mode Driver) — Ring 2, full power. TTY, GPU, Internet, RingFS.
  - **CMD** (Component Mode Driver) — Ring 2, hardware-bound. Must be passed a component address at load time. One instance per physical component. Block device, RBMK reactor.
  - **UMD** (User Mode Driver) — Ring 3, sandboxed inside a driver host process.

- **Virtual Devices** — Programs write to `/dev/tty`, `/dev/gpu0`, `/dev/net`, `/dev/ringlog`, `/dev/hbm_rbmk` instead of calling `component.invoke`. The Pipeline Manager resolves VFS paths to kernel device objects; DKMS routes IRPs to the correct driver process.

- **IRP Flow** — Every I/O operation creates an I/O Request Packet. A `write()` call in userspace becomes `vfs_write` → PM creates IRP → DKMS dispatches to driver → driver calls `DkCompleteRequest` → PM returns result to caller. TTY writes use a fire-and-forget fast path (`IRP_FLAG_NO_REPLY`) that skips the round-trip for zero-latency screen output.

- **Device Stack** — Filter drivers can attach above function drivers. IRPs traverse the stack top-down. `DkAttachDevice` / `DkDetachDevice` / `DkCallDriver` provide the NT-style layered I/O model.

- **DKMS** — The Dynamic Kernel Module System manages driver lifecycles: validation, spawning, signal routing, watchdog restart. It auto-discovers hardware components and loads matching CMD drivers. Configuration lives in `/etc/drivers.cfg` (or `/boot/sys/drivers.cfg`), editable via the `drvconf` tool.

- **Driver Security** — Before loading, DKMS runs the driver source through `dkms_sec.lua` which:
  1. Validates `g_tDriverInfo` structure (including mandatory `bAsyncIoSupported = true`)
  2. Computes SHA-256 of the code body
  3. Verifies ECDSA signature against the approved keystore (`/etc/pki_keystore.lua`)
  4. Enforces policy (disabled / warn / enforce) from `/etc/pki.cfg`
  5. Checks HVCI capability sandbox and quarantine status

- **Driver Quarantine** — When a driver crashes 3 times within 60 seconds, HVCI automatically quarantines it. Quarantined drivers are blocked from loading and all IRPs to their devices return `STATUS_DRIVER_QUARANTINED`. The quarantine persists across reboots (stored in the `@VT\DRV` registry hive). Clear via BIOS Setup (DEL at boot) → Drivers → Clear Quarantine.

- **Shipped Drivers:**
  - `tty.sys.lua` — Terminal with color-tracked scrollback (500 lines), cooked/raw mode, mouse input (SGR encoding), text selection, clipboard, PgUp/PgDn, alt-screen, visible cursor
  - `gpu.sys.lua` — Multi-GPU driver v2.0 with GX_AX extension architecture: multi-adapter enumeration, swapchains with hardware double-buffering (Tier 3), sync fences, command buffers with collision-aware color-sorted batch submission, buffer pools, pipeline state cache, fast-path TTY integration
  - `internet.sys.lua` — HTTP + TCP with session management, connection pooling, netfilter integration
  - `blkdev.sys.lua` — Unmanaged drive block I/O with batch read/write
  - `ringfs.sys.lua` — Circular buffer device for live log streaming
  - `hbm_rbmk.sys.lua` — HBM Nuclear Tech RBMK reactor control (console, crane, fuel rods, boilers, etc.)
  - `quarantine_test.sys.lua` — Deliberately faulty driver for testing quarantine protection
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
| **I/O Completion Ports** | Async I/O model with associate/post/get completions and WaitForMultiple support |
| **DPC Queue** | Deferred Procedure Calls processed once per scheduler tick |
| **IRQL** | Passive, APC, Dispatch, Device levels; blocks sleeping at Dispatch+ |
| **Process Groups** | Group-wide signal delivery |
| **D-Bus** | Publish/subscribe named channels with typed payloads |

**sMLTR** (Synapse Message Layer Token Randomization) — Every process gets a unique cryptographic-ish token at creation. Handle operations validate the caller's token against the token stored in the handle entry. Token rotation on privilege elevation invalidates stale handles. System processes (PID < 20) bypass sMLTR for boot-time operations.

### 4. RKA Security

The **Ringed Kernel Authority** replaces UNIX-style file descriptors with a Windows NT-inspired object model, augmented with SGX-like enclave isolation.

- **Object Manager** — Kernel namespace (`\Device\TTY0`, `\DosDevices`, `\Pipe\...`), reference-counted object headers, typed objects, symbolic links. The PM creates `IoFileObject` instances on `vfs_open` and mints handle tokens via `ObCreateHandle`.

- **Handles** — Opaque strings, not integers. A process cannot guess another process's handles. Each handle entry stores: object reference, granted access mask, synapse token, inheritability flag. Standard handle slots (-10 stdin, -11 stdout, -12 stderr) are mapped per-process. Handle token generation uses an EXSi enclave-sealed PRNG — the PRNG state is invisible even to Ring 0.

- **ACLs** — `/etc/perms.lua` stores per-path permissions as `{uid, gid, mode}`. The Pipeline Manager checks these on every `vfs_open`, `vfs_delete`, `vfs_mkdir`, and `vfs_chmod`. UID 0 bypasses all checks.

- **RPL Checks** — The syscall dispatcher verifies the caller's ring against each syscall's `allowed_rings` table before execution. Ring violations are logged and the offending process is killed.

- **Ring Escalation Detection** — The I/O Manager validates argument types before processing. Tables with metatables in cross-ring IPC are stripped and logged as `STATUS_RING_ESCALATION_METAMETHOD`. Nil method calls from metamethod exploits are caught by safe handler wrappers.

- **Handle Inheritance** — On `process_spawn`, inheritable handles from the parent are duplicated into the child's handle table with the child's synapse token. Standard handle slots are remapped.

- **EXSi Enclaves** — SGX-like memory isolation. Secrets live as closure upvalues inside enclave functions — invisible to all code including Ring 0 (debug library is disabled for Ring ≥ 1). Cryptographic attestation (MRENCLAVE = SHA-256 of source code), data sealing (encrypted with key derived from enclave hash + hardware identity).

- **PatchGuard v3** — Runtime kernel integrity monitor with: pure-Lua SHA-256 hashing (no data card dependency), XOR-encrypted snapshot hashes (per-boot random key), check function rotation (3 equivalent variants, random pick each cycle), syscall behavior profiling with baseline anomaly detection, mtime-scan of all critical files every tick for instant tamper detection.

---

## ⚡ Features

### Preemptive Scheduling

AxisOS does not use Lua's `debug.sethook`. Instead, `/lib/preempt.lua` performs a source-to-source transformation at process load time, injecting `__pc()` calls after loop, branch, function entry, goto, and return keywords. The `__pc()` function:

1. Increments a counter
2. Every N calls (configurable, default 128), checks wall-clock time
3. If the process has exceeded its quantum (default 50ms), yields
4. Also delivers pending POSIX signals at each checkpoint

Sub-coroutine depth tracking ensures that `__pc()` inside a nested coroutine propagates the yield to the process level. `coroutine.resume` and `coroutine.wrap` are wrapped with depth counters; when a sub-coroutine yields due to preemption, a `bForceYield` flag propagates the yield upward when depth returns to 0.

The watchdog runs in the scheduler loop. If any single `coroutine.resume` exceeds 2 seconds, the process gets a strike. Three strikes and it's killed.

```
sched              — Global scheduler statistics
sched -p           — Per-process CPU stats
sched -v           — Instrumentation details
```

### Object Manager & Handle Tables

Every opened file, device, pipe, event, mutex, semaphore, shared memory section, message queue, and I/O completion port is an object in the kernel namespace. The Object Manager provides:

- `ObCreateObject` / `ObDeleteObject` — Lifecycle
- `ObInsertObject` / `ObLookupObject` — Namespace registration
- `ObCreateHandle` / `ObCloseHandle` — Per-process handle minting
- `ObReferenceObjectByHandle` — Token + access mask validation
- `ObInheritHandles` — Fork-time handle duplication
- `ObDuplicateHandle` — Explicit handle sharing between processes
- `ObAttachHandlePrng` — Wire EXSi enclave PRNG for token generation

All handles are sMLTR-bound. The Object Manager is loaded at boot from `/lib/ob_manager.lua` before any processes start. Handle token generation optionally uses an EXSi enclave whose PRNG state is sealed in closure upvalues — invisible to any code path including Ring 0.

### Virtual File System

The VFS is split between three Ring 1 sub-modules:

- **I/O Manager** (`/lib/io_manager.lua`) — VFS open/read/write/close/list/mkdir/delete + device IRP dispatch. Ensures parent directories exist before file creation. Ring escalation detection on all VFS handlers.
- **Security Monitor** (`/lib/security_monitor.lua`) — Permission checks, ACL enforcement, chmod. Loads `/etc/perms.lua` at boot.
- **Session Manager** (`/lib/session_manager.lua`) — Boot sequencing, log rotation setup, init spawn.

- **Files** — PM reads/writes through `raw_component_invoke` on the root filesystem proxy
- **Devices** — PM resolves `/dev/*` paths to kernel device objects, creates IRPs, forwards to DKMS
- **Permissions** — Security Monitor loads `/etc/perms.lua`, checks UID/mode on every operation
- **Pipes** — Shell pipelines use temp files (`/tmp/.pipe_*`); kernel pipes use the IPC subsystem directly
- **Device Control** — `fs.deviceControl(handle, method, args)` sends `IRP_MJ_DEVICE_CONTROL` to the driver
- **Buffered I/O** — `/lib/filesystem.lua` maintains per-coroutine write buffers, flushed on newline or `\f`

### AXFS Filesystem & Partitioning

AXFS v3 is a custom inode-based filesystem for unmanaged OC drives with performance and integrity features:

- 512 max inodes, 80-byte inode entries (extent-based), 32-byte directory entries
- Extent-based allocation with up to 13 direct extents + 1 indirect block
- Inline data for files ≤52 bytes (stored directly in the inode)
- CLOCK sector cache with frequency-biased circular eviction
- Inode/path/directory-hash caches with LRU eviction
- Batch reads with readahead for sequential extents
- Copy-on-Write write engine (allocate new blocks → update inode → free old)
- Per-block CRC32 checksums (optional, `FEAT_CHECKSUMS` flag)
- Delayed flush for reduced disk I/O
- Health reporting (`vol:health()`) with CRC verification and free-block audit
- `purgeCache()` for memory pressure relief during bulk operations

The partition table uses an Amiga-inspired Rigid Disk Block (RDB) format with **@RDB::Partition extensions**:

- Visibility modes: normal, hidden-from-FS, system (shown in tools as "SYSTEM")
- Encryption types: none, HMAC-XOR keystream, OC data card AES
- Boot chain roles: data, EFI stage-3, recovery, swap, AXFS root
- Integrity modes: none, CRC32, SHA-256
- Content hash, machine binding, encrypted key material per partition

```
axfs scan                         — List block devices
axfs init /dev/drive_xxx_0        — Write empty RDB
axfs addpart /dev/drive_xxx_0 SYSTEM 900  — Create partition
axfs format /dev/drive_xxx_0 0 AxisOS     — Format with AXFS
axfs ls /dev/drive_xxx_0 0 /              — List root directory
axfs install /dev/drive_xxx_0 0           — Copy entire OS tree (with progress bar)
axfs flash                                — Write AXFS bootloader to EEPROM
```

`axfs-switch` prepares an unmanaged drive in one command, with optional `--efi-prebuild` for encrypted EFI + AXFS dual-partition layout. `parted` provides an interactive shell for drive management with @RDB::Partition display.

### GDI Compositor & Windowing

The **Graphics Device Interface** (`/system/gdi.lua`) is a kernel-level surface compositor:

- **Surfaces** — Rectangular pixel buffers with per-cell character, foreground, and background color. Each surface has a position, z-order, visibility flag, GPU target, and owner PID.
- **Compositing** — Dirty-row tracking with color-sorted batch submission. Only changed cells reach the GPU. Deferred clears prevent blinking during window moves.
- **Drag & Drop** — Title bar drag with clamped positioning. Close button detection. Automatic z-order promotion on click.
- **Input Routing** — Keyboard events go to the focused surface. Mouse events are hit-tested against visible surfaces in z-order. Touch, drag, drop, and scroll events are all routed.
- **Multi-GPU** — Multiple GPUs are auto-paired with screens. Surfaces can target specific GPUs. `gdi_multi_gpu_draw` broadcasts to all GPUs simultaneously.
- **GPU Driver Fast-Path** — When the GPU driver registers its fast-path functions, GDI calls them directly (zero IRP overhead) for render batches, fills, swapchain operations, and command buffer submission.
- **Window Manager** (`/lib/wm.lua`) — Unicode box-drawing borders, title bars, close buttons. `wm.createWindow()` returns a handle for content drawing.

### Display Manager & Desktop

- **Display Manager** (`/system/dm.lua`) — Graphical login screen with GDI surfaces. Password authentication against `/etc/passwd.lua`. Auto-login support. Configurable via `/etc/dm.cfg`.
- **Desktop** (`/system/desktop.lua`) — Taskbar with clock, start menu with power options, window list, app launching. Configurable via `/etc/desktop.cfg`.
- **Init** (`/bin/init.lua`) — Detects `/etc/dm.cfg` and launches either graphical (DM) or text-mode login. DM auto-restarts on exit.
- **Shell GDI Acceleration** — When the compositor is running with 2+ surfaces, the shell can create a GDI surface for output, bypassing TTY ANSI parsing overhead.

### EXSi Enclaves

**EXSi** (Enclaved Kernel eXecution Isolation) provides SGX-like enclave protection for Lua:

- **Memory Isolation** — Enclave source code runs inside `load()` with a minimal sandbox (no `debug`, `rawset`, `rawget`, `load`, `require`, `io`, `os`, `component`, `computer`, `syscall`, `coroutine`). Secrets live as local variables that become closure upvalues — permanently unreachable from outside.
- **Cryptographic Attestation** — MRENCLAVE = SHA-256 of source code. Same source always produces the same hash. Remote servers can verify which code is running inside an enclave.
- **Data Sealing** — `seal(data)` encrypts with a key derived from MRENCLAVE + hardware identity. Only the same enclave on the same machine can `unseal()`. Uses HMAC-SHA256 keystream cipher with MAC-then-encrypt integrity.
- **Handle PRNG** — The Object Manager's handle token generation uses an EXSi enclave whose xorshift32 PRNG state is sealed in upvalues. Pre-generates batches of 64 tokens for amortized O(1) per handle.

```lua
local enc = require("enclave")
local h, mrHash = enc.create([=[
    local secret = nil
    return function(method, ...)
        if method == "store" then secret = select(1, ...); return true
        elseif method == "retrieve" then return secret end
    end
]=])
enc.call(h, "store", "my_private_key")
print(enc.call(h, "retrieve"))  -- "my_private_key"
local proof = enc.attest(h)     -- {sMrEnclave, nOwnerPid, ...}
enc.destroy(h)
```

### PCMR (Polymorphic Cryptographic Mutating Region)

PCMR defeats JVM heap inspection (`jmap` + `strings`) for cryptographic key material:

- Keys are stored inside an EXSi enclave as two parallel number arrays: `Data[]` and `Mask[]`. The actual key byte at position `i` is `bxor(Data[i], Mask[i])`.
- **Mutation**: A new random `NewMask[]` is generated inside the enclave, and `Data[i] = bxor(Data[i], NewMask[i])`, `Mask[i] = bxor(Mask[i], NewMask[i])`. XOR is self-cancelling, so the key is invariant across mutations, but the physical bytes in the heap rotate.
- **Ephemeral Materialization**: The enclave includes a self-contained SHA-256 + HMAC-SHA256 that operates on the split arrays directly. Key bytes are reconstructed one-at-a-time as transient Lua locals, never assembled into a string.
- `mutateAll()` rotates all active PCMR instances every scheduler tick.

### Networking

The internet driver (`internet.sys.lua`) provides:

- **HTTP** — Streaming and simple API. `http.get(url)`, `http.post(url, body)`, `http.open(url)` for streaming, `http.download(url, path)` with progress callback. Chunked response retry (8 retries × 50ms for Cloudflare/nginx gaps).
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

- **Shadow Buffer** — Byte-array front buffer, sparse delta buffer. Only changed cells reach the GPU. Run-length grouping with gap-bridging minimizes batch entries. Deferred clears via single compositor call — no flicker.
- **GDI Integration** — XE contexts create GDI surfaces for output and receive keyboard input via GDI focus routing. No direct TTY rendering.
- **Widgets** — Buttons, checkboxes, text inputs (with cursor and scrolling), scroll containers with scrollbars, dropdowns, selectables, progress bars.
- **Modals** — Stacked modal system with solid/dim/transparent backdrops. Pre-built: alert, confirm, prompt, select, command palette.
- **Toasts** — Auto-dismissing notifications at screen edge.
- **Graphs** — Line graphs, multi-line graphs, bar charts, sparklines, heat rows. All backed by a half-block pixel canvas (2× vertical resolution using ▀ characters). Ring-buffer time series with O(1) push.
- **Pages** — Suspend/resume with GPU snapshot for instant page switching. Inactive pages free their RAM buffers.
- **Mouse** — Click, drag, scroll wheel via SGR mouse encoding from the TTY driver.
- **Tooltips** — Positioned popup boxes with semantic coloring (signature, @param annotations, location).
- **Themes** — Built-in dark and light themes, plugin-extensible.
- **Extensions** — 20+ optional features, auto-resolved dependencies.

### Text Editors

**xevi** — A vim-like editor built on XE:
- Normal, insert, command, search modes
- Paged buffer (constant memory for huge files — only 4 pages of ~48 lines live in RAM)
- Swap-to-disk for evicted dirty pages (`/tmp/.xevi/`)
- Diff-based undo (tracks edit operations, not full snapshots)
- Syntax highlighting with per-line caching (Lua, C, Shell, Log)
- Contextual semantic tokens: function names, field/method access, doc comments, labels, string escapes
- Fuzzy command dropdown with descriptions
- File tree browser with directory navigation
- Tooltip system (K key): finds function definitions and `---` doc comments in buffer
- Plugin system (`/lib/xevi/plug.lua`) with vim-plug-style management: `:PlugInstall`, `:PlugUpdate`, `:PlugStatus`
- Config auto-generation and migration (`/etc/xevi.cfg`)
- Command palette (F5)

**xvi** — A simpler vi clone using the same paged buffer and batch render API. Same syntax highlighting engine, no plugins.

### Package Manager (xpm)

```
xpm init                  — Initialize local database & config
xpm config [key] [val]    — View/edit configuration (repos, SigLevel)
xpm sync                  — Fetch package index from repo.axis.ru
xpm install <pkg>         — Download, verify signature, install
xpm remove <pkg>          — Uninstall
xpm search <term>         — Search available packages
xpm list                  — Show installed
xpm remote-list [term]    — List all available packages (grouped by category)
xpm info <pkg>            — Package details
xpm update                — Re-download all installed packages
xpm outdated              — Check for available updates
xpm sign <file>           — Sign a package (requires APPROVED key)
xpm clean                 — Clear download cache
```

Also accepts pacman-style flags: `-Sy`, `-S`, `-R`, `-Ss`, `-Q`, `-Qi`, `-Syu`.

**Signature Verification** — Three SigLevel policies:
- `Required` — refuse unsigned packages entirely
- `Optional` — install unsigned, warn if signature invalid (default)
- `Never` — skip all verification

Packages are categorized as drivers, executables, modules, or multilib. The index lives at `repo.axis.ru/_sys/pkgindex`. Installed packages are tracked in `/etc/xpm/installed.lua`. Signatures are ECDSA-384 verified against the approved keystore.

### Virtual Registry

The `@VT` namespace is a hierarchical key-value store for runtime metadata with **persistent hive files** on disk:

```
@VT\DEV\VIRT_001          — Device: TTY0, online, Ring 2
@VT\DEV\PHYS_002          — Device: blkdev, drive address
@VT\DRV\AxisTTY           — Driver: path, PID, version, status, quarantine state
@VT\SYS\BOOT              — KernelVersion, BootTime, SafeMode
@VT\SYS\CONFIG            — Hostname, logging settings
@VT\SYS\HARDWARE\gpu_xxx  — Component addresses
@VT\SYS\HVCI              — HVCI mode, whitelist size, policy tier
@VT\USER                   — User preferences
```

Hive files (`SYS.hive`, `DEV.hive`, `DRV.hive`, `USER.hive`) are stored in `/etc/registry/` and flushed lazily on shutdown or explicit `reg_flush`. Dirty tracking per hive avoids unnecessary writes.

CLI: `reg query @VT\DEV`, `reg tree`, `reg set`, `reg find`.
TUI: `regedit` — full-screen registry editor with tree navigation, search, and value display.

### SecureBoot & PKI

The secure boot chain:

1. **EEPROM** — Three boot ROMs: `boot.lua` (plain menu), `boot_secure.lua` (with verification), `axfs_secure_boot.lua` (AXFS + encrypted EFI). SecureBoot computes machine binding (SHA-256 of data card + EEPROM + filesystem addresses) and kernel hash, then compares against values stored in the EEPROM data area.

2. **BIOS Setup** — Press DEL during boot splash. Full TUI with boot entry management, driver configuration, EEPROM parameters, SecureBoot provisioning, quarantine clearing.

3. **EFI Partition** — Third-layer encrypted boot chain. The EFI partition stores an HMAC-XOR keystream encrypted stage-3 bootloader. Decryption key = `HMAC-SHA256(secureboot_key, machine_binding)`. The partition is marked hidden from AXFS (`@RDB::Partition` visibility = `SYSTEM`) but visible in partition tools.

4. **Remote Attestation** — Stage-3 bootloader contacts `pki.axis-os.ru/api/machine_attest.php` for challenge-response verification. HMAC-signed nonce proves machine identity. Offline boot policy configurable in key block.

5. **Kernel Signing** — `sign -g` generates ECDSA-384 key pairs. `sign <file>` appends a signature block. `sign -r` registers the public key with `pki.axis.ru`. `mkefi sign` re-signs kernel HMAC-SHA256 for EFI boot.

6. **Boot Manifest** — `manifest -g` hashes all critical system files and optionally signs the manifest. `manifest -v` verifies integrity.

7. **Provisioning** — `secureboot provision` walks through the checklist. `secureboot register` registers the machine with the PKI server and derives HMAC keys from server_secret + machine_binding + PGP fingerprint. `secureboot verify` runs remote attestation.

### PatchGuard v3

Runtime kernel integrity monitor with five anti-evasion features:

1. **Pure-Lua SHA-256** (`/lib/sha256.lua`) — No data card dependency for hashing. Works on any hardware.
2. **XOR-Encrypted Hash Storage** — File hashes are encrypted with a per-boot 32-byte key (from hardware RNG or entropy fallback). Memory dumps reveal only ciphertext.
3. **Check Function Rotation** — Three functionally-equivalent check functions (`alpha`, `beta`, `gamma`) with different variable names, execution order, and bytecode. Each cycle randomly picks one. Patching one doesn't disable the others.
4. **Syscall Behavior Profiling** — During the first 120 seconds of boot, each process's syscall usage is recorded. After stabilization, baselines are locked. Any process using a syscall outside its baseline triggers an anomaly alert.
5. **Mtime-Scan** — Supercritical files (kernel, init, passwd) are stat-checked every 0.5s; critical files every 2s. Only re-hashed when mtime changes. Detection latency: ≤0.5s for supercritical, ≤2s for critical.

Monitored: syscall table function pointers + ring permissions + key structure, override table, PM PID, PG self-integrity, process ring escalation, frozen library function identities, OB namespace paths, SecureBoot binding/kernel hash, EEPROM code/data, 21+ critical file hashes.

### HVCI & Driver Quarantine

**HVCI v2** (Hypervisor-Enforced Code Integrity):

- **Capability-Based Access** — Drivers declare capabilities in `g_tDriverInfo.capabilities` (e.g., `{"GPU_ACCESS", "SCREEN_ACCESS", "RAW_COMPONENT_LIST"}`). HVCI generates a sandbox restricting component access to declared types only. In `ENFORCE` mode, undeclared capabilities are blocked.
- **Whitelist** — `/etc/driver_whitelist.lua` maps SHA-256 hashes to approved drivers. Unknown hashes are audited (mode 1), warned (mode 2), or blocked (mode 3).
- **Audit Trail** — Timestamped record of every driver load decision (max 200 entries). Stored in `@VT\SYS\HVCI` registry.
- **Quarantine** — 3 dispatch faults in 60 seconds triggers automatic quarantine. Quarantine persists in `@VT\DRV\<name>\Quarantined` registry hive, survives reboots. All IRPs to quarantined devices return error.
- **Runtime Recheck** — Periodic re-hashing of loaded driver files to detect on-disk modification.

### D-Bus Message Bus

Publish/subscribe event notifications without polling:

```lua
local dbus = require("dbus")
dbus.subscribe("system.component.added")
local msg = dbus.poll()         -- blocking
print(msg.channel, msg.data)
dbus.publish("myapp.ready", {status = "ok"})
```

Well-known channels: `system.component.added`, `system.component.removed`, `system.memory.low`, `system.process.spawned`, `system.process.exited`, `system.driver.loaded`, `system.driver.quarantined`.

### Crash Dump System

On kernel panic, before the BSOD screen:

1. Structured crash report written to `/log/crash_NNN.dump`
2. Appended to current VBL session log
3. EEPROM crash flag set (byte 245 = crash type, byte 246 = PG violation count)
4. Next boot detects and reports the previous crash

Dump includes: stop code, reason, PatchGuard violations, faulting process stack trace, full process table with CPU stats, scheduler stats, PatchGuard stats, memory info, IPC stats, component list, and last 30 dmesg entries.

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
| **System** | `ps` `kill` `free` `uptime` `uname` `id` `whoami` `printenv` `reboot` `shutdown` `su` `passwd` |
| **Process** | `htop` (interactive viewer with graphs) `sched` (scheduler stats) `meminfo` (per-process memory) |
| **Network** | `curl` `wget` `ping` `nfw` |
| **Diagnostics** | `dmesg` (structured kernel log) `logread` `ipcs` (IPC status) |
| **Security** | `sign` `secureboot` `provision` `manifest` `pgtest` (PatchGuard test) `exploit_test` (preemption exploit stress-test) `entest` (EXSi enclave test) `pcmr_test` (PCMR handle security test) `qtest` (quarantine test) |
| **Drivers** | `insmod` `drvconf` |
| **Filesystem** | `axfs` `axfs_install` `axfs_flash` `axfs-switch` `parted` (interactive drive manager) `mkefi` |
| **Package** | `xpm` |
| **Registry** | `reg` `regedit` |
| **Editors** | `xvi` `xevi` |
| **Windowing** | `mux` (terminal multiplexer) `appmgr` (application manager) `gdi_ex` (GDI demo) |
| **XE Demos** | `graph` `modal` `xe_dashboard` `xe_pages` `top` (htop with XE) |
| **Fun** | `donut` (donut.c but Lua) |

---

## 🔧 Boot Process

```
EEPROM (4KB)
  ├─ Reads /boot/loader.cfg
  ├─ Shows boot menu (if multiple entries)
  ├─ DEL → loads /boot/setup.lua (BIOS Setup)
  ├─ SecureBoot verification (if enabled)
  │   ├─ Machine binding check
  │   ├─ Kernel hash verification
  │   └─ Remote attestation (if internet card present)
  └─ Loads /kernel.lua

Kernel (Ring 0)
  ├─ Synthesizes bit32 (Lua 5.3 compat)
  ├─ Mounts root filesystem (managed or AXFS v3)
  ├─ Loads Object Manager, Registry (with persistent hives)
  ├─ Loads Preempt, IPC, Hypervisor, PatchGuard v3, EXSi
  ├─ Creates EXSi Handle PRNG enclave
  ├─ Checks for previous crash (EEPROM flag)
  ├─ Freezes standard libraries (string, table, math, os)
  ├─ Initializes GDI compositor (multi-GPU auto-bind)
  ├─ Creates PID 0 (kernel process)
  ├─ Generates syscall ASLR table
  └─ Spawns Pipeline Manager (Ring 1, PID 2)

Pipeline Manager (Ring 1)
  ├─ Splits into I/O Manager, Security Monitor, Session Manager
  ├─ Spawns DKMS (Ring 1)
  ├─ Loads TTY driver
  ├─ Scans components → loads matching drivers
  ├─ Processes /etc/fstab.lua (RingFS, log rotation)
  ├─ Processes /etc/drivers.cfg (dependency-ordered autoload)
  ├─ Populates Virtual Registry
  ├─ Arms PatchGuard (after boot stabilization, ~300 ticks)
  └─ Spawns /bin/init.lua (Ring 3)

Init (Ring 3)
  ├─ Opens /dev/tty
  ├─ Checks /etc/dm.cfg
  ├─ If DM enabled → spawns /system/dm.lua (Display Manager)
  │   ├─ Creates GDI login surface
  │   ├─ Authenticates user
  │   └─ Spawns /system/desktop.lua (Desktop session)
  └─ If DM disabled → text-mode login
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
- Data card Tier 3 (for SecureBoot / driver signing / EXSi sealing — optional)

**Install via xpm (from an existing AxisOS machine):**
```
xpm init
xpm sync
xpm install <package>
```

**Manual install:** Copy the contents of `src/kernel/` to the root of your OpenComputers filesystem. Flash `/boot/boot.lua` to the EEPROM.

**AXFS install (to unmanaged drive):**
```
insmod blkdev
axfs-switch /dev/drive_xxx_0              # Standard (AXFS only)
axfs-switch /dev/drive_xxx_0 --efi-prebuild  # With encrypted EFI
axfs install /dev/drive_xxx_0 0
axfs flash
```

> There is no automated installer yet. One is planned.

---

## 📋 Roadmap

- [x] Microkernel architecture with privilege rings (0, 1, 2, 2.5, 3)
- [x] WDM-like driver model (KMD / UMD / CMD) with device stacks
- [x] IRP (I/O Request Packets) abstraction with fire-and-forget fast path
- [x] DKMS with driver auto-discovery and dependency resolution
- [x] Preemptive scheduling via source instrumentation (function/goto/return keywords)
- [x] NT-style Object Manager with per-process handle tables
- [x] sMLTR (Synapse Message Layer Token Randomization)
- [x] Handle PRNG via EXSi enclave (sealed PRNG state)
- [x] Full IPC subsystem (Events, Mutexes, Semaphores, Pipes, Shared Memory, Message Queues, Signals, WaitMultiple, IOCP)
- [x] D-Bus publish/subscribe message bus
- [x] ACL-based file permissions with ring escalation detection
- [x] Virtual File System with device nodes (split PM: I/O Manager, Security Monitor, Session Manager)
- [x] AXFS v3 inode filesystem (CLOCK cache, CoW, checksums, batch reads, health reporting)
- [x] @RDB::Partition extensions (visibility, encryption, boot roles, integrity modes)
- [x] EFI encrypted boot partition (HMAC-XOR keystream cipher)
- [x] Boot from AXFS partitions on unmanaged drives
- [x] Pipes and output redirection in shell
- [x] Memory management with OOM killer and swap space
- [x] Multitasking + threads + vfork (Copy-on-Write) in userspace
- [x] Namespace separation (sandboxing with three-layer proxy, frozen stdlib)
- [x] Syscall ASLR (per-boot randomized dispatch names)
- [x] Syscall rate limiting (10K/sec for Ring 3)
- [x] Network stack (Internet card: HTTP, TCP, ping)
- [x] Application-level firewall (netfilter)
- [x] SecureBoot with EEPROM attestation + machine binding + remote attestation
- [x] PKI infrastructure with ECDSA driver signing + approved keystore
- [x] EXSi enclave isolation (SGX-like: memory isolation, attestation, sealing)
- [x] PCMR (Polymorphic Cryptographic Mutating Region)
- [x] PatchGuard v3 (SHA-256, XOR hashes, rotation, profiling, mtime scan)
- [x] HVCI v2 (capability sandbox, quarantine, audit trail, runtime recheck)
- [x] Crash dump writer (structured reports + EEPROM crash flag)
- [x] GDI surface compositor with multi-GPU support
- [x] GPU driver v2.0 (GX_AX: swapchains, fences, cmd buffers, pipeline cache)
- [x] Window Manager with drag, close, z-order
- [x] Display Manager (graphical login + desktop session)
- [x] Desktop environment (taskbar, start menu, app launching)
- [x] XE immediate-mode GUI framework with diff rendering + GDI integration
- [x] Graph API (line, multi-line, bar, sparkline, heatmap) with ring-buffer time series
- [x] Modal system, toast notifications, command palette, dropdowns, tooltips
- [x] Plugin-extensible text editor (xevi) with paged buffer, file tree, tooltip system
- [x] Package manager (xpm) with SigLevel policies, package signing, init/config
- [x] Virtual Registry (@VT) with persistent hive files and CLI/TUI tools
- [x] BIOS Setup utility with SecureBoot provisioning + quarantine clearing
- [x] Structured kernel log (dmesg) with level filtering and ring buffer
- [x] Persistent log rotation (.log / .vbl) with crash dump integration
- [x] HBM Nuclear Tech RBMK reactor driver + library
- [x] Cross-boundary data sanitization (Ring 3 → Ring 1) with metamethod detection
- [x] Sub-coroutine depth tracking (preemption bypass fix)
- [x] Ancestor protection (cannot kill/signal parent chain)
- [x] Terminal multiplexer (mux)
- [x] Interactive process viewer (htop) with graphs
- [x] Interactive drive manager (parted)
- [ ] Modem / Linked Card network driver
- [ ] Automated installer
- [ ] Full user/group management (useradd, groupadd)
- [ ] Kernel paravirtualization over Lua VM
- [ ] Proper filesystem journaling
- [ ] Shell scripting (conditionals, variables, loops)
- [ ] Background jobs (`&`, `fg`, `bg`, `jobs`)
- [ ] Process priority / nice levels
- [ ] Multi-screen display server (per-screen desktop)

---

## 🌐 Infrastructure

| URL | Purpose |
|-----|---------|
| [axis.ru](https://axis.ru/) | Main site |
| [repo.axis.ru](https://repo.axis.ru/) | Package repository |
| [auth.axis.ru](https://auth.axis.ru/) | Developer account portal |
| [pki.axis.ru](https://pki.axis.ru/) | Verification server (key registration, attestation, machine binding) |
```