## 3. Ring Model & Process Security

### 3.1 Privilege Rings

AxisOS enforces a five-level privilege model:

```
  Ring 0 ──── Kernel         (kernel.lua, PID 0)
    │         Full hardware access, raw_component, raw_computer
    │
  Ring 1 ──── System Services (PM, DKMS)
    │         Can override syscalls, manage drivers
    │
  Ring 2 ──── Kernel Drivers  (KMD, CMD)
    │         Can create devices, access hardware proxies
    │
  Ring 2.5 ── Elevated User   (via 'su' command)
    │         Hybrid: user sandbox + some kernel access
    │
  Ring 3 ──── User Processes  (init, sh, commands)
              Sandboxed, all I/O through syscalls
```

### 3.2 Sandbox Construction

Each process receives a Lua environment table created by `kernel.create_sandbox(nPid, nRing)`. The sandbox provides:

| Feature | Ring 0 | Ring 1 | Ring 2 | Ring 2.5 | Ring 3 |
|---------|--------|--------|--------|----------|--------|
| `raw_component` | ✅ | ❌ | ❌ | ❌ | ❌ |
| `raw_computer` | ✅ | ❌ | ❌ | ❌ | ❌ |
| `kernel` table | ✅ | ❌ | ❌ | ❌ | ❌ |
| `syscall()` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `require()` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `__pc()` preemption | ❌ | ❌ | ❌ | ✅ | ✅ |
| `os.exit` / `os.execute` | ❌ | ❌ | ❌ | ❌ | ❌ |

### 3.3 Process Creation Rules

A process can only spawn children at **equal or lower privilege**:

```lua
-- Ring 3 process trying to spawn Ring 2:
local pid = syscall("process_spawn", "/drivers/my.sys.lua", 2)
-- Returns: nil, "Permission denied: cannot spawn higher-privilege process"
```

### 3.4 Syscall Ring Checks

Every syscall definition includes an `allowed_rings` table. The dispatcher rejects calls from unauthorized rings:

```lua
kernel.tSyscallTable["kernel_panic"] = {
  func = function(nPid, sReason) kernel.panic(sReason) end,
  allowed_rings = {0, 1, 2}  -- Ring 3 cannot trigger panic
}
```

If a Ring 3 process attempts a restricted syscall, the kernel **terminates the process** and logs a ring violation.

---