--
-- /lib/iocp.lua — I/O Completion Port user-space API
--
local oIocp = {}

function oIocp.create(nMaxConcurrent)
    return syscall("ke_create_iocp", nMaxConcurrent or 0)
end

function oIocp.associate(hPort, hFile, nKey)
    return syscall("ke_associate_iocp", hPort, hFile, nKey)
end

function oIocp.post(hPort, nKey, nBytes, nStatus, vData)
    return syscall("ke_post_completion", hPort, nKey, nBytes, nStatus, vData)
end

function oIocp.get(hPort, nTimeoutMs)
    return syscall("ke_get_completion", hPort, nTimeoutMs)
end

-- Wait for any of multiple completion ports (uses WaitForMultipleObjects)
function oIocp.waitAny(tPorts, nTimeoutMs)
    return syscall("ke_wait_multiple", tPorts, false, nTimeoutMs)
end

return oIocp