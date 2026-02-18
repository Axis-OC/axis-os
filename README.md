<p align="center">
  <img src="./img/banner.jpg"  alt="AxisOS Logo">
</p>

# Axis OS

![Version](https://img.shields.io/badge/version-0.3--Xen-blue) ![License](https://img.shields.io/badge/license-MIT-green) ![Platform](https://img.shields.io/badge/platform-OpenComputers-orange)

| Feature | Specification |
| :--- | :--- |
| **Kernel** | **Xen XKA** (eXtensible Kernel Architecture) |
| **Driver Model** | **AXON** (Abstract Xen Object Network) |
| **IPC** | **Synapse** Protocol |
| **Security** | **RKA** (Ringed Kernel Authority) |

**Axis OS** is a multitasking, microkernel-like operating system designed for the OpenComputers mod. Unlike standard OpenOS, which provides a thin wrapper around Lua libraries, Axis OS implements a strict separation of concerns, simulating an enterprise-grade architecture with privilege rings, an I/O request packet (IRP) driver model, and Access Control Lists (ACLs).

> **Warning:** This OS is highly experimental. It fundamentally changes how software interacts with OC components. Standard OpenOS programs will likely require porting to work within the Axis sandbox.

#### Roadmap:
>- [x] Access Control List (ACL)
>- [x] Ringed Kernel Authority (RKA)
>- [x] Microkernel Architecture
>- [x] WDM-like strict driver-model
>- [x] IRP (I/O Request Packets) abstraction
>- [x] DKMS & Dynamic Driver Loader
>- [x] Virtual File System (VFS)
>- [x] Handling frozen drivers
>- [x] Synapse Message Layer Token Randomization (sMLTR)
>- [x] Own Object Handles implementation
>- [ ] Simulated Amiga RDB Disk Partition System
>- [ ] Kernel Paravirtualization over Lua VM
>- [x] Pipes and flow redirection
>- [ ] Network Stack (Modem / Linked Card)
>- [x] Memory Management (Garbage Collection & Limits)
>- [x] Multitasking in User-space (Ring 3)
>- [x] Namespace Separation (Sandboxing)
---

## 🏗 System Architecture

Axis OS is built on four core pillars:

### 1. Xen XKA (Kernel)
The kernel (Ring 0) is minimal by design. It handles:
*   **Process Scheduling:** Cooperative multitasking with priority queues.
*   **Memory Sandboxing:** Strict environment isolation. User processes have no access to the global `_G`.
*   **Privilege Rings:**
    *   **Ring 0:** Kernel / Hardware abstraction.
    *   **Ring 1:** System Services (Pipeline Manager, DKMS).
    *   **Ring 2:** Drivers.
    *   **Ring 3:** User-space applications.

### 2. AXON (Driver Model)
The **Abstract Xen Object Network** replaces direct component access.
*   **Virtual Devices:** User programs write to virtual nodes (e.g., `/dev/tty`, `/dev/gpu0`) instead of calling `component.invoke`.
*   **DKMS Supervisor:** The Dynamic Kernel Module System manages driver lifecycles and provides a Watchdog service to restart crashed drivers without a kernel panic.
*   **IRP Flow:** All I/O is handled via **I/O Request Packets**. A `write()` call generates an IRP, which passes through the Pipeline Manager to the specific driver.

### 3. Synapse IPC
Inter-Process Communication protocol. Since processes are fully isolated, they communicate via signals. The kernel acts as the message bus, routing signals between User Space, the Virtual File System (VFS), and Drivers.

### 4. RKA (Security)
The **Ringed Kernel Authority** replaces standard permission checks.
*   **Handles vs. FDs:** File Descriptors are process-local. A process cannot guess or access another process's open files.
*   **ACLs:** Granular file permissions beyond standard UNIX bits (defined in `/etc/perms.lua`).
*   **RPL Checks:** *Requested Privilege Level* checks prevent "Confused Deputy" attacks, ensuring drivers do not perform privileged actions on behalf of unprivileged users.

---

## ⚡ Installation

**Requirements:**
*   Tier 3 CPU (APU recommended).
*   Tier 3 RAM (minimum 2 sticks).
*   Tier 3 HDD or RAID.

**Installation:**
no current installer