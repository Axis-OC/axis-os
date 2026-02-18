## 8. Pipeline Manager (PM) & VFS

### 8.1 Role

The Pipeline Manager is a Ring 1 process that serves as the **VFS router**. It intercepts all filesystem syscalls via the override mechanism and routes them to either:

- The raw filesystem (for regular files)
- DKMS (for device files under `/dev/`)

### 8.2 Syscall Override Mechanism

During boot, PM registers overrides:

```lua
syscall("syscall_override", "vfs_open")
syscall("syscall_override", "vfs_read")
syscall("syscall_override", "vfs_write")
-- ... etc.
```

When any process calls `syscall("vfs_open", ...)`, the kernel:

1. Detects the override for `"vfs_open"`.
2. Puts the calling process to sleep.
3. Sends an IPC signal to PM with the syscall name, arguments, and the caller's synapse token.
4. PM processes the request and sends `"syscall_return"` back.
5. The kernel wakes the caller with the return values.

### 8.3 VFS Open Flow

```lua
function vfs_state.handle_open(nSenderPid, sSynapseToken, sPath, sMode)
    -- 1. Permission check (unless /dev/)
    if not check_access(nSenderPid, sPath, sMode) then
        return nil, "Permission denied"
    end

    -- 2. Create IoFileObject body
    local tBody = { sPath = sPath, sMode = sMode }

    if sPath starts with "/dev/" then
        -- Route to DKMS: send IRP_MJ_CREATE
        tBody.sCategory = "device"
        tBody.sDeviceName = resolveDeviceName(sPath)
    else
        -- Open on raw filesystem
        tBody.sCategory = "file"
        tBody.hRawHandle = raw_fs.open(sPath, sMode)
    end

    -- 3. Create object in ObManager
    local pObj = syscall("ob_create_object", "IoFileObject", tBody)

    -- 4. Create handle with access mask + synapse token
    local sToken = syscall("ob_create_handle",
        nSenderPid, pObj, nAccess, sSynapseToken)

    -- 5. Auto-assign standard handles for /dev/tty
    if sPath == "/dev/tty" and sMode == "r" then
        syscall("ob_set_standard_handle", nSenderPid, -10, sToken)
    end

    return true, sToken
end
```

### 8.4 Permission System

Permissions are stored in `/etc/perms.lua`:

```lua
return {
    ["/etc/passwd.lua"] = { uid = 0, gid = 0, mode = 600 },
    ["/dev/tty"]        = { uid = 0, gid = 0, mode = 666 },
}
```

The mode is a three-digit octal-style number: `owner|group|other`. PM checks the caller's UID against the file's owner/group and extracts the appropriate permission digit.

---