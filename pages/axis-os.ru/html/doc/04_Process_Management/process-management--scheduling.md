## 4. Process Management & Scheduling

### 4.1 Process Lifecycle

```
  create_process()           scheduler resumes        dead/exit
       │                          │                      │
       ▼                          ▼                      ▼
   ┌────────┐  yield/preempt  ┌─────────┐           ┌────────┐
   │ READY  │ ◄──────────────►│ RUNNING │ ────────► │  DEAD  │
   └────┬───┘                 └────┬────┘           └────────┘
        │                          │
        │    syscall blocks        │    waiters
        │    (signal_pull,         │    woken
        │     process_wait,        │
        │     ke_wait_single)      │
        ▼                          │
   ┌──────────┐                    │
   │ SLEEPING │ ───────────────────┘
   │          │    signal received
   └──────────┘    or event signaled
```

### 4.2 Process Table Entry

Each process is stored in `kernel.tProcessTable[nPid]`:

```lua
{
    co             = <coroutine>,       -- Lua coroutine
    status         = "ready",           -- ready | running | sleeping | dead
    ring           = 3,                 -- privilege level
    parent         = 2,                 -- parent PID
    env            = <sandbox table>,   -- process environment
    fds            = {},                -- legacy (handles now in ObManager)
    wait_queue     = {},                -- PIDs waiting for this process to die
    signal_queue   = {},                -- pending IPC signals
    uid            = 1000,              -- user ID
    synapseToken   = "SYN-xxxx-...",    -- sMLTR authentication token
    threads        = {},                -- child thread PIDs
    is_thread      = false,             -- true if this is a thread

    -- Preemptive scheduler stats
    nCpuTime         = 0,              -- total CPU seconds
    nPreemptCount    = 0,              -- times preempted by __pc()
    nLastSlice       = 0,              -- duration of last resume
    nMaxSlice        = 0,              -- longest single resume
    nWatchdogStrikes = 0,              -- watchdog warnings

    -- IPC state (initialized by ke_ipc)
    nIrql             = 0,             -- current IRQL
    tPendingSignals   = {},            -- queued POSIX signals
    tSignalHandlers   = {},            -- signal → handler function
    tSignalMask       = {},            -- blocked signals
    nPgid             = <nPid>,        -- process group ID
}
```

### 4.3 Threads

Threads share the parent's sandbox environment, file descriptors, and synapse token. They are created with `process_thread`:

```lua
-- From user space:
local thread = require("thread")
local t = thread.create(function()
    print("Hello from thread!")
end)
t:join()
```

Internally, `kernel.create_thread(fFunc, nParentPid)` creates a new PID with the parent's `env` table. The child coroutine runs `fFunc` directly.

> **Note:** Threads share mutable state. Use synchronization primitives (mutexes, semaphores) when accessing shared data from multiple threads.

---
