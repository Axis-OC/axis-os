--
-- /lib/pipe.lua — User-space pipe API
--

local oPipe = {}

function oPipe.create(nBufSize)
    local hRead, hWrite = syscall("ke_create_pipe", nBufSize or 4096)
    if not hRead then return nil, hWrite end
    return {
        read  = hRead,
        write = hWrite,
        _open = true,
    }
end

function oPipe.createNamed(sName, nBufSize)
    local hR, hW = syscall("ke_create_named_pipe", sName, nBufSize or 4096)
    if not hR then return nil, hW end
    return {read = hR, write = hW, _open = true, name = sName}
end

function oPipe.connectNamed(sName)
    local h, sErr = syscall("ke_connect_named_pipe", sName)
    if not h then return nil, sErr end
    return {handle = h, _open = true, name = sName}
end

function oPipe.write(hWrite, sData)
    return syscall("ke_pipe_write", hWrite, sData)
end

function oPipe.read(hRead, nCount)
    return syscall("ke_pipe_read", hRead, nCount or math.huge)
end

function oPipe.closeRead(hRead)
    return syscall("ke_pipe_close", hRead, false)
end

function oPipe.closeWrite(hWrite)
    return syscall("ke_pipe_close", hWrite, true)
end

return oPipe