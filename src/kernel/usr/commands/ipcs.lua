--
-- /usr/commands/ipcs.lua — IPC status display
--

local tArgs = env.ARGS or {}
local C = {
    R="\27[37m", CYN="\27[36m", GRN="\27[32m",
    YLW="\27[33m", RED="\27[31m", GRY="\27[90m", MAG="\27[35m",
}

local tStats = syscall("ke_ipc_stats")
if not tStats then print("ipcs: IPC subsystem not available"); return end

print(C.CYN .. "AxisOS IPC Status" .. C.R)
print(C.GRY .. string.rep("-", 50) .. C.R)

print(C.YLW .. "\n  Synchronization Objects" .. C.R)
print(string.format("    Events created:      %s%d%s", C.GRN, tStats.nEventCreated or 0, C.R))
print(string.format("    Mutexes created:     %s%d%s", C.GRN, tStats.nMutexCreated or 0, C.R))
print(string.format("    Semaphores created:  %s%d%s", C.GRN, tStats.nSemCreated or 0, C.R))

print(C.YLW .. "\n  Pipes" .. C.R)
print(string.format("    Pipes created:       %s%d%s", C.GRN, tStats.nPipeCreated or 0, C.R))
print(string.format("    Named pipes active:  %s%d%s", C.GRN, tStats.nNamedPipes or 0, C.R))
print(string.format("    Bytes transferred:   %s%d%s", C.GRN, tStats.nPipeBytes or 0, C.R))

print(C.YLW .. "\n  Shared Memory" .. C.R)
print(string.format("    Sections created:    %s%d%s", C.GRN, tStats.nSectionCreated or 0, C.R))
print(string.format("    Active sections:     %s%d%s", C.GRN, tStats.nSections or 0, C.R))

print(C.YLW .. "\n  Message Queues" .. C.R)
print(string.format("    Queues created:      %s%d%s", C.GRN, tStats.nMqCreated or 0, C.R))
print(string.format("    Active queues:       %s%d%s", C.GRN, tStats.nMQueues or 0, C.R))

print(C.YLW .. "\n  Signals" .. C.R)
print(string.format("    Signals sent:        %s%d%s", C.GRN, tStats.nSignalsSent or 0, C.R))
print(string.format("    Signals delivered:   %s%d%s", C.GRN, tStats.nSignalsDelivered or 0, C.R))
print(string.format("    Process groups:      %s%d%s", C.GRN, tStats.nProcGroups or 0, C.R))

print(C.YLW .. "\n  Wait System" .. C.R)
print(string.format("    Waits issued:        %s%d%s", C.GRN, tStats.nWaitsIssued or 0, C.R))
print(string.format("    Waits satisfied:     %s%d%s", C.GRN, tStats.nWaitsSatisfied or 0, C.R))
print(string.format("    Waits timed out:     %s%d%s", C.YLW, tStats.nWaitsTimedOut or 0, C.R))

print(C.YLW .. "\n  DPC & Timers" .. C.R)
print(string.format("    DPCs processed:      %s%d%s", C.GRN, tStats.nDpcsProcessed or 0, C.R))
print(string.format("    DPCs pending:        %s%d%s", C.GRN, tStats.nActiveDpcs or 0, C.R))
print(string.format("    Timers fired:        %s%d%s", C.GRN, tStats.nTimersFired or 0, C.R))
print(string.format("    Timers active:       %s%d%s", C.GRN, tStats.nActiveTimers or 0, C.R))
print("")