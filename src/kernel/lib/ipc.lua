--
-- /lib/ipc.lua — User-space shared memory & message queues
--

local oIpc = {}

-- ===== Shared Memory =====

function oIpc.createSection(sName, nSize)
    return syscall("ke_create_section", sName, nSize or 4096)
end

function oIpc.openSection(sName)
    return syscall("ke_open_section", sName)
end

function oIpc.mapSection(hSection)
    return syscall("ke_map_section", hSection)
end

-- ===== Message Queues =====

function oIpc.createMqueue(sName, nMaxMsgs, nMaxSize)
    return syscall("ke_create_mqueue", sName, nMaxMsgs, nMaxSize)
end

function oIpc.openMqueue(sName)
    return syscall("ke_open_mqueue", sName)
end

function oIpc.mqSend(hQueue, sMessage, nPriority)
    return syscall("ke_mq_send", hQueue, sMessage, nPriority or 0)
end

function oIpc.mqReceive(hQueue, nTimeoutMs)
    return syscall("ke_mq_receive", hQueue, nTimeoutMs)
end

-- ===== IRQL =====

function oIpc.raiseIrql(nLevel)
    return syscall("ke_raise_irql", nLevel)
end

function oIpc.lowerIrql(nLevel)
    return syscall("ke_lower_irql", nLevel)
end

function oIpc.getIrql()
    return syscall("ke_get_irql")
end

function oIpc.ipcStats()
    return syscall("ke_ipc_stats")
end

return oIpc