## 5. Preemptive Multitasking

### 5.1 The Problem

OpenComputers runs Lua in a single OS thread. The `debug.sethook` approach (used by OpenOS) is fragile and server-unfriendly. A tight `while true do end` loop without yielding will crash the OC machine after ~5 seconds.

### 5.2 The Solution: Source Instrumentation

AxisOS uses **compile-time source code transformation**. Before any Ring ≥ 2.5 process is loaded, the kernel rewrites its source code to insert yield checkpoints.

The `preempt.lua` module scans source text and injects `__pc();` calls after specific keywords:

| Keyword | Injection Point | Purpose |
|---------|----------------|---------|
| `do` | After `for`/`while`/generic `do` blocks | Loop iteration |
| `then` | After `if`/`elseif` conditions | Branch entry |
| `repeat` | At start of repeat-until body | Loop iteration |
| `else` | At else branch entry (NOT elseif) | Branch entry |

**Example transformation:**

```lua
-- Original:
while running do
  process()
  if done then
    break
  end
end

-- Instrumented:
while running do __pc();
  process()
  if done then __pc();
    break
  end
end
```

### 5.3 The `__pc()` Function

Each Ring ≥ 2.5 sandbox receives a unique `__pc()` closure:

```lua
tSandbox.__pc = function()
    nPcCounter = nPcCounter + 1
    if nPcCounter < nPcInterval then return end  -- fast path: no check
    nPcCounter = 0

    -- Deliver pending signals
    if g_oIpc then ... end

    -- Check time quantum
    local nNow = fUptime()
    if nNow - nPcLastYield >= nPcQuantum then
        coroutine.yield()              -- preempt!
        nPcLastYield = fUptime()       -- reset after resume
    end
end
```

**Configuration parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DEFAULT_QUANTUM` | 50 ms | Maximum CPU time before forced yield |
| `CHECK_INTERVAL` | 256 | `__pc()` calls between wall-clock checks |

### 5.4 Scanner Safety

The instrumenter correctly handles:

- **String literals** (`"..."`, `'...'`) — skipped entirely
- **Long strings** (`[[...]]`, `[=[...]=]`) — skipped
- **Short comments** (`-- ...`) — skipped to end of line
- **Long comments** (`--[[...]]`) — skipped to closing bracket
- **Word boundaries** — `redo`, `done`, `do_something` are NOT matched

### 5.5 Dynamic Code

The sandbox's `load()` is wrapped to also instrument dynamically compiled code:

```lua
tSandbox.load = function(sChunk, sName, sMode, tLoadEnv)
    if type(sChunk) == "string" then
        local sInst, nInj = g_oPreempt.instrument(sChunk, sName)
        if nInj > 0 then sChunk = sInst end
    end
    return fKernelLoad(sChunk, sName, sMode, tLoadEnv or tSandbox)
end
```

### 5.6 Scheduler Loop Integration

After each `coroutine.resume()`, the scheduler detects preemption:

```lua
-- In the main kernel loop:
local bIsOk, sErr = coroutine.resume(tProcess.co, ...)

-- PREEMPTION DETECTION:
-- If status is still "running", the process was preempted by __pc()
-- (it called coroutine.yield() without going through a syscall).
if tProcess.status == "running" then
    tProcess.status = "ready"           -- reschedule next tick
    tProcess.nPreemptCount = tProcess.nPreemptCount + 1
    g_tSchedStats.nPreemptions = g_tSchedStats.nPreemptions + 1
end
```

### 5.7 Watchdog

If a single resume exceeds `WATCHDOG_WARN_THRESHOLD` (2 seconds), the process receives a "strike." After `WATCHDOG_KILL_STRIKES` (3) strikes, the process is killed.

```
[WARN] WATCHDOG: PID 42 ran 2.15s without yielding (strike 1/3)
[WARN] WATCHDOG: PID 42 ran 3.01s without yielding (strike 2/3)
[FAIL] WATCHDOG: Killing PID 42 — exceeded 3 strikes
```

### 5.8 OC Timer Reset

Between every process resume, the scheduler calls `computer.pullSignal(0)` to reset OpenComputers' built-in 5-second timeout. This is **critical** — without it, the cumulative runtime of all processes in one scheduler pass could exceed OC's hard limit.

---