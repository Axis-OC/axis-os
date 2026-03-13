--
-- /usr/commands/insmod.lua
-- AxisOS Driver Insertion Tool v2
-- "insmod - because hot-plugging drivers at runtime is totally safe"
--
-- Usage:
--   insmod <path>              Load a driver from explicit path
--   insmod -s <component>      Scan and load driver for component type
--   insmod -v <path>           Verbose mode (extra debug output)
--   insmod -i <path>           Info-only mode (inspect without loading)
--

local fs = require("filesystem")
local sys = require("syscall")

local tArgs = env.ARGS or {}

-- =============================================
-- OUTPUT HELPERS
-- =============================================

local C_RESET  = "\27[37m"
local C_RED    = "\27[31m"
local C_GREEN  = "\27[32m"
local C_YELLOW = "\27[33m"
local C_BLUE   = "\27[34m"
local C_CYAN   = "\27[36m"
local C_GRAY   = "\27[90m"

local bVerbose = false

local function log_info(sMsg)
  print(C_BLUE .. ":: " .. C_RESET .. sMsg)
end

local function log_ok(sMsg)
  print(C_GREEN .. "[  OK  ] " .. C_RESET .. sMsg)
end

local function log_fail(sMsg)
  print(C_RED .. "[ FAIL ] " .. C_RESET .. sMsg)
end

local function log_warn(sMsg)
  print(C_YELLOW .. "[ WARN ] " .. C_RESET .. sMsg)
end

local function log_verbose(sMsg)
  if bVerbose then
    print(C_GRAY .. "  [dbg] " .. sMsg .. C_RESET)
  end
end

local function log_step(nStep, nTotal, sMsg)
  local sPrefix = string.format(C_CYAN .. "[%d/%d]" .. C_RESET, nStep, nTotal)
  print(sPrefix .. " " .. sMsg)
end

-- =============================================
-- USAGE
-- =============================================

local function print_usage()
  print(C_CYAN .. "insmod" .. C_RESET .. " - AxisOS Driver Insertion Tool v2")
  print("")
  print("Usage:")
  print("  insmod <path>            Load driver from path")
  print("  insmod -s <component>    Auto-scan and load for component type")
  print("  insmod -v <path>         Verbose mode")
  print("  insmod -i <path>         Inspect driver without loading")
  print("")
  print("Examples:")
  print("  insmod /drivers/iter.sys.lua")
  print("  insmod -s iter")
  print("  insmod -v /drivers/ringfs.sys.lua")
  print("  insmod -i /drivers/gpu.sys.lua")
end

-- =============================================
-- PATH RESOLUTION
-- =============================================

local function resolve_path(sInput)
  -- If it's already an absolute path, use it
  if sInput:sub(1, 1) == "/" then
    return sInput
  end

  -- Try as relative path
  local sRelative = (env.PWD or "/") .. "/" .. sInput
  sRelative = sRelative:gsub("//", "/")

  -- Try the standard driver directory
  local tCandidates = {
    sRelative,
    "/sys/drivers/" .. sInput,
    "/sys/drivers/" .. sInput .. ".sys.lua",
    "/sys/drivers/" .. sInput .. ".lua",
    "/drivers/" .. sInput,
    "/drivers/" .. sInput .. ".sys.lua",
    "/drivers/" .. sInput .. ".lua",
  }

  for _, sCandidate in ipairs(tCandidates) do
    local h = fs.open(sCandidate, "r")
    if h then
      fs.close(h)
      return sCandidate
    end
  end

  return nil
end

-- =============================================
-- DRIVER FILE VALIDATION
-- =============================================

local function validate_driver_file(sPath)
  log_verbose("Opening file: " .. sPath)

  -- Read-only validation — we never write to the driver file
  local hFile = fs.open(sPath, "r")
  if not hFile then
    return nil, "File not found or permission denied: " .. sPath
  end

  local sCode = fs.read(hFile, math.huge)
  fs.close(hFile)

  if not sCode or #sCode == 0 then
    return nil, "File is empty or unreadable: " .. sPath
  end

  log_verbose("File size: " .. #sCode .. " bytes")
  log_verbose("Read-only validation (no system state modified)")

  -- Check for required globals
  local bHasDriverInfo = false
  local bHasDriverEntry = false
  local bHasMainLoop = false

  -- Simple text scanning (no regex, as requested)
  -- Look for g_tDriverInfo
  if sCode:find("g_tDriverInfo") then
    bHasDriverInfo = true
    log_verbose("Found g_tDriverInfo declaration")
  end

  -- Look for DriverEntry or UMDriverEntry
  if sCode:find("function DriverEntry") or sCode:find("function UMDriverEntry") then
    bHasDriverEntry = true
    log_verbose("Found DriverEntry function")
  end

  -- Look for main loop
  if sCode:find("while true") then
    bHasMainLoop = true
    log_verbose("Found main event loop")
  end

  local tWarnings = {}

  if not bHasDriverInfo then
    return nil, "Missing g_tDriverInfo table. This is not a valid AxisOS driver."
  end

  if not bHasDriverEntry then
    table.insert(tWarnings, "No DriverEntry function found. Driver may not initialize properly.")
  end

  if not bHasMainLoop then
    table.insert(tWarnings, "No main loop detected. Driver may exit immediately after init.")
  end

  -- Extract driver info from the file text
  local tInfo = {}

  -- Find sDriverName
  local nNameStart = sCode:find("sDriverName")
  if nNameStart then
    -- Walk forward to find the string value
    local nQuoteStart = sCode:find('"', nNameStart)
    if nQuoteStart then
      local nQuoteEnd = sCode:find('"', nQuoteStart + 1)
      if nQuoteEnd then
        tInfo.sDriverName = sCode:sub(nQuoteStart + 1, nQuoteEnd - 1)
      end
    end
  end

  -- Find sDriverType
  local nTypeStart = sCode:find("sDriverType")
  if nTypeStart then
    -- Check for known types
    if sCode:find("DRIVER_TYPE_KMD", nTypeStart) then
      tInfo.sDriverType = "KernelModeDriver"
    elseif sCode:find("DRIVER_TYPE_CMD", nTypeStart) then
      tInfo.sDriverType = "ComponentModeDriver"
    elseif sCode:find("DRIVER_TYPE_UMD", nTypeStart) then
      tInfo.sDriverType = "UserModeDriver"
    end
  end

  -- Find nLoadPriority
  local nPrioStart = sCode:find("nLoadPriority")
  if nPrioStart then
    -- Walk forward to find the number
    local nEqSign = sCode:find("=", nPrioStart)
    if nEqSign then
      local sRest = sCode:sub(nEqSign + 1, nEqSign + 10)
      -- Extract digits
      local sNum = ""
      for i = 1, #sRest do
        local c = sRest:sub(i, i)
        if c == "0" or c == "1" or c == "2" or c == "3" or c == "4" or
           c == "5" or c == "6" or c == "7" or c == "8" or c == "9" then
          sNum = sNum .. c
        elseif #sNum > 0 then
          break
        end
      end
      if #sNum > 0 then
        tInfo.nLoadPriority = tonumber(sNum)
      end
    end
  end

  -- Find sVersion
  local nVerStart = sCode:find("sVersion")
  if nVerStart then
    local nQuoteStart = sCode:find('"', nVerStart)
    if nQuoteStart then
      local nQuoteEnd = sCode:find('"', nQuoteStart + 1)
      if nQuoteEnd then
        tInfo.sVersion = sCode:sub(nQuoteStart + 1, nQuoteEnd - 1)
      end
    end
  end

  -- Find sSupportedComponent
  local nCompStart = sCode:find("sSupportedComponent")
  if nCompStart then
    local nQuoteStart = sCode:find('"', nCompStart)
    if nQuoteStart then
      local nQuoteEnd = sCode:find('"', nQuoteStart + 1)
      if nQuoteEnd then
        tInfo.sSupportedComponent = sCode:sub(nQuoteStart + 1, nQuoteEnd - 1)
      end
    end
  end

  tInfo.nFileSize = #sCode
  tInfo.tWarnings = tWarnings

  return tInfo
end

-- =============================================
-- DRIVER TYPE DISPLAY
-- =============================================

local function format_driver_type(sType)
  if sType == "KernelModeDriver" then
    return C_RED .. "KMD (Ring 2)" .. C_RESET
  elseif sType == "ComponentModeDriver" then
    return C_YELLOW .. "CMD (Ring 2, Hardware-Bound)" .. C_RESET
  elseif sType == "UserModeDriver" then
    return C_GREEN .. "UMD (Ring 3, Sandboxed)" .. C_RESET
  end
  return C_GRAY .. tostring(sType) .. C_RESET
end

-- =============================================
-- INFO DISPLAY
-- =============================================

local function display_driver_info(sPath, tInfo)
  print("")
  print(C_CYAN .. "  Driver Information" .. C_RESET)
  print(C_GRAY .. "  " .. string.rep("-", 40) .. C_RESET)
  print("  Name:       " .. C_GREEN .. (tInfo.sDriverName or "Unknown") .. C_RESET)
  print("  Type:       " .. format_driver_type(tInfo.sDriverType))
  print("  Priority:   " .. tostring(tInfo.nLoadPriority or "N/A"))
  print("  Version:    " .. (tInfo.sVersion or "N/A"))
  print("  File:       " .. sPath)
  print("  Size:       " .. tostring(tInfo.nFileSize) .. " bytes")

  if tInfo.sSupportedComponent then
    print("  Component:  " .. C_YELLOW .. tInfo.sSupportedComponent .. C_RESET)
  end

  if tInfo.tWarnings and #tInfo.tWarnings > 0 then
    print("")
    for _, sWarn in ipairs(tInfo.tWarnings) do
      log_warn(sWarn)
    end
  end

  print(C_GRAY .. "  " .. string.rep("-", 40) .. C_RESET)
  print("")
end

-- =============================================
-- SECURITY CHECK
-- =============================================

local function check_permissions()
  local nRing = syscall("process_get_ring")
  local nUid = env.UID

  log_verbose("Current ring level: " .. tostring(nRing))
  log_verbose("Current UID: " .. tostring(nUid))

  -- UID 0 (root) can always load drivers regardless of ring
  if nUid and tonumber(nUid) == 0 then
    log_verbose("Running as root (UID 0). Access granted.")
    return true
  end

  -- Non-root users cannot load drivers at any ring
  log_fail("Permission denied: only root (UID 0) can load drivers.")
  print("  Your UID: " .. tostring(nUid or "unknown"))
  print("  Required: UID 0 (root)")
  print("")
  print("  To elevate, run: " .. C_CYAN .. "su" .. C_RESET)
  return false
end

-- =============================================
-- LOAD DRIVER
-- =============================================

local function load_driver(sPath)
  local nTotalSteps = 5

  -- Step 1: Resolve path
  log_step(1, nTotalSteps, "Resolving driver path...")
  local sResolvedPath = resolve_path(sPath)

  if not sResolvedPath then
    log_fail("Could not find driver file.")
    log_verbose("Tried paths based on: " .. sPath)
    print("  Searched:")
    print("    " .. C_GRAY .. sPath .. C_RESET)
    print("    " .. C_GRAY .. "/drivers/" .. sPath .. C_RESET)
    print("    " .. C_GRAY .. "/drivers/" .. sPath .. ".sys.lua" .. C_RESET)
    return false
  end

  log_ok("Resolved to: " .. sResolvedPath)

  -- Step 2: Validate driver file
  log_step(2, nTotalSteps, "Validating driver file...")
  local tInfo, sValidateErr = validate_driver_file(sResolvedPath)

  if not tInfo then
    log_fail("Validation failed: " .. sValidateErr)
    return false
  end

  log_ok("Validation passed for '" .. (tInfo.sDriverName or "Unknown") .. "'")
  display_driver_info(sResolvedPath, tInfo)

  -- Step 3: Security check
  log_step(3, nTotalSteps, "Checking security permissions...")

  if not check_permissions() then
    return false
  end

  log_ok("Security check passed.")

  -- Step 4: Check for CMD component availability
  if tInfo.sDriverType == "ComponentModeDriver" and tInfo.sSupportedComponent then
    log_step(4, nTotalSteps, "Scanning for '" .. tInfo.sSupportedComponent .. "' hardware...")
    log_verbose("Driver is a CMD. DKMS will auto-discover components.")
    log_verbose("Supported component type: " .. tInfo.sSupportedComponent)
    log_ok("DKMS will handle hardware binding during load.")
  else
    log_step(4, nTotalSteps, "Preparing for load...")
    if tInfo.sDriverType == "KernelModeDriver" then
      log_verbose("Driver is KMD. Will run at Ring 2.")
    elseif tInfo.sDriverType == "UserModeDriver" then
      log_verbose("Driver is UMD. Will run at Ring 3 inside a driver host.")
    end
    log_ok("Ready.")
  end

  -- Step 5: Actually load via syscall
-- Step 5: Actually load via syscall
  log_step(5, nTotalSteps, "Sending load request to Pipeline Manager...")
  log_verbose("Issuing syscall('driver_load', '" .. sResolvedPath .. "')")
  log_verbose("PM will validate, DKMS will spawn, driver will init.")

  -- syscall returns: (ipc_ok, pm_result, pm_message)
  local bIpcOk, bPmResult, sPmMessage = syscall("driver_load", sResolvedPath)

  if not bIpcOk then
    log_fail("IPC failure communicating with Pipeline Manager!")
    print("  " .. C_RED .. "The syscall itself failed. Kernel issue?" .. C_RESET)
    return false
  end

  if bPmResult then
    log_ok("Driver loaded successfully!")
    print("")
    print("  " .. C_GREEN .. tostring(sPmMessage) .. C_RESET)
    print("")

    -- Verify the driver appeared in /dev
    if tInfo.sSupportedComponent then
      log_verbose("Checking /dev for new device entries...")
      local tDevList = fs.list("/dev")
      if tDevList then
        local tNewDevs = {}
        for _, sName in ipairs(tDevList) do
          -- Check if device name contains the component type
          local sClean = sName
          if sClean:sub(-1) == "/" then sClean = sClean:sub(1, -2) end
          -- Simple string search
          local bMatch = false
          local sComp = tInfo.sSupportedComponent
          if #sClean >= #sComp then
            for i = 1, #sClean - #sComp + 1 do
              if sClean:sub(i, i + #sComp - 1) == sComp then
                bMatch = true
                break
              end
            end
          end
          if bMatch then
            table.insert(tNewDevs, sClean)
          end
        end

        if #tNewDevs > 0 then
          print("  New device(s) in /dev:")
          for _, sDev in ipairs(tNewDevs) do
            print("    " .. C_YELLOW .. "/dev/" .. sDev .. C_RESET)
          end
          print("")
        end
      end
    end

    return true
  else
    log_fail("Driver load failed!")
    print("")
    print("  " .. C_RED .. "Error: " .. C_RESET .. tostring(sPmMessage))
    print("")

    -- Diagnostics
    print("  " .. C_CYAN .. "Troubleshooting:" .. C_RESET)

    if tInfo.sDriverType == "ComponentModeDriver" then
      print("    - Is the required hardware component present?")
      print("    - Run: " .. C_GRAY .. "ls /dev" .. C_RESET .. " to check existing devices")
      print("    - The component type '" .. (tInfo.sSupportedComponent or "?") .. "' may not be connected")
    end

    if tostring(sResult):find("SECURITY") or tostring(sResult):find("denied") then
      print("    - Driver signature or security check failed")
      print("    - Ensure the driver file is not corrupted")
    end

    if tostring(sResult):find("STATUS_DRIVER_INIT_FAILED") or tostring(sResult):find("404") then
      print("    - DriverEntry returned an error status")
      print("    - Check " .. C_GRAY .. "logread" .. C_RESET .. " for detailed DKMS logs")
    end

    print("")
    return false
  end
end

-- =============================================
-- SCAN MODE (-s)
-- =============================================

local function scan_and_load(sComponentType)
  log_info("Scanning for component type: " .. C_YELLOW .. sComponentType .. C_RESET)
  log_verbose("Looking for driver at /drivers/" .. sComponentType .. ".sys.lua")

  local sDriverPath = "/drivers/" .. sComponentType .. ".sys.lua"

  -- Check if driver file exists
  local hCheck = fs.open(sDriverPath, "r")
  if not hCheck then
    log_fail("No driver file found for component type '" .. sComponentType .. "'")
    print("")
    print("  Expected driver at: " .. C_GRAY .. sDriverPath .. C_RESET)
    print("  Install it with:    " .. C_CYAN .. "pkgman -S " .. sComponentType .. " driver" .. C_RESET)
    return false
  end
  fs.close(hCheck)

  log_ok("Found driver file: " .. sDriverPath)
  return load_driver(sDriverPath)
end

-- =============================================
-- INSPECT MODE (-i)
-- =============================================

local function inspect_driver(sPath)
  log_info("Inspecting driver (no load)...")

  local sResolvedPath = resolve_path(sPath)
  if not sResolvedPath then
    log_fail("Could not find driver file: " .. sPath)
    return false
  end

  local tInfo, sErr = validate_driver_file(sResolvedPath)
  if not tInfo then
    log_fail("Validation failed: " .. sErr)
    return false
  end

  display_driver_info(sResolvedPath, tInfo)
  log_ok("Inspection complete. No changes made.")
  return true
end

-- =============================================
-- MAIN
-- =============================================

if #tArgs < 1 then
  print_usage()
  return
end

-- Parse flags
local sMode = "load"
local sTarget = nil

local i = 1
while i <= #tArgs do
  local sArg = tArgs[i]

  if sArg == "-v" or sArg == "--verbose" then
    bVerbose = true
    log_verbose("Verbose mode enabled")

  elseif sArg == "-s" or sArg == "--scan" then
    sMode = "scan"
    i = i + 1
    if i <= #tArgs then
      sTarget = tArgs[i]
    else
      log_fail("Missing component type after -s flag")
      print("  Usage: insmod -s <component_type>")
      return
    end

  elseif sArg == "-i" or sArg == "--info" then
    sMode = "inspect"
    i = i + 1
    if i <= #tArgs then
      sTarget = tArgs[i]
    else
      log_fail("Missing path after -i flag")
      print("  Usage: insmod -i <driver_path>")
      return
    end

  elseif sArg == "-h" or sArg == "--help" then
    print_usage()
    return

  elseif sArg:sub(1, 1) == "-" then
    log_fail("Unknown flag: " .. sArg)
    print("  Use " .. C_CYAN .. "insmod -h" .. C_RESET .. " for help.")
    return

  else
    if not sTarget then
      sTarget = sArg
    else
      log_fail("Too many arguments. Did you mean to use quotes?")
      return
    end
  end

  i = i + 1
end

if not sTarget then
  log_fail("No target specified.")
  print_usage()
  return
end

-- Header
print("")
print(C_CYAN .. "insmod" .. C_RESET .. " - AxisOS Driver Insertion Tool")
print(C_GRAY .. string.rep("-", 50) .. C_RESET)
print("")

-- Dispatch
if sMode == "load" then
  local bSuccess = load_driver(sTarget)
  if bSuccess then
    print(C_GREEN .. "Operation completed successfully." .. C_RESET)
  else
    print(C_RED .. "Operation failed. See errors above." .. C_RESET)
  end

elseif sMode == "scan" then
  local bSuccess = scan_and_load(sTarget)
  if bSuccess then
    print(C_GREEN .. "Scan and load completed successfully." .. C_RESET)
  else
    print(C_RED .. "Scan and load failed. See errors above." .. C_RESET)
  end

elseif sMode == "inspect" then
  inspect_driver(sTarget)
end
