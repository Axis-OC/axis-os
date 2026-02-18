# AxisOS Xen XKA — Developer Reference Manual

**Version 0.32-alpha1**

---

## Table of Contents

| # | Chapter | Description |
|---|---------|-------------|
| 1 | [Kernel Architecture](./01_kernel-architecture/kernel-architecture.md)) | Ring model, component map, data flow |
| 2 | [Boot Sequence](./02_boot-sequence/boot-sequence.md) | EEPROM → Kernel → PM → DKMS → Userspace |
| 3 | [Ring Model & Process Security](#3-ring-model--process-security) | Privilege levels, sandboxes, sMLTR |
| 4 | [Process Management & Scheduling](#4-process-management--scheduling) | Lifecycle, threads, scheduler loop |
| 5 | [Preemptive Multitasking](#5-preemptive-multitasking) | Source instrumentation, `__pc()`, quantum |
| 6 | [Object Manager (Ob)](#6-object-manager-ob) | Handles, namespace, reference counting |
| 7 | [Synapse Tokens (sMLTR)](#7-synapse-tokens-smltr) | Handle authentication, rotation, validation |
| 8 | [Pipeline Manager (PM) & VFS](#8-pipeline-manager-pm--vfs) | Syscall routing, file I/O, permissions |
| 9 | [Dynamic Kernel Module System (DKMS)](#9-dynamic-kernel-module-system-dkms) | Driver loading, device tree, symlinks |
| 10 | [I/O Request Packets (IRPs)](#10-io-request-packets-irps) | Request lifecycle, dispatch, completion |
| 11 | [Driver Objects & Structure](#11-driver-objects--structure) | DRIVER\_OBJECT, DEVICE\_OBJECT, dispatch tables |
| 12 | [Driver Development Guide](#12-driver-development-guide) | Step-by-step, KMD, CMD, UMD |
| 13 | [Synchronization & IPC](#13-synchronization--ipc) | Events, mutexes, semaphores, pipes, signals |
| 14 | [Virtual Registry (@VT)](#14-virtual-registry-vt) | Hierarchical key-value store |
| 15 | [Syscall Reference](#15-syscall-reference) | Complete syscall table |
| 16 | [Error Codes](#16-error-codes) | STATUS codes and meaning |
| 17 | [User-Space Libraries](#17-user-space-libraries) | filesystem, http, thread, sync, etc. |

---
