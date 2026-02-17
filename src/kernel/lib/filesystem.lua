--
-- /lib/filesystem.lua
-- User-mode VFS wrapper — WDM Handle Model
-- v4: Per-coroutine write buffers. Flush on \f.
--

local oFsLib = {}

oFsLib.STDIN  = -10
oFsLib.STDOUT = -11
oFsLib.STDERR = -12

-- =============================================
-- PER-PROCESS BUFFER ISOLATION
-- Each coroutine (== process) gets its own buffer table.
-- Weak keys so dead coroutines are GC'd automatically.
-- =============================================

local tPerProcessBuffers = setmetatable({}, { __mode = "k" })

local function fGetBuffers()
    local co = coroutine.running()
    if not tPerProcessBuffers[co] then
        tPerProcessBuffers[co] = {}
    end
    return tPerProcessBuffers[co]
end

-- =============================================
-- HANDLE RESOLUTION
-- =============================================

local function fResolve(handle)
    if handle == nil then return nil end
    if type(handle) == "string" then return handle end
    if type(handle) == "number" then
        if handle <= -10 and handle >= -12 then return handle end
        if handle == 0 then return -10 end
        if handle == 1 then return -11 end
        if handle == 2 then return -12 end
        return handle
    end
    if type(handle) == "table" then
        if handle._token then return handle._token end
        if handle.fd ~= nil then return fResolve(handle.fd) end
    end
    return nil
end

-- =============================================
-- BUFFERED WRITE / FLUSH
-- =============================================

local function fFlush(tok)
    if tok == nil then return true end
    local tBuf = fGetBuffers()
    local sData = tBuf[tok]
    if sData and #sData > 0 then
        tBuf[tok] = ""
        local b1, b2 = syscall("vfs_write", tok, sData)
        return b1 and b2
    end
    return true
end

local function fFlushAll()
    local tBuf = fGetBuffers()
    for k in pairs(tBuf) do fFlush(k) end
end

-- =============================================
-- PUBLIC API
-- =============================================

oFsLib.open = function(sPath, sMode)
    local b1, b2, sToken = syscall("vfs_open", sPath, sMode or "r")
    if b1 and b2 and sToken then
        return { _token = sToken }
    end
    return nil, sToken
end

oFsLib.read = function(handle, nCount)
    local tok = fResolve(handle)
    if not tok then return nil, "Invalid handle" end
    -- only flush THIS process's buffers (safe now)
    fFlushAll()
    local b1, b2, val = syscall("vfs_read", tok, nCount or math.huge)
    return (b1 and b2) and val or nil, val
end

oFsLib.write = function(handle, sData)
    local tok = fResolve(handle)
    if not tok then return nil, "Invalid handle" end
    local tBuf = fGetBuffers()
    local sBuf = (tBuf[tok] or "") .. tostring(sData)
    tBuf[tok] = sBuf
    -- flush on newline, carriage return, form feed, or size limit
    if sBuf:find("[\n\r\f]") or #sBuf > 2048 then
        return fFlush(tok)
    end
    return true
end

oFsLib.flush = function(handle)
    local tok = fResolve(handle)
    if tok then return fFlush(tok) end
end

oFsLib.close = function(handle)
    local tok = fResolve(handle)
    if not tok then return nil end
    fFlush(tok)
    local tBuf = fGetBuffers()
    tBuf[tok] = nil
    local b1, b2 = syscall("vfs_close", tok)
    return b1 and b2
end

oFsLib.list = function(sPath)
    local b1, b2, val = syscall("vfs_list", sPath)
    return (b1 and b2 and type(val) == "table") and val or nil, val
end

oFsLib.chmod = function(sPath, nMode)
    local b1, b2, val = syscall("vfs_chmod", sPath, nMode)
    return b1 and b2, val
end

oFsLib.deviceControl = function(handle, sMethod, tArgs)
    local tok = fResolve(handle)
    if not tok then return nil, "Invalid handle" end
    local b1, b2, val = syscall("vfs_device_control", tok, sMethod, tArgs or {})
    return b1 and b2, val
end

return oFsLib