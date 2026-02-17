--
-- /home/ex_thread.lua
-- The glorious multithreaded future.
-- v2: demonstrates thread.kill, thread.parallel, and thread.alive
--

local thread = require("thread")
local sys = require("syscall")
local computer = require("computer")

local function heavy_task(sName, nTime)
  print(string.format("\27[32m[%s]\27[37m Starting task (%ds)...", sName, nTime))
  
  local nDead = computer.uptime() + nTime
  while computer.uptime() < nDead do
     thread.yield() -- cooperatively yield to other threads
  end
  
  print(string.format("\27[32m[%s]\27[37m Done!", sName))
end

print("--- Multi Threaded Demo (v2) ---")

-- Show our synapse token (sMLTR)
local sToken = sys.getSynapseToken()
if sToken then
  print("\27[90mSynapse Token: " .. sToken:sub(1, 20) .. "...\27[37m")
end

local nStart = computer.uptime()

-- Method 1: Manual thread management
print("\n\27[36m[Test 1] Manual thread create/join\27[37m")
local t1 = thread.create(function() heavy_task("Downloader", 2) end)
local t2 = thread.create(function() heavy_task("Renderer", 2) end)

if t1 and t2 then
  print("Threads spawned. PIDs: " .. t1.pid .. ", " .. t2.pid)
  
  -- Check alive status
  print("t1 alive: " .. tostring(t1:alive()))
  print("t2 alive: " .. tostring(t2:alive()))
  
  t1:join()
  t2:join()
  
  print("t1 alive after join: " .. tostring(t1:alive()))
end

-- Method 2: Parallel helper
print("\n\27[36m[Test 2] thread.parallel()\27[37m")
local nParallelStart = computer.uptime()

thread.parallel({
  function() heavy_task("TaskA", 1) end,
  function() heavy_task("TaskB", 1) end,
  function() heavy_task("TaskC", 1) end,
})

print(string.format("Parallel block took: %.2fs", computer.uptime() - nParallelStart))

-- Method 3: List active threads
print("\n\27[36m[Test 3] Active thread list\27[37m")
local tActive = thread.list()
print("Active threads from parent: " .. #tActive)

local nTotal = computer.uptime() - nStart
print(string.format("\n\27[33mTotal time: %.2f seconds\27[37m", nTotal))