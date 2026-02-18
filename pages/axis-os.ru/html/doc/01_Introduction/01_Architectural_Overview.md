# 1.1. Architectural Overview

## The Layered Model

AxisOS is structured in a series of layers, each with a distinct set of responsibilities and privileges, enforced by the Ring Model.

- **Ring 0: The Kernel (`kernel.lua`)**: The core of the operating system. It is responsible for fundamental operations: process scheduling, memory management (sandboxing), syscall dispatching, and the initial handling of hardware events. It is the most privileged component but delegates complex logic to Ring 1.

- **Ring 1: System Services (`pipeline_manager.lua`, `dkms.lua`)**: Privileged user-space processes that form the backbone of the OS.
    - **Pipeline Manager (PM)**: The "init" of the system services. It manages the Virtual File System (VFS), handles permissions (`/etc/perms.lua`), and acts as the router for all I/O syscalls. It decides whether a request goes to the physical disk or to a device driver.
    - **DKMS (Dynamic Kernel Module System)**: The Driver Manager. It maintains the device tree, manages driver processes, and routes I/O Request Packets (IRPs) to the appropriate driver.

- **Ring 2: Kernel-Mode Drivers (KMD/CMD)**: Isolated processes that have direct access to hardware components via privileged syscalls. They abstract hardware details and present devices through a standardized I/O interface.
    - **KMD (`*.sys.lua`)**: Standard drivers (e.g., GPU, TTY).
    - **CMD (Component Mode Drivers)**: Specialized drivers that bind 1:1 to specific OpenComputers components (e.g., `iter.sys.lua`).

- **Ring 2.5: User-Mode Driver Hosts (`driverhost.lua`)**: A specialized privilege level for processes that host and supervise less-trusted User-Mode Drivers.

- **Ring 3: Applications and User-Mode Drivers (`init.lua`, `sh.lua`, `*.umd.lua`)**: The least privileged layer. All applications, shells, and standard libraries run here. Access to system resources is strictly mediated through the syscall interface, which is intercepted by the Pipeline Manager.

## Component Diagram

```text
[ Application (Ring 3) ]
       |  syscall("vfs_write")
       v
[ Kernel Dispatcher (Ring 0) ] --(Override)--> [ Pipeline Manager (Ring 1) ]
                                                      |
                                          [ Is it a file? ] --yes--> [ RootFS Proxy ]
                                                      | no (/dev/...)
                                                      v
                                               [ DKMS (Ring 1) ]
                                                      |
                                          [ IRP Dispatch Signal ]
                                                      v
                                            [ Driver Process (Ring 2) ]
                                                      |
                                            [ Hardware / Component ]