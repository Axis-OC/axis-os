--
-- pkgman - AxisOS Package Manager
-- "It's like pacman, but with more howling."
--

local fs = require("filesystem")
local sys = require("syscall")
local tArgs = env.ARGS

-- Configuration
local REPO_BASE = "https://raw.githubusercontent.com/nyanity/AxisOS/refs/heads/v0.21N25RC01/src/packages/"

-- Mappings for "zoning"
local tZones = {
  driver = { path = "drivers/", local_dir = "/drivers/", ext = ".sys.lua" },
  bin    = { path = "executable/", local_dir = "/usr/commands/", ext = ".lua" },
  lib    = { path = "multilib/", local_dir = "/usr/lib/", ext = ".lua" },
  module = { path = "modules/", local_dir = "/lib/", ext = ".lua" }
}

local function print_usage()
  -- buffered output construction
  local tOut = {}
  table.insert(tOut, "\27[36mpkgman v1.2\27[37m")
  table.insert(tOut, "usage: pkgman <operation> [...]")
  table.insert(tOut, "operations:")
  table.insert(tOut, "  -S <package> [type]   install a package")
  table.insert(tOut, "                        types: driver, bin (default), lib, module")
  table.insert(tOut, "  -R <package>          remove a package")
  
  -- one single write syscall for the whole help message
  print(table.concat(tOut, "\n"))
end

local function download_file(sUrl, sDest)
  local http = require("http")

  local stream, sErr = http.open(sUrl)
  if not stream then return false, sErr end

  -- check for 404 before writing
  if stream.code == 404 then
    stream:close()
    return false, "404 Not Found"
  end

  local hFile = fs.open(sDest, "w")
  if not hFile then
    stream:close()
    return false, "Write permission denied"
  end

  local nBytes = 0
  while true do
    local sChunk = stream:read(2048)
    if not sChunk then break end
    fs.write(hFile, sChunk)
    nBytes = nBytes + #sChunk
    local sSizeStr = string.format("%.1f KB", nBytes / 1024)
    io.write("\r\27[K :: Downloading... " .. sSizeStr)
  end

  fs.close(hFile)
  stream:close()
  io.write("\n")
  return true
end

local function install_package(sName, sType)
  sType = sType or "bin"
  local tZone = tZones[sType]
  
  if not tZone then
    print("\27[31merror:\27[37m unknown package type: " .. sType)
    return
  end
  
  local sUrl = REPO_BASE .. tZone.path .. sName .. tZone.ext
  local sDest = tZone.local_dir .. sName .. tZone.ext
  
  -- use one print for the header info
  local sHeader = string.format(
    "\27[1m\27[34m::\27[37m Searching for \27[36m%s\27[37m in \27[33m%s\27[37m...\n" ..
    "\27[1m\27[34m::\27[37m Resolving dependencies...\n" ..
    "\27[1m\27[34m::\27[37m Packages to install (1): \27[36m%s\27[37m", 
    sName, sType, sName
  )
  print(sHeader)
  
  -- actually download
  local bOk, sErr = download_file(sUrl, sDest)
  
  if bOk then
    print(string.format("\27[1m\27[32m[OK]\27[37m Installed to %s", sDest))
    
    if sType == "driver" then
       io.write("\27[1m\27[34m::\27[37m Loading driver module... ")
       local bLoadOk, sLoadMsg = sys.syscall("driver_load", sDest)
       if bLoadOk then
          print("\27[32m[LOADED]\27[37m\n   " .. tostring(sLoadMsg))
       else
          print("\27[31m[FAILED]\27[37m\n   " .. tostring(sLoadMsg))
       end
    elseif sType == "bin" then
       fs.chmod(sDest, 755)
    end
  else
    print("\n\27[31merror:\27[37m failed to download: " .. tostring(sErr))
  end
end

if #tArgs < 1 then print_usage(); return end

local sOp = tArgs[1]

if sOp == "-S" then
  if not tArgs[2] then print("error: no package specified"); return end
  install_package(tArgs[2], tArgs[3])
elseif sOp == "-R" then
  print("remove not implemented yet.")
else
  print_usage()
end