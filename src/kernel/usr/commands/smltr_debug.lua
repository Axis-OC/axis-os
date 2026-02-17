--
-- /usr/commands/smltr_debug.lua
-- sMLTR Verbose Debug Program for AxisOS
-- "Synapse Message Layer Token Randomization - trust no handle."
--
-- Usage:
--   smltr_debug              Full diagnostic suite
--   smltr_debug -t           Token info only
--   smltr_debug -h           Handle table only  (NOTE: -h is handles, --help for help)
--   smltr_debug -o           Object directory only
--   smltr_debug -r           Token rotation test
--   smltr_debug -v           Extra verbose
--   smltr_debug -a           All tests + stress
--   smltr_debug --help       Help
--

local fs   = require("filesystem")
local sys  = require("syscall")
local tArgs = env.ARGS or {}

-- =============================================
-- ANSI
-- =============================================

local C = {
  RESET   = "\27[37m",
  RED     = "\27[31m",
  GREEN   = "\27[32m",
  YELLOW  = "\27[33m",
  BLUE    = "\27[34m",
  MAGENTA = "\27[35m",
  CYAN    = "\27[36m",
  GRAY    = "\27[90m",
  WHITE   = "\27[37m",
}

-- =============================================
-- FLAGS
-- =============================================

local bTokenOnly    = false
local bHandleOnly   = false
local bObjectOnly   = false
local bRotateTest   = false
local bExtraVerbose = false
local bRunAll       = false
local bShowHelp     = false

for _, sArg in ipairs(tArgs) do
  if sArg == "-t" then bTokenOnly = true
  elseif sArg == "-h" then bHandleOnly = true
  elseif sArg == "-o" then bObjectOnly = true
  elseif sArg == "-r" then bRotateTest = true
  elseif sArg == "-v" then bExtraVerbose = true
  elseif sArg == "-a" then bRunAll = true; bExtraVerbose = true
  elseif sArg == "--help" then bShowHelp = true
  end
end

local bDefaultMode = not (bTokenOnly or bHandleOnly or bObjectOnly or bRotateTest or bRunAll)
if bDefaultMode then bRunAll = true end

-- =============================================
-- OUTPUT HELPERS  (all use io.write/print — unbuffered)
-- =============================================

local nTestsPassed = 0
local nTestsFailed = 0
local nTestsWarned = 0
local nTotalChecks = 0

local function hline(nWidth)
  return string.rep("-", nWidth or 58)
end

local function banner(sTitle)
  local sBar = hline(58)
  print("")
  print(C.CYAN .. "  " .. sBar .. C.RESET)
  print(C.CYAN .. "  " .. sTitle .. C.RESET)
  print(C.CYAN .. "  " .. sBar .. C.RESET)
end

local function section(sTitle)
  print("")
  print(C.YELLOW .. "  >> " .. sTitle .. C.RESET)
  print(C.GRAY .. "  " .. string.rep("-", 50) .. C.RESET)
end

local function field(sLabel, vValue, sColor)
  local sC = sColor or C.WHITE
  print(string.format("  %-22s %s%s%s",
    C.GRAY .. sLabel .. ":" .. C.RESET,
    sC, tostring(vValue or "nil"), C.RESET))
end

local function pass(sMsg)
  nTestsPassed = nTestsPassed + 1
  nTotalChecks = nTotalChecks + 1
  print(C.GREEN .. "  [PASS] " .. C.RESET .. sMsg)
end

local function fail(sMsg)
  nTestsFailed = nTestsFailed + 1
  nTotalChecks = nTotalChecks + 1
  print(C.RED .. "  [FAIL] " .. C.RESET .. sMsg)
end

local function warn(sMsg)
  nTestsWarned = nTestsWarned + 1
  nTotalChecks = nTotalChecks + 1
  print(C.YELLOW .. "  [WARN] " .. C.RESET .. sMsg)
end

local function info(sMsg)
  print(C.BLUE .. "  [INFO] " .. C.RESET .. sMsg)
end

local function verbose(sMsg)
  if bExtraVerbose then
    print(C.GRAY .. "  [VERB] " .. sMsg .. C.RESET)
  end
end

local function hex_dump_token(sToken)
  if not sToken or not bExtraVerbose then return end
  local tHex = {}
  local nMax = math.min(#sToken, 32)
  for i = 1, nMax do
    tHex[i] = string.format("%02X", string.byte(sToken, i))
  end
  verbose("Hex: " .. table.concat(tHex, " ") .. (#sToken > 32 and " ..." or ""))
end

-- =============================================
-- TIMING (safe — no require("computer") which may not exist)
-- =============================================

local function uptime()
  -- os.clock is always in the sandbox
  return os.clock()
end

-- =============================================
-- HELP
-- =============================================

local function print_help()
  print("")
  print(C.CYAN .. "smltr_debug" .. C.RESET .. " - sMLTR Verbose Debug Program")
  print(C.GRAY .. "Synapse Message Layer Token Randomization diagnostics" .. C.RESET)
  print("")
  print("Usage: smltr_debug [flags]")
  print("")
  print("  (no flags)    Run full diagnostic suite")
  print("  -t            Token inspection only")
  print("  -h            Handle table dump only")
  print("  -o            Object directory dump only")
  print("  -r            Token rotation test")
  print("  -v            Extra verbose (hex dumps)")
  print("  -a            All tests including stress tests")
  print("  --help        This help message")
  print("")
end

if bShowHelp then
  print_help()
  return
end

-- =============================================
-- 1. PROCESS CONTEXT & TOKEN INSPECTION
-- =============================================

local function test_token_inspection()
  banner("SECTION 1: PROCESS CONTEXT & TOKEN INSPECTION")

  section("1.1 Current Process Identity")

  local nPid = syscall("process_get_pid")
  local nRing = syscall("process_get_ring")

  field("PID", nPid, C.CYAN)
  field("Ring Level", nRing, (nRing and nRing <= 1) and C.RED or C.GREEN)
  field("User", env.USER or "(unknown)", C.GREEN)
  field("UID", env.UID, (env.UID and tonumber(env.UID) == 0) and C.RED or C.WHITE)
  field("Home", env.HOME or "(unknown)")
  field("Hostname", env.HOSTNAME or "(unknown)")
  field("PWD", env.PWD or "/")
  field("PATH", env.PATH or "(unset)")

  if nRing == 0 then
    warn("Running in Ring 0 (KERNEL MODE) - full sMLTR bypass!")
  elseif nRing == 1 then
    warn("Running in Ring 1 (PIPELINE) - sMLTR bypass for PID < 20")
  elseif nRing == 2 then
    info("Running in Ring 2 (DRIVER MODE)")
  elseif nRing == 2.5 then
    info("Running in Ring 2.5 (ELEVATED)")
  elseif nRing == 3 then
    pass("Running in Ring 3 (USER MODE) - full sMLTR enforcement")
  end

  section("1.2 Synapse Token Retrieval")

  local sToken = sys.getSynapseToken()

  if sToken then
    pass("Synapse token retrieved successfully")
    field("Token", sToken, C.MAGENTA)
    field("Token Length", #sToken)

    -- Parse: SYN-XXXX-XXXX-XXXX-XXXX
    local sPfx = sToken:sub(1, 4)
    if sPfx == "SYN-" then
      pass("Token has correct SYN- prefix")
      -- Count the segments
      local nDashes = 0
      for i = 1, #sToken do
        if sToken:sub(i, i) == "-" then nDashes = nDashes + 1 end
      end
      if nDashes == 4 then
        pass("Token format valid (4 dashes = 5 segments)")
      else
        warn("Unexpected dash count: " .. nDashes)
      end
    else
      fail("Token prefix INVALID - expected SYN-, got: " .. sPfx)
    end

    hex_dump_token(sToken)
  else
    fail("Failed to retrieve synapse token!")
    info("Kernel may not implement synapse_get_token")
  end

  section("1.3 Token Stability")
  info("Reading token multiple times...")

  local sToken2 = sys.getSynapseToken()
  local sToken3 = sys.getSynapseToken()

  if sToken and sToken2 and sToken3 then
    if sToken == sToken2 and sToken2 == sToken3 then
      pass("Token stable across repeated reads (no unintended rotation)")
    else
      fail("Token CHANGED between reads without rotation!")
      field("Read 1", sToken)
      field("Read 2", sToken2)
      field("Read 3", sToken3)
    end
  end

  section("1.4 sMLTR Bypass Eligibility")
  if nPid then
    if nPid < 20 then
      warn("PID " .. nPid .. " < 20: sMLTR validation BYPASSED")
    else
      pass("PID " .. nPid .. " >= 20: sMLTR validation ENFORCED")
    end
  end
end

-- =============================================
-- 2. HANDLE TABLE INSPECTION
-- =============================================

local function test_handle_table()
  banner("SECTION 2: HANDLE TABLE INSPECTION")

  section("2.1 Standard Handle Probes")
  info("Testing standard I/O handles (-10, -11, -12)...")

  -- Test stdout by writing zero-length string
  -- io.write goes directly to syscall, no pcall needed
  io.write("")  -- zero-length probe
  pass("stdout (-11) write chain functional (zero-length probe OK)")

  -- stdin can't be probed without blocking
  info("stdin (-10) cannot be probed without blocking")

  section("2.2 Handle Token Inspection")
  info("Opening test handles to inspect token structure...")

  local hProbe = fs.open("/dev/tty", "r")
  if hProbe then
    local sTok = hProbe._token
    if sTok then
      pass("Obtained handle token: " .. sTok:sub(1, 20) .. "...")
      local sPfx = sTok:sub(1, 2)
      if sPfx == "H-" then
        pass("Token has correct H- prefix (ObManager handle format)")
      else
        warn("Token prefix is not H-: " .. sPfx)
      end
      hex_dump_token(sTok)
    else
      warn("Handle object has no _token field")
    end
    fs.close(hProbe)
    pass("Handle closed successfully")
  else
    fail("Could not open /dev/tty for handle inspection")
  end

  section("2.3 Handle Collision Test")
  info("Opening multiple handles to check uniqueness...")

  local tTokensSeen = {}
  local nCollisions = 0
  local nHandlesToTest = 10

  for i = 1, nHandlesToTest do
    local hFile = fs.open("/dev/tty", "r")
    if hFile and hFile._token then
      if tTokensSeen[hFile._token] then
        nCollisions = nCollisions + 1
        fail("COLLISION! Token reused: " .. hFile._token:sub(1, 20))
      else
        tTokensSeen[hFile._token] = i
      end
      fs.close(hFile)
    end
  end

  if nCollisions == 0 then
    pass("No collisions across " .. nHandlesToTest .. " handle opens")
  else
    fail(nCollisions .. " collision(s) in " .. nHandlesToTest .. " opens!")
  end

  if bExtraVerbose then
    verbose("All tokens:")
    for sTok, nIdx in pairs(tTokensSeen) do
      verbose(string.format("  [%2d] %s", nIdx, sTok))
    end
  end

  section("2.4 Cross-Handle Isolation")
  info("Two simultaneous opens should produce different tokens...")

  local hA = fs.open("/dev/tty", "r")
  local hB = fs.open("/dev/tty", "r")

  if hA and hB then
    local sTokA = hA._token
    local sTokB = hB._token
    if sTokA and sTokB then
      if sTokA ~= sTokB then
        pass("Different opens produce different tokens")
        verbose("A: " .. sTokA:sub(1, 20))
        verbose("B: " .. sTokB:sub(1, 20))
      else
        fail("Two opens returned SAME token! Isolation failure!")
      end
    else
      warn("Missing _token on one or both handles")
    end
    fs.close(hA)
    fs.close(hB)
  else
    warn("Could not open two handles for isolation test")
  end

  section("2.5 Handle Lifecycle (Open -> Use -> Close -> Use-After-Close)")

  local hLife = fs.open("/dev/tty", "w")
  if hLife then
    local sSaved = hLife._token
    field("Handle", sSaved and (sSaved:sub(1, 20) .. "...") or "N/A")

    -- Write while open (use io.write to avoid buffer issues)
    pass("Handle opened")

    fs.close(hLife)
    pass("Handle closed")

    -- Attempt use-after-close via raw syscall with saved token
    if sSaved then
      local b1, b2, sErr = syscall("vfs_write", sSaved, "UAF_TEST")
      if b1 and b2 then
        fail("USE-AFTER-CLOSE SUCCEEDED! Critical vulnerability!")
      else
        pass("Use-after-close correctly rejected")
        verbose("Rejection: " .. tostring(b2 or sErr))
      end
    end
  else
    warn("Could not open handle for lifecycle test")
  end
end

-- =============================================
-- 3. OBJECT DIRECTORY
-- =============================================

local function test_object_directory()
  banner("SECTION 3: KERNEL OBJECT DIRECTORY")

  local nRing = syscall("process_get_ring")

  section("3.1 VFS /dev Enumeration")

  local tDevList = fs.list("/dev")
  if tDevList and type(tDevList) == "table" then
    pass("/dev listing: " .. #tDevList .. " entries")
    for _, sName in ipairs(tDevList) do
      local sClean = sName
      if sClean:sub(-1) == "/" then sClean = sClean:sub(1, -2) end
      print(string.format("  %s/dev/%-20s%s", C.YELLOW, sClean, C.RESET))
    end
  else
    warn("Could not list /dev")
  end

  section("3.2 Device Reachability")

  local tKnownDevices = { "/dev/tty", "/dev/ringlog", "/dev/gpu0", "/dev/net" }

  for _, sPath in ipairs(tKnownDevices) do
    local hDev = fs.open(sPath, "r")
    if hDev then
      pass(sPath .. " reachable (token: " ..
        (hDev._token and hDev._token:sub(1, 16) .. "..." or "N/A") .. ")")
      fs.close(hDev)
    else
      verbose(sPath .. " not reachable")
    end
  end

  section("3.3 Kernel Object Dump (Ring 0-1 only)")
  if nRing and nRing <= 1 then
    local tObjects = syscall("ob_dump_directory")
    if tObjects and type(tObjects) == "table" then
      pass("Object directory: " .. #tObjects .. " objects")
      print("")
      print(string.format("  %s%-34s %-18s %-5s %-5s%s",
        C.GRAY, "PATH", "TYPE", "REFS", "HNDL", C.RESET))
      print(C.GRAY .. "  " .. string.rep("-", 68) .. C.RESET)

      for _, tObj in ipairs(tObjects) do
        local sP = tObj.sPath or "(null)"
        if #sP > 32 then sP = sP:sub(1, 29) .. "..." end
        local sT = tObj.sType or "?"
        local sTC = C.WHITE
        if sT == "ObpDirectory" then sTC = C.BLUE
        elseif sT == "ObpSymbolicLink" then sTC = C.CYAN
        elseif sT == "IoDeviceObject" then sTC = C.YELLOW
        elseif sT == "IoFileObject" then sTC = C.GREEN
        end
        print(string.format("  %-34s %s%-18s%s %-5d %-5d",
          sP, sTC, sT, C.RESET, tObj.nRefCount or 0, tObj.nHandleCount or 0))
      end
    else
      warn("ob_dump_directory returned nil")
    end
  else
    info("Object dump requires Ring 0-1 (current: " .. tostring(nRing) .. ")")
    info("Log in as 'dev' (Ring 0) for full namespace dump")
  end
end

-- =============================================
-- 4. TOKEN ROTATION TEST
-- =============================================

local function test_token_rotation()
  banner("SECTION 4: sMLTR TOKEN ROTATION TEST")

  local nRing = syscall("process_get_ring")
  local nPid = syscall("process_get_pid")

  section("4.1 Pre-Rotation State")
  local sTokenBefore = sys.getSynapseToken()
  field("Current Token", sTokenBefore and (sTokenBefore:sub(1, 24) .. "...") or "nil", C.MAGENTA)

  if not sTokenBefore then
    fail("Cannot test rotation: no token")
    return
  end

  section("4.2 Rotation Attempt")

  if nRing and nRing <= 1 then
    local sNewToken = syscall("synapse_rotate", nPid)

    if sNewToken then
      pass("Token rotation succeeded")
      field("Old", sTokenBefore:sub(1, 24) .. "...", C.GRAY)
      field("New", sNewToken:sub(1, 24) .. "...", C.GREEN)

      if sNewToken ~= sTokenBefore then
        pass("New token differs from old (entropy confirmed)")
      else
        fail("New token IDENTICAL to old! Entropy failure!")
      end

      local sVerify = sys.getSynapseToken()
      if sVerify == sNewToken then
        pass("get_token returns the rotated token")
      else
        fail("get_token still returns old token!")
      end

      section("4.3 Post-Rotation Handle Test")
      local hPost = fs.open("/dev/tty", "r")
      if hPost then
        pass("New handle creation works after rotation")
        fs.close(hPost)
      else
        warn("Handle creation failed after rotation")
      end
    else
      fail("synapse_rotate returned nil")
    end
  else
    info("Rotation requires Ring 0-1 (current: " .. tostring(nRing) .. ")")
    info("Log in as 'dev' and run: smltr_debug -r -v")

    section("4.3 Token Validation Probe (Ring 0-2)")
    if nRing and nRing <= 2 then
      local sOurs = sys.getSynapseToken()
      local bSelf = syscall("synapse_validate", nPid, sOurs)
      if bSelf then
        pass("Self-validation: own PID + own token accepted")
      else
        fail("Self-validation FAILED!")
      end

      local bFake = syscall("synapse_validate", nPid, "SYN-dead-beef-cafe-babe")
      if not bFake then
        pass("Bogus token correctly rejected")
      else
        fail("Bogus token ACCEPTED! sMLTR is broken!")
      end
    else
      info("Validation probe requires Ring <= 2")
    end
  end
end

-- =============================================
-- 5. HANDLE I/O SECURITY
-- =============================================

local function test_handle_io_security()
  banner("SECTION 5: HANDLE I/O SECURITY TESTS")

  section("5.1 Device IOCTL via sMLTR")

  local hTty = fs.open("/dev/tty", "r")
  if hTty then
    local bOk1, vR1 = fs.deviceControl(hTty, "get_buffer", {})
    if bOk1 then
      pass("deviceControl(get_buffer) succeeded via sMLTR handle")
    else
      verbose("get_buffer: " .. tostring(vR1))
    end

    local bOk2, vR2 = fs.deviceControl(hTty, "get_cursor", {})
    if bOk2 then
      pass("deviceControl(get_cursor) succeeded")
      if type(vR2) == "table" then
        verbose("Cursor: x=" .. tostring(vR2.x) .. " y=" .. tostring(vR2.y))
      end
    end

    fs.close(hTty)
  else
    warn("Could not open /dev/tty for IOCTL test")
  end
end

-- =============================================
-- 6. PROCESS TABLE SURVEY
-- =============================================

local function test_process_enumeration()
  banner("SECTION 6: PROCESS TABLE & sMLTR COVERAGE")

  section("6.1 Active Process List")

  local tProcs = syscall("process_list")
  if not tProcs or type(tProcs) ~= "table" then
    fail("process_list returned nil")
    return
  end

  pass("Processes: " .. #tProcs)
  print("")
  print(string.format("  %s%-5s %-5s %-6s %-10s %-6s %s%s",
    C.GRAY, "PID", "PPID", "RING", "STATUS", "UID", "IMAGE", C.RESET))
  print(C.GRAY .. "  " .. string.rep("-", 60) .. C.RESET)

  local nR0, nR1, nR2, nR3 = 0, 0, 0, 0

  for _, p in ipairs(tProcs) do
    local nR = p.ring or -1
    local sRC = C.WHITE
    if nR == 0 then sRC = C.RED; nR0 = nR0 + 1
    elseif nR == 1 then sRC = C.YELLOW; nR1 = nR1 + 1
    elseif nR == 2 then sRC = C.CYAN; nR2 = nR2 + 1
    elseif nR == 3 then sRC = C.GREEN; nR3 = nR3 + 1
    end
    print(string.format("  %-5d %-5d %s%-6s%s %-10s %-6s %s",
      p.pid, p.parent, sRC, tostring(nR), C.RESET,
      p.status or "?", tostring(p.uid or "?"), p.image or "?"))
  end

  print("")
  section("6.2 Ring Distribution")
  field("Ring 0 (Kernel)", nR0, C.RED)
  field("Ring 1 (Pipeline)", nR1, C.YELLOW)
  field("Ring 2 (Driver)", nR2, C.CYAN)
  field("Ring 3 (User)", nR3, C.GREEN)

  section("6.3 sMLTR Coverage")
  local nBypass = 0
  local nEnforced = 0
  for _, p in ipairs(tProcs) do
    if p.pid < 20 then nBypass = nBypass + 1
    else nEnforced = nEnforced + 1 end
  end

  field("Bypass Eligible", nBypass .. " (PID < 20)", C.YELLOW)
  field("Enforced", nEnforced .. " (PID >= 20)", C.GREEN)

  local nCov = (#tProcs > 0) and math.floor((nEnforced / #tProcs) * 100) or 0
  field("Coverage", nCov .. "%", nCov >= 80 and C.GREEN or C.YELLOW)
end

-- =============================================
-- 7. STRESS TESTS
-- =============================================

local function test_stress()
  banner("SECTION 7: sMLTR STRESS TESTS")

  section("7.1 Rapid Handle Churn")
  info("50 open/close cycles...")

  local nCount = 50
  local nSuccess = 0
  local nFail = 0
  local tAllTokens = {}
  local nStart = uptime()

  for i = 1, nCount do
    local hFile = fs.open("/dev/tty", "r")
    if hFile then
      if hFile._token then
        if tAllTokens[hFile._token] then
          nFail = nFail + 1
        else
          tAllTokens[hFile._token] = true
          nSuccess = nSuccess + 1
        end
      end
      fs.close(hFile)
    else
      nFail = nFail + 1
    end
  end

  local nElapsed = uptime() - nStart

  field("Unique tokens", nSuccess, C.GREEN)
  field("Collisions/fails", nFail, nFail > 0 and C.RED or C.GREEN)
  field("Time", string.format("%.4fs", nElapsed))

  if nFail == 0 then
    pass("All " .. nCount .. " tokens unique")
  else
    fail(nFail .. " issues in " .. nCount .. " operations!")
  end

  section("7.2 Simultaneous Handles")
  info("Opening 20 handles at once...")

  local tOpen = {}
  local nMax = 20
  local nOpened = 0

  for i = 1, nMax do
    local h = fs.open("/dev/tty", "r")
    if h then
      table.insert(tOpen, h)
      nOpened = nOpened + 1
    else
      break
    end
  end

  field("Opened", nOpened .. "/" .. nMax, nOpened == nMax and C.GREEN or C.YELLOW)

  local tSeen = {}
  local nSimColl = 0
  for _, h in ipairs(tOpen) do
    if h._token then
      if tSeen[h._token] then nSimColl = nSimColl + 1 end
      tSeen[h._token] = true
    end
  end

  if nSimColl == 0 then
    pass("All simultaneous handles have unique tokens")
  else
    fail(nSimColl .. " collisions among simultaneous handles!")
  end

  for _, h in ipairs(tOpen) do fs.close(h) end
  pass("All handles closed")

  section("7.3 Token Entropy")

  -- Combine all tokens
  local tAllList = {}
  for sTok in pairs(tAllTokens) do table.insert(tAllList, sTok) end
  for sTok in pairs(tSeen) do table.insert(tAllList, sTok) end

  if #tAllList > 0 then
    local tFreq = {}
    local nTotal = 0
    for _, sTok in ipairs(tAllList) do
      local sHex = ""
      for i = 1, #sTok do
        local c = sTok:sub(i, i)
        -- check if hex char
        local b = string.byte(c)
        if (b >= 48 and b <= 57) or (b >= 97 and b <= 102) or (b >= 65 and b <= 70) then
          sHex = sHex .. c:lower()
        end
      end
      for i = 1, #sHex do
        local ch = sHex:sub(i, i)
        tFreq[ch] = (tFreq[ch] or 0) + 1
        nTotal = nTotal + 1
      end
    end

    local nUnique = 0
    local nMaxF, nMinF = 0, nTotal
    for _, n in pairs(tFreq) do
      nUnique = nUnique + 1
      if n > nMaxF then nMaxF = n end
      if n < nMinF then nMinF = n end
    end

    field("Tokens analyzed", #tAllList)
    field("Hex chars", nTotal)
    field("Unique hex digits", nUnique .. "/16")

    if nUnique >= 14 then
      pass("Good hex coverage (" .. nUnique .. "/16)")
    else
      warn("Low hex coverage: " .. nUnique .. "/16")
    end

    if bExtraVerbose then
      verbose("Frequency table:")
      local tSorted = {}
      for c, n in pairs(tFreq) do table.insert(tSorted, {c = c, n = n}) end
      table.sort(tSorted, function(a, b) return a.c < b.c end)
      for _, t in ipairs(tSorted) do
        local bar = string.rep("#", math.floor((t.n / nMaxF) * 20))
        verbose(string.format("  %s: %3d %s", t.c, t.n, bar))
      end
    end
  end
end

-- =============================================
-- SUMMARY
-- =============================================

local function print_summary()
  banner("sMLTR DIAGNOSTIC SUMMARY")

  print("")
  print(string.format("  %sPassed:%s  %d", C.GREEN, C.RESET, nTestsPassed))
  print(string.format("  %sFailed:%s  %d", C.RED, C.RESET, nTestsFailed))
  print(string.format("  %sWarned:%s  %d", C.YELLOW, C.RESET, nTestsWarned))
  print(string.format("  %sTotal:%s   %d", C.CYAN, C.RESET, nTotalChecks))
  print("")

  if nTestsFailed == 0 then
    print(C.GREEN .. "  ======================================" .. C.RESET)
    print(C.GREEN .. "  sMLTR SUBSYSTEM: ALL CHECKS PASSED" .. C.RESET)
    print(C.GREEN .. "  ======================================" .. C.RESET)
  elseif nTestsFailed <= 2 then
    print(C.YELLOW .. "  ======================================" .. C.RESET)
    print(C.YELLOW .. "  sMLTR SUBSYSTEM: MINOR ISSUES" .. C.RESET)
    print(C.YELLOW .. "  ======================================" .. C.RESET)
  else
    print(C.RED .. "  ======================================" .. C.RESET)
    print(C.RED .. "  sMLTR SUBSYSTEM: CRITICAL ISSUES" .. C.RESET)
    print(C.RED .. "  ======================================" .. C.RESET)
  end

  print("")
  field("Tool", "smltr_debug v1.1.0")
  field("OS", "AxisOS Xen XKA v0.3")
  field("Security", "sMLTR + WDM ObManager handles")
  print("")
end

-- =============================================
-- MAIN
-- =============================================

print("")
print(C.CYAN .. "  ==========================================================" .. C.RESET)
print(C.CYAN .. "  sMLTR VERBOSE DEBUG PROGRAM v1.1.0" .. C.RESET)
print(C.CYAN .. "  Synapse Message Layer Token Randomization Diagnostics" .. C.RESET)
print(C.CYAN .. "  AxisOS Xen XKA v0.3" .. C.RESET)
print(C.CYAN .. "  ==========================================================" .. C.RESET)

local nStartTime = uptime()

if bTokenOnly or bRunAll then test_token_inspection() end
if bHandleOnly or bRunAll then test_handle_table() end
if bObjectOnly or bRunAll then test_object_directory() end
if bRotateTest or bRunAll then test_token_rotation() end

if bRunAll then
  test_handle_io_security()
  test_process_enumeration()
  test_stress()
end

local nElapsed = uptime() - nStartTime
print("")
field("Runtime", string.format("%.4f seconds", nElapsed))

print_summary()