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

local function fFlush(vFd)
  local sData = tBuffers[vFd]
  if sData and #sData > 0 then
    tBuffers[vFd] = ""
    local bSys, bVfs, valResult = syscall("vfs_write", vFd, sData)
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
  local vFd = fGetFd(hHandle)
  if vFd == nil then return nil, "Invalid handle" end
  
  -- flush all write buffers before reading
  for vBufFd, _ in pairs(tBuffers) do
     fFlush(vBufFd)
  end
  
  local bSys, bVfs, valResult = syscall("vfs_read", vFd, nCount or math.huge)
  return (bSys and bVfs) and valResult or nil, valResult
end

oFsLib.write = function(hHandle, sData)
  local vFd = fGetFd(hHandle)
  if vFd == nil then return nil, "Invalid handle" end
  
  -- Buffer key: use tostring so both strings and numbers work as keys
  local sBufKey = tostring(vFd)
  local sBuf = (tBuffers[sBufKey] or "") .. tostring(sData)
  tBuffers[sBufKey] = sBuf
  
  if sBuf:find("[\n\r]") or #sBuf > 2048 then
     return fFlush(vFd)
  end
  return true
end

oFsLib.flush = function(hHandle)
  local vFd = fGetFd(hHandle)
  if vFd ~= nil then return fFlush(vFd) end
end

oFsLib.close = function(hHandle)
  local vFd = fGetFd(hHandle)
  if vFd == nil then return nil end
  
  local sBufKey = tostring(vFd)
  fFlush(vFd)
  tBuffers[sBufKey] = nil
  
  local bSys, bVfs = syscall("vfs_close", vFd)
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
  local vFd = fGetFd(hHandle)
  if vFd == nil then return nil, "Invalid handle" end
  local bSys, bVfs, valResult = syscall("vfs_device_control", vFd, sMethod, tArgs)
  return bSys and bVfs, valResult
end

return oFsLib