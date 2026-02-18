## 17. User-Space Libraries

### 17.1 `filesystem` (`/lib/filesystem.lua`)

The primary file I/O library. Wraps VFS syscalls with buffering:

```lua
local fs = require("filesystem")

local h = fs.open("/etc/hostname", "r")
local data = fs.read(h, math.huge)
fs.close(h)

-- Device control:
local bOk, result = fs.deviceControl(hDevice, "methodName", {arg1, arg2})
```

**Buffering:** Writes are buffered per-coroutine and flushed on `\n`, `\r`, `\f`, or when the buffer exceeds 2048 bytes.

### 17.2 `http` (`/lib/http.lua`)

HTTP client library built on the internet driver:

```lua
local http = require("http")

-- Simple GET:
local resp = http.get("https://example.com")
print(resp.code, resp.body)

-- Streaming:
local stream = http.open("https://example.com/large")
while true do
    local chunk = stream:read(4096)
    if not chunk then break end
    -- process chunk
end
stream:close()
```

### 17.3 `thread` (`/lib/thread.lua`)

User-space threading library:

```lua
local thread = require("thread")

local t = thread.create(function()
    -- runs in parallel
end)

t:join()    -- wait for completion
t:alive()   -- check if still running
t:kill()    -- terminate thread
t:status()  -- "ready", "running", "sleeping", "dead"

-- Run multiple functions in parallel:
thread.parallel({
    function() task1() end,
    function() task2() end,
    function() task3() end,
})
```

### 17.4 `sync` (`/lib/sync.lua`)

Synchronization primitives:

```lua
local sync = require("sync")

-- Events:
local hEvt = sync.createEvent(manual, initial)
sync.setEvent(h) / sync.resetEvent(h) / sync.pulseEvent(h)

-- Mutexes:
local hMtx = sync.createMutex(owned)
sync.wait(hMtx)
sync.releaseMutex(hMtx)

-- Semaphores:
local hSem = sync.createSemaphore(init, max)
sync.wait(hSem)
sync.releaseSemaphore(hSem, count)

-- Wait:
sync.wait(handle, timeoutMs)
sync.waitMultiple({h1, h2, h3}, waitAll, timeoutMs)

-- Constants:
sync.WAIT_0       -- 0   (success)
sync.WAIT_TIMEOUT -- 258 (timed out)
sync.WAIT_FAILED  -- -1  (error)
```

### 17.5 `syscall` (`/lib/syscall.lua`)

Convenience wrappers for common operations:

```lua
local sys = require("syscall")

sys.spawn(path, ring, env)
sys.wait(pid)
sys.reboot()
sys.shutdown()
sys.getSynapseToken()
```

---

## Appendix A: Configuration Files

| File | Purpose | Format |
|------|---------|--------|
| `/etc/fstab.lua` | Filesystem table | Lua table |
| `/etc/passwd.lua` | User database | Lua table |
| `/etc/perms.lua` | File permissions | Lua table |
| `/etc/autoload.lua` | Drivers to load at boot | Lua array of paths |
| `/etc/sys.cfg` | System configuration | Lua table |
| `/etc/netpolicy.cfg` | Firewall rules | Lua table |
| `/etc/pki.cfg` | Cloud PKI settings | Lua table |
| `/etc/hostname` | Machine name | Plain text |

## Appendix B: Driver API Quick Reference

```lua
-- Common (all drivers):
oKMD.DkPrint(sMessage)

-- KMD API:
oKMD.DkCreateDevice(pDriverObject, sDeviceName) → nStatus, pDevObj
oKMD.DkDeleteDevice(pDeviceObject) → nStatus
oKMD.DkCreateSymbolicLink(sLink, sDevice) → nStatus
oKMD.DkDeleteSymbolicLink(sLink) → nStatus
oKMD.DkCompleteRequest(pIrp, nStatus, vInfo)
oKMD.DkGetHardwareProxy(sAddress) → nStatus, oProxy
oKMD.DkRegisterInterrupt(sEventName) → nStatus
oKMD.DkCreateComponentDevice(pDriverObject, sType) → nStatus, pDevObj
```

## Appendix C: Diagnostic Commands

| Command | Description |
|---------|-------------|
| `ps` | List processes |
| `sched` | Scheduler statistics |
| `sched -p` | Per-process CPU stats |
| `ipcs` | IPC subsystem status |
| `reg tree @VT` | Full registry tree |
| `regedit` | Visual registry editor |
| `logread` | Kernel ring buffer log |
| `smltr_debug` | sMLTR diagnostic suite |
| `preempt_test` | Preemptive scheduling verification |
| `ipc_test` | IPC subsystem test suite |
| `insmod -i <path>` | Inspect driver without loading |

---
