## 6. Object Manager (Ob)

### 6.1 Overview

The Object Manager (`/lib/ob_manager.lua`) implements a Windows NT-style object system. Every kernel resource — devices, files, symlinks, events, pipes — is represented as a typed object with reference counting. Processes access objects through **handle tokens**, never through direct pointers.

### 6.2 Object Header

Every object in the system has a header:

```lua
{
    nObjectId       = 1,                  -- unique sequence number
    sType           = "IoDeviceObject",   -- type name
    sName           = "\\Device\\TTY0",   -- path in kernel namespace (or nil)
    nReferenceCount = 2,                  -- total references
    nHandleCount    = 1,                  -- open handles
    tSecurity       = {
        nOwnerUid = 0,
        nGroupGid = 0,
        nMode     = 755,
    },
    pBody           = { ... },            -- type-specific data
    bPermanent      = false,              -- if true, never auto-deleted
    bDeletePending  = false,              -- marked for deletion
    pTypeObject     = <type ref>,         -- back-pointer to type definition
}
```

### 6.3 Object Types

| Type Name | Created By | Contains |
|-----------|-----------|----------|
| `ObpDirectory` | `ObInitSystem()` | Namespace directory node |
| `ObpSymbolicLink` | `DkCreateSymbolicLink()` | Target path string |
| `IoDeviceObject` | `DkCreateDevice()` | Driver back-pointer, device extension |
| `IoFileObject` | PM `vfs_open` | File path, raw handle or device info |
| `IoDriverObject` | DKMS | Driver PID, dispatch table |
| `KeEvent` | `KeCreateEvent()` | Dispatch header, signaled state |
| `KeMutex` | `KeCreateMutex()` | Owner PID, recursion count |
| `KeSemaphore` | `KeCreateSemaphore()` | Count, max |
| `KeTimer` | `KeCreateTimer()` | Deadline, period, DPC |
| `IoPipeObject` | `KeCreatePipe()` | Buffer, read/write state |
| `MmSectionObject` | `KeCreateSection()` | Shared memory table |
| `IpcMessageQueue` | `KeCreateMqueue()` | Priority message list |

### 6.4 Kernel Namespace

Objects can be registered in a global namespace (the **Object Directory**):

```
\                          (root)
├── \Device
│   ├── \Device\TTY0       (IoDeviceObject)
│   ├── \Device\Gpu0       (IoDeviceObject)
│   ├── \Device\Net0       (IoDeviceObject)
│   └── \Device\ringlog    (IoDeviceObject)
├── \DosDevices
├── \ObjectTypes
├── \Pipe
│   └── \Pipe\myfifo       (IoPipeObject)
└── \Section
    └── \Section\shm_test   (MmSectionObject)
```

Symbolic links map user-facing paths to kernel objects:

```
/dev/tty     →  \Device\TTY0
/dev/gpu0    →  \Device\Gpu0
/dev/net     →  \Device\Net0
/dev/ringlog →  \Device\ringlog
```

### 6.5 Handle Tables

Each process has a **handle table** mapping opaque tokens to object references:

```
Process PID 5 Handle Table:
┌──────────────────────────────┬──────────────────┬──────────┬──────────────┐
│ Token                        │ Object Type      │ Access   │ Synapse      │
├──────────────────────────────┼──────────────────┼──────────┼──────────────┤
│ H-a3f21c-0c9ab-12de-00a7    │ IoFileObject     │ 0x0001   │ SYN-4a2b-... │
│ H-b7e109-1a45c-89fe-0013    │ IoFileObject     │ 0x0002   │ SYN-4a2b-... │
│ H-c90def-2b63d-45ab-0029    │ IoFileObject     │ 0x0002   │ SYN-4a2b-... │
└──────────────────────────────┴──────────────────┴──────────┴──────────────┘

Standard Handles:
  -10 (STD_INPUT)  → H-a3f21c-0c9ab-12de-00a7
  -11 (STD_OUTPUT) → H-b7e109-1a45c-89fe-0013
  -12 (STD_ERROR)  → H-c90def-2b63d-45ab-0029
```

### 6.6 Handle Lifecycle

```lua
-- 1. Create object
local pObj = syscall("ob_create_object", "IoFileObject", {
    sPath = "/dev/tty", sCategory = "device", ...
})

-- 2. Create handle (binds to synapse token)
local sToken = syscall("ob_create_handle",
    nCallerPid, pObj, ACCESS_READ, sSynapseToken)

-- 3. Use handle (validated every access)
local pObj = syscall("ob_reference_by_handle",
    nCallerPid, sToken, ACCESS_READ, sSynapseToken)

-- 4. Close handle (decrements ref count)
syscall("ob_close_handle", nCallerPid, sToken)

-- 5. Object auto-deleted when refCount == 0 && handleCount == 0
```

### 6.7 Handle Inheritance

When a process spawns a child, inheritable handles are **duplicated** with new tokens bound to the child's synapse token:

```lua
function ObInheritHandles(nParentPid, nChildPid, sChildSynapseToken)
    -- For each inheritable handle in parent:
    --   1. Reference the object (refCount++)
    --   2. Create new token for child
    --   3. Bind to child's synapse token
    --   4. Copy standard handle mappings
end
```

---