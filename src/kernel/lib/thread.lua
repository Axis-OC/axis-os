--
-- /lib/thread.lua
-- Multithreading library for AxisOS Ring 3.
-- v2: Proper join, kill, status, and detach.
--     Threads run cooperatively in user-space via the kernel scheduler.
--

local oSys = require("syscall")
local oThread = {}

-- Thread state constants (mirrors kernel process status)
oThread.RUNNING  = "running"
oThread.READY    = "ready"
oThread.SLEEPING = "sleeping"
oThread.DEAD     = "dead"

-- Creates a new thread from a function.
-- The thread shares the parent process's sandbox (globals, env, fds).
-- Returns a thread object or nil + error.
function oThread.create(fFunc)
  if type(fFunc) ~= "function" then
    return nil, "Argument must be a function"
  end

  local nPid, sErr = syscall("process_thread", fFunc)
  
  if not nPid then
    return nil, sErr or "Failed to create thread"
  end
  
  local tThreadObj = {
    pid = nPid,
    _detached = false,
    _joined = false,
  }
  
  -- Wait for the thread to finish. Blocks the calling thread.
  function tThreadObj:join()
    if self._joined then return true end
    if self._detached then return nil, "Cannot join detached thread" end
    self._joined = true
    return oSys.wait(self.pid)
  end
  
  -- Kill the thread. Sends SIGKILL equivalent.
  function tThreadObj:kill()
    local bOk, sErr = syscall("process_kill", self.pid)
    return bOk, sErr
  end
  
  -- Check if the thread is still alive.
  function tThreadObj:alive()
    local sStatus = syscall("process_status", self.pid)
    return sStatus and sStatus ~= "dead"
  end
  
  -- Get thread status string.
  function tThreadObj:status()
    return syscall("process_status", self.pid) or "dead"
  end
  
  -- Detach the thread. It will clean up on its own when done.
  function tThreadObj:detach()
    self._detached = true
  end
  
  return tThreadObj
end

-- Yield the current thread's timeslice to let others run.
function oThread.yield()
  syscall("process_yield")
end

-- Sleep the current thread for approximately nSeconds.
function oThread.sleep(nSeconds)
  local nDeadline = require("computer").uptime() + nSeconds
  while require("computer").uptime() < nDeadline do
    syscall("process_wait", 0)
  end
end

-- Get a list of thread PIDs spawned by the current process.
function oThread.list()
  return syscall("process_list_threads") or {}
end

-- Spawn multiple threads and wait for all of them.
-- tFuncs is a list of functions. Returns when all complete.
function oThread.parallel(tFuncs)
  local tThreads = {}
  for _, fFunc in ipairs(tFuncs) do
    local t, sErr = oThread.create(fFunc)
    if t then
      table.insert(tThreads, t)
    end
  end
  for _, t in ipairs(tThreads) do
    t:join()
  end
  return #tThreads
end

return oThread