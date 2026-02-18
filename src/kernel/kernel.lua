--
-- /kernel.lua
-- AxisOS Xen XKA v0.32-alpha1
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

local g_bAxfsRoot = false
local g_oAxfsVol  = nil

local g_oPreempt = nil          -- loaded from /lib/preempt.lua at boot
local g_oIpc = nil  -- Kernel IPC subsystem

local g_tSchedStats = {
    nTotalResumes      = 0,
    nPreemptions       = 0,
    nWatchdogWarnings  = 0,
    nWatchdogKills     = 0,
    nMaxSliceMs        = 0,
}

local WATCHDOG_WARN_THRESHOLD = 2.0   -- seconds — warn if a single resume exceeds this
local WATCHDOG_KILL_STRIKES   = 3     -- kill after this many warnings

-- Object Manager (loaded at boot from /lib/ob_manager.lua)
local g_oObManager = nil
local g_oRegistry = nil

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

local function rawtostring(v)
    local t = type(v)
    if t == "string"  then return v end
    if t == "number"  then return tostring(v) end
    if t == "boolean" then return v and "true" or "false" end
    if t == "nil"     then return "nil" end
    local sAddr = "?"
    pcall(function() sAddr = string.format("%p", v) end)
    return t .. ": " .. sAddr
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
do
    local sMT = getmetatable("")
    if sMT then
        sMT.__metatable = "string"   -- locks the metatable
    end
end

kprint("info", "AxisOS Xen XKA v0.32-alpha1 starting...")
kprint("info", "Copyright (C) 2025 AxisOS")
kprint("none", "")

-------------------------------------------------
-- PRIMITIVE BOOTLOADER HELPERS
-------------------------------------------------

-- =============================================
-- ROOT FILESYSTEM BOOTSTRAP
-- Detects AXFS boot or falls back to managed FS
-- =============================================

local g_oPrimitiveFs

if _G.boot_fs_type == "axfs" then
  -- Booted from AXFS — create minimal volume reader
  -- Load bpack inline (can't require yet)
  local function r16(s,o) return s:byte(o)*256+s:byte(o+1) end
  local function r32(s,o) return s:byte(o)*16777216+s:byte(o+1)*65536+s:byte(o+2)*256+s:byte(o+3) end
  local function rstr(s,o,n) local r=s:sub(o,o+n-1); local z=r:find("\0",1,true); return z and r:sub(1,z-1) or r end

  local oDrv = raw_component.proxy(_G.boot_drive_addr)
  local nPOff = _G.boot_part_offset
  local ss = oDrv.getSectorSize()

  local function prs(n) return oDrv.readSector(nPOff + n + 1) end

  local sb = prs(0)
  local nDS = r16(sb, 20)
  local ips = math.floor(ss / 64)

  local function ri(n)
    local sec = 3+math.floor(n/ips); local off = (n%ips)*64
    local sd = prs(sec); if not sd then return nil end
    local o = off+1
    local t = {iType=r16(sd,o), size=r32(sd,o+8), nBlk=r16(sd,o+22), dir={}, ind=r16(sd,o+44)}
    for i=1,10 do t.dir[i]=r16(sd,o+24+(i-1)*2) end; return t
  end
  local function rb(n) return prs(nDS+n) end
  local function blks(t)
    local r={}
    for i=1,math.min(10,t.nBlk) do if t.dir[i] and t.dir[i]>0 then r[#r+1]=t.dir[i] end end
    if t.nBlk>10 and t.ind>0 then
      local si=rb(t.ind); if si then
        for i=1,math.floor(ss/2) do local p2=r16(si,(i-1)*2+1); if p2>0 then r[#r+1]=p2 end end
      end
    end; return r
  end
  local function dfind(di,nm)
    local dpb=math.floor(ss/32)
    for _,bn in ipairs(blks(di)) do
      local sd=rb(bn); if sd then
        for i=0,dpb-1 do local o=i*32+1; local ino=r16(sd,o)
          if ino>0 then local nl=sd:byte(o+3); if sd:sub(o+4,o+3+nl)==nm then return ino end end
        end
      end
    end
  end
  local function resolve(p)
    local c=1; for seg in p:gmatch("[^/]+") do
      local t=ri(c); if not t or t.iType~=2 then return nil end
      c=dfind(t,seg); if not c then return nil end
    end; return c
  end
  local function readfile(p)
    local n=resolve(p); if not n then return nil end
    local t=ri(n); if not t or t.iType~=1 then return nil end
    local ch={}; local rem=t.size
    for _,bn in ipairs(blks(t)) do
      local sd=rb(bn); if sd then ch[#ch+1]=sd:sub(1,math.min(rem,ss)); rem=rem-ss end
      if rem<=0 then break end
    end; return table.concat(ch)
  end

  -- Now load axfs_core + axfs_proxy properly
  local sAxCode = readfile("/lib/axfs_core.lua")
  local sBpCode = readfile("/lib/bpack.lua")
  local sPxCode = readfile("/lib/axfs_proxy.lua")

  if sAxCode and sBpCode and sPxCode then
    -- Load bpack
    local tBpEnv = {string=string, math=math, table=table}
    local fBp = load(sBpCode, "@bpack", "t", tBpEnv)
    local oBpack = fBp()

    -- Load axfs_core with bpack available
    local tAxEnv = {
      string=string, math=math, table=table, os=os, type=type,
      tostring=tostring, pairs=pairs, ipairs=ipairs, setmetatable=setmetatable,
      require=function(m)
        if m == "bpack" then return oBpack end
        error("Cannot require '"..m.."' during AXFS boot")
      end,
    }
    local fAx = load(sAxCode, "@axfs_core", "t", tAxEnv)
    local oAXFS = fAx()

    -- Load proxy module
    local tPxEnv = {
      string=string, math=math, table=table, tostring=tostring,
      type=type, pairs=pairs, ipairs=ipairs,
      require=function(m)
        if m == "axfs_core" then return oAXFS end
        if m == "bpack" then return oBpack end
      end,
    }
    local fPx = load(sPxCode, "@axfs_proxy", "t", tPxEnv)
    local oProxy = fPx()

    -- Create proper AXFS volume
    local tDisk = oAXFS.wrapDrive(oDrv, nPOff, _G.boot_part_size)
    local vol, vErr = oAXFS.mount(tDisk)

    if vol then
      g_oAxfsVol = vol
      g_bAxfsRoot = true
      g_oPrimitiveFs = oProxy.createProxy(vol, "root")
      __gpu_dprint("AXFS root mounted (" .. vol.su.label .. ")")
    else
      kernel.panic("Failed to mount AXFS root: " .. tostring(vErr))
    end
  else
    kernel.panic("AXFS boot: missing core libraries on disk")
  end
else
  -- Standard managed FS boot
  g_oPrimitiveFs = raw_component.proxy(boot_fs_address)
end

local function primitive_load(sPath)
  local hFile, sReason = g_oPrimitiveFs.open(sPath, "r")
  if not hFile then
    return nil, "primitive_load failed to open: " .. tostring(sReason or "Unknown error")
  end
  local tChunks = {}
  while true do
    local sChunk = g_oPrimitiveFs.read(hFile, math.huge)
    if not sChunk then break end
    tChunks[#tChunks + 1] = sChunk
  end
  g_oPrimitiveFs.close(hFile)
  local sData = table.concat(tChunks)
  if #sData == 0 then
    return nil, "primitive_load: empty file: " .. sPath
  end
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

local function __load_registry()
  local sCode, sErr = primitive_load("/lib/registry.lua")
  if not sCode then
    kprint("warn", "Registry not found at /lib/registry.lua: " .. tostring(sErr))
    return nil
  end
  local tRegEnv = {
    string = string, math = math, os = os,
    pairs = pairs, type = type, tostring = tostring, table = table,
    setmetatable = setmetatable, pcall = pcall, ipairs = ipairs,
    raw_computer = raw_computer,
  }
  local fChunk, sLoadErr = load(sCode, "@registry", "t", tRegEnv)
  if not fChunk then
    kprint("fail", "Failed to parse registry: " .. tostring(sLoadErr))
    return nil
  end
  local bOk, oResult = pcall(fChunk)
  if bOk and type(oResult) == "table" then
    return oResult
  else
    kprint("fail", "Failed to init registry: " .. tostring(oResult))
    return nil
  end
end

local function __load_preempt()
    local sCode, sErr = primitive_load("/lib/preempt.lua")
    if not sCode then
        kprint("warn", "Preempt module not found at /lib/preempt.lua: " .. tostring(sErr))
        return nil
    end
    local tEnv = {
        string = string, math = math, table = table,
        pairs = pairs, ipairs = ipairs, type = type,
        tostring = tostring, tonumber = tonumber,
    }
    local fChunk, sLoadErr = load(sCode, "@preempt", "t", tEnv)
    if not fChunk then
        kprint("fail", "Failed to parse preempt module: " .. tostring(sLoadErr))
        return nil
    end
    local bOk, oResult = pcall(fChunk)
    if bOk and type(oResult) == "table" then
        return oResult
    else
        kprint("fail", "Failed to init preempt module: " .. tostring(oResult))
        return nil
    end
end

local function __load_ke_ipc()
    local sCode, sErr = primitive_load("/lib/ke_ipc.lua")
    if not sCode then
        kprint("warn", "ke_ipc not found: " .. tostring(sErr))
        return nil
    end
    local tEnv = {
        string = string, math = math, os = os, table = table,
        pairs = pairs, ipairs = ipairs, type = type,
        tostring = tostring, tonumber = tonumber,
        pcall = pcall, select = select, next = next, error = error,
        setmetatable = setmetatable, coroutine = coroutine,
        raw_computer = raw_computer,
    }
    local fChunk, sLoadErr = load(sCode, "@ke_ipc", "t", tEnv)
    if not fChunk then
        kprint("fail", "Failed to parse ke_ipc: " .. tostring(sLoadErr))
        return nil
    end
    local bOk, oResult = pcall(fChunk)
    if bOk and type(oResult) == "table" then return oResult
    else kprint("fail", "Failed to init ke_ipc: " .. tostring(oResult)); return nil end
end

-------------------------------------------------
-- PROCESS & MODULE MANAGEMENT
-------------------------------------------------

function kernel.custom_require(sModulePath, nCallingPid)
    local tProc = kernel.tProcessTable[nCallingPid]
    if not tProc then return nil, "No such process" end
    
    -- Per-process cache
    if not tProc._moduleCache then tProc._moduleCache = {} end
    if tProc._moduleCache[sModulePath] then
        return tProc._moduleCache[sModulePath]
    end
    
    -- Load from global cache or disk
    if not kernel.tLoadedModules[sModulePath] then
        local tPathsToTry = {
            "/lib/" .. sModulePath .. ".lua",
            "/usr/lib/" .. sModulePath .. ".lua",
            "/drivers/" .. sModulePath .. ".lua",
            "/drivers/" .. sModulePath .. ".sys.lua",
            "/system/" .. sModulePath .. ".lua",
            "/system/lib/dk/" .. sModulePath .. ".lua",
            "/sys/security/" .. sModulePath .. ".lua",
        }
        local sCode, sFoundPath
        for _, sPath in ipairs(tPathsToTry) do
            sCode = kernel.syscalls.vfs_read_file(nCallingPid, sPath)
            if sCode then sFoundPath = sPath; break end
        end
        if not sCode then return nil, "Module not found: " .. sModulePath end
        
        local fFunc, sLoadErr = load(sCode, "@" .. sFoundPath, "t", tProc.env)
        if not fFunc then
            return nil, "Failed to load module " .. sModulePath .. ": " .. sLoadErr
        end
        local bOk, result = pcall(fFunc)
        if not bOk then
            return nil, "Failed to init module " .. sModulePath .. ": " .. result
        end
        kernel.tLoadedModules[sModulePath] = result
    end
    
    -- Give this process its own copy if it's a table
    local cached = kernel.tLoadedModules[sModulePath]
    if type(cached) == "table" then
        local tCopy = {}
        for k, v in pairs(cached) do tCopy[k] = v end
        tProc._moduleCache[sModulePath] = tCopy
        return tCopy
    end
    tProc._moduleCache[sModulePath] = cached
    return cached
end

-- ANSI escape code stripper for NO_COLOR support
local function fStripAnsi(s)
    return s:gsub("\27%[[%d;]*[a-zA-Z]", "")
end


local function shallowCopy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

function kernel.create_sandbox(nPid, nRing)
  -- =========================================================
  -- THREE-LAYER PROXY SANDBOX
  --
  -- The sandbox table itself is ALWAYS EMPTY.  Every global
  -- read goes through __index, every global write through
  -- __newindex.  This is possible because:
  --
  --   a) rawset / rawget are NOT exposed to Ring ≥ 2.5
  --   b) debug library is NOT exposed to Ring ≥ 1
  --   c) __metatable = "protected" blocks getmetatable() and
  --      setmetatable() on the sandbox itself
  --
  -- Three layers (checked in order by __index):
  --
  --   1. tProtected   — kernel-owned, IMMUTABLE from user code
  --                     (__pc, syscall, load, require, print, io,
  --                      standard library names, etc.)
  --
  --   2. tUserGlobals — user-writable globals
  --                     (anything user code assigns goes here;
  --                      writes to protected names are silently
  --                      dropped)
  --
  --   3. tSafeGlobals — read-only platform APIs
  --                     (computer, unicode, bit32; ring-gated)
  -- =========================================================

  local tProtected   = {}   -- immutable kernel symbols
  local tUserGlobals = {}   -- user-writable globals
  local tSandbox     = {}   -- EMPTY proxy — MUST never gain direct keys

  local tSafeComputer = {
    uptime      = computer.uptime,
    freeMemory  = computer.freeMemory,
    totalMemory = computer.totalMemory,
    address     = computer.address,
    tmpAddress  = computer.tmpAddress,
  }

  -- Capture real functions before any user code can replace them.
  -- These upvalues are used inside __pc() and can never be reached
  -- or modified by user code.
  local fRealYield  = coroutine.yield
  local fRealUptime = raw_computer.uptime

  -- =============================================
  -- LAYER 1: Protected kernel symbols
  -- =============================================

  -- Standard Lua (safe subset — NO rawset, rawget, debug)
  tProtected.assert   = assert
  tProtected.error    = error
  tProtected.next     = next
  tProtected.pcall    = pcall
  tProtected.select   = select
  tProtected.tonumber = tonumber
  tProtected.tostring = tostring
  tProtected.type     = type
  tProtected.unpack   = unpack
  tProtected._VERSION = _VERSION
  tProtected.xpcall   = xpcall

  do
      local fRealNext = next
      tProtected.pairs = function(t)
          if type(t) ~= "table" then
              error("bad argument #1 to 'pairs' (table expected, got "
                    .. type(t) .. ")", 2)
          end
          return fRealNext, t, nil
      end
      tProtected.ipairs = function(t)
          if type(t) ~= "table" then
              error("bad argument #1 to 'ipairs' (table expected, got "
                    .. type(t) .. ")", 2)
          end
          local i = 0
          return function()
              i = i + 1
              local v = rawget(t, i)
              if v ~= nil then return i, v end
          end
      end
  end

  -- Library tables
  tProtected.coroutine = coroutine
  do
      local tSafeString = shallowCopy(string)
      tSafeString.dump = nil
      -- Cap string.rep to prevent single-call memory bombs
      local fRealRep = string.rep
      tSafeString.rep = function(s, n, sep)
          local nEst = #s * n + (sep and #sep * (n - 1) or 0)
          if nEst > 1048576 then
              error("string.rep: result too large", 2)
          end
          return fRealRep(s, n, sep)
      end
      tProtected.string = tSafeString
  end
  tProtected.table  = shallowCopy(table)
  tProtected.math   = shallowCopy(math)


  -- Safe os (no exit/execute/remove/rename)
  do
    local tSafeOs = {}
    for k, v in pairs(os) do
      if k ~= "exit" and k ~= "execute"
         and k ~= "remove" and k ~= "rename" then
        tSafeOs[k] = v
      end
    end
    tProtected.os = tSafeOs
  end

  -- setmetatable / getmetatable are safe to expose because the
  -- sandbox has __metatable = "protected", so:
  --   getmetatable(sandbox) → "protected"  (not the real mt)
  --   setmetatable(sandbox, x) → error     (can't override __metatable)
  -- All other tables work normally.
  -- REPLACE THIS:
  tProtected.setmetatable = setmetatable

  -- WITH THIS:
  do
      local fRealSetmt = setmetatable
      tProtected.setmetatable = function(tbl, mt)
          if type(mt) == "table" then
              rawset(mt, "__gc", nil)
          end
          return fRealSetmt(tbl, mt)
      end
  end
  tProtected.getmetatable = getmetatable

  -- ---- Kernel interfaces ----

  tProtected.syscall = function(...)
    return kernel.syscall_dispatch(...)
  end

  tProtected.require = function(sModulePath)
    local mod, sErr = kernel.custom_require(sModulePath, nPid)
    if not mod then error(sErr, 2) end
    return mod
  end

  -- ---- Preemptive checkpoint: __pc() ----

-- Inside create_sandbox, in the tProtected.load definition:

  if g_oPreempt and nRing >= 2.5 then
      local nPcCounter   = 0
      local nPcLastYield = fRealUptime()
      local nPcQuantum   = g_oPreempt.DEFAULT_QUANTUM
      local nPcInterval  = g_oPreempt.CHECK_INTERVAL

      tProtected.__pc = function()
          nPcCounter = nPcCounter + 1
          if nPcCounter < nPcInterval then return end
          nPcCounter = 0
          if g_oIpc then
              local tProc = kernel.tProcessTable[nPid]
              if tProc and tProc.tPendingSignals
                and #tProc.tPendingSignals > 0 then
                  g_oIpc.DeliverSignals(nPid)
                  if tProc.status == "dead" then
                      fRealYield()
                      return
                  end
              end
          end
          local nNow = fRealUptime()
          if nNow - nPcLastYield >= nPcQuantum then
              fRealYield()
              nPcLastYield = fRealUptime()
          end
      end

      local fKernelLoad = load
      tProtected.load = function(sChunk, sName, sMode, _tUserEnv)
          if type(sChunk) == "function" then
              local tParts = {}
              while true do
                  local sPart = sChunk()
                  if not sPart or sPart == "" then break end
                  tParts[#tParts + 1] = sPart
              end
              sChunk = table.concat(tParts)
          end
          if type(sChunk) ~= "string" then
              return nil, "string expected"
          end
          local sInst, nInj = g_oPreempt.instrument(
              sChunk, sName or "[dynamic]")
          if nInj > 0 then sChunk = sInst end
          return fKernelLoad(sChunk, sName, "t", tSandbox)
      end
  else
      tProtected.__pc = function() end
      tProtected.load = load
  end

  -- ---- print / io ----

  tProtected.print = function(...)
    local tP = {}
    for i = 1, select("#", ...) do tP[i] = tostring(select(i, ...)) end
    local sOut = table.concat(tP, "\t") .. "\n"
    local tE = tUserGlobals.env
    if tE and tE.NO_COLOR then sOut = fStripAnsi(sOut) end
    kernel.syscall_dispatch("vfs_write", -11, sOut)
  end

  tProtected.io = {
    write = function(...)
      local tP = {}
      for i = 1, select("#", ...) do tP[i] = tostring(select(i, ...)) end
      local sOut = table.concat(tP)
      local tE = tUserGlobals.env
      if tE and tE.NO_COLOR then sOut = fStripAnsi(sOut) end
      kernel.syscall_dispatch("vfs_write", -11, sOut)
    end,
    read = function()
      local _, _, data = kernel.syscall_dispatch("vfs_read", -10)
      return data
    end,
  }

  -- =============================================
  -- LAYER 3: Safe platform globals (ring-gated)
  -- =============================================

  local tSafeGlobals = {
    computer  = tSafeComputer,
    unicode   = unicode,
    bit32     = bit32,
    checkArg  = checkArg,
    rawequal  = rawequal,
    rawlen    = rawlen,
  }

  if nRing == 0 then
    -- God-mode
    tProtected.kernel        = kernel
    tProtected.raw_component = raw_component
    tProtected.raw_computer  = raw_computer
    tProtected.rawset        = rawset
    tProtected.rawget        = rawget
    tProtected.debug         = debug
    tSafeGlobals.component   = component
  elseif nRing <= 2 then
    -- Drivers / Pipeline Manager need component and raw ops
    tSafeGlobals.component   = component
    tSafeGlobals.rawset      = rawset
    tSafeGlobals.rawget      = rawget
  end
  -- Ring 2.5, 3: NO rawset, rawget, debug, raw_component, raw_computer

  -- =============================================
  -- METATABLE — the core of the protection
  -- =============================================

  -- Fast-lookup set of all protected key names
  local tProtectedSet = {}
  for k in pairs(tProtected) do tProtectedSet[k] = true end
  tProtectedSet["_G"] = true

  setmetatable(tSandbox, {
    __index = function(_, key)
      -- Priority 1: protected kernel symbols (ALWAYS win)
      local pv = tProtected[key]
      if pv ~= nil then return pv end
      -- Priority 2: _G self-reference
      if key == "_G" then return tSandbox end
      -- Priority 3: user-defined globals
      local uv = tUserGlobals[key]
      if uv ~= nil then return uv end
      -- Priority 4: safe platform globals
      return tSafeGlobals[key]
    end,

    __newindex = function(_, key, value)
      -- Writes to protected names are silently dropped.
      -- (Cannot error — instrumented code like `for i=1,10 do __pc();`
      --  must not break if some bizarre edge case tries to assign.)
      if tProtectedSet[key] then return end
      tUserGlobals[key] = value
    end,

    -- Makes getmetatable(sandbox) return "protected" (not the real mt).
    -- Makes setmetatable(sandbox, ...) raise an error.
    __metatable = "protected",
  })

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

  -- =========================================================
  -- PREEMPTIVE SCHEDULING:  instrument source for Ring ≥ 2.5
  -- Injects __pc() calls after every  do / then / repeat / else
  -- so the process yields back to the scheduler periodically.
  -- =========================================================
  if g_oPreempt and nRing >= 2.5 then
      local sInstrumented, nInjections = g_oPreempt.instrument(sCode, sPath)
      if nInjections > 0 then
          kprint("dev", string.format(
              "Preempt: %s → %d yield checkpoints injected", sPath, nInjections))
          sCode = sInstrumented
      else
          kprint("dev", "Preempt: " .. sPath .. " — no loops/branches to instrument")
      end
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
    -- Preemptive scheduler per-process stats
    nCpuTime         = 0,
    nPreemptCount    = 0,
    nLastSlice       = 0,
    nMaxSlice        = 0,
    nWatchdogStrikes = 0,
  }
  kernel.tPidMap[coProcess] = nPid
  kernel.tRings[nPid] = nRing

  -- Initialize IPC per-process state (signals, IRQL, process group)
  if g_oIpc then
      g_oIpc.InitProcessSignals(nPid)
  end

  -- Object Handle: Initialize per-process handle table
  if g_oObManager then
    g_oObManager.ObInitializeProcess(nPid)
    if nParentPid and nParentPid > 0 and kernel.tProcessTable[nParentPid] then
      g_oObManager.ObInheritHandles(nParentPid, nPid, sSynapseToken)
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
  
  local tSharedEnv = tParentProcess.env
  
  local coThread = coroutine.create(function()
    local bOk, sErr = pcall(fFunc)
    if not bOk then
      kprint("fail", "Thread " .. nPid .. " crashed: " .. tostring(sErr))
    end
    kernel.tProcessTable[nPid].status = "dead"
  end)
  
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
    -- Preemptive scheduler stats
    nCpuTime         = 0,
    nPreemptCount    = 0,
    nLastSlice       = 0,
    nMaxSlice        = 0,
    nWatchdogStrikes = 0,
  }
  
  kernel.tPidMap[coThread] = nPid
  kernel.tRings[nPid] = tParentProcess.ring

  if g_oObManager then
    g_oObManager.ObInitializeProcess(nPid)
    if nParentPid and nParentPid > 0 and kernel.tProcessTable[nParentPid] then
      g_oObManager.ObInheritHandles(nParentPid, nPid, sSynapseToken)
    end
  end
  
  -- Initialize IPC per-process state
  if g_oIpc then
      g_oIpc.InitProcessSignals(nPid)
  end
  
  table.insert(tParentProcess.threads, nPid)
  
  return nPid
end
-------------------------------------------------
-- SYSCALL DISPATCHER
-------------------------------------------------
kernel.syscalls = {}

-- =============================================
-- CROSS-BOUNDARY DATA SANITIZATION
-- =============================================

local SANITIZE_MAX_DEPTH = 16
local SANITIZE_MAX_ITEMS = 4096

local function deepSanitize(vValue, nDepth, tCounter)
    nDepth   = nDepth or 0
    tCounter = tCounter or { n = 0 }
    if nDepth > SANITIZE_MAX_DEPTH then return nil end
    if tCounter.n > SANITIZE_MAX_ITEMS then return nil end

    local sType = type(vValue)
    if sType == "string" or sType == "number"
       or sType == "boolean" or sType == "nil" then
        tCounter.n = tCounter.n + 1
        return vValue
    end
    if sType == "table" then
        tCounter.n = tCounter.n + 1
        local tClean = {}
        local key = nil
        while true do
            key = next(vValue, key)
            if key == nil then break end
            if tCounter.n > SANITIZE_MAX_ITEMS then break end
            local vRaw = rawget(vValue, key)
            local vCleanKey = deepSanitize(key, nDepth + 1, tCounter)
            local vCleanVal = deepSanitize(vRaw, nDepth + 1, tCounter)
            if vCleanKey ~= nil then
                tClean[vCleanKey] = vCleanVal
            end
        end
        return tClean
    end
    -- functions, userdata, threads: stripped
    return nil
end

function kernel.syscall_dispatch(sName, ...)
    if type(sName) ~= "string" then
        return nil, "Syscall name must be a string"
    end

    local coCurrent = coroutine.running()
    local nPid = kernel.tPidMap[coCurrent]

    if not nPid then
        kernel.panic("Untracked coroutine tried to syscall: " .. sName)
    end
  
  g_nCurrentPid = nPid
  local nRing = kernel.tRings[nPid]
  
  -- PIPE FAST PATH: intercept vfs_read/vfs_write for kernel pipe handles
  -- This bypasses PM entirely, preventing PM from blocking on pipe I/O
  if g_oIpc and (sName == "vfs_read" or sName == "vfs_write") then
        local vHandle = select(1, ...)
        local bPcallOk, bIsPipe, r1, r2 = pcall(g_oIpc.TryPipeIo, nPid, sName, ...)
        if bPcallOk and bIsPipe then
            return r1, r2
        end
        if not bPcallOk then
            kprint("fail", "[IPC] Pipe fast-path error: " .. tostring(bIsPipe))
        end
    end

  -- Signal delivery point: deliver pending signals on every syscall entry
  if g_oIpc then
        local p = kernel.tProcessTable[nPid]
        if p and p.tPendingSignals and #p.tPendingSignals > 0 then
            local bKilled = g_oIpc.DeliverSignals(nPid)
            if bKilled then
                return nil, "Killed by signal"
            end
        end
  end

  -- Check for ring 1 overrides
-- Find this existing block and REPLACE it:
  local nOverridePid = kernel.tSyscallOverrides[sName]
  if nOverridePid then
      local tProcess = kernel.tProcessTable[nPid]
      tProcess.status = "sleeping"
      tProcess.wait_reason = "syscall"
      
      local sSynapseToken = tProcess.synapseToken or "NO_TOKEN"
      
      -- SANITIZE when Ring >= 2.5 sends to Ring 1 PM
      local tArgs
      if kernel.tRings[nPid] >= 2.5 then
          tArgs = deepSanitize({...})
      else
          tArgs = {...}
      end
      
      if type(sName) ~= "string" then
          tProcess.status = "ready"
          return nil, "Syscall name must be a string"
      end
      
      local bIsOk, sErr = pcall(kernel.syscalls.signal_send, 0, nOverridePid, "syscall", {
          name          = sName,
          args          = tArgs,
          sender_pid    = nPid,
          synapse_token = sSynapseToken,
      })
      
      if not bIsOk then
          tProcess.status = "ready"
          return nil, "Syscall IPC failed: " .. tostring(sErr)
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
  allowed_rings = {0, 1, 2}
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
  func = function(nPid, nTargetPid, nSignal)
    local tTarget = kernel.tProcessTable[nTargetPid]
    if not tTarget then return nil, "No such process" end
    local nCallerRing = kernel.tRings[nPid]
    if nCallerRing > 1 and tTarget.parent ~= nPid then
       return nil, "Permission denied"
    end
    -- Use signal system if available, otherwise direct kill
    if g_oIpc then
        nSignal = nSignal or g_oIpc.SIGTERM
        return g_oIpc.SignalSend(nTargetPid, nSignal)
    end
    tTarget.status = "dead"
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

kernel.tSyscallTable["process_list"] = {
    func = function(nPid)
        local tResult = {}
        for nProcPid, tProc in pairs(kernel.tProcessTable) do
            if tProc.status ~= "dead" then
                local sImage = "?"
                if tProc.env and tProc.env.env and tProc.env.env.arg then
                    sImage = tProc.env.env.arg[0] or "?"
                end
                table.insert(tResult, {
                    pid    = nProcPid,
                    parent = tProc.parent or 0,
                    ring   = tProc.ring or -1,
                    status = tProc.status or "?",
                    uid    = tProc.uid or -1,
                    image  = sImage,
                })
            end
        end
        table.sort(tResult, function(a, b) return a.pid < b.pid end)
        return tResult
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

kernel.tSyscallTable["ob_create_object"] = {
    func = function(nPid, sType, tBody)
        if not g_oObManager then return nil, "ObManager not loaded" end
        return g_oObManager.ObCreateObject(sType, tBody)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_reference_object"] = {
    func = function(nPid, pObj)
        if g_oObManager and pObj then g_oObManager.ObReferenceObject(pObj) end
        return true
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_dereference_object"] = {
    func = function(nPid, pObj)
        if g_oObManager and pObj then g_oObManager.ObDereferenceObject(pObj) end
        return true
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_insert_object"] = {
    func = function(nPid, pObj, sPath)
        if not g_oObManager then return nil end
        return g_oObManager.ObInsertObject(pObj, sPath)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_lookup_object"] = {
    func = function(nPid, sPath)
        if not g_oObManager then return nil end
        return g_oObManager.ObLookupObject(sPath)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_delete_object"] = {
    func = function(nPid, sPath)
        if not g_oObManager then return nil end
        return g_oObManager.ObDeleteObject(sPath)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_create_symlink"] = {
    func = function(nPid, sLink, sTarget)
        if not g_oObManager then return nil end
        return g_oObManager.ObCreateSymbolicLink(sLink, sTarget)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_delete_symlink"] = {
    func = function(nPid, sPath)
        if not g_oObManager then return nil end
        return g_oObManager.ObDeleteSymbolicLink(sPath)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_create_handle"] = {
    func = function(nPid, nTargetPid, pObj, nAccess, sSynapseToken, bInheritable)
        if not g_oObManager then return nil end
        return g_oObManager.ObCreateHandle(nTargetPid, pObj, nAccess, sSynapseToken, bInheritable)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_close_handle"] = {
    func = function(nPid, nTargetPid, vHandle)
        if not g_oObManager then return false end
        return g_oObManager.ObCloseHandle(nTargetPid, vHandle)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_reference_by_handle"] = {
    func = function(nPid, nTargetPid, vHandle, nDesiredAccess, sSynapseToken)
        if not g_oObManager then return nil end
        return g_oObManager.ObReferenceObjectByHandle(nTargetPid, vHandle, nDesiredAccess, sSynapseToken)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_set_standard_handle"] = {
    func = function(nPid, nTargetPid, nIndex, sToken)
        if not g_oObManager then return false end
        -- Security: Ring 3+ can only modify their OWN standard handles
        if kernel.tRings[nPid] >= 3 and nTargetPid ~= nPid then
            return nil, "Permission denied: can only set own standard handles"
        end
        return g_oObManager.ObSetStandardHandle(nTargetPid, nIndex, sToken)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["ob_get_standard_handle"] = {
    func = function(nPid, nTargetPid, nIndex)
        if not g_oObManager then return nil end
        -- Security: Ring 3+ can only query their OWN standard handles
        if kernel.tRings[nPid] >= 3 and nTargetPid ~= nPid then
            return nil, "Permission denied"
        end
        return g_oObManager.ObGetStandardHandle(nTargetPid, nIndex)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["ob_init_process"] = {
    func = function(nPid, nTargetPid)
        if not g_oObManager then return false end
        g_oObManager.ObInitializeProcess(nTargetPid)
        return true
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_destroy_process"] = {
    func = function(nPid, nTargetPid)
        if not g_oObManager then return false end
        g_oObManager.ObObDestroyProcess(nTargetPid)
        return true
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_inherit_handles"] = {
    func = function(nPid, nParentPid, nChildPid, sChildToken)
        if not g_oObManager then return false end
        g_oObManager.ObInheritHandles(nParentPid, nChildPid, sChildToken)
        return true
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_duplicate_handle"] = {
    func = function(nPid, nSrcPid, sSrcToken, nDstPid, nAccess, sSynToken)
        if not g_oObManager then return nil end
        return g_oObManager.ObDuplicateHandle(nSrcPid, sSrcToken, nDstPid, nAccess, sSynToken)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_list_handles"] = {
    func = function(nPid, nTargetPid)
        if not g_oObManager then return {} end
        return g_oObManager.ObListHandles(nTargetPid or nPid)
    end,
    allowed_rings = {0, 1}
}

kernel.tSyscallTable["ob_dump_directory"] = {
    func = function(nPid)
        if not g_oObManager then return {} end
        return g_oObManager.ObDumpDirectory()
    end,
    allowed_rings = {0, 1}
}

-- ==========================================
-- REGISTRY SYSCALLS (@VT)
-- ==========================================

kernel.tSyscallTable["reg_create_key"] = {
    func = function(nPid, sPath)
        if not g_oRegistry then return false, "Registry not loaded" end
        return g_oRegistry.CreateKey(sPath)
    end,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["reg_delete_key"] = {
    func = function(nPid, sPath)
        if not g_oRegistry then return false end
        -- protect root hives
        if sPath == "@VT" or sPath == "@VT\\DEV" or sPath == "@VT\\DRV" or sPath == "@VT\\SYS" then
            return false, "Cannot delete root hive"
        end
        return g_oRegistry.DeleteKey(sPath)
    end,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["reg_key_exists"] = {
    func = function(nPid, sPath)
        if not g_oRegistry then return false end
        return g_oRegistry.KeyExists(sPath)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["reg_set_value"] = {
    func = function(nPid, sPath, sName, vValue, sType)
        if not g_oRegistry then return false end
        return g_oRegistry.SetValue(sPath, sName, vValue, sType)
    end,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["reg_get_value"] = {
    func = function(nPid, sPath, sName)
        if not g_oRegistry then return nil end
        return g_oRegistry.GetValue(sPath, sName)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["reg_delete_value"] = {
    func = function(nPid, sPath, sName)
        if not g_oRegistry then return false end
        return g_oRegistry.DeleteValue(sPath, sName)
    end,
    allowed_rings = {0, 1, 2}
}

kernel.tSyscallTable["reg_enum_keys"] = {
    func = function(nPid, sPath)
        if not g_oRegistry then return {} end
        return g_oRegistry.EnumKeys(sPath)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["reg_enum_values"] = {
    func = function(nPid, sPath)
        if not g_oRegistry then return {} end
        return g_oRegistry.EnumValues(sPath)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["reg_query_info"] = {
    func = function(nPid, sPath)
        if not g_oRegistry then return nil end
        return g_oRegistry.QueryInfo(sPath)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["reg_dump_tree"] = {
    func = function(nPid, sPath, nMaxDepth)
        if not g_oRegistry then return {} end
        return g_oRegistry.DumpTree(sPath, nMaxDepth)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["reg_alloc_device_id"] = {
    func = function(nPid, sClass)
        if not g_oRegistry then return nil end
        return g_oRegistry.AllocateDeviceId(sClass)
    end,
    allowed_rings = {0, 1, 2}
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

-- ==========================================
-- IPC SYSCALLS
-- ==========================================

-- IRQL
kernel.tSyscallTable["ke_raise_irql"] = {
    func = function(nPid, nLevel)
        if not g_oIpc then return nil end
        return g_oIpc.KeRaiseIrql(nPid, nLevel)
    end, allowed_rings = {0, 1, 2}
}
kernel.tSyscallTable["ke_lower_irql"] = {
    func = function(nPid, nLevel)
        if not g_oIpc then return end
        g_oIpc.KeLowerIrql(nPid, nLevel)
    end, allowed_rings = {0, 1, 2}
}
kernel.tSyscallTable["ke_get_irql"] = {
    func = function(nPid)
        if not g_oIpc then return 0 end
        return g_oIpc.KeGetCurrentIrql(nPid)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Events
kernel.tSyscallTable["ke_create_event"] = {
    func = function(nPid, bManual, bInit)
        if not g_oIpc then return nil end
        return g_oIpc.KeCreateEvent(nPid, bManual, bInit)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_set_event"] = {
    func = function(nPid, sH)
        if not g_oIpc then return nil end
        return g_oIpc.KeSetEvent(nPid, sH)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_reset_event"] = {
    func = function(nPid, sH)
        if not g_oIpc then return nil end
        return g_oIpc.KeResetEvent(nPid, sH)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_pulse_event"] = {
    func = function(nPid, sH)
        if not g_oIpc then return nil end
        return g_oIpc.KePulseEvent(nPid, sH)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Mutexes
kernel.tSyscallTable["ke_create_mutex"] = {
    func = function(nPid, bOwned)
        if not g_oIpc then return nil end
        return g_oIpc.KeCreateMutex(nPid, bOwned)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_release_mutex"] = {
    func = function(nPid, sH)
        if not g_oIpc then return nil end
        return g_oIpc.KeReleaseMutex(nPid, sH)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Semaphores
kernel.tSyscallTable["ke_create_semaphore"] = {
    func = function(nPid, nInit, nMax)
        if not g_oIpc then return nil end
        return g_oIpc.KeCreateSemaphore(nPid, nInit, nMax)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_release_semaphore"] = {
    func = function(nPid, sH, nCount)
        if not g_oIpc then return nil end
        return g_oIpc.KeReleaseSemaphore(nPid, sH, nCount)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Timers
kernel.tSyscallTable["ke_create_timer"] = {
    func = function(nPid)
        if not g_oIpc then return nil end
        return g_oIpc.KeCreateTimer(nPid)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_set_timer"] = {
    func = function(nPid, sH, nDelay, nPeriod)
        if not g_oIpc then return nil end
        return g_oIpc.KeSetTimer(nPid, sH, nDelay, nPeriod)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_cancel_timer"] = {
    func = function(nPid, sH)
        if not g_oIpc then return nil end
        return g_oIpc.KeCancelTimer(nPid, sH)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Pipes
kernel.tSyscallTable["ke_create_pipe"] = {
    func = function(nPid, nBuf)
        if not g_oIpc then return nil end
        return g_oIpc.KeCreatePipe(nPid, nBuf)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_create_named_pipe"] = {
    func = function(nPid, sName, nBuf)
        if not g_oIpc then return nil end
        return g_oIpc.KeCreateNamedPipe(nPid, sName, nBuf)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_connect_named_pipe"] = {
    func = function(nPid, sName)
        if not g_oIpc then return nil end
        return g_oIpc.KeConnectNamedPipe(nPid, sName)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_pipe_write"] = {
    func = function(nPid, sH, sData)
        if not g_oIpc then return nil end
        local pH = g_oObManager.ObReferenceObjectByHandle(
            nPid, sH, 0x0002, kernel.tProcessTable[nPid].synapseToken)
        if not pH or not pH.pBody then return nil, "Invalid pipe handle" end
        return g_oIpc.PipeWrite(nPid, pH.pBody, sData)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_pipe_read"] = {
    func = function(nPid, sH, nCount)
        if not g_oIpc then return nil end
        local pH = g_oObManager.ObReferenceObjectByHandle(
            nPid, sH, 0x0001, kernel.tProcessTable[nPid].synapseToken)
        if not pH or not pH.pBody then return nil, "Invalid pipe handle" end
        return g_oIpc.PipeRead(nPid, pH.pBody, nCount)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_pipe_close"] = {
    func = function(nPid, sH, bIsWrite)
        if not g_oIpc then return nil end
        return g_oIpc.PipeClose(nPid, sH, bIsWrite)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Wait
kernel.tSyscallTable["ke_wait_single"] = {
    func = function(nPid, sH, nTimeout)
        if not g_oIpc then return -1 end
        return g_oIpc.KeWaitSingle(nPid, sH, nTimeout)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_wait_multiple"] = {
    func = function(nPid, tHandles, bAll, nTimeout)
        if not g_oIpc then return -1 end
        return g_oIpc.KeWaitMultiple(nPid, tHandles, bAll, nTimeout)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Shared Memory
kernel.tSyscallTable["ke_create_section"] = {
    func = function(nPid, sName, nSize)
        if not g_oIpc then return nil end
        return g_oIpc.KeCreateSection(nPid, sName, nSize)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_open_section"] = {
    func = function(nPid, sName)
        if not g_oIpc then return nil end
        return g_oIpc.KeOpenSection(nPid, sName)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_map_section"] = {
    func = function(nPid, sH)
        if not g_oIpc then return nil end
        return g_oIpc.KeMapSection(nPid, sH)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Message Queues
kernel.tSyscallTable["ke_create_mqueue"] = {
    func = function(nPid, sName, nMax, nSize)
        if not g_oIpc then return nil end
        return g_oIpc.KeCreateMqueue(nPid, sName, nMax, nSize)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_open_mqueue"] = {
    func = function(nPid, sName)
        if not g_oIpc then return nil end
        return g_oIpc.KeOpenMqueue(nPid, sName)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_mq_send"] = {
    func = function(nPid, sH, sMsg, nPri)
        if not g_oIpc then return nil end
        return g_oIpc.KeMqSend(nPid, sH, sMsg, nPri)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_mq_receive"] = {
    func = function(nPid, sH, nTimeout)
        if not g_oIpc then return nil end
        return g_oIpc.KeMqReceive(nPid, sH, nTimeout)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Signals
kernel.tSyscallTable["ke_signal_send"] = {
    func = function(nPid, nTarget, nSig)
        if not g_oIpc then return nil end
        return g_oIpc.SignalSend(nTarget, nSig)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_signal_handler"] = {
    func = function(nPid, nSig, fHandler)
        if not g_oIpc then return nil end
        return g_oIpc.SignalSetHandler(nPid, nSig, fHandler)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_signal_mask"] = {
    func = function(nPid, tMask)
        if not g_oIpc then return nil end
        return g_oIpc.SignalSetMask(nPid, tMask)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_signal_group"] = {
    func = function(nPid, nPgid, nSig)
        if not g_oIpc then return nil end
        return g_oIpc.SignalSendGroup(nPgid, nSig)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_setpgid"] = {
    func = function(nPid, nTarget, nPgid)
        if not g_oIpc then return nil end
        return g_oIpc.SetProcessGroup(nTarget or nPid, nPgid)
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_getpgid"] = {
    func = function(nPid)
        local p = kernel.tProcessTable[nPid]
        return p and (p.nPgid or nPid) or nil
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["ke_ipc_stats"] = {
    func = function(nPid)
        if not g_oIpc then return nil end
        return g_oIpc.GetStats()
    end, allowed_rings = {0, 1, 2, 2.5, 3}
}

-- ==========================================
-- SCHEDULER DIAGNOSTICS
-- ==========================================

kernel.tSyscallTable["sched_get_stats"] = {
    func = function(nPid)
        local tResult = {
            nTotalResumes     = g_tSchedStats.nTotalResumes,
            nPreemptions      = g_tSchedStats.nPreemptions,
            nWatchdogWarnings = g_tSchedStats.nWatchdogWarnings,
            nWatchdogKills    = g_tSchedStats.nWatchdogKills,
            nMaxSliceMs       = g_tSchedStats.nMaxSliceMs,
        }
        if g_oPreempt then
            local tP = g_oPreempt.getStats()
            tResult.nInstrumentedFiles    = tP.nTotalInstrumented
            tResult.nInjectedCheckpoints  = tP.nTotalInjections
            tResult.nQuantumMs            = tP.nQuantumMs
            tResult.nCheckInterval        = tP.nCheckInterval
        end
        return tResult
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_cpu_stats"] = {
    func = function(nPid, nTargetPid)
        local tTarget = kernel.tProcessTable[nTargetPid or nPid]
        if not tTarget then return nil end
        return {
            nCpuTime         = tTarget.nCpuTime         or 0,
            nPreemptCount    = tTarget.nPreemptCount    or 0,
            nLastSlice       = tTarget.nLastSlice       or 0,
            nMaxSlice        = tTarget.nMaxSlice        or 0,
            nWatchdogStrikes = tTarget.nWatchdogStrikes or 0,
        }
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
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
-- REPLACE the entire kernel.syscalls.signal_send function:
kernel.syscalls.signal_send = function(nPid, nTargetPid, ...)
    local tTarget = kernel.tProcessTable[nTargetPid]
    if not tTarget then return nil, "Invalid PID" end
    
    local nSenderRing = kernel.tRings[nPid] or 3
    local nTargetRing = kernel.tRings[nTargetPid] or 3
    
    -- Sanitize when untrusted → trusted
    local tSignal
    if nSenderRing > nTargetRing or nSenderRing >= 3 then
        tSignal = {nPid}
        local tRawArgs = {...}
        for i = 1, #tRawArgs do
            tSignal[i + 1] = deepSanitize(tRawArgs[i])
        end
    else
        tSignal = {nPid, ...}
    end
    
    if tTarget.status == "sleeping"
       and (tTarget.wait_reason == "signal"
            or tTarget.wait_reason == "syscall") then
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

kernel.tSyscallTable["vfs_delete"] = {
    func = function(nPid, sPath)
        return pcall(g_oPrimitiveFs.remove, sPath)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["vfs_mkdir"] = {
    func = function(nPid, sPath)
        return pcall(g_oPrimitiveFs.makeDirectory, sPath)
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Computer
kernel.tSyscallTable["computer_shutdown"] = {
  func = function()
    if g_oAxfsVol then g_oAxfsVol:flush() end
    raw_computer.shutdown()
  end,
  allowed_rings = {0, 1, 2, 2.5}
}
kernel.tSyscallTable["computer_reboot"] = {
  func = function()
    if g_oAxfsVol then g_oAxfsVol:flush() end
    raw_computer.shutdown(true)
  end,
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
    g_oObManager.ObInitSystem()
    kprint("ok", "Object Manager initialised.  Namespace: \\, \\Device, \\DosDevices")
else
    kprint("warn", "Object Manager not available. Running without handle security.")
end
kprint("ok", "sMLTR (Synapse Message Layer Token Randomisation) active.")

-- Load Virtual Registry
g_oRegistry = __load_registry()
if g_oRegistry then
    g_oRegistry.InitSystem()
    kprint("ok", "Virtual Registry (@VT) initialised.")
else
    kprint("warn", "Virtual Registry not available.")
end

-- Load Preemptive Scheduler module
g_oPreempt = __load_preempt()
if g_oPreempt then
    kprint("ok", string.format(
        "Preemptive scheduler active  (quantum=%dms, interval=%d, no debug hooks)",
        g_oPreempt.DEFAULT_QUANTUM * 1000,
        g_oPreempt.CHECK_INTERVAL))
else
    kprint("warn", "Preemptive scheduling unavailable — cooperative only.")
end

-- Load Kernel IPC subsystem
g_oIpc = __load_ke_ipc()
if g_oIpc and g_oObManager then
    g_oIpc.Initialize({
        tProcessTable = kernel.tProcessTable,
        fUptime       = raw_computer.uptime,
        fLog          = function(s) kprint("info", s) end,
        oObManager    = g_oObManager,
        fYield        = coroutine.yield,
    })
    -- Register new object types
    g_oObManager.ObCreateObjectType("KeMutex",          {})
    g_oObManager.ObCreateObjectType("KeSemaphore",      {})
    g_oObManager.ObCreateObjectType("KeTimer",          {})
    g_oObManager.ObCreateObjectType("IoPipeObject",     {})
    g_oObManager.ObCreateObjectType("IpcMessageQueue",  {})
    kprint("ok", "Kernel IPC subsystem online (Events, Mutexes, Semaphores,")
    kprint("ok", "  Pipes, Sections, MQueues, Signals, WaitMultiple, DPC, IRQL)")
else
    kprint("warn", "Kernel IPC subsystem not available.")
end

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

if g_bAxfsRoot then
  kernel.tVfs.sRootUuid = g_oPrimitiveFs.address
  kernel.tVfs.oRootFs = g_oPrimitiveFs
  kprint("ok", "Mounted AXFS root filesystem (" .. g_oPrimitiveFs._label .. ")")
else
  kernel.tVfs.sRootUuid = tRootEntry.uuid
  kernel.tVfs.oRootFs = raw_component.proxy(tRootEntry.uuid)
  kprint("ok", "Mounted root filesystem on " .. kernel.tVfs.sRootUuid:sub(1,13) .. "...")
end

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

if g_oObManager then g_oObManager.ObInitializeProcess(nKernelPid) end

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

-- =================================================================
-- MAIN KERNEL EVENT LOOP  —  Preemptive Round-Robin Scheduler
--
-- Key changes from cooperative-only:
--
--  1) After each coroutine.resume(), if the process status is still
--     "running" it was preempted by __pc() rather than yielding via
--     a syscall.  We set it back to "ready" so it runs again next
--     tick.
--
--  2) Between every process resume we call computer.pullSignal(0)
--     to RESET the OpenComputers "too long without yielding" timer.
--     Without this, the cumulative runtime of all processes in one
--     tick could exceed OC's ~5-second hard limit and crash the
--     machine.
--
--  3) We track wall-clock time per resume and maintain per-process
--     CPU accounting.  A watchdog warns (and eventually kills)
--     processes whose single resumes exceed WATCHDOG_WARN_THRESHOLD.
--
--  4) Hardware events captured during intermediate pullSignal(0)
--     calls are forwarded to the Pipeline Manager immediately,
--     improving input responsiveness.
-- =================================================================

while true do
  local nWorkDone = 0

  for nPid, tProcess in pairs(kernel.tProcessTable) do
    if tProcess.status == "ready" then
      nWorkDone = nWorkDone + 1
      g_nCurrentPid = nPid
      tProcess.status = "running"

      local nResumeStart = raw_computer.uptime()

      local tResumeParams = tProcess.resume_args
      tProcess.resume_args = nil

      local bIsOk, sErrOrSignalName
      if tResumeParams then
        bIsOk, sErrOrSignalName = coroutine.resume(
            tProcess.co, true, table.unpack(tResumeParams))
      else
        bIsOk, sErrOrSignalName = coroutine.resume(tProcess.co)
      end

      local nSliceTime = raw_computer.uptime() - nResumeStart

      g_nCurrentPid = nKernelPid

      -- ---------- per-process CPU accounting ----------
      tProcess.nCpuTime  = (tProcess.nCpuTime or 0) + nSliceTime
      tProcess.nLastSlice = nSliceTime
      if nSliceTime > (tProcess.nMaxSlice or 0) then
          tProcess.nMaxSlice = nSliceTime
      end

      -- ---------- global scheduler accounting ----------
      g_tSchedStats.nTotalResumes = g_tSchedStats.nTotalResumes + 1
      local nSliceMs = nSliceTime * 1000
      if nSliceMs > g_tSchedStats.nMaxSliceMs then
          g_tSchedStats.nMaxSliceMs = nSliceMs
      end

      -- ---------- crash handling ----------
      if not bIsOk then
        tProcess.status = "dead"
        kernel.panic(tostring(sErrOrSignalName), tProcess.co)
      end

      -- ---------- PREEMPTION DETECTION ----------
      if tProcess.status == "running" then
          tProcess.status = "ready"
          tProcess.nPreemptCount = (tProcess.nPreemptCount or 0) + 1
          g_tSchedStats.nPreemptions = g_tSchedStats.nPreemptions + 1
      end

      -- ---------- natural exit ----------
      if coroutine.status(tProcess.co) == "dead" then
        if tProcess.status ~= "dead" then
          kprint("info", "Process " .. nPid .. " exited normally.")
          tProcess.status = "dead"
        end
      end

      -- ---------- watchdog ----------
      if nSliceTime > WATCHDOG_WARN_THRESHOLD and tProcess.status ~= "dead" then
          tProcess.nWatchdogStrikes = (tProcess.nWatchdogStrikes or 0) + 1
          g_tSchedStats.nWatchdogWarnings = g_tSchedStats.nWatchdogWarnings + 1
          kprint("warn", string.format(
              "WATCHDOG: PID %d ran %.2fs without yielding (strike %d/%d)",
              nPid, nSliceTime,
              tProcess.nWatchdogStrikes, WATCHDOG_KILL_STRIKES))
          if tProcess.nWatchdogStrikes >= WATCHDOG_KILL_STRIKES then
              kprint("fail", "WATCHDOG: Killing PID " .. nPid ..
                             " — exceeded " .. WATCHDOG_KILL_STRIKES .. " strikes")
              tProcess.status = "dead"
              g_tSchedStats.nWatchdogKills = g_tSchedStats.nWatchdogKills + 1
          end
      end

      -- ---------- wake waiters / clean up dead ----------
      if tProcess.status == "dead" then
        if g_oIpc then
            g_oIpc.NotifyChildDeath(nPid)
        end
        if g_oObManager then
          g_oObManager.ObDestroyProcess(nPid)
        end

        for _, nWaiterPid in ipairs(tProcess.wait_queue or {}) do
          local tWaiter = kernel.tProcessTable[nWaiterPid]
          if tWaiter and tWaiter.status == "sleeping"
             and tWaiter.wait_reason == "wait_pid" then
            tWaiter.status = "ready"
            tWaiter.resume_args = {true}
          end
        end

        for _, nTid in ipairs(tProcess.threads or {}) do
          if kernel.tProcessTable[nTid]
             and kernel.tProcessTable[nTid].status ~= "dead" then
            kernel.tProcessTable[nTid].status = "dead"
            if g_oObManager then g_oObManager.ObDestroyProcess(nTid) end
          end
        end
      end

      -- ======================================================
      -- CRITICAL:  Reset the OC "too long without yielding"
      -- timer.  This MUST stay inside the per-process loop so
      -- that each individual resume gets a fresh 5-second window.
      -- Also picks up hardware events for responsiveness.
      -- ======================================================
      local sIntEvt, ip1, ip2, ip3, ip4, ip5 = computer.pullSignal(0)
      if sIntEvt then
          pcall(kernel.syscalls.signal_send, nKernelPid,
                kernel.nPipelinePid, "os_event",
                sIntEvt, ip1, ip2, ip3, ip4, ip5)
      end

    end  -- if status == "ready"
  end  -- for each process

  -- ====== IPC TICK: process DPCs and timers ONCE per iteration ======
  -- This runs AFTER all ready processes have had their turn,
  -- so DPCs queued during this tick's resumes execute here,
  -- and timers are checked exactly once per scheduler pass.
  if g_oIpc then
      g_oIpc.Tick()
  end

  -- ====== OOM KILLER ======
  local FREE_MEMORY_FLOOR = 32768
  local nFreeMem = computer.freeMemory()
  if nFreeMem < FREE_MEMORY_FLOOR then
      local nVictimPid = nil
      local nVictimCpu = 0
      for nKillPid, tKillProc in pairs(kernel.tProcessTable) do
          if tKillProc.status ~= "dead" and tKillProc.ring >= 3
            and (tKillProc.nCpuTime or 0) > nVictimCpu then
              nVictimCpu = tKillProc.nCpuTime or 0
              nVictimPid = nKillPid
          end
      end
      if nVictimPid then
          kprint("fail", string.format(
              "OOM KILLER: PID %d (free=%dB)", nVictimPid, nFreeMem))
          kernel.tProcessTable[nVictimPid].status = "dead"
          if g_oObManager then
              g_oObManager.ObDestroyProcess(nVictimPid)
          end
          collectgarbage("collect")
      end
  end

  -- Pull external events (block briefly if idle)
  local nTimeout = (nWorkDone > 0) and 0 or 0.05
  local sEventName, p1, p2, p3, p4, p5 = computer.pullSignal(nTimeout)

  if sEventName then
    pcall(kernel.syscalls.signal_send, nKernelPid,
          kernel.nPipelinePid, "os_event",
          sEventName, p1, p2, p3, p4, p5)
  end
end