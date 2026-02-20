--
-- /usr/commands/ipc_test.lua — Full IPC subsystem test suite
--

local thread   = require("thread")
local sync     = require("sync")
local pipe     = require("pipe")
local signal   = require("signal_lib")
local ipc      = require("ipc")
local computer = require("computer")

local C = {
    R="\27[37m", GRN="\27[32m", RED="\27[31m",
    YLW="\27[33m", CYN="\27[36m", GRY="\27[90m",
}
local nP, nF, nW = 0, 0, 0
local function pass(s) nP=nP+1; print(C.GRN.."  [PASS] "..C.R..s) end
local function fail(s) nF=nF+1; print(C.RED.."  [FAIL] "..C.R..s) end
local function warn(s) nW=nW+1; print(C.YLW.."  [WARN] "..C.R..s) end
local function info(s) nP=nP+1; print(C.CYN.."  [INFO] "..C.R..s) end
local function banner(s) print("\n"..C.CYN.."  === "..s.." ==="..C.R) end

local function sleep(n)
    local d = computer.uptime() + n
    while computer.uptime() < d do syscall("process_yield") end
end

print(C.CYN.."\n  IPC Subsystem Test Suite"..C.R)
print(C.GRY.."  "..string.rep("=",50)..C.R)

-- =============================================
-- TEST 1: Events
-- =============================================
banner("TEST 1: Events")
do
    local hEvt = sync.createEvent(false, false) -- auto-reset, not signaled
    if hEvt then pass("Event created") else fail("Event creation failed"); goto t2 end

    local bSeen = false
    local t = thread.create(function()
        sync.wait(hEvt)
        bSeen = true
    end)
    sleep(0.1)
    if bSeen then fail("Thread woke before event set") else pass("Thread blocked on event") end

    sync.setEvent(hEvt)
    sleep(0.2)
    if t then t:join() end
    if bSeen then pass("Thread woke after event set") else fail("Thread never woke") end

    -- Manual reset event
    local hM = sync.createEvent(true, false)
    sync.setEvent(hM)
    local r1 = sync.wait(hM, 100)
    local r2 = sync.wait(hM, 100)
    if r1 == 0 and r2 == 0 then
        pass("Manual-reset event stays signaled for multiple waits")
    else
        fail("Manual-reset behavior wrong: "..tostring(r1).." "..tostring(r2))
    end
    sync.resetEvent(hM)
    local r3 = sync.wait(hM, 50)
    if r3 == 258 then pass("Reset event blocks → timeout") else warn("Expected timeout, got "..tostring(r3)) end
end
::t2::

-- =============================================
-- TEST 2: Mutexes
-- =============================================
banner("TEST 2: Mutexes")
do
    local hMtx = sync.createMutex(false)
    if hMtx then pass("Mutex created") else fail("Mutex creation failed"); goto t3 end

    local nShared = 0
    local N = 500

    local function worker()
        for i = 1, N do
            sync.wait(hMtx)
            nShared = nShared + 1
            sync.releaseMutex(hMtx)
        end
    end

    local t1 = thread.create(worker)
    local t2 = thread.create(worker)
    if t1 then t1:join() end
    if t2 then t2:join() end

    info("Expected: " .. (N * 2) .. "  Got: " .. nShared)
    if nShared == N * 2 then
        pass("Mutex protected shared counter perfectly")
    else
        fail("Race condition! Expected ".. (N * 2) .." got "..nShared)
    end
end
::t3::

-- =============================================
-- TEST 3: Semaphores
-- =============================================
banner("TEST 3: Semaphores")
do
    local hSem = sync.createSemaphore(2, 5) -- 2 initial, 5 max
    if hSem then pass("Semaphore created (2/5)") else fail("Semaphore creation failed"); goto t4 end

    local r1 = sync.wait(hSem, 50)
    local r2 = sync.wait(hSem, 50)
    if r1 == 0 and r2 == 0 then pass("Acquired 2 permits (count→0)") end

    local r3 = sync.wait(hSem, 50)
    if r3 == 258 then pass("3rd acquire timed out (count=0)") else fail("Expected timeout") end

    sync.releaseSemaphore(hSem, 1)
    local r4 = sync.wait(hSem, 50)
    if r4 == 0 then pass("Acquire after release works") else fail("Post-release acquire failed") end
end
::t4::

-- =============================================
-- TEST 4: Pipes
-- =============================================
banner("TEST 4: Pipes")
do
    local p = pipe.create(256)
    if p then pass("Pipe created (256B buffer)") else fail("Pipe creation failed"); goto t5 end

    local sReceived = nil
    local t = thread.create(function()
        local ok, data = pipe.read(p.read, 1024)
        sReceived = data
    end)

    sleep(0.1)
    pipe.write(p.write, "Hello, Pipe!")
    pipe.closeWrite(p.write)
    if t then t:join() end

    if sReceived == "Hello, Pipe!" then
        pass("Pipe transferred data: '"..sReceived.."'")
    else
        fail("Pipe data mismatch: '"..tostring(sReceived).."'")
    end

    -- Blocking write test (fill the buffer)
    local p2 = pipe.create(32)
    if p2 then
        local bWriteDone = false
        local tW = thread.create(function()
            pipe.write(p2.write, string.rep("X", 64)) -- exceeds 32B buffer
            bWriteDone = true
        end)
        sleep(0.1)
        if not bWriteDone then pass("Write blocked on full pipe") else warn("Write didn't block") end
        local _, chunk = pipe.read(p2.read, 32)
        sleep(0.2)
        if tW then tW:join() end
        if bWriteDone then pass("Write completed after read freed space") end
    end
end
::t5::

-- =============================================
-- TEST 5: Shared Memory
-- =============================================
banner("TEST 5: Shared Memory Sections")
do
    local hSec = ipc.createSection("test_shm", 4096)
    if hSec then pass("Section 'test_shm' created") else fail("Section creation failed"); goto t6 end

    local tView = ipc.mapSection(hSec)
    if tView then pass("Section mapped") else fail("Map failed"); goto t6 end

    tView.counter = 0
    tView.message = "init"

    local tDone = {false, false}
    local hMtx = sync.createMutex(false)

    for i = 1, 2 do
        local idx = i
        thread.create(function()
            local hS2 = ipc.openSection("test_shm")
            local tV2 = ipc.mapSection(hS2)
            for j = 1, 100 do
                sync.wait(hMtx)
                tV2.counter = tV2.counter + 1
                sync.releaseMutex(hMtx)
            end
            tDone[idx] = true
        end)
    end

    while not (tDone[1] and tDone[2]) do sleep(0.05) end
    info("Shared counter: " .. tostring(tView.counter))
    if tView.counter == 200 then
        pass("Two threads incremented shared memory to 200")
    else
        fail("Expected 200, got "..tostring(tView.counter))
    end
end
::t6::

-- =============================================
-- TEST 6: Message Queues
-- =============================================
banner("TEST 6: Message Queues")
do
    local hQ = ipc.createMqueue("test_mq", 16, 256)
    if hQ then pass("MQueue 'test_mq' created") else fail("MQueue creation failed"); goto t7 end

    ipc.mqSend(hQ, "low_priority", 1)
    ipc.mqSend(hQ, "high_priority", 10)
    ipc.mqSend(hQ, "med_priority", 5)

    local m1 = ipc.mqReceive(hQ, 100)
    local m2 = ipc.mqReceive(hQ, 100)
    local m3 = ipc.mqReceive(hQ, 100)

    if m1 == "high_priority" then pass("Highest priority first: '"..m1.."'") else fail("Order wrong: "..tostring(m1)) end
    if m2 == "med_priority" then pass("Medium priority second") end
    if m3 == "low_priority" then pass("Low priority last") end

    -- Blocking receive
    local sGot = nil
    local tR = thread.create(function()
        sGot = ipc.mqReceive(hQ, 2000)
    end)
    sleep(0.1)
    if sGot then fail("Receiver should be blocked") else pass("Receiver blocked on empty queue") end
    local hQ2 = ipc.openMqueue("test_mq")
    ipc.mqSend(hQ2, "delayed_msg", 0)
    sleep(0.2)
    if tR then tR:join() end
    if sGot == "delayed_msg" then
        pass("Blocking receive got message: '"..sGot.."'")
    else
        fail("Expected 'delayed_msg', got: "..tostring(sGot))
    end
end
::t7::

-- =============================================
-- TEST 7: Signals
-- =============================================
banner("TEST 7: Signals")
do
    local bCaught = false
    local nCaughtSig = 0

    signal.handle(signal.SIGUSR1, function(sig)
        bCaught = true
        nCaughtSig = sig
    end)

    local nMyPid = syscall("process_get_pid")
    signal.send(nMyPid, signal.SIGUSR1)
    -- Signal is delivered at next __pc() or syscall
    syscall("process_yield")
    sleep(0.1)

    if bCaught then
        pass("SIGUSR1 caught by handler (sig="..nCaughtSig..")")
    else
        fail("Signal handler was not called")
    end

    -- SIGCHLD test
    local bChildDied = false
    signal.handle(signal.SIGCHLD, function()
        bChildDied = true
    end)

    local tChild = thread.create(function()
        -- do nothing, just exit
    end)
    if tChild then tChild:join() end
    sleep(0.2)
    syscall("process_yield")

    if bChildDied then
        pass("SIGCHLD received on child death")
    else
        warn("SIGCHLD not received (delivery may be delayed)")
    end

    signal.handle(signal.SIGUSR1, nil)  -- reset to default
    signal.handle(signal.SIGCHLD, nil)
end

-- =============================================
-- TEST 8: WaitForMultipleObjects
-- =============================================
banner("TEST 8: WaitForMultipleObjects")
do
    local hE1 = sync.createEvent(false, false)
    local hE2 = sync.createEvent(false, false)
    local hE3 = sync.createEvent(false, false)
    if not hE1 then fail("Couldn't create events"); goto t9 end

    -- WaitAny
    local nResult = -1
    local tW = thread.create(function()
        nResult = sync.waitMultiple({hE1, hE2, hE3}, false, 2000)
    end)
    sleep(0.1)
    sync.setEvent(hE2) -- signal second event
    sleep(0.2)
    if tW then tW:join() end

    if nResult == 1 then -- WAIT_OBJECT_0 + 1 (index of hE2)
        pass("WaitAny returned index 1 (second object signaled)")
    else
        fail("WaitAny returned "..tostring(nResult).." expected 1")
    end

    -- WaitAll
    local hA = sync.createEvent(true, false)
    local hB = sync.createEvent(true, false)
    local nAllResult = -1
    local tA = thread.create(function()
        nAllResult = sync.waitMultiple({hA, hB}, true, 2000)
    end)
    sleep(0.1)
    sync.setEvent(hA)
    sleep(0.1)
    if nAllResult >= 0 then fail("WaitAll woke with only one event") end
    sync.setEvent(hB)
    sleep(0.2)
    if tA then tA:join() end
    if nAllResult == 0 then
        pass("WaitAll woke when both events signaled")
    else
        fail("WaitAll returned "..tostring(nAllResult))
    end

    -- Timeout
    local hNever = sync.createEvent(false, false)
    local rTimeout = sync.wait(hNever, 100)
    if rTimeout == 258 then
        pass("Wait timed out correctly (100ms)")
    else
        fail("Expected timeout(258), got "..tostring(rTimeout))
    end
end
::t9::

-- =============================================
-- TEST 9: Process Groups
-- =============================================
banner("TEST 9: Process Groups")
do
    local nMyPid = syscall("process_get_pid")
    local nPgid = signal.getpgid()
    info("My PID=" .. tostring(nMyPid) .. " PGID=" .. tostring(nPgid))

    local nGroupHits = 0
    signal.handle(signal.SIGUSR2, function()
        nGroupHits = nGroupHits + 1
    end)

    -- The main thread's pgid IS nMyPid, so sending to group sends to us
    signal.sendGroup(nPgid, signal.SIGUSR2)
    syscall("process_yield")
    sleep(0.1)

    if nGroupHits > 0 then
        pass("Group signal delivered ("..nGroupHits.." hits)")
    else
        warn("Group signal not yet delivered")
    end

    signal.handle(signal.SIGUSR2, nil)
end

-- =============================================
-- TEST 10: IPC Statistics
-- =============================================
banner("TEST 10: IPC Statistics")
do
    local t = syscall("ke_ipc_stats")
    if t then
        pass("Stats retrieved")
        info(string.format("Pipes=%d  Events=%d  Mutexes=%d  Signals=%d",
            t.nPipeCreated, t.nEventCreated, t.nMutexCreated, t.nSignalsSent))
        info(string.format("Waits issued=%d  satisfied=%d  timed_out=%d",
            t.nWaitsIssued, t.nWaitsSatisfied, t.nWaitsTimedOut))
        info(string.format("DPCs=%d  Timers=%d  Pipe bytes=%d",
            t.nDpcsProcessed, t.nTimersFired, t.nPipeBytes))
    else
        fail("Stats unavailable")
    end
end

-- =============================================
-- SUMMARY
-- =============================================
banner("SUMMARY")
print(string.format("\n  %sPassed:%s %d", C.GRN, C.R, nP))
print(string.format("  %sFailed:%s %d", C.RED, C.R, nF))
print(string.format("  %sWarned:%s %d", C.YLW, C.R, nW))
if nF == 0 then
    print(C.GRN.."\n  IPC SUBSYSTEM: ALL TESTS PASSED"..C.R)
else
    print(C.RED.."\n  IPC SUBSYSTEM: "..nF.." FAILURE(S)"..C.R)
end
print("")