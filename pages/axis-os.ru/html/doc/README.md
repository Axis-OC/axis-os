# AxisOS Xen XKA — Developer Reference Manual

**Version 0.32-alpha1**

---

## Table of Contents

| # | Chapter | Description |
|---|---------|-------------|
| 1 | [Kernel Architecture](./01_kernel-architecture/kernel-architecture.md)) | Ring model, component map, data flow |
| 2 | [Boot Sequence](./02_boot-sequence/boot-sequence.md) | EEPROM → Kernel → PM → DKMS → Userspace |
| 3 | [Ring Model & Process Security](./03_Ring_Model/ring-model--process-security.MD) | Privilege levels, sandboxes, sMLTR |
| 4 | [Process Management & Scheduling](./04_Process_Management/process-management--scheduling.md) | Lifecycle, threads, scheduler loop |
| 5 | [Preemptive Multitasking](./05_Preemptive-Multitasking/preemptive-multitasking.md) | Source instrumentation, `__pc()`, quantum |
| 6 | [Object Manager (Ob)](./06_ObjectManager/object-manager-ob.md) | Handles, namespace, reference counting |
| 7 | [Synapse Tokens (sMLTR)](./07_SynapseProtocol/synapse-tokens-smltr.md) | Handle authentication, rotation, validation |
| 8 | [Pipeline Manager (PM) & VFS](./08_PipelineManager/pipeline-manager-pm--vfs.md) | Syscall routing, file I/O, permissions |
| 9 | [Dynamic Kernel Module System (DKMS)](./09_DKMS/dynamic-kernel-module-system-dkms.md) | Driver loading, device tree, symlinks |
| 10 | [I/O Request Packets (IRPs)](./10_IRP/io-request-packets-irps.md) | Request lifecycle, dispatch, completion |
| 11 | [Driver Objects & Structure](./11_DriverObjects/driver-objects--structure.md) | DRIVER\_OBJECT, DEVICE\_OBJECT, dispatch tables |
| 12 | [Driver Development Guide](./12_DriverDevelopment/driver-development-guide.md) | Step-by-step, KMD, CMD, UMD |
| 13 | [Synchronization & IPC](./12_DriverDevelopment/synchronization--ipc.md) | Events, mutexes, semaphores, pipes, signals |
| 14 | [Virtual Registry (@VT)](./12_DriverDevelopment/virtual-registry-vt.md) | Hierarchical key-value store |
| 15 | [Syscall Reference](./12_DriverDevelopment/syscall-reference.md) | Complete syscall table |
| 16 | [Error Codes](./12_DriverDevelopment/error-codes.md) | STATUS codes and meaning |
| 17 | [User-Space Libraries](./12_DriverDevelopment/user-space-libraries.md) | filesystem, http, thread, sync, etc. |

---
