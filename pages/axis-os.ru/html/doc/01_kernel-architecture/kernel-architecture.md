## 1. Kernel Architecture

### 1.1 Overview

AxisOS is a microkernel-inspired operating system for OpenComputers (Minecraft mod). It implements a hardware-abstraction layer atop OC components using a driver model loosely modeled on Windows Driver Model (WDM) concepts, combined with POSIX-style process management and a cooperative/preemptive hybrid scheduler.

**Key design principles:**

- **Ring-based privilege separation** — five privilege levels from Ring 0 (kernel) to Ring 3 (user).
- **Message-passing I/O** — all device I/O flows through I/O Request Packets (IRPs) dispatched to driver processes.
- **Object-handle security** — every open resource is tracked by the Object Manager with per-process, token-bound handle tables.
- **Preemptive scheduling** — Lua source is automatically instrumented with yield checkpoints, providing time-sliced multitasking without `debug.sethook`.

### 1.2 Architectural Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         USER SPACE  (Ring 3)                             │
│                                                                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐    │
│  │ init.lua │  │  sh.lua  │  │ cat.lua  │  │  User Applications   │    │
│  └─────┬────┘  └─────┬────┘  └─────┬────┘  └──────────┬───────────┘    │
│        │             │             │                   │                 │
│  ┌─────▼─────────────▼─────────────▼───────────────────▼───────────┐    │
│  │         User-Space Libraries  (/lib/*.lua)                       │    │
│  │  filesystem.lua · http.lua · thread.lua · sync.lua · syscall.lua │    │
│  └──────────────────────────────┬───────────────────────────────────┘    │
│                                 │ syscall()                              │
├─────────────────────────────────┼────────────────────────────────────────┤
│                 KERNEL BOUNDARY  │                                       │
├─────────────────────────────────┼────────────────────────────────────────┤
│                                 ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                  KERNEL  (Ring 0) — kernel.lua                   │    │
│  │                                                                   │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌─────────────────────┐    │    │
│  │  │   Scheduler  │  │   Syscall    │  │  Process Manager    │    │    │
│  │  │  (preemptive │  │  Dispatcher  │  │  (create, kill,     │    │    │
│  │  │  round-robin)│  │              │  │   wait, threads)    │    │    │
│  │  └──────┬───────┘  └──────┬───────┘  └──────────┬──────────┘    │    │
│  │         │                 │                      │               │    │
│  │  ┌──────▼─────────────────▼──────────────────────▼──────────┐   │    │
│  │  │                KERNEL SUBSYSTEMS                          │   │    │
│  │  │                                                           │   │    │
│  │  │  ┌────────────┐  ┌──────────┐  ┌────────────────────┐   │   │    │
│  │  │  │  Object    │  │ Preempt  │  │    Kernel IPC      │   │   │    │
│  │  │  │  Manager   │  │  Module  │  │ (Events, Mutexes,  │   │   │    │
│  │  │  │ (handles,  │  │ (__pc    │  │  Pipes, Signals,   │   │   │    │
│  │  │  │  sMLTR)    │  │  inject) │  │  SharedMem, MQueue)│   │   │    │
│  │  │  └────────────┘  └──────────┘  └────────────────────┘   │   │    │
│  │  │                                                           │   │    │
│  │  │  ┌────────────┐                                          │   │    │
│  │  │  │  Virtual   │                                          │   │    │
│  │  │  │  Registry  │                                          │   │    │
│  │  │  │   (@VT)    │                                          │   │    │
│  │  │  └────────────┘                                          │   │    │
│  │  └──────────────────────────────────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
├──────────────────────────────────────────────────────────────────────────┤
│                       RING 1 SERVICES                                    │
│                                                                          │
│  ┌──────────────────────────┐    ┌──────────────────────────────────┐   │
│  │  Pipeline Manager (PM)   │    │   DKMS (Driver Manager)          │   │
│  │                          │    │                                    │   │
│  │  • VFS syscall routing   │◄──►│  • Driver lifecycle               │   │
│  │  • File handle mgmt     │    │  • Device tree                    │   │
│  │  • Permission checks    │    │  • Symbolic links                 │   │
│  │  • Log rotation         │    │  • IRP dispatch                   │   │
│  │  • Boot orchestration   │    │  • Component auto-discovery       │   │
│  │  • init.lua spawning    │    │  • Driver security validation     │   │
│  └──────────┬───────────────┘    └───────────────┬──────────────────┘   │
│             │                                     │                      │
├─────────────┼─────────────────────────────────────┼──────────────────────┤
│             │          RING 2 DRIVERS             │                      │
│             │                                     ▼                      │
│  ┌──────────▼────────────────────────────────────────────────────────┐  │
│  │                        Driver Processes                            │  │
│  │                                                                    │  │
│  │  ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────────────┐ │  │
│  │  │ tty.sys   │ │ gpu.sys   │ │ net.sys   │ │ blkdev / iter /   │ │  │
│  │  │ (KMD)     │ │ (KMD)     │ │ (KMD)     │ │ ringfs (CMD/KMD)  │ │  │
│  │  └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └────────┬──────────┘ │  │
│  └────────┼──────────────┼─────────────┼─────────────────┼────────────┘  │
│           │              │             │                 │                │
├───────────┼──────────────┼─────────────┼─────────────────┼────────────────┤
│           ▼              ▼             ▼                 ▼                │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │              HARDWARE  (OpenComputers Components)                   │  │
│  │   GPU · Screen · Keyboard · Internet · Drive · EEPROM · Data Card  │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

### 1.3 Data Flow: User Read from `/dev/tty`

```
  User Process (Ring 3)                     Kernel (Ring 0)
  ┌─────────────────┐                      ┌───────────────┐
  │ fs.read(handle)  │                      │               │
  │   │              │                      │  Syscall      │
  │   ▼              │  ───syscall()───►    │  Dispatcher   │
  │ syscall          │  "vfs_read"          │   │           │
  │ ("vfs_read",     │  + handle token      │   │ override? │
  │  token, count)   │  + synapse token     │   ▼           │
  │                  │                      │  Yes → route  │
  │                  │                      │  to PM (Ring 1)│
  └─────────┬────────┘                      └──────┬────────┘
            │                                       │
            │  ◄──── process sleeps ────────────    │
            │                                       ▼
            │                        ┌──────────────────────────┐
            │                        │  Pipeline Manager (PM)   │
            │                        │                          │
            │                        │  1. Validate handle via  │
            │                        │     ObManager + sMLTR    │
            │                        │  2. Resolve to device    │
            │                        │  3. Build IRP            │
            │                        │  4. Send to DKMS         │
            │                        └────────────┬─────────────┘
            │                                      │
            │                                      ▼
            │                        ┌──────────────────────────┐
            │                        │  DKMS                    │
            │                        │                          │
            │                        │  1. Resolve device name  │
            │                        │  2. Find driver PID      │
            │                        │  3. signal_send(driver,  │
            │                        │     "irp_dispatch", irp) │
            │                        └────────────┬─────────────┘
            │                                      │
            │                                      ▼
            │                        ┌──────────────────────────┐
            │                        │  TTY Driver (Ring 2)     │
            │                        │                          │
            │                        │  1. Queue read request   │
            │                        │  2. Wait for key_down    │
            │                        │  3. Process input         │
            │                        │  4. DkCompleteRequest()  │
            │                        │     → signals PM back    │
            │                        └────────────┬─────────────┘
            │                                      │
            │  ◄─── process wakes ─────────────    │
            │       with data from TTY             │
            ▼                                      │
  ┌─────────────────┐                              │
  │ fs.read returns  │  ◄──────────────────────────┘
  │ the typed text   │
  └─────────────────┘
```

### 1.4 Key Source Files

| File | Ring | Purpose |
|------|------|---------|
| `kernel.lua` | 0 | Core kernel: scheduler, syscalls, process management |
| `/lib/ob_manager.lua` | 0 | Object Manager: handles, namespace, security |
| `/lib/preempt.lua` | 0 | Preemptive scheduling: source code instrumenter |
| `/lib/ke_ipc.lua` | 0 | Kernel IPC: events, mutexes, pipes, signals |
| `/lib/registry.lua` | 0 | Virtual Registry (@VT namespace) |
| `/lib/pipeline_manager.lua` | 1 | VFS routing, boot orchestration, permissions |
| `/system/dkms.lua` | 1 | Driver loading, device tree, IRP routing |
| `/system/driverdispatch.lua` | 1 | IRP → driver resolution |
| `/system/lib/dk/shared_structs.lua` | — | IRP and driver object definitions |
| `/system/lib/dk/kmd_api.lua` | 2 | Kernel-mode driver API |
| `/system/lib/dk/common_api.lua` | — | Common driver utilities |
| `/drivers/*.sys.lua` | 2 | Individual hardware drivers |

---