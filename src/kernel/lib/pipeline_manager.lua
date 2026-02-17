--
-- /lib/pipeline_manager.lua
-- VFS Router with Object Handle & sMLTR Support
-- v3: Per-process handle tokens, synapse token validation, handle inheritance.
--

local syscall = syscall

syscall("kernel_register_pipeline")
syscall("kernel_log", "[PM] Ring 1 Pipeline Manager started.")

local nMyPid = syscall("process_get_pid") 

local tPermCache = nil

local nDkmsPid, sDkmsErr = syscall("process_spawn", "/system/dkms.lua", 1)
if not nDkmsPid then syscall("kernel_panic", "Could not spawn DKMS: " .. tostring(sDkmsErr)) end
syscall("kernel_log", "[PM] DKMS process started as PID " .. tostring(nDkmsPid))

local vfs_state = { oRootFs = nil, nNextFd = 0, tOpenHandles = {} }
local tProcessNextAlias = {} -- [pid] = next alias number for that process
local g_tPmSignalBuffer = {}

syscall("syscall_override", "vfs_open")
syscall("syscall_override", "vfs_read")
syscall("syscall_override", "vfs_write")
syscall("syscall_override", "vfs_close")
syscall("syscall_override", "vfs_list")
syscall("syscall_override", "vfs_chmod")
syscall("syscall_override", "vfs_device_control")

syscall("syscall_override", "driver_load")


local function parse_options(sOptions)
  local tOpts = {}
  if not sOptions then return tOpts end
  for sPart in string.gmatch(sOptions, "[^,]+") do
    local k, v = sPart:match("([^=]+)=(.*)")
    if k then 
      tOpts[k] = tonumber(v) or v 
    else
      tOpts[sPart] = true
    end
  end
  return tOpts
end

-- ==========================================
-- sMLTR HELPERS
-- ==========================================


local function fResolveHandle(nCallerPid, sSynapseToken, vHandle)
  local tObj = syscall("ob_resolve_handle", nCallerPid, vHandle)
  if not tObj then
    return nil, nil, "Handle not found for PID " .. nCallerPid .. " handle " .. tostring(vHandle)
  end
  -- sMLTR validation (skip for system PIDs)
  if nCallerPid >= 20 and tObj.sSynapseToken and sSynapseToken then
    if tObj.sSynapseToken ~= sSynapseToken then
      syscall("kernel_log", "[PM] sMLTR VIOLATION: PID " .. nCallerPid .. " token mismatch")
      return nil, nil, "Synapse token mismatch"
    end
  end
  return tObj.nInternalFd, tObj
end

--[[
-- Validate that the caller's synapse token matches what's stored in the handle.
-- Returns true if valid, false + reason if not.
local function fValidateSynapseToken(nCallerPid, sSynapseToken, tObjectHeader)
  if not tObjectHeader then return false, "No object header" end
  -- System processes (PID < 20) bypass sMLTR
  if nCallerPid < 20 then return true end
  -- If handle has no token stored (legacy), allow access but log
  if not tObjectHeader.sSynapseToken then return true end
  -- The actual check
  if tObjectHeader.sSynapseToken ~= sSynapseToken then
    syscall("kernel_log", "[PM] sMLTR VIOLATION: PID " .. nCallerPid .. " token mismatch on handle")
    return false, "Synapse token mismatch"
  end
  return true
end

-- Resolve a handle (token string or numeric alias) for a given process.
-- Uses kernel ob_manager syscalls. Returns the internal FD and the object header.
local function fResolveHandle(nCallerPid, sSynapseToken, vHandle)
  local tObj = syscall("ob_resolve_handle", nCallerPid, vHandle)
  if not tObj then
    -- Auto-create standard aliases for FDs 0, 1, 2 if they don't exist yet
    if type(vHandle) == "number" and vHandle <= 2 then
      local bOk, sToken = fAutoCreateStdHandle(nCallerPid, sSynapseToken, vHandle)
      if bOk then
        tObj = syscall("ob_resolve_handle", nCallerPid, vHandle)
      end
    end
    if not tObj then return nil, nil, "Handle not found" end
  end
  
  -- sMLTR validation
  local bValid, sReason = fValidateSynapseToken(nCallerPid, sSynapseToken, tObj)
  if not bValid then return nil, nil, sReason end
  
  return tObj.nInternalFd, tObj
end

-- Auto-create standard I/O handles (stdin=0, stdout=1, stderr=2)
-- This handles the case where a child process uses print() / fd 1
-- without having explicitly opened /dev/tty.
function fAutoCreateStdHandle(nCallerPid, sSynapseToken, nAlias)
  syscall("kernel_log", "[PM] Auto-creating std handle alias " .. nAlias .. " for PID " .. nCallerPid)
  
  -- Open /dev/tty for this process
  local sMode = (nAlias == 0) and "r" or "w"
  
  -- Do the internal open (we are PM, we call ourselves)
  local bOk, nFd = _doInternalOpen(nMyPid, "/dev/tty", sMode)
  if not bOk then return false end
  
  -- Create handle token in ob_manager
  local sToken = syscall("ob_create_handle", nCallerPid, {
    nInternalFd = nFd,
    sSynapseToken = sSynapseToken,
    sPath = "/dev/tty",
  })
  
  if sToken then
    syscall("ob_set_alias", nCallerPid, nAlias, sToken)
    return true, sToken
  end
  return false
end

--]]


-- ==========================================
-- BOOT LOG FLUSH
-- ==========================================

local function flush_boot_log(sLogDevice)
  syscall("kernel_log", "[PM] Flushing boot log to " .. sLogDevice)
  local sBootLog = syscall("kernel_get_boot_log")
  if not sBootLog or #sBootLog == 0 then return end
  
  local bOk, nFd = _doInternalOpen(nMyPid, sLogDevice, "w")
  if bOk then
     _doInternalWrite(nMyPid, nFd, sBootLog)
     _doInternalClose(nMyPid, nFd)
     syscall("kernel_log", "[PM] Boot log flushed.")
  else
     syscall("kernel_log", "[PM] Failed to open log device for flushing.")
  end
end


local function wait_for_dkms()
  while true do
    local bOk, nSender, sSig, p1, p2, p3, p4, p5 = syscall("signal_pull")
    if bOk then
        if sSig == "syscall_return" and nSender == nDkmsPid then
           return p1, p2
        elseif sSig == "os_event" then
           syscall("signal_send", nDkmsPid, "os_event", p1, p2, p3, p4, p5)
        else
           -- Buffer any other signals so they aren't lost
           table.insert(g_tPmSignalBuffer, {nSender, sSig, p1, p2, p3, p4, p5})
        end
    end
  end
end

local function load_perms()
  local bOk, h = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", "/etc/perms.lua", "r")
  if bOk and h then
     local bReadOk, d = syscall("raw_component_invoke", vfs_state.oRootFs.address, "read", h, math.huge)
     syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", h)
     if bReadOk and d then 
        local f = load(d, "perms", "t", {})
        if f then tPermCache = f() end
     end
  end
  if not tPermCache then tPermCache = {} end
end

local function save_perms()
  if not tPermCache then return end
  local sData = "return {\n"
  for sPath, tInfo in pairs(tPermCache) do
     sData = sData .. string.format('  ["%s"] = { uid = %d, gid = %d, mode = %d },\n', 
       sPath, tInfo.uid or 0, tInfo.gid or 0, tInfo.mode or 755)
  end
  sData = sData .. "}"
  local bOk, h = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", "/etc/perms.lua", "w")
  if bOk and h then
     syscall("raw_component_invoke", vfs_state.oRootFs.address, "write", h, sData)
     syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", h)
  else
     syscall("kernel_log", "[PM] ERROR: Failed to save permissions to disk!")
  end
end

local function check_access(nPid, sPath, sMode)
  local nUid = 1000
  if nPid < 20 then nUid = 0 end
  if nUid == 0 then return true end
  if not tPermCache then load_perms() end
  local tP = tPermCache[sPath]
  if not tP then tP = { uid=0, gid=0, mode=755 } end
  local nReq = 4
  if sMode == "w" or sMode == "a" then nReq = 2 end
  local nPermDigit = 0
  local sModeStr = tostring(tP.mode)
  if nUid == tP.uid then
     nPermDigit = tonumber(sModeStr:sub(1,1))
  else
     nPermDigit = tonumber(sModeStr:sub(3,3))
  end
  local bAllowed = false
  if nReq == 4 then
     if nPermDigit >= 4 then bAllowed = true end
  elseif nReq == 2 then
     if nPermDigit == 2 or nPermDigit == 3 or nPermDigit == 6 or nPermDigit == 7 then bAllowed = true end
  end
  if not bAllowed then
     syscall("kernel_log", "[PM] ACCESS DENIED: PID " .. nPid .. " tried to " .. sMode .. " " .. sPath)
  end
  return bAllowed
end


-- ==========================================
-- INTERNAL VFS OPS (used by PM itself, no handle tokens)
-- ==========================================

function _doInternalOpen(nSenderPid, sPath, sMode)
  if string.sub(sPath, 1, 5) == "/dev/" then
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_CREATE)
    if sPath == "/dev/tty" then pIrp.sDeviceName = "\\Device\\TTY0" 
    elseif sPath == "/dev/gpu0" then pIrp.sDeviceName = "\\Device\\Gpu0"
    else pIrp.sDeviceName = "\\Device" .. sPath:sub(5):gsub("/", "\\") end
    pIrp.nSenderPid = nMyPid
    pIrp.tParameters.sMode = sMode
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    local nStatus, vInfo = wait_for_dkms()
    if nStatus == 0 then 
       local nFd = vfs_state.nNextFd
       vfs_state.nNextFd = vfs_state.nNextFd + 1
       local nDriverPid = (type(vInfo) == "number") and vInfo or nDkmsPid
       vfs_state.tOpenHandles[nFd] = { 
         type = "device", devname = pIrp.sDeviceName, driverPid = nDriverPid
       }
       return true, nFd
    else
       return nil, "Device Open Failed: " .. tostring(nStatus)
    end
  end
  
  local bOk, hHandle, sReason = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", sPath, sMode)
  if not hHandle then return nil, sReason end
  local nFd = vfs_state.nNextFd
  vfs_state.nNextFd = vfs_state.nNextFd + 1
  vfs_state.tOpenHandles[nFd] = { type = "file", handle = hHandle }
  return true, nFd
end

function _doInternalWrite(nSenderPid, nFd, sData)
  local tHandle = vfs_state.tOpenHandles[nFd]
  if not tHandle then return nil, "Invalid Handle" end
  if tHandle.type == "file" then
    return syscall("raw_component_invoke", vfs_state.oRootFs.address, "write", tHandle.handle, sData)
  elseif tHandle.type == "device" then
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_WRITE)
    pIrp.sDeviceName = tHandle.devname
    pIrp.nSenderPid = nMyPid
    pIrp.tParameters.sData = sData
    if tHandle.devname == "\\Device\\TTY0" then
        pIrp.nFlags = tDKStructs.IRP_FLAG_NO_REPLY 
        local nTarget = tHandle.driverPid or nDkmsPid
        local sSignal = (nTarget == nDkmsPid) and "vfs_io_request" or "irp_dispatch"
        syscall("signal_send", nTarget, sSignal, pIrp)
        return true, #sData
    end
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    local nStatus, vInfo = wait_for_dkms()
    if nStatus == 0 then return true, vInfo else return nil, "Write Error" end
  end
end

function _doInternalRead(nSenderPid, nFd, nCount)
  local tHandle = vfs_state.tOpenHandles[nFd]
  if not tHandle then return nil, "Invalid Handle" end
  if tHandle.type == "file" then
    local res1, res2 = syscall("raw_component_invoke", vfs_state.oRootFs.address, "read", tHandle.handle, nCount)
    if type(res2) == "boolean" then res2 = nil end
    return res1, res2
  elseif tHandle.type == "device" then
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_READ)
    pIrp.sDeviceName = tHandle.devname
    pIrp.nSenderPid = nMyPid
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    local nStatus, vInfo = wait_for_dkms()
    if nStatus == 0 then return true, vInfo else return nil, "Read Error" end
  end
end

function _doInternalClose(nSenderPid, nFd)
  local tHandle = vfs_state.tOpenHandles[nFd]
  if not tHandle then return nil end
  if tHandle.type == "file" then
      syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", tHandle.handle)
  elseif tHandle.type == "device" then
      local tDKStructs = require("shared_structs")
      local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_CLOSE)
      pIrp.sDeviceName = tHandle.devname
      pIrp.nSenderPid = nMyPid
      syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
      wait_for_dkms()
  end
  vfs_state.tOpenHandles[nFd] = nil
  return true
end


-- ==========================================
-- PUBLIC VFS HANDLERS (called via syscall override)
-- These now accept synapse tokens from the kernel dispatcher.
-- ==========================================

function vfs_state.handle_open(nSenderPid, sSynapseToken, sPath, sMode)
  if string.sub(sPath, 1, 5) ~= "/dev/" then
    if not check_access(nSenderPid, sPath, sMode or "r") then
       return nil, "Permission denied"
    end
  end

  local bOk, nFd = _doInternalOpen(nSenderPid, sPath, sMode)
  if not bOk then return nil, nFd end

  -- Find next free alias for this process (skip over inherited ones)
  if not tProcessNextAlias[nSenderPid] then tProcessNextAlias[nSenderPid] = 0 end
  local nAlias = tProcessNextAlias[nSenderPid]
  -- Skip aliases that already exist (e.g. inherited 0, 1, 2)
  while syscall("ob_resolve_handle", nSenderPid, nAlias) ~= nil do
    nAlias = nAlias + 1
  end
  tProcessNextAlias[nSenderPid] = nAlias + 1

  local sToken = syscall("ob_create_handle", nSenderPid, {
    nInternalFd = nFd,
    sSynapseToken = sSynapseToken,
    sPath = sPath,
  })
  if sToken then
    syscall("ob_set_alias", nSenderPid, nAlias, sToken)
  end

  return true, nAlias
end


function vfs_state.handle_write(nSenderPid, sSynapseToken, vHandle, sData)
  local nFd, tObj, sErr = fResolveHandle(nSenderPid, sSynapseToken, vHandle)
  if not nFd then return nil, sErr or "Invalid Handle" end
  return _doInternalWrite(nSenderPid, nFd, sData)
end

function vfs_state.handle_read(nSenderPid, sSynapseToken, vHandle, nCount)
  local nFd, tObj, sErr = fResolveHandle(nSenderPid, sSynapseToken, vHandle)
  if not nFd then return nil, sErr or "Invalid Handle" end
  return _doInternalRead(nSenderPid, nFd, nCount)
end

function vfs_state.handle_close(nSenderPid, sSynapseToken, vHandle)
  local nFd, tObj, sErr = fResolveHandle(nSenderPid, sSynapseToken, vHandle)
  if not nFd then return nil end
  _doInternalClose(nSenderPid, nFd)
  syscall("ob_close_handle", nSenderPid, vHandle)
  return true
end

function vfs_state.handle_chmod(nSenderPid, sPath, nMode)
  local nUid = syscall("process_get_uid", nSenderPid) or 1000
  if not tPermCache then load_perms() end
  local tEntry = tPermCache[sPath]
  if not tEntry then
     tEntry = { uid = nUid, gid = 0, mode = 755 }
     tPermCache[sPath] = tEntry
  end
  if nUid ~= 0 and tEntry.uid ~= nUid then
     syscall("kernel_log", "[PM] CHMOD DENIED: PID " .. nSenderPid .. " (UID " .. nUid .. ") tried to touch " .. sPath)
     return nil, "Operation not permitted (Not owner)"
  end
  if nUid ~= 0 and (sPath:sub(1,5) == "/boot" or sPath:sub(1,4) == "/sys") then
     return nil, "Operation not permitted (System protected)"
  end
  tEntry.mode = nMode
  save_perms()
  syscall("kernel_log", "[PM] CHMOD: " .. sPath .. " -> " .. nMode .. " by UID " .. nUid)
  return true
end

function vfs_state.handle_device_control(nSenderPid, sSynapseToken, vHandle, sMethod, tArgs)
  local nFd, tObj, sErr = fResolveHandle(nSenderPid, sSynapseToken, vHandle)
  if not nFd then return nil, sErr or "Invalid Handle" end
  
  local tHandle = vfs_state.tOpenHandles[nFd]
  if not tHandle or tHandle.type ~= "device" then
    return nil, "Not a device handle"
  end
  
  local tDKStructs = require("shared_structs")
  local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_DEVICE_CONTROL)
  pIrp.sDeviceName = tHandle.devname
  pIrp.nSenderPid = nMyPid
  pIrp.tParameters.sMethod = sMethod
  pIrp.tParameters.tArgs = tArgs or {}
  
  syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
  local nStatus, vInfo = wait_for_dkms()
  if nStatus == 0 then return true, vInfo else return nil, "DeviceControl Error" end
end

function vfs_state.handle_list(nSenderPid, sPath)
  local sCleanPath = sPath
  if #sCleanPath > 1 and string.sub(sCleanPath, -1) == "/" then
     sCleanPath = string.sub(sCleanPath, 1, -2)
  end
  if sCleanPath == "/dev" then
     syscall("signal_send", nDkmsPid, "dkms_list_devices_request", nSenderPid)
     while true do
        local bOk, nSender, sSig, p1, p2 = syscall("signal_pull")
        if bOk and nSender == nDkmsPid then
           if sSig == "dkms_list_devices_result" and p1 == nSenderPid then
              return true, p2
           elseif sSig == "os_event" then
              syscall("signal_send", nDkmsPid, "os_event", p1, p2)
           end
        end
     end
  end
  local bOk, tListOrErr = syscall("raw_component_invoke", vfs_state.oRootFs.address, "list", sPath)
  if bOk then return true, tListOrErr else return nil, tListOrErr end
end


function vfs_state.handle_driver_load(nSenderPid, sPath)
  -- Security: check ring and UID
  local nCallerRing = syscall("process_get_ring")
  -- nCallerRing here is PM's ring (1), not the original caller's.
  -- We check the original caller's UID instead.
  local nUid = syscall("process_get_uid", nSenderPid) or 1000
  if nUid ~= 0 then
     syscall("kernel_log", "[PM] DRIVER_LOAD DENIED: PID " .. nSenderPid .. " (UID " .. nUid .. ") is not root")
     return nil, "Permission denied: only root (UID 0) can load drivers"
  end

  syscall("kernel_log", "[PM] User (PID " .. nSenderPid .. ") requested load of: " .. sPath)
  syscall("signal_send", nDkmsPid, "load_driver_path_request", sPath, nSenderPid)
  while true do
    local bOk, nSender, sSig, p1, p2, p3, p4 = syscall("signal_pull") 
    if bOk and nSender == nDkmsPid then
       if sSig == "load_driver_result" and p1 == nSenderPid then
          local nStatus, sDrvName, nDrvPid = p2, p3, p4
          if not sDrvName then sDrvName = "Unknown" end
          if nStatus == 0 then 
             local sMsg = (nDrvPid == 0) and string.format("[PM] Success: %s", sDrvName) or string.format("[PM] Success: Loaded '%s' (PID %d)", sDrvName, nDrvPid)
             syscall("kernel_log", sMsg)
             return true, sMsg 
          else
             local sMsg = "[PM] Driver load failed. Status: " .. tostring(nStatus)
             syscall("kernel_log", sMsg)
             return nil, sMsg 
          end
       elseif sSig == "os_event" then
          syscall("signal_send", nDkmsPid, "os_event", p1, p2, p3, p4)
       else
          table.insert(g_tPmSignalBuffer, {nSender, sSig, p1, p2, p3, p4})
       end
    elseif bOk then
       -- Signal from non-DKMS sender — buffer it
       table.insert(g_tPmSignalBuffer, {nSender, sSig, p1, p2, p3, p4})
    end
  end
end


-- ==========================================
-- BOOT HELPERS
-- ==========================================

local function get_gpu_proxy()
  local bOk, tList = syscall("raw_component_list", "gpu")
  if not bOk or not tList then return nil end
  for sAddr in pairs(tList) do return syscall("raw_component_proxy", sAddr) end
end

local function get_screen_addr()
  local bOk, tList = syscall("raw_component_list", "screen")
  if not bOk or not tList then return nil end
  for sAddr in pairs(tList) do return sAddr end
end

local function wait_with_throbber(sMessage, nSeconds)
  local oGpu = get_gpu_proxy()
  local sScreen = get_screen_addr()
  local nWidth, nHeight = 80, 25
  if oGpu and sScreen then 
     oGpu.bind(sScreen) 
     nWidth, nHeight = oGpu.getResolution()
  end
  local nStartTime = computer.uptime()
  local nDeadline = nStartTime + nSeconds
  local nFrame = 0
  local nThrobberWidth = 12
  syscall("kernel_log", "[PM] " .. sMessage)
  while computer.uptime() < nDeadline do
    if oGpu then
       local nPos = math.floor(nFrame / 1.5) % (nThrobberWidth * 2 - 2)
       if nPos >= nThrobberWidth then nPos = (nThrobberWidth * 2 - 2) - nPos end
       local sLine = "("
       for i = 0, nThrobberWidth - 1 do
          if i >= nPos and i < nPos + 3 then sLine = sLine .. "*"
          else sLine = sLine .. " " end
       end
       sLine = sLine .. ")"
       local sFullMsg = string.format("%s %s", sLine, "Driver loading...")
       oGpu.set(1, nHeight, sFullMsg .. string.rep(" ", nWidth - #sFullMsg))
       nFrame = nFrame + 1
    end
    syscall("process_yield")
  end
  if oGpu then oGpu.fill(1, nHeight, nWidth, 1, " ") end
end

local function __scandrvload()
  syscall("kernel_log", "[PM] Loading TTY Driver explicitly...")
  syscall("signal_send", nDkmsPid, "load_driver_path", "/drivers/tty.sys.lua")
  
  local deadline = computer.uptime() + 0.0
  while computer.uptime() < deadline do syscall("process_yield") end

  syscall("kernel_log", "[PM] Scanning components...")

  local sRootUuid, oRootProxy = syscall("kernel_get_root_fs")
  if not oRootProxy then syscall("kernel_panic", "Pipeline could not get root FS info.") end
  vfs_state.oRootFs = oRootProxy
  
  local bListOk, tCompList = syscall("raw_component_list")
  if not bListOk then return end
  
  for sAddr, sCtype in pairs(tCompList) do
    if sCtype ~= "screen" and sCtype ~= "gpu" and sCtype ~= "keyboard" then
        syscall("kernel_log", "[PM] Loading driver for " .. sCtype)
        syscall("signal_send", nDkmsPid, "load_driver_for_component", sCtype, sAddr)
    end
  end
end


local function process_fstab()
  syscall("kernel_log", "[PM] Processing fstab...")
  local bOpenOk, hFstab = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", "/etc/fstab.lua", "r")
  if bOpenOk and hFstab then
     local bReadOk, sData = syscall("raw_component_invoke", vfs_state.oRootFs.address, "read", hFstab, math.huge)
     syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", hFstab)
     if bReadOk and type(sData) == "string" then
        local f, sErr = load(sData, "fstab", "t", {})
        if f then 
           local tFstab = f()
           if type(tFstab) == "table" then
               for _, tEntry in ipairs(tFstab) do
                  if tEntry.type == "ringfs" then
                     if not bRingFsLoaded then
                         syscall("kernel_log", "[PM] Auto-loading RingFS...")
                         syscall("signal_send", nDkmsPid, "load_driver_path", "/drivers/ringfs.sys.lua")
                         syscall("process_wait", 0) 
                         bRingFsLoaded = true
                     end
                     local tOpts = parse_options(tEntry.options)
                     if tOpts.size then
                        local tDKStructs = require("shared_structs")
                        local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_DEVICE_CONTROL)
                        pIrp.sDeviceName = "\\Device\\ringlog"
                        pIrp.nSenderPid = nMyPid
                        pIrp.tParameters.sMethod = "resize"
                        pIrp.tParameters.tArgs = { tOpts.size }
                        syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
                        wait_for_dkms()
                     end
                     if string.sub(tEntry.path, 1, 5) == "/dev/" then
                        flush_boot_log(tEntry.path)
                     end
                  end
               end
           end
        else
            syscall("kernel_log", "[PM] Syntax error in fstab: " .. tostring(sErr))
        end
     end
  else
     syscall("kernel_log", "[PM] Warning: /etc/fstab.lua not found or unreadable.")
  end
end

local function process_autoload()
  syscall("kernel_log", "[PM] Processing autoload...")
  local bOk, hFile = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", "/etc/autoload.lua", "r")
  if bOk and hFile then
     local _, sData = syscall("raw_component_invoke", vfs_state.oRootFs.address, "read", hFile, math.huge)
     syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", hFile)
     if sData then
        local f = load(sData, "autoload", "t", {})
        if f then
           local tList = f()
           if tList then
              for _, sDrvPath in ipairs(tList) do
                 syscall("kernel_log", "[PM] Autoloading: " .. sDrvPath)
                 syscall("signal_send", nDkmsPid, "load_driver_path", sDrvPath)
                 syscall("process_wait", 0)
              end
           end
        end
     end
  end
end


-- ==========================================
-- BOOT SEQUENCE
-- ==========================================

__scandrvload()
process_fstab()
if env.SAFE_MODE then
   syscall("kernel_log", "[PM] SAFE MODE ENABLED: Skipping autoload.lua")
else
   process_autoload()
end

wait_with_throbber("Waiting for system stabilization...", 1.0)

syscall("kernel_log", "[PM] Silence on deck. Handing off to userspace.")
syscall("kernel_set_log_mode", false)


local sInitPath = env.INIT_PATH or "/bin/init.lua"
syscall("kernel_log", "[PM] Spawning " .. sInitPath .. "...")
local nInitPid, sInitErr = syscall("process_spawn", sInitPath, 3)

if not nInitPid then syscall("kernel_log", "[PM] FAILED TO SPAWN INIT: " .. tostring(sInitErr))
else syscall("kernel_log", "[PM] Init spawned as PID " .. tostring(nInitPid)) end


-- ==========================================
-- MAIN DISPATCH LOOP
-- ==========================================

while true do
   -- Drain buffered signals first
   while #g_tPmSignalBuffer > 0 do
      local tSig = table.remove(g_tPmSignalBuffer, 1)
      local nBufSender, sBufSig = tSig[1], tSig[2]
      local bp1, bp2, bp3, bp4, bp5 = tSig[3], tSig[4], tSig[5], tSig[6], tSig[7]
      
      if sBufSig == "syscall" then
        local tData = bp1
        local sName = tData.name
        local tArgs = tData.args
        local nCaller = tData.sender_pid
        local sSynToken = tData.synapse_token
        local result1, result2
        
        if sName == "vfs_open" then result1, result2 = vfs_state.handle_open(nCaller, sSynToken, tArgs[1], tArgs[2])
        elseif sName == "vfs_write" then result1, result2 = vfs_state.handle_write(nCaller, sSynToken, tArgs[1], tArgs[2])
        elseif sName == "vfs_read" then result1, result2 = vfs_state.handle_read(nCaller, sSynToken, tArgs[1], tArgs[2])
        elseif sName == "vfs_close" then result1, result2 = vfs_state.handle_close(nCaller, sSynToken, tArgs[1])
        elseif sName == "vfs_list" then result1, result2 = vfs_state.handle_list(nCaller, tArgs[1])
        elseif sName == "vfs_chmod" then result1, result2 = vfs_state.handle_chmod(nCaller, tArgs[1], tArgs[2])
        elseif sName == "vfs_device_control" then result1, result2 = vfs_state.handle_device_control(nCaller, sSynToken, tArgs[1], tArgs[2], tArgs[3])
        elseif sName == "driver_load" then result1, result2 = vfs_state.handle_driver_load(nCaller, tArgs[1])
        end
        
        if result1 ~= "async_wait" then
          syscall("signal_send", nCaller, "syscall_return", result1, result2)
        end
      elseif sBufSig == "os_event" then
        syscall("signal_send", nDkmsPid, "os_event", bp1, bp2, bp3, bp4, bp5)
      end
    end
  local bOk, nSender, sSignal, p1, p2, p3, p4, p5 = syscall("signal_pull")
  if bOk then
    if sSignal == "syscall" then
      local tData = p1
      local sName = tData.name
      local tArgs = tData.args
      local nCaller = tData.sender_pid
      local sSynapseToken = tData.synapse_token -- sMLTR: token from kernel
      local result1, result2
      
      if sName == "vfs_open" then 
        result1, result2 = vfs_state.handle_open(nCaller, sSynapseToken, tArgs[1], tArgs[2])
      elseif sName == "vfs_write" then 
        result1, result2 = vfs_state.handle_write(nCaller, sSynapseToken, tArgs[1], tArgs[2])
      elseif sName == "vfs_read" then 
        result1, result2 = vfs_state.handle_read(nCaller, sSynapseToken, tArgs[1], tArgs[2])
      elseif sName == "vfs_close" then 
        result1, result2 = vfs_state.handle_close(nCaller, sSynapseToken, tArgs[1])
      elseif sName == "vfs_list" then 
        result1, result2 = vfs_state.handle_list(nCaller, tArgs[1])
      elseif sName == "vfs_chmod" then 
        result1, result2 = vfs_state.handle_chmod(nCaller, tArgs[1], tArgs[2])
      elseif sName == "vfs_device_control" then
        result1, result2 = vfs_state.handle_device_control(nCaller, sSynapseToken, tArgs[1], tArgs[2], tArgs[3])
      elseif sName == "driver_load" then 
        result1, result2 = vfs_state.handle_driver_load(nCaller, tArgs[1])
      end
      
      if result1 ~= "async_wait" then
         syscall("signal_send", nCaller, "syscall_return", result1, result2)
      end
    elseif sSignal == "os_event" then
       syscall("signal_send", nDkmsPid, "os_event", p1, p2, p3, p4, p5)
    end
  end
end