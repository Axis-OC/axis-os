--
-- /lib/sync.lua — User-space synchronization primitives
--

local oSync = {}

function oSync.createEvent(bManualReset, bInitial)
    return syscall("ke_create_event", bManualReset or false, bInitial or false)
end
function oSync.setEvent(h) return syscall("ke_set_event", h) end
function oSync.resetEvent(h) return syscall("ke_reset_event", h) end
function oSync.pulseEvent(h) return syscall("ke_pulse_event", h) end

function oSync.createMutex(bOwned)
    return syscall("ke_create_mutex", bOwned or false)
end
function oSync.releaseMutex(h) return syscall("ke_release_mutex", h) end

function oSync.createSemaphore(nInit, nMax)
    return syscall("ke_create_semaphore", nInit or 1, nMax or 0x7FFFFFFF)
end
function oSync.releaseSemaphore(h, n)
    return syscall("ke_release_semaphore", h, n or 1)
end

function oSync.wait(h, nTimeoutMs)
    return syscall("ke_wait_single", h, nTimeoutMs)
end

function oSync.waitMultiple(tHandles, bWaitAll, nTimeoutMs)
    return syscall("ke_wait_multiple", tHandles, bWaitAll or false, nTimeoutMs)
end

function oSync.createTimer()
    return syscall("ke_create_timer")
end
function oSync.setTimer(h, nDelayMs, nPeriodMs)
    return syscall("ke_set_timer", h, nDelayMs, nPeriodMs)
end
function oSync.cancelTimer(h)
    return syscall("ke_cancel_timer", h)
end

oSync.WAIT_0       = 0
oSync.WAIT_TIMEOUT = 258
oSync.WAIT_FAILED  = -1

return oSync