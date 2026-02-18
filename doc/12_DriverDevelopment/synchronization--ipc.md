## 13. Synchronization & IPC

### 13.1 Overview

The Kernel IPC subsystem (`/lib/ke_ipc.lua`) provides Windows NT-style synchronization objects combined with POSIX signals. All primitives are accessible from user space through the `sync`, `pipe`, `signal_lib`, and `ipc` libraries.

### 13.2 Events

Events are the simplest synchronization primitive. An event can be **signaled** or **non-signaled**.

```lua
local sync = require("sync")

-- Auto-reset event: resets to non-signaled after one waiter wakes
local hEvt = sync.createEvent(false, false)

-- Thread A: wait for event
sync.wait(hEvt)  -- blocks until signaled

-- Thread B: signal the event
sync.setEvent(hEvt)  -- wakes Thread A
```

**Manual-reset events** stay signaled until explicitly reset, waking ALL waiters:

```lua
local hEvt = sync.createEvent(true, false)  -- manual reset
sync.setEvent(hEvt)    -- all waiters wake
sync.resetEvent(hEvt)  -- back to non-signaled
```

### 13.3 Mutexes

Mutexes provide exclusive access with ownership tracking and recursion:

```lua
local sync = require("sync")
local hMtx = sync.createMutex(false)

sync.wait(hMtx)         -- acquire (blocks if already held)
-- ... critical section ...
sync.releaseMutex(hMtx)  -- release
```

> **Note:** Only the owning thread can release a mutex. Recursive acquisition increments an internal counter.

### 13.4 Semaphores

Semaphores control concurrent access with a configurable permit count:

```lua
local hSem = sync.createSemaphore(3, 10)  -- 3 initial, 10 max

sync.wait(hSem)                -- acquire one permit (count--)
sync.releaseSemaphore(hSem, 1) -- release one permit (count++)
```

### 13.5 Pipes

Pipes provide **blocking, buffered** byte streams between processes or threads:

```lua
local pipe = require("pipe")

local p = pipe.create(4096)  -- 4KB buffer

-- Writer thread:
pipe.write(p.write, "Hello from pipe!")
pipe.closeWrite(p.write)

-- Reader thread:
local ok, data = pipe.read(p.read, 1024)
print(data)  -- "Hello from pipe!"
```

**Named pipes** are accessible by name across processes:

```lua
-- Process A:
pipe.createNamed("my_channel", 4096)

-- Process B:
local p = pipe.connectNamed("my_channel")
```

### 13.6 Shared Memory

Shared memory sections provide a Lua table accessible by multiple processes:

```lua
local ipc = require("ipc")

-- Process A: create
local hSec = ipc.createSection("my_shm", 4096)
local tView = ipc.mapSection(hSec)
tView.counter = 0

-- Process B: open
local hSec2 = ipc.openSection("my_shm")
local tView2 = ipc.mapSection(hSec2)
tView2.counter = tView2.counter + 1  -- modifies same table!
```

> **Warning:** Shared memory provides **no automatic synchronization**. Use a mutex to protect concurrent access.

### 13.7 Message Queues

Priority-ordered message queues for inter-process communication:

```lua
local ipc = require("ipc")

local hQ = ipc.createMqueue("my_queue", 64, 1024)

-- Send (priority 10 = high)
ipc.mqSend(hQ, "urgent message", 10)
ipc.mqSend(hQ, "normal message", 1)

-- Receive (highest priority first)
local msg = ipc.mqReceive(hQ, 5000)  -- timeout 5s
print(msg)  -- "urgent message"
```

### 13.8 POSIX Signals

AxisOS implements a subset of POSIX signals:

| Signal | Number | Default Action | Catchable? |
|--------|--------|---------------|------------|
| `SIGHUP` | 1 | Terminate | Yes |
| `SIGINT` | 2 | Terminate | Yes |
| `SIGKILL` | 9 | Terminate | **No** |
| `SIGPIPE` | 13 | Terminate | Yes |
| `SIGTERM` | 15 | Terminate | Yes |
| `SIGCHLD` | 17 | Ignore | Yes |
| `SIGCONT` | 18 | Continue | Yes |
| `SIGSTOP` | 19 | Stop | **No** |
| `SIGUSR1` | 30 | Terminate | Yes |
| `SIGUSR2` | 31 | Terminate | Yes |

```lua
local signal = require("signal_lib")

-- Set handler
signal.handle(signal.SIGUSR1, function(sig)
    print("Got signal: " .. sig)
end)

-- Send signal
signal.send(targetPid, signal.SIGUSR1)
```

Signals are **delivered at `__pc()` checkpoints** (during preemptive scheduling) and at **syscall entry points**, ensuring timely delivery even in computation-heavy code.

### 13.9 WaitForMultipleObjects

Wait for any or all of multiple objects to become signaled:

```lua
local sync = require("sync")

local hEvt1 = sync.createEvent(false, false)
local hEvt2 = sync.createEvent(false, false)

-- Wait for ANY (returns index of signaled object)
local nResult = sync.waitMultiple({hEvt1, hEvt2}, false, 5000)
if nResult == 0 then print("Event 1 fired")
elseif nResult == 1 then print("Event 2 fired")
elseif nResult == 258 then print("Timeout") end

-- Wait for ALL
local nResult = sync.waitMultiple({hEvt1, hEvt2}, true, 5000)
```

### 13.10 IRQL Levels

| Level | Value | Can Block? | Use |
|-------|-------|-----------|-----|
| `PASSIVE_LEVEL` | 0 | Yes | Normal code execution |
| `APC_LEVEL` | 1 | Yes | Signal delivery |
| `DISPATCH_LEVEL` | 2 | **No** | DPC processing |
| `DEVICE_LEVEL` | 3 | **No** | Hardware interrupt context |

---