--
-- /lib/ke_ipc.lua
-- AxisOS Kernel Executive IPC Subsystem
-- NT/POSIX Hybrid: IRQL, DPC, Timers, Waitable Objects, Events,
-- Mutexes, Semaphores, Pipes, Shared Memory, Message Queues,
-- Signals, Process Groups, WaitForMultipleObjects
--

local oIpc = {}

-- =============================================
-- 1. CONSTANTS
-- =============================================

oIpc.PASSIVE_LEVEL  = 0
oIpc.APC_LEVEL      = 1
oIpc.DISPATCH_LEVEL = 2
oIpc.DEVICE_LEVEL   = 3

oIpc.STATUS_WAIT_0        = 0
oIpc.STATUS_TIMEOUT       = 258
oIpc.STATUS_ABANDONED     = 0x80
oIpc.STATUS_IO_COMPLETION = 0xC0
oIpc.STATUS_FAILED        = -1

oIpc.WAIT_TYPE_EVENT     = 1
oIpc.WAIT_TYPE_MUTEX     = 2
oIpc.WAIT_TYPE_SEMAPHORE = 3
oIpc.WAIT_TYPE_TIMER     = 4
oIpc.WAIT_TYPE_PIPE      = 5
oIpc.WAIT_TYPE_MQUEUE    = 6

oIpc.SIGHUP=1  oIpc.SIGINT=2  oIpc.SIGQUIT=3  oIpc.SIGILL=4
oIpc.SIGABRT=6 oIpc.SIGKILL=9 oIpc.SIGPIPE=13 oIpc.SIGALRM=14
oIpc.SIGTERM=15 oIpc.SIGCHLD=17 oIpc.SIGCONT=18 oIpc.SIGSTOP=19
oIpc.SIGTSTP=20 oIpc.SIGUSR1=30 oIpc.SIGUSR2=31

local DFL_TERM="terminate" local DFL_IGN="ignore"
local DFL_STOP="stop"      local DFL_CONT="continue"
local g_tDefAct = {
    [1]=DFL_TERM,[2]=DFL_TERM,[3]=DFL_TERM,[4]=DFL_TERM,
    [6]=DFL_TERM,[9]=DFL_TERM,[13]=DFL_TERM,[14]=DFL_TERM,
    [15]=DFL_TERM,[17]=DFL_IGN,[18]=DFL_CONT,[19]=DFL_STOP,
    [20]=DFL_STOP,[30]=DFL_TERM,[31]=DFL_TERM,
}

oIpc.DEFAULT_PIPE_SIZE = 4096
oIpc.MAX_PIPE_SIZE     = 65536
oIpc.DEFAULT_MQ_MAX    = 64
oIpc.DEFAULT_MQ_SIZE   = 1024

-- =============================================
-- 2. INTERNAL STATE
-- =============================================

local g_tPT       = nil
local g_fUp       = nil
local g_fLog      = nil
local g_oOb       = nil
local g_fYield    = nil

local g_tDpcQueue = {}
local g_nDpcNext  = 1
local g_tTimers   = {}
local g_nTimerNext= 1
local g_tNamedPipes = {}
local g_tSections  = {}
local g_tMQueues   = {}
local g_tProcGroups= {}

-- Timeout registry: [nPid] = { nDeadline, tDH (optional), tDHList (optional) }
-- Checked each Tick(). When deadline passes, sleeping process is woken
-- with _nWaitResult = STATUS_TIMEOUT.
local g_tWaitTimeouts = {}

local g_tStats = {
    nDpcsProcessed = 0,
    nTimersFired   = 0,
    nSignalsSent   = 0,
    nSignalsDelivered = 0,
    nPipeCreated   = 0,
    nPipeBytes     = 0,
    nWaitsIssued   = 0,
    nWaitsSatisfied= 0,
    nWaitsTimedOut = 0,
    nMutexCreated  = 0,
    nEventCreated  = 0,
    nSemCreated    = 0,
    nSectionCreated= 0,
    nMqCreated     = 0,
}

-- =============================================
-- 3. INITIALIZE
-- =============================================

function oIpc.Initialize(tK)
    g_tPT    = tK.tProcessTable
    g_fUp    = tK.fUptime
    g_fLog   = tK.fLog
    g_oOb    = tK.oObManager
    g_fYield = tK.fYield
    g_fLog("[IPC] Kernel IPC subsystem initialized")
    g_fLog("[IPC]   IRQL, DPC, Timers, Events, Mutexes, Semaphores")
    g_fLog("[IPC]   Pipes, Shared Memory, Message Queues, Signals")
    g_fLog("[IPC]   WaitForMultipleObjects, Process Groups")
end

-- =============================================
-- 4. IRQL MANAGEMENT
-- =============================================

function oIpc.KeGetCurrentIrql(nPid)
    local p = g_tPT[nPid]
    return p and (p.nIrql or oIpc.PASSIVE_LEVEL) or oIpc.PASSIVE_LEVEL
end

function oIpc.KeRaiseIrql(nPid, nNewIrql)
    local p = g_tPT[nPid]
    if not p then return oIpc.PASSIVE_LEVEL end
    local nOld = p.nIrql or oIpc.PASSIVE_LEVEL
    if nNewIrql < nOld then
        g_fLog("[IPC] WARNING: KeRaiseIrql called to LOWER (pid="..nPid..")")
    end
    p.nIrql = nNewIrql
    return nOld
end

function oIpc.KeLowerIrql(nPid, nNewIrql)
    local p = g_tPT[nPid]
    if not p then return end
    p.nIrql = nNewIrql
end

local function fCanBlock(nPid)
    local p = g_tPT[nPid]
    if not p then return false end
    return (p.nIrql or 0) < oIpc.DISPATCH_LEVEL
end

-- =============================================
-- 5. WAITABLE OBJECT CORE
-- =============================================

local function fNewDispatchHeader(nType, bManualReset, bInitSignaled)
    return {
        nType        = nType,
        bSignaled    = bInitSignaled or false,
        bManualReset = bManualReset or false,
        tWaitList    = {},   -- {nPid, nWaitKey}
    }
end

-- Wake processes waiting on an object. Returns count woken.
local function fSignalObject(tDH)
    if not tDH then return 0 end
    tDH.bSignaled = true
    local nWoken = 0

    for _, tEntry in ipairs(tDH.tWaitList) do
        local tWaiter = g_tPT[tEntry.nPid]
        if tWaiter and tWaiter.status == "sleeping" then
            if tWaiter._tWaitCtx then
                local ctx = tWaiter._tWaitCtx
                if ctx.bWaitAll then
                    local bAllReady = true
                    for _, tWO in ipairs(ctx.tWaitObjs) do
                        if not tWO.tDH.bSignaled then bAllReady = false; break end
                    end
                    if bAllReady then
                        for _, tWO in ipairs(ctx.tWaitObjs) do
                            if not tWO.tDH.bManualReset then tWO.tDH.bSignaled = false end
                        end
                        tWaiter._nWaitResult = oIpc.STATUS_WAIT_0
                        tWaiter.status = "ready"
                        tWaiter._tWaitCtx = nil
                        g_tWaitTimeouts[tEntry.nPid] = nil
                        nWoken = nWoken + 1
                    end
                else
                    if not tDH.bManualReset then tDH.bSignaled = false end
                    tWaiter._nWaitResult = oIpc.STATUS_WAIT_0 + (tEntry.nWaitKey or 0)
                    tWaiter.status = "ready"
                    tWaiter._tWaitCtx = nil
                    g_tWaitTimeouts[tEntry.nPid] = nil
                    nWoken = nWoken + 1
                end
            else
                if not tDH.bManualReset then tDH.bSignaled = false end
                tWaiter._nWaitResult = oIpc.STATUS_WAIT_0
                tWaiter.status = "ready"
                g_tWaitTimeouts[tEntry.nPid] = nil
                nWoken = nWoken + 1
            end

            if not tDH.bManualReset and nWoken > 0 then break end
        end
    end

    if nWoken > 0 then
        local tNew = {}
        for _, tEntry in ipairs(tDH.tWaitList) do
            local tW = g_tPT[tEntry.nPid]
            if tW and tW.status == "sleeping" then
                table.insert(tNew, tEntry)
            end
        end
        tDH.tWaitList = tNew
    end

    return nWoken
end

local function fUnsignalObject(tDH)
    if tDH then tDH.bSignaled = false end
end

local function fAddWaiter(tDH, nPid, nWaitKey)
    table.insert(tDH.tWaitList, {nPid = nPid, nWaitKey = nWaitKey or 0})
end

local function fRemoveWaiter(tDH, nPid)
    local tNew = {}
    for _, e in ipairs(tDH.tWaitList) do
        if e.nPid ~= nPid then table.insert(tNew, e) end
    end
    tDH.tWaitList = tNew
end

-- =============================================
-- 6. DPC QUEUE
-- =============================================

function oIpc.KeQueueDpc(fCallback, vArg1, vArg2)
    local nId = g_nDpcNext; g_nDpcNext = g_nDpcNext + 1
    table.insert(g_tDpcQueue, {
        nId = nId, fCb = fCallback, a1 = vArg1, a2 = vArg2
    })
    return nId
end

function oIpc.KeCancelDpc(nId)
    for i = #g_tDpcQueue, 1, -1 do
        if g_tDpcQueue[i].nId == nId then
            table.remove(g_tDpcQueue, i)
            return true
        end
    end
    return false
end

function oIpc.ProcessDpcQueue()
    local nProcessed = 0
    while #g_tDpcQueue > 0 do
        local tDpc = table.remove(g_tDpcQueue, 1)
        local bOk, sErr = pcall(tDpc.fCb, tDpc.a1, tDpc.a2)
        if not bOk then
            g_fLog("[IPC] DPC " .. tDpc.nId .. " crashed: " .. tostring(sErr))
        end
        nProcessed = nProcessed + 1
        g_tStats.nDpcsProcessed = g_tStats.nDpcsProcessed + 1
        if nProcessed > 64 then break end  -- prevent DPC storms
    end
    return nProcessed
end

-- =============================================
-- 7. TIMER SYSTEM
-- =============================================

function oIpc.KeCreateTimer(nPid)
    local tBody = {
        tDH = fNewDispatchHeader(oIpc.WAIT_TYPE_TIMER, true, false),
        nDeadline  = 0,
        nPeriodMs  = 0,
        fDpc       = nil,
        vDpcArg    = nil,
        bActive    = false,
    }
    local pH = g_oOb.ObCreateObject("KeTimer", tBody)
    local sSyn = g_tPT[nPid] and g_tPT[nPid].synapseToken or ""
    local sH = g_oOb.ObCreateHandle(nPid, pH, 0x007F, sSyn)
    local nId = g_nTimerNext; g_nTimerNext = g_nTimerNext + 1
    tBody.nTimerId = nId
    g_tTimers[nId] = tBody
    return sH, nId
end

function oIpc.KeSetTimer(nPid, sHandle, nDelayMs, nPeriodMs, fDpc, vArg)
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sHandle, 0, g_tPT[nPid] and g_tPT[nPid].synapseToken or "")
    if not pH then return false, "Invalid handle" end
    local b = pH.pBody
    b.nDeadline = g_fUp() + (nDelayMs / 1000)
    b.nPeriodMs = nPeriodMs or 0
    b.fDpc = fDpc
    b.vDpcArg = vArg
    b.bActive = true
    fUnsignalObject(b.tDH)
    g_tTimers[b.nTimerId] = b
    return true
end

function oIpc.KeCancelTimer(nPid, sHandle)
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sHandle, 0, g_tPT[nPid] and g_tPT[nPid].synapseToken or "")
    if not pH then return false end
    pH.pBody.bActive = false
    return true
end

function oIpc.ProcessTimers()
    local nNow = g_fUp()
    local nFired = 0
    for nId, b in pairs(g_tTimers) do
        if b.bActive and nNow >= b.nDeadline then
            fSignalObject(b.tDH)
            g_tStats.nTimersFired = g_tStats.nTimersFired + 1
            nFired = nFired + 1
            if b.fDpc then
                oIpc.KeQueueDpc(b.fDpc, b.vDpcArg, nId)
            end
            if b.nPeriodMs > 0 then
                b.nDeadline = nNow + (b.nPeriodMs / 1000)
                fUnsignalObject(b.tDH)
            else
                b.bActive = false
            end
        end
    end
    return nFired
end

-- =============================================
-- 8. EVENTS (NT KeEvent — manual/auto reset)
-- =============================================

function oIpc.KeCreateEvent(nPid, bManualReset, bInitial)
    local tBody = {
        tDH = fNewDispatchHeader(oIpc.WAIT_TYPE_EVENT, bManualReset, bInitial),
    }
    local pH = g_oOb.ObCreateObject("KeEvent", tBody)
    local sSyn = g_tPT[nPid] and g_tPT[nPid].synapseToken or ""
    local sH = g_oOb.ObCreateHandle(nPid, pH, 0x007F, sSyn)
    g_tStats.nEventCreated = g_tStats.nEventCreated + 1
    g_fLog("[IPC] Event created (manual=" .. tostring(bManualReset) ..
           " initial=" .. tostring(bInitial) .. ") for PID " .. nPid)
    return sH
end

function oIpc.KeSetEvent(nPid, sHandle)
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sHandle, 0, g_tPT[nPid] and g_tPT[nPid].synapseToken or "")
    if not pH or not pH.pBody or not pH.pBody.tDH then return 0 end
    return fSignalObject(pH.pBody.tDH)
end

function oIpc.KeResetEvent(nPid, sHandle)
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sHandle, 0, g_tPT[nPid] and g_tPT[nPid].synapseToken or "")
    if not pH or not pH.pBody then return false end
    fUnsignalObject(pH.pBody.tDH)
    return true
end

function oIpc.KePulseEvent(nPid, sHandle)
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sHandle, 0, g_tPT[nPid] and g_tPT[nPid].synapseToken or "")
    if not pH or not pH.pBody then return 0 end
    local n = fSignalObject(pH.pBody.tDH)
    fUnsignalObject(pH.pBody.tDH)
    return n
end

-- =============================================
-- 9. MUTEXES (NT KeMutex — owned, recursive)
-- =============================================

function oIpc.KeCreateMutex(nPid, bInitialOwner)
    local tBody = {
        tDH = fNewDispatchHeader(oIpc.WAIT_TYPE_MUTEX, false, not bInitialOwner),
        nOwnerPid  = bInitialOwner and nPid or nil,
        nRecurse   = bInitialOwner and 1 or 0,
    }
    local pH = g_oOb.ObCreateObject("KeMutex", tBody)
    local sSyn = g_tPT[nPid] and g_tPT[nPid].synapseToken or ""
    local sH = g_oOb.ObCreateHandle(nPid, pH, 0x007F, sSyn)
    g_tStats.nMutexCreated = g_tStats.nMutexCreated + 1
    g_fLog("[IPC] Mutex created for PID " .. nPid)
    return sH
end

function oIpc.KeReleaseMutex(nPid, sHandle)
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sHandle, 0, g_tPT[nPid] and g_tPT[nPid].synapseToken or "")
    if not pH or not pH.pBody then return nil, "Invalid handle" end
    local b = pH.pBody
    if b.nOwnerPid ~= nPid then return nil, "Not owner" end
    b.nRecurse = b.nRecurse - 1
    if b.nRecurse <= 0 then
        b.nOwnerPid = nil
        b.nRecurse = 0
        fSignalObject(b.tDH)
    end
    return true
end

-- Called by wait system when mutex is acquired
local function fMutexAcquire(b, nPid)
    if b.nOwnerPid == nPid then
        b.nRecurse = b.nRecurse + 1
        return true
    end
    if b.nOwnerPid == nil then
        b.nOwnerPid = nPid
        b.nRecurse = 1
        fUnsignalObject(b.tDH)
        return true
    end
    return false
end

-- =============================================
-- 10. SEMAPHORES
-- =============================================

function oIpc.KeCreateSemaphore(nPid, nInitial, nMax)
    nMax = nMax or 0x7FFFFFFF
    local tBody = {
        tDH = fNewDispatchHeader(oIpc.WAIT_TYPE_SEMAPHORE, false, nInitial > 0),
        nCount = nInitial or 0,
        nMax   = nMax,
    }
    local pH = g_oOb.ObCreateObject("KeSemaphore", tBody)
    local sSyn = g_tPT[nPid] and g_tPT[nPid].synapseToken or ""
    local sH = g_oOb.ObCreateHandle(nPid, pH, 0x007F, sSyn)
    g_tStats.nSemCreated = g_tStats.nSemCreated + 1
    return sH
end

function oIpc.KeReleaseSemaphore(nPid, sHandle, nCount)
    nCount = nCount or 1
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sHandle, 0, g_tPT[nPid] and g_tPT[nPid].synapseToken or "")
    if not pH or not pH.pBody then return nil, "Invalid handle" end
    local b = pH.pBody
    local nPrev = b.nCount
    b.nCount = b.nCount + nCount
    if b.nCount > b.nMax then b.nCount = b.nMax end
    if b.nCount > 0 then
        fSignalObject(b.tDH)
    end
    return nPrev
end

local function fSemaphoreAcquire(b)
    if b.nCount > 0 then
        b.nCount = b.nCount - 1
        if b.nCount == 0 then fUnsignalObject(b.tDH) end
        return true
    end
    return false
end

-- =============================================
-- 11. PIPES
-- =============================================

function oIpc.KeCreatePipe(nPid, nBufSize)
    nBufSize = nBufSize or oIpc.DEFAULT_PIPE_SIZE
    if nBufSize > oIpc.MAX_PIPE_SIZE then nBufSize = oIpc.MAX_PIPE_SIZE end

    local tBody = {
        sCategory      = "pipe",
        tDH            = fNewDispatchHeader(oIpc.WAIT_TYPE_PIPE, true, false),
        sBuffer        = "",
        nMaxSize       = nBufSize,
        bReadClosed    = false,
        bWriteClosed   = false,
        nBytesRead     = 0,
        nBytesWritten  = 0,
        tReadWaitList  = {},
        tWriteWaitList = {},
    }

    local pH = g_oOb.ObCreateObject("IoPipeObject", tBody)
    local sSyn = g_tPT[nPid] and g_tPT[nPid].synapseToken or ""
    local sHRead  = g_oOb.ObCreateHandle(nPid, pH, 0x0001, sSyn) -- READ
    local sHWrite = g_oOb.ObCreateHandle(nPid, pH, 0x0002, sSyn) -- WRITE
    g_tStats.nPipeCreated = g_tStats.nPipeCreated + 1
    g_fLog("[IPC] Pipe created (buf=" .. nBufSize .. ") for PID " .. nPid)
    return sHRead, sHWrite
end

function oIpc.KeCreateNamedPipe(nPid, sName, nBufSize)
    if g_tNamedPipes[sName] then return nil, "Pipe exists" end
    local sR, sW = oIpc.KeCreatePipe(nPid, nBufSize)
    if not sR then return nil, sW end
    -- Resolve to get the object header for namespace registration
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sR, 0, g_tPT[nPid].synapseToken)
    if pH then
        g_tNamedPipes[sName] = pH
        pH.pBody.sName = sName
        g_oOb.ObInsertObject(pH, "\\Pipe\\" .. sName)
    end
    return sR, sW
end

function oIpc.KeConnectNamedPipe(nPid, sName)
    local pH = g_tNamedPipes[sName]
    if not pH then return nil, "No such pipe" end
    local sSyn = g_tPT[nPid] and g_tPT[nPid].synapseToken or ""
    local sH = g_oOb.ObCreateHandle(nPid, pH, 0x0003, sSyn) -- READ|WRITE
    return sH
end

local function fWakePipeReaders(b)
    for _, nWPid in ipairs(b.tReadWaitList) do
        local tW = g_tPT[nWPid]
        if tW and tW.status == "sleeping" and tW.wait_reason == "pipe_read" then
            tW.status = "ready"
        end
    end
    b.tReadWaitList = {}
    if #b.sBuffer > 0 then fSignalObject(b.tDH) end
end

local function fWakePipeWriters(b)
    for _, nWPid in ipairs(b.tWriteWaitList) do
        local tW = g_tPT[nWPid]
        if tW and tW.status == "sleeping" and tW.wait_reason == "pipe_write" then
            tW.status = "ready"
        end
    end
    b.tWriteWaitList = {}
end

function oIpc.PipeWrite(nPid, b, sData)
    if not sData then return nil, "No data" end
    if b.bReadClosed then
        -- Broken pipe → SIGPIPE
        oIpc.SignalSend(nPid, oIpc.SIGPIPE)
        return nil, "Broken pipe"
    end
    local nWritten = 0
    while #sData > 0 do
        local nSpace = b.nMaxSize - #b.sBuffer
        if nSpace > 0 then
            local nChunk = math.min(nSpace, #sData)
            b.sBuffer = b.sBuffer .. sData:sub(1, nChunk)
            sData = sData:sub(nChunk + 1)
            nWritten = nWritten + nChunk
            b.nBytesWritten = b.nBytesWritten + nChunk
            g_tStats.nPipeBytes = g_tStats.nPipeBytes + nChunk
            fWakePipeReaders(b)
        end
        if #sData == 0 then break end
        -- Buffer full — block
        if not fCanBlock(nPid) then return nil, "Would block (DISPATCH_LEVEL)" end
        table.insert(b.tWriteWaitList, nPid)
        g_tPT[nPid].status = "sleeping"
        g_tPT[nPid].wait_reason = "pipe_write"
        g_fYield()
        if b.bReadClosed then
            oIpc.SignalSend(nPid, oIpc.SIGPIPE)
            return nil, "Broken pipe"
        end
    end
    return true, nWritten
end

function oIpc.PipeRead(nPid, b, nCount)
    nCount = nCount or math.huge
    while #b.sBuffer == 0 do
        if b.bWriteClosed then return true, nil end  -- EOF
        if not fCanBlock(nPid) then return nil, "Would block" end
        table.insert(b.tReadWaitList, nPid)
        g_tPT[nPid].status = "sleeping"
        g_tPT[nPid].wait_reason = "pipe_read"
        g_fYield()
        if b.bWriteClosed and #b.sBuffer == 0 then return true, nil end
    end
    local nTake = math.min(nCount, #b.sBuffer)
    local sResult = b.sBuffer:sub(1, nTake)
    b.sBuffer = b.sBuffer:sub(nTake + 1)
    b.nBytesRead = b.nBytesRead + nTake
    fWakePipeWriters(b)
    if #b.sBuffer == 0 then fUnsignalObject(b.tDH) end
    return true, sResult
end

function oIpc.PipeClose(nPid, sHandle, bIsWrite)
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sHandle, 0, g_tPT[nPid] and g_tPT[nPid].synapseToken or "")
    if not pH or not pH.pBody then return false end
    local b = pH.pBody
    if bIsWrite then
        b.bWriteClosed = true
        fWakePipeReaders(b)
    else
        b.bReadClosed = true
        fWakePipeWriters(b)
    end
    g_oOb.ObCloseHandle(nPid, sHandle)
    return true
end

-- VFS fast-path: intercept vfs_read/vfs_write on pipe handles
function oIpc.TryPipeIo(nPid, sName, vHandle, vArg)
    if not g_oOb then return false end
    local p = g_tPT[nPid]
    if not p then return false end
    local pH, nSt = g_oOb.ObReferenceObjectByHandle(
        nPid, vHandle, 0, p.synapseToken or "")
    if not pH then return false end
    if pH.sType ~= "IoPipeObject" then return false end
    local b = pH.pBody
    if not b or b.sCategory ~= "pipe" then return false end
    if sName == "vfs_write" then
        return true, oIpc.PipeWrite(nPid, b, vArg)
    elseif sName == "vfs_read" then
        return true, oIpc.PipeRead(nPid, b, vArg)
    end
    return false
end

-- =============================================
-- 12. SHARED MEMORY SECTIONS
-- =============================================

function oIpc.KeCreateSection(nPid, sName, nSize)
    nSize = nSize or 4096
    if sName and g_tSections[sName] then return nil, "Section exists" end
    local tBody = {
        sName  = sName,
        nSize  = nSize,
        tData  = {},     -- the shared memory region (Lua table)
        nRefs  = 1,
    }
    local pH = g_oOb.ObCreateObject("MmSectionObject", tBody)
    if sName then
        g_tSections[sName] = pH
        g_oOb.ObInsertObject(pH, "\\Section\\" .. sName)
    end
    local sSyn = g_tPT[nPid] and g_tPT[nPid].synapseToken or ""
    local sH = g_oOb.ObCreateHandle(nPid, pH, 0x007F, sSyn)
    g_tStats.nSectionCreated = g_tStats.nSectionCreated + 1
    g_fLog("[IPC] Section '" .. (sName or "anon") .. "' created (" .. nSize .. "B)")
    return sH
end

function oIpc.KeOpenSection(nPid, sName)
    local pH = g_tSections[sName]
    if not pH then return nil, "No such section" end
    pH.pBody.nRefs = pH.pBody.nRefs + 1
    local sSyn = g_tPT[nPid] and g_tPT[nPid].synapseToken or ""
    return g_oOb.ObCreateHandle(nPid, pH, 0x007F, sSyn)
end

function oIpc.KeMapSection(nPid, sHandle)
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sHandle, 0, g_tPT[nPid] and g_tPT[nPid].synapseToken or "")
    if not pH or not pH.pBody then return nil, "Invalid handle" end
    return pH.pBody.tData  -- direct reference to shared table
end

-- =============================================
-- 13. MESSAGE QUEUES
-- =============================================

function oIpc.KeCreateMqueue(nPid, sName, nMaxMsgs, nMaxSize)
    nMaxMsgs = nMaxMsgs or oIpc.DEFAULT_MQ_MAX
    nMaxSize = nMaxSize or oIpc.DEFAULT_MQ_SIZE
    if sName and g_tMQueues[sName] then return nil, "Queue exists" end
    local tBody = {
        tDH       = fNewDispatchHeader(oIpc.WAIT_TYPE_MQUEUE, true, false),
        sName     = sName,
        nMaxMsgs  = nMaxMsgs,
        nMaxSize  = nMaxSize,
        tMessages = {},      -- {sData, nPriority}
        tRecvWait = {},      -- PIDs waiting to receive
        tSendWait = {},      -- PIDs waiting to send
    }
    local pH = g_oOb.ObCreateObject("IpcMessageQueue", tBody)
    if sName then
        g_tMQueues[sName] = pH
        g_oOb.ObInsertObject(pH, "\\MQueue\\" .. sName)
    end
    local sSyn = g_tPT[nPid] and g_tPT[nPid].synapseToken or ""
    local sH = g_oOb.ObCreateHandle(nPid, pH, 0x007F, sSyn)
    g_tStats.nMqCreated = g_tStats.nMqCreated + 1
    g_fLog("[IPC] MQueue '" .. (sName or "anon") .. "' created")
    return sH
end

function oIpc.KeOpenMqueue(nPid, sName)
    local pH = g_tMQueues[sName]
    if not pH then return nil, "No such queue" end
    local sSyn = g_tPT[nPid] and g_tPT[nPid].synapseToken or ""
    return g_oOb.ObCreateHandle(nPid, pH, 0x007F, sSyn)
end

function oIpc.KeMqSend(nPid, sHandle, sMessage, nPriority)
    nPriority = nPriority or 0
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sHandle, 0, g_tPT[nPid] and g_tPT[nPid].synapseToken or "")
    if not pH or not pH.pBody then return nil, "Invalid handle" end
    local b = pH.pBody
    if #sMessage > b.nMaxSize then return nil, "Message too large" end

    while #b.tMessages >= b.nMaxMsgs do
        if not fCanBlock(nPid) then return nil, "Would block" end
        table.insert(b.tSendWait, nPid)
        g_tPT[nPid].status = "sleeping"
        g_tPT[nPid].wait_reason = "mq_send"
        g_fYield()
    end

    local bInserted = false
    for i, tMsg in ipairs(b.tMessages) do
        if nPriority > tMsg.nPri then
            table.insert(b.tMessages, i, {sData = sMessage, nPri = nPriority})
            bInserted = true; break
        end
    end
    if not bInserted then
        table.insert(b.tMessages, {sData = sMessage, nPri = nPriority})
    end

    -- Wake receivers (no resume_args needed — they re-check the queue)
    for _, nWPid in ipairs(b.tRecvWait) do
        local tW = g_tPT[nWPid]
        if tW and tW.status == "sleeping" and tW.wait_reason == "mq_recv" then
            tW.status = "ready"
            g_tWaitTimeouts[nWPid] = nil  -- cancel any pending timeout
        end
    end
    b.tRecvWait = {}
    fSignalObject(b.tDH)
    return true
end

function oIpc.KeMqReceive(nPid, sHandle, nTimeoutMs)
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sHandle, 0, g_tPT[nPid] and g_tPT[nPid].synapseToken or "")
    if not pH or not pH.pBody then return nil, "Invalid handle" end
    local b = pH.pBody

    local nDeadline = nTimeoutMs and (g_fUp() + nTimeoutMs / 1000) or nil

    while #b.tMessages == 0 do
        -- Check deadline before blocking
        if nDeadline and g_fUp() >= nDeadline then return nil, "timeout" end
        if not fCanBlock(nPid) then return nil, "Would block" end

        table.insert(b.tRecvWait, nPid)

        -- Register timeout in the central registry
        if nDeadline then
            g_tWaitTimeouts[nPid] = { nDeadline = nDeadline }
        end

        g_tPT[nPid]._nWaitResult = nil
        g_tPT[nPid].status = "sleeping"
        g_tPT[nPid].wait_reason = "mq_recv"
        g_fYield()

        -- Cleanup and check if we timed out
        g_tWaitTimeouts[nPid] = nil
        if g_tPT[nPid]._nWaitResult == oIpc.STATUS_TIMEOUT then
            g_tPT[nPid]._nWaitResult = nil
            return nil, "timeout"
        end
        g_tPT[nPid]._nWaitResult = nil
    end

    local tMsg = table.remove(b.tMessages, 1)
    if #b.tMessages == 0 then fUnsignalObject(b.tDH) end

    -- Wake senders
    for _, nWPid in ipairs(b.tSendWait) do
        local tW = g_tPT[nWPid]
        if tW and tW.status == "sleeping" and tW.wait_reason == "mq_send" then
            tW.status = "ready"
        end
    end
    b.tSendWait = {}
    return tMsg.sData, tMsg.nPri
end

-- =============================================
-- 14. SIGNALS & PROCESS GROUPS
-- =============================================

function oIpc.InitProcessSignals(nPid)
    local p = g_tPT[nPid]
    if not p then return end
    p.tPendingSignals = {}
    p.tSignalHandlers = {}
    p.tSignalMask     = {}    -- [signum] = true → blocked
    p.nPgid           = nPid  -- own process group by default
    p.bDeliveringSignals = false
    p.nIrql           = oIpc.PASSIVE_LEVEL
    -- Register in default process group
    if not g_tProcGroups[nPid] then g_tProcGroups[nPid] = {} end
    table.insert(g_tProcGroups[nPid], nPid)
end

function oIpc.SignalSend(nTargetPid, nSignal)
    local p = g_tPT[nTargetPid]
    if not p then return nil, "No such process" end
    if not p.tPendingSignals then oIpc.InitProcessSignals(nTargetPid) end
    g_tStats.nSignalsSent = g_tStats.nSignalsSent + 1

    -- SIGKILL: immediate, uncatchable
    if nSignal == oIpc.SIGKILL then
        g_fLog("[IPC] SIGKILL → PID " .. nTargetPid)
        p.status = "dead"
        for _, nTid in ipairs(p.threads or {}) do
            if g_tPT[nTid] then g_tPT[nTid].status = "dead" end
        end
        return true
    end

    -- SIGSTOP: immediate, uncatchable
    if nSignal == oIpc.SIGSTOP then
        g_fLog("[IPC] SIGSTOP → PID " .. nTargetPid)
        p.status = "stopped"
        return true
    end

    -- SIGCONT: wake stopped process
    if nSignal == oIpc.SIGCONT then
        if p.status == "stopped" then
            p.status = "ready"
            g_fLog("[IPC] SIGCONT → PID " .. nTargetPid .. " resumed")
        end
        -- Also deliver to handler if registered
    end

    -- Queue the signal
    table.insert(p.tPendingSignals, nSignal)

    -- Wake sleeping processes so they can receive the signal
    if p.status == "sleeping" then
        p.status = "ready"
        p.resume_args = {true, oIpc.STATUS_IO_COMPLETION}
    end
    return true
end

function oIpc.SignalSendGroup(nPgid, nSignal)
    local tGroup = g_tProcGroups[nPgid]
    if not tGroup then return nil, "No such group" end
    local nSent = 0
    for _, nPid in ipairs(tGroup) do
        if g_tPT[nPid] and g_tPT[nPid].status ~= "dead" then
            oIpc.SignalSend(nPid, nSignal)
            nSent = nSent + 1
        end
    end
    return nSent
end

function oIpc.SignalSetHandler(nPid, nSignal, fHandler)
    local p = g_tPT[nPid]
    if not p then return nil, "No such process" end
    if not p.tSignalHandlers then oIpc.InitProcessSignals(nPid) end
    if nSignal == oIpc.SIGKILL or nSignal == oIpc.SIGSTOP then
        return nil, "Cannot catch SIGKILL/SIGSTOP"
    end
    local fOld = p.tSignalHandlers[nSignal]
    p.tSignalHandlers[nSignal] = fHandler  -- nil to reset to default
    return fOld
end

function oIpc.SignalSetMask(nPid, tMask)
    local p = g_tPT[nPid]
    if not p then return nil end
    if not p.tSignalMask then oIpc.InitProcessSignals(nPid) end
    local tOld = p.tSignalMask
    p.tSignalMask = tMask or {}
    return tOld
end

function oIpc.SetProcessGroup(nPid, nPgid)
    local p = g_tPT[nPid]
    if not p then return false end
    -- Remove from old group
    local nOldPgid = p.nPgid or nPid
    local tOld = g_tProcGroups[nOldPgid]
    if tOld then
        local tNew = {}
        for _, id in ipairs(tOld) do
            if id ~= nPid then table.insert(tNew, id) end
        end
        g_tProcGroups[nOldPgid] = tNew
    end
    -- Add to new group
    p.nPgid = nPgid
    if not g_tProcGroups[nPgid] then g_tProcGroups[nPgid] = {} end
    table.insert(g_tProcGroups[nPgid], nPid)
    return true
end

-- Deliver pending signals — called in process context
function oIpc.DeliverSignals(nPid)
    local p = g_tPT[nPid]
    if not p or not p.tPendingSignals then return false end
    if p.bDeliveringSignals then return false end -- prevent reentry
    if #p.tPendingSignals == 0 then return false end

    p.bDeliveringSignals = true
    local nOldIrql = p.nIrql or 0
    p.nIrql = oIpc.APC_LEVEL

    while #p.tPendingSignals > 0 do
        local nSig = table.remove(p.tPendingSignals, 1)

        -- Check mask
        if p.tSignalMask and p.tSignalMask[nSig] then
            table.insert(p.tPendingSignals, nSig) -- re-queue
            break  -- don't spin forever on masked signals
        end

        g_tStats.nSignalsDelivered = g_tStats.nSignalsDelivered + 1
        local fHandler = p.tSignalHandlers and p.tSignalHandlers[nSig]

        if fHandler then
            -- Call user handler
            local bOk, sErr = pcall(fHandler, nSig)
            if not bOk then
                g_fLog("[IPC] Signal handler crashed PID="..nPid.." sig="..nSig..": "..tostring(sErr))
            end
        else
            -- Default action
            local sAct = g_tDefAct[nSig] or DFL_TERM
            if sAct == DFL_TERM then
                g_fLog("[IPC] Default TERM for signal " .. nSig .. " → PID " .. nPid)
                p.status = "dead"
                break
            elseif sAct == DFL_STOP then
                p.status = "stopped"
                break
            elseif sAct == DFL_CONT then
                if p.status == "stopped" then p.status = "ready" end
            end
            -- DFL_IGN: do nothing
        end
    end

    p.nIrql = nOldIrql
    p.bDeliveringSignals = false
    return p.status == "dead"
end

-- Notify parent of child death (SIGCHLD)
function oIpc.NotifyChildDeath(nChildPid)
    local child = g_tPT[nChildPid]
    if not child then return end
    local nParent = child.parent
    if nParent and g_tPT[nParent] and g_tPT[nParent].status ~= "dead" then
        oIpc.SignalSend(nParent, oIpc.SIGCHLD)
    end
end

-- =============================================
-- 15. WAITFORSINGLE / WAITFORMULTIPLE
-- =============================================

local function fResolveWaitable(nPid, sHandle)
    local pH = g_oOb.ObReferenceObjectByHandle(
        nPid, sHandle, 0, g_tPT[nPid] and g_tPT[nPid].synapseToken or "")
    if not pH or not pH.pBody then return nil end
    local b = pH.pBody
    if not b.tDH then return nil end
    return b.tDH, b
end

function oIpc.KeWaitSingle(nPid, sHandle, nTimeoutMs)
    if not fCanBlock(nPid) then return oIpc.STATUS_FAILED, "Cannot block" end
    g_tStats.nWaitsIssued = g_tStats.nWaitsIssued + 1

    local tDH, tBody = fResolveWaitable(nPid, sHandle)
    if not tDH then return oIpc.STATUS_FAILED, "Not waitable" end

    -- Immediate satisfaction
    if tDH.bSignaled then
        if tDH.nType == oIpc.WAIT_TYPE_MUTEX then
            if fMutexAcquire(tBody, nPid) then
                g_tStats.nWaitsSatisfied = g_tStats.nWaitsSatisfied + 1
                return oIpc.STATUS_WAIT_0
            end
        elseif tDH.nType == oIpc.WAIT_TYPE_SEMAPHORE then
            if fSemaphoreAcquire(tBody) then
                g_tStats.nWaitsSatisfied = g_tStats.nWaitsSatisfied + 1
                return oIpc.STATUS_WAIT_0
            end
        else
            if not tDH.bManualReset then tDH.bSignaled = false end
            g_tStats.nWaitsSatisfied = g_tStats.nWaitsSatisfied + 1
            return oIpc.STATUS_WAIT_0
        end
    end

    -- Must sleep — register waiter and optional timeout
    fAddWaiter(tDH, nPid, 0)

    if nTimeoutMs then
        g_tWaitTimeouts[nPid] = {
            nDeadline = g_fUp() + nTimeoutMs / 1000,
            tDH       = tDH,
        }
    end

    g_tPT[nPid]._nWaitResult = nil
    g_tPT[nPid].status = "sleeping"
    g_tPT[nPid].wait_reason = "ke_wait"
    g_fYield()

    -- Woken up — read result from _nWaitResult (set by fSignalObject or ProcessWaitTimeouts)
    g_tWaitTimeouts[nPid] = nil
    local nResult = g_tPT[nPid]._nWaitResult or oIpc.STATUS_WAIT_0
    g_tPT[nPid]._nWaitResult = nil

    if nResult == oIpc.STATUS_TIMEOUT then
        g_tStats.nWaitsTimedOut = g_tStats.nWaitsTimedOut + 1
        return oIpc.STATUS_TIMEOUT
    end

    -- Post-acquisition for mutex/semaphore
    if tDH.nType == oIpc.WAIT_TYPE_MUTEX then fMutexAcquire(tBody, nPid) end
    if tDH.nType == oIpc.WAIT_TYPE_SEMAPHORE then fSemaphoreAcquire(tBody) end

    g_tStats.nWaitsSatisfied = g_tStats.nWaitsSatisfied + 1
    return nResult
end

function oIpc.KeWaitMultiple(nPid, tHandles, bWaitAll, nTimeoutMs)
    if not fCanBlock(nPid) then return oIpc.STATUS_FAILED end
    g_tStats.nWaitsIssued = g_tStats.nWaitsIssued + 1

    local tWaitObjs = {}
    for i, sH in ipairs(tHandles) do
        local tDH, tBody = fResolveWaitable(nPid, sH)
        if not tDH then return oIpc.STATUS_FAILED, "Handle " .. i .. " not waitable" end
        tWaitObjs[i] = {tDH = tDH, tBody = tBody, sHandle = sH}
    end

    -- Immediate check — WaitAll
    if bWaitAll then
        local bAllReady = true
        for _, wo in ipairs(tWaitObjs) do
            if not wo.tDH.bSignaled then bAllReady = false; break end
        end
        if bAllReady then
            for _, wo in ipairs(tWaitObjs) do
                if not wo.tDH.bManualReset then wo.tDH.bSignaled = false end
                if wo.tDH.nType == oIpc.WAIT_TYPE_MUTEX then fMutexAcquire(wo.tBody, nPid) end
                if wo.tDH.nType == oIpc.WAIT_TYPE_SEMAPHORE then fSemaphoreAcquire(wo.tBody) end
            end
            g_tStats.nWaitsSatisfied = g_tStats.nWaitsSatisfied + 1
            return oIpc.STATUS_WAIT_0
        end
    else
        -- Immediate check — WaitAny
        for i, wo in ipairs(tWaitObjs) do
            if wo.tDH.bSignaled then
                if not wo.tDH.bManualReset then wo.tDH.bSignaled = false end
                if wo.tDH.nType == oIpc.WAIT_TYPE_MUTEX then fMutexAcquire(wo.tBody, nPid) end
                if wo.tDH.nType == oIpc.WAIT_TYPE_SEMAPHORE then fSemaphoreAcquire(wo.tBody) end
                g_tStats.nWaitsSatisfied = g_tStats.nWaitsSatisfied + 1
                return oIpc.STATUS_WAIT_0 + i - 1
            end
        end
    end

    -- Must sleep
    local ctx = {tWaitObjs = tWaitObjs, bWaitAll = bWaitAll}
    g_tPT[nPid]._tWaitCtx = ctx

    for i, wo in ipairs(tWaitObjs) do
        fAddWaiter(wo.tDH, nPid, i - 1)
    end

    if nTimeoutMs then
        g_tWaitTimeouts[nPid] = {
            nDeadline = g_fUp() + nTimeoutMs / 1000,
            tDHList   = tWaitObjs,   -- so ProcessWaitTimeouts can clean up all wait lists
        }
    end

    g_tPT[nPid]._nWaitResult = nil
    g_tPT[nPid].status = "sleeping"
    g_tPT[nPid].wait_reason = "ke_wait"
    g_fYield()

    -- Woken up — cleanup
    g_tWaitTimeouts[nPid] = nil
    g_tPT[nPid]._tWaitCtx = nil
    for _, wo in ipairs(tWaitObjs) do fRemoveWaiter(wo.tDH, nPid) end

    local nResult = g_tPT[nPid]._nWaitResult or oIpc.STATUS_WAIT_0
    g_tPT[nPid]._nWaitResult = nil

    if nResult == oIpc.STATUS_TIMEOUT then
        g_tStats.nWaitsTimedOut = g_tStats.nWaitsTimedOut + 1
        return oIpc.STATUS_TIMEOUT
    end

    -- Post-acquisition for the specific object(s) that signaled
    if not bWaitAll then
        local nIdx = nResult - oIpc.STATUS_WAIT_0 + 1
        local wo = tWaitObjs[nIdx]
        if wo then
            if wo.tDH.nType == oIpc.WAIT_TYPE_MUTEX then fMutexAcquire(wo.tBody, nPid) end
            if wo.tDH.nType == oIpc.WAIT_TYPE_SEMAPHORE then fSemaphoreAcquire(wo.tBody) end
        end
    else
        for _, wo in ipairs(tWaitObjs) do
            if wo.tDH.nType == oIpc.WAIT_TYPE_MUTEX then fMutexAcquire(wo.tBody, nPid) end
            if wo.tDH.nType == oIpc.WAIT_TYPE_SEMAPHORE then fSemaphoreAcquire(wo.tBody) end
        end
    end

    g_tStats.nWaitsSatisfied = g_tStats.nWaitsSatisfied + 1
    return nResult
end

-- =============================================
-- 16. TICK (called once per scheduler iteration)
-- =============================================

function oIpc.ProcessWaitTimeouts()
    local nNow = g_fUp()
    for nPid, tTO in pairs(g_tWaitTimeouts) do
        if nNow >= tTO.nDeadline then
            local tW = g_tPT[nPid]
            if tW and tW.status == "sleeping" then
                -- Remove from dispatch header wait lists
                if tTO.tDH then
                    fRemoveWaiter(tTO.tDH, nPid)
                end
                if tTO.tDHList then
                    for _, wo in ipairs(tTO.tDHList) do
                        fRemoveWaiter(wo.tDH, nPid)
                    end
                end
                -- Clean up WaitMultiple context
                if tW._tWaitCtx then
                    for _, wo in ipairs(tW._tWaitCtx.tWaitObjs) do
                        fRemoveWaiter(wo.tDH, nPid)
                    end
                    tW._tWaitCtx = nil
                end
                -- Set result and wake
                tW._nWaitResult = oIpc.STATUS_TIMEOUT
                tW.status = "ready"
                g_fLog("[IPC] Timeout expired for PID " .. nPid)
            end
            g_tWaitTimeouts[nPid] = nil
        end
    end
end

function oIpc.Tick()
    oIpc.ProcessTimers()
    oIpc.ProcessWaitTimeouts()
    oIpc.ProcessDpcQueue()
end

-- =============================================
-- 17. STATISTICS
-- =============================================

function oIpc.GetStats()
    return {
        nDpcsProcessed    = g_tStats.nDpcsProcessed,
        nTimersFired      = g_tStats.nTimersFired,
        nSignalsSent      = g_tStats.nSignalsSent,
        nSignalsDelivered = g_tStats.nSignalsDelivered,
        nPipeCreated      = g_tStats.nPipeCreated,
        nPipeBytes        = g_tStats.nPipeBytes,
        nWaitsIssued      = g_tStats.nWaitsIssued,
        nWaitsSatisfied   = g_tStats.nWaitsSatisfied,
        nWaitsTimedOut    = g_tStats.nWaitsTimedOut,
        nMutexCreated     = g_tStats.nMutexCreated,
        nEventCreated     = g_tStats.nEventCreated,
        nSemCreated       = g_tStats.nSemCreated,
        nSectionCreated   = g_tStats.nSectionCreated,
        nMqCreated        = g_tStats.nMqCreated,
        nActiveDpcs       = #g_tDpcQueue,
        nActiveTimers     = (function() local n=0; for _ in pairs(g_tTimers) do n=n+1 end; return n end)(),
        nNamedPipes       = (function() local n=0; for _ in pairs(g_tNamedPipes) do n=n+1 end; return n end)(),
        nSections         = (function() local n=0; for _ in pairs(g_tSections) do n=n+1 end; return n end)(),
        nMQueues          = (function() local n=0; for _ in pairs(g_tMQueues) do n=n+1 end; return n end)(),
        nProcGroups       = (function() local n=0; for _ in pairs(g_tProcGroups) do n=n+1 end; return n end)(),
    }
end

return oIpc