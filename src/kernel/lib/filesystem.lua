--
-- /lib/filesystem.lua
-- user-mode fs wrapper.
-- v3: Object Handle token support. Handles can be string tokens or numeric aliases.
--     Aggressive buffering retained for performance.
--

local oFsLib = {}
local tBuffers = {} 

-- Internal: get the raw handle value (token string or numeric alias)
local function fGetFd(hHandle)
  if not hHandle then return nil end
  if type(hHandle) == "table" then return hHandle.fd end
  return hHandle -- already a raw value
end

local function fFlush(nFd)
  local sData = tBuffers[nFd]
  if sData and #sData > 0 then
    tBuffers[nFd] = ""
    local bSys, bVfs, valResult = syscall("vfs_write", nFd, sData)
    return bSys and bVfs, valResult
  end
  return true
end

oFsLib.open = function(sPath, sMode)
  local bSys, bVfs, valResult = syscall("vfs_open", sPath, sMode or "r")
  if bSys and bVfs and valResult ~= nil then
    -- valResult is now a handle token (string) or legacy fd (number)
    return { fd = valResult }
  else
    return nil, valResult
  end
end

oFsLib.read = function(hHandle, nCount)
  if not hHandle then return nil, "Invalid handle" end
  local nFd = (type(hHandle) == "table") and hHandle.fd or hHandle
  if nFd == nil then return nil, "Invalid handle" end

  -- flush all write buffers before reading
  for nBufFd, _ in pairs(tBuffers) do
     fFlush(nBufFd)
  end

  local bSys, bVfs, valResult = syscall("vfs_read", nFd, nCount or math.huge)
  return (bSys and bVfs) and valResult or nil, valResult
end

oFsLib.write = function(hHandle, sData)
  if not hHandle then return nil, "Invalid handle" end
  local nFd = (type(hHandle) == "table") and hHandle.fd or hHandle
  if nFd == nil then return nil, "Invalid handle" end

  local sBuf = (tBuffers[nFd] or "") .. tostring(sData)
  tBuffers[nFd] = sBuf

  if sBuf:find("[\n\r]") or #sBuf > 2048 then
     return fFlush(nFd)
  end
  return true
end

oFsLib.flush = function(hHandle)
  if not hHandle then return end
  local nFd = (type(hHandle) == "table") and hHandle.fd or hHandle
  if nFd ~= nil then return fFlush(nFd) end
end

oFsLib.close = function(hHandle)
  if not hHandle then return nil end
  local nFd = (type(hHandle) == "table") and hHandle.fd or hHandle
  if nFd == nil then return nil end

  fFlush(nFd)
  tBuffers[nFd] = nil

  local bSys, bVfs = syscall("vfs_close", nFd)
  return bSys and bVfs
end

oFsLib.list = function(sPath)
  local bSys, bVfs, valResult = syscall("vfs_list", sPath)
  return (bSys and bVfs and type(valResult) == "table") and valResult or nil, valResult
end

oFsLib.chmod = function(sPath, nMode)
  local bSys, bVfs, valResult = syscall("vfs_chmod", sPath, nMode)
  return bSys and bVfs, valResult
end

-- deviceControl for ITER and similar drivers
oFsLib.deviceControl = function(hHandle, sMethod, tArgs)
  if not hHandle then return nil, "Invalid handle" end
  local nFd = (type(hHandle) == "table") and hHandle.fd or hHandle
  if nFd == nil then return nil, "Invalid handle" end
  local bSys, bVfs, valResult = syscall("vfs_device_control", nFd, sMethod, tArgs or {})
  return bSys and bVfs, valResult
end

return oFsLib