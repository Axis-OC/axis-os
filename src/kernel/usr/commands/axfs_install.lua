--
-- /usr/commands/axfs_install.lua
-- Install AxisOS onto an AXFS partition
--
-- Usage:
--   axfs_install <device> <partition#>
--
-- Copies the entire OS tree from the managed FS root
-- onto the specified AXFS partition, making it bootable.
--

local fs = require("filesystem")
local tArgs = env.ARGS or {}

local C = {R="\27[37m", G="\27[32m", Y="\27[33m", C="\27[36m", E="\27[31m", D="\27[90m"}

local sDev  = tArgs[1]
local sPart = tArgs[2]

if not sDev or not sPart then
  print(C.C .. "axfs_install" .. C.R .. " — Install AxisOS to AXFS partition")
  print("  Usage: axfs_install <device> <partition#>")
  print("")
  print("  Example:")
  print("    axfs init /dev/drive_xxx_0")
  print("    axfs addpart /dev/drive_xxx_0 SYSTEM 900")
  print("    axfs format /dev/drive_xxx_0 0 AxisOS")
  print("    axfs_install /dev/drive_xxx_0 0")
  print("")
  print("  Then flash /boot/axfs_boot.lua to EEPROM to boot from it.")
  return
end

-- Open device + partition
local hDev = fs.open(sDev, "r")
if not hDev then print(C.E .. "Cannot open " .. sDev .. C.R); return end

-- Get partition info
local AX = require("axfs_core")
local RDB = require("rdb")

local bI, tI = fs.deviceControl(hDev, "info", {})
if not bI or not tI then
  fs.close(hDev); print(C.E .. "Device info failed" .. C.R); return
end

-- We need to use the raw approach via AXFS
-- Read RDB through device control
local function readSec(n)
  local bOk, sData = fs.deviceControl(hDev, "read_sector", {n + 1})
  return bOk and sData or nil
end

local function writeSec(n, sData)
  return fs.deviceControl(hDev, "write_sector", {n + 1, sData})
end

-- Parse RDB
local s0 = readSec(0)
if not s0 or s0:sub(1,4) ~= "AXRD" then
  fs.close(hDev); print(C.E .. "No RDB on device" .. C.R); return
end

local nP = tonumber(sPart)
local ps = readSec(nP + 1)
if not ps or ps:sub(1,4) ~= "AXPT" then
  fs.close(hDev); print(C.E .. "Partition " .. sPart .. " not found" .. C.R); return
end

local B = require("bpack")
local pOff = B.r32(ps, 30)
local pCnt = B.r32(ps, 34)

print(C.C .. "Installing AxisOS to partition " .. sPart .. C.R)
print(C.D .. "  Offset: sector " .. pOff .. ", Size: " .. pCnt .. " sectors" .. C.R)

-- Create a tDisk wrapper for AXFS
local tDisk = {
  sectorSize = tI.sectorSize,
  sectorCount = pCnt,
  readSector = function(n) return readSec(pOff + n) end,
  writeSector = function(n, d)
    d = d or ""
    if #d < tI.sectorSize then d = d .. string.rep("\0", tI.sectorSize - #d) end
    return writeSec(pOff + n, d:sub(1, tI.sectorSize))
  end,
}

-- Mount AXFS
local vol, vErr = AX.mount(tDisk)
if not vol then
  fs.close(hDev); print(C.E .. "Mount failed: " .. tostring(vErr) .. C.R); return
end

-- Recursive copy from managed FS to AXFS
local nFiles = 0
local nDirs = 0
local nBytes = 0
local nErrors = 0

-- Directories to skip (runtime-generated, not needed)
local tSkip = {
  ["/tmp"] = true,
  ["/log"] = true,
  ["/vbl"] = true,
}

local function copyTree(sSrcDir, sDstDir)
  local tList = fs.list(sSrcDir)
  if not tList then return end

  for _, sName in ipairs(tList) do
    local bIsDir = sName:sub(-1) == "/"
    local sClean = bIsDir and sName:sub(1, -2) or sName
    local sSrcPath = sSrcDir .. (sSrcDir == "/" and "" or "/") .. sClean
    local sDstPath = sDstDir .. (sDstDir == "/" and "" or "/") .. sClean

    sSrcPath = sSrcPath:gsub("//", "/")
    sDstPath = sDstPath:gsub("//", "/")

    if tSkip[sSrcPath] then
      io.write(C.D .. "  SKIP  " .. sSrcPath .. C.R .. "\n")
    elseif bIsDir then
      io.write(C.Y .. "  DIR   " .. sDstPath .. C.R .. "\n")
      vol:mkdir(sDstPath)
      nDirs = nDirs + 1
      copyTree(sSrcPath, sDstPath)
    else
      -- Read file from managed FS
      local hSrc = fs.open(sSrcPath, "r")
      if hSrc then
        local tChunks = {}
        while true do
          local sChunk = fs.read(hSrc, math.huge)
          if not sChunk then break end
          tChunks[#tChunks + 1] = sChunk
        end
        fs.close(hSrc)
        local sData = table.concat(tChunks)

        -- Strip CR from CRLF
        sData = sData:gsub("\r\n", "\n")

        local bOk, sErr = vol:writeFile(sDstPath, sData)
        if bOk then
          nFiles = nFiles + 1
          nBytes = nBytes + #sData
          io.write(C.G .. "  FILE  " .. C.R .. sDstPath ..
                   C.D .. " (" .. #sData .. "B)" .. C.R .. "\n")
        else
          nErrors = nErrors + 1
          io.write(C.E .. "  FAIL  " .. sDstPath .. ": " .. tostring(sErr) .. C.R .. "\n")
        end
      else
        nErrors = nErrors + 1
        io.write(C.E .. "  FAIL  Cannot read " .. sSrcPath .. C.R .. "\n")
      end
    end
  end
end

print("")
print(C.C .. "Copying filesystem tree..." .. C.R)
print("")

-- Create essential directories first
for _, sDir in ipairs({"/bin", "/etc", "/lib", "/drivers", "/system",
    "/usr", "/usr/commands", "/home", "/tmp", "/boot",
    "/system/lib", "/system/lib/dk", "/lib/vi",
    "/sys", "/sys/security"}) do
  vol:mkdir(sDir)
end

-- Copy everything
copyTree("/", "/")

-- Flush
vol:flush()
fs.close(hDev)

-- Summary
print("")
print(C.C .. string.rep("=", 50) .. C.R)
print(C.G .. "  Installation complete!" .. C.R)
print(string.format("  %s%d%s files, %s%d%s directories, %s%s%s bytes",
  C.G, nFiles, C.R, C.Y, nDirs, C.R,
  C.C, tostring(nBytes), C.R))
if nErrors > 0 then
  print(C.E .. "  " .. nErrors .. " error(s) — check output above" .. C.R)
end
print(C.C .. string.rep("=", 50) .. C.R)
print("")
print("  Next steps:")
print("  1. Flash the AXFS bootloader to EEPROM:")
print("     " .. C.Y .. "provision" .. C.R .. " (or manually flash /boot/axfs_boot.lua)")
print("  2. Reboot — the system will boot from AXFS")
print("")