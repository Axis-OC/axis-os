# 5.1. VFS Architecture

The Virtual File System in AxisOS is unique because it is primarily implemented in **Ring 1** by the **Pipeline Manager**, not the kernel.

## The Syscall Override Mechanism

1.  **Kernel VFS**: The kernel implements primitive `vfs_*` syscalls that only work with the boot filesystem (using `primitive_load`).
2.  **Pipeline Manager Interception**: Upon boot, the Pipeline Manager calls `syscall("syscall_override", "vfs_open")` (and others).
3.  **Routing**:
    *   When a user calls `fs.open()`, the kernel routes the request to the Pipeline Manager.
    *   **Files**: If the path is a regular file, the PM handles it via the root FS proxy.
    *   **Devices (`/dev/`)**: If the path starts with `/dev/`, the PM constructs an IRP and sends a `vfs_io_request` signal to the **DKMS**.

## The `/dev` Namespace

The Pipeline Manager does not "know" about devices. It simply acts as a router.
1.  PM receives `open("/dev/tty")`.
2.  PM asks DKMS to handle it.
3.  DKMS looks up the device object for `/dev/tty`.
4.  DKMS dispatches `IRP_MJ_CREATE` to the TTY Driver process.
5.  Result is bubbled back: Driver -> DKMS -> PM -> User.