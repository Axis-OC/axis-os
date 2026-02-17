-- ls - list directory (Pro Edition)
-- now with colors, -l and -a support.

local fs = require("filesystem")
local tArgs = env.ARGS or {}

-- ANSI Colors
local C_RESET  = "\27[37m"
local C_DIR    = "\27[34m"
local C_DEV    = "\27[33m"
local C_EXEC   = "\27[32m"
local C_FILE   = "\27[37m"
local C_GRAY   = "\27[90m"

-- Parse arguments: flags start with -, everything else is the path
local bLongMode = false
local bShowAll  = false
local sPath = nil

for _, sArg in ipairs(tArgs) do
  if sArg:sub(1, 1) == "-" then
    -- walk each flag character after the dash
    for i = 2, #sArg do
      local c = sArg:sub(i, i)
      if c == "l" then
        bLongMode = true
      elseif c == "a" then
        bShowAll = true
      else
        print("ls: unknown option -- '" .. c .. "'")
        print("Usage: ls [-la] [directory]")
        return
      end
    end
  elseif not sPath then
    sPath = sArg
  else
    print("ls: too many arguments")
    print("Usage: ls [-la] [directory]")
    return
  end
end

local sPwd = env.PWD or "/"
local sTargetDir = sPath or sPwd

-- Resolve relative paths
if sTargetDir:sub(1,1) ~= "/" then
  sTargetDir = sPwd .. (sPwd == "/" and "" or "/") .. sTargetDir
end
sTargetDir = sTargetDir:gsub("//", "/")

-- Get file list
local tList, sErr = fs.list(sTargetDir)
if not tList or type(tList) ~= "table" then
  print("ls: cannot access '" .. sTargetDir .. "': " .. tostring(sErr or "No such file or directory"))
  return
end

table.sort(tList)

-- Load permissions DB for -l mode
local tPermsDb = {}
if bLongMode then
  local hPerms = fs.open("/etc/perms.lua", "r")
  if hPerms then
    local sData = fs.read(hPerms, math.huge)
    fs.close(hPerms)
    if sData then
       local f = load(sData, "perms", "t", {})
       if f then tPermsDb = f() end
    end
  end
end

local function format_mode(nMode)
  if not nMode then return "rwxr-xr-x" end
  local sM = string.format("%03d", nMode)
  local sRes = ""
  local tMaps = { [7]="rwx", [6]="rw-", [5]="r-x", [4]="r--", [0]="---" }
  for i=1, 3 do
    local c = tonumber(sM:sub(i,i))
    sRes = sRes .. (tMaps[c] or "???")
  end
  return sRes
end

local tBuffer = {}

for _, sName in ipairs(tList) do
  local bIsDir = (sName:sub(-1) == "/")
  local sCleanName = bIsDir and sName:sub(1, -2) or sName

  -- skip dotfiles unless -a
  if not bShowAll and sCleanName:sub(1, 1) == "." then
    goto continue
  end

  local sFullPath = sTargetDir .. (sTargetDir == "/" and "" or "/") .. sCleanName

  local sColor = C_FILE
  local sTypeChar = "-"

  if bIsDir then
    sColor = C_DIR
    sTypeChar = "d"
  elseif sTargetDir:sub(1, 5) == "/dev/" or sTargetDir == "/dev" then
    sColor = C_DEV
    sTypeChar = "c"
  elseif sName:sub(-4) == ".lua" then
    sColor = C_EXEC
  end

  if bLongMode then
    local tP = tPermsDb[sFullPath]
    local sModeStr = format_mode(tP and tP.mode)
    local nUid = tP and tP.uid or 0
    local sOwner = (nUid == 0) and "root" or tostring(nUid)
    if #sOwner < 5 then sOwner = sOwner .. string.rep(" ", 5 - #sOwner) end

    local sLine = string.format("%s%s%s %s %s%s%s",
      C_GRAY, sTypeChar .. sModeStr, C_RESET,
      sOwner,
      sColor, sName, C_RESET
    )
    table.insert(tBuffer, sLine)
  else
    table.insert(tBuffer, sColor .. sName .. C_RESET)
  end

  ::continue::
end

if #tBuffer > 0 then
  io.write(table.concat(tBuffer, "\n") .. "\n")
end