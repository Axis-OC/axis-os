--
-- /kernel.lua
-- AxisOS Xen XKA v0.3
-- v3: Object Handles, sMLTR (Synapse Message Layer Token Randomization),
--     Ring 3 multitasking improvements.
--

local kernel = {
  tProcessTable = {},
  tPidMap = {},
  tRings = {},
  nNextPid = 1,
  
  tSyscallTable = {},
  tSyscallOverrides = {},
  
  tEventQueue = {},
  
  tVfs = {
    tMounts = {},
    oRootFs = nil,
    sRootUuid = nil,
  },
  
  tDriverRegistry = {},
  tComponentDriverMap = {},
  nPipelinePid = nil,
  tBootLog = {},
  tLoadedModules = {},
}

local g_nCurrentPid = 0
local g_nDebugY = 2
local g_bLogToScreen = true
local g_oGpu = nil
local g_nWidth, g_nHeight = 80, 25
local g_nCurrentLine = 0
local tBootArgs = boot_args or {} 

-- Object Manager (loaded at boot from /lib/ob_manager.lua)
local g_oObManager = nil

-- Color constants
local C_WHITE  = 0xFFFFFF
local C_GRAY   = 0xAAAAAA
local C_GREEN  = 0x55FF55
local C_RED    = 0xFF5555
local C_YELLOW = 0xFFFF55
local C_CYAN   = 0x55FFFF
local C_BLUE   = 0x5555FF

local tLogLevels = {
  ok    = { text = "[  OK  ]", color = C_GREEN },
  fail  = { text = "[ FAIL ]", color = C_RED },
  info  = { text = "[ INFO ]", color = C_CYAN },
  warn  = { text = "[ WARN ]", color = C_YELLOW },
  dev   = { text = "[ DEV  ]", color = C_BLUE },
  none  = { text = "         ", color = C_WHITE },
}

local tLogLevelsPriority = {
  debug = 0, info = 1, warn = 2, fail = 3, none = 4
}

local sCurrentLogLevel = string.lower(tBootArgs.loglevel or "info")
local nMinPriority = tLogLevelsPriority[sCurrentLogLevel] or 1

-------------------------------------------------
-- sMLTR: SYNAPSE TOKEN GENERATION
-------------------------------------------------

-- Counter for extra entropy in token generation
local g_nSynapseCounter = 0

-- Generate a cryptographically-ish unique synapse token.
-- Uses uptime, counter, and random values for entropy.
local function fGenerateSynapseToken()
    g_nSynapseCounter = g_nSynapseCounter + 1
    local nUptime = math.floor(raw_computer.uptime() * 100000)
    local t = {}
    for i = 1, 4 do
        local nEntropy = math.random(0, 0xFFFF)
        -- mix in counter and uptime bits
        nEntropy = (nEntropy + g_nSynapseCounter * 31 + nUptime) % 0xFFFF
        t[i] = string.format("%04x", nEntropy)
        -- rotate uptime bits for next iteration
        nUptime = math.floor(nUptime / 7) + math.random(0, 0xFF)
    end
    return "SYN-" .. table.concat(t, "-")
end

-------------------------------------------------
-- EARLY BOOT & DEBUG FUNCTIONS
-------------------------------------------------

local function __gpu_dprint(sText)
  local sGpuAddr, sScreenAddr
  for sAddr in raw_component.list("gpu") do sGpuAddr = sAddr; break end
  for sAddr in raw_component.list("screen") do sScreenAddr = sAddr; break end
  if sGpuAddr and sScreenAddr then
    local oGpu = raw_component.proxy(sGpuAddr)
    pcall(oGpu.bind, sScreenAddr)
    pcall(oGpu.fill, 1, g_nDebugY, 160, 1, " ")
    pcall(oGpu.set, 1, g_nDebugY, tostring(sText))
    g_nDebugY = g_nDebugY + 1
    if g_nDebugY > 40 then g_nDebugY = 2 end
  end
end

local function __logger_init()
  local sGpuAddr, sScreenAddr
  for sAddr in raw_component.list("gpu") do sGpuAddr = sAddr; break end
  for sAddr in raw_component.list("screen") do sScreenAddr = sAddr; break end
  if sGpuAddr and sScreenAddr then
    g_oGpu = raw_component.proxy(sGpuAddr)
    pcall(g_oGpu.bind, sScreenAddr)
    g_nWidth, g_nHeight = g_oGpu.getResolution()
    g_oGpu.fill(1, 1, g_nWidth, g_nHeight, " ")
    g_nCurrentLine = 0
  end
end

function kprint(sLevel, ...)
  local nMsgPriority = tLogLevelsPriority[sLevel] or 1
  if nMsgPriority < nMinPriority then return end 
  local tMsgParts = {...}
  local sMessage = ""
  for i, v in ipairs(tMsgParts) do
    sMessage = sMessage .. tostring(v) .. (i < #tMsgParts and " " or "")
  end
  local sFullLogMessage = string.format("[%s] %s", sLevel, sMessage)
  table.insert(kernel.tBootLog, sFullLogMessage)
  if not g_bLogToScreen then return end
  if not g_oGpu then return end
  if g_nCurrentLine >= g_nHeight then
    g_oGpu.copy(1, 2, g_nWidth, g_nHeight - 1, 0, -1)
    g_oGpu.fill(1, g_nHeight, g_nWidth, 1, " ")
  else
    g_nCurrentLine = g_nCurrentLine + 1
  end
  local tLevelInfo = tLogLevels[sLevel] or tLogLevels.none
  local nPrintY = g_nCurrentLine
  local nPrintX = 1
  g_oGpu.setForeground(C_GRAY)
  local sTimestamp = string.format("[%8.4f]", raw_computer.uptime())
  g_oGpu.set(nPrintX, nPrintY, sTimestamp)
  nPrintX = nPrintX + #sTimestamp + 1
  g_oGpu.setForeground(tLevelInfo.color)
  g_oGpu.set(nPrintX, nPrintY, tLevelInfo.text)
  nPrintX = nPrintX + #tLevelInfo.text + 1
  g_oGpu.setForeground(C_WHITE)
  g_oGpu.set(nPrintX, nPrintY, sMessage)
end

-------------------------------------------------
-- KERNEL PANIC
-------------------------------------------------

function kernel.panic(sReason, coFaulting)
  raw_computer.beep(1100, 1.3); raw_computer.pullSignal(0.1)
  local sGpuAddress, sScreenAddress
  for sAddr in raw_component.list("gpu") do sGpuAddress = sAddr; break end
  for sAddr in raw_component.list("screen") do sScreenAddress = sAddr; break end
  if not sGpuAddress or not sScreenAddress then
    while true do raw_computer.pullSignal(1) end
  end
  local oGpu = raw_component.proxy(sGpuAddress)
  pcall(oGpu.bind, sScreenAddress)
  local nW, nH = oGpu.getResolution()
  pcall(oGpu.setBackground, 0x0000AA)
  pcall(oGpu.setForeground, 0xFFFFFF)
  pcall(oGpu.fill, 1, 1, nW, nH, " ")
  local y = 1
  local function print_line(sText, sColor)
    if y > nH then return end
    pcall(oGpu.setForeground, sColor or 0xFFFFFF)
    pcall(oGpu.set, 2, y, tostring(sText or ""))
    y = y + 1
  end
  print_line(" ")
  print_line(":( A fatal error has occurred and AxisOS has been shut down.", 0xFFFFFF)
  print_line("   to prevent damage to your system.", 0xFFFFFF)
  y = y + 1
  print_line("[ KERNEL PANIC ]", 0xFF5555)
  y = y + 1
  print_line("Reason: " .. tostring(sReason or "No reason specified."), 0xFFFF55)
  y = y + 1
  print_line("---[ Faulting Context ]---", 0x55FFFF)
  local nFaultingPid = coFaulting and kernel.tPidMap[coFaulting]
  if nFaultingPid then
    local p = kernel.tProcessTable[nFaultingPid]
    print_line(string.format("PID: %d   Parent: %d   Ring: %d   Status: %s",
               nFaultingPid, p.parent or -1, p.ring or -1, p.status or "UNKNOWN"), 0xFFFFFF)
    local sPath = "N/A"
    if p.env and p.env.arg and type(p.env.arg) == "table" then sPath = p.env.arg[0] or "N/A" end
    print_line("Image Path: " .. sPath, 0xAAAAAA)
    -- sMLTR: show synapse token in panic
    print_line("Synapse Token: " .. tostring(p.synapseToken or "N/A"), 0xAAAAAA)
    y = y + 1
    print_line("Stack Trace:", 0x55FFFF)
    local sTraceback = debug.traceback(coFaulting)
    for line in sTraceback:gmatch("[^\r\n]+") do
      line = line:gsub("kernel.lua", "kernel"):gsub("pipeline_manager.lua", "pm"):gsub("dkms.lua", "dkms")
      print_line("  " .. line, 0xAAAAAA)
      if y > 22 then print_line("  ... (trace truncated)", 0xAAAAAA); break end
    end
  else
    print_line("Panic occurred outside of a managed process (e.g., during boot).", 0xFFFF55)
  end
  y = y + 1
  print_line("---[ System State ]---", 0x55FFFF)
  print_line(string.format("Uptime: %.4f seconds", raw_computer.uptime()), 0xFFFFFF)
  print_line(string.format("Total Processes: %d", kernel.nNextPid - 1), 0xFFFFFF)
  y = y + 1
  print_line("Process Table (Top 10):", 0x55FFFF)
  print_line(string.format("%-5s %-7s %-12s %-6s %-s", "PID", "PARENT", "STATUS", "RING", "IMAGE"), 0xAAAAAA)
  local nCount = 0
  for pid, p in pairs(kernel.tProcessTable) do
    if nCount >= 10 then break end
    local sPath = "N/A"
    if p.env and p.env.arg and type(p.env.arg) == "table" then sPath = p.env.arg[0] or "N/A" end
    print_line(string.format("%-5d %-7d %-12s %-6d %-s",
               pid, p.parent or -1, p.status or "??", p.ring or "?", sPath), 0xFFFFFF)
    nCount = nCount + 1
  end
  y = y + 1
  print_line("---[ Component Dump ]---", 0x55FFFF)
  local tComponents = {}
  for addr, ctype in raw_component.list() do table.insert(tComponents, {addr=addr, ctype=ctype}) end
  for i, comp in ipairs(tComponents) do
    if y > nH - 2 then print_line("... (list truncated)", 0xAAAAAA); break end
    print_line(string.format("[%s...] %s", comp.addr:sub(1, 13), comp.ctype), 0xFFFFFF)
  end
  pcall(oGpu.setForeground, 0xFFFF55)
  pcall(oGpu.set, 2, nH, "System halted. Please power cycle the machine.")
  while true do raw_computer.pullSignal(1) end
end

------------------------------------------------
-- BOOT MSG
------------------------------------------------

__logger_init()
kprint("info", "AxisOS Xen XKA v0.3 starting...")
kprint("info", "Copyright (C) 2025 AxisOS")
kprint("none", "")

-------------------------------------------------
-- PRIMITIVE BOOTLOADER HELPERS
-------------------------------------------------

local g_oPrimitiveFs = raw_component.proxy(boot_fs_address)

local function primitive_load(sPath)
  local hFile, sReason = g_oPrimitiveFs.open(sPath, "r")
  if not hFile then
    return nil, "primitive_load failed to open: " .. tostring(sReason or "Unknown error")
  end
  local sData = ""
  local sChunk
  repeat
    sChunk = g_oPrimitiveFs.read(hFile, math.huge)
    if sChunk then sData = sData .. sChunk end
  until not sChunk
  g_oPrimitiveFs.close(hFile)
  return sData
end

local function primitive_load_lua(sPath)
  local sCode, sErr = primitive_load(sPath)
  if not sCode then
    kernel.panic("CRITICAL: Failed to load " .. sPath .. ": " .. (sErr or "File not found"))
  end
  local fFunc, sLoadErr = load(sCode, "@" .. sPath, "t", {})
  if not fFunc then
    kernel.panic("CRITICAL: Failed to parse " .. sPath .. ": " .. sLoadErr)
  end
  return fFunc()
end

-------------------------------------------------
-- OBJECT MANAGER BOOT LOAD
-------------------------------------------------

local function __load_ob_manager()
  local sCode, sErr = primitive_load("/lib/ob_manager.lua")
  if not sCode then
    kprint("warn", "Object Manager not found at /lib/ob_manager.lua: " .. tostring(sErr))
    return nil
  end
  -- Provide a minimal sandbox for ob_manager to load in
  local tObEnv = {
    string = string, math = math, os = os,
    pairs = pairs, type = type, tostring = tostring, table = table,
    setmetatable = setmetatable, pcall = pcall, ipairs = ipairs,
    -- Give it access to raw_computer for uptime-based entropy
    raw_computer = raw_computer,
  }
  local fChunk, sLoadErr = load(sCode, "@ob_manager", "t", tObEnv)
  if not fChunk then
    kprint("fail", "Failed to parse ob_manager: " .. tostring(sLoadErr))
    return nil
  end
  local bOk, oResult = pcall(fChunk)
  if bOk and type(oResult) == "table" then
    return oResult
  else
    kprint("fail", "Failed to init ob_manager: " .. tostring(oResult))
    return nil
  end
end

-------------------------------------------------
-- PROCESS & MODULE MANAGEMENT
-------------------------------------------------

function kernel.custom_require(sModulePath, nCallingPid)
  if kernel.tLoadedModules[sModulePath] then
    return kernel.tLoadedModules[sModulePath]
  end
  
  local tPathsToTry = {
    "/lib/" .. sModulePath .. ".lua",
    "/usr/lib/" .. sModulePath .. ".lua",
    "/drivers/" .. sModulePath .. ".lua",
    "/drivers/" .. sModulePath .. ".sys.lua",
    "/system/" .. sModulePath .. ".lua",
    "/system/lib/dk/" .. sModulePath .. ".lua",
    "/sys/security/" .. sModulePath .. ".lua",
  }
  
  local sCode, sErr
  local sFoundPath
  for _, sPath in ipairs(tPathsToTry) do
    sCode, sErr = kernel.syscalls.vfs_read_file(nCallingPid, sPath)
    if sCode then sFoundPath = sPath; break end
  end
  
  if not sCode then return nil, "Module not found: " .. sModulePath end
  
  local tEnv = kernel.tProcessTable[nCallingPid].env
  local fFunc, sLoadErr = load(sCode, "@" .. sFoundPath, "t", tEnv)
  if not fFunc then return nil, "Failed to load module " .. sModulePath .. ": " .. sLoadErr end
  
  local bIsOk, result = pcall(fFunc)
  if not bIsOk then return nil, "Failed to initialize module " .. sModulePath .. ": " .. result end
  
  kernel.tLoadedModules[sModulePath] = result
  return result
end

function kernel.create_sandbox(nPid, nRing)
  local tSandbox = {
    assert = assert,
    error = error,
    ipairs = ipairs,
    next = next,
    pairs = pairs,
    pcall = pcall,
    select = select,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    unpack = unpack,
    _VERSION = _VERSION,
    xpcall = xpcall,
    coroutine = coroutine,
    string = string,
    table = table,
    math = math,
    debug = debug, -- needed for traceback
    
    syscall = function(...)
      return kernel.syscall_dispatch(...)
    end,
    
    require = function(sModulePath)
      local mod, sErr = kernel.custom_require(sModulePath, nPid)
      if not mod then error(sErr, 2) end
      return mod
    end,
    
    print = function(...)
      local tParts = {}
      for i = 1, select("#", ...) do
        tParts[i] = tostring(select(i, ...))
      end
      kernel.syscall_dispatch("vfs_write", 1, table.concat(tParts, "\t") .. "\n")
    end,
  }
  
  -- Safe os table
  local tSafeOs = {}
  for sKey, vValue in pairs(os) do
    if sKey ~= "exit" and sKey ~= "execute" and sKey ~= "remove" and sKey ~= "rename" then
      tSafeOs[sKey] = vValue
    end
  end
  tSandbox.os = tSafeOs

  -- io library (unbuffered stdout/stdin)
  tSandbox.io = {
    write = function(...)
      local tParts = {}
      for i = 1, select("#", ...) do
        tParts[i] = tostring(select(i, ...))
      end
      kernel.syscall_dispatch("vfs_write", 1, table.concat(tParts))
    end,
    read = function()
      local _, _, data = kernel.syscall_dispatch("vfs_read", 0)
      return data
    end,
  }
  
  -- Ring 0 gets god-mode
  if nRing == 0 then
    tSandbox.kernel = kernel
    tSandbox.raw_component = raw_component
    tSandbox.raw_computer = raw_computer
  end
  
  setmetatable(tSandbox, { __index = _G })
  tSandbox._G = tSandbox
  
  return tSandbox
end

function kernel.create_process(sPath, nRing, nParentPid, tPassEnv)
  local nPid = kernel.nNextPid
  kernel.nNextPid = kernel.nNextPid + 1
  
  kprint("info", "Creating process " .. nPid .. " ('" .. sPath .. "') at Ring " .. nRing)
  
  local sCode, sErr = kernel.syscalls.vfs_read_file(0, sPath)
  if not sCode then
    kprint("fail", "Failed to create process: " .. sErr)
    return nil, sErr
  end
  
  local tEnv = kernel.create_sandbox(nPid, nRing)
  if tPassEnv then tEnv.env = tPassEnv end
  
  local fFunc, sLoadErr = load(sCode, "@" .. sPath, "t", tEnv)
  if not fFunc then
    kprint("fail", "SYNTAX ERROR in " .. sPath .. ": " .. tostring(sLoadErr))
    return nil, sLoadErr
  end
  
  local coProcess = coroutine.create(function()
    local bIsOk, sErr = pcall(fFunc)
    if not bIsOk then
      kprint("fail", "!!! KERNEL ALERT: PROCESS " .. nPid .. " CRASHED !!!")
      kprint("fail", "Crash reason: " .. tostring(sErr))
    else
      kprint("info", "Process " .. nPid .. " exited normally.")
    end
    kernel.tProcessTable[nPid].status = "dead"
  end)
  
  -- sMLTR: Generate unique synapse token for this process
  local sSynapseToken = fGenerateSynapseToken()
  
  kernel.tProcessTable[nPid] = {
    co = coProcess,
    status = "ready",
    ring = nRing,
    parent = nParentPid,
    env = tEnv,
    fds = {},
    wait_queue = {},
    run_queue = {},
    uid = (tPassEnv and tPassEnv.UID) or 1000,
    -- sMLTR
    synapseToken = sSynapseToken,
    -- Thread tracking
    threads = {},
  }
  kernel.tPidMap[coProcess] = nPid
  kernel.tRings[nPid] = nRing
  
  -- Object Handle: Initialize per-process handle table
  if g_oObManager then
    g_oObManager.InitProcess(nPid)
    -- Inherit parent's handles (stdin/stdout/stderr aliases)
    if nParentPid and nParentPid > 0 and kernel.tProcessTable[nParentPid] then
      -- child's handles are rebound to child's synapse token
        g_oObManager.InheritHandles(nParentPid, nPid, sSynapseToken)
    end
  end
  
  kprint("dev", "  PID " .. nPid .. " synapse token: " .. sSynapseToken:sub(1, 16) .. "...")
  
  return nPid
end

function kernel.create_thread(fFunc, nParentPid)
  local nPid = kernel.nNextPid
  kernel.nNextPid = kernel.nNextPid + 1
  
  local tParentProcess = kernel.tProcessTable[nParentPid]
  if not tParentProcess then return nil, "Parent died" end
  
  kprint("dev", "Spawning thread " .. nPid .. " for parent " .. nParentPid)
  
  -- Threads share parent's sandbox (globals, env, fds)
  local tSharedEnv = tParentProcess.env
  
  local coThread = coroutine.create(function()
    local bOk, sErr = pcall(fFunc)
    if not bOk then
      kprint("fail", "Thread " .. nPid .. " crashed: " .. tostring(sErr))
    end
    kernel.tProcessTable[nPid].status = "dead"
  end)
  
  -- sMLTR: Thread shares parent's synapse token (same security context)
  local sSynapseToken = tParentProcess.synapseToken
  
  kernel.tProcessTable[nPid] = {
    co = coThread,
    status = "ready",
    ring = tParentProcess.ring,
    parent = nParentPid,
    env = tSharedEnv,
    fds = tParentProcess.fds,
    wait_queue = {},
    run_queue = {},
    uid = tParentProcess.uid,
    synapseToken = sSynapseToken,
    threads = {},
    is_thread = true,
  }
  
  kernel.tPidMap[coThread] = nPid
  kernel.tRings[nPid] = tParentProcess.ring
  
  -- Object Handle: Threads share parent's handle table
  -- They get the SAME synapse token so they can use parent's handles
  if g_oObManager then
    g_oObManager.InitProcess(nPid)
    if nParentPid and nParentPid > 0 and kernel.tProcessTable[nParentPid] then
      g_oObManager.InheritHandles(nParentPid, nPid, sSynapseToken)
    end
  end
  
  -- Track thread in parent
  table.insert(tParentProcess.threads, nPid)
  
  return nPid
end

-------------------------------------------------
-- SYSCALL DISPATCHER
-------------------------------------------------
kernel.syscalls = {}

function kernel.syscall_dispatch(sName, ...)
  local coCurrent = coroutine.running()
  local nPid = kernel.tPidMap[coCurrent]
  
  if not nPid then
    kernel.panic("Untracked coroutine tried to syscall: " .. sName)
  end
  
  g_nCurrentPid = nPid
  local nRing = kernel.tRings[nPid]
  
  -- Check for ring 1 overrides
  local nOverridePid = kernel.tSyscallOverrides[sName]
  if nOverridePid then
    local tProcess = kernel.tProcessTable[nPid]
    tProcess.status = "sleeping"
    tProcess.wait_reason = "syscall"
    
    -- sMLTR: Include the caller's synapse token in the IPC message
    local sSynapseToken = tProcess.synapseToken or "NO_TOKEN"
    
    local bIsOk, sErr = pcall(kernel.syscalls.signal_send, 0, nOverridePid, "syscall", {
      name = sName,
      args = {...},
      sender_pid = nPid,
      synapse_token = sSynapseToken,  -- sMLTR
    })
    
    if not bIsOk then
      tProcess.status = "ready"
      return nil, "Syscall IPC failed: " .. sErr
    end
    
    return coroutine.yield()
  end
  
  local tHandler = kernel.tSyscallTable[sName]
  if not tHandler then
    return nil, "Unknown syscall: " .. sName
  end
  
  -- RING CHECK
  local bIsAllowed = false
  for _, nAllowedRing in ipairs(tHandler.allowed_rings) do
    if nRing == nAllowedRing then bIsAllowed = true; break end
  end
  
  if not bIsAllowed then
    kprint("fail", "Ring violation: PID " .. nPid .. " (Ring " .. nRing .. ") tried to call " .. sName)
    kernel.tProcessTable[nPid].status = "dead"
    return coroutine.yield()
  end

  local tReturns = {pcall(tHandler.func, nPid, ...)}
  local bIsOk = table.remove(tReturns, 1)
  if not bIsOk then return nil, tReturns[1] end
  return table.unpack(tReturns)
end

-------------------------------------------------
-- SYSCALL DEFINITIONS
-------------------------------------------------

-- Kernel (Ring 0)
kernel.tSyscallTable["kernel_panic"] = {
  func = function(nPid, sReason) kernel.panic(sReason) end,
  allowed_rings = {0}
}

kernel.tSyscallTable["kernel_yield"] = {
    func = function() return coroutine.yield() end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["kernel_host_yield"] = {
  func = function() computer.pullSignal(0); return true end,
  allowed_rings = {0, 1} 
}

kernel.tSyscallTable["kernel_register_pipeline"] = {
  func = function(nPid) kernel.nPipelinePid = nPid end,
  allowed_rings = {0, 1}
}

kernel.tSyscallTable["kernel_register_driver"] = {
  func = function(nPid, sComponentType, nHandlerPid)
    if not kernel.tDriverRegistry[sComponentType] then kernel.tDriverRegistry[sComponentType] = {} end
    table.insert(kernel.tDriverRegistry[sComponentType], nHandlerPid)
  end,
  allowed_rings = {1}
}

kernel.tSyscallTable["kernel_map_component"] = {
  func = function(nPid, sAddress, nDriverPid) kernel.tComponentDriverMap[sAddress] = nDriverPid end,
  allowed_rings = {1}
}

kernel.tSyscallTable["kernel_get_root_fs"] = {
  func = function(nPid)
    if kernel.tVfs.sRootUuid and kernel.tVfs.oRootFs then
      return kernel.tVfs.sRootUuid, kernel.tVfs.oRootFs
    else return nil, "Root FS not mounted in kernel" end
  end,
  allowed_rings = {0, 1}
}

kernel.tSyscallTable["kernel_log"] = {
  func = function(nPid, sMessage) kprint("info", tostring(sMessage)); return true end,
  allowed_rings = {0, 1, 2, 3}
}

kernel.tSyscallTable["kernel_get_boot_log"] = {
  func = function(nPid)
    local sLog = table.concat(kernel.tBootLog, "\n")
    kernel.tBootLog = {}
    return sLog
  end,
  allowed_rings = {1, 2}
}

kernel.tSyscallTable["kernel_set_log_mode"] = {
  func = function(nPid, bEnable) g_bLogToScreen = bEnable; return true end,
  allowed_rings = {0, 1}
}

kernel.tSyscallTable["driver_load"] = {
  func = function(nPid, sPath) return nil, "Syscall not handled by PM" end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["syscall_override"] = {
  func = function(nPid, sSyscallName) kernel.tSyscallOverrides[sSyscallName] = nPid; return true end,
  allowed_rings = {1}
}

-- Process Management
kernel.tSyscallTable["process_spawn"] = {
  func = function(nPid, sPath, nRing, tPassEnv)
    local nParentRing = kernel.tRings[nPid]
    if nRing < nParentRing then
      return nil, "Permission denied: cannot spawn higher-privilege process"
    end
    local nNewPid, sErr = kernel.create_process(sPath, nRing, nPid, tPassEnv)
    if not nNewPid then return nil, sErr end
    return nNewPid
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_yield"] = {
  func = function(nPid)
    kernel.tProcessTable[nPid].status = "ready"
    coroutine.yield()
    return true
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_thread"] = {
  func = function(nPid, fFunc)
    if type(fFunc) ~= "function" then return nil, "Argument must be a function" end
    local nThreadPid, sErr = kernel.create_thread(fFunc, nPid)
    return nThreadPid, sErr
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_wait"] = {
  func = function(nPid, nTargetPid)
    if not kernel.tProcessTable[nTargetPid] then return nil, "Invalid PID" end
    if kernel.tProcessTable[nTargetPid].status == "dead" then return true end
    table.insert(kernel.tProcessTable[nTargetPid].wait_queue, nPid)
    kernel.tProcessTable[nPid].status = "sleeping"
    kernel.tProcessTable[nPid].wait_reason = "wait_pid"
    return coroutine.yield()
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_kill"] = {
  func = function(nPid, nTargetPid)
    local tTarget = kernel.tProcessTable[nTargetPid]
    if not tTarget then return nil, "No such process" end
    local nCallerRing = kernel.tRings[nPid]
    if nCallerRing > 1 and tTarget.parent ~= nPid then
       return nil, "Permission denied"
    end
    tTarget.status = "dead"
    -- Also kill all threads of the target
    for _, nTid in ipairs(tTarget.threads or {}) do
      if kernel.tProcessTable[nTid] then
        kernel.tProcessTable[nTid].status = "dead"
      end
    end
    kprint("info", "Process " .. nTargetPid .. " killed by " .. nPid)
    return true
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_status"] = {
  func = function(nPid, nTargetPid)
    local tTarget = kernel.tProcessTable[nTargetPid or nPid]
    if tTarget then return tTarget.status else return nil end
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_list_threads"] = {
  func = function(nPid)
    local tProc = kernel.tProcessTable[nPid]
    if not tProc then return {} end
    local tAlive = {}
    for _, nTid in ipairs(tProc.threads or {}) do
      if kernel.tProcessTable[nTid] and kernel.tProcessTable[nTid].status ~= "dead" then
        table.insert(tAlive, nTid)
      end
    end
    tProc.threads = tAlive
    return tAlive
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_elevate"] = {
  func = function(nPid, nNewRing)
    if kernel.tRings[nPid] == 3 and nNewRing == 2.5 then
      kernel.tRings[nPid] = 2.5
      kernel.tProcessTable[nPid].ring = 2.5
      kernel.tProcessTable[nPid].env = kernel.create_sandbox(nPid, 2.5)
      -- sMLTR: Rotate synapse token on elevation for security
      kernel.tProcessTable[nPid].synapseToken = fGenerateSynapseToken()
      return true
    end
    return nil, "Permission denied"
  end,
  allowed_rings = {3}
}

kernel.tSyscallTable["process_get_ring"] = {
  func = function(nPid) return kernel.tRings[nPid] end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_get_pid"] = {
  func = function(nPid) return nPid end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_get_uid"] = {
  func = function(nPid, nTargetPid)
    local tP = kernel.tProcessTable[nTargetPid or nPid]
    if tP then return tP.uid else return nil end
  end,
  allowed_rings = {0, 1}
}


-- ==========================================
-- OBJECT HANDLE SYSCALLS (Ring 1 — used by PM)
-- ==========================================

kernel.tSyscallTable["ob_create_handle"] = {
  func = function(nPid, nTargetPid, tObjectHeader)
    if not g_oObManager then return nil, "ObManager not loaded" end
    local sToken = g_oObManager.CreateHandle(nTargetPid, tObjectHeader)
    return sToken
  end,
  allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_resolve_handle"] = {
  func = function(nPid, nTargetPid, vHandle)
    if not g_oObManager then return nil end
    return g_oObManager.ReferenceObjectByHandle(nTargetPid, vHandle)
  end,
  allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_close_handle"] = {
  func = function(nPid, nTargetPid, vHandle)
    if not g_oObManager then return false end
    return g_oObManager.CloseHandle(nTargetPid, vHandle)
  end,
  allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_set_alias"] = {
  func = function(nPid, nTargetPid, nAlias, sToken)
    if not g_oObManager then return false end
    return g_oObManager.SetHandleAlias(nTargetPid, nAlias, sToken)
  end,
  allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_init_process"] = {
  func = function(nPid, nTargetPid)
    if not g_oObManager then return false end
    g_oObManager.InitProcess(nTargetPid)
    return true
  end,
  allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_inherit_handles"] = {
  func = function(nPid, nParentPid, nChildPid)
    if not g_oObManager then return false end
    g_oObManager.InheritHandles(nParentPid, nChildPid)
    return true
  end,
  allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_list_handles"] = {
  func = function(nPid, nTargetPid)
    if not g_oObManager then return {} end
    return g_oObManager.ListHandles(nTargetPid or nPid)
  end,
  allowed_rings = {0, 1}
}


-- ==========================================
-- sMLTR SYSCALLS
-- ==========================================

-- Get own synapse token
kernel.tSyscallTable["synapse_get_token"] = {
  func = function(nPid)
    local tProc = kernel.tProcessTable[nPid]
    return tProc and tProc.synapseToken or nil
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Validate a target process's synapse token
kernel.tSyscallTable["synapse_validate"] = {
  func = function(nPid, nTargetPid, sToken)
    local tTarget = kernel.tProcessTable[nTargetPid]
    if tTarget and tTarget.synapseToken == sToken then return true end
    return false
  end,
  allowed_rings = {0, 1, 2}
}

-- Rotate a process's synapse token (security measure)
-- After rotation, all old handles bound to the old token become invalid.
kernel.tSyscallTable["synapse_rotate"] = {
  func = function(nPid, nTargetPid)
    local nTarget = nTargetPid or nPid
    local tTarget = kernel.tProcessTable[nTarget]
    if not tTarget then return nil, "No such process" end
    local sOldToken = tTarget.synapseToken
    tTarget.synapseToken = fGenerateSynapseToken()
    kprint("dev", "sMLTR: Rotated token for PID " .. nTarget .. " (old: " .. sOldToken:sub(1,12) .. "...)")
    return tTarget.synapseToken
  end,
  allowed_rings = {0, 1}
}


-- Raw Component (Privileged)
kernel.tSyscallTable["raw_component_list"] = {
  func = function(nPid, sFilter)
    local bIsOk, tList = pcall(function()
        local tTempList = {}
        for sAddr, sCtype in raw_component.list(sFilter) do
          tTempList[sAddr] = sCtype
        end
        return tTempList
    end)
    if bIsOk then return true, tList else return false, tList end
  end,
  allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["raw_component_invoke"] = {
  func = function(nPid, sAddress, sMethod, ...)
    local oProxy = raw_component.proxy(sAddress)
    if not oProxy then return nil, "Invalid component" end
    return pcall(oProxy[sMethod], ...)
  end,
  allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["raw_component_proxy"] = {
  func = function(nPid, sAddress)
    local bIsOk, oProxy = pcall(raw_component.proxy, sAddress)
    if bIsOk then return oProxy else return nil, "Invalid component address" end
  end,
  allowed_rings = {0, 1, 2}
}

-- IPC
kernel.syscalls.signal_send = function(nPid, nTargetPid, ...)
  local tTarget = kernel.tProcessTable[nTargetPid]
  if not tTarget then return nil, "Invalid PID" end
  
  local tSignal = {nPid, ...}
  
  if tTarget.status == "sleeping" and (tTarget.wait_reason == "signal" or tTarget.wait_reason == "syscall") then
    tTarget.status = "ready"
    if tTarget.wait_reason == "syscall" then
        tTarget.resume_args = {tSignal[3], table.unpack(tSignal, 4)}
    else
        tTarget.resume_args = tSignal
    end
  else
    if not tTarget.signal_queue then tTarget.signal_queue = {} end
    table.insert(tTarget.signal_queue, tSignal)
  end
  
  return true
end

kernel.tSyscallTable["signal_send"] = {
  func = kernel.syscalls.signal_send,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["signal_pull"] = {
  func = function(nPid, nTimeout)
    local tProcess = kernel.tProcessTable[nPid]
    if tProcess.signal_queue and #tProcess.signal_queue > 0 then
      return true, table.unpack(table.remove(tProcess.signal_queue, 1))
    end
    tProcess.status = "sleeping"
    tProcess.wait_reason = "signal"
    return coroutine.yield()
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

-- VFS (placeholders, overridden by PM)
kernel.syscalls.vfs_read_file = function(nPid, sPath)
  return primitive_load(sPath)
end

kernel.tSyscallTable["vfs_read_file"] = {
    func = kernel.syscalls.vfs_read_file,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["vfs_open"]  = {
    func = function(nPid, sPath, sMode) return pcall(g_oPrimitiveFs.open, sPath, sMode) end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_read"]  = {
    func = function(nPid, hHandle, nCount) return pcall(g_oPrimitiveFs.read, hHandle, nCount or math.huge) end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_write"] = {
    func = function(nPid, hHandle, sData) return pcall(g_oPrimitiveFs.write, hHandle, sData) end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_close"] = {
    func = function(nPid, hHandle) return pcall(g_oPrimitiveFs.close, hHandle) end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_chmod"] = {
  func = function() return nil, "Not implemented in kernel" end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_device_control"] = {
  func = function() return nil, "Not implemented in kernel" end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_list"]  = {
    func = function(nPid, sPath)
        local bOk, tListOrErr = pcall(g_oPrimitiveFs.list, sPath)
        if bOk then return true, tListOrErr else return false, tListOrErr end
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Computer
kernel.tSyscallTable["computer_shutdown"] = {
  func = function() raw_computer.shutdown() end,
  allowed_rings = {0, 1, 2, 2.5}
}
kernel.tSyscallTable["computer_reboot"] = {
  func = function() raw_computer.shutdown(true) end,
  allowed_rings = {0, 1, 2, 2.5}
}

-------------------------------------------------
-- KERNEL INITIALIZATION
-------------------------------------------------
kprint("info", "Kernel entering initialization sequence (Ring 0).")
kprint("dev", "Initializing syscall dispatcher table...")

-- 0. Load Object Manager
g_oObManager = __load_ob_manager()
if g_oObManager then
  kprint("ok", "Object Manager loaded. Handle tables active.")
else
  kprint("warn", "Object Manager not available. Running without handle security.")
end

kprint("ok", "sMLTR (Synapse Message Layer Token Randomization) active.")

-- 1. Mount Root FS
kprint("info", "Reading fstab from /etc/fstab.lua...")
local tFstab = primitive_load_lua("/etc/fstab.lua")
if not tFstab then
    kprint("fail", "Failed to load /etc/fstab.lua")
  kernel.panic("fstab is missing or corrupt.")
end

local tRootEntry = tFstab[1]
if tRootEntry.type ~= "rootfs" then
  kprint("fail", "fstab[1] is not of type 'rootfs'.")
  kernel.panic("Invalid fstab configuration.")
end
kernel.tVfs.sRootUuid = tRootEntry.uuid
kernel.tVfs.oRootFs = raw_component.proxy(tRootEntry.uuid)
kernel.tVfs.tMounts["/"] = {
  type = "rootfs",
  proxy = kernel.tVfs.oRootFs,
  options = tRootEntry.options,
}
kprint("ok", "Mounted root filesystem on", kernel.tVfs.sRootUuid:sub(1,13).."...")

-- 2. Create PID 0 (Kernel Process)
local nKernelPid = kernel.nNextPid
kernel.nNextPid = kernel.nNextPid + 1
local coKernel = coroutine.running()
local tKernelEnv = kernel.create_sandbox(nKernelPid, 0)
kernel.tProcessTable[nKernelPid] = {
  co = coKernel, status = "running", ring = 0,
  parent = 0, env = tKernelEnv, fds = {},
  synapseToken = fGenerateSynapseToken(),
  threads = {},
}
kernel.tPidMap[coKernel] = nKernelPid
kernel.tRings[nKernelPid] = 0
g_nCurrentPid = nKernelPid
_G = tKernelEnv

if g_oObManager then g_oObManager.InitProcess(nKernelPid) end

kprint("ok", "Kernel process registered as PID", nKernelPid)

-- 3. Load Ring 1 Pipeline Manager
kprint("info", "Starting Ring 1 services...")
local tPmEnv = {
   SAFE_MODE = (tBootArgs.safemode == "Enabled"),
   INIT_PATH = tBootArgs.init or "/bin/init.lua"
}

local nPipelinePid, sErr = kernel.create_process("/lib/pipeline_manager.lua", 1, nKernelPid, tPmEnv)

if not nPipelinePid then
  kprint("fail", "Failed to start Ring 1 Pipeline Manager:", sErr)
  kernel.panic("Critical service failure: pipeline_manager")
end
kernel.nPipelinePid = nPipelinePid
kprint("ok", "Ring 1 Pipeline Manager started as PID", nPipelinePid)

-------------------------------------------------
-- MAIN KERNEL EVENT LOOP
-------------------------------------------------
kprint("info", "Handing off control to scheduler...")
kprint("ok", "Entering main event loop. Kernel is now running.")
kprint("none", "")

table.insert(kernel.tProcessTable[nPipelinePid].run_queue, "start")

while true do
  local nWorkDone = 0
  
  -- 1. Run all "ready" processes
  for nPid, tProcess in pairs(kernel.tProcessTable) do
    if tProcess.status == "ready" then
      nWorkDone = nWorkDone + 1
      g_nCurrentPid = nPid
      tProcess.status = "running"
      
      local tResumeParams = tProcess.resume_args
      tProcess.resume_args = nil
      
      local bIsOk, sErrOrSignalName
      if tResumeParams then
        bIsOk, sErrOrSignalName = coroutine.resume(tProcess.co, true, table.unpack(tResumeParams))
      else
        bIsOk, sErrOrSignalName = coroutine.resume(tProcess.co)
      end
      
      g_nCurrentPid = nKernelPid 
      
      if not bIsOk then
        tProcess.status = "dead"
        kernel.panic(tostring(sErrOrSignalName), tProcess.co)
      end
      
      if coroutine.status(tProcess.co) == "dead" then
        if tProcess.status ~= "dead" then
          kprint("info", "Process " .. nPid .. " exited normally.")
          tProcess.status = "dead"
        end
      end
      
      -- Wake up waiters and clean up dead processes
      if tProcess.status == "dead" then
        -- Object Handle: Destroy process handle table
        if g_oObManager then
          g_oObManager.DestroyProcess(nPid)
        end
        
        for _, nWaiterPid in ipairs(tProcess.wait_queue or {}) do
          local tWaiter = kernel.tProcessTable[nWaiterPid]
          if tWaiter and tWaiter.status == "sleeping" and tWaiter.wait_reason == "wait_pid" then
            tWaiter.status = "ready"
            tWaiter.resume_args = {true}
            nWorkDone = nWorkDone + 1
          end
        end
        
        -- Kill orphaned threads
        for _, nTid in ipairs(tProcess.threads or {}) do
          if kernel.tProcessTable[nTid] and kernel.tProcessTable[nTid].status ~= "dead" then
            kernel.tProcessTable[nTid].status = "dead"
            if g_oObManager then g_oObManager.DestroyProcess(nTid) end
          end
        end
      end
    end
  end
  
  -- 2. Pull external events
  local nTimeout = (nWorkDone > 0) and 0 or 0.05
  local sEventName, p1, p2, p3, p4, p5 = computer.pullSignal(nTimeout)
  
  if sEventName then
    pcall(kernel.syscalls.signal_send, nKernelPid, kernel.nPipelinePid, "os_event", sEventName, p1, p2, p3, p4, p5)
  end
end