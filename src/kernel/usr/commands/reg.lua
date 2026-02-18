--
-- /usr/commands/reg.lua
-- AxisOS Registry CLI — query, set, delete, tree
--
-- Usage:
--   reg query <path>             List subkeys and values
--   reg get <path> <name>        Get a specific value
--   reg set <path> <name> <val>  Set a value (Ring 2+ only)
--   reg tree [path]              Print full tree
--   reg info <path>              Key metadata
--   reg find <search>            Search key names
--

local tArgs = env.ARGS or {}

local C = {
  R = "\27[37m", RED = "\27[31m", GRN = "\27[32m", YLW = "\27[33m",
  BLU = "\27[34m", CYN = "\27[36m", GRY = "\27[90m", MAG = "\27[35m",
}

local function usage()
  print(C.CYN .. "reg" .. C.R .. " - AxisOS Virtual Registry Tool")
  print("")
  print("Usage:")
  print("  reg query <path>             List subkeys and values")
  print("  reg get <path> <name>        Get a specific value")
  print("  reg set <path> <name> <val>  Set a value")
  print("  reg tree [path] [depth]      Print tree")
  print("  reg info <path>              Key metadata")
  print("  reg find <term>              Search key names")
  print("")
  print("Paths start with @VT\\  e.g. @VT\\DEV  @VT\\DRV\\AxisTTY")
end

local function typeColor(sType)
  if sType == "STR" then return C.GRN
  elseif sType == "NUM" then return C.YLW
  elseif sType == "BOOL" then return C.MAG
  else return C.GRY end
end

local function formatValue(v)
  if type(v) == "table" then return "{...}" end
  return tostring(v)
end

local function cmd_query(sPath)
  if not sPath then print("reg query: missing path"); return end
  local bExists = syscall("reg_key_exists", sPath)
  if not bExists then
    print(C.RED .. "Key not found: " .. C.R .. sPath)
    return
  end

  print(C.CYN .. "Key: " .. C.R .. sPath)
  print("")

  -- subkeys
  local tKeys = syscall("reg_enum_keys", sPath)
  if tKeys and #tKeys > 0 then
    print(C.GRY .. "  Subkeys:" .. C.R)
    for _, sKey in ipairs(tKeys) do
      print("    " .. C.BLU .. sKey .. C.R)
    end
    print("")
  end

  -- values
  local tVals = syscall("reg_enum_values", sPath)
  if tVals and #tVals > 0 then
    print(C.GRY .. "  Values:" .. C.R)
    print(string.format("    %-24s %-6s %s", C.GRY .. "Name" .. C.R,
          C.GRY .. "Type" .. C.R, C.GRY .. "Data" .. C.R))
    print("    " .. C.GRY .. string.rep("-", 55) .. C.R)
    for _, tVal in ipairs(tVals) do
      local sTC = typeColor(tVal.sType)
      local sValStr = formatValue(tVal.value)
      if #sValStr > 40 then sValStr = sValStr:sub(1, 37) .. "..." end
      print(string.format("    %-24s %s%-6s%s %s",
            tVal.sName, sTC, tVal.sType, C.R, sValStr))
    end
  end

  if (not tKeys or #tKeys == 0) and (not tVals or #tVals == 0) then
    print(C.GRY .. "  (empty key)" .. C.R)
  end
end

local function cmd_get(sPath, sName)
  if not sPath or not sName then print("reg get: missing path or name"); return end
  local vVal, sType = syscall("reg_get_value", sPath, sName)
  if vVal ~= nil then
    local sTC = typeColor(sType)
    print(string.format("%s%s%s = %s (%s%s%s)",
          C.CYN, sName, C.R, formatValue(vVal), sTC, sType, C.R))
  else
    print(C.RED .. "Value not found: " .. C.R .. sName .. " in " .. sPath)
  end
end

local function cmd_set(sPath, sName, sValue)
  if not sPath or not sName or not sValue then
    print("reg set: missing path, name, or value"); return
  end
  -- auto-detect type
  local vVal = sValue
  local sType = "STR"
  local nNum = tonumber(sValue)
  if nNum then vVal = nNum; sType = "NUM"
  elseif sValue == "true" then vVal = true; sType = "BOOL"
  elseif sValue == "false" then vVal = false; sType = "BOOL"
  end

  -- ensure key exists
  syscall("reg_create_key", sPath)
  local bOk = syscall("reg_set_value", sPath, sName, vVal, sType)
  if bOk then
    print(C.GRN .. "[OK]" .. C.R .. " " .. sName .. " = " .. formatValue(vVal))
  else
    print(C.RED .. "[FAIL]" .. C.R .. " Could not set value (access denied?)")
  end
end

local function cmd_tree(sPath, nMaxDepth)
  sPath = sPath or "@VT"
  nMaxDepth = tonumber(nMaxDepth) or 10
  local tTree = syscall("reg_dump_tree", sPath, nMaxDepth)
  if not tTree or #tTree == 0 then
    print(C.RED .. "Key not found or empty: " .. C.R .. sPath)
    return
  end

  print(C.CYN .. "Registry Tree: " .. C.R .. sPath)
  print("")

  for _, tNode in ipairs(tTree) do
    local sIndent = string.rep("  ", tNode.nDepth)
    local sIcon = tNode.nSubKeys > 0 and "+" or "-"
    local sExtra = ""
    if tNode.nValues > 0 then
      sExtra = C.GRY .. " (" .. tNode.nValues .. " values)" .. C.R
    end
    print(string.format("%s%s%s %s%s%s",
          sIndent, C.YLW, sIcon, C.BLU, tNode.sName, C.R) .. sExtra)
  end
end

local function cmd_info(sPath)
  if not sPath then print("reg info: missing path"); return end
  local tInfo = syscall("reg_query_info", sPath)
  if not tInfo then
    print(C.RED .. "Key not found: " .. C.R .. sPath)
    return
  end
  print(C.CYN .. "Key Info: " .. C.R .. sPath)
  print("  Name:       " .. tInfo.sName)
  print("  Subkeys:    " .. tInfo.nSubKeys)
  print("  Values:     " .. tInfo.nValues)
  print("  Created:    " .. string.format("%.4f", tInfo.nCreated or 0))
  print("  Modified:   " .. string.format("%.4f", tInfo.nModified or 0))
end

local function cmd_find(sTerm)
  if not sTerm then print("reg find: missing search term"); return end
  local sLower = sTerm:lower()
  local tTree = syscall("reg_dump_tree", "@VT", 20)
  local nFound = 0
  for _, tNode in ipairs(tTree) do
    if tNode.sName:lower():find(sLower, 1, true) or
       tNode.sPath:lower():find(sLower, 1, true) then
      print(C.GRN .. "  " .. tNode.sPath .. C.R)
      nFound = nFound + 1
    end
  end
  if nFound == 0 then
    print(C.GRY .. "  No matches for '" .. sTerm .. "'" .. C.R)
  else
    print(C.GRY .. "  " .. nFound .. " match(es)" .. C.R)
  end
end

-- =============================================
-- DISPATCH
-- =============================================

if #tArgs < 1 then usage(); return end

local sCmd = tArgs[1]

if sCmd == "query"    then cmd_query(tArgs[2])
elseif sCmd == "get"  then cmd_get(tArgs[2], tArgs[3])
elseif sCmd == "set"  then cmd_set(tArgs[2], tArgs[3], tArgs[4])
elseif sCmd == "tree" then cmd_tree(tArgs[2], tArgs[3])
elseif sCmd == "info" then cmd_info(tArgs[2])
elseif sCmd == "find" then cmd_find(tArgs[2])
elseif sCmd == "-h" or sCmd == "--help" then usage()
else
  print(C.RED .. "Unknown command: " .. C.R .. sCmd)
  usage()
end